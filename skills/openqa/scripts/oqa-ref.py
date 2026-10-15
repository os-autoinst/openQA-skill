#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# State of the ticket behind a bugref: one anonymous GET to a fixed tracker host, one compact line.
"""Look up a bugref (gh#owner/repo#n, boo#n, bsc#n, bnc#n, poo#n) or its tracker URL.

The host comes from TRACKERS below, never from the argument text or from a
response. Everything goes through _oqa.Client: GET only, no credentials, no
redirect to another host. "not accessible" is a final answer, not an error.
"""

import argparse
import os
import re
import sys

# python3 -I leaves the script's own directory off sys.path; the sibling modules live there.
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import _oqa
from _sanitize import ArgumentParser

# prefix -> (API host, web URL of a ticket); mirrors the bugref table of openQA.
TRACKERS = {
    "gh": ("https://api.github.com", "https://github.com/{repo}/{page}/{id}"),
    "boo": (
        "https://bugzilla.opensuse.org",
        "https://bugzilla.opensuse.org/show_bug.cgi?id={id}",
    ),
    "bsc": (
        "https://bugzilla.suse.com",
        "https://bugzilla.suse.com/show_bug.cgi?id={id}",
    ),
    "poo": (
        "https://progress.opensuse.org",
        "https://progress.opensuse.org/issues/{id}",
    ),
}
TRACKERS["bnc"] = TRACKERS["bsc"]

MAX_JSON_BYTES = 1024 * 1024
BODY_BYTES = 4000
BODY_LINE = 400
MAX_FILES = 100
MAX_NOTES = 10
NOTE_BYTES = 1500
NOTES_ELSEWHERE = "notes: only progress tickets (poo#) have them here; --notes ignored"
# An optional extra (a description, a file list) the tracker sent as junk or as too much.
UNREADABLE = object()

_ID = r"([0-9]{1,12})"
_REPO = r"([A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100})"
_REF = re.compile(rf"(gh)#{_REPO}#{_ID}|(boo|bsc|bnc|poo)#{_ID}")
_URLS = (
    (
        "gh",
        re.compile(rf"https://github\.com/{_REPO}/(?:issues|pull)/{_ID}(?:[/?#].*)?"),
    ),
    (
        "boo",
        re.compile(
            rf"https://bugzilla\.opensuse\.org/show_bug\.cgi\?id={_ID}(?:[&#].*)?"
        ),
    ),
    (
        "bsc",
        re.compile(rf"https://bugzilla\.suse\.com/show_bug\.cgi\?id={_ID}(?:[&#].*)?"),
    ),
    ("poo", re.compile(rf"https://progress\.opensuse\.org/issues/{_ID}(?:[/?#].*)?")),
)
_FILE_STATUS = ("added", "removed", "modified", "renamed", "copied", "changed")
_BUG_FIELDS = "id,summary,status,resolution,is_open,last_change_time,dupe_of"


def parse_ref(text):
    """Return (prefix, "owner/repo" or None, id) for a bugref or a tracker URL."""
    text = text.strip()
    match = _REF.fullmatch(text)
    if match:
        if match.group(1):
            return "gh", _repo(match.group(2)), int(match.group(3))
        return match.group(4), None, int(match.group(5))
    for prefix, pattern in _URLS:
        match = pattern.fullmatch(text)
        if match:
            groups = match.groups()
            return (
                prefix,
                _repo(groups[0]) if len(groups) > 1 else None,
                int(groups[-1]),
            )
    raise _oqa.OqaError(
        "not a supported bugref or tracker URL (gh#owner/repo#N, boo#N, bsc#N, bnc#N, "
        f"poo#N or the ticket URL on those trackers): {_oqa.clean(text)}"
    )


def _repo(repo):
    if repo.rpartition("/")[2] in (".", ".."):
        raise _oqa.OqaError(f"not a repository name: {_oqa.clean(repo)}")
    return repo


class Refused(Exception):
    """The tracker answered 401, 403 or 404 to the anonymous request."""


def _fetch(client, path, params=None, max_bytes=MAX_JSON_BYTES, shape=dict):
    try:
        data = client.get_json(path, params, max_bytes=max_bytes)
    except _oqa.NotFound:
        raise Refused(404) from None
    except _oqa.OqaError as error:
        refused = re.match(r"HTTP (401|403):", str(error))
        if not refused:
            raise
        raise Refused(int(refused.group(1))) from None
    if not isinstance(data, shape):
        raise _oqa.OqaError("the tracker answer has an unexpected shape")
    return data


def _field(data, *keys):
    for key in keys:
        data = data.get(key) if isinstance(data, dict) else None
    return data


def _text(value):
    return value if isinstance(value, str) else ""


def _yes(value):
    return "yes" if value else "no"


def github(client, repo, number):
    data = _fetch(client, f"/repos/{repo}/issues/{number}")
    pull = data.get("pull_request")
    fields = [("kind", "pr" if isinstance(pull, dict) else "issue")]
    fields.append(("state", data.get("state")))
    if _text(data.get("state_reason")):
        fields.append(("reason", data["state_reason"]))
    fields.append(("open", _yes(data.get("state") == "open")))
    if isinstance(pull, dict):
        fields.append(("merged", _yes(pull.get("merged_at"))))
        if pull.get("merged_at"):
            fields.append(("merged_at", pull["merged_at"]))
    fields += [("updated", data.get("updated_at")), ("title", data.get("title"))]
    return fields, _text(data.get("body"))


def bugzilla(client, number, want_body):
    data = _fetch(client, f"/rest/bug/{number}", {"include_fields": _BUG_FIELDS})
    bugs = data.get("bugs")
    bug = bugs[0] if isinstance(bugs, list) and bugs else None
    if not isinstance(bug, dict):
        raise _oqa.OqaError("the tracker answer has an unexpected shape (no bug)")
    state = _text(bug.get("status"))
    if _text(bug.get("resolution")):
        state += "/" + bug["resolution"]
    fields = [("kind", "bug"), ("state", state), ("open", _yes(bug.get("is_open")))]
    if _oqa.job_id_of(bug.get("dupe_of")):
        fields.append(("duplicate_of", bug["dupe_of"]))
    fields += [("updated", bug.get("last_change_time")), ("title", bug.get("summary"))]
    body = None
    if want_body:
        path = f"/rest/bug/{number}/comment"
        try:
            found = _fetch(
                client, path, {"include_fields": "text"}, _oqa.MAX_JSON_BYTES
            )
        except Refused:
            found = None
        except _oqa.OqaError:
            # The description is an extra: whoever wrote the bug must not be able
            # to take the digest away by making the comment list too big or broken.
            return fields, UNREADABLE
        comments = _field(found, "bugs", str(number), "comments")
        first = comments[0] if isinstance(comments, list) and comments else None
        body = _text(_field(first, "text"))
    return fields, body


def redmine(client, number, want_notes):
    """(fields, description, notes): notes are (created, text) of the non-empty
    journal notes, oldest first, UNREADABLE, or None when not asked for."""
    path, notes = f"/issues/{number}.json", None
    if want_notes:
        try:
            data = _fetch(client, path, {"include": "journals"}, _oqa.MAX_JSON_BYTES)
        except _oqa.OqaError:
            # The notes are an extra: a history too large or broken must not cost the digest.
            data, notes = _fetch(client, path), UNREADABLE
    else:
        data = _fetch(client, path)
    issue = data.get("issue")
    if not isinstance(issue, dict):
        raise _oqa.OqaError("the tracker answer has an unexpected shape (no issue)")
    closed = _field(issue, "status", "is_closed")
    fields = [("kind", "ticket"), ("state", _field(issue, "status", "name"))]
    if isinstance(closed, bool):
        fields.append(("open", _yes(not closed)))
    fields += [("updated", issue.get("updated_on")), ("title", issue.get("subject"))]
    if want_notes and notes is None:
        journals, notes = issue.get("journals"), UNREADABLE
        if isinstance(journals, list):
            notes = [
                (journal.get("created_on"), journal["notes"])
                for journal in journals
                if isinstance(journal, dict) and _text(journal.get("notes")).strip()
            ]
    return fields, _text(issue.get("description")), notes


def print_notes(notes, wanted, source):
    """The last notes with their dates, the author left out."""
    if notes is UNREADABLE:
        print("notes: not readable (the answer was too large, not JSON or had none)")
        return
    if not notes:
        print("notes: none")
        return
    shown = notes[-wanted:]
    print(f"notes: last {len(shown)} of {len(notes)}, oldest first")
    for created, text in shown:
        print(f"note created={_oqa.tok(created, 40)}")
        text = _oqa.sanitize(text, max_line=BODY_LINE, max_bytes=NOTE_BYTES)
        print(_oqa.fence(text, source), end="")


def pr_files(client, repo, number):
    path = f"/repos/{repo}/pulls/{number}/files"
    try:
        data = _fetch(client, path, {"per_page": MAX_FILES}, shape=list)
    except Refused:
        return ["files: not accessible"]
    except _oqa.OqaError:
        return ["files: not readable (the answer was too large or not JSON)"]
    rows = [
        f"{row.get('status') if row.get('status') in _FILE_STATUS else '?'} "
        f"{_oqa.tok(_text(row.get('filename')), 200)}"
        for row in data[:MAX_FILES]
        if isinstance(row, dict)
    ]
    more = (
        " (first page only, the pull request has more)"
        if len(data) >= MAX_FILES
        else ""
    )
    return [f"files={len(rows)}{more}", *rows]


def note_count(value):
    number = int(value)
    if not 1 <= number <= MAX_NOTES:
        raise argparse.ArgumentTypeError(f"must be 1 to {MAX_NOTES}")
    return number


def main():
    parser = ArgumentParser(
        prog="oqa-ref.py",
        description="State of the ticket behind a bugref: anonymous GET to the fixed host of "
        "that tracker (api.github.com, bugzilla.opensuse.org, bugzilla.suse.com, "
        "progress.opensuse.org), one line: ref kind state open merged updated title. "
        "'not-accessible' (private, missing or rate-limited) is a final answer: exit 0, "
        "do not retry and do not look for another way in. Exit 2 on usage or runtime error.",
    )
    parser.add_argument(
        "ref",
        help="gh#owner/repo#N, boo#N, bsc#N, bnc#N, poo#N, or the ticket URL on one of those trackers",
    )
    parser.add_argument(
        "--body",
        action="store_true",
        help=f"add the description, fenced and capped at {BODY_BYTES} bytes (Bugzilla: one more request)",
    )
    parser.add_argument(
        "--files",
        action="store_true",
        help=f"GitHub pull requests: list the changed files, at most {MAX_FILES} (one more request)",
    )
    parser.add_argument(
        "--notes",
        type=note_count,
        metavar="N",
        help=f"progress tickets: add the last N notes (1-{MAX_NOTES}) with their dates, "
        "fenced; same request",
    )
    # Offline tests only, like _oqa.add_common_args.
    parser.add_argument("--fixture-dir", metavar="DIR", help=argparse.SUPPRESS)
    args = parser.parse_args()

    prefix, repo, number = parse_ref(args.ref)
    host, web = TRACKERS[prefix]
    client = _oqa.Client(
        host, script="oqa-ref", fixture_dir=args.fixture_dir, max_requests=3
    )
    ref = f"gh#{repo}#{number}" if repo else f"{prefix}#{number}"
    try:
        if prefix == "gh":
            fields, body = github(client, repo, number)
        elif prefix == "poo":
            fields, body, notes = redmine(client, number, args.notes)
        else:
            fields, body = bugzilla(client, number, args.body)
    except Refused as refused:
        print(
            f"ref={ref} state=not-accessible http={refused} "
            "(private, missing or rate-limited for anonymous access; final answer, do not retry)"
        )
        if args.notes and prefix == "poo":
            login = "is missing or needs" if str(refused) == "404" else "needs"
            url = web.format(id=number)
            print(f"notes: the ticket {login} a login; the user can read it at {url}")
        elif args.notes:
            print(NOTES_ELSEWHERE)
        print(f"requests: {client.requests}")
        return 0

    is_pr = ("kind", "pr") in fields
    url = web.format(repo=repo, page="pull" if is_pr else "issues", id=number)
    shown = [
        f"{key}={_oqa.quoted(value, 120) if key == 'title' else _oqa.tok(value, 40)}"
        for key, value in fields
    ]
    print(f"ref={ref} {' '.join(shown)} url={url}")
    if args.body and body is UNREADABLE:
        print("body: not readable (the answer was too large or not JSON)")
    elif args.body:
        text = _oqa.sanitize(body or "", max_line=BODY_LINE, max_bytes=BODY_BYTES)
        if text.strip():
            print(_oqa.fence(text, url.partition("://")[2]), end="")
        else:
            print("body: empty")
    if args.files:
        lines = (
            pr_files(client, repo, number)
            if is_pr
            else ["files: only for GitHub pull requests"]
        )
        print("\n".join(lines))
    if args.notes and prefix == "poo":
        print_notes(notes, args.notes, url.partition("://")[2])
    elif args.notes:
        print(NOTES_ELSEWHERE)
    print(f"requests: {client.requests}")
    return 0


if __name__ == "__main__":
    _oqa.run(main)
