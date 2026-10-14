#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Offline check of a drafted pull request review against references/pr-reviewing.md "Review size", "Form".
"""Check a drafted review (the JSON for POST /repos/O/R/pulls/N/reviews) for size and form.

No network access. Whether a finding is right is not checked, only whether the
draft stays inside the budget and the form of references/pr-reviewing.md.
"""

import itertools
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

# Wording, pr-reviewing.md "Form". A line starting a list item, heading or table row starts a new block.
BLOCK_START = re.compile(r"\s*(?:[-*+]\s|\d{1,9}[.)]\s|#{1,6}\s|\|)")
NIT = re.compile(r"\s*(?:[-*+]\s+|\d{1,9}[.)]\s+)?nit:", re.IGNORECASE)
TICKS = re.compile(r"`+")
CODE = "\x1a"
# A link or image, an HTML anchor, or a [label] alone, which links only when a definition names it.
LINK = re.compile(
    r"!?\[([^\[\]\n]*)\](\([^()\n]*\)|\[[^\[\]\n]*\])?|<a\s[^<>\n]*>([^<\n]*)</a>",
    re.IGNORECASE,
)
# CommonMark: link reference definitions open a paragraph, and GitHub shows none of them.
DEFINITION = re.compile(r" {0,3}\[([^\[\]\n]+)\]:[ \t]*\S")
# A URL without the punctuation that ends the sentence around it.
URL_TEXT = re.compile(r"https?://\S*[^\s.,;:!?)\]\"']")
MAX_WORDS = 30
SENTENCE_END = re.compile(
    r"(?<=[.!?])(?<!\be\.g\.)(?<!\bi\.e\.)(?<!\bvs\.)[)\]\"']*\s+", re.IGNORECASE
)
WORD = re.compile(r"[\w" + CODE + "]")
DIGITS = re.compile(r"\d{6,}")
# A number glued to a path, version, setting or reference is not an id, nor is a size or a duration.
NOT_BEFORE = r"(?<![\w.\-/#:@=])"
ID_RANGE = re.compile(NOT_BEFORE + r"\d{6,}(?:/\d{1,4})+(?![\w/])")
BARE_ID = re.compile(
    NOT_BEFORE + r"\d{6,}(?![\w/\-]|[.,]\w|\s?(?:(?:[kKMGT]i?)?B\b|bytes?\b|ms\b|%))"
)
# A build or snapshot date, 20YYMMDD.
DATE = re.compile(r"20[1-3]\d(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])")
ONLY_IDS = re.compile(r"\s*\d{6,}(?:/\d{1,4})*\s*")
# lib/OpenQA/Utils.pm, %BUGREFS. GitHub links none of them; gh#owner/repo#n and the
# other project trackers end in a reference GitHub links itself.
PROJECT_TRACKERS = ("gh", "kdi", "pio", "ggo", "gfs", "ffo")
TRACKERS = ("bnc", "bsc", "boo", "bgo", "bmo", "brc", "bko", "poo", "kde", "fdo", "jsc")
TRACKERS += PROJECT_TRACKERS
PLAIN_REF = re.compile(
    r"(?<![\w/])(?:"
    + "|".join(t for t in TRACKERS if t not in PROJECT_TRACKERS)
    + r")#(?:[A-Z]+-)?\d+",
    re.IGNORECASE,
)
# GitHub resolves no repository from name#n and links it only when name is an existing account, so
# any name an account could have is reported: letters, digits, hyphens.
CROSS_REPO = re.compile(r"(?<![\w/.\-#])([A-Za-z0-9][A-Za-z0-9-]*)#\d+\b")
JARGON = (
    (re.compile(r"\bVRs?\b"), '"verification run"'),
    (
        re.compile(r"\b(?:at|on|this|the)\s+head\b", re.IGNORECASE),
        '"the latest commit of this PR, `<hash>`"',
    ),
)
# A star touching a path or file-name character, unless escaped; ".*" is left out, as "**Note.**" ends that way.
GLOB = re.compile(r"[_/]\*|(?<!\\)\*[._/]|\w\*\w")
WORDING = ("bare-id", "id-range", "cross-repo", "plain-ref", "jargon", "glob")
STUB_WORDS = 8
STUB = {"inline", "below", "comments", "attached"}


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
    """Return (prose lines, prose blocks as lists of lines, code blocks as (info, lines, chars,
    closed), quoted lines, quoted chars).

    A prose block is a paragraph, list item, heading, table row or a line opening with nit:
    (GitHub keeps the line break); a blank line, a fence or a quote ends it, and a line
    holding only a URL stays in it.
    """
    prose, paragraphs, blocks, quote_lines, quote_chars = [], [[]], [], 0, 0
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
            paragraphs.append([])
        elif line.lstrip().startswith(">"):
            content = line.lstrip()[1:].strip()
            if content:
                quote_lines += 1
                quote_chars += length(content)
            paragraphs.append([])
        elif URL.sub("", line).strip():
            prose.append(URL.sub("", line))
            if BLOCK_START.match(visible(line)) or NIT.match(visible(line)):
                paragraphs.append([])
            paragraphs[-1].append(line)
        elif line.strip():
            paragraphs[-1].append(line)
        else:
            paragraphs.append([])
    if fence:
        blocks.append((fence[1], fence[2], fence[3], False))
    paragraphs = [p for p in paragraphs if any(URL.sub("", line).strip() for line in p)]
    return prose, paragraphs, blocks, quote_lines, quote_chars


def code_spans(text):
    """Return text with each code span replaced by CODE, and the spans' contents.

    CommonMark: a run of n backticks opens a span that the next run of exactly n closes; a run
    with no such run after it is plain text. Each run is visited once.
    """
    runs = [(m.start(), m.end()) for m in TICKS.finditer(text)]
    by_size = {}
    for index, (start, end) in enumerate(runs):
        by_size.setdefault(end - start, []).append(index)
    seen = dict.fromkeys(by_size, 0)
    out, contents, done, index = [], [], 0, 0
    while index < len(runs):
        start, end = runs[index]
        same = by_size[end - start]
        at = seen[end - start]
        while at < len(same) and same[at] <= index:
            at += 1
        seen[end - start] = at
        if at == len(same):
            index += 1
            continue
        closing = runs[same[at]]
        out += [text[done:start], CODE]
        contents.append(text[end : closing[0]])
        done = closing[1]
        index = same[at] + 1
    out.append(text[done:])
    return "".join(out), contents


def sentences(text):
    """Sentences of a prose block: split at a line break, which GitHub keeps in a comment, and after
    . ! or ? and a space, not after e.g., i.e. or vs.; a code span is one word."""
    for line in text.split("\n"):
        for sentence in SENTENCE_END.split(" ".join(line.split())):
            words = [w for w in sentence.split() if WORD.search(w)]
            if words:
                yield sentence, len(words)


def strip_links(text, labels, keep):
    """text with each link, anchor and defined [label] replaced by its text with keep, else by a blank."""

    def replace(link):
        if link.group(3) is not None:
            return link.group(3) if keep else " "
        if (
            link.group(2) is None
            and " ".join(link.group(1).split()).lower() not in labels
        ):
            return link.group()
        return link.group(1) if keep else " "

    return LINK.sub(replace, text)


def wording(paragraphs, body):
    """Return [(finding id, detail)], at most one per id, for pr-reviewing.md "Form"."""
    hits = {}

    def hit(check, token, fix):
        if (check, fix) in hits:
            hits[check, fix][1] += 1
        else:
            hits[check, fix] = [token.replace(CODE, "`...`"), 1]

    labels, prose = set(), []
    for lines in paragraphs:
        defined = list(
            itertools.takewhile(bool, (DEFINITION.match(visible(x)) for x in lines))
        )
        labels.update(" ".join(d.group(1).split()).lower() for d in defined)
        prose.append(lines[len(defined) :])

    long, longest, words = 0, None, []
    for lines in prose:
        text, contents = code_spans(visible("\n".join(lines)))
        # An id is linked when a URL of the same paragraph holds it.
        linked = set(DIGITS.findall(" ".join(URL_TEXT.findall(text))))
        for content in contents:
            if ONLY_IDS.fullmatch(content) and content.strip() not in linked:
                check = "id-range" if "/" in content else "bare-id"
                hit(check, content.strip(), "")
        unlinked = URL_TEXT.sub(" ", strip_links(text, labels, False))
        for match in ID_RANGE.finditer(unlinked):
            hit("id-range", match.group(), "")
        for match in BARE_ID.finditer(ID_RANGE.sub(" ", unlinked)):
            if match.group() not in linked and not (
                len(match.group()) == 8 and DATE.fullmatch(match.group())
            ):
                hit("bare-id", match.group(), "")
        for match in CROSS_REPO.finditer(unlinked):
            if match.group(1).lower() not in TRACKERS:
                hit("cross-repo", match.group(), "")
        for match in PLAIN_REF.finditer(unlinked):
            hit("plain-ref", match.group(), "")
        readable = URL_TEXT.sub("", strip_links(text, labels, True))
        for pattern, fix in JARGON:
            for match in pattern.finditer(readable):
                hit("jargon", match.group(), fix)
        for token in readable.split():
            if GLOB.search(token.strip("([{\"'").rstrip(".,;:!?)]}\"'")):
                hit("glob", token, "")
        words += readable.lower().split()
        for sentence, count in sentences(readable):
            if count > MAX_WORDS:
                long += 1
                if not longest or count > longest[1]:
                    longest = (sentence, count)

    found = []
    for (check, fix), (token, count) in sorted(
        hits.items(), key=lambda entry: WORDING.index(entry[0][0])
    ):
        more = f" and {count - 1} more" if count > 1 else ""
        token = quoted(token, 60)
        detail = {
            "bare-id": f"{token}{more} is a bare number; write each job as its full URL "
            "(https://<host>/tests/<id>), a bug or ticket as a link",
            "id-range": f"{token}{more} shortens job ids; write each job as its full URL",
            "cross-repo": f"{token}{more}: GitHub resolves no repository from it; "
            "write owner/repo#<n>, or #<n> for this one",
            "plain-ref": f"{token}{more} stays plain text on GitHub; write it as a link",
            "jargon": f"{token}{more} is shorthand; write {fix}",
            "glob": f"{token}{more} can turn into italics; put file names and globs in backticks",
        }[check]
        found.append((check, detail))
    if long:
        sample = quoted(longest[0].replace(CODE, "`...`"), 60)
        detail = (
            f"{long} sentence{'s' if long > 1 else ''} over {MAX_WORDS} words, "
            f"the longest {longest[1]} ({sample}); split it, one statement per sentence"
        )
        found.append(("long-sentence", detail))
    plain = re.findall(r"[a-z]+", " ".join(words))
    if body and 0 < len(plain) <= STUB_WORDS and STUB.intersection(plain):
        found.append(
            ("stub-body", "it only points at the inline comments; leave the body empty")
        )
    return found


def item(where, text, body=False):
    prose, paragraphs, blocks, quote_lines, quote_chars = parts(text)
    head = visible(text).lstrip()
    prefix = PREFIX.match(head)
    # The prefix after a quote or a code block: GitHub shows it, the budget does not see it.
    later = (
        not prefix and bool(prose) and bool(PREFIX.match(visible(prose[0]).lstrip()))
    )
    # A nit: opening any prose block is a nit of its own: (block number, chars, lines).
    nits = []
    for number, lines in enumerate(paragraphs, 1):
        if NIT.match(visible(lines[0])):
            text_lines = [
                URL.sub("", line) for line in lines if URL.sub("", line).strip()
            ]
            nits.append(
                (
                    number,
                    length(" ".join(" ".join(text_lines).split())),
                    len(text_lines),
                )
            )
    return {
        "where": where,
        "text": text,
        "kind": prefix.group(1).lower() if prefix else "",
        "near": not prefix and (later or bool(NEAR.match(head))),
        "prose": length(" ".join(" ".join(prose).split())),
        "nits": nits,
        "only_nits": bool(nits) and len(nits) == len(paragraphs),
        "wording": wording(paragraphs, body),
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
        items.append(item("body", review["body"], body=bool(review["comments"])))
    for number, comment in enumerate(review["comments"], 1):
        line = comment.get("line", comment.get("position"))
        place = quoted(f"{comment['path']}:{line}", 120)
        items.append(item(f"comment {number} {place}", comment["body"]))
    body = items[0] if items and items[0]["where"] == "body" else None
    comments = [x for x in items if x is not body]
    counted = [x for x in items if x["kind"] != "blocking"]
    nit_count = sum(len(x["nits"]) for x in items)
    blocking = [x for x in items if x["kind"] == "blocking"]
    requests = [x for x in comments if x["kind"] == "" and not x["only_nits"]]
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
    if nit_count > MAX_NITS:
        found.append(f"nits review: {nit_count} nits, at most {MAX_NITS}")
    long_nit = (
        f"a nit is one line of at most {PROSE['nit']} chars, prefix included; "
        "a longer one is a change request or nothing"
    )
    for x in items:
        if x["kind"] == "nit":
            # Each line opening with nit: is a nit of its own; prose that is no nit lengthens the first.
            if not x["only_nits"] or any(
                nit_chars > PROSE["nit"] or nit_lines > 1
                for _, nit_chars, nit_lines in x["nits"]
            ):
                found.append(f"long-nit {x['where']}: {long_nit}")
            continue
        for number, nit_chars, nit_lines in x["nits"]:
            if nit_chars > PROSE["nit"] or nit_lines > 1:
                found.append(f"long-nit {x['where']} paragraph {number}: {long_nit}")
    if nit_count and not requests and not blocking:
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
        found += [f"{check} {x['where']}: {detail}" for check, detail in x["wording"]]
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
            f"blocking {len(blocking)}, nit {nit_count}, non-blocking prose {prose} chars"
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
        description="Offline size, form and wording check of a DRAFT pull request review: the JSON for "
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
