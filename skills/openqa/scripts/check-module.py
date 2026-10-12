#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Lint os-autoinst-distri-opensuse test modules offline for the traps CI, the engine and reviewers catch.
"""One line per finding: <file>:<line>: <id> <message> -> <fix>

Rule classes: "ci" ports a grep gate of the distri (Makefile, tools/check_*, t/01_style.t),
"engine" is a die in os-autoinst, "review" is a documented coding rule reviewers ask for.
Line based: calls split over several lines are not inspected.
"""

import bisect
import os
import re
import sys

from _sanitize import ArgumentParser, one_lines

RULES = {}
ORDER = []


def rule(ident, kind, scope, summary):
    def register(function):
        RULES[ident] = (kind, scope, summary, function)
        ORDER.append(ident)
        return function

    return register


def _string(quote):
    return rf"{quote}(?:[^{quote}\\]|\\.)*({quote})?"


# A string that never closes is matched to the end of the line: a failed match would restart at each later quote.
_STRINGS = {
    kinds: re.compile("|".join(map(_string, kinds))) for kinds in ("\"'", '"', "'")
}


def _empty_strings(text, kinds="\"'"):
    """text with "" for each string literal that starts with one of the quote kinds."""

    def empty(string):
        if string.lastindex:
            return '""'
        # No quote of this kind closes behind an open one, the other kind still can.
        quote, rest = string.group()[0], string.group()[1:]
        return quote + _empty_strings(rest, kinds.replace(quote, ""))

    return _STRINGS[kinds].sub(empty, text) if kinds else text


class Module:
    def __init__(self, path, text):
        self.path = path
        parts = os.path.normpath(path).split(os.sep)
        self.python = path.endswith(".py")
        # The nearest "lib" or "tests" directory decides; anything else is a test module.
        nearest = [part for part in parts[:-1] if part in ("lib", "tests")]
        self.is_test = not nearest or nearest[-1] == "tests"
        self.arch_helper = path.endswith(
            ("lib/Utils/Architectures.pm", "lib/Utils/Backends.pm")
        )
        self.raw = text.split("\n")
        self.code = [self._code(line) for line in self._without_pod()]

    def _without_pod(self):
        """Blank POD, here-document bodies and everything after __END__ (Perl only)."""
        if self.python:
            return self.raw
        # Looked up per tag: reading on to the closing line would read a file of open tags once per tag.
        where = {}
        for index, line in enumerate(self.raw):
            where.setdefault(line.strip(), []).append(index)
        lines = []
        in_pod = ended = False
        heredoc_end = 0
        for index, line in enumerate(self.raw):
            if index < heredoc_end:
                lines.append("")
                continue
            if re.match(r"^__(END|DATA)__\s*$", line):
                ended = True
            elif re.match(r"^=cut\b", line):
                in_pod = False
                line = ""
            elif re.match(r"^=[a-zA-Z]", line):
                in_pod = True
            lines.append("" if in_pod or ended else line)
            tag = re.search(r"""(?<!<)<<~?(["']?)([A-Za-z_]\w*)\1""", lines[-1])
            if tag:
                closing = where.get(tag.group(2), [])
                later = bisect.bisect(closing, index)
                heredoc_end = closing[later] + 1 if later < len(closing) else 0
        return lines

    @staticmethod
    def _code(line):
        """Empty the string literals, then drop the comment."""
        return re.sub(r"(^|\s)#.*$", "", _empty_strings(line))

    def grep(self, pattern, lines=None):
        regex = re.compile(pattern)
        source = self.raw if lines is None else lines
        return [number for number, line in enumerate(source, 1) if regex.search(line)]


# --- ci: tools/check_metadata, t/01_style.t --------------------------------------------


def _header(module, pattern):
    return [] if module.grep(pattern) else [1]


@rule("header-copyright", "ci", "test", "tools/check_metadata: '# Copyright .+'")
def header_copyright(module):
    return _header(module, r"# Copyright .+"), (
        "no '# Copyright ...' line",
        "add '# Copyright SUSE LLC' (no year in new files)",
    )


@rule("header-summary", "ci", "test", "tools/check_metadata: '# Summary: .+'")
def header_summary(module):
    return _header(module, r"# Summary: .+"), (
        "no '# Summary: <text>' line",
        "add '# Summary: <what the module verifies>'",
    )


@rule(
    "header-maintainer",
    "ci",
    "test",
    "tools/check_metadata: '# Maintainer: .+(@| at ).+'",
)
def header_maintainer(module):
    # Tried behind the first '# Maintainer: ' only: a later one has less of the line left.
    found = any(
        re.match(r".+(@| at ).+", line.partition("# Maintainer: ")[2])
        for line in module.raw
    )
    return [] if found else [1], (
        "no '# Maintainer:' line with an address",
        "add '# Maintainer: <team> <address@...>' in the owning team's spelling",
    )


@rule("copyright-sign", "ci", "all", "t/01_style.t: no 'Copyright (C)', '(c)' or sign")
def copyright_sign(module):
    return module.grep(r"Copyright (\(C\)|\(c\)|©)"), (
        "redundant copyright character",
        "write 'Copyright SUSE LLC'",
    )


@rule("licence-text", "ci", "all", "t/01_style.t: no verbatim GPL text")
def licence_text(module):
    return module.grep(r"This program is free software")[:1], (
        "verbatim licence text",
        "replace the block with '# SPDX-License-Identifier: FSFAP' (or the team's identifier)",
    )


@rule(
    "spdx-colon", "ci", "all", "t/01_style.t: 'SPDX-License-Identifier' needs a colon"
)
def spdx_colon(module):
    # The '[#/ ]*' that leads the CI pattern matches nothing more and rescans each run of spaces.
    return module.grep(r"SPDX-License-Identifier "), (
        "SPDX-License-Identifier is not followed by ':'",
        "write 'SPDX-License-Identifier: <id>'",
    )


@rule("use-strict", "ci", "test-perl", "t/01_style.t: no use strict/warnings in tests/")
def use_strict(module):
    return module.grep(r"use (strict|warnings);"), (
        "redundant in a test module, the base class enables it",
        "delete the line",
    )


@rule(
    "use-base",
    "ci",
    "test-perl",
    "check-strict job: os-autoinst-testmodules-strict rewrites 'use base|parent'",
)
def use_base(module):
    if module.grep(r"^## no os-autoinst style"):
        return [], None
    return module.grep(r"^\s*use (base|parent)\b", module.code), (
        "the check-strict job rewrites this and fails on the diff",
        "use Mojo::Base '<baseclass>';",
    )


@rule("no-base", "ci", "test-perl", "check-strict job: dies with 'No base statements'")
def no_base(module):
    if module.grep(r"^## no os-autoinst style") or module.grep(
        r"^\s*use (base|parent|Mojo::Base)\b", module.code
    ):
        return [], None
    return [1], (
        "no base class statement",
        "add use Mojo::Base 'consoletest'; (or the base class that fits)",
    )


@rule(
    "check-var-arch", "ci", "all", "t/01_style.t: no check_var('ARCH'|'BACKEND', ...)"
)
def check_var_arch(module):
    if module.arch_helper:
        return [], None
    return module.grep(r"""check_var\(\s*['"](ARCH|BACKEND)['"]\s*,"""), (
        "check_var on ARCH/BACKEND",
        "use Utils::Architectures is_<arch> / Utils::Backends is_<backend>; add the helper if missing",
    )


@rule("egrep-fgrep", "ci", "all", "t/01_style.t: no egrep/fgrep, comments included")
def egrep_fgrep(module):
    return module.grep(r"egrep|fgrep"), (
        "deprecated egrep/fgrep",
        "grep -E / grep -F",
    )


# --- ci: Makefile and tools/check_* grep gates -------------------------------------------


@rule("wait-idle", "ci", "all", "Makefile test-no-wait_idle: string must not appear")
def wait_idle(module):
    return module.grep(r"wait_idle"), (
        "wait_idle is banned, comments included",
        "assert_screen on the expected state, or wait_still_screen",
    )


def _ci_check_screen(line):
    """'check_screen.*00(?!.*nocheck:)', which as a regex rescans the line from every call and every '00'."""
    call = line.find("check_screen")
    last = max(call + len("check_screen"), line.rfind("nocheck:"))
    return call >= 0 and "00" in line[last:]


@rule(
    "check-screen-timeout",
    "ci",
    "all",
    "tools/check_code_style: 'check_screen.*00(?!.*nocheck:)'",
)
def check_screen_timeout(module):
    lines = [
        number
        for number in module.grep("check_screen")
        if _ci_check_screen(module.raw[number - 1])
    ]
    return lines, (
        "check_screen with a timeout that CI rejects ('check_screen.*00')",
        "assert_screen([qw(tag-a tag-b)], <timeout>) then branch with match_has_tag",
    )


@rule(
    "soft-failure-reference",
    "ci",
    "all",
    "Makefile test-soft_failure-no-reference: reference on the same line",
)
def soft_failure_reference(module):
    # The Makefile's pattern, with the dots of the host escaped.
    accepted = re.compile(
        r"(^use |[a-zA-Z]#[a-zA-Z-]*[0-9]|fate\.suse\.com/[0-9]+|\$(reference|bsc))"
    )
    # 'record_soft_failure\b.*;' of the Makefile: the call is in front of the last ';'.
    ended = [line[: line.rfind(";") + 1] for line in module.raw]
    hits = [
        number
        for number in module.grep(r"record_soft_failure\b", ended)
        if not accepted.search(module.raw[number - 1])
    ]
    return hits, (
        "record_soft_failure without a reference on the same line",
        (
            "start the text with bsc#N / boo#N / poo#N / jsc#KEY-N / gh#org/repo#N; "
            "without a ticket use record_info(..., result => 'softfail')"
        ),
    )


@rule("loadtest-pm", "ci", "all", "tools/check_invalid_syntax: loadtest with '.pm'")
def loadtest_pm(module):
    return module.grep(r"""\sloadtest\s?\(?(?:"|')?[\w/]+\.pm(?:"|'),?.*\)?"""), (
        "loadtest with a .pm extension",
        "drop the extension: loadtest '<dir>/<name>' (only .py is spelled out)",
    )


@rule("is-leap-major", "ci", "all", "tools/check_invalid_syntax: is_leap('15')")
def is_leap_major(module):
    return module.grep(r"""is_leap[(\s]("|')\d{2}(?!\.\d)\1"""), (
        "is_leap with a major version only",
        "give major.minor with an operator, e.g. is_leap('<15.6') or is_leap('16.0+')",
    )


# --- engine: die at run time -------------------------------------------------------------


@rule(
    "script-run-background",
    "engine",
    "perl",
    "distribution.pm script_run dies on a trailing '&'",
)
def script_run_background(module):
    no_wait = re.compile(r",\s*(timeout\s*=>\s*)?0\s*(?:\)\s*)?;")
    hits = [
        number
        for number in module.grep(
            r"""\b(assert_)?script_run\s*(?:\(\s*)?(["'])(?:(?!\2).)*(?<!\\)&\2\s*[,);]"""
        )
        if not no_wait.search(module.raw[number - 1])
    ]
    return hits, (
        "command ends in '&', script_run dies unless the timeout is 0",
        "background_script_run('<cmd> >/dev/null 2>&1') returns the PID",
    )


@rule(
    "click-positional-timeout",
    "engine",
    "perl",
    "testapi assert_and_click/assert_and_dclick/click_lastmatch take named arguments only",
)
def click_positional_timeout(module):
    # A call takes the text up to its ',' or ';' with it, timeout or not, so that a later call does not rescan it.
    click = re.compile(r"\bassert_and_d?click[^,;]+(,\s*\d+\s*(?:\)\s*)?;)?")
    lastmatch = re.compile(r"\bclick_lastmatch\s*(?:\(\s*)?\d+\s*(?:\)\s*)?;")
    lines = [
        number
        for number in module.grep("click", module.code)
        if lastmatch.search(module.code[number - 1])
        or any(call.group(1) for call in click.finditer(module.code[number - 1]))
    ]
    return lines, (
        "positional timeout, the signature takes key => value pairs only",
        "timeout => <seconds>",
    )


# --- review: CONTRIBUTING.md coding style and recurring review requests ------------------


@rule("sleep", "review", "all", "CONTRIBUTING.md 'Avoid sleep()'")
def sleep(module):
    pattern = (
        r"\btime\.sleep\s*\(" if module.python else r"(?<![\w$@%>:-])sleep\s*[($\d+]"
    )
    return module.grep(pattern, module.code), (
        "sleep instead of synchronisation (CONTRIBUTING.md allows it in very limited cases only)",
        (
            "script_retry(cmd, retry => N, delay => S), validate_script_output_retry, wait_serial "
            "or assert_screen"
        ),
    )


def _call_with(line, call, argument):
    """Both matches in the leftmost statement closed by ';' where argument follows the first call.

    The regex '<call>[^;]*?<argument>[^;]*;' finds the same and rescans the statement from every later call.
    """
    for statement in line.split(";")[:-1]:
        first = call.search(statement)
        found = first and argument.search(statement, first.end())
        if found:
            return first, found
    return None


_SCREEN_CALL = re.compile(r"\bcheck_screen\b")
_SCREEN_WAIT = re.compile(r",\s*(timeout\s*=>\s*)?[1-9]")


@rule(
    "check-screen-wait",
    "review",
    "perl",
    "CONTRIBUTING.md: no check_screen with a non-zero timeout",
)
def check_screen_wait(module):
    hits = [
        number
        for number in module.grep(_SCREEN_CALL, module.code)
        if _call_with(module.code[number - 1], _SCREEN_CALL, _SCREEN_WAIT)
        and not _ci_check_screen(module.raw[number - 1])
        and "nocheck:" not in module.raw[number - 1]
    ]
    return hits, (
        "check_screen with a non-zero timeout makes the run timing dependent",
        "assert_screen([qw(tag-a tag-b)]) then branch with match_has_tag; check_screen(<tag>, 0) for a probe",
    )


@rule(
    "raw-zypper",
    "review",
    "all",
    "zypper through script_run: no retry, no exit-code handling, breaks on transactional systems",
)
def raw_zypper(module):
    verbs = "in|install|rm|remove|up|update|dup|patch|ar|addrepo|rr|removerepo|mr|modifyrepo|ref|refresh"
    hits = [
        number
        for number in module.grep(
            rf"""^\s*(assert_script_run|script_run|assert_script_sudo|script_sudo)\s*(?:\(\s*)?["'](sudo )?zypper (-\S+ )*({verbs}) """
        )
        if not re.search(r"\|\s*grep", module.raw[number - 1])
    ]
    return hits, (
        "zypper run as a plain command",
        (
            "install_package / uninstall_package('<pkgs>', trup_apply => 1 | trup_reboot => 1) from package_utils, "
            "zypper_call('<cmd>') for repositories and updates"
        ),
    )


@rule(
    "zypper-call-noninteractive",
    "review",
    "all",
    "zypper_call already runs 'zypper -n'",
)
def zypper_call_noninteractive(module):
    return module.grep(
        r"""\bzypper_call\s*(?:\(\s*)?["'](-n |--non-interactive |(?:[^"']* )?(-y|--no-confirm)[ "'])"""
    ), (
        "-n/-y passed to zypper_call, which already runs 'zypper -n'",
        "drop the option",
    )


@rule(
    "type-string-newline", "review", "perl", 'enter_cmd replaces type_string "...\\n"'
)
def type_string_newline(module):
    return module.grep(r'\btype_string\s*(?:\(\s*)?"(?:[^"\\]|\\.)*\\n"\s*[,);]'), (
        "type_string with a trailing newline",
        'enter_cmd "<cmd>"; or assert_script_run when the exit code matters',
    )


DEFAULT_TIMEOUTS = {
    "assert_script_run": 90,
    "script_run": 30,
    "script_output": 90,
    "validate_script_output": 90,
    "wait_serial": 90,
    "assert_screen": 30,
    "assert_and_click": 30,
    "wait_still_screen": 30,
    "script_retry": 30,
    "zypper_call": 700,
}
_TIMEOUT_CALL = re.compile(r"\b({})\b(?!\s*=>)".format("|".join(DEFAULT_TIMEOUTS)))
_TIMEOUT = re.compile(r"\btimeout\s*=>\s*(\d+)")


@rule("default-timeout", "review", "perl", "timeout equal to the function's default")
def default_timeout(module):
    hits = []
    for number in module.grep(_TIMEOUT, module.code):
        match = _call_with(module.code[number - 1], _TIMEOUT_CALL, _TIMEOUT)
        if not match:
            continue
        call, timeout = match
        # As text: int() refuses more than 4,300 digits.
        if timeout.group(1).lstrip("0") == str(DEFAULT_TIMEOUTS[call.group(1)]):
            hits.append(number)
    return hits, ("timeout equals the default", "drop the timeout argument")


# Adjacent parts share no character, or a run of backslashes or spaces makes the match backtrack.
_CHAIN_CALL = re.compile(
    r"""^\s*assert_script_run\s*(?:\(\s*)?(["'])((?:\\.|(?!\1)[^\\])*)\1"""
)
# A literal that never closes takes the rest of the line: tried again at each later quote, it reads the line per quote.
_PERL_TOKEN = re.compile(
    r"""(?P<text>(?P<quote>["'])(?:\\.|(?!(?P=quote))[^\\])*(?P=quote))|(?P<open>[(\[{])|(?P<close>[)\]}])"""
    r"""|(?P<dot>\.)|(?P<blank>\s+)|(?P<word>[\w$@%:>-]+)|(?P<rest>["'].*|.)"""
)
_SHELL_QUOTED = re.compile(r"""'[^']*'|"[^"]*"|`[^`]*`""")
# $? and PIPESTATUS settle the status; a compound command, a here-document, errexit and pipefail are skipped.
# A keyword or set starts a command, behind 'time' or '!' at most: the 'for' of 'echo wait for it' is an argument.
# A here-document has its tag behind '<<', be it \"EOF\" or a Perl variable: '<<<' and '$((1<<4))' have none.
_SHELL_CHECKED = re.compile(
    r"""(?:^|[;|&("'`]|\{\s)\s*(?:time\s+(?:-p\s+)?)?(?:!\s+)?"""
    r"""(?:(?:for|while|until|if|case)[\s(]|set\s+-\w*(?:e|o\s+(?:errexit|pipefail)\b))"""
    r"""|\$\?|\bPIPESTATUS\b|(?<!<)<<[-~]?\s*["'\\]{0,2}[A-Za-z_$]"""
)
_STATUS_TEST = re.compile(r"(?:(?:test|\[\[?)\s[^|&]*|true)$")
# An exit code that says nothing: clear, cd to the home directory, an echo that writes no file, an assignment.
_NO_STATUS = re.compile(r"(?:clear|cd(?:\s+~)?|echo(?:\s[^|&<>]*)?)$")
# A test in front of an assignment is its condition: 1 is no failure, and '&&' in place of the next ';' would stop there.
_ASSIGNMENT = re.compile(
    r"(?:(?:test|\[\[?)\s[^|&]*&&\s*)?(?:(?:export\s+)?\w+=[^\s|&<>]*|export\s+\w+)$"
)


def _command(line, call):
    """The first literal of the call and each literal that '.' joins to it, with '_' for a term in between."""
    parts, depth, state = [call.group(2)], 0, "operand"
    for token in _PERL_TOKEN.finditer(line, call.end()):
        kind = token.lastgroup
        if depth:
            depth += (kind == "open") - (kind == "close")
        elif kind == "blank":
            state = "operand" if state == "term" else state
        elif kind == "dot" and state != "dot":
            state = "dot"
        elif kind == "text" and state == "dot":
            parts.append(token.group()[1:-1])
            state = "operand"
        elif kind in ("word", "open") and state != "operand":
            if state == "dot":
                parts.append("_")
            state, depth = "term", int(kind == "open")
        else:
            # A ',' starts the next argument, a word such as 'if' or 'x' what is no part of the command.
            break
    return "".join(parts)


def _shell_checked(command):
    """Whether _SHELL_CHECKED matches anywhere but behind the quote that closes a quoted text."""
    closing = {quoted.end() - 1 for quoted in _SHELL_QUOTED.finditer(command)}
    return any(
        found.start() not in closing for found in _SHELL_CHECKED.finditer(command)
    )


def _top_level(command):
    """The command without escaped ';', with '_' for each quoted text and each ( ) or { } group."""
    depth, kept = 0, []
    for char in _SHELL_QUOTED.sub("_", command.replace("\\;", "")):
        if char in "({":
            if not depth:
                kept.append("_")
            depth += 1
        elif char in ")}":
            depth = max(depth - 1, 0)
        elif not depth:
            kept.append(char)
    return "".join(kept)


@rule(
    "semicolon-chain",
    "review",
    "all",
    "after ';' assert_script_run checks only the last exit code",
)
def semicolon_chain(module):
    hits = []
    for number, line in enumerate(module.raw, 1):
        call = _CHAIN_CALL.match(line)
        if not call or "assert_script_run" not in module.code[number - 1]:
            continue
        # '.' joins strings in Perl only.
        command = call.group(2) if module.python else _command(line, call)
        if _shell_checked(command):
            continue
        parts = _top_level(command).rstrip("; ").split(";")
        *before, last = [part.strip() for part in parts]
        # Quoted text is a '_' by now, so a value from $( ) or backticks, which can fail, is looked for in the call.
        computed = "$(" in command or "`" in command
        dropped = [
            part
            for part in before
            if part
            and "||" not in part
            and not _NO_STATUS.match(part)
            and (computed or not _ASSIGNMENT.match(part))
        ]
        # Silent where the last command is the check itself or no other one drops an exit code that says something.
        if dropped and not _STATUS_TEST.match(last):
            hits.append(number)
    return hits, (
        "';' joins commands inside assert_script_run: only the last exit code is checked",
        (
            "join with '&&'; a tolerated failure gets '|| true'; a script goes through script_output "
            "or write_sut_file + 'bash -e' (references/performance.md \"Batch and upload\")"
        ),
    )


@rule(
    "trailing-true",
    "engine",
    "perl",
    "autotest.pm loads modules with require, which needs a true value",
)
def trailing_true(module):
    last = [number for number, line in enumerate(module.code, 1) if line.strip()]
    if not last or re.match(r"^\s*1;\s*$", module.code[last[-1] - 1]):
        return [], None
    return [last[-1]], (
        "file does not end in '1;', loading dies unless the last statement happens to be true",
        "end the file with '1;'",
    )


SCOPES = {
    "all": lambda module: True,
    "perl": lambda module: not module.python,
    "test": lambda module: module.is_test,
    "test-perl": lambda module: module.is_test and not module.python,
}


MAX_LINES_SHOWN = 12


def check(module, disabled):
    findings = []
    for ident in ORDER:
        _kind, scope, _summary, function = RULES[ident]
        if ident in disabled or not SCOPES[scope](module):
            continue
        lines, text = function(module)
        for number in lines:
            findings.append((number, ORDER.index(ident), ident, text))
    return sorted(findings)


def main(argv=None):
    parser = ArgumentParser(
        prog="check-module.py",
        description="Offline lint of os-autoinst-distri-opensuse test modules (.pm, .py). "
        "Prints one '<file>:<line>[,<line>...]: <id>' per file and rule; '<message> -> <fix>' "
        "follows the first finding of each rule only. Files under lib/ skip the rules that "
        "only apply to tests/. The last line is always 'summary: N file(s), M finding(s)'.",
        epilog="exit: 0 clean, 1 findings, 2 usage or file error",
    )
    parser.add_argument("files", nargs="*", metavar="file", help="module(s) to check")
    parser.add_argument(
        "--list-rules",
        action="store_true",
        help="print id, class and source of each rule",
    )
    parser.add_argument(
        "--disable",
        action="append",
        default=[],
        metavar="ids",
        help="comma-separated rule ids to skip (repeatable)",
    )
    args = parser.parse_args(argv)

    if args.list_rules:
        for ident in ORDER:
            print(f"{ident:27s} {RULES[ident][0]:7s} {RULES[ident][2]}")
        return 0
    if not args.files:
        parser.error("give at least one file, or --list-rules")
    disabled = {ident for chunk in args.disable for ident in chunk.split(",") if ident}
    unknown = sorted(disabled - set(RULES))
    if unknown:
        parser.error(
            "unknown rule id: {} (see --list-rules)".format(", ".join(unknown))
        )

    out = []
    explained = set()
    broken = False
    checked = findings = 0
    for path in args.files:
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                module = Module(path, handle.read())
        except OSError as error:
            print(
                one_lines([f"check-module.py: {path}: {error.strerror}"]),
                end="",
                file=sys.stderr,
            )
            broken = True
            continue
        checked += 1
        grouped = {}
        for number, _rank, ident, text in check(module, disabled):
            grouped.setdefault((ident, text), []).append(number)
        for (ident, (message, fix)), numbers in grouped.items():
            findings += len(numbers)
            where = ",".join(map(str, numbers[:MAX_LINES_SHOWN]))
            if len(numbers) > MAX_LINES_SHOWN:
                where += f",+{len(numbers) - MAX_LINES_SHOWN}"
            line = f"{path}:{where}: {ident}"
            if (ident, message, fix) not in explained:
                explained.add((ident, message, fix))
                line += f" {message} -> {fix}"
            out.append(line)
    sys.stdout.write(one_lines(out, max_line=600))
    print(f"summary: {checked} file(s), {findings} finding(s)")
    if broken:
        return 2
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main())
