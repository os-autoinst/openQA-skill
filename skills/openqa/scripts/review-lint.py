#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Offline size check of a drafted pull request review against references/pr-reviewing.md "Review size".
"""Check a drafted review (the JSON for POST /repos/O/R/pulls/N/reviews) for size and form.

No network access. Whether a finding is right is not checked, only whether the
draft stays inside the budget and the form of references/pr-reviewing.md.
"""

import json
import os
import re
import sys
import unicodedata

from _sanitize import ArgumentParser, sanitize

MAX_INPUT = 262144
MAX_LISTED = 40
# pr-reviewing.md "Review size": changed lines <=20 / 21-100 / 101-300 / >300.
SIZES = (20, 100, 300)
COMMENTS = {"tests": (3, 5, 4, 4), "lib": (2, 4, 5, 8)}
CHARS = (600, 1000, 1500, 1500)
# Prose of one item by prefix; a body beside inline comments gets BODY_PROSE.
PROSE = {"": 600, "blocking": 1000, "nit": 150}
BODY_PROSE = 300
MAX_NITS = 2
BLOCK_LINES = 10
BLOCK_CHARS = 800
QUOTE_LINES = 2
QUOTE_CHARS = 300
EVENTS = ("COMMENT", "APPROVE", "REQUEST_CHANGES")

PREFIX = re.compile(r"(blocking|nit):", re.IGNORECASE)
# Near misses the exact prefix does not catch: **nit:**, Nit :, nitpick:, blocker:, blocking(x):
NEAR = re.compile(
    r"[*_\s]*(blocking|blocker|nit(?:s|pick\w*)?)[*_\s]*[:(-]", re.IGNORECASE
)
# CommonMark: up to 3 spaces, and a backtick fence's info string has no backtick.
FENCE = re.compile(r" {0,3}(?:(`{3,})([^`]*)|(~{3,})(.*))$")
URL = re.compile(r"https?://\S+")


def quoted(text, limit=80):
    # Sanitise before cutting: padding that sanitize() strips must not push a secret past the cut.
    text = " ".join(sanitize(str(text), max_line=0, max_bytes=0).split())
    if len(text) > limit:
        text = text[: limit - 3] + "..."
    return '"' + text.replace('"', "'") + '"'


def visible(text):
    return "".join(c for c in text if unicodedata.category(c) != "Cf")


def length(text):
    return len(unicodedata.normalize("NFC", visible(text)))


def closes(line, marker):
    rest = line.lstrip(" ")
    run = rest.rstrip()
    return (
        len(line) - len(rest) <= 3
        and len(run) >= len(marker)
        and set(run) == {marker[0]}
    )


def parts(text):
    """Return (prose lines, blocks as (info, lines, chars, closed), quoted lines, quoted chars)."""
    prose, blocks, quote_lines, quote_chars = [], [], 0, 0
    fence = None
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if fence:
            marker, info, lines, chars = fence
            if closes(line, marker):
                blocks.append((info, lines, chars, True))
                fence = None
            else:
                fence = (marker, info, lines + 1, chars + length(line))
            continue
        opening = FENCE.match(line)
        if opening:
            marker = opening.group(1) or opening.group(3)
            info = opening.group(2) if opening.group(1) else opening.group(4)
            fence = (marker, info.strip().lower(), 0, 0)
        elif line.lstrip().startswith(">"):
            content = line.lstrip()[1:].strip()
            if content:
                quote_lines += 1
                quote_chars += length(content)
        elif URL.sub("", line).strip():
            prose.append(URL.sub("", line))
    if fence:
        blocks.append((fence[1], fence[2], fence[3], False))
    return prose, blocks, quote_lines, quote_chars


def item(where, text):
    prose, blocks, quote_lines, quote_chars = parts(text)
    head = visible(text).lstrip()
    prefix = PREFIX.match(head)
    # The prefix after a quote or a code block: GitHub shows it, the budget does not see it.
    later = (
        not prefix and bool(prose) and bool(PREFIX.match(visible(prose[0]).lstrip()))
    )
    return {
        "where": where,
        "text": text,
        "kind": prefix.group(1).lower() if prefix else "",
        "near": not prefix and (later or bool(NEAR.match(head))),
        "prose": length(" ".join(" ".join(prose).split())),
        "prose_lines": len(prose),
        "blocks": blocks,
        "quote_lines": quote_lines,
        "quote_chars": quote_chars,
    }


def bucket(lines):
    return next((i for i, top in enumerate(SIZES) if lines <= top), len(SIZES))


def lint(review, lines, kind, late, replies=0):
    """Return (report lines, number of findings)."""
    event = review["event"]
    items = []
    if review["body"].strip():
        items.append(item("body", review["body"]))
    for number, comment in enumerate(review["comments"], 1):
        line = comment.get("line", comment.get("position"))
        place = quoted(f"{comment['path']}:{line}", 120)
        items.append(item(f"comment {number} {place}", comment["body"]))
    body = items[0] if items and items[0]["where"] == "body" else None
    comments = [x for x in items if x is not body]
    counted = [x for x in items if x["kind"] != "blocking"]
    nits = [x for x in items if x["kind"] == "nit"]
    blocking = [x for x in items if x["kind"] == "blocking"]
    requests = [x for x in comments if x["kind"] == ""]
    prose = sum(x["prose"] for x in counted)
    count = len(counted) + replies
    size = bucket(lines)
    most, chars = COMMENTS[kind][size], CHARS[size]

    found = []
    for x in items:
        if x["near"]:
            found.append(
                f"prefix {x['where']}: start with exactly `blocking:` or `nit:`, before any quote, "
                "or with neither"
            )
    if not review["commit_id"]:
        found.append(
            "commit review: no commit_id; the review would land on whatever head exists when posted"
        )
    if count > most:
        found.append(
            f"over-count review: {count} non-blocking items, the budget is {most}; "
            "cut nits, then the least concrete"
        )
    if prose > chars:
        found.append(
            f"over-chars review: {prose} chars of non-blocking prose, the budget is {chars}"
        )
    for x in items:
        if x["kind"] == "nit":
            continue
        if x is body and comments and not x["kind"]:
            if x["prose"] > BODY_PROSE:
                found.append(
                    f"long-body body: {x['prose']} chars beside inline comments, over {BODY_PROSE}; "
                    "the comments carry the points"
                )
        elif x["prose"] > PROSE[x["kind"]]:
            found.append(
                f"long-comment {x['where']}: {x['prose']} chars of prose, over {PROSE[x['kind']]}; "
                "one point: the failure and the fix"
            )
    if len(nits) > MAX_NITS:
        found.append(f"nits review: {len(nits)} nits, at most {MAX_NITS}")
    for x in nits:
        if x["prose"] > PROSE["nit"] or x["prose_lines"] > 1:
            found.append(
                f"long-nit {x['where']}: a nit is one line of at most {PROSE['nit']} chars, "
                "prefix included; a longer one is a change request or nothing"
            )
    if nits and not requests and not blocking:
        found.append(
            "lone-nits review: nits ride along a change request; on their own, drop them"
        )
    seen = {}
    for x in items:
        if not x["prose"]:
            continue
        key = " ".join(x["text"].split()).lower()
        if key in seen:
            found.append(
                f"duplicate {x['where']}: same text as {seen[key]}; post it once, naming the other places"
            )
        else:
            seen[key] = x["where"]
    for x in items:
        for info, block_lines, size_chars, closed in x["blocks"]:
            if not closed:
                found.append(
                    f"unclosed-fence {x['where']}: a code block never closes; "
                    "the rest of the text escapes every check"
                )
            if info != "suggestion" and (
                block_lines > BLOCK_LINES or size_chars > BLOCK_CHARS
            ):
                found.append(
                    f"pasted-block {x['where']}: a {block_lines}-line, {size_chars}-char code block; "
                    "link the step or the line"
                )
        if x["quote_lines"] > QUOTE_LINES or x["quote_chars"] > QUOTE_CHARS:
            found.append(
                f"quotes {x['where']}: {x['quote_lines']} quoted lines, {x['quote_chars']} chars; "
                "quote only the line you answer"
            )
    if late:
        for x in items:
            if x["kind"] != "blocking":
                found.append(
                    f"late {x['where']}: after approval or merge, post blocking findings only"
                )
    if event == "APPROVE" and items:
        found.append(
            "event review: an approval carries no text; findings go in a COMMENT review"
        )
    if event == "REQUEST_CHANGES" and not blocking:
        found.append("event review: REQUEST_CHANGES without a blocking: comment")
    if event == "COMMENT" and not items:
        found.append(
            "event review: an empty late review; nothing blocking, so post nothing"
            if late
            else "event review: an empty COMMENT review; approve if the user wants to, or post nothing"
        )

    label = (
        "beyond tests/, data/, schedule/"
        if kind == "lib"
        else "tests/, data/, schedule/ only"
    )
    report = [
        f"budget: {lines} changed lines, {label}: {most} non-blocking items, {chars} chars",
        (
            f"draft: {event}, {len(comments)} comment{'' if len(comments) == 1 else 's'}"
            f"{' + body' if body else ''}; "
            f"blocking {len(blocking)}, nit {len(nits)}, non-blocking prose {prose} chars"
            f"{f'; replies {replies}' if replies else ''}"
        ),
    ]
    if found:
        report.append(f"findings: {len(found)}")
        report += [f"  F {line}" for line in found[:MAX_LISTED]]
        if len(found) > MAX_LISTED:
            report.append(f"  ... {len(found) - MAX_LISTED} more not shown")
    else:
        report.append(
            f"size ok: {count}/{most} items, {prose}/{chars} chars; "
            "the findings themselves are not checked"
        )
    return report, len(found)


class NotAReview(Exception):
    """The input is not the JSON of a review."""


def load(raw):
    """Return the review as {event, body, commit_id, comments} or raise NotAReview."""
    try:
        data = json.loads(raw)
    except (ValueError, RecursionError):
        raise NotAReview("not JSON") from None
    if not isinstance(data, dict):
        raise NotAReview("not a JSON object")
    event = data.get("event")
    if event not in EVENTS:
        raise NotAReview("event must be " + ", ".join(EVENTS))
    body = data.get("body")
    body = "" if body is None else body
    if not isinstance(body, str):
        raise NotAReview("body must be a string")
    commit = data.get("commit_id")
    if commit is not None and not isinstance(commit, str):
        raise NotAReview("commit_id must be a string")
    comments = data.get("comments", [])
    if not isinstance(comments, list):
        raise NotAReview("comments must be a list")
    for number, comment in enumerate(comments, 1):
        line = (
            comment.get("line", comment.get("position"))
            if isinstance(comment, dict)
            else None
        )
        if not (
            isinstance(comment, dict)
            and isinstance(comment.get("body"), str)
            and comment["body"].strip()
            and isinstance(comment.get("path"), str)
            and comment["path"]
            and isinstance(line, int)
            and not isinstance(line, bool)
        ):
            raise NotAReview(
                f"comment {number} needs a non-empty string body and path, "
                "and an integer line or position"
            )
    return {"event": event, "body": body, "commit_id": commit, "comments": comments}


def main():
    parser = ArgumentParser(
        prog="review-lint.py",
        description="Offline size and form check of a DRAFT pull request review: the JSON for "
        "gh api -X POST repos/O/R/pulls/N/reviews --input FILE (commit_id, event, body, comments "
        "with path, line, body). Comments prefixed blocking: count against no budget; nit: and "
        "unprefixed ones do. Whether a finding is right is not checked; posting stays a separate, "
        "human-approved step.",
        epilog="Exit codes: 0 size ok, 1 findings, 2 usage error or a draft that is not a review JSON "
        f"object, also one over {MAX_INPUT} characters.",
    )
    parser.add_argument(
        "file",
        nargs="?",
        metavar="FILE",
        help="file holding the review JSON, '-' for stdin (default: stdin)",
    )
    parser.add_argument(
        "--lines",
        type=int,
        required=True,
        metavar="N",
        help="changed lines of the pull request (additions + deletions)",
    )
    parser.add_argument(
        "--lib",
        action="store_true",
        help="the pull request changes files beyond tests/, data/ and schedule/: "
        "ceilings 2/4/5/8 instead of 3/5/4/4",
    )
    parser.add_argument(
        "--replies",
        type=int,
        default=0,
        metavar="N",
        help="thread replies posted beside the review; each counts as a non-blocking item",
    )
    parser.add_argument(
        "--late",
        action="store_true",
        help="the pull request is merged or has the approvals it needs: blocking comments only",
    )
    args = parser.parse_args()
    if args.lines < 0 or args.replies < 0:
        parser.error("--lines and --replies must not be negative")

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
        review = load(raw)
    except NotAReview as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    report, found = lint(
        review, args.lines, "lib" if args.lib else "tests", args.late, args.replies
    )
    print("\n".join(report))
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
