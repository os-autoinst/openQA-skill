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

A row's start is its "finished" less its "duration", which Plugin/Helpers.pm
"_format_time_duration" writes as "MM:SS minutes", "HH:MM hours" or "D days HH:MM hours";
a run still going has neither.

Route: GET /api/v1/jobs?ids=<id>,<id>,... (Controller/API/V1/Job.pm "list",
Schema/Result/Jobs.pm "to_hash"): t_started, t_finished and assigned_worker_id of
the rows, and their modules ordered by id, which is the order they were scheduled in.
Read only with --workers or --investigation, and with --before for the runs still going.

Route: GET /api/v1/workers/<id> (Controller/API/V1/Worker.pm "show"): host and instance.

Route: GET /api/v1/jobs/<id>/comments (Controller/API/V1/Comment.pm "list"): bugrefs and
created of each comment; the table's bugrefs and label follow
Schema/ResultSet/Comments.pm "comment_data_for_jobs".

Route: GET /tests/<id>/downloads_ajax, /tests/<id>/file/<name> and
/tests/<id>/file/details-<module>.json (Controller/Test.pm "downloads", Controller/File.pm
"test_file"): uploaded package lists, and the steps of a module with their text.
"""

import argparse
import os
import posixpath
import re
import sys
from datetime import datetime, timedelta, timezone

# python3 -I leaves the script's own directory off sys.path; the sibling modules live there.
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import _oqa
import _secrets
from _sanitize import ArgumentParser

OK_RESULTS = _oqa.RESULT_GROUPS["ok"]
# Not-ok runs in a row from which a failure is called persistent rather than intermittent.
PERSISTENT_STREAK = 3
# Runs after the job read with --before, the nearest first.
NEXT_BEFORE = 20
# A job's module list is part of each row of /api/v1/jobs: LTP jobs take ~130 kB each.
IDS_PER_REQUEST = 25
MAX_WORKERS = 20
MAX_COMMENT_JOBS = 30
MAX_REQUESTS = 80
DETAILS_BYTES = 4 << 20
LIST_BYTES = 512 << 10
# Uploaded package lists, by preference: rpm -qa (lib/LTP/utils.pm log_versions), xfstests'
# version.log, rpm -qi of the kernel.
VERSION_SOURCES = (
    re.compile(r"(?:^|-)rpm-qa\.txt$"),
    re.compile(r"(?:^|-)version\.log$"),
    re.compile(r"(?:^|-)kernel-pkg\.txt$"),
)
KERNEL_PACKAGE = re.compile(
    r"kernel-(?:default|rt|64kb|azure|kvmsmall|vanilla|pae|longterm|zfcpdump|lpae)(?:-base)?"
)
SUITE_PACKAGES = ("ltp", "ltp-stable", "blktests", "xfstests", "kirk")
ARCHS = ("x86_64", "aarch64", "ppc64le", "s390x", "noarch", "i586", "i686", "riscv64")

_SETTING = re.compile(r'^([+-])\s*"([^"]+)"\s*:\s*(.*?),?\s*$')
# A commit with an empty subject is printed as "<hash> " with nothing after it.
_COMMIT = re.compile(r"^[0-9a-f]{7,40}(?: |$)")
# git log --stat: " <path> | <n> +-"; a rename shows as "dir/{old => new}/file".
_STAT = re.compile(r"^ (\S[^|\n]{0,400}?) +\| ")
_NO_CHANGES = re.compile(r"^No (?:test|needle) changes recorded")
_TOO_MANY = re.compile(r"Too many commits \((\d{1,9})\) .*\(maximum: (\d{1,9})\)$")
# Settings that differ between any two runs and say nothing about the failure.
_PER_RUN = re.compile(
    r"^(?:CHECKSUM_\w+|QEMUPORT|VNC|WORKER_ID|WORKER_INSTANCE|JOBTOKEN|NAME"
    r"|\w*_GIT_HASH|\w*_GIT_URL)$"
)
# A frame of a step's stack trace, "... called at lib/utils.pm line 12"; os-autoinst's and
# Perl's own frames are not test code.
_FRAME = re.compile(r"\bat (\S{1,400}) line \d+")
_NOT_DISTRI = re.compile(r"^\(|^/usr/|/os-autoinst/|/perl5/")
# A checkout in a directory named after the distri gives "sle/lib/x.pm": the repository path
# starts at the first of a test distribution's top-level directories.
_REPO_PATH = re.compile(r"(?:^|/)((?:lib|tests|products|data)/.+)")
_RENAME = re.compile(r"^(.*)\{(.*) => (.*)\}(.*)$")
# os-autoinst script/isotovideo "_get_version_string", logged in the setup notes, within the
# first 30 kB of autoinst-log.txt on o3.
_ISOTOVIDEO = re.compile(r"Current version is ([\w.+~-]{1,80}) \[interface v\d{1,4}\]")
HEAD_BYTES = 64 << 10
_QI_FIELD = re.compile(r"^(Name|Version|Release)\s*:\s*(\S+)$")
_PACKAGE_LINE = re.compile(r"[A-Za-z0-9_.+~^-]+")
# The downloads tab links the "#" of a module loaded twice as "%23": generate_report%231-dmesg.txt.
_UPLOAD_NAME = r"[A-Za-z0-9_](?:[A-Za-z0-9._+@=~-]|%23)*"
_DURATION = re.compile(r"(?:(\d{1,5}) days )?(\d{1,5}):(\d\d) (hours|minutes)")
INVESTIGATE_CLONES = "Automatic investigation jobs for job"
# As oqa-job.py INVESTIGATE_CLONE: "* *<name>*: t#<id>", older revisions bold with a URL.
_CLONE = re.compile(
    r"\s*\*\s+\*{1,2}([^*\s]+)\*{1,2}:\s*(?:t#|https?://[^/\s]+/(?:tests/|t))([0-9]{1,18})(?![0-9])"
)
# lib/OpenQA/Utils.pm LABEL_REGEX; Schema/Result/Comments.pm "force_result"
_LABEL = re.compile(r"\blabel:([\w:#/-]+)\b")
_FORCE_RESULT = re.compile(r"force_result:(\w+)")


def positive(value):
    number = int(value)
    if not 1 <= number <= 200:
        raise argparse.ArgumentTypeError("must be between 1 and 200")
    return number


def parse_time(value):
    """An aware UTC datetime from ISO 8601 or openQA's "2030-01-02 10:00:00 +0000", or None;
    a time without a zone is UTC, as openQA's t_started is."""
    if not isinstance(value, str):
        return None
    text = re.sub(r"[zZ]$", "+00:00", value.strip())
    text = re.sub(r" ?([+-]\d\d):?(\d\d)$", r"\1:\2", text)
    try:
        stamp = datetime.fromisoformat(text)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(timezone.utc)


def before_time(value):
    stamp = parse_time(value)
    if stamp is None:
        raise argparse.ArgumentTypeError(
            "expected an ISO 8601 time such as 2030-01-02T10:00Z"
        )
    return stamp


def bad(row):
    return row.get("result") not in OK_RESULTS


def build_of(row):
    return _oqa.tok(row.get("build"), 40)


def failed_set(row):
    return {str(name) for name in row.get("failedmodules") or ()}


def module_cell(names, width=60):
    """The failed modules sorted, as many as fit the table's column, then "+<n>" for the rest:
    openQA lists them in the order their results were stored, which varies between calls."""
    names = sorted(_oqa.clean(name, width) for name in names or ())
    shown, cell = len(names), ",".join(names)
    while len(cell) > width and shown > 1:
        shown -= 1
        cell = ",".join([*names[:shown], f"+{len(names) - shown}"])
    if len(cell) > width:
        rest = f",+{len(names) - 1}"
        cell = _oqa.clean(names[0], width - len(rest)) + rest
    return cell or None


def one_machine(rows, machines):
    """The worker every not-ok run ran on, when every run there was not ok and every run
    elsewhere ok; None otherwise or without the workers."""
    places = {machines.get(row["id"]) for row in rows if bad(row)}
    if len(places) != 1 or None in places:
        return None
    (place,) = places
    known = [row for row in rows if machines.get(row["id"])]
    alone = all(bad(row) == (machines[row["id"]] == place) for row in known)
    return (
        place if alone and any(machines[row["id"]] != place for row in known) else None
    )


def describe(rows, more, machines=None):
    """rows: finished runs, newest first, rows[0] is the current job; machines: {id: worker}
    when the workers were read."""
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

    signature = failed_set(rows[0])

    def holds(row):
        # A module that failed in older runs only, softfailing, passing or not reached
        # now, does not move where the current failures start.
        failed = failed_set(row)
        return failed == signature or bool(signature) and failed > signature

    alike = next((i for i, row in enumerate(rows[:streak]) if not holds(row)), streak)
    also = sorted(set().union(*map(failed_set, rows[:alike])) - signature)
    if alike == streak:
        same = "the current failed modules" if also else "same failed modules"
        same += " throughout"
    else:
        origin = rows[alike - 1]
        same = (
            f"failed modules CHANGE within the streak: the current ones go back only to "
            f"{origin['id']} build {build_of(origin)}, probably more than one issue"
        )
    if also:
        same += f", older runs also failed {_oqa.toks(also, 60, 4)}"
    builds = len({row.get("build") for row in rows[:streak]})
    earlier = failed - streak
    if streak == total:
        hint = f"always failing: no ok run in the last {total}; {same}"
    elif streak >= PERSISTENT_STREAK or (streak > 1 and not earlier):
        hint = f"failing since {since}: {streak} runs in a row over {builds} build(s); {same}"
        if earlier:
            hint += f"; {earlier} more not-ok run(s) before the last good one"
    elif earlier and all(
        bad(row) == (row.get("build") == rows[0].get("build")) for row in rows
    ):
        # Runs of two builds interleaved: deterministic per build, as with a missing asset.
        hint = (
            f"every run of build {build_of(rows[0])} failed; "
            f"last good on build {build_of(rows[streak])}"
        )
    elif earlier and (place := one_machine(rows, machines or {})):
        hint = (
            f"bound to one machine: every run on {place} failed, every run on the other "
            "workers was ok"
        )
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


def history(client, job_id, previous, following=0):
    """following: how many runs after the job to ask for, the nearest first; openQA adds the
    latest run whatever this is."""
    data = client.get_json(
        f"/tests/{job_id}/ajax", {"previous_limit": previous, "next_limit": following}
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


def run_details(client, ids):
    """{id: job} of /api/v1/jobs for the rows, or None when the list cannot be read; the
    chunks read before one that fails are kept."""
    found = {}
    for start in range(0, len(ids), IDS_PER_REQUEST):
        chunk = ",".join(str(job_id) for job_id in ids[start : start + IDS_PER_REQUEST])
        try:
            data = client.get_json("/api/v1/jobs", {"ids": chunk})
        except _oqa.OqaError:
            break
        jobs = data.get("jobs") if isinstance(data, dict) else None
        if not isinstance(jobs, list):
            break
        for job in jobs:
            if isinstance(job, dict) and _oqa.job_id_of(job.get("id")) in ids:
                found[job["id"]] = job
    else:
        return found
    return found or None


def row_times(row, runs):
    """(started, finished) of a history row: finished less duration, else the start
    /api/v1/jobs gives in runs; None for what is unknown."""
    finished = parse_time(row.get("finished"))
    match = _DURATION.fullmatch(str(row.get("duration") or ""))
    if finished and match:
        days, high, low, unit = match.groups()
        if unit == "hours":
            spent = timedelta(days=int(days or 0), hours=int(high), minutes=int(low))
        else:
            spent = timedelta(minutes=int(high), seconds=int(low))
        return finished - spent, finished
    job = (runs or {}).get(row["id"]) or {}
    return parse_time(job.get("t_started")), finished or parse_time(
        job.get("t_finished")
    )


def as_of(before, runs, current, newer, older):
    """The rows as they stood at `before`: a run that started later is cut, one still going
    then shows as running. Returns (current, newer, older, number cut)."""
    if not all(
        row.get("finished") or (runs or {}).get(row["id"])
        for row in (current, *newer, *older)
    ):
        raise _oqa.OqaError(
            "--before needs the start times of the runs still going; /api/v1/jobs could "
            "not be read"
        )

    def then(row):
        started, finished = row_times(row, runs)
        started = started or finished
        if started is None or started > before:
            return None
        if row.get("state") == "done" and (finished is None or finished > before):
            return {**row, "state": "running", "result": None, "failedmodules": []}
        return row

    shown = then(current)
    if shown is None:
        raise _oqa.OqaError(f"job {current['id']} had not started by --before")
    newer_then = [row for row in map(then, newer) if row]
    older_then = [row for row in map(then, older) if row]
    cut = len(newer) + len(older) - len(newer_then) - len(older_then)
    # A restart that is not a run kept here may not have existed yet.
    kept = {row["id"] for row in (shown, *newer_then, *older_then)}
    shown, newer_then, older_then = (
        [row if row.get("clone") in kept else {**row, "clone": None} for row in rows]
        for rows in ([shown], newer_then, older_then)
    )
    return shown[0], newer_then, older_then, cut


def has_reference(row):
    data = row.get("comment_data")
    return isinstance(data, dict) and bool(data.get("bugs") or data.get("label"))


def comments_as_of(client, before, rows):
    """{id: (bugrefs, label)} from the comments created by `before`, for the rows that carry
    a bugref or a label now; "?" for those not read. Also the number of later comments that
    carried one, and {id: result then} of the finished rows whose result a later
    label:force_result comment changed."""
    found, later, forced = {}, 0, {}
    for count, row in enumerate(row for row in rows if has_reference(row)):
        comments = None
        if count < MAX_COMMENT_JOBS:
            try:
                comments = client.get_json(f"/api/v1/jobs/{row['id']}/comments")
            except _oqa.OqaError:
                pass
        if not isinstance(comments, list):
            found[row["id"]] = ("?", "?")
            continue
        bugs, label, then, changed = [], None, None, False
        comments = [c for c in comments if isinstance(c, dict)]
        for comment in sorted(comments, key=lambda c: _oqa.job_id_of(c.get("id")) or 0):
            refs = comment.get("bugrefs")
            refs = [str(ref) for ref in refs] if isinstance(refs, list) else []
            labels = _LABEL.findall(str(comment.get("text") or ""))
            created = parse_time(comment.get("created"))
            force = next(filter(None, map(_FORCE_RESULT.match, labels)), None)
            if created is None or created > before:
                later += bool(refs or labels)
                changed = changed or bool(force)
                continue
            if force:
                then = force.group(1)
            if refs:
                bugs += [ref for ref in refs if ref not in bugs]
            elif labels:
                label = labels[0]
        found[row["id"]] = (sorted(bugs) or None, label)
        if changed and row.get("state") == "done":
            # openQA keeps no result from before a force: failed modules still say "failed".
            forced[row["id"]] = then or ("failed" if row.get("failedmodules") else "?")
    return found, later, forced


def investigate_jobs(client, job_id, before=None):
    """ "<suffix> t#<id>" of the clones openqa-investigate listed in the job's comments, those
    created by `before` when given; None when the comments cannot be read."""
    try:
        comments = client.get_json(f"/api/v1/jobs/{job_id}/comments")
    except _oqa.OqaError:
        return None
    clones = []
    for comment in comments if isinstance(comments, list) else ():
        if not isinstance(comment, dict):
            continue
        created = parse_time(comment.get("created"))
        if before and (created is None or created > before):
            continue
        lines = str(comment.get("text") or "").split("\n")
        if not any(line.lstrip().startswith(INVESTIGATE_CLONES) for line in lines):
            continue
        for match in filter(None, map(_CLONE.match, lines)):
            name = match.group(1).partition(":investigate:")[2] or match.group(1)
            clone = f"{_oqa.tok(name, 60)} t#{match.group(2)}"
            if clone not in clones:
                clones.append(clone)
    return clones


def worker_names(client, worker_ids):
    names = {}
    for worker_id in worker_ids[:MAX_WORKERS]:
        try:
            worker = client.get_json(f"/api/v1/workers/{worker_id}")["worker"]
            names[worker_id] = f"{worker['host']}:{worker['instance']}"
        except (_oqa.OqaError, KeyError, TypeError):
            continue
    return names


def worker_name(run, workers):
    """host:instance of the worker a run ran on, "#<id>" when not looked up, else None."""
    worker_id = _oqa.job_id_of(run.get("assigned_worker_id"))
    return workers.get(worker_id, f"#{worker_id}") if worker_id else None


def worker_tally(rows, machines, most=8):
    """ "<worker> ok=N not_ok=M, ..." of the runs, the most failing first; None for one worker."""
    tally = {}
    for row in rows:
        if machines.get(row["id"]):
            tally.setdefault(machines[row["id"]], [0, 0])[bad(row)] += 1
    if len(tally) < 2:
        return None
    items = sorted(tally.items(), key=lambda item: (-item[1][1], item[0]))
    text = ", ".join(
        f"{_oqa.tok(name)} ok={ok} not_ok={not_ok}"
        for name, (ok, not_ok) in items[:most]
    )
    return text + (f", +{len(items) - most} more" if len(items) > most else "")


def row_cells(row, run=None, workers=None, references=None):
    """run: the row's /api/v1/jobs entry, "?" when unknown, None when not read at all;
    workers: None when not read, which leaves the worker cell empty."""
    comment_data = row.get("comment_data") or {}
    bugs = [
        bug.get("content")
        for bug in comment_data.get("bugs") or ()
        if isinstance(bug, dict)
    ]
    label = comment_data.get("label")
    if references:
        bugs, label = references
    result = row.get("result") if row.get("state") == "done" else row.get("state")
    known = isinstance(run, dict)
    stamp = row_times(row, {row["id"]: run} if known else None)[0]
    started = stamp.strftime("%Y-%m-%dT%H:%MZ") if stamp else (None if known else run)
    worker = None if workers is None else run
    if known and workers is not None:
        worker = worker_name(run, workers)
    return (
        row["id"],
        row.get("build"),
        started,
        worker,
        result,
        module_cell(row.get("failedmodules")),
        bugs or None,
        label,
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

    def shown(key, value):
        # A side without the key says it was added or removed, which masking must not hide.
        if value is None:
            return "-"
        return _secrets.setting_value(key, value, _oqa.tok(value, 100))

    lines = [
        f"{key}: {shown(key, change.get('-'))} -> {shown(key, change.get('+'))}"
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


def commits(text):
    """[(head line, [paths])] from openQA's `git log --stat --pretty=oneline` text."""
    found = []
    for line in text.split("\n"):
        if _COMMIT.match(line):
            found.append((line, []))
        elif found and (match := _STAT.match(line)):
            found[-1][1].append(match.group(1))
    return found


def module_pattern(names):
    if not names:
        return None
    names = "|".join(re.escape(name) for name in sorted(names, key=len, reverse=True))
    return re.compile(r"(?:^|[/{ ])(" + names + r")\.p[my](?![\w.])")


def touched(paths, pattern):
    names = []
    for path in paths:
        if pattern and (path.startswith((".../", "tests/")) or "tests/" in path):
            names += [
                m.group(1) for m in pattern.finditer(path) if m.group(1) not in names
            ]
    return names


def stat_paths(path):
    """Both sides of a rename as git --stat prints it ("a/{x => y}/b", "x => y"), else the path."""
    match = _RENAME.match(path)
    if match:
        head, old, new, tail = match.groups()
        return [re.sub("/+", "/", head + side + tail) for side in (old, new)]
    return path.split(" => ", 1)


def on_call_path(path, frames):
    """The frame file a changed path is, or None. A relative frame is relative to the test
    repository; an absolute one and git's ".../<tail>" match by their tail."""
    for candidate in stat_paths(path):
        short = candidate.startswith(".../")
        tail = candidate[4:] if short else candidate
        for frame in frames:
            absolute = frame.startswith("/")
            if frame == tail or (
                (short or absolute) and frame.endswith("/" + tail.lstrip("/"))
            ):
                return candidate if absolute else frame
    return None


def marks(paths, failed_re, earlier_re=None, frames=()):
    """Markers for a commit that touches a failed module's test file, another file of the
    failing step's stack trace, lib/ or the test file of a module that ran before the
    failed one.

    git shortens a long path to ".../<tail>": such a name may still be a test module, but
    whether it lies in lib/ cannot be told."""
    found = [f"[failed module {name}]" for name in touched(paths, failed_re)]
    calls = []
    for path in paths:
        frame = None if touched([path], failed_re) else on_call_path(path, frames)
        if frame and frame not in calls:
            calls.append(frame)
    found += [f"[call path {frame}]" for frame in calls]
    if any(path.startswith(("lib/", "{lib")) or "=> lib/" in path for path in paths):
        found.append("[lib]")
    return found + [f"[earlier module {name}]" for name in touched(paths, earlier_re)]


MARKED = ("[failed module ", "[call path ", "[lib]", "[earlier module ")


def marked_heads(text, limit, failed, earlier=(), frames=(), verbose=False):
    """Commits touching the failed module, the failing call path, lib/, an earlier module,
    then the rest, each group newest first; the counts of the first four. verbose: every
    commit, each followed by its files."""
    patterns = module_pattern(failed), module_pattern(earlier)
    groups, counts = ([], [], [], [], []), [0, 0, 0, 0]
    for head, paths in commits(text):
        tags = marks(paths, *patterns, frames)
        hits = [any(tag.startswith(mark) for tag in tags) for mark in MARKED]
        counts = [count + hit for count, hit in zip(counts, hits)]
        group = next((i for i, hit in enumerate(hits) if hit), 4)
        files = [f"    {path}" for path in paths] if verbose else []
        groups[group].append([" ".join([*tags, head]), *files])
    entries = [entry for group in groups for entry in group]
    shown = entries if verbose else entries[:limit]
    lines = [line for entry in shown for line in entry]
    return lines, len(entries), len(shown), tuple(counts)


def earlier_modules(job, failed):
    """Names of the modules that ran before the first failed one; None when the job's
    module list is unknown."""
    modules = job.get("modules") if isinstance(job, dict) else None
    if not isinstance(modules, list):
        return None
    modules = [module for module in modules if isinstance(module, dict)]
    names = [re.sub(r"#\d+$", "", str(module.get("name") or "")) for module in modules]
    # By result, not name: an earlier load of a module loaded twice may have passed.
    first = next(
        (i for i, module in enumerate(modules) if module.get("result") == "failed"), 0
    )
    return sorted({name for name in names[:first] if name and name not in failed})


def first_failed(job, row):
    """The name of the first failed module as openQA stores its results, "#<n>" kept."""
    modules = job.get("modules") if isinstance(job, dict) else None
    for module in modules if isinstance(modules, list) else ():
        if isinstance(module, dict) and module.get("result") == "failed":
            return str(module.get("name") or "") or None
    names = row.get("failedmodules") or ()
    return str(names[0]) if names else None


def module_history(module, older, runs):
    """When this job's first failed module last ran ok, and in how many older runs since it
    failed or did not run; None without every one of those runs' module lists."""
    failed = absent = 0
    for row in older:
        modules = ((runs or {}).get(row["id"]) or {}).get("modules")
        if not isinstance(modules, list):
            return None
        result = next(
            (
                m.get("result")
                for m in modules
                if isinstance(m, dict) and m.get("name") == module
            ),
            None,
        )
        if result in OK_RESULTS:
            since = f"last_ok={row['id']} build={build_of(row)}; since then "
            break
        failed += result == "failed"
        absent += result != "failed"
    else:
        since = f"last_ok=none in {len(older)} older run(s); "
    return (
        f"module {_oqa.tok(module)}: {since}failed={failed} not_run={absent} "
        "(skipped or not reached)"
    )


def call_path(client, job_id, module):
    """Files of the stack trace of the failing step, outside os-autoinst; None when there
    is no readable step that died."""
    if not module:
        return None
    try:
        data = client.get_json(
            f"/tests/{job_id}/file/details-{module}.json", max_bytes=DETAILS_BYTES
        )
    except _oqa.OqaError:
        return None
    steps = data.get("details") if isinstance(data, dict) else data
    for step in steps if isinstance(steps, list) else ():
        text = step.get("text_data") if isinstance(step, dict) else None
        if not isinstance(text, str) or "# Test died" not in text:
            continue
        files = []
        for match in _FRAME.finditer(text[:65536]):
            if _NOT_DISTRI.search(match.group(1)):
                continue
            path = posixpath.normpath(match.group(1))
            while path.startswith("../"):
                path = path[3:]
            repo = None if path.startswith("/") else _REPO_PATH.search(path)
            path = repo.group(1) if repo else path
            if path not in files:
                files.append(path)
        return files
    return None


def uploads(client, job_id):
    """Names of the files a job uploaded, from the downloads tab; None when unreadable."""
    try:
        page = client.get_bytes(
            f"/tests/{job_id}/downloads_ajax", max_bytes=1 << 20, accept="text/html"
        ).decode("utf-8", "replace")
    except _oqa.OqaError:
        return None
    names = re.findall(rf"/tests/{job_id}/file/({_UPLOAD_NAME})(?=[\"'?#<>\s])", page)
    return list(dict.fromkeys(name.replace("%23", "#") for name in names))


def version_file(names, prefer=None):
    if prefer in (names or ()):
        return prefer
    for pattern in VERSION_SOURCES:
        for name in names or ():
            if pattern.search(name):
                return name
    return None


def wanted(name):
    return bool(KERNEL_PACKAGE.fullmatch(name)) or name in SUITE_PACKAGES


def package_versions(text):
    """{package: [version-release, ...]} of the kernel and the test suites in an rpm -qa
    list (name-version-release[.arch] lines) or rpm -qi output."""
    found, fields = {}, {}

    def add(name, version):
        if not wanted(name) or not _PACKAGE_LINE.fullmatch(version):
            return
        if version not in found.setdefault(name, []):
            found[name].append(version)

    for line in text.split("\n"):
        line = line.strip()
        field = _QI_FIELD.match(line)
        if field:
            fields[field.group(1)] = field.group(2)
            if field.group(1) == "Release" and "Name" in fields and "Version" in fields:
                add(fields["Name"], f"{fields['Version']}-{fields['Release']}")
                fields = {}
        elif _PACKAGE_LINE.fullmatch(line):
            base, dot, arch = line.rpartition(".")
            parts = (base if dot and arch in ARCHS else line).rsplit("-", 2)
            if len(parts) == 3 and all(parts):
                add(parts[0], f"{parts[1]}-{parts[2]}")
    return found


def job_versions(client, job_id, names, prefer=None):
    """(file name, {package: versions}) of one job from the names of its uploads, (None, None)
    without a package list."""
    name = version_file(names, prefer)
    if not name:
        return None, None
    try:
        text = client.get_text(f"/tests/{job_id}/file/{name}", max_bytes=LIST_BYTES)
    except _oqa.OqaError:
        return name, None
    return name, package_versions(text)


def versions_line(client, job_id, good_id, good_files):
    """Kernel and test suite package versions of last good and this job, side by side."""
    name, new = job_versions(client, job_id, uploads(client, job_id))
    good_name, old = job_versions(client, good_id, good_files, name)
    if not new and not old:
        return "  versions: not found"
    # rpm -qi of the kernel cannot show a suite: there a missing one is unknown, not absent.
    kernel_only = [bool(f and VERSION_SOURCES[-1].search(f)) for f in (good_name, name)]
    items = []
    packages = {*(new or {}), *(old or {})}
    for package in sorted(packages, key=lambda n: (n[:7] != "kernel-", n)):
        before, after = (
            ",".join(_oqa.tok(v, 60) for v in side[package])
            if side and package in side
            else ("?" if side is None or (only and package in SUITE_PACKAGES) else "-")
            for side, only in zip((old, new), kernel_only)
        )
        if before == after:
            items.append(f"{package} {after} (unchanged)")
        elif (
            package in SUITE_PACKAGES
            and "," not in before + after
            and before.rpartition("-")[0] == after.rpartition("-")[0] != ""
        ):
            items.append(f"{package} {before} -> {after} (release only)")
        else:
            items.append(f"{package} {before} -> {after}")
    if any(kernel_only) and not packages & set(SUITE_PACKAGES):
        items.append("suites ?")
    files = [_oqa.tok(file, 80) if file else "-" for file in (good_name, name)]
    source = files[1] if name == good_name else " -> ".join(files)
    return f"  versions (last_good {good_id} -> this job, from {source}): " + "; ".join(
        items
    )


def isotovideo_version(client, job_id):
    """The os-autoinst version a job ran with, "?" when unknown."""
    try:
        head = client.get_range(
            f"/tests/{job_id}/file/autoinst-log.txt", max_bytes=HEAD_BYTES
        )[0]
    except _oqa.OqaError:
        return "?"
    match = _ISOTOVIDEO.search(head.decode("utf-8", "replace"))
    return _oqa.tok(match.group(1)) if match else "?"


def fenced(client, job_id, title, lines, max_bytes=16384):
    block = _oqa.sanitize("\n".join(lines), max_line=240, max_bytes=max_bytes)
    source = f"{client.host.split('//')[1]}/tests/{job_id}/investigation_ajax:{title}"
    return _oqa.fence(block, source)


def investigation(
    client, job_id, limit, verbose, failed=(), job=None, module=None, before=None
):
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
    first_bad = link_id(data.get("first_bad"))
    print(f"  last_good={link_id(data.get('last_good'))} first_bad={first_bad}")
    clones = (
        investigate_jobs(client, int(first_bad), before)
        if first_bad.isdigit()
        else None
    )
    if clones:
        print(f"  first_bad {first_bad} investigate jobs: {', '.join(clones)}")
    if not isinstance(data.get("last_good"), dict):
        print(
            "  nothing to compare: openQA found no passed or softfailed run of this scenario "
            "before this job, in all of its history, not only the --previous shown"
        )
        return
    good_id = link_id(data.get("last_good"))
    good_files = uploads(client, int(good_id)) if good_id.isdigit() else None
    # The log cleanup deletes autoinst-log.txt with the other logs and uploads.
    gone = good_files is not None and "autoinst-log.txt" not in good_files
    if gone:
        print("  last_good logs: gone (pruned, its log files answer 404)")
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
    if good_id.isdigit():
        print(versions_line(client, job_id, int(good_id), good_files))
        old = "?" if gone else isotovideo_version(client, int(good_id))
        new = isotovideo_version(client, job_id)
        change = f"{new} (unchanged)" if old == new != "?" else f"{old} -> {new}"
        print(f"  os-autoinst (last_good {good_id} -> this job): {change}")

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
        if key == "test_log":
            earlier = earlier_modules(job, failed) if failed else []
            frames = call_path(client, job_id, module)
            heads, total, shown, (in_module, on_path, lib, before) = marked_heads(
                text, limit, failed, earlier or (), frames or (), verbose
            )
            # Unknown, not 0: no earlier-module or call-path commit must look ruled out.
            before = "?" if earlier is None else before
            on_path = "?" if frames is None else on_path
            order = (
                f"failed_module={in_module} call_path={on_path} lib={lib} "
                f"earlier_module={before} (those first, then newest first)"
            )
        else:
            heads, total = git_heads(text, limit)
            shown = len(heads)
            order = "(newest first)"
        stat = data.get(stat_key)
        # openQA counts the range with merges, lists it with git log --no-merges and stops
        # that log at twice the diff's maximum (Schema/Result/Jobs.pm "investigate").
        too_many = _TOO_MANY.match(stat) if isinstance(stat, str) else None
        count, most = map(int, too_many.groups()) if too_many else (0, 0)
        cut = most and total >= 2 * most
        print(
            f"  {title} changes: commits={total}{' (list cut by openQA)' if cut else ''} "
            f"{order} url={_oqa.tok(data.get(url_key), 120)}"
        )
        if isinstance(stat, str) and stat.startswith("Too many commits"):
            gap = ""
            if cut:
                gap = f"; {total} listed: openQA's git log stops at {2 * most}"
            elif total < count:
                gap = (
                    f"; {total} listed, the other {count - total} are merge commits, "
                    "which openQA does not list"
                )
            print(f"  {title} diff stat: {_oqa.quoted(stat, 160)}{gap}")
        omitted = total - shown
        print(
            fenced(
                client,
                job_id,
                key,
                heads + ([f"[... {omitted} more commits omitted]"] if omitted else []),
                65536 if verbose else 16384,
            ),
            end="",
        )


def main():
    parser = ArgumentParser(
        prog="oqa-history.py",
        description="Newest-first history of the scenario of one openQA job (same distri, version, "
        "flavor, arch, test and machine) with start time per run, last good / first bad, the "
        "failure rate and a one-line classification hint, in one request. GET only, "
        f"{MAX_REQUESTS} requests at most.",
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
        "--before",
        type=before_time,
        metavar="TIME",
        help="the history as of TIME (ISO 8601, UTC unless it has an offset): runs that "
        "started later are cut, runs still going then show as running, comments created "
        "later are ignored",
    )
    parser.add_argument(
        "--workers",
        action="store_true",
        help="add the worker column: one /api/v1/jobs request per 25 runs, which carry "
        "their module lists, and one request per worker",
    )
    parser.add_argument(
        "--investigation",
        action="store_true",
        help="add a capped summary of the investigation data: last good, first bad, "
        "changed settings, package diffs, kernel, test suite and os-autoinst versions, test and needle "
        "commit subjects; reads the workers too",
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
        "hashes) and 'not available' lines; list every test commit with its files",
    )
    args = parser.parse_args()

    args.host, job_id = _oqa.parse_job_url(args.job, args.host)
    client = _oqa.client_from_args(args, "oqa-history", max_requests=MAX_REQUESTS)
    # --before shows the runs after the job that had started by then, its restart among them.
    following = NEXT_BEFORE if args.before else 0
    current, newer, older, more = history(client, job_id, args.previous, following)
    rows = [*newer, current, *older]
    full = args.workers or args.investigation
    # The list carries every run's modules, megabytes for long suites: only when needed.
    listed = [
        row["id"] for row in rows if full or (args.before and not row.get("finished"))
    ]
    runs = run_details(client, listed) if listed else None
    cut, references, later, forced = 0, {}, 0, {}
    if args.before:
        current, newer, older, cut = as_of(args.before, runs, current, newer, older)
        references, later, forced = comments_as_of(
            client, args.before, [*newer, current, *older]
        )

        def then(row):
            return {**row, "result": forced[row["id"]]} if row["id"] in forced else row

        current, newer, older = then(current), [*map(then, newer)], [*map(then, older)]
    rows = [*newer, current, *older]
    workers = None
    if full and runs is not None:
        worker_ids = []
        for row in rows:
            run = runs.get(row["id"]) or {}
            worker_id = _oqa.job_id_of(run.get("assigned_worker_id"))
            if worker_id and worker_id not in worker_ids:
                worker_ids.append(worker_id)
        workers = worker_names(client, worker_ids)

    scenario = "-".join(
        str(current.get(key) or "?")
        for key in ("distri", "version", "flavor", "arch", "test")
    )
    print(f"job={job_id} host={client.host} scenario={_oqa.tok(scenario, 160)}")
    cells = [
        row_cells(
            row,
            None
            if runs is None or row["id"] not in listed
            else runs.get(row["id"], "?"),
            workers,
            references.get(row["id"]),
        )
        for row in rows
    ]
    headers = (
        "id",
        "build",
        "started",
        "worker",
        "result",
        "failed_modules",
        "bugrefs",
        "label",
        "clone",
    )
    print(_oqa.table(cells, headers, drop_empty=True), end="")
    if not full:
        print("note: no worker column; --workers reads it")
    elif runs is None:
        print("note: workers not read (/api/v1/jobs not readable)")
    notes = (
        [f"{len(newer)} newer run(s) not counted, latest={newer[0]['id']}"]
        if newer
        else []
    )
    if cut:
        notes.append(f"{cut} run(s) that started after --before cut")
    if later:
        notes.append(
            f"{later} bugref or label comment(s) created after --before ignored"
        )
    if forced:
        notes.append(
            f"result(s) of {','.join(map(str, forced))} forced later, shown as at --before"
        )
    if notes:
        print("note: " + "; ".join(notes))

    status = 0
    if current.get("state") != "done":
        state = _oqa.clean(current.get("state"))
        when = "was running at --before" if args.before else f"is {state}"
        print(f"hint: job {job_id} {when}, no result to classify yet")
    else:
        finished = [current, *(row for row in older if row.get("state") == "done")]
        machines = {}
        for row in finished if workers is not None else ():
            run = runs.get(row["id"])
            machines[row["id"]] = worker_name(run, workers) if run else None
        tally = worker_tally(finished, machines)
        if tally:
            print(f"workers: {tally}")
        for line in describe(finished, more, machines):
            print(line)
        status = 1 if bad(current) else 0
    if args.investigation:
        # A module name may carry the "#<n>" os-autoinst gives a repeated load.
        failed = {
            re.sub(r"#\d+$", "", str(name))
            for name in current.get("failedmodules") or ()
            if name
        }
        job = (runs or {}).get(job_id)
        module = first_failed(job, current)
        done = [row for row in older if row.get("state") == "done"]
        own = module and job and module_history(module, done, runs)
        if own:
            print(own)
        investigation(
            client,
            job_id,
            args.max_items,
            args.verbose,
            sorted(failed),
            job,
            module,
            args.before,
        )
    print(f"requests: {client.requests}")
    return status if args.exit_code else 0


if __name__ == "__main__":
    _oqa.run(main)
