# SPDX-License-Identifier: GPL-2.0-or-later
# Which lines of a Markdown text are fenced code: one reading for both repository gates.
import re

# CommonMark: three or more backticks or tildes after at most three spaces. The info string of
# a backtick fence holds no backtick, so a code span that starts a line opens nothing.
_MARK = re.compile(r" {0,3}(`{3,}(?=[^`]*$)|~{3,})(.*)$")


def fenced(lines):
    """Per line: True inside a fenced code block, None for the line that opens or closes it,
    False outside. Only its own marker closes a block: the same character, at least as often,
    alone on its line."""
    opened = None
    for line in lines:
        mark = _MARK.match(line)
        if opened is None:
            opened = mark.group(1) if mark else None
            yield None if mark else False
        elif (
            mark
            and mark.group(1)[0] == opened[0]
            and len(mark.group(1)) >= len(opened)
            and not mark.group(2).strip()
        ):
            opened = None
            yield None
        else:
            yield True
