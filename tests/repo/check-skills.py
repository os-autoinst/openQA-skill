#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Repository gate: frontmatter, byte budgets, pointer resolution, public-content and attribution checks.
"""Usage: check-skills.py [--only frontmatter,budget,pointers,public,attribution]

Exit 0 when every check passes, 1 otherwise. One line per finding: "<check>: <file>[:<line>]: <message>".
"""

import argparse
import re
import sys
from pathlib import Path

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

# Byte caps. SKILL.md is loaded on every trigger; references are read a section at a time.
DEFAULT_REFERENCE_CAP = 15000
BUDGETS = {
    "SKILL.md": 16700,
    "references/untrusted-content.md": 7500,
    "references/site-policy.md": 6500,
    "references/pr-reviewing.md": 7500,
    "references/custom-distri.md": 8000,
    "references/agnostic-tests.md": 9000,
    "references/review-tooling.md": 10500,
    "references/review-comments-tickets.md": 12000,
    "references/needles-gui.md": 13000,
    "references/multimachine.md": 13000,
    "references/contributing-gates.md": 13000,
    "references/area-conventions.md": 13000,
    "references/review-workflow.md": 13000,
    "references/bugs-and-tickets.md": 16000,
    "references/openqa-model.md": 14000,
    "references/clone-and-run.md": 14000,
    "references/distri-helpers.md": 17000,
    "references/module-templates.md": 16000,
}
AGENT_CAP = 5000

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

TEXT_SUFFIXES = {".md", ".py", ".sh", ".json", ".yaml", ".yml", ".txt", ".toml", ""}


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


def check_budget(skill, out):
    for path in sorted(skill.rglob("*.md")):
        rel = path.relative_to(skill).as_posix()
        if rel.startswith("scripts/"):
            continue
        cap = BUDGETS.get(
            rel, AGENT_CAP if rel.startswith("agents/") else DEFAULT_REFERENCE_CAP
        )
        size = path.stat().st_size
        if size > cap:
            out.append(
                f"budget: skills/{skill.name}/{rel}: {size} bytes exceeds cap {cap} by {size - cap}"
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


def tracked_text_files():
    for path in sorted(ROOT.rglob("*")):
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


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--only", default="frontmatter,budget,pointers,public,attribution"
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
    print("\n".join(out) if out else "ok - all repository checks pass")
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main())
