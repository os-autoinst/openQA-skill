#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Print one section of a markdown reference (or its outline) so whole files never need loading.
"""Sections are ATX headings ("## Title"); setext underlines are not recognised."""

import difflib
import os
import re
import sys

from _sanitize import ArgumentParser, fence, one_lines, sanitize

SKILL_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
REFERENCES = os.path.join(SKILL_DIR, "references")

_HEADING = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$")
_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")


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
    # The skill's own documents, from any working directory: `-> SKILL.md "<Section>"`
    # pointers, and the per-script flag notes that SKILL.md "Script flags" points at.
    if name in ("SKILL.md", "scripts/README.md"):
        return os.path.join(SKILL_DIR, name)
    if os.sep not in name:
        for candidate in (name, name + ".md"):
            path = os.path.join(REFERENCES, candidate)
            if os.path.isfile(path):
                return path
    return name if os.path.isfile(name) else None


def is_bundled(path):
    return os.path.realpath(path).startswith(SKILL_DIR + os.sep)


def main(argv=None):
    parser = ArgumentParser(
        prog="refsection.py",
        description="Print one or more sections of a markdown file. A section runs from its "
        "heading to the next heading of the same or higher level. Titles match exactly, then "
        "case-insensitively, then as a unique prefix. Files outside the skill are sanitised "
        "and fenced as untrusted data.",
        epilog="exit: 0 ok, 1 section missing or ambiguous, 2 usage or file error",
    )
    parser.add_argument(
        "--list", action="store_true", help="print the outline: bytes, level, title"
    )
    parser.add_argument(
        "file",
        help="bare name looked up in the skill's references/ (.md optional), or a path",
    )
    parser.add_argument(
        "titles", nargs="*", metavar="title", help="section title(s) to print"
    )
    args = parser.parse_args(argv)
    if args.list == bool(args.titles):
        parser.error("give either --list or at least one section title")

    path = resolve(args.file)
    if path is None:
        print(
            one_lines([f"refsection: no such file: {args.file}"]),
            end="",
            file=sys.stderr,
        )
        if os.path.isdir(REFERENCES):
            names = sorted(n for n in os.listdir(REFERENCES) if n.endswith(".md"))
            print(f"references: {' '.join(names) or '(none)'}", file=sys.stderr)
        return 2
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError as error:
        print(
            one_lines([f"refsection: {path}: {error.strerror}"]),
            end="",
            file=sys.stderr,
        )
        return 2

    bundled = is_bundled(path)
    if not bundled:
        text = sanitize(text, max_line=0, max_bytes=0)
    lines = text.split("\n")
    sections = parse(lines)
    shown = os.path.basename(path)

    chunks = []
    problems = []
    if args.list:
        for section in sections:
            size = len(body(lines, section).encode("utf-8"))
            chunks.append(f"{size:6d}  {section.label()}\n")
    for raw in args.titles:
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
            problems.append(f'refsection: no section "{wanted}" in {shown}; closest:')
            problems += [f"  {section.label()}" for section in near]
        else:
            problems.append(f'refsection: no section "{wanted}" in {shown}; try --list')

    output = "".join(chunks) if args.list else "\n".join(chunks)
    if output and not bundled:
        output = fence(sanitize(output), shown)
    sys.stdout.write(output)
    sys.stderr.write(one_lines(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
