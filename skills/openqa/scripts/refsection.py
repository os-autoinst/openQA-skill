#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Print one section of a markdown reference (or its outline) so whole files never need loading.
"""Sections are ATX headings ("## Title"); setext underlines are not recognised."""

import difflib
import os
import re
import sys

# python3 -I leaves the script's own directory off sys.path; the sibling modules live there.
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from _sanitize import ArgumentParser, fence, one_lines, sanitize

SKILL_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
REFERENCES = os.path.join(SKILL_DIR, "references")

_HEADING = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$")
_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
_TITLE_HINT = "; a title that ends in .md needs a leading #"


class Section:
    def __init__(self, level, title, start):
        self.level = level
        self.title = title
        self.start = start
        self.end = None

    def label(self):
        return f"{'#' * self.level} {self.title}"


def parse(lines):
    sections = []
    open_fence = None
    start = 0
    if lines and lines[0].strip() == "---":
        closing = [i for i, line in enumerate(lines[1:], 1) if line.strip() == "---"]
        start = closing[0] + 1 if closing else 0
    for index in range(start, len(lines)):
        line = lines[index]
        marker = _FENCE.match(line)
        if open_fence:
            if (
                marker
                and marker.group(1)[0] == open_fence[0]
                and len(marker.group(1)) >= len(open_fence)
                and not marker.group(2).strip()
            ):
                open_fence = None
            continue
        if marker:
            open_fence = marker.group(1)
            continue
        heading = _HEADING.match(line)
        if heading and heading.group(2):
            sections.append(Section(len(heading.group(1)), heading.group(2), index))
    for position, section in enumerate(sections):
        section.end = len(lines)
        for later in sections[position + 1 :]:
            if later.level <= section.level:
                section.end = later.start
                break
    return sections


def body(lines, section):
    return "\n".join(lines[section.start : section.end]).rstrip() + "\n"


def find(sections, wanted):
    """Return the matches from the first strategy that yields any."""
    folded = wanted.casefold()
    strategies = (
        lambda title: title == wanted,
        lambda title: title.casefold() == folded,
        lambda title: title.casefold().startswith(folded),
    )
    for matches in strategies:
        hits = [section for section in sections if matches(section.title)]
        if hits:
            return hits
    return []


def closest(sections, wanted, limit=5):
    folded = wanted.casefold()
    by_title = {}
    for section in sections:
        by_title.setdefault(section.title.casefold(), section)
    names = [name for name in by_title if folded in name]
    names += difflib.get_close_matches(folded, list(by_title), n=limit, cutoff=0.5)
    return [by_title[name] for name in dict.fromkeys(names)][:limit]


def resolve(name):
    # The skill's own documents, from any working directory: `-> SKILL.md "<Section>"`, the
    # per-script notes in scripts/README.md, and `references/<file>.md` as references spell it.
    if name in ("SKILL.md", "scripts/README.md"):
        return os.path.join(SKILL_DIR, name)
    bare = name.removeprefix("references/")
    if os.sep not in bare:
        for candidate in (bare, bare + ".md"):
            path = os.path.join(REFERENCES, candidate)
            if os.path.isfile(path):
                return path
    return name if os.path.isfile(name) else None


def is_bundled(path):
    return os.path.realpath(path).startswith(SKILL_DIR + os.sep)


def lost_suffix(title):
    """True if the title names a document of the skill once .md is appended."""
    path = resolve(title + ".md")
    return path is not None and is_bundled(path)


def split(first, rest):
    """[(file, [titles])]: after the first argument, one ending in .md names the next file."""
    groups = [(first, [])]
    for raw in rest:
        name = raw.strip()
        if name.endswith(".md") and not name.startswith("#"):
            groups.append((name, []))
        else:
            groups[-1][1].append(raw)
    return groups


def main(argv=None):
    parser = ArgumentParser(
        prog="refsection.py",
        description="Print one or more sections of a markdown file. A section runs from its "
        "heading to the next heading of the same or higher level. Titles match exactly, then "
        "case-insensitively, then as a unique prefix. A later argument ending in .md switches "
        "to that document of the skill, so a chained pointer is one argument list; a leading # "
        "forces a title. Files outside the skill are sanitised and fenced as untrusted data.",
        epilog="exit: 0 ok, 1 section missing or ambiguous, 2 usage or file error",
    )
    parser.add_argument(
        "--list", action="store_true", help="print the outline: bytes, level, title"
    )
    parser.add_argument(
        "file",
        help="name looked up in the skill's references/ (.md and a references/ prefix "
        "optional), or a path",
    )
    parser.add_argument(
        "titles",
        nargs="*",
        metavar="title",
        help="section title(s) to print; an argument ending in .md names the next file",
    )
    args = parser.parse_args(argv)
    groups = split(args.file, args.titles)
    if args.list and len(groups) > 1:
        parser.error("--list takes one file")
    if args.list == bool(args.titles):
        parser.error("give either --list or at least one section title")

    blocks = []
    errors = []
    status = 0
    missing = False
    for position, (name, titles) in enumerate(groups):
        # A later name without titles may have been meant as a title of the file before it.
        hint = _TITLE_HINT if position and not titles else ""
        path = resolve(name)
        if path is None:
            errors.append(f"refsection: no such file: {name}{hint}")
            missing = True
            status = 2
            continue
        bundled = is_bundled(path)
        shown = os.path.basename(path)
        if position and not bundled:
            # A mistyped link of a chain must not fall through to a file under the cwd.
            errors.append(
                f"refsection: not a document of the skill: {name}; "
                f"a file outside the skill must be the first argument{hint}"
            )
            status = 2
            continue
        if not titles and not args.list:
            errors.append(f"refsection: no title given for {shown}{_TITLE_HINT}")
            status = 2
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as error:
            errors.append(f"refsection: {path}: {error.strerror}")
            status = 2
            continue

        if not bundled:
            text = sanitize(text, max_line=0, max_bytes=0)
        lines = text.split("\n")
        sections = parse(lines)

        chunks = []
        problems = []
        if args.list:
            for section in sections:
                size = len(body(lines, section).encode("utf-8"))
                chunks.append(f"{size:6d}  {section.label()}\n")
        for raw in titles:
            wanted = raw.strip().lstrip("#").strip()
            hits = find(sections, wanted)
            if len(hits) == 1:
                chunks.append(body(lines, hits[0]))
                continue
            if hits:
                problems.append(f'refsection: "{wanted}" is ambiguous in {shown}:')
                problems += [f"  {hit.label()} (line {hit.start + 1})" for hit in hits]
                continue
            near = closest(sections, wanted)
            if near:
                problems.append(
                    f'refsection: no section "{wanted}" in {shown}; closest:'
                )
                problems += [f"  {section.label()}" for section in near]
            else:
                problems.append(
                    f'refsection: no section "{wanted}" in {shown}; try --list'
                )
            if lost_suffix(wanted):
                problems.append(
                    f"refsection: a later file needs its .md suffix: {wanted}.md"
                )
        if problems:
            errors += problems
            status = max(status, 1)

        output = "".join(chunks) if args.list else "\n".join(chunks)
        if output and not bundled:
            output = fence(sanitize(output), shown)
        if output:
            blocks.append(output)

    sys.stdout.write("\n".join(blocks))
    # One call, so the cap on the number of lines holds for the whole run.
    sys.stderr.write(one_lines(errors))
    if missing and os.path.isdir(REFERENCES):
        names = sorted(n for n in os.listdir(REFERENCES) if n.endswith(".md"))
        sys.stderr.write(f"references: {' '.join(names) or '(none)'}\n")
    return status


if __name__ == "__main__":
    sys.exit(main())
