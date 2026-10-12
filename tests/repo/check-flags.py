#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# The skill states every bundled-script flag itself, so an agent never has to run --help.
"""Usage: check-flags.py [--write]

For every skill with scripts/*.py, reads the argparse parser of each script without running the
script's work, and checks:

  index     the "## Script flags" section of scripts/README.md is exactly what the parsers render
            (--write regenerates it); SKILL.md points at it with "->" and has no heading of that
            title; none of this applies to a skill without public scripts
  meaning   every option appears in that script's section of scripts/README.md; only the flags
            every openQA script shares may be explained once in the preamble instead
  citations every "<script>.py ... --flag" in a code span, fenced or indented block of SKILL.md,
            agents/, references/ or scripts/README.md is an option of that script, and every
            scripts/<name>.py mentioned exists
  no-help   none of those documents sends the agent to --help, or to -h next to a script name
  help      every script's --help still exits 0 and prints something, for humans

Exit 0 when all checks pass, 1 otherwise.
"""

import argparse
import contextlib
import io
import re
import runpy
import subprocess
import sys
from pathlib import Path

from _fences import fenced

ROOT = Path(__file__).resolve().parents[2]
HEADING = "## Script flags"
POINTER = 'scripts/README.md "Script flags"'
# refsection.py finds a title at any level, whatever its case, and by prefix.
COPY = re.compile(r"(?i) {0,3}#{1,6}[ \t]+script flags")
SPAN = re.compile(r"`([^`]+)`")
CALL = re.compile(r"(?:\$\s+)?(?:python3\s+)?(?:\S*/)?([A-Za-z_-]+\.py)\b(.*)")
COMMANDS = re.compile(r"&&|\|\||;")
FLAG = re.compile(r"(?<![\w-])(--[a-z][a-z0-9-]+)")
HELP = re.compile(r"(?<![\w-])(?:--help|-h)(?![\w-])")
# The exit-code clause of an epilog: what 1 means, between the 0 and the 2.
EXIT_1 = re.compile(r"(?i)\bexit(?: codes)?:\s*0\b[^,]*,\s*1\s+(.+?),\s*2\b")


class _Parsed(BaseException):
    """Escapes _oqa.run(), which catches Exception, carrying the parser it was raised from."""

    def __init__(self, parser):
        super().__init__()
        self.parser = parser


@contextlib.contextmanager
def isolated(directory):
    """Import a skill's scripts by their bare names, then forget them, so skills never mix."""
    argv, path, modules, stdin = sys.argv, sys.path[:], set(sys.modules), sys.stdin
    sys.path[:0] = [str(directory)]
    sys.stdin = io.StringIO()
    quiet = io.StringIO()
    try:
        with contextlib.redirect_stdout(quiet), contextlib.redirect_stderr(quiet):
            yield
    finally:
        sys.argv, sys.path[:], sys.stdin = argv, path, stdin
        for name in set(sys.modules) - modules:
            del sys.modules[name]


def parser_of(script):
    """(parser, None), taken at the script's parse_args() call before any real work, or
    (None, reason)."""

    def stop(self, *args, **kwargs):
        raise _Parsed(self)

    patched = ("parse_args", "parse_known_args")
    originals = {n: getattr(argparse.ArgumentParser, n) for n in patched}
    for name in patched:
        setattr(argparse.ArgumentParser, name, stop)
    try:
        with isolated(script.parent):
            sys.argv = [script.name]
            runpy.run_path(str(script), run_name="__main__")
    except _Parsed as got:
        return got.parser, None
    except SystemExit:
        pass
    except Exception as error:  # noqa: BLE001 - any failure is a finding, not a crash
        return None, f"importing it raised {type(error).__name__}"
    finally:
        for name, method in originals.items():
            setattr(argparse.ArgumentParser, name, method)
    return None, "no argparse parser reached"


def common_actions(skill):
    """The options _oqa.add_common_args() gives every openQA script, keyed by option string."""
    helper = skill / "scripts" / "_oqa.py"
    if not helper.exists():
        return {}
    with isolated(helper.parent):
        namespace = runpy.run_path(str(helper))
    parser = argparse.ArgumentParser(add_help=False)
    namespace["add_common_args"](parser)
    return {
        o: a
        for a in parser._actions
        if a.option_strings and shown(a)
        for o in a.option_strings
    }


def shown(action):
    return action.help != argparse.SUPPRESS and "-h" not in action.option_strings


def value(action):
    """How the value(s) of an option or positional are written."""
    if action.choices:
        name = "{" + ",".join(map(str, action.choices)) + "}"
    else:
        name = action.metavar or action.dest.upper()
    if isinstance(name, tuple):
        return " ".join(n.upper() for n in name)
    if not action.choices:
        name = str(name).upper()
    if isinstance(action.nargs, int):
        return " ".join([name] * action.nargs)
    return {"?": f"[{name}]", "*": f"[{name}...]", "+": f"{name}..."}.get(
        action.nargs, name
    )


def usage(action):
    """One option or positional; a repeatable option is followed by "...", outside brackets."""
    if not action.option_strings:
        return value(action)
    text = max(action.option_strings, key=len)
    if action.nargs != 0:
        text += " " + value(action)
    return text


def synopsis(name, parser, shared):
    groups = {
        id(action): group
        for group in parser._mutually_exclusive_groups
        for action in group._group_actions
    }
    parts, done = [], set()
    for action in parser._actions:
        if not shown(action) or set(action.option_strings) & shared:
            continue
        repeat = "..." if isinstance(action, argparse._AppendAction) else ""
        group = groups.get(id(action))
        if group is None:
            text = usage(action)
            if action.option_strings and not action.required:
                text = f"[{text}]"
            elif repeat:
                text = f"({text})"
            parts.append(text + repeat)
        elif id(group) not in done:
            done.add(id(group))
            inner = " | ".join(usage(a) for a in group._group_actions if shown(a))
            parts.append(f"({inner})" if group.required else f"[{inner}]")
    line = f"- `{name} {' '.join(parts)}`"
    exit_1 = EXIT_1.search(parser.epilog or "")
    has_exit_code = any("--exit-code" in a.option_strings for a in parser._actions)
    if exit_1 and not has_exit_code:
        line += f"; exit 1: {' '.join(exit_1.group(1).split())}"
    return line


def uses_common(parser, common):
    """The script got these options from _oqa.add_common_args(), not its own look-alike."""
    mine = {o: a for a in parser._actions for o in a.option_strings}
    return bool(common) and all(
        o in mine and mine[o].help == a.help for o, a in common.items()
    )


def render(parsers, common, has_refsection):
    """The body of the "Script flags" section for the public scripts."""
    public = {n: p for n, p in sorted(parsers.items()) if not n.startswith("_")}
    where = "that script's section below"
    if has_refsection:
        where = '`python3 scripts/refsection.py scripts/README.md "<script>"`'
    intro = "One line per script, generated from the parsers: do not edit it by hand."
    lines = ["", f"{intro} What a flag means: {where}.", ""]
    users = [n for n, p in public.items() if uses_common(p, common)]
    if users:
        flags = ", ".join(f"`{usage(a)}`" for a in dict.fromkeys(common.values()))
        lines.append(f"- {flags} on {', '.join(users)}")
    lines += [
        synopsis(n, p, set(common) if n in users else set()) for n, p in public.items()
    ]
    return "\n".join(lines) + "\n\n"


def section_span(text, heading):
    """Start and end offsets of the body under a "## " heading, or None."""
    match = re.search(rf"^{re.escape(heading)}[ \t]*\n", text, re.MULTILINE)
    if not match:
        return None
    following = re.search(r"^## ", text[match.end() :], re.MULTILINE)
    end = match.end() + following.start() if following else len(text)
    return match.end(), end


def copy_line(text):
    """Line of a heading that refsection.py would print as "Script flags", or None."""
    lines = text.splitlines()
    for num, (line, inside) in enumerate(zip(lines, fenced(lines)), 1):
        if inside is False and COPY.match(line):
            return num
    return None


def readme_sections(text):
    """(preamble, {script name: section text}) of a scripts/README.md."""
    chunks = re.split(r"^## ", text, flags=re.MULTILINE)
    sections = {}
    for chunk in chunks[1:]:
        title = chunk.split("\n", 1)[0].split(" - ", 1)[0]
        for name in re.findall(r"[\w-]+\.py", title):
            sections[name] = chunk
    return chunks[0], sections


def mentions(text, option):
    return re.search(rf"(?<![\w-]){re.escape(option)}(?![\w-])", text) is not None


def code_lines(text):
    """(line number, line, code pieces): code spans, and whole fenced or indented lines."""
    lines = text.splitlines()
    for num, (line, inside) in enumerate(zip(lines, fenced(lines)), 1):
        if inside is None:
            continue
        whole = inside or line.startswith(("    ", "\t"))
        yield num, line, [line.strip()] if whole else SPAN.findall(line)


def read(path):
    """The text; a byte that is not UTF-8 stays what it is, so that --write hands it back."""
    return path.read_text(encoding="utf-8", errors="surrogateescape")


def check_skill(skill, write, problems):
    def rel(path):
        return path.relative_to(ROOT).as_posix()

    scripts = {p.name: p for p in sorted((skill / "scripts").glob("*.py"))}
    parsers = {}
    for name, path in scripts.items():
        parser, reason = parser_of(path)
        if parser is None:
            problems.append(f"help: {rel(path)}: {reason}")
        else:
            parsers[name] = parser
        done = subprocess.run(
            [sys.executable, str(path), "--help"],
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=60,
            check=False,
        )
        if done.returncode != 0 or not done.stdout.strip():
            problems.append(
                f"help: {rel(path)}: --help exited {done.returncode} "
                f"and printed {len(done.stdout)} bytes"
            )

    # index
    skill_md = skill / "SKILL.md"
    readme = skill / "scripts" / "README.md"
    text = read(skill_md)
    notes = read(readme) if readme.is_file() else ""
    common = common_actions(skill)
    if any(not n.startswith("_") for n in scripts):
        copy = copy_line(text)
        if copy:
            problems.append(
                f'index: {rel(skill_md)}:{copy}: "{HEADING}" belongs in scripts/README.md'
            )
        span = section_span(notes, HEADING)
        if span is None:
            problems.append(f'index: {rel(readme)}: no "{HEADING}" section')
        else:
            wanted = render(parsers, common, "refsection.py" in scripts)
            if notes[span[0] : span[1]] != wanted:
                if write:
                    notes = notes[: span[0]] + wanted + notes[span[1] :]
                    readme.write_text(notes, encoding="utf-8", errors="surrogateescape")
                else:
                    problems.append(
                        f'index: {rel(readme)}: "{HEADING}" does not match the parsers; '
                        "run python3 tests/repo/check-flags.py --write"
                    )
        if f"-> {POINTER}" not in text:
            problems.append(f"index: {rel(skill_md)}: no pointer -> {POINTER}")

    # meaning
    preamble, sections = readme_sections(notes)
    for name, parser in parsers.items():
        for action in parser._actions:
            if not (action.option_strings and shown(action)):
                continue
            where = sections.get(name, "")
            if set(action.option_strings) & set(common) and uses_common(parser, common):
                where += preamble
            if not any(mentions(where, o) for o in action.option_strings):
                problems.append(
                    f"meaning: {rel(readme)}: {name} "
                    f"{max(action.option_strings, key=len)} is not described"
                )

    # citations and no-help
    options = {
        n: {o for a in p._actions for o in a.option_strings} for n, p in parsers.items()
    }
    docs = [skill_md, readme]
    docs += sorted((skill / "agents").glob("*.md"))
    docs += sorted((skill / "references").glob("*.md"))
    checked = 0
    for doc in (d for d in docs if d.is_file()):
        text = read(doc)
        if bad := re.search("[\udc80-\udcff]", text):
            line = text.count("\n", 0, bad.start()) + 1
            problems.append(f"citations: {rel(doc)}:{line}: not valid UTF-8")
        for name in set(re.findall(r"scripts/([A-Za-z_-]+\.py)", text)) - set(scripts):
            problems.append(f"citations: {rel(doc)}: mentions missing script {name}")
        for num, line, pieces in code_lines(text):
            named = [
                n for n in scripts if re.search(rf"(?<![\w-]){re.escape(n)}\b", line)
            ]
            if (named and HELP.search(line)) or "`--help`" in line:
                problems.append(
                    f"no-help: {rel(doc)}:{num}: sends the agent to --help; "
                    f"point at {POINTER} instead"
                )
            for piece in pieces:
                for command in COMMANDS.split(piece):
                    call = CALL.match(command.strip())
                    if not call or call.group(1) not in options:
                        continue
                    for flag in FLAG.findall(call.group(2)):
                        checked += 1
                        if flag not in options[call.group(1)]:
                            problems.append(
                                f"citations: {rel(doc)}:{num}: "
                                f"{call.group(1)} has no {flag}"
                            )
    return checked


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Check that the skills state every bundled-script flag correctly."
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help='regenerate the "Script flags" section of each scripts/README.md',
    )
    args = parser.parse_args(argv)
    problems, checked = [], 0
    for skill in sorted(
        p for p in (ROOT / "skills").iterdir() if (p / "SKILL.md").exists()
    ):
        checked += check_skill(skill, args.write, problems)
    print(
        "\n".join(problems)
        if problems
        else f"ok - flag index matches the parsers, {checked} citations checked"
    )
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
