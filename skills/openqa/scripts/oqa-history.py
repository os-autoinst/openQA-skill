#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Scenario history of one openQA job: previous results, last good / first bad, failure rate, and the investigation summary.
"""History of a job's scenario from the "Next & previous results" data (GET only).

Route: GET /tests/<id>/ajax?previous_limit=N&next_limit=0
(lib/OpenQA/WebAPI.pm "job_next_previous_ajax", Controller/Test.pm). Without an
explicit previous_limit the server returns up to 500 rows. The rows cover jobs
of the same DISTRI, VERSION, FLAVOR, ARCH, TEST and MACHINE that are done and
not aborted (no skipped, obsoleted, parallel_failed, parallel_restarted,
user_cancelled, user_restarted), plus the current job and the latest job of
the scenario whatever their state (lib/OpenQA/Schema/Result/JobNextPrevious.pm).

Route: GET /tests/<id>/investigation_ajax (Controller/Test.pm "investigate",
lib/OpenQA/Schema/Result/Jobs.pm "investigate").
"""

import argparse
import re

import _oqa
import _secrets
from _sanitize import ArgumentParser

OK_RESULTS = _oqa.RESULT_GROUPS["ok"]
# Not-ok runs in a row from which a failure is called persistent rather than intermittent.
PERSISTENT_STREAK = 3

_SETTING = re.compile(r'^([+-])\s*"([^"]+)"\s*:\s*(.*?),?\s*$')
_COMMIT = re.compile(r"^[0-9a-f]{7,40} \S")
_NO_CHANGES = re.compile(r"^No (?:test|needle) changes recorded")
# Settings that differ between any two runs and say nothing about the failure.
_PER_RUN = re.compile(
    r"^(?:CHECKSUM_\w+|QEMUPORT|VNC|WORKER_ID|WORKER_INSTANCE|JOBTOKEN|NAME"
    r"|\w*_GIT_HASH|\w*_GIT_URL)$"
)


def positive(value):
    number = int(value)
    if not 1 <= number <= 200:
        raise argparse.ArgumentTypeError("must be between 1 and 200")
    return number


def bad(row):
    return row.get("result") not in OK_RESULTS


def build_of(row):
    return _oqa.tok(row.get("build"), 40)


def describe(rows, more):
    """rows: finished runs, newest first, rows[0] is the current job."""
    total, failed = len(rows), sum(bad(row) for row in rows)
    rate = f"not_ok={failed}/{total}" + (
        " (older runs exist: --previous N)" if more else ""
    )
    if not bad(rows[0]):
        return [rate, "hint: this job is ok"]

    streak = next((i for i, row in enumerate(rows) if not bad(row)), total)
    first_bad = rows[streak - 1]
    since = f"build {build_of(first_bad)}"
    if streak < total:
        good = rows[streak]
        last_good = (
            f"{good['id']} build={build_of(good)} result={_oqa.tok(good.get('result'))}"
        )
    else:
        last_good = "none"

    signature = sorted(rows[0].get("failedmodules") or ())
    alike = next(
        (
            i
            for i, row in enumerate(rows[:streak])
            if sorted(row.get("failedmodules") or ()) != signature
        ),
        streak,
    )
    if alike == streak:
        same = "same failed modules throughout"
    else:
        origin = rows[alike - 1]
        same = (
            f"failed modules CHANGE within the streak: the current ones go back only to "
            f"{origin['id']} build {build_of(origin)}, probably more than one issue"
        )
    builds = len({row.get("build") for row in rows[:streak]})
    earlier = failed - streak
    if streak == total:
        hint = f"always failing: no ok run in the last {total}; {same}"
    elif streak >= PERSISTENT_STREAK or (streak > 1 and not earlier):
        hint = f"failing since {since}: {streak} runs in a row over {builds} build(s); {same}"
        if earlier:
            hint += f"; {earlier} more not-ok run(s) before the last good one"
    elif earlier:
        hint = (
            f"intermittent: only {streak} not-ok in a row now; "
            f"look for a sporadic issue before blaming {since}"
        )
    else:
        hint = f"first failure: the {total - 1} previous runs were ok, new in {since}"
    return [
        f"last_good={last_good}",
        f"first_bad={first_bad['id']} build={build_of(first_bad)} streak={streak}",
        rate,
        f"hint: {hint}",
    ]


def history(client, job_id, previous):
    data = client.get_json(
        f"/tests/{job_id}/ajax", {"previous_limit": previous, "next_limit": 0}
    )
    rows = [
        row
        for row in data.get("data") or ()
        if isinstance(row, dict) and _oqa.job_id_of(row.get("id"))
    ]
    rows.sort(key=lambda row: row["id"], reverse=True)
    current = next((row for row in rows if row.get("iscurrent")), None)
    if current is None:
        raise _oqa.OqaError(f"job {job_id} is not part of the answer")
    older = [row for row in rows if row["id"] < job_id]
    more = len(older) > previous
    return current, [row for row in rows if row["id"] > job_id], older[:previous], more


def row_cells(row):
    comment_data = row.get("comment_data") or {}
    bugs = [
        bug.get("content")
        for bug in comment_data.get("bugs") or ()
        if isinstance(bug, dict)
    ]
    result = row.get("result") if row.get("state") == "done" else row.get("state")
    return (
        row["id"],
        row.get("build"),
        result,
        row.get("failedmodules") or None,
        bugs or None,
        comment_data.get("label"),
        row.get("clone"),
    )


def link_id(value):
    """last_good / first_bad are {type: link, link: /tests/<id>, text: <id>} or a string."""
    if isinstance(value, dict):
        return _oqa.clean(value.get("text"))
    return _oqa.quoted(value) if value is not None else "-"


def settings_diff(text, limit, verbose):
    """Fold the vars.json diff into 'KEY: old -> new' lines; BUILD first."""
    changes, other = {}, []
    for line in text.split("\n"):
        match = _SETTING.match(line)
        if match:
            sign, key, value = match.groups()
            changes.setdefault(key, {})[sign] = value.strip('"')
        elif line.strip():
            other.append(line)
    noise = [
        key
        for key, change in changes.items()
        if _PER_RUN.match(key) or change.get("-") == change.get("+")
    ]
    if not verbose:
        for key in noise:
            del changes[key]
    build = changes.get("BUILD", {})
    old, new = build.get("-"), build.get("+")
    follows = [
        key
        for key, change in changes.items()
        if key != "BUILD"
        and old
        and new
        and old in change.get("-", "")
        and change["-"].replace(old, new) == change.get("+")
    ]
    lines = [
        f"{key}: "
        + _secrets.setting_value(key, change.get("-"), _oqa.tok(change.get("-"), 100))
        + " -> "
        + _secrets.setting_value(key, change.get("+"), _oqa.tok(change.get("+"), 100))
        for key, change in sorted(changes.items(), key=lambda item: item[0] != "BUILD")
        if key not in follows
    ]
    lines += other
    omitted = max(len(lines) - limit, 0)
    lines = lines[:limit]
    if omitted:
        lines.append(f"[... {omitted} more changes omitted]")
    if follows:
        lines.append(f"[{len(follows)} more settings differ only by the BUILD value]")
    if noise and not verbose:
        lines.append(f"[{len(noise)} per-run settings left out (--verbose)]")
    return lines, "BUILD" in changes


def git_heads(text, limit):
    heads = [line for line in text.split("\n") if _COMMIT.match(line)]
    return heads[:limit], len(heads)


def fenced(client, job_id, title, lines):
    block = _oqa.sanitize("\n".join(lines), max_line=240, max_bytes=16384)
    source = f"{client.host.split('//')[1]}/tests/{job_id}/investigation_ajax:{title}"
    return _oqa.fence(block, source)


def investigation(client, job_id, limit, verbose):
    try:
        data = client.get_json(f"/tests/{job_id}/investigation_ajax")
    except _oqa.NotFound as error:
        print(f"investigation: not readable ({error})")
        return
    print("investigation:")
    if not isinstance(data, dict):
        print("  unexpected answer")
        return
    if data.get("error"):
        print(f"  server says: {_oqa.quoted(data['error'], 160)}")
        return
    print(
        f"  last_good={link_id(data.get('last_good'))} first_bad={link_id(data.get('first_bad'))}"
    )
    if not isinstance(data.get("last_good"), dict):
        print("  no last good job, so openQA has nothing to compare against")
        return
    first_bad = link_id(data.get("first_bad"))
    if first_bad.isdigit() and first_bad != str(job_id):
        print(
            f"  hint: the diffs end at THIS job; run on first_bad {first_bad} for the tight window"
        )

    diff = data.get("diff_to_last_good")
    if isinstance(diff, str) and diff.strip():
        lines, build_changed = settings_diff(diff, limit, verbose)
        verdict = "yes" if build_changed else "no (product regression unlikely)"
        print(f"  settings diff (last_good -> this job): build_changed={verdict}")
        print(fenced(client, job_id, "settings", lines), end="")
    else:
        print("  settings diff: not available")

    for key, title in (
        ("diff_packages_to_last_good", "worker packages"),
        ("diff_sut_packages_to_last_good", "SUT packages"),
    ):
        text = data.get(key)
        if not isinstance(text, str) or not text.strip() or "\n" not in text.strip():
            if verbose or "not available" not in str(text):
                print(f"  {title} diff: {_oqa.quoted(text, 120)}")
            continue
        lines = [
            line
            for line in text.split("\n")
            if line[:1] in "+-" and line[:3] not in ("+++", "---")
        ]
        omitted = max(len(lines) - limit, 0)
        print(f"  {title} diff: {len(lines)} changed lines")
        print(
            fenced(
                client,
                job_id,
                key,
                lines[:limit] + ([f"[... {omitted} more omitted]"] if omitted else []),
            ),
            end="",
        )

    for key, stat_key, title, url_key in (
        ("test_log", "test_diff_stat", "test", "testgiturl"),
        ("needles_log", "needles_diff_stat", "needle", "needlegiturl"),
    ):
        text = data.get(key)
        if not isinstance(text, str) or not text.strip():
            same = key == "needles_log" and isinstance(data.get("test_log"), str)
            print(
                f"  {title} changes: not reported"
                + (" (needles may share the test repository)" if same else "")
            )
            continue
        if _NO_CHANGES.match(text) or "\n" not in text.strip():
            print(f"  {title} changes: {_oqa.quoted(text, 160)}")
            continue
        heads, total = git_heads(text, limit)
        print(
            f"  {title} changes: commits={total} (newest first) url={_oqa.tok(data.get(url_key), 120)}"
        )
        stat = data.get(stat_key)
        if isinstance(stat, str) and stat.startswith("Too many commits"):
            print(f"  {title} diff stat: {_oqa.quoted(stat, 160)}")
        omitted = total - len(heads)
        print(
            fenced(
                client,
                job_id,
                key,
                heads + ([f"[... {omitted} more commits omitted]"] if omitted else []),
            ),
            end="",
        )


def main():
    parser = ArgumentParser(
        prog="oqa-history.py",
        description="Newest-first history of the scenario of one openQA job (same distri, version, "
        "flavor, arch, test and machine), with last good / first bad, the failure rate and a "
        "one-line classification hint. GET only, two requests at most.",
        epilog="Exit codes: 0 the history was produced (a failed job is the normal case), "
        "2 usage or runtime error; --exit-code: 1 when the job is not ok. Aborted runs (obsoleted, cancelled, parallel_failed, ...) "
        "never appear in the history; incomplete and timeout_exceeded runs do and count as "
        "not ok. The hint is a heuristic, not a verdict.",
    )
    parser.add_argument(
        "job",
        help="job id or job URL (a URL also selects the host, --host is then ignored)",
    )
    _oqa.add_common_args(parser)
    parser.add_argument(
        "--previous",
        type=positive,
        default=10,
        metavar="N",
        help="previous runs to look at, 1-200 (default: 10, the depth openQA uses for carry-over)",
    )
    parser.add_argument(
        "--investigation",
        action="store_true",
        help="add a capped summary of the investigation data: last good, first bad, "
        "changed settings, package diffs, test and needle commit subjects",
    )
    parser.add_argument(
        "--max-items",
        type=positive,
        default=10,
        metavar="N",
        help="--investigation: at most N lines per section (default: 10)",
    )
    parser.add_argument(
        "--exit-code",
        action="store_true",
        help="exit 1 when the job is not ok (default: exit 0 whenever the history was produced)",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="--investigation: keep per-run settings (checksums, ports, worker ids, git "
        "hashes) and 'not available' lines",
    )
    args = parser.parse_args()

    args.host, job_id = _oqa.parse_job_url(args.job, args.host)
    client = _oqa.client_from_args(args, "oqa-history", max_requests=4)
    current, newer, older, more = history(client, job_id, args.previous)

    scenario = "-".join(
        str(current.get(key) or "?")
        for key in ("distri", "version", "flavor", "arch", "test")
    )
    print(f"job={job_id} host={client.host} scenario={_oqa.tok(scenario, 160)}")
    rows = [row_cells(row) for row in [*newer, current, *older]]
    headers = (
        "id",
        "build",
        "result",
        "failed_modules",
        "bugrefs",
        "label",
        "clone",
    )
    print(_oqa.table(rows, headers, drop_empty=True), end="")
    if newer:
        print(f"note: {len(newer)} newer run(s) not counted, latest={newer[0]['id']}")

    status = 0
    if current.get("state") != "done":
        print(
            f"hint: job {job_id} is {_oqa.clean(current.get('state'))}, no result to classify yet"
        )
    else:
        finished = [current, *older]
        for line in describe(finished, more):
            print(line)
        status = 1 if bad(current) else 0
    if args.investigation:
        investigation(client, job_id, args.max_items, args.verbose)
    print(f"requests: {client.requests}")
    return status if args.exit_code else 0


if __name__ == "__main__":
    _oqa.run(main)
