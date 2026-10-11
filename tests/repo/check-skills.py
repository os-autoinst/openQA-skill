#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Repository gate: frontmatter, byte budgets, pointer resolution, public-content and attribution checks.
"""Usage: check-skills.py [--only frontmatter,budget,pointers,public,attribution,credentials]

Exit 0 when every check passes, 1 otherwise. One line per finding: "<check>: <file>[:<line>]: <message>".
"""

import argparse
import importlib.util
import re
import sys
from pathlib import Path

# The gate imports the skill's own scripts and must leave no cache in the tree it checks.
sys.dont_write_bytecode = True

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
# A "## " section of a reference with its "### " parts: what one pointer makes an agent read.
SECTION_CAP = 5000
# A reference: read whole by mistake, it still fits the 30,000 characters Claude Code returns of
# a command's output by default (BASH_MAX_OUTPUT_LENGTH).
FILE_CAP = 17000
# A playbook, read whole by its sub-agent.
AGENT_CAP = 5000
# Files that are read whole, each capped as the one read it is.
BUDGETS = {
    "SKILL.md": 16700,
    "references/untrusted-content.md": 7900,
}

# Applied only to lines containing "->"; also catches ', other-file.md "Section"' continuations.
POINTER_RE = re.compile(
    r"(?:references/)?([A-Za-z0-9_-]+\.md)((?:\s*,?\s*\"[^\"\n]+\")+)"
)

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


def headings(path):
    out, fenced = [], False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.lstrip().startswith(("```", "~~~")):
            fenced = not fenced
        elif not fenced and (m := re.match(r"^(#{1,6})\s+(.+?)\s*$", line)):
            out.append(m.group(2))
    return out


def frontmatter(path):
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        return None
    block = text[4 : text.index("\n---", 4)]
    data, key = {}, None
    for line in block.splitlines():
        if m := re.match(r"^([A-Za-z-]+):\s*(.*)$", line):
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
    """Yield (title, level, first line, bytes) per heading; bytes are what `refsection.py --list` prints."""
    lines = path.read_text(encoding="utf-8").split("\n")
    for sec in reader.parse(lines):
        size = len(reader.body(lines, sec).encode("utf-8"))
        yield sec.title, sec.level, sec.start + 1, size


def check_budget(skill, out):
    where = f"skills/{skill.name}"
    for path in sorted(skill.rglob("*.md")):
        rel = path.relative_to(skill).as_posix()
        if rel.startswith("scripts/"):
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
        for title, level, first, size in outline(reader, path):
            if level >= 2 and size > SECTION_CAP:
                out.append(
                    f'budget: {where}/references/{path.name}:{first}: section "{title}" is {size} '
                    f"bytes, {size - SECTION_CAP} over the section cap {SECTION_CAP}"
                )


def check_pointers(skill, out):
    heads = {p.name: set(headings(p)) for p in (skill / "references").glob("*.md")}
    heads["SKILL.md"] = set(headings(skill / "SKILL.md"))
    for path in [
        skill / "SKILL.md",
        *sorted((skill / "references").glob("*.md")),
        *sorted((skill / "agents").glob("*.md")),
    ]:
        fenced = False
        for num, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith(("```", "~~~")):
                fenced = not fenced
            if fenced or "->" not in line:
                continue
            for m in POINTER_RE.finditer(line):
                target, sections = m.group(1), re.findall(r'"([^"]+)"', m.group(2))
                rel = f"skills/{skill.name}/{path.relative_to(skill).as_posix()}:{num}"
                if target not in heads:
                    out.append(f"pointers: {rel}: no such file '{target}'")
                    continue
                for sec in sections:
                    if not sec.startswith("<") and sec not in heads[target]:
                        out.append(
                            f"pointers: {rel}: '{target}' has no section \"{sec}\""
                        )
    for m in re.finditer(
        r"`?scripts/([A-Za-z0-9_.-]+\.(?:py|sh))`?",
        (skill / "SKILL.md").read_text(encoding="utf-8"),
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
        for num, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for pattern, what in patterns:
                if m := pattern.search(line):
                    out.append(f"credentials: {rel}:{num}: {what}: '{m.group(0)[:60]}'")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--only", default="frontmatter,budget,pointers,public,attribution,credentials"
    )
    only = set(parser.parse_args(argv).only.split(","))
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
    print("\n".join(out) if out else "ok - all repository checks pass")
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main())
