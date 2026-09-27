#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Offline check of a drafted Bugzilla bug or progress ticket against references/bugs-and-tickets.md.
"""Check a drafted bug or ticket (JSON) for shape, size, markup and leaks before it is filed.

No network access. Whether the report is right is not checked: that is the refute pass.
"""

import ipaddress
import json
import os
import re
import sys
from urllib.parse import urlsplit

import _secrets
from _sanitize import ArgumentParser, sanitize

MAX_INPUT = 262144
MAX_LISTED = 40
# Bugzilla short_desc and Redmine subject both stop at 255 characters.
SUMMARY_MAX = 255
BODY_TARGET = {"bugzilla": 1500, "progress": 2000}
BODY_MAX = {"bugzilla": 3000, "progress": 4000}
PROSE_LINE = 80
# os-autoinst-scripts openqa-label-known-issues: min_search_term.
MIN_SEARCH = 16
FORCE_TRACKER = "openqa-force-result"
SECTIONS = {
    "bugzilla": (
        "## Observation",
        "## Reproducible",
        "## Expected result",
        "## Further details",
    ),
    "progress": ("## Observation", "## Reproducible", "## Expected result"),
}
LABELS = {"bugzilla": ("Expected:", "Actual:"), "progress": ()}
FIELDS = {
    "bugzilla": ("product", "component", "version", "severity"),
    "progress": ("project", "tracker", "category"),
}
SEVERITIES = ("Blocker", "Critical", "Major", "Normal", "Minor", "Enhancement")
TITLE = {"bugzilla": "summary", "progress": "subject"}
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

URL = re.compile(r"https?://(?:\[[0-9A-Fa-f:.%]+\])?[^\s<>\"'`)\]]*", re.IGNORECASE)
HTML_TAGS = r"a|b|i|br|p|pre|code|ul|ol|li|table|tr|td"
# Template slots like <module> or <step URL>; an HTML tag is the markup check's business.
PLACEHOLDER = re.compile(
    rf"<(?!/?(?:{HTML_TAGS})\b)(?!https?:)[A-Za-z0-9][^<>\n]{{0,100}}>"
    r"|\b(?:TBD|TODO|XXX|PLACEHOLDER|xyz)\b"
)
MARKDOWN = (
    ("link", re.compile(r"\[[^\[\]\n]+\]\((?:https?://|/)[^)\s]*\)")),
    (
        "bold",
        re.compile(r"\*\*[^*\n]+\*\*|(?<!\w)__(?=\S)[^\s_]*\s[^_\n]*(?<=\S)__(?!\w)"),
    ),
    ("fence", re.compile(r"^\s*(?:```|~~~)")),
    ("table", re.compile(r"^\s*\|?\s*:?-{3,}:?\s*\|")),
    ("html", re.compile(rf"</?(?:{HTML_TAGS})\b[^<>\n]*>", re.IGNORECASE)),
)
SEE_TITLE = re.compile(r"\bsee (?:the )?(?:summary|subject|title)\b", re.IGNORECASE)
NOTES_LEAK = re.compile(r"\bapprover notes?\b", re.IGNORECASE)
FENCE = re.compile(r"\s*(`{3,}|~{3,})")
CODE_SPAN = re.compile(r"`[^`\n]*`")
PUBLIC_PREFIXES = ("openSUSE ", "PUBLIC ")
PUBLIC_PROJECTS = ("openqatests", "openqav3", "openqa-infrastructure")


def quoted(text, limit=80):
    text = " ".join(sanitize(str(text), max_line=0, max_bytes=0).split())
    if len(text) > limit:
        text = text[: limit - 3] + "..."
    return '"' + text.replace('"', "'") + '"'


def private_host(host, extra_suffixes):
    host = (host or "").lower().rstrip(".")
    if not host:
        return False
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return (
            "." not in host
            or host.endswith((*PRIVATE_SUFFIXES, *extra_suffixes))
            or any(host == suffix[1:] for suffix in extra_suffixes)
        )
    return not address.is_global


def prose_lines(kind, body):
    """Yield (number, line) outside verbatim blocks: fenced on progress, indented on Bugzilla.

    An unclosed fence yields (number, None) at its opening line once the body ends.
    """
    fence, opened = "", 0
    for number, line in enumerate(body.split("\n"), 1):
        mark = FENCE.match(line) if kind == "progress" else None
        if mark and not fence:
            fence, opened = mark.group(1), number
            continue
        if mark and mark.group(1)[0] == fence[0] and len(mark.group(1)) >= len(fence):
            fence = ""
            continue
        if fence or (kind == "bugzilla" and re.match(r"(?: {4}|\t)", line)):
            continue
        yield number, line
    if fence:
        yield opened, None


def search_term(subject):
    """The regex openqa-label-known-issues reads: between the first and the last double quote."""
    after = subject.split('"', 1)[1] if '"' in subject else ""
    return after.rsplit('"', 1)[0] if '"' in after else ""


def present(value):
    return (
        isinstance(value, (str, int))
        and not isinstance(value, bool)
        and bool(str(value).strip())
    )


def is_public_target(kind, fields):
    if kind == "bugzilla":
        return str(fields.get("product", "")).startswith(PUBLIC_PREFIXES)
    return fields.get("project") in PUBLIC_PROJECTS


def lint(draft, extra_suffixes=()):
    """Return (report lines, number of findings)."""
    kind, fields, body = draft["kind"], draft["fields"], draft["body"]
    title_name = TITLE[kind]
    title = draft[title_name]
    public = draft["public"]
    found = []

    for name in FIELDS[kind]:
        if not present(fields.get(name)):
            found.append(
                f"field {name}: missing; -> bugs-and-tickets.md for how to choose it"
            )
    if kind == "bugzilla":
        if fields.get("priority") is not None:
            found.append(
                "field priority: set by the bug owner or release manager, never by the reporter"
            )
        severity = fields.get("severity")
        if present(severity) and severity not in SEVERITIES:
            found.append(
                f"field severity: {quoted(severity)} is not one of {', '.join(SEVERITIES)}"
            )
    if not public and is_public_target(kind, fields):
        found.append(
            "field public: false, but this product or project is public; the private-link "
            "check stays on"
        )
        public = True

    if not title.strip() or "\n" in title.strip():
        found.append(f"title {title_name}: must be one non-empty line")
    if len(title) > SUMMARY_MAX:
        found.append(
            f"title {title_name}: {len(title)} chars, the tracker stops at {SUMMARY_MAX}"
        )

    prose = list(prose_lines(kind, body))
    stripped = [line.strip() for _, line in prose if line is not None]
    position = -1
    for heading in SECTIONS[kind]:
        if heading not in stripped:
            found.append(f"section {quoted(heading)}: missing")
            continue
        index = stripped.index(heading)
        if index < position:
            found.append(f"section {quoted(heading)}: out of order")
        position = max(position, index)
    for label in LABELS[kind]:
        if not any(re.match(rf"{label}\s*\S", line) for line in stripped):
            found.append(
                f"label {quoted(label)}: missing; one line each for Expected and Actual"
            )

    size = len(body)
    if size > BODY_MAX[kind]:
        found.append(
            f"size body: {size} chars, over {BODY_MAX[kind]} (target {BODY_TARGET[kind]}); "
            "cut what the maintainer does not need, or give the reason in the approver notes"
        )

    for number, line in prose:
        where = f"body line {number}"
        if line is None:
            found.append(
                f"markdown {where}: the fence opened here is never closed; the rest of the "
                "body renders as code"
            )
            continue
        if kind == "bugzilla":
            for name, pattern in MARKDOWN:
                if pattern.search(line):
                    found.append(
                        f"markdown {where}: {name}; Bugzilla shows plain text, use bare URLs and "
                        "4-space verbatim blocks"
                    )
                    break
            text = URL.sub("", line).rstrip()
            if len(text) > PROSE_LINE and not line.startswith("## "):
                found.append(
                    f"long-line {where}: {len(text)} chars without URLs, wrap prose at {PROSE_LINE}"
                )
        slot = PLACEHOLDER.search(
            CODE_SPAN.sub("", line) if kind == "progress" else line
        )
        if slot:
            found.append(f"placeholder {where}: {quoted(slot.group())}")
        if SEE_TITLE.search(line):
            found.append(
                f"see-title {where}: the {title_name} gets edited; say it again in the body"
            )
    for number, line in enumerate(body.split("\n"), 1):
        if NOTES_LEAK.search(line):
            found.append(
                f"notes body line {number}: approver notes are shown to the user, never filed"
            )
    if PLACEHOLDER.search(title):
        found.append(
            f"placeholder {title_name}: {quoted(PLACEHOLDER.search(title).group())}"
        )

    texts = [(title_name, title), ("body", body)]
    texts += [
        (f"field {name}", value)
        for name, value in fields.items()
        if isinstance(value, str)
    ]
    for where, text in texts:
        for number, line in enumerate(text.split("\n"), 1):
            _, hits = _secrets.redact(line)
            for rule in sorted(hits):
                found.append(
                    f"credential {where} line {number}: looks like a {rule}; remove it and "
                    "rotate the credential"
                )
        if public:
            for match in URL.finditer(text):
                url = match.group().rstrip(".,;:!?")
                try:
                    host = urlsplit(url).hostname
                except ValueError:
                    host = None
                if host is None or private_host(host, extra_suffixes):
                    found.append(
                        f"private-url {where}: {quoted(url, 120)} is not reachable for readers "
                        "of a public tracker"
                    )

    if kind == "progress" and "auto_review:" in title:
        # openqa-label-known-issues: search term, re.compile, min_search_term, force_result tracker.
        term = search_term(title)
        if title.count('"') != 2:
            found.append(
                f"auto-review subject: {title.count(chr(34))} double quotes; the search term runs "
                "from the first to the last, so the subject may hold only its own pair"
            )
        if len(term) < MIN_SEARCH:
            found.append(
                f"auto-review subject: the regex {quoted(term)} is {len(term)} chars; "
                f"openqa-label-known-issues ignores terms under {MIN_SEARCH}"
            )
        try:
            empty = re.compile(term).search("") is not None
        except re.error as error:
            found.append(
                f"auto-review subject: the regex does not compile ({quoted(error, 120)}); "
                "openqa-label-known-issues stops with exit 2"
            )
        else:
            if empty:
                found.append(
                    "auto-review subject: the regex matches an empty log, so it labels every job"
                )
        if ":force_result:" in title and fields.get("tracker") != FORCE_TRACKER:
            found.append(
                f"auto-review subject: force_result is ignored unless the tracker is {FORCE_TRACKER}"
            )
        if "openqa-query-for-job-label" not in body:
            found.append(
                "auto-review body: add the Steps to reproduce snippet with openqa-query-for-job-label"
            )

    notes = draft["notes"]
    report = [
        (
            f"draft: {kind}, {title_name} {len(title)}/{SUMMARY_MAX} chars, body {size} chars "
            f"(target {BODY_TARGET[kind]}, limit {BODY_MAX[kind]}), notes {len(notes)} chars "
            "(not filed)"
        )
    ]
    if found:
        report.append(f"findings: {len(found)}")
        report += [f"  F {line}" for line in found[:MAX_LISTED]]
        if len(found) > MAX_LISTED:
            report.append(f"  ... {len(found) - MAX_LISTED} more not shown")
    else:
        report.append("shape ok; whether the report is right is the refute pass's job")
    return report, len(found)


class NotADraft(Exception):
    """The input is not the JSON of a bug or ticket draft."""


def load(raw):
    """Return the draft as {kind, fields, <title>, body, notes, public} or raise NotADraft."""
    try:
        data = json.loads(raw)
    except (ValueError, RecursionError):
        raise NotADraft("not JSON") from None
    if not isinstance(data, dict):
        raise NotADraft("not a JSON object")
    kind = data.get("kind")
    if kind not in TITLE:
        raise NotADraft("kind must be bugzilla or progress")
    fields = data.get("fields")
    if not isinstance(fields, dict):
        raise NotADraft("fields must be an object")
    title = data.get(TITLE[kind])
    if not isinstance(title, str):
        raise NotADraft(f"{TITLE[kind]} must be a string")
    body = data.get("body")
    if not isinstance(body, str) or not body.strip():
        raise NotADraft("body must be a non-empty string")
    notes = data.get("notes")
    notes = "" if notes is None else notes
    if not isinstance(notes, str):
        raise NotADraft("notes must be a string")
    public = data.get("public", True)
    if not isinstance(public, bool):
        raise NotADraft("public must be true or false")
    return {
        "kind": kind,
        "fields": fields,
        TITLE[kind]: title,
        "body": body.replace("\r\n", "\n"),
        "notes": notes,
        "public": public,
    }


def main():
    parser = ArgumentParser(
        prog="ticket-lint.py",
        description="Offline check of a DRAFT Bugzilla bug or progress ticket, given as JSON: "
        '{"kind": "bugzilla"|"progress", "fields": {...}, "summary"|"subject": "...", '
        '"body": "...", "notes": "...", "public": true}. Checks fields, sections, size, markup, '
        "placeholders, credentials, private links and auto_review subjects; not whether the "
        "report is right. Filing stays a separate, human-approved step.",
        epilog="Exit codes: 0 shape ok, 1 findings, 2 usage error or not a draft JSON object, also "
        f"one over {MAX_INPUT} characters.",
    )
    parser.add_argument(
        "file",
        nargs="?",
        metavar="FILE",
        help="file holding the draft JSON, '-' for stdin (default: stdin)",
    )
    parser.add_argument(
        "--private-suffix",
        action="append",
        default=[],
        metavar="SUFFIX",
        help="additional host name suffix readers of a public tracker cannot reach, e.g. "
        ".corp.example (repeatable)",
    )
    args = parser.parse_args()

    if args.file in (None, "-"):
        sys.stdin.reconfigure(encoding="utf-8", errors="replace")
        raw = sys.stdin.read(MAX_INPUT + 1)
    elif os.path.exists(args.file) and not os.path.isfile(args.file):
        # A FIFO would block for ever, a device has no end.
        print(f"error: {quoted(args.file)}: not a regular file", file=sys.stderr)
        return 2
    else:
        try:
            with open(args.file, encoding="utf-8", errors="replace") as handle:
                raw = handle.read(MAX_INPUT + 1)
        except OSError as error:
            print(
                f"error: {quoted(args.file)}: {quoted(error.strerror)}", file=sys.stderr
            )
            return 2
    if len(raw) > MAX_INPUT:
        print(f"error: draft longer than {MAX_INPUT} characters", file=sys.stderr)
        return 2
    try:
        draft = load(raw)
    except NotADraft as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    suffixes = tuple("." + suffix.lower().strip(".") for suffix in args.private_suffix)
    report, found = lint(draft, suffixes)
    print("\n".join(report))
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
