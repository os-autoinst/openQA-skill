#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Offline lint of a draft openQA review comment: predicts the bugrefs, labels, flags and force_result openQA will parse.
"""Predict how openQA interprets a draft job comment. No network access.

The parsing rules are ports of the openQA sources; each regex below quotes the
Perl original with its file.
"""

import ipaddress
import os
import re
import sys
from urllib.parse import urlsplit

import _secrets
from _sanitize import ArgumentParser, excerpt, sanitize

MAX_INPUT = 65536
# The upstream patterns rescan the rest of a line from every marker or tracker URL in it.
MAX_LINE = 1000
MAX_LISTED = 40
LONG_CHARS = 1000
LONG_LINES = 15
PASTED_LOG_LINES = 3

# lib/OpenQA/Utils.pm, %BUGREFS
BUGREFS = {
    "bnc": "https://bugzilla.suse.com/show_bug.cgi?id=",
    "bsc": "https://bugzilla.suse.com/show_bug.cgi?id=",
    "boo": "https://bugzilla.opensuse.org/show_bug.cgi?id=",
    "bgo": "https://bugzilla.gnome.org/show_bug.cgi?id=",
    "bmo": "https://bugzilla.mozilla.org/show_bug.cgi?id=",
    "brc": "https://bugzilla.redhat.com/show_bug.cgi?id=",
    "bko": "https://bugzilla.kernel.org/show_bug.cgi?id=",
    "poo": "https://progress.opensuse.org/issues/",
    "gh": "https://github.com/",
    "kde": "https://bugs.kde.org/show_bug.cgi?id=",
    "kdi": "https://invent.kde.org/",
    "fdo": "https://bugs.freedesktop.org/show_bug.cgi?id=",
    "jsc": "https://jira.suse.com/browse/",
    "pio": "https://pagure.io/",
    "ggo": "https://gitlab.gnome.org/",
    "gfs": "https://gitlab.com/fedora/sigs/",
    "ffo": "https://forge.fedoraproject.org/",
}
# lib/OpenQA/Utils.pm, %BUGURLS: the reverse map has no entry for bnc and one
# extra root that also becomes bsc.
BUGURLS = {
    "https://bugzilla.novell.com/show_bug.cgi?id=": "bsc",
    **{url: marker for marker, url in BUGREFS.items() if marker != "bnc"},
}
# Trackers whose references carry a project: <marker>#<project/repo>#<id>
REPO_TRACKERS = ("gh", "kdi", "pio", "ggo", "gfs", "ffo")
# lib/OpenQA/WebAPI/Plugin/Helpers.pm, bugicon_for: $bugref =~ /(poo|gh)#/ -> test issue icon
TEST_ISSUE = re.compile(r"(poo|gh)#")
# lib/OpenQA/Jobs/Constants.pm, RESULTS
RESULTS = (
    "none",
    "passed",
    "softfailed",
    "failed",
    "incomplete",
    "skipped",
    "obsoleted",
    "parallel_failed",
    "parallel_restarted",
    "user_cancelled",
    "user_restarted",
    "timeout_exceeded",
)

_MARKERS = "|".join(BUGREFS)
# lib/OpenQA/Utils.pm:
#   $BUGREF_REGEX = qr{(?<match>(?<marker>$MARKER_REFS)\#?(?<repo>[^#\s<>,]+)?\#(?<id>([A-Z]+-)?\d+))};
_REF = rf"(?P<match>(?P<marker>{_MARKERS})\#?(?P<repo>[^#\s<>,]+)?\#(?P<id>(?:[A-Z]+-)?\d+))"
UNCONSTRAINED_BUGREF = re.compile(_REF)
# lib/OpenQA/Utils.pm:
#   $AFTER_TAG_LOOKBEHIND = qr{(?<=<\w{1}>)|(?<=<\w{2}>)|...|(?<=<\w{6}>)};
#   BUGREF_REGEX => qr{(?:^|$AFTER_TAG_LOOKBEHIND|(?<=\s|,))$BUGREF_REGEX(?![\w\"])};
# No /m there: "^" is the start of the comment, not of a line.
_AFTER_TAG = "|".join(rf"(?<=<\w{{{width}}}>)" for width in range(1, 7))
BUGREF = re.compile(rf"(?:^|{_AFTER_TAG}|(?<=\s|,)){_REF}(?![\w\"])")
# lib/OpenQA/Utils.pm: LABEL_REGEX => qr/\blabel:(?<match>([\w:#\/-]+))\b/
LABEL = re.compile(r"\blabel:(?P<match>[\w:#/-]+)\b")
# lib/OpenQA/Utils.pm: FLAG_REGEX => qr/\bflag:(?<match>([\w:#]+))\b/
FLAG = re.compile(r"\bflag:(?P<match>[\w:#]+)\b")
# lib/OpenQA/Schema/Result/Comments.pm, force_result:
#   next unless $label =~ /^force_result:(\w+):?(\w*)/;
FORCE_RESULT = re.compile(r"^force_result:(\w+):?(\w*)")
# lib/OpenQA/Utils.pm, href_to_bugref (applied when a comment is created or
# updated through the API, Controller/API/V1/Comment.pm); only "?" is escaped
# in the URL roots; the /i of the substitution does not reach the precompiled
# qr// object, so the match is case sensitive:
#   qr{(?<!["\(\[])(?<url_root>$regex)((?<repo>.*?)/(-/)?(issues?|pulls?|work_items)/)?(?<id>([A-Z]+-)?\d+)(?![\w])}
_ROOTS = "|".join(url.replace("?", r"\?") for url in BUGURLS)
_HREF_BODY = (
    rf"(?P<url_root>{_ROOTS})"
    r"((?P<repo>.*?)/(-/)?(issues?|pulls?|work_items)/)?(?P<id>([A-Z]+-)?\d+)(?![\w])"
)
HREF = re.compile(r"(?<![\"(\[])" + _HREF_BODY)
_HREF_ANYWHERE = re.compile(_HREF_BODY)
_URL = re.compile(r"https?://[^\s<>()\[\]\"'`]+")
_LOOSE_REF = re.compile(r"(?<![\w/#.-])([A-Za-z][A-Za-z0-9]{1,9})#(\d{3,})(?!\w)")
_SPLIT_REF = re.compile(rf"(?<![\w/#])({_MARKERS})(\s*(?:\#\s*)?)(\d{{3,}})(?!\w)")
# A known marker whose id is still a placeholder: poo#<id>, bsc#N, boo#TBD, gh#owner/repo#<n>, poo#?
_PLACEHOLDER = re.compile(
    rf"(?<![\w/#.-])(?:{_MARKERS})\#(?:[^#\s<>,]+\#)?"
    r"(?:<[^>\n]{0,40}>?|\?+|\.{3}|[A-Za-z_]\w*(?!\w|-\d|[^#\s<>,]*\#\d))"
)
_LOOSE_LABEL = re.compile(r"\b(labels?|flags?)(\s*):(\s*)(?=\S)", re.IGNORECASE)
_BARE_FORCE = re.compile(r"(?<![\w:])force_result\b")
_LOG_LINE = re.compile(
    r"^\s*\[\d{4}-\d\d-\d\dT[\d:.]+Z?\]|\[pid:\d+\]|^\s*(?:\|\|\||<<<|>>>|:::|!!!) \S"
)
PRIVATE_SUFFIXES = (
    ".local",
    ".localdomain",
    ".localhost",
    ".lan",
    ".home",
    ".home.arpa",
    ".internal",
    ".intranet",
    ".corp",
    ".test",
    ".invalid",
)


def quoted(text, limit=80):
    return '"' + excerpt(str(text), limit).replace('"', "'") + '"'


def href_to_bugref(text):
    """Return (rewritten text, number of rewrites, rewrites that swallowed other text)."""
    swallowed = []

    def short(match):
        repo = match.group("repo")
        if repo and re.search(r"\s", repo):
            swallowed.append(match.group())
        return (
            BUGURLS[match.group("url_root")]
            + ("#" + repo if repo else "")
            + "#"
            + match.group("id")
        )

    text, count = HREF.subn(short, text)
    return text, count, swallowed


def bugurl(match):
    """lib/OpenQA/Utils.pm, bugurl: pagure uses issue/, everything else issues/."""
    marker, repo = match.group("marker"), match.group("repo")
    issues = "issue" if marker == "pio" else "issues"
    return BUGREFS[marker] + (f"{repo}/{issues}/" if repo else "") + match.group("id")


def accidental(match):
    """A word such as bootloader_uefi#1 or ghostscript#2 that only happens to parse."""
    marker, repo = match.group("marker"), match.group("repo")
    hash_follows = match.group("match")[len(marker) :].startswith("#")
    if marker in REPO_TRACKERS:
        return bool(repo) and (not hash_follows or "/" not in repo)
    return bool(repo)


def private_host(host, extra_suffixes):
    host = (host or "").lower().rstrip(".")
    if not host:
        return False
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return "." not in host or host.endswith((*PRIVATE_SUFFIXES, *extra_suffixes))
    return not address.is_global


def listed(lines):
    """At most MAX_LISTED report lines; the count line above them stays exact."""
    more = len(lines) - MAX_LISTED
    return lines[:MAX_LISTED] + ([f"  ... {more} more not shown"] if more > 0 else [])


def line_of(text, position):
    return text.count("\n", 0, position) + 1


def covered(spans):
    """Character positions inside the spans: overlap checks stay linear in the draft."""
    return {position for start, end in spans for position in range(start, end)}


def overlaps(span, positions):
    return any(position in positions for position in range(*span))


def lint(draft, extra_suffixes=()):
    """Return the report lines and the number of warnings."""
    warnings, notes, out = [], [], []
    text, rewritten, swallowed = href_to_bugref(draft)
    lines = text.split("\n")
    if rewritten:
        out.append(
            f"on save openQA rewrites {rewritten} tracker URL(s) into short refs; "
            "the results below are for the rewritten text"
        )

    refs = list(BUGREF.finditer(text))
    labels = list(LABEL.finditer(text))
    flags = list(FLAG.finditer(text))
    ref_spans = [match.span("match") for match in refs]
    in_refs = covered(ref_spans)
    in_labels = covered(match.span() for match in labels)

    # --- bugrefs ---
    out.append(f"bugrefs: {len(refs)}")
    real_refs, shown = 0, []
    for match in refs:
        ref = match.group("match")
        kind = "test issue" if TEST_ISSUE.search(ref) else "product bug"
        shown.append(f"  {quoted(ref)} -> {quoted(bugurl(match), 160)} ({kind})")
        if accidental(match):
            warnings.append(
                f"accidental-bugref line {line_of(text, match.start('match'))}: {quoted(ref)} is "
                f"parsed as a {match.group('marker')} reference; if it is a module name put it "
                "in backticks or write category/module#N"
            )
        else:
            real_refs += 1
    out += listed(shown)
    if refs and ref_spans[0][0] > text.find("\n") >= 0:
        notes.append(
            "the first line has no bugref; carry-over copies the whole text, so start with "
            "'<bugref> <short title>'"
        )

    # --- near misses for bugrefs ---
    near_spans = []
    for match in UNCONSTRAINED_BUGREF.finditer(text):
        span = match.span("match")
        if overlaps(span, in_refs) or overlaps(span, in_labels) or accidental(match):
            continue
        before = text[span[0] - 1] if span[0] else ""
        after = text[span[1]] if span[1] < len(text) else ""
        if before.isalnum() or before == "_":
            continue  # tail of an ordinary word
        reason = (
            f"followed by {quoted(after)}"
            if after and (after.isalnum() or after in '_"')
            else f"preceded by {quoted(before)}"
        )
        near_spans.append(span)
        warnings.append(
            f"near-miss-bugref line {line_of(text, span[0])}: {quoted(match.group('match'))} is NOT "
            f"a bugref ({reason}); a ref must start the comment or follow whitespace or a comma, "
            'and must not be followed by a word character or "'
        )
    in_refs_or_near = in_refs | covered(near_spans)
    taken = in_refs_or_near | in_labels
    for match in _LOOSE_REF.finditer(text):
        span = match.span()
        if overlaps(span, taken):
            continue
        prefix = match.group(1)
        if prefix.lower() in BUGREFS:
            fixed = quoted(prefix.lower() + "#" + match.group(2))
            why = f"markers are lower case, write {fixed}"
        else:
            why = "unknown tracker prefix, openQA knows: " + " ".join(BUGREFS)
        warnings.append(
            f"unknown-tracker line {line_of(text, span[0])}: {quoted(match.group())}: {why}"
        )
    for match in _SPLIT_REF.finditer(text):
        if match.group(2) == "#" or overlaps(match.span(), taken):
            continue
        warnings.append(
            f"near-miss-bugref line {line_of(text, match.start())}: {quoted(match.group())} is NOT "
            f"a bugref, write {quoted(match.group(1) + '#' + match.group(3))}"
        )

    explained = False
    for match in _PLACEHOLDER.finditer(text):
        if overlaps(match.span(), in_refs_or_near):
            continue
        warning = f"placeholder-bugref line {line_of(text, match.start())}: {quoted(match.group())}"
        if not explained:
            explained = True
            warning += (
                " is a placeholder: not parsed, on its own the job stays unreviewed and "
                "nothing carries over; find or file the ticket first and write its number"
            )
        warnings.append(warning)

    # --- URLs ---
    for victim in swallowed:
        warnings.append(
            f"url-rewrite line {line_of(draft, draft.find(victim))}: on save openQA's URL rewriting "
            f"mangles {quoted(victim, 120)}: a tracker URL followed on the same line by an "
            "issues/pull URL is merged into one ref; use short refs or one URL per line"
        )
    for match in _URL.finditer(text):
        url = match.group().rstrip(".,;:!?")
        try:
            host = urlsplit(url).hostname
        except ValueError:
            continue
        where = line_of(text, match.start())
        if private_host(host, extra_suffixes):
            warnings.append(
                f"private-url line {where}: {quoted(url, 120)} points at a host other readers "
                "cannot reach; reference a public tracker with a short ref instead"
            )
        elif _HREF_ANYWHERE.match(url):
            warnings.append(
                f"tracker-url line {where}: {quoted(url, 120)} stays a plain link (openQA does not "
                'rewrite a URL that follows ( [ or "); it is not a bugref, add the short ref'
            )

    # --- credentials ---
    # The last gate before an internal secret becomes a public comment: this draft is
    # usually assembled from log excerpts, which openQA does not redact.
    for number, line in enumerate(text.split("\n"), 1):
        _, found = _secrets.redact(line)
        for rule in sorted(found):
            warnings.append(
                f"credential line {number}: looks like a {rule}; openQA does not redact "
                "logs, so a quoted excerpt can carry one. Remove it and rotate the credential"
            )

    # --- labels ---
    if labels:
        out.append(f"labels: {len(labels)}")
    shown = []
    for index, match in enumerate(labels):
        label = match.group("match")
        role = (
            "the label of this comment"
            if index == 0
            else "ignored as a label, only the first one counts"
        )
        shown.append(f"  {quoted(label)} ({role})")
        tail = text[match.end() : match.end() + 2]
        if (
            len(tail) == 2
            and not tail[0].isspace()
            and (tail[1].isalnum() or tail[1] == "_")
        ):
            warnings.append(
                f"label-cut line {line_of(text, match.start())}: the label ends before {quoted(tail[0])}; "
                "labels may only contain letters, digits, _ : # / -"
            )
        inner = UNCONSTRAINED_BUGREF.search(label)
        if inner and not FORCE_RESULT.match(label) and not label.startswith("linked:"):
            text_ = (
                f"label-bugref line {line_of(text, match.start())}: {quoted('label:' + label)} is a "
                "label, not a bugref: no bug icon and NO carry-over"
            )
            if real_refs or any(m.group("match") == "carryover" for m in flags):
                notes.append(text_ + " (the comment carries over for another reason)")
            else:
                warnings.append(
                    text_
                    + f"; write {quoted(inner.group('match'))} on its own to get carry-over"
                )
    out += listed(shown)
    if refs and labels:
        notes.append(
            "a comment with a bugref is shown by its bugref; its label is not displayed"
        )
    for match in _LOOSE_LABEL.finditer(text):
        word, exact = match.group(1), match.group(1) in ("label", "flag")
        if exact and not match.group(2) and not match.group(3):
            continue
        warnings.append(
            f"near-miss-{word.lower().rstrip('s')} line {line_of(text, match.start())}: "
            f"{quoted(text[match.start() : match.start() + 30].split(chr(10))[0])} is not parsed; write "
            f"{word.lower().rstrip('s')}:<value> in lower case without spaces"
        )

    # --- flags ---
    names = [match.group("match") for match in flags]
    if names:
        more = f" +{len(names) - MAX_LISTED}" if len(names) > MAX_LISTED else ""
        out.append(
            "flags: " + " ".join(quoted(name) for name in names[:MAX_LISTED]) + more
        )
    for match in flags:
        if match.group("match") != "carryover":
            warnings.append(
                f"unknown-flag line {line_of(text, match.start())}: {quoted(match.group())} has no "
                "effect, the only flag is flag:carryover"
            )
    carry_flag = "carryover" in names

    # --- verdicts ---
    if refs:
        out.append("counts as reviewed: yes (bugref)")
    elif labels:
        out.append("counts as reviewed: yes (label)")
    else:
        out.append(
            "counts as reviewed: no (plain comment: needs a bugref or a label:<keyword>)"
        )
    conditions = "the WHOLE text is copied onto the next job of the scenario that fails in the same modules"
    if refs or carry_flag:
        cause = "bugref" if refs else "flag:carryover"
        out.append(f"will carry over: yes ({cause}) - {conditions}")
        if refs and not real_refs:
            notes.append("carry-over rests on an accidental bugref only")
    elif labels:
        out.append(
            "will carry over: no (labels alone are never carried over; add a bugref or flag:carryover)"
        )
    else:
        out.append("will carry over: no (no bugref and no flag:carryover)")

    # --- force_result ---
    parses = [(m, FORCE_RESULT.match(m.group("match"))) for m in labels]
    forced, force = next(((m, found) for m, found in parses if found), (None, None))
    broken = [
        m
        for m, found in parses
        if not found and m.group("match").split(":")[0] == "force_result"
    ]
    if forced and force:
        label = forced.group("match")
        result, description = force.groups()
        if result in RESULTS:
            out.append(
                f"force_result: result {quoted(result)} is valid; description seen by openQA: "
                f"{quoted(description) if description else 'none'}; needs the operator role; the job "
                "must be done or cancelled; the comment cannot be deleted through the API afterwards"
            )
        else:
            out.append(f"force_result: INVALID result {quoted(result)}")
            warnings.append(
                f"force-result-invalid line {line_of(text, forced.start())}: openQA rejects the "
                f"comment with HTTP 400 \"Invalid result '{quoted(result)[1:-1]}' for force_result\"; "
                "valid: " + " ".join(RESULTS)
            )
        rest = label[force.end() :]
        if rest and result in RESULTS:
            notes.append(
                f"force_result description: only {quoted(description)} is captured (\\w* stops at "
                f"{quoted(rest[0])}); an instance with force_result_regex checks just that part"
            )
        if not refs and not carry_flag:
            notes.append(
                "this force_result will not be re-applied on later jobs: a ref inside the label "
                "is no bugref, add one on its own line or flag:carryover"
            )
    elif broken:
        out.append("force_result: NOT parsed")
        warnings.append(
            f"force-result-invalid line {line_of(text, broken[0].start())}: "
            f"{quoted('label:' + broken[0].group('match'))} has no result name; write "
            "label:force_result:<result>[:<description>]"
        )
    for match in _BARE_FORCE.finditer(text):
        if not overlaps(match.span(), in_labels):
            warnings.append(
                f"force-result-invalid line {line_of(text, match.start())}: force_result without "
                "the label: prefix is plain text; write label:force_result:<result>[:<description>]"
            )

    # --- shape ---
    # Compare against the redacted draft, not the raw one: sanitize() also redacts,
    # so a credential would otherwise be reported as a control character.
    if sanitize(draft, max_line=0, max_bytes=0) != _secrets.redact(draft)[0]:
        warnings.append(
            "control-chars: the draft contains control, escape or invisible characters "
            "(or a fence marker); retype it as plain text"
        )
    pasted = sum(bool(_LOG_LINE.search(line)) for line in lines)
    if pasted >= PASTED_LOG_LINES:
        warnings.append(
            f"pasted-log: {pasted} lines look like log output; quote one decisive line and link "
            "the step (/tests/<id>#step/<module>/<n>) instead"
        )
    if len(draft) > LONG_CHARS or len(lines) > LONG_LINES:
        warnings.append(
            f"too-long: {len(lines)} lines, {len(draft)} chars (limits {LONG_LINES}/{LONG_CHARS}); "
            "the whole text is copied to every later job on carry-over, move details to the ticket"
        )

    out.append(f"warnings: {len(warnings)}")
    out += listed([f"  W {warning}" for warning in warnings])
    if notes:
        out.append(f"notes: {len(notes)}")
        out += listed([f"  N {note}" for note in notes])
    return out, len(warnings)


def main():
    parser = ArgumentParser(
        prog="oqa-comment-lint.py",
        description="Offline check of a DRAFT openQA job comment: shows the bugrefs, labels, flags "
        "and force_result that openQA will parse from it, whether the job then counts as reviewed "
        "and whether the comment carries over, and warns about near misses. Nothing is sent "
        "anywhere; posting the comment stays a separate, human-approved step.",
        epilog="Exit codes: 0 no warnings, 1 at least one warning, 2 usage error, also a draft over "
        f"{MAX_INPUT} characters or with a line over {MAX_LINE}. Each list shows {MAX_LISTED} entries "
        "at most. Group comments (tag:, pinned-description) are out of scope.",
    )
    parser.add_argument(
        "file",
        nargs="?",
        metavar="FILE",
        help="file holding the draft, '-' for stdin (default: stdin)",
    )
    parser.add_argument("--text", help="the draft itself, instead of FILE")
    parser.add_argument(
        "--private-suffix",
        action="append",
        default=[],
        metavar="SUFFIX",
        help="additional host name suffix to treat as not publicly reachable, e.g. .corp.example "
        "(repeatable)",
    )
    args = parser.parse_args()

    if args.text is not None and args.file is not None:
        parser.error("give FILE or --text, not both")
    if args.text is not None:
        draft = args.text
    elif args.file in (None, "-"):
        sys.stdin.reconfigure(encoding="utf-8", errors="replace")
        draft = sys.stdin.read(MAX_INPUT + 1)
    elif os.path.exists(args.file) and not os.path.isfile(args.file):
        # A FIFO would block for ever, a device has no end.
        print(f"error: {quoted(args.file)}: not a regular file", file=sys.stderr)
        return 2
    else:
        try:
            with open(args.file, encoding="utf-8", errors="replace") as handle:
                draft = handle.read(MAX_INPUT + 1)
        except OSError as error:
            print(f"error: {quoted(args.file)}: {error.strerror}", file=sys.stderr)
            return 2
    if len(draft) > MAX_INPUT:
        print(f"error: draft longer than {MAX_INPUT} characters", file=sys.stderr)
        return 2
    if any(len(line) > MAX_LINE for line in draft.split("\n")):
        print(
            f"error: draft has a line longer than {MAX_LINE} characters",
            file=sys.stderr,
        )
        return 2
    draft = draft.replace("\r\n", "\n").strip("\n")
    if not draft.strip():
        print("error: empty draft", file=sys.stderr)
        return 2
    suffixes = tuple("." + suffix.lower().lstrip(".") for suffix in args.private_suffix)
    report, warnings = lint(draft, suffixes)
    print("\n".join(report))
    return 1 if warnings else 0


if __name__ == "__main__":
    sys.exit(main())
