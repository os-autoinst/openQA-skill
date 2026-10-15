#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# What awaits my review on GitHub and what moved since my last review: read-only gh calls, one line per pull request.
"""List the open pull requests of a repository that ask for my review or moved since it.

Read-only `gh pr list` calls: review requested from me, reviewed by me, and the
newest open non-draft pull requests. My last review comes from `reviews`, because
`latestReviews` carries an empty commit. gh authenticates itself; no token passes
through this script.
"""

import json
import os
import re
import subprocess
import sys

# python3 -I leaves the script's own directory off sys.path; the sibling modules live there.
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from _sanitize import ArgumentParser, excerpt

DEFAULT_REPO = "os-autoinst/os-autoinst-distri-opensuse"
FIELDS = "number,title,isDraft,headRefOid,updatedAt,author,reviews"
SEARCH_LIMIT = 100
MAX_NEWEST = 100
MAX_ANSWER = 16 * 1024 * 1024
TITLE_CHARS = 120
_REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}")
_LOGIN = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}")
_OID = re.compile(r"[0-9a-f]{40}")
_BARE = re.compile(r"[\w.:#@/+%=-]+", re.ASCII)


class QueueError(Exception):
    pass


def gh(*args):
    try:
        done = subprocess.run(
            ["gh", *args],
            capture_output=True,
            check=False,
            timeout=300,
            env={**os.environ, "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"},
        )
    except FileNotFoundError:
        raise QueueError(
            "gh, the GitHub CLI, is not on PATH: this script reads GitHub only through it"
        ) from None
    except (OSError, subprocess.SubprocessError) as error:
        raise QueueError(
            f"gh {args[0]} {args[1]}: {excerpt(str(error), 200)}"
        ) from None
    if done.returncode:
        message = done.stderr.decode("utf-8", "replace").strip().split("\n")[0]
        raise QueueError(
            f"gh {args[0]} {args[1]} failed (exit {done.returncode}): "
            f"{excerpt(message, 200) or 'no message'}"
        )
    if len(done.stdout) > MAX_ANSWER:
        raise QueueError(f"gh {args[0]} {args[1]}: answer over {MAX_ANSWER} bytes")
    return done.stdout.decode("utf-8", "replace")


def pull_list(repo, what, *query):
    text = gh("pr", "list", "-R", repo, "--state", "open", *query, "--json", FIELDS)
    try:
        data = json.loads(text)
    except ValueError:
        raise QueueError(f"{what}: gh answered something that is not JSON") from None
    if not isinstance(data, list) or not all(
        isinstance(item, dict)
        and isinstance(item.get("number"), int)
        and not isinstance(item.get("number"), bool)
        for item in data
    ):
        raise QueueError(f"{what}: gh answered JSON of an unexpected shape")
    return data


def tok(value, limit=40):
    text = excerpt(value, limit) if isinstance(value, str) else ""
    if not text:
        return "?"
    return text if _BARE.fullmatch(text) else quoted(value, limit)


def quoted(value, limit=TITLE_CHARS):
    text = excerpt(value, limit) if isinstance(value, str) else ""
    return '"' + text.replace('"', "'") + '"'


def oid(value):
    return value if isinstance(value, str) and _OID.fullmatch(value) else None


def login_of(value):
    login = value.get("login") if isinstance(value, dict) else None
    return login if isinstance(login, str) else ""


def last_review(pull, me):
    """My newest submitted review: (state, commit or None, time), or None."""
    reviews = pull.get("reviews")
    best = None
    for review in reviews if isinstance(reviews, list) else ():
        if not isinstance(review, dict):
            continue
        # A pending review has no submittedAt.
        when = review.get("submittedAt")
        if (
            login_of(review.get("author")).lower() != me.lower()
            or not isinstance(when, str)
            or not when
        ):
            continue
        if best is None or when >= best[0]:
            commit = review.get("commit")
            best = (
                when,
                review.get("state"),
                oid(commit.get("oid") if isinstance(commit, dict) else None),
            )
    if best is None:
        return None
    return tok(best[1]).lower(), best[2], tok(best[0])


def main():
    parser = ArgumentParser(
        prog="pr-queue.py",
        description="What awaits my review: the open pull requests of a GitHub repository that "
        "request my review, that I reviewed, and the newest open non-draft ones, one line each "
        "with my last review's state and commit against the current head (moved=OLD..NEW, full "
        "commits, when the head changed since). Read-only gh calls; gh authenticates itself.",
        epilog="Exit codes: 0 the list was printed, 2 usage or runtime error (gh missing or "
        "failing, an answer that is not the expected JSON).",
    )
    parser.add_argument(
        "--repo",
        default=DEFAULT_REPO,
        metavar="O/R",
        help=f"owner/repository (default: {DEFAULT_REPO})",
    )
    parser.add_argument(
        "--newest",
        type=int,
        default=20,
        metavar="N",
        help=f"also list the N newest open non-draft pull requests, 0 = none, at most "
        f"{MAX_NEWEST} (default: 20)",
    )
    parser.add_argument(
        "--me",
        metavar="LOGIN",
        help="whose reviews count (default: the login gh is authenticated as)",
    )
    args = parser.parse_args()
    if not _REPO.fullmatch(args.repo) or args.repo.rpartition("/")[2] in (".", ".."):
        parser.error("--repo must be OWNER/REPOSITORY")
    if not 0 <= args.newest <= MAX_NEWEST:
        parser.error(f"--newest must be between 0 and {MAX_NEWEST}")
    if args.me is not None and not _LOGIN.fullmatch(args.me):
        parser.error("--me must be a GitHub login")

    try:
        me = args.me or gh("api", "user", "--jq", ".login").strip()
        if not _LOGIN.fullmatch(me):
            raise QueueError("gh api user returned no usable login")
        limit = str(SEARCH_LIMIT)
        requested = pull_list(
            args.repo,
            "requested",
            "--search",
            f"review-requested:{me}",
            "--limit",
            limit,
        )
        reviewed = pull_list(
            args.repo, "reviewed", "--search", f"reviewed-by:{me}", "--limit", limit
        )
        newest = []
        if args.newest:
            newest = pull_list(
                args.repo,
                "newest",
                "--search",
                "draft:false",
                "--limit",
                str(args.newest),
            )
    except QueueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    pulls = {}
    for pull in [*requested, *reviewed, *newest]:
        pulls.setdefault(pull["number"], pull)
    asked = {pull["number"] for pull in requested}
    rows = []
    counts = {"requested": 0, "reviewed": 0, "moved": 0, "drafts": 0}
    for number, pull in pulls.items():
        head = oid(pull.get("headRefOid"))
        mine = last_review(pull, me)
        moved = mine and mine[1] and head and mine[1] != head
        draft = pull.get("isDraft") is True
        fields = [
            f"pr={number}",
            f"draft={'yes' if draft else 'no'}",
            f"requested={'yes' if number in asked else 'no'}",
            f"author={tok(login_of(pull.get('author')))}",
        ]
        if mine:
            fields.append(f"review={mine[0]}@{mine[1][:7] if mine[1] else '?'}")
            fields.append(f"reviewed_at={mine[2]}")
        fields.append(f"head={head[:7] if head else '?'}")
        if moved:
            fields.append(f"moved={mine[1]}..{head}")
        fields.append(f"title={quoted(pull.get('title'))}")
        counts["requested"] += number in asked
        counts["reviewed"] += bool(mine)
        counts["moved"] += bool(moved)
        counts["drafts"] += draft
        updated = pull.get("updatedAt")
        rows.append(
            (
                number in asked,
                bool(moved),
                updated if isinstance(updated, str) else "",
                " ".join(fields),
            )
        )
    # Requested first, then moved, then the rest; newest update first within each.
    rows.sort(key=lambda row: row[:3], reverse=True)
    for row in rows:
        print(row[3])
    for what, found in (("requested", requested), ("reviewed", reviewed)):
        if len(found) >= SEARCH_LIMIT:
            print(f"note: the {what} list stops at {SEARCH_LIMIT} pull requests")
    print(
        f"summary: repo={args.repo} me={me} prs={len(rows)} "
        + " ".join(f"{key}={value}" for key, value in counts.items())
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
