#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Repository gate: frontmatter, byte budgets, pointers, public content, attribution, credentials, evals.
"""Usage: check-skills.py [--only frontmatter,budget,pointers,public,attribution,credentials,evals]

Exit 0 when every check passes, 1 otherwise; 2 when --only names a check that does not exist.
One line per finding: "<check>: <file>[:<line>]: <message>".
"""

import argparse
import importlib.util
import json
import os
import re
import sys
from pathlib import Path

# The gate imports the skill's own scripts and must leave no cache in the tree it checks.
sys.dont_write_bytecode = True

CHECKS = "frontmatter,budget,pointers,public,attribution,credentials,evals"
ROOT = Path(__file__).resolve().parents[2]
SKILLS = ROOT / "skills"

NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
ALLOWED_KEYS = {
    "name",
    "description",
    "license",
    "compatibility",
    "metadata",
    "allowed-tools",
}

# Byte caps: what one read may cost an agent. Why these numbers: AGENTS.md "Token budget".
# The body of SKILL.md, the text after its frontmatter, is loaded on every trigger; the Agent
# Skills specification recommends under 5,000 tokens for it. The gate cannot count tokens, so
# the cap is bytes: (5000 - 150) * bytes / tokens of the openqa body, rounded down to 100; the
# 150 tokens are headroom, because bytes per token vary with the text.
# Measured 2026-10-12 on claude-opus-5-5: 12,625 bytes = 4,816 tokens. One sample is a call of
#   claude -p --output-format stream-json --verbose --model claude-opus-5-5 --tools "" \
#     --system-prompt "Answer with one word."
# with a fixed one-line prompt on stdin, once alone and once followed by the body. The tokens
# are the difference of input_tokens + cache_creation_input_tokens + cache_read_input_tokens in
# the usage of the first assistant event. Measure again before raising the cap.
BODY_CAP = 12700
# SKILL.md as a file: the specification asks for under 500 lines.
LINE_CAP = 499
# A "## " section of a reference with its "### " parts: the least one pointer makes an agent read.
SECTION_CAP = 5000
# All that one pointer joins by ",": two full sections, as one call is one tool output.
GROUP_CAP = 10000
# A reference: read whole by mistake, it still fits the 30,000 characters Claude Code returns of
# a command's output by default (BASH_MAX_OUTPUT_LENGTH).
FILE_CAP = 17000
# A playbook, read whole by its sub-agent.
AGENT_CAP = 5000
# References that are read whole, each capped as the one read it is.
BUDGETS = {
    "references/untrusted-content.md": 7900,
}

# A document is the whole path as written, because that is the argument refsection.py is
# given; the lookbehind only keeps the scan linear.
_FILE = r"(?<![A-Za-z0-9_./-])([A-Za-z0-9_./-]+\.md)"
# 'file.md "A", "B" / "C"' names sections of one file, with or without a "->" before it.
POINTER_RE = re.compile(_FILE + r"((?:(?:\s*[,/])?\s*\"[^\"\n]+\")+)")
# The path alone names a reference or a playbook: one read whole has no section to point at.
# A longer name ("x.md.bak", "x.md5") is another file.
NAMED_RE = re.compile(_FILE + r"(?![A-Za-z0-9_-]|[./][A-Za-z0-9_])")
# An HTML comment, on one line or several, is not rendered: it shows a name to no reader.
COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)
# '-> "A", "B"' without a file names sections of the file the line is in.
BARE_RE = re.compile(r"->\s*((?:\"[^\"\n]+\"(?:\s*[,/]\s*)?)+)")
QUOTED = re.compile(r'"([^"\n]+)"')
# One call of refsection.py: a "->", or a file name without one, with the file names and titles
# that follow it, joined by "," or "/"; any other text ends it. A joiner at the end of the
# line leaves it open: what the next line adds would be measured as another pointer.
CHAIN_RE = re.compile(
    rf'(?:->|(?={_FILE}))((?:\s*(?:[,/]\s*)?(?:{_FILE}|"[^"\n]+"))+)(\s*[,/]\s*$)?'
)
LINK_RE = re.compile(rf'([,/])?\s*(?:{_FILE}|"([^"\n]+)")')

# "## " sections of a reference that no pointer leads to, per skill and file: an agent finds
# them only through `refsection.py --list`. The note says what leads there by name, or that
# the section is background. A new section gets a pointer, not an entry.
UNROUTED = {
    "openqa": {
        "agnostic-tests.md": {
            "Converting existing modules",  # background
        },
        "area-conventions.md": {
            "Security",  # "Find the area": the CODEOWNERS block of this name
        },
        "openqa-model.md": {
            "Vocabulary",  # background
        },
        "redaction.md": {
            "Why the skill has to do it",  # background
        },
        "review-comments-tickets.md": {
            "Good examples",  # background
            "Poor examples",  # background
        },
        "review-tooling.md": {
            "openQA-python-client",  # background
        },
        "site-policy.md": {
            "Generic or site-specific",  # background
            "Not in this skill",  # background
        },
    },
}

# Content that must not reach a public repository.
PUBLIC_PATTERNS = [
    (
        r"gitlab\.suse\.de|confluence|jira\.suse|\.slack\.com|smelt|dashboard\.qam|monitor\.qa\.suse",
        "internal service",
    ),
    (
        r"(?<![\w.-])(?!openqa\.suse\.de)[\w-]+(?:\.[\w-]+)*\.suse\.de\b",
        "internal host",
    ),
    (r"#(?:team|discuss|proj|eng)-[\w-]+", "chat channel"),
    (r"\b[\w.+-]+@suse\.(?:de|com|cz)\b", "e-mail address"),
    (
        r"openqa\.suse\.de/(?:tests|group_overview|api)",
        "runnable example against the internal instance",
    ),
]
PUBLIC_ALLOW = {
    # openQA's own tracker map (lib/OpenQA/Utils.pm) names this host for the jsc# prefix
    "skills/openqa/scripts/oqa-comment-lint.py": [r"jira\.suse"],
    "tests/openqa/test-oqa-comment-lint.sh": [r"jira\.suse"],
    # hazard detection for production hosts is tested with the host name only
    "tests/openqa/test-vr-clone-cmd.sh": [r"openqa\.suse\.de/tests"],
    # the slack-webhook redaction rule is tested on Slack's public webhook host
    "tests/openqa/test-_secrets.sh": [r"\.slack\.com"],
}

ATTRIBUTION_PATTERNS = [
    (r"co-authored-by\s*:", "co-author trailer"),
    (r"generated (?:with|by)\b", "generated-with footer"),
    (r"\U0001F916", "robot emoji"),
    (r"assisted-by:\s*(?!<)\S", "Assisted-by trailer naming a concrete model"),
    (
        r"\b(?:written|authored|produced|created) (?:by|with) (?:an? )?(?:ai|llm|assistant|language model)\b",
        "AI authorship",
    ),
    (r"\banthropic\b", "vendor name"),
    (r"\bclaude\b(?! code\b)(?!\.md\b)(?!-plugin)(?!/)", "assistant name"),
]
# The upstream rule on commit trailers is described, neutrally, in exactly one place.
ATTRIBUTION_ALLOW_FILES = {"skills/openqa/references/contributing-gates.md"}
ATTRIBUTION_SKIP_CONTEXT = re.compile(
    r"\.claude(?:-plugin)?/|CLAUDE\.md|Claude Code", re.IGNORECASE
)

# Documentation must never teach an agent to handle a credential itself: that is how an
# agent learns to scrape a token. A slot or $VAR standing for a key still puts it on the
# command line. Command words count only where a command starts, so prose naming one passes;
# gaps are bounded to keep the scan linear.
_CMD = r"(?:^\s*(?:\$\s+)?|`|(?:&&|\|\||;)\s*|\$\(\s*)(?:sudo(?:\s+-\w+(?:\s+(?!-)[\w.-]+)?)*\s+)?"
_TOKEN_VAR = r"[A-Z_]{0,40}(?:TOKEN|API_KEY|API_SECRET|PASSWORD|(?<![A-Z])PAT)\b"
_PRINTER = (
    r"(?:git\s+credential\s+fill|gh\s+auth\s+git-credential|secret-tool\s+lookup"
    r"|osc\s+(?:config\s+--dump-full|token))\b"
)
CREDENTIAL_PATTERNS = [
    (
        (
            rf"(?:{_CMD}(?:cat|bat|less|more|head|tail|grep|rg|sed|awk|source|jq|yq|strings|xxd"
            r"|od|base64|cp|scp|python3?|perl|open)\b"
            r"(?:[^\n|;&`'\"]{0,100}?(?:'[^'\n]{0,100}'|\"[^\"\n]{0,100}\")){0,3}[^\n|;&`]{0,200}?"
            r"|(?:\bopen|\.read|\bPath)\((?:[^\n)`]|\(\)){0,200}?|(?:\$\(|\s)<\s*(?=[~/$.])[^\s`]{0,200}?)"
            r"(?:client\.conf|hosts\.yml|oscrc|\.netrc|tea/config\.yml|\.git-credentials|git/credentials"
            r"|/proc/[^/\s]+/environ|(?:\.config|etc)/(?:openqa|gh|osc|tea)/?(?=[\s'\"`)*]|$))"
        ),
        "reads a credential file",
    ),
    (
        (
            r"\$\(\s*gh\s+auth\s+token|=\s*`\s*gh\s+auth\s+token"
            r"|(?:^\s*(?:\$\s+)?|(?:&&|\|\|)\s*)(?:\w+=[^\s&|;]*\s+)*gh\s+auth\s+token\b"
            r"|\bgh(?<!\|gh)(?<!\|\sgh)\s+auth\s+(?:token\b[^\n|>`]{0,80}?[|>]"
            r"|status\b[^\n|;&`]{0,80}?\s(?:-\w*t\w*|--show-token)\b(?!`))"
        ),
        "prints gh's token",
    ),
    (
        # a span holding only the command names it; a leading | opens a table row, not a pipe
        rf"{_CMD}(?<!`){_PRINTER}|`{_PRINTER}(?!`)|^(?!\s*\|)[^\n]*?\|\s*{_PRINTER}",
        "runs a credential printer",
    ),
    (
        r"--api-?(?:key|secret)[ =][\"'`]?(?:<[^>\s]+>|\$[({]?\w|(?![a-z]+\b)[A-Za-z0-9+/=_.-]{6,})",
        "passes a key on the command line",
    ),
    (
        (
            rf"{_CMD}curl\b[^\n|;&`]{{0,200}}?\s(?:(?:-u\s*|--user[\s=]\s*)[\"']?[^\s:\"'`]{{0,100}}:"
            r"(?:<[^>\s]+>|\$[({]?\w|[^\s\"'`]{6,})|--oauth2-bearer[\s=])"
        ),
        "passes a key on the command line",
    ),
    (
        (
            r"(?i)\b(?:Authorization|X-[\w-]{0,40}?API-?(?:Key|Hash)|X-Auth-Token|PRIVATE-TOKEN)"
            r"\s*:\s*(?:\w+\s+)?(?:\$[({]?\w|(?![<\[`])[A-Za-z0-9+/=_.-]{16,})"
        ),
        "a concrete auth header value",
    ),
    (r"https?://[^\s/:@`]+:(?!\[REDACTED)[^\s/@`]+@", "a password in a URL"),
    (
        (
            rf"https?://(?:\$\{{?{_TOKEN_VAR}\}}?|[A-Za-z0-9_-]{{20,}})@"
            r"|[?&](?:api[_-]?key|key|(?:access_|private_)?token)=(?![A-Z0-9_*]*[_*])"
            r"(?:\$[({]?\w|[A-Za-z0-9._~+/-]{16,})"
        ),
        "a token in a URL",
    ),
    (
        (
            rf"{_CMD}(?:(?:(?:echo|printf)\b[^\n|;&`]{{0,80}}?\$\{{?|printenv\s+){_TOKEN_VAR}"
            r"|(?:env|printenv)\s*\|)|^\s*(?:\$\s+)?(?:env|printenv|export(?:\s+-p)?)\s*$"
        ),
        "prints the environment or a token variable",
    ),
    (
        (
            r"\bMOJO_CLIENT_DEBUG=(?!0\b)[^\s`;&|]{1,20}\s+[\w./$~-]"
            r"|^\s*(?:\$\s+)?(?:export|declare\s+-x)\s+MOJO_CLIENT_DEBUG=(?!0\b)"
        ),
        "turns on MOJO_CLIENT_DEBUG",
    ),
]

TEXT_SUFFIXES = {
    ".md",
    ".py",
    ".sh",
    ".json",
    ".jsonc",
    ".rules",
    ".yaml",
    ".yml",
    ".txt",
    ".toml",
    "",
}


def read(path):
    """The text as refsection.py serves it: check_pointers reports a byte that is not UTF-8."""
    return path.read_text(encoding="utf-8", errors="replace")


def split_frontmatter(text):
    """(frontmatter, body), delimited as scripts/refsection.py reads it; none closed: (None, text)."""
    lines = text.split("\n")
    if lines[0].strip() == "---":
        for num, line in enumerate(lines[1:], 1):
            if line.strip() == "---":
                return "\n".join(lines[1:num]), "\n".join(lines[num + 1 :])
    return None, text


def frontmatter(path):
    block, _ = split_frontmatter(read(path))
    if block is None:
        return None
    data, key = {}, None
    for line in block.splitlines():
        if m := re.match(r"^([\w-]+):\s*(.*)$", line):
            key, val = m.group(1), m.group(2)
            data[key] = "" if val in (">-", ">", "|", "|-") else val
        elif key and line.startswith(" "):
            data[key] = (data[key] + " " + line.strip()).strip()
    return data


def check_frontmatter(skill, out):
    fm = frontmatter(skill / "SKILL.md")
    rel = f"skills/{skill.name}/SKILL.md"
    if fm is None:
        out.append(f"frontmatter: {rel}: missing frontmatter")
        return
    for key in set(fm) - ALLOWED_KEYS:
        out.append(
            f"frontmatter: {rel}: key '{key}' is not in the Agent Skills specification"
        )
    name = fm.get("name", "")
    if not NAME_RE.match(name) or len(name) > 64:
        out.append(
            f"frontmatter: {rel}: name '{name}' must match {NAME_RE.pattern} (max 64)"
        )
    if name != skill.name:
        out.append(
            f"frontmatter: {rel}: name '{name}' differs from directory '{skill.name}'"
        )
    if not 1 <= len(fm.get("description", "")) <= 1024:
        out.append(
            f"frontmatter: {rel}: description must be 1-1024 characters, is {len(fm.get('description', ''))}"
        )
    if not fm.get("license"):
        out.append(f"frontmatter: {rel}: license missing")
    # `gh skill publish` refuses a list here: "allowed-tools must be a string
    # (space-delimited), not an array", which makes the skill unpublishable.
    if fm.get("allowed-tools", "").lstrip().startswith("-"):
        out.append(
            f"frontmatter: {rel}: allowed-tools must be a space-delimited string"
        )


def section_reader(skill):
    """The skill's own refsection.py: sections are cut and measured as an agent is served them."""
    script = skill / "scripts" / "refsection.py"
    if not script.exists():
        return None
    path, modules = sys.path[:], set(sys.modules)
    sys.path[:0] = [str(script.parent)]  # it imports its sibling _sanitize
    try:
        spec = importlib.util.spec_from_file_location("refsection", script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.path[:] = path
        siblings = {p.stem for p in script.parent.glob("*.py")}
        for name in siblings & (set(sys.modules) - modules):
            del sys.modules[name]  # the next skill imports its own
    return module


def outline(reader, path):
    """Yield (title, level, first line, last line, bytes) per heading; bytes are what
    `refsection.py --list` prints."""
    lines = read(path).split("\n")
    for sec in reader.parse(lines):
        size = len(reader.body(lines, sec).encode("utf-8"))
        yield sec.title, sec.level, sec.start + 1, sec.end, size


def check_budget(skill, out):
    where = f"skills/{skill.name}"
    # Bytes as on disk: read_text() drops the "\r" of a CRLF file.
    text = (skill / "SKILL.md").read_bytes().decode("utf-8", errors="replace")
    size = len(split_frontmatter(text)[1].encode("utf-8"))
    if size > BODY_CAP:
        out.append(
            f"budget: {where}/SKILL.md: body of {size} bytes exceeds cap {BODY_CAP} by {size - BODY_CAP}"
        )
    lines = len(text.split("\n")) - text.endswith("\n")
    if lines > LINE_CAP:
        out.append(
            f"budget: {where}/SKILL.md: {lines} lines exceeds cap {LINE_CAP} by {lines - LINE_CAP}"
        )
    for path in sorted(skill.rglob("*.md")):
        rel = path.relative_to(skill).as_posix()
        if rel.startswith("scripts/") or rel == "SKILL.md":
            continue
        cap = BUDGETS.get(rel, AGENT_CAP if rel.startswith("agents/") else FILE_CAP)
        size = path.stat().st_size
        if size > cap:
            out.append(
                f"budget: {where}/{rel}: {size} bytes exceeds cap {cap} by {size - cap}"
            )
    if not (skill / "references").is_dir():
        return
    reader = section_reader(skill)
    if reader is None:
        out.append(
            f"budget: {where}/scripts/refsection.py: missing, so no section can be measured"
        )
        return
    for path in sorted((skill / "references").glob("*.md")):
        for title, level, first, _, size in outline(reader, path):
            if level >= 2 and size > SECTION_CAP:
                out.append(
                    f'budget: {where}/references/{path.name}:{first}: section "{title}" is {size} '
                    f"bytes, {size - SECTION_CAP} over the section cap {SECTION_CAP}"
                )


def documents(skill):
    """{path relative to the skill: Path} of the files that hold pointers."""
    paths = [
        skill / "SKILL.md",
        *sorted((skill / "references").glob("*.md")),
        *sorted((skill / "agents").glob("*.md")),
    ]
    return {p.relative_to(skill).as_posix(): p for p in paths}


def unfenced_lines(path):
    fenced = False
    # Split as refsection.py does, so that a line has one number everywhere.
    for num, line in enumerate(read(path).split("\n"), 1):
        if line.lstrip().startswith(("```", "~~~")):
            fenced = not fenced
        if not fenced:
            yield num, line


def pointers_on(line):
    """([(file, or None for the file the line is in, [titles])], [other quoted strings after "->"])."""

    def titles(m, part):
        found = QUOTED.finditer(m.group(part))
        return {m.start(part) + q.start(): q.group(1) for q in found}

    named = [(m.group(1), titles(m, 2)) for m in POINTER_RE.finditer(line)]
    bare = [(None, titles(m, 1)) for m in BARE_RE.finditer(line)]
    taken = {col for _, cols in named + bare for col in cols}
    found = QUOTED.finditer(line, line.index("->")) if "->" in line else ()
    return (
        [(name, list(cols.values())) for name, cols in named + bare],
        [q.group(1) for q in found if q.start() not in taken],
    )


def chains_on(line):
    """Per chain of the line, what one call is asked for: one list per "," of the (file, or
    None for the file the line is in, title) pairs that "/" leaves to pick from; then the
    joiner the line ends in, if it leaves the chain open."""
    for chain in CHAIN_RE.finditer(line):
        name, parts, joint = None, [], ","
        for m in LINK_RE.finditer(chain.group(2)):
            joint = m.group(1) or joint
            if m.group(2):
                name = m.group(2)
                continue
            if joint == "," or not parts:
                parts.append([])
            parts[-1].append((name, m.group(3)))
            joint = ","
        yield parts, (chain.group(4) or "").strip()


def check_pointers(skill, out):
    where = f"skills/{skill.name}"
    reader = section_reader(skill)
    docs = documents(skill)
    for rel, path in docs.items():
        try:
            path.read_bytes().decode("utf-8")
        except UnicodeDecodeError as error:
            line = error.object.count(b"\n", 0, error.start) + 1
            out.append(f"pointers: {where}/{rel}:{line}: not valid UTF-8")
    # refsection.py looks a reference up at the top level only, and documents() reads no other.
    for top in ("references", "agents"):
        for path in sorted((skill / top).glob("*/**/*.md")):
            out.append(
                f"pointers: {where}/{path.relative_to(skill).as_posix()}: {top}/ is one "
                "level deep: move this file up"
            )
    targets = {r: p for r, p in docs.items() if not r.startswith("agents/")}
    if (skill / "scripts" / "README.md").exists():
        targets["scripts/README.md"] = skill / "scripts" / "README.md"
    if reader is None and any(
        pointers_on(line)[0] for p in docs.values() for _, line in unfenced_lines(p)
    ):
        out.append(
            f"pointers: {where}/scripts/refsection.py: missing, so no pointer can be resolved"
        )
    # Keyed by every name refsection.py resolves to the file:
    # {title: (level, first line, last line, bytes)}.
    heads, links = {}, []
    for rel, path in targets.items() if reader else ():
        found, seen = {}, {}
        sections = list(outline(reader, path))
        folded = [title.casefold() for title, *_ in sections]
        for title, level, first, last, size in sections:
            if title.casefold() in seen:
                out.append(
                    f'pointers: {where}/{rel}:{first}: heading "{title}" repeats '
                    f"line {seen[title.casefold()]}"
                )
            seen.setdefault(title.casefold(), first)
            found.setdefault(title, (level, first, last, size))
            if title.endswith(".md"):
                out.append(
                    f'pointers: {where}/{rel}:{first}: heading "{title}" ends in .md, '
                    "which refsection.py reads as a file"
                )
            # refsection.py takes a prefix only one title has: a script's notes by the script's name
            if rel == "scripts/README.md":
                short = title.split(" - ")[0]
                if sum(t.startswith(short.casefold()) for t in folded) == 1:
                    found.setdefault(short, (level, first, last, size))
        heads[rel] = found
        if rel.startswith("references/"):
            heads[path.name] = found
    for rel, path in docs.items() if reader else ():
        own = None if rel.startswith("agents/") else path.name
        # A reference is served one "## " section at a time: a pointer leads on from the
        # section it is in, and the lines above the first section are served to no one.
        whole = not rel.startswith("references/") or rel in BUDGETS
        spans = [
            (f, e, t) for t, (lv, f, e, _) in heads.get(rel, {}).items() if lv == 2
        ]
        for num, line in unfenced_lines(path):
            at = f"pointers: {where}/{rel}:{num}"
            groups, loose = pointers_on(line)
            files = [own] if own else []
            for target, titles in groups:
                if target is None and own is None:
                    out.append(
                        f'{at}: "{titles[0]}" needs its file: a playbook has no sections'
                    )
                    continue
                target = target or own
                if target not in heads:
                    out.append(f"{at}: no such file '{target}'")
                    continue
                files.append(target)
                for title in titles:
                    if title.startswith("<"):
                        continue
                    level = heads[target].get(title, (0,))[0]
                    if not level:
                        out.append(f"{at}: '{target}' has no section \"{title}\"")
                    elif level == 1:
                        out.append(
                            f"{at}: \"{title}\" is the whole of '{target}': name a section"
                        )
                    else:
                        home = target if target in targets else f"references/{target}"
                        origin = whole or next(
                            ((rel, t) for f, e, t in spans if f <= num <= e), None
                        )
                        links.append((origin, (home, title), f"{rel}:{num}"))
            for title in loose:
                target = next((f for f in files[::-1] if title in heads[f]), None)
                if target:
                    out.append(
                        f"{at}: \"{title}\" is a section of '{target}' outside a pointer: "
                        f'join it with a comma or write -> "{title}"'
                    )
            for parts, joiner in chains_on(line):
                sizes = []
                for part in parts:
                    known = [
                        heads[name or own][title][3]
                        for name, title in part
                        if not title.startswith("<")
                        and title in heads.get(name or own, ())
                    ]
                    sizes += [max(known)] if known else []
                # refsection.py puts a newline between two sections
                size = sum(sizes) + len(sizes) - 1
                if size > GROUP_CAP:
                    out.append(
                        f'{at}: the pointer that starts with "{parts[0][0][1]}" prints {size} '
                        f"bytes, {size - GROUP_CAP} over the group cap {GROUP_CAP}: split it"
                    )
                if joiner and parts:
                    out.append(
                        f'{at}: the pointer that starts with "{parts[0][0][1]}" ends in '
                        f'"{joiner}": keep a pointer on one line'
                    )
    # An agent starts at SKILL.md, a sub-agent at its playbook, and a playbook is handed over
    # by whoever read SKILL.md or a reference: a file none of them names is never opened.
    entry, callers = set(), set()
    for rel, path in docs.items():
        text = "\n".join(line for _, line in unfenced_lines(path))
        names = set(NAMED_RE.findall(COMMENT_RE.sub("", text)))
        if not rel.startswith("references/"):
            entry |= names
        if not rel.startswith("agents/"):
            callers |= names
    for rel, path in docs.items():
        if rel.startswith("references/") and not {rel, path.name} & entry:
            out.append(
                f"pointers: {where}/{rel}: neither SKILL.md nor a playbook points here"
            )
        if rel.startswith("agents/") and rel not in callers:
            out.append(
                f"pointers: {where}/{rel}: neither SKILL.md nor a reference names this playbook"
            )
    listed = UNROUTED.get(skill.name, {})
    # Reach spreads from what is read whole, one pointer at a time. A listed section is
    # found without a pointer and leads on like a reached one; a section that only points
    # at itself has no way in.
    reached = {}
    served = {True} | {(f"references/{n}", t) for n in listed for t in listed[n]}
    grown = True
    while grown:
        grown = False
        for origin, dest, at in links:
            if origin in served and origin != dest and dest not in reached:
                reached[dest] = at
                served.add(dest)
                grown = True
    for rel in sorted(heads):
        if not rel.startswith("references/") or rel in BUDGETS:
            continue
        titles = listed.get(rel.split("/")[1], set())
        for title, (level, first, *_) in heads[rel].items():
            source = reached.get((rel, title))
            if level != 2:
                if title in titles:
                    out.append(
                        f'pointers: {where}/{rel}:{first}: UNROUTED lists "{title}", '
                        'which is not a "## " section'
                    )
            elif not source and title not in titles:
                out.append(
                    f'pointers: {where}/{rel}:{first}: no pointer reaches section "{title}": '
                    "point to it, or list it in UNROUTED"
                )
            elif source and title in titles:
                out.append(
                    f'pointers: {where}/{rel}:{first}: UNROUTED lists "{title}", '
                    f"which {source} points to"
                )
        for title in sorted(titles - set(heads[rel])):
            out.append(
                f'pointers: {where}/{rel}: UNROUTED lists "{title}", which does not exist'
            )
    for name in sorted(listed):
        rel = f"references/{name}"
        if rel not in docs:
            out.append(
                f"pointers: {where}/{rel}: UNROUTED lists this file, which does not exist"
            )
        elif rel in BUDGETS:
            out.append(
                f"pointers: {where}/{rel}: UNROUTED lists this file, which is read whole: "
                "its sections need no pointer"
            )
    for m in re.finditer(
        r"`?scripts/([A-Za-z0-9_.-]+\.(?:py|sh))`?",
        read(skill / "SKILL.md"),
    ):
        if not (skill / "scripts" / m.group(1)).exists():
            out.append(
                f"pointers: skills/{skill.name}/SKILL.md: script '{m.group(1)}' does not exist"
            )


def tracked_text_files(base=ROOT):
    for path in sorted(base.rglob("*")):
        rel = path.relative_to(ROOT)
        if (
            not path.is_file()
            or rel.parts[0] == ".git"
            or "__pycache__" in rel.parts
            or ".ruff_cache" in rel.parts
        ):
            continue
        if (
            rel.as_posix() in ("LICENSE", "tests/repo/check-skills.py")
            or path.suffix not in TEXT_SUFFIXES
        ):
            continue
        if "fixtures" in rel.parts or (
            rel.parts[:1] == ("evals",) and "files" in rel.parts
        ):
            continue
        yield path, rel.as_posix()


def scan(patterns, label, out, allow=None, skip_context=None, skip_files=()):
    for path, rel in tracked_text_files():
        if rel in skip_files:
            continue
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        for num, line in enumerate(lines, 1):
            for pattern, what in patterns:
                for m in re.finditer(pattern, line, re.IGNORECASE):
                    if any(
                        re.search(a, m.group(0), re.IGNORECASE)
                        for a in (allow or {}).get(rel, [])
                    ):
                        continue
                    if skip_context and skip_context.search(
                        line[max(0, m.start() - 12) : m.end() + 12]
                    ):
                        continue
                    out.append(f"{label}: {rel}:{num}: {what}: '{m.group(0)}'")


def check_credentials(out):
    # contrib/ and the root stay .md-only: the harness deny lists name these forms on purpose
    docs = [path for path, _ in tracked_text_files(SKILLS)]
    docs += [*sorted((ROOT / "contrib").rglob("*.md")), *sorted(ROOT.glob("*.md"))]
    patterns = [(re.compile(p), what) for p, what in CREDENTIAL_PATTERNS]
    for path in docs:
        rel = path.relative_to(ROOT).as_posix()
        for num, line in enumerate(read(path).splitlines(), 1):
            for pattern, what in patterns:
                if m := pattern.search(line):
                    out.append(f"credentials: {rel}:{num}: {what}: '{m.group(0)[:60]}'")


def _text(value):
    return isinstance(value, str) and bool(value.strip())


def _texts(value):
    return isinstance(value, list) and all(map(_text, value))


# What every eval holds today. No CI job runs the evals: a hand edit that breaks one shows here.
EVAL_KEYS = {
    "id": ("an integer", lambda value: type(value) is int),
    "name": ("a non-empty string", _text),
    "prompt": ("a non-empty string", _text),
    "expected_output": ("a non-empty string", _text),
    "files": ("a list of paths", _texts),
    "assertions": (
        "a non-empty list of strings",
        lambda value: bool(value) and _texts(value),
    ),
}


def check_evals(skills, out):
    for path in sorted((ROOT / "evals").glob("*/evals.json")):
        base, rel = path.parent, path.relative_to(ROOT).as_posix()
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except ValueError as error:  # bytes that are not UTF-8 raise one too
            out.append(f"evals: {rel}: not valid JSON: {error}")
            continue
        cases = data.get("evals") if isinstance(data, dict) else None
        if not isinstance(cases, list) or not cases:
            out.append(f"evals: {rel}: must be an object with a non-empty list 'evals'")
            continue
        if data.get("skill_name") != base.name:
            out.append(
                f"evals: {rel}: skill_name {data.get('skill_name')!r} differs from "
                f"directory '{base.name}'"
            )
        if base.name not in skills:
            out.append(f"evals: {rel}: skill '{base.name}' does not exist")
        seen, used = {}, []
        fixtures = base / "files"
        # Not resolved itself: as a link it would make any place the fixture directory.
        inside = base.resolve() / "files"
        for index, case in enumerate(cases):
            at = f"evals: {rel}: evals[{index}]"
            if not isinstance(case, dict):
                out.append(f"{at}: must be an object")
                continue
            for key, (what, valid) in EVAL_KEYS.items():
                value = case.get(key)
                if not valid(value):
                    out.append(f"{at}: '{key}' must be {what}")
                elif key in ("id", "name"):
                    first = seen.setdefault((key, value), index)
                    if first != index:
                        out.append(f"{at}: {key} {value!r} repeats evals[{first}]")
                elif key == "files":
                    for entry in value:
                        # os.path.exists() is false for a path the system refuses, too.
                        if not os.path.exists(base / entry):
                            out.append(f"{at}: 'files' entry '{entry}' does not exist")
                            continue
                        # Resolved, as ".." or a link may lead anywhere from a path below files/.
                        target = (base / entry).resolve()
                        if target.is_relative_to(inside):
                            used.append(target)
                        else:
                            out.append(
                                f"{at}: 'files' entry '{entry}' is outside files/"
                            )
        # A fixture is listed by its directory, by a file in it or by a directory above it.
        for fixture in sorted(fixtures.iterdir()) if fixtures.is_dir() else ():
            if not fixture.is_dir():
                continue
            real = fixture.resolve()
            if not any(p.is_relative_to(real) or real.is_relative_to(p) for p in used):
                out.append(
                    f"evals: {fixture.relative_to(ROOT).as_posix()}: no eval lists this directory"
                )


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--only", action="append")
    given = parser.parse_args(argv).only or [CHECKS]
    only = {name for names in given for name in names.split(",")}
    # A misspelt name would run nothing and report that every check passes.
    if unknown := sorted(only - set(CHECKS.split(","))):
        names = ", ".join(map(repr, unknown))
        print(f"check-skills.py: no such check: {names}", file=sys.stderr)
        return 2
    out = []
    skills = sorted(p for p in SKILLS.iterdir() if (p / "SKILL.md").exists())
    if not skills:
        out.append("frontmatter: skills/: no skill found")
    if (ROOT / "SKILL.md").exists():
        out.append(
            "frontmatter: SKILL.md: a root SKILL.md hides the skills/ directory from installers"
        )
    for skill in skills:
        if "frontmatter" in only:
            check_frontmatter(skill, out)
        if "budget" in only:
            check_budget(skill, out)
        if "pointers" in only:
            check_pointers(skill, out)
    if "pointers" in only:
        for name in sorted(set(UNROUTED) - {skill.name for skill in skills}):
            out.append(
                f"pointers: skills/{name}: UNROUTED lists this skill, which does not exist"
            )
    if "public" in only:
        scan(PUBLIC_PATTERNS, "public", out, allow=PUBLIC_ALLOW)
    if "attribution" in only:
        scan(
            ATTRIBUTION_PATTERNS,
            "attribution",
            out,
            skip_context=ATTRIBUTION_SKIP_CONTEXT,
            skip_files=ATTRIBUTION_ALLOW_FILES,
        )
    if "credentials" in only:
        check_credentials(out)
    if "evals" in only:
        check_evals({skill.name for skill in skills}, out)
    # A finding quotes what it found: text that cannot be encoded must not end the run.
    sys.stdout.reconfigure(errors="backslashreplace")
    print("\n".join(out) if out else "ok - all repository checks pass")
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main())
