#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Review work-list: build counters of a job group plus one line per CURRENT not-ok job with its review state (GET only).
"""One header line per group/build, then one line per job that still fails.

"Current" means the newest job of each scenario: a failure that was restarted
and then passed is not listed. The rich mode gets everything from one
/tests/overview.json request; when that answer does not look as expected the
script says so and falls back to /api/v1 (one listing plus one comments
request per job).

Header fields come from build_results; counters that are 0 are left out.
failed counts failed and not-complete jobs, labeled counts those that have a
bugref or a label, unreviewed is failed - labeled (0 means the build shows
the "reviewed" badge), unfinished is scheduled or running. scenario_prefix is
the DISTRI-VERSION- part all listed scenarios share; it is cut from the lines.

Job line: <id> <result> <scenario> then only the fields that have a value.
bugrefs are the bug references openQA parsed from the comments, label is the
newest label, comments counts comments that carry neither (automated ones
included), restarts says how often the scenario was restarted in this build
(a cheap hint for a sporadic failure), origin is the job this one was cloned
from, parents lists dependency parents: for parallel_failed and skipped jobs
triage the parent or sibling that failed, not this job. review=? means the
comments were not read: the request cap, less what the builds and groups
still to list need, was reached. Jobs that never ran because a parent failed
(cancelled, skipped) are folded into one "victims" line per parent.
--test REGEX keeps the jobs whose test name it matches (re.search, case-sensitive,
the name without the @machine the overview may add), so one scenario's spread over
flavors and arches needs no full listing; the header counters stay those of the
whole build.

--before TIME (ISO 8601, UTC unless it has an offset; needs --build) shows the
build as it stood then, for a review of an older failure: per scenario the newest
job that had started by TIME, restarted later or not, with its result then
(running when it finished later). Bugrefs and labels come from the comments
created by TIME. A note line counts the jobs that started later, left out, and
names the cost: one /api/v1/jobs request per build of at most 1000 jobs and
8 MB with their module lists (a literal --test '^NAME$' is sent as test=NAME),
plus the comments reads, capped as in the API fallback. as_of= replaces the
header counters, which are those of now.

--passed turns the list around: current passed and softfailed jobs of the
build, either is a source to clone for a verification run; --module M keeps
those in which M itself passed. Line: <id> <test@machine> result= arch= flavor=,
then hdd= (HDD_1, the image the job boots), publishes= (PUBLISH_HDD_1) and
parents= when set. --test keeps those whose TEST it matches: openQA filters a
literal '^NAME$' (test=NAME), any other regex searches the newest 100 such jobs.

--uses-schedule PATH answers "which scenarios does a change to this schedule
file reach": in the groups given by --group ID and/or --match REGEX (on
'parent / name'; one of them is required) it lists every job template whose
YAML_SCHEDULE, from the template or else from its test suite, is PATH. Line:
group= version= flavor= arch= machine= test= job= result= build=, the job being
the newest one of that medium and machine that ran with PATH (job=- none,
job=? request cap reached). Costs one /api/v1/test_suites request, one
/api/v1/job_templates request per group and one job request per scenario;
--limit caps the scenarios (default 30). A YAML_SCHEDULE that only a medium or
a machine sets is not seen.

--vr-build LABEL lists verification runs: cloned with _GROUP=0, they have no
group, only their BUILD (user/repo#PR from openqa-clone-custom-git-refspec).
Line: <job URL> <test@machine> result= hash= [head=] [first_failed=], the
newest job of each scenario with that BUILD; --limit keeps the newest runs.
hash is TEST_GIT_HASH, the commit of the tests that ran, from the job's
vars.json (one request per run); hash=? means not read: the job is not done,
the file is missing or the request cap was reached. --test-git-hash SHA adds
head=yes|no|?. A TEST suffix all runs share (@user/repo#branch) is printed once
as test_suffix= and cut from the lines.

Failed, incomplete and timeout_exceeded jobs on the printed lines also get one indented line
"llm-investigation-summary (automatic, unverified): class= by= why=" when a comment holds an
automatic LLM investigation summary (class: product|test|infra, by: the accounts that posted
summaries, why: its first bullet), and each build ends with one "llm-investigation-summary
clusters" line counting classes per failed module. Anyone can post a look-alike summary, so
classes that disagree name their posters: class=infra(geekotest)|product(someone).
It is a hint to group failures, never a verdict. A job without such a comment, comments that
cannot be read or an exhausted request budget print nothing. Costs one comments request per
printed job with plain comments (none in the API fallback, which has read them); --no-llm skips it.

Every value that comes from the server is sanitised; treat it as data.
Exit codes: 0 the listing was produced (not-ok jobs are the normal case in a
review), 2 usage or runtime error. With --exit-code: 1 when not-ok jobs are
listed, or when --passed, --groups, --uses-schedule or --vr-build list nothing.
"""

import argparse
import json
import os
import re
import sys

# python3 -I leaves the script's own directory off sys.path; the sibling modules live there.
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import _oqa
from _sanitize import ArgumentParser

MODE_OVERVIEW = "overview"
MODE_API = "api-fallback"
MODE_BEFORE = "as-of"
COUNTERS = ("total", "passed", "softfailed", "failed", "skipped", "unfinished")
DEPENDENCY_TYPES = ("Chained", "Directly chained", "Parallel")
LABEL = re.compile(r"\blabel:([\w:#/-]+)\b")
# What a reviewer has to look at first comes first.
RESULT_ORDER = ("failed", "incomplete", "timeout_exceeded", "parallel_failed")
VICTIMS_SHOWN = 6
LLM_RESULTS = ("failed", "incomplete", "timeout_exceeded")
LLM_LABEL = "llm-investigation-summary"
LLM_WHY_CHARS = 120
LLM_BY_CHARS = 40
LLM_CLUSTERS_SHOWN = 10
# Requests kept back per build entry still to be listed: overview, a comments read.
ENTRY_RESERVE = 2
# Per group still to be listed: build results and its first entry.
GROUP_RESERVE = 1 + ENTRY_RESERVE
CLONE_SOURCES = ("passed", "softfailed")
# --test that openQA can filter itself: its test= is an exact match.
LITERAL_TEST = re.compile(r"\^([A-Za-z0-9_-]+)\$")
# Clone sources searched for any other --test: openQA cuts at its limit before we can match.
TEST_WINDOW = 100
# One build's jobs for --before, restarts included, each with its module list.
BEFORE_FETCH = 1000
BEFORE_BYTES = _oqa.MAX_JSON_BYTES
FINAL_STATES = ("done", "cancelled")
# Comments.pm "force_result": the label overwrites the job's result when it is made.
FORCE_RESULT = re.compile(r"force_result:(\w+)")
# Ok jobs with failed modules whose comments --before reads for a later force_result.
MAX_FORCE_CHECKS = 20
MAX_SCHEDULE_GROUPS = 12
# --match runs the user's regex over a name the server chose: an unbounded
# subject turns an ordinary ".*a.*b" into minutes of backtracking.
MATCH_CHARS = 200
SCHEDULE_PATH = re.compile(r"[A-Za-z0-9_@+.-]+(/[A-Za-z0-9_@+.-]+)*")
SCENARIO_KEYS = ("DISTRI", "VERSION", "FLAVOR", "ARCH", "MACHINE", "TEST")
# Jobs of one BUILD label asked for, restarts and re-clones of a scenario included.
VR_FETCH = 100
VARS_BYTES = 256 * 1024
GIT_HASH = re.compile(r"[0-9a-f]{7,40}")
HASH_SHOWN = 10


class ShapeError(Exception):
    """The overview answer is not what this script knows how to read."""


tok, toks = _oqa.tok, _oqa.toks


def _iso(stamp):
    return stamp.strftime("%Y-%m-%dT%H:%M:%SZ")


def matching_groups(client, pattern):
    """(id, name, parent name) of the groups whose 'parent / name' matches."""
    try:
        matcher = re.compile(pattern or "", re.IGNORECASE)
    except re.error as error:
        raise _oqa.OqaError(f"--match is not a valid regex: {error}") from None
    parents = {
        parent.get("id"): parent.get("name")
        for parent in client.get_json("/api/v1/parent_groups")
    }
    rows = []
    for group in client.get_json("/api/v1/job_groups"):
        parent = parents.get(group.get("parent_id"))
        name = str(group.get("name"))[:MATCH_CHARS]
        label = f"{str(parent)[:MATCH_CHARS]} / {name}" if parent else name
        if matcher.search(label):
            rows.append((_oqa.job_id_of(group.get("id")), name, parent))
    rows.sort(key=lambda row: (str(row[2] or ""), row[1]))
    return rows


def list_groups(client, pattern):
    rows = matching_groups(client, pattern)
    print(f"host={client.host} groups={len(rows)} match={_oqa.quoted(pattern or '')}")
    print(_oqa.table(rows, ("id", "name", "parent"), drop_empty=True), end="")
    print(f"requests: {client.requests}")
    return len(rows)


def pick_builds(client, group, build):
    """Return (group name, [build_results entry, ...]); entries may lack counters."""
    try:
        data = client.get_json(
            f"/api/v1/job_groups/{group}/build_results", {"show_tags": 1}
        )
        entries = [entry for entry in data["build_results"] if "build" in entry]
        name = data["group"]["name"]
    except (KeyError, TypeError):
        raise _oqa.OqaError(
            f"unexpected build_results answer for group {group}"
        ) from None
    except _oqa.OqaError as error:
        # _oqa words an error status "HTTP <code>: <path>"; a 4xx means no such group here,
        # but a request timeout (408) or too many requests (429) says nothing about the group.
        if isinstance(error, _oqa.NotFound) or re.match(
            r"HTTP 4(?!08|29)\d\d:", str(error)
        ):
            raise _oqa.OqaError(
                f"group {group} is not readable on {client.host} ({error}); a group of "
                "another openQA instance needs --host"
            ) from None
        if build is None:
            raise
        return None, [{"build": build}]
    if build is None:
        if not entries:
            raise _oqa.OqaError(f"group {group} has no builds")
        return name, entries[:1]
    # The same build can exist once per version.
    matching = [entry for entry in entries if str(entry["build"]) == build]
    return name, matching or [{"build": build}]


def header(group, name, entry, mode, prefix, as_of=None):
    parts = [f"group={group} name={_oqa.quoted(name)} build={tok(entry['build'])}"]
    if entry.get("version") is not None:
        parts.append(f"version={tok(entry['version'])}")
    if as_of:
        parts.append(f"as_of={as_of}")
    elif "failed" not in entry:
        parts.append("counters=unavailable (build not among the newest of the group)")
    else:
        failed, labeled = int(entry["failed"]), int(entry.get("labeled") or 0)
        counters = {key: int(entry.get(key) or 0) for key in COUNTERS}
        counters.update(labeled=labeled, commented=int(entry.get("comments") or 0))
        parts += [
            f"{key}={value}"
            for key, value in counters.items()
            if value or key in ("total", "failed")
        ]
        parts.append(f"unreviewed={max(failed - labeled, 0)}")
        if entry.get("all_passed"):
            state = "all-passed"
        elif entry.get("reviewed"):
            state = "reviewed"
        else:
            state = "needs-review"
        parts.append(f"state={state}")
        if isinstance(entry.get("tag"), dict):
            parts.append(f"tag={tok(entry['tag'].get('description'))}")
    if mode not in (MODE_OVERVIEW, MODE_BEFORE):
        parts.append(f"mode={mode}")
    if prefix:
        parts.append(f"scenario_prefix={tok(prefix, 80)}")
    return " ".join(parts)


def _ids(value):
    """Job ids only: they are printed for the reviewer to look up. bool is not one."""
    return [_oqa.job_id_of(item) for item in value or () if _oqa.job_id_of(item)]


def _parents(deps):
    parents = deps.get("parents") if isinstance(deps, dict) else None
    if not isinstance(parents, dict):
        return []
    return [job for kind in DEPENDENCY_TYPES for job in _ids(parents.get(kind))]


def overview_jobs(client, group, entry, results, todo, pattern=None):
    params = [("groupid", group), ("build", entry["build"])]
    if entry.get("version") is not None:
        params.append(("version", entry["version"]))
    params.append(("result", results))
    if todo:
        params.append(("todo", 1))
    data = client.get_json("/tests/overview.json", params)
    if not isinstance(data, dict) or not isinstance(data.get("results"), dict):
        raise ShapeError("no results object")
    jobs = []
    try:
        for distri, versions in data["results"].items():
            for version, flavors in versions.items():
                for flavor, tests in flavors.items():
                    for test, archs in tests.items():
                        for arch, leaf in archs.items():
                            if isinstance(leaf, dict) and "jobid" in leaf:
                                scenario = (distri, version, flavor, arch, test)
                                jobs.append(_overview_job(scenario, leaf))
    except (AttributeError, TypeError, ValueError):
        raise ShapeError("results are not nested as expected") from None
    listed = data.get("job_ids")
    if isinstance(listed, list) and sorted(_ids(listed)) != sorted(
        job["id"] for job in jobs
    ):
        raise ShapeError("job_ids and results disagree")
    return _of_test(jobs, pattern), bool(data.get("limit_exceeded"))


def _of_test(jobs, pattern, name=lambda job: job["test"]):
    """The jobs whose test name --test matches; all of them without --test. The overview
    names a test on a machine other than the preferred one TEST@MACHINE, /api/v1 plain
    TEST: the match is on TEST in both."""
    if pattern is None:
        return jobs
    return [
        job
        for job in jobs
        if pattern.search(str(name(job)).split("@", 1)[0][:MATCH_CHARS])
    ]


def _overview_job(scenario, leaf):
    try:
        deps = json.loads(leaf.get("deps") or "{}")
    except (RecursionError, TypeError, ValueError):
        deps = {}
    return {
        "id": int(leaf["jobid"]),
        "result": leaf.get("overall") or leaf.get("state"),
        "prefix": f"{scenario[0]}-{scenario[1]}-",
        "scenario": "-".join(str(part) for part in scenario),
        "test": scenario[4],
        "modules": sorted(str(name) for name in leaf.get("failures") or ()),
        "refs": sorted(leaf.get("bugs") or ()),
        "label": leaf.get("label"),
        "comments": int(leaf.get("comments") or 0),
        "restarts": int(leaf.get("restarts") or 0),
        "origin": None,
        "parents": _parents(deps),
        "llm": None,
    }


def api_jobs(client, group, entry, results, todo, pattern=None, reserve=0):
    """scope=current drops restarted jobs; a scenario that was scheduled again
    without a restart can still show its older failure here. The comments reads
    leave `reserve` requests to the entries and groups still to list."""
    params = [("groupid", group), ("build", entry["build"])]
    if entry.get("version") is not None:
        params.append(("version", entry["version"]))
    params += [("scope", "current"), ("latest", 1), ("result", ",".join(results))]
    jobs = [
        _api_job(job)
        for job in client.get_json("/api/v1/jobs", params).get("jobs") or ()
    ]
    jobs = _of_test(jobs, pattern)
    jobs.sort(key=_order)
    complete = _read_reviews(client, jobs, reserve)
    if todo:
        jobs = [job for job in jobs if not (job["refs"] or job["label"])]
    return jobs, complete


def _api_job(job):
    settings = job.get("settings") or {}
    keys = ("DISTRI", "VERSION", "FLAVOR", "ARCH", "TEST")
    scenario = "-".join(str(settings.get(key)) for key in keys)
    if settings.get("MACHINE"):
        scenario += f"@{settings['MACHINE']}"
    failed = [
        str(module.get("name"))
        for module in job.get("modules") or ()
        if module.get("result") == "failed"
    ]
    return {
        "id": int(job["id"]),
        "result": job.get("result"),
        "prefix": f"{settings.get('DISTRI')}-{settings.get('VERSION')}-",
        "scenario": scenario,
        "test": settings.get("TEST"),
        "modules": sorted(failed),
        "refs": None,
        "label": None,
        "comments": None,
        "restarts": None,
        "origin": job.get("origin_id"),
        "parents": _parents(job),
        "llm": None,
    }


def _api_test(job):
    return (job.get("settings") or {}).get("TEST")


def jobs_before(client, group, entry, args, results, reserve):
    """The build as it stood at --before: per scenario the newest job that had started by
    then, as running when it finished later. Returns (jobs, note lines)."""
    params = [("groupid", group), ("build", entry["build"])]
    if entry.get("version") is not None:
        params.append(("version", entry["version"]))
    if name := _literal_test(args.test):
        params.append(("test", name))
    params.append(("limit", BEFORE_FETCH))
    body = client.get_bytes(
        "/api/v1/jobs", params, max_bytes=BEFORE_BYTES + 1, accept="application/json"
    )
    if len(body) > BEFORE_BYTES:
        raise _oqa.OqaError(
            f"the jobs of build {tok(entry['build'])} exceed {BEFORE_BYTES >> 20} MB: "
            "narrow them with --test '^NAME$'"
        )
    try:
        fetched = json.loads(body).get("jobs") or ()
    except (RecursionError, ValueError):
        raise _oqa.OqaError("response is not JSON: /api/v1/jobs") from None
    fetched = [job for job in fetched if _oqa.job_id_of(job.get("id"))]
    newest, later = {}, 0
    for job in sorted(
        _of_test(fetched, args.test, _api_test), key=lambda job: -job["id"]
    ):
        finished = _oqa.parse_time(job.get("t_finished"))
        # A job cancelled before it ran has no start, only its end.
        started = _oqa.parse_time(job.get("t_started")) or finished
        if started is None or started > args.before:
            later += 1
            continue
        settings = job.get("settings") or {}
        scenario = tuple(str(settings.get(key)) for key in SCENARIO_KEYS)
        if scenario in newest:
            continue
        newest[scenario] = _api_job(job)
        if (
            job.get("state") not in FINAL_STATES
            or not finished
            or finished > args.before
        ):
            newest[scenario].update(result="running", modules=[], refs=[], comments=0)
    reads = client.requests
    # A failed module in an ok job may be one a later label:force_result overruled.
    suspects = [
        job
        for job in newest.values()
        if job["result"] in CLONE_SOURCES and job["modules"]
    ]
    forced = []
    for job in suspects[:MAX_FORCE_CHECKS]:
        if client.requests >= client.max_requests - reserve:
            break
        comments = client.get_json(f"/api/v1/jobs/{job['id']}/comments")
        comments = comments if isinstance(comments, list) else []
        job["fetched"] = [c for c in comments if isinstance(c, dict)]
        then = _result_then(job["fetched"], args.before)
        if then:
            job["result"] = then
            forced.append(job["id"])
    unchecked = sum("fetched" not in job for job in suspects)
    jobs = [job for job in newest.values() if job["result"] in (*results, "running")]
    jobs.sort(key=_order)
    done = [job for job in jobs if job["result"] != "running"]
    complete = _read_reviews(client, done, reserve, args.before)
    if args.todo:
        jobs = [job for job in jobs if not (job["refs"] or job["label"])]
    cost = (
        f"1 /api/v1/jobs request ({len(fetched)} jobs, {(len(body) + 1023) // 1024} kB)"
    )
    cost += f" and {client.requests - reads} comments requests"
    notes = [
        f"note: as of {_iso(args.before)}: {later} job(s) that started later left out; cost: {cost}"
    ]
    if len(fetched) >= BEFORE_FETCH:
        notes.append(
            f"warning: only the newest {BEFORE_FETCH} jobs of the build were read, older "
            "ones are missing (--test '^NAME$' narrows the request)"
        )
    if not complete:
        notes.append(
            "warning: request cap reached, '?' marks jobs whose comments were not read"
        )
    if forced:
        notes.append(
            f"note: result(s) of {','.join(map(str, forced))} forced later, shown as at --before"
        )
    if unchecked:
        notes.append(
            f"warning: {unchecked} ok job(s) with failed modules not checked for a result forced "
            f"later (at most {MAX_FORCE_CHECKS}, or the request cap)"
        )
    return jobs, notes


def _result_then(comments, before):
    """The result at `before` of a job whose result a label:force_result comment made later
    changed, else None. openQA keeps no result from before a force: an earlier force's,
    else failed, as the caller asks only for jobs with failed modules."""
    then, changed = None, False
    for comment in sorted(comments, key=lambda c: _oqa.job_id_of(c.get("id")) or 0):
        labels = LABEL.findall(str(comment.get("text") or ""))
        force = next(filter(None, map(FORCE_RESULT.match, labels)), None)
        created = _oqa.parse_time(comment.get("created"))
        if created is None or created > before:
            changed = changed or bool(force)
        elif force:
            then = force.group(1)
    return (then or "failed") if changed else None


def _read_reviews(client, jobs, reserve, before=None):
    """Review state of each job in turn while `reserve` requests stay free; False when
    the budget ran out first."""
    for job in jobs:
        if "fetched" not in job and client.requests >= client.max_requests - reserve:
            return False
        _review_state(client, job, before)
    return True


def _review_state(client, job, before=None):
    """Same rule as openQA: a comment with a bugref counts as a bugref, else
    its first label counts, else it is a plain comment. With `before` only the
    comments created by then count."""
    job.update(refs=[], comments=0)
    comments = job.pop("fetched", None)
    if comments is None:
        comments = client.get_json(f"/api/v1/jobs/{job['id']}/comments")
    if before is not None:
        comments = [
            comment
            for comment in comments
            if (created := _oqa.parse_time(comment.get("created")))
            and created <= before
        ]
    job["llm"] = _oqa.llm_review(comments)
    for comment in comments:
        text = str(comment.get("text") or "")
        label = LABEL.search(text)
        if comment.get("bugrefs"):
            job["refs"] = sorted({*job["refs"], *map(str, comment["bugrefs"])})
        elif label:
            job["label"] = label.group(1)
        else:
            job["comments"] += 1


def _order(job):
    result = job["result"]
    if result in RESULT_ORDER:
        return RESULT_ORDER.index(result), job["id"]
    return len(RESULT_ORDER) + (result == "softfailed"), job["id"]


def job_line(job, prefix):
    parts = [
        str(job["id"]),
        tok(job["result"], 20),
        tok(job["scenario"][len(prefix) :], 120),
    ]
    if job["modules"]:
        parts.append(f"modules={toks(job['modules'], 60)}")
    if job["refs"] is None:
        parts.append("review=?")
    if job["refs"]:
        parts.append(f"bugrefs={toks(job['refs'], 60)}")
    if job["label"]:
        parts.append(f"label={tok(job['label'], 60)}")
    if job["comments"]:
        parts.append(f"comments={job['comments']}")
    if job["restarts"]:
        parts.append(f"restarts={job['restarts']}")
    if job["origin"]:
        parts.append(f"origin={int(job['origin'])}")
    if job["parents"]:
        parts.append(
            "parents=" + ",".join(str(parent) for parent in job["parents"][:6])
        )
    return " ".join(parts)


def read_llm(client, jobs, reserve):
    """Overview mode: fetch the comments of listed failures that have plain ones; any problem skips quietly."""
    for job in jobs:
        if job["result"] not in LLM_RESULTS or not job["comments"]:
            continue
        if client.requests >= client.max_requests - reserve:
            return
        try:
            comments = client.get_json(f"/api/v1/jobs/{job['id']}/comments")
        except _oqa.OqaError:
            continue
        if isinstance(comments, list):
            job["llm"] = _oqa.llm_review(comments)


def llm_line(summary):
    """class is a fixed word set; the posters (by=, and per class when classes disagree) and why= are
    server text, cleaned by toks() and quoted(). The restart advice is left out: summaries of one
    cluster disagree on it, and oqa-job.py shows it for the job in triage."""
    parts = [f"  {LLM_LABEL} (automatic, unverified):"]
    if summary["class"]:
        classes = summary["class"].split("|")
        if len(classes) > 1:
            classes = [
                f"{name}({toks(summary['class_by'][name], LLM_BY_CHARS)})"
                for name in classes
            ]
        parts.append("class=" + "|".join(classes))
    parts.append(f"by={toks(summary['by'], LLM_BY_CHARS)}")
    why = (summary["bullets"] or [summary["prose"]])[0]
    if why:
        parts.append(f"why={_oqa.quoted(why, LLM_WHY_CHARS)}")
    return " ".join(parts)


def llm_clusters(jobs):
    """Per failed module the classes of the printed jobs; None when no job has a summary."""
    clusters = {}
    for job in jobs:
        if job["llm"]:
            counts = clusters.setdefault(tuple(job["modules"]) or ("-",), {})
            name = job["llm"]["class"] or "unclassified"
            counts[name] = counts.get(name, 0) + 1
    if not clusters:
        return None
    items = [
        f"{toks(modules, 60)} "
        + " ".join(f"{name}={n}" for name, n in sorted(counts.items()))
        for modules, counts in sorted(clusters.items())
    ]
    more = (
        f" | +{len(items) - LLM_CLUSTERS_SHOWN}"
        if len(items) > LLM_CLUSTERS_SHOWN
        else ""
    )
    return (
        f"{LLM_LABEL} clusters (automatic, unverified): "
        + " | ".join(items[:LLM_CLUSTERS_SHOWN])
        + more
    )


def sweep(client, group, args, results, reserve=0):
    name, entries = pick_builds(client, group, args.build)
    listed = 0
    for index, entry in enumerate(entries):
        mode, note = MODE_OVERVIEW, None
        later = (len(entries) - 1 - index) * ENTRY_RESERVE
        if args.before is not None:
            mode = MODE_BEFORE
            jobs, notes = jobs_before(
                client, group, entry, args, results, reserve + later
            )
            note = "\n".join(notes)
        else:
            try:
                jobs, truncated = overview_jobs(
                    client, group, entry, results, args.todo, args.test
                )
                if truncated:
                    note = "warning: the server truncated the overview, the list is incomplete"
            except (ShapeError, _oqa.OqaError) as error:
                mode = MODE_API
                print(f"note: /tests/overview.json not usable ({error}); using /api/v1")
                jobs, complete = api_jobs(
                    client, group, entry, results, args.todo, args.test, reserve + later
                )
                if not complete:
                    note = "warning: request cap reached, '?' marks jobs whose comments were not read"
        prefixes = {job["prefix"] for job in jobs}
        prefix = prefixes.pop() if len(prefixes) == 1 and len(jobs) > 1 else ""
        as_of = _iso(args.before) if args.before is not None else None
        print(header(group, name, entry, mode, prefix, as_of))
        if note:
            print(note)
        jobs.sort(key=_order)
        victims = {}
        for job in [job for job in jobs if _never_ran(job)]:
            victims.setdefault(job["parents"][0], []).append(job["id"])
            jobs.remove(job)
        shown = jobs[: args.limit]
        if mode == MODE_OVERVIEW and not args.no_llm:
            read_llm(client, shown, reserve + later)
        for job in shown:
            if args.no_llm or job["result"] not in LLM_RESULTS:
                job["llm"] = None
            print(job_line(job, prefix))
            if job["llm"]:
                print(llm_line(job["llm"]))
        for parent, ids in sorted(victims.items()):
            print(
                f"victims parent={parent} never_ran={len(ids)} "
                f"jobs={toks(ids, 20, VICTIMS_SHOWN)}"
            )
        clusters = llm_clusters(shown)
        if clusters:
            print(clusters)
        if args.todo:
            kind = "jobs still to review"
        else:
            kind = "not-ok jobs" if as_of else "current not-ok jobs"
        if args.include_softfailed:
            kind += " (softfailed included)"
        if args.test:
            kind += " whose test matches --test"
        running = sum(job["result"] == "running" for job in jobs) if as_of else 0
        if as_of:
            kind += f" as of --before, {running} running then"
        count = len(jobs) - running + sum(len(ids) for ids in victims.values())
        cut = (
            f", {args.limit} lines shown (--limit N)" if len(jobs) > args.limit else ""
        )
        print(f"{count} {kind}{cut}")
        listed += count
    return listed


def _literal_test(pattern):
    match = pattern and LITERAL_TEST.fullmatch(pattern.pattern)
    return match.group(1) if match else None


def passed_jobs(client, group, entry, module, limit, pattern=None):
    """scope=current drops jobs that were restarted afterwards. Name and
    result of the module are matched on the same row, so it is M that passed.
    Returns (jobs, whether the server may have more)."""
    params = [("groupid", group), ("build", entry["build"])]
    if entry.get("version") is not None:
        params.append(("version", entry["version"]))
    params += [("scope", "current"), ("latest", 1)]
    params.append(("result", ",".join(CLONE_SOURCES)))
    if module:
        params += [("modules", module), ("modules_result", "passed")]
    fetch, name = limit, _literal_test(pattern)
    if name:
        params.append(("test", name))
    elif pattern:
        fetch = max(limit, TEST_WINDOW)
    params.append(("limit", fetch))
    jobs = client.get_json("/api/v1/jobs", params).get("jobs") or ()
    # Checked again here: a server that ignores a filter must not widen the list.
    kept = [
        job
        for job in jobs
        if _oqa.job_id_of(job.get("id"))
        and job.get("result") in CLONE_SOURCES
        and not job.get("clone_id")
        and (not module or _module_passed(job, module))
    ]
    kept = _of_test(kept, pattern, _api_test)
    return kept[:limit], len(jobs) >= fetch


def _module_passed(job, module):
    return any(
        item.get("name") == module and item.get("result") == "passed"
        for item in job.get("modules") or ()
    )


def passed_line(job):
    settings = job.get("settings") or {}
    test = str(settings.get("TEST"))
    if settings.get("MACHINE"):
        test += f"@{settings['MACHINE']}"
    parts = [
        str(job["id"]),
        tok(test, 100),
        f"result={job['result']}",
        f"arch={tok(settings.get('ARCH'), 20)}",
    ]
    fields = (("flavor", "FLAVOR"), ("hdd", "HDD_1"), ("publishes", "PUBLISH_HDD_1"))
    parts += [
        f"{key}={tok(settings[name], 120)}"
        for key, name in fields
        if settings.get(name)
    ]
    parents = _parents(job)
    if parents:
        parts.append("parents=" + ",".join(str(parent) for parent in parents[:6]))
    return " ".join(parts)


def sweep_passed(client, group, args):
    name, entries = pick_builds(client, group, args.build)
    listed = 0
    for entry in entries:
        jobs, more = passed_jobs(
            client, group, entry, args.module, args.limit, args.test
        )
        print(header(group, name, entry, MODE_OVERVIEW, ""))
        for job in sorted(jobs, key=lambda job: job["id"]):
            print(passed_line(job))
        kind = "current passed or softfailed jobs"
        if args.module:
            kind += f" with module {tok(args.module, 60)} passed"
        if args.test:
            kind += " whose test matches --test"
        cut = ", more may exist (--limit N)" if more else ""
        windowed = args.test and not _literal_test(args.test)
        if more and windowed and len(jobs) < args.limit:
            window = max(args.limit, TEST_WINDOW)
            cut = f", only the newest {window} were searched ('^NAME$' is filtered by openQA)"
        print(f"{len(jobs)} {kind}{cut}")
        listed += len(jobs)
    return listed


def _settings(entry):
    """{key: value} of a test suite or job template; a '+' prefix only raises precedence."""
    found = {}
    for item in entry.get("settings") or ():
        if isinstance(item, dict) and isinstance(item.get("key"), str):
            found[item["key"]] = str(item.get("value"))
    return found


def _schedule_of(template, suites):
    """YAML_SCHEDULE as openQA merges it: test suite, then job template, '+KEY' on top."""
    product, machine = template.get("product") or {}, template.get("machine") or {}
    suite = str((template.get("test_suite") or {}).get("name"))
    layers = (suites.get(suite, {}), _settings(template))
    value = None
    for key in ("YAML_SCHEDULE", "+YAML_SCHEDULE"):
        for layer in layers:
            value = layer.get(key, value)
    scenario = {
        "DISTRI": product.get("distri"),
        "VERSION": product.get("version"),
        "FLAVOR": product.get("flavor"),
        "ARCH": product.get("arch"),
        "MACHINE": machine.get("name"),
        "TEST": suite,
    }
    if value:
        value = re.sub(
            r"%([A-Z]+)%",
            lambda found: str(scenario.get(found.group(1), found.group())),
            value,
        )
    return value, scenario


def _newest_job(client, group, scenario, path, by_test):
    params = [("groupid", group)]
    params += [
        (key.lower(), scenario[key])
        for key in SCENARIO_KEYS
        if scenario[key] is not None and (key != "TEST" or by_test)
    ]
    params += [("job_setting", f"YAML_SCHEDULE={path}"), ("limit", 1)]
    for job in client.get_json("/api/v1/jobs", params).get("jobs") or ():
        settings = job.get("settings") or {}
        # Checked again here: a server that ignores the filter must not invent a user.
        if _oqa.job_id_of(job.get("id")) and settings.get("YAML_SCHEDULE") == path:
            return job
    return None


def uses_schedule(client, args):
    path = args.uses_schedule
    groups = {group: None for group in args.group or ()}
    if args.match:
        found = matching_groups(client, args.match)
        groups.update({row[0]: row[1] for row in found if isinstance(row[0], int)})
    if len(groups) > MAX_SCHEDULE_GROUPS:
        raise _oqa.OqaError(
            f"{len(groups)} groups selected, at most {MAX_SCHEDULE_GROUPS} are read: "
            "narrow it (see --groups --match)"
        )
    print(f"schedule={tok(path, 160)} groups={len(groups)}")
    suites = {}
    if groups:
        for suite in client.get_json("/api/v1/test_suites")["TestSuites"]:
            suites[str(suite.get("name"))] = _settings(suite)
    listed, capped = 0, False
    for index, (group, name) in enumerate(groups.items()):
        templates = client.get_json("/api/v1/job_templates", {"group_id": group})
        templates = templates["JobTemplates"]
        users = []
        for template in templates:
            value, scenario = _schedule_of(template, suites)
            if value == path:
                name = name or template.get("group_name")
                users.append(scenario)
        users.sort(key=lambda scenario: [str(scenario[key]) for key in SCENARIO_KEYS])
        print(
            f"group={group} name={_oqa.quoted(name or '?')} templates={len(templates)} "
            f"scenarios={len(users)}"
        )
        media = [[scenario[key] for key in SCENARIO_KEYS[:5]] for scenario in users]
        for scenario, medium in list(zip(users, media))[: args.limit]:
            parts = [f"group={group}"]
            job, missing = None, "-"
            # Keep one request for the templates of each group still to come.
            if client.requests < client.max_requests - (len(groups) - index - 1):
                job = _newest_job(
                    client, group, scenario, path, media.count(medium) > 1
                )
            else:
                missing, capped = "?", True
            test = (job or {}).get("settings", {}).get("TEST") or scenario["TEST"]
            for key in ("VERSION", "FLAVOR", "ARCH", "MACHINE"):
                parts.append(f"{key.lower()}={tok(scenario[key], 40)}")
            parts.append(f"test={tok(test, 100)}")
            if job:
                done = job.get("state") == "done"
                result = job.get("result") if done else job.get("state")
                build = (job.get("settings") or {}).get("BUILD")
                parts += [
                    f"job={job['id']}",
                    f"result={tok(result, 20)}",
                    f"build={tok(build, 40)}",
                ]
            else:
                parts.append(f"job={missing}")
            print(" ".join(parts))
        if len(users) > args.limit:
            print(f"{len(users) - args.limit} more scenarios not shown (--limit N)")
        listed += len(users)
    if capped:
        print(
            "warning: request cap reached, '?' marks scenarios whose newest job was not looked up"
        )
    print(f"{listed} scenario(s) use this schedule")
    return listed


def _test_git_hash(client, job_id):
    """TEST_GIT_HASH of a run, or None. vars.json also holds the job's token: nothing else of it is kept."""
    try:
        data = client.get_json(f"/tests/{job_id}/file/vars.json", max_bytes=VARS_BYTES)
    except _oqa.OqaError:
        return None
    value = data.get("TEST_GIT_HASH") if isinstance(data, dict) else None
    value = value.lower() if isinstance(value, str) else ""
    return value if GIT_HASH.fullmatch(value) else None


def vr_runs(client, args):
    label = args.vr_build
    params = {"build": label, "limit": VR_FETCH}
    fetched = [
        job
        for job in client.get_json("/api/v1/jobs", params).get("jobs") or ()
        # Checked again here: a server that ignores the filter must not widen the list.
        if _oqa.job_id_of(job.get("id"))
        and (job.get("settings") or {}).get("BUILD") == label
    ]
    # Folded here, not with latest=1: openQA applies limit before latest, which hides the cut.
    newest = {}
    for job in sorted(fetched, key=lambda job: job["id"], reverse=True):
        settings = job.get("settings") or {}
        newest.setdefault(tuple(str(settings.get(key)) for key in SCENARIO_KEYS), job)
    jobs = sorted(newest.values(), key=lambda job: job["id"])
    shown = jobs[-args.limit :]
    tests = [str((job.get("settings") or {}).get("TEST")) for job in shown]
    suffixes = {test.partition("@")[2] for test in tests}
    suffix = suffixes.pop() if len(suffixes) == 1 and len(tests) > 1 else ""
    header = f"vr_build={tok(label, 160)} runs={len(jobs)}"
    print(header + (f" test_suffix={tok('@' + suffix, 160)}" if suffix else ""))
    capped = False
    for job, test in zip(shown, tests):
        settings = job.get("settings") or {}
        if suffix:
            test = test[: -len(suffix) - 1]
        if settings.get("MACHINE"):
            test += f"@{settings['MACHINE']}"
        done = job.get("state") == "done"
        sha = None
        if done and client.requests >= client.max_requests:
            capped = True
        elif done:
            sha = _test_git_hash(client, job["id"])
        parts = [
            f"{client.host}/tests/{job['id']}",
            tok(test, 100),
            f"result={tok(job.get('result') if done else job.get('state'), 20)}",
            f"hash={sha[:HASH_SHOWN] if sha else '?'}",
        ]
        if args.test_git_hash and sha:
            short, full = sorted((sha, args.test_git_hash), key=len)
            parts.append("head=" + ("yes" if full.startswith(short) else "no"))
        elif args.test_git_hash:
            parts.append("head=?")
        failed = next(
            (
                module.get("name")
                for module in job.get("modules") or ()
                if isinstance(module, dict) and module.get("result") == "failed"
            ),
            None,
        )
        if failed:
            parts.append(f"first_failed={tok(failed, 60)}")
        print(" ".join(parts))
    if capped:
        print(
            "warning: request cap reached, hash=? marks runs whose vars.json was not read"
        )
    more = len(jobs) - len(shown)
    cut = f", {more} more not shown (--limit N)" if more else ""
    if len(fetched) >= VR_FETCH:
        cut += f", only the newest {VR_FETCH} jobs of this BUILD were read"
    print(f"{len(jobs)} verification run(s) with this BUILD{cut}")
    return len(jobs)


def _never_ran(job):
    return (
        job["result"] in ("cancelled", "skipped")
        and job["parents"]
        and not (job["modules"] or job["refs"] or job["label"] or job["comments"])
    )


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be >= 1")
    return number


def test_regex(value):
    try:
        return re.compile(value)
    except re.error as error:
        raise argparse.ArgumentTypeError(f"not a valid regex: {error}") from None


def before_time(value):
    stamp = _oqa.parse_time(value)
    if stamp is None:
        raise argparse.ArgumentTypeError(
            "expected an ISO 8601 time such as 2030-01-02T10:00Z"
        )
    return stamp


def git_hash(value):
    if not GIT_HASH.fullmatch(value.lower()):
        raise argparse.ArgumentTypeError("must be 7 to 40 hex digits")
    return value.lower()


def main():
    parser = ArgumentParser(
        prog="oqa-sweep.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
        description="Review work-list of openQA job groups (GET only).",
    )
    _oqa.add_common_args(parser)
    parser.add_argument(
        "--group",
        type=positive,
        action="append",
        metavar="ID",
        help="job group id; repeat for several groups",
    )
    parser.add_argument(
        "--build", help="build to look at (default: latest build of the group)"
    )
    parser.add_argument(
        "--todo",
        action="store_true",
        help="only jobs that do not yet count as reviewed (no bugref, no label)",
    )
    parser.add_argument(
        "--include-softfailed", action="store_true", help="also list softfailed jobs"
    )
    parser.add_argument(
        "--test",
        type=test_regex,
        metavar="REGEX",
        help="only jobs whose test name, without @machine, matches (a Python regex "
        "searched in it, case-sensitive), e.g. '^ltp_syscalls$' for one scenario across "
        "flavors and arches; with --passed openQA filters such a literal name, any other "
        "regex searches the newest 100 clone sources",
    )
    parser.add_argument(
        "--before",
        type=before_time,
        metavar="TIME",
        help="the build as it stood at TIME (ISO 8601 such as 2030-01-02T10:00Z, UTC "
        "unless it has an offset): per scenario the newest job that had started by then, "
        "its result then, bugrefs and labels of comments created by then; needs --build",
    )
    parser.add_argument(
        "--limit",
        type=positive,
        metavar="N",
        help="job lines per build (default: 30, with --passed 10)",
    )
    parser.add_argument(
        "--no-llm",
        action="store_true",
        help="do not read the automatic LLM investigation summaries (one comments request per failed job)",
    )
    parser.add_argument(
        "--passed",
        action="store_true",
        help="list current passed jobs instead: a source job to clone for a verification run",
    )
    parser.add_argument(
        "--module",
        metavar="NAME",
        help="with --passed: only jobs in which this test module ran and passed",
    )
    parser.add_argument(
        "--groups",
        action="store_true",
        help="list job groups (id, name, parent) and exit",
    )
    parser.add_argument(
        "--match",
        metavar="REGEX",
        help="with --groups or --uses-schedule: groups whose 'parent / name' matches "
        "(case-insensitive)",
    )
    parser.add_argument(
        "--uses-schedule",
        metavar="PATH",
        help="list the scenarios whose YAML_SCHEDULE is this schedule file, e.g. "
        "schedule/foo/bar.yaml; needs --group and/or --match",
    )
    parser.add_argument(
        "--vr-build",
        metavar="LABEL",
        help="list the verification runs whose BUILD is LABEL, e.g. "
        "user/os-autoinst-distri-opensuse#123: they have no group",
    )
    parser.add_argument(
        "--test-git-hash",
        type=git_hash,
        metavar="SHA",
        help="with --vr-build: head=yes when a run's TEST_GIT_HASH is this commit",
    )
    parser.add_argument(
        "--exit-code",
        action="store_true",
        help="exit 1 when not-ok jobs are listed, or when --passed, --groups, "
        "--uses-schedule or --vr-build list nothing (default: exit 0 whenever the "
        "listing was produced)",
    )
    args = parser.parse_args()
    if args.before is not None:
        others = (args.uses_schedule, args.vr_build)
        if args.passed or args.groups or others != (None, None):
            parser.error(
                "--before goes with the not-ok listing of --group ID --build B only: "
                "--passed lists clone sources, which are current jobs"
            )
        if args.build is None:
            parser.error(
                "--before needs --build B: the group's newest build may not have "
                "existed then"
            )
    if args.vr_build is not None:
        others = (args.group, args.groups, args.build, args.match, args.passed)
        others += (args.module, args.todo, args.include_softfailed, args.no_llm)
        if any(others) or args.uses_schedule is not None:
            parser.error(
                "--vr-build goes with --test-git-hash, --limit and --exit-code only"
            )
        if not args.vr_build.strip():
            parser.error("--vr-build needs a BUILD label")
    elif args.test_git_hash:
        parser.error("--test-git-hash needs --vr-build")
    elif args.uses_schedule is not None:
        if args.groups or args.passed or args.todo or args.include_softfailed:
            parser.error("--uses-schedule goes with --group, --match and --limit only")
        if args.build:
            parser.error("--uses-schedule goes with --group, --match and --limit only")
        if not (args.group or args.match):
            parser.error(
                "--uses-schedule needs --group ID and/or --match REGEX to bound it"
            )
        if not SCHEDULE_PATH.fullmatch(args.uses_schedule):
            parser.error(
                "--uses-schedule takes a relative path like schedule/foo/bar.yaml"
            )
    elif args.build is not None and not args.group:
        parser.error(
            "--build needs --group ID: find the id with --groups --match REGEX "
            "(a verification run has no group: --vr-build LABEL)"
        )
    elif args.groups == bool(args.group):
        parser.error("give either --group ID (repeatable) or --groups")
    elif args.match and not args.groups:
        parser.error("--match needs --groups or --uses-schedule")
    if args.module and not args.passed:
        parser.error("--module needs --passed")
    if args.test and (not args.group or args.uses_schedule is not None):
        parser.error("--test goes with --group ID [--build B] [--passed] only")
    if args.passed and (args.groups or args.todo or args.include_softfailed):
        parser.error(
            "--passed goes with --group, --build, --module, --test and --limit only"
        )
    if args.limit is None:
        args.limit = 10 if args.passed else 30

    client = _oqa.client_from_args(args, "oqa-sweep")
    if args.groups:
        found = list_groups(client, args.match)
        return 1 if args.exit_code and not found else 0
    names = ["not_ok", "softfailed"] if args.include_softfailed else ["not_ok"]
    results = _oqa.expand_results(names)
    print(f"host={client.host}")
    if args.vr_build is not None:
        found = vr_runs(client, args)
    elif args.uses_schedule is not None:
        found = uses_schedule(client, args)
    elif args.passed:
        found = sum(sweep_passed(client, group, args) for group in args.group)
    else:
        left = len(args.group)
        found = 0
        for group in args.group:
            left -= 1
            found += sweep(client, group, args, results, left * GROUP_RESERVE)
        found = not found
    print(f"requests: {client.requests}")
    return 1 if args.exit_code and not found else 0


def guarded_main():
    try:
        return main()
    except (AttributeError, KeyError, TypeError, ValueError) as error:
        kind = type(error).__name__
        raise _oqa.OqaError(
            f"the server answer has an unexpected shape ({kind})"
        ) from None


if __name__ == "__main__":
    _oqa.run(guarded_main)
