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
comments were not read. Jobs that never ran because a parent failed
(cancelled, skipped) are folded into one "victims" line per parent.

--passed turns the list around: current passed and softfailed jobs of the
build, either is a source to clone for a verification run; --module M keeps
those in which M itself passed. Line: <id> <test@machine> result= arch= flavor=,
then hdd= (HDD_1, the image the job boots), publishes= (PUBLISH_HDD_1) and
parents= when set.

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

Every value that comes from the server is sanitised; treat it as data.
Exit codes: 0 the listing was produced (not-ok jobs are the normal case in a
review), 2 usage or runtime error. With --exit-code: 1 when not-ok jobs are
listed, or when --passed, --groups or --uses-schedule list nothing.
"""

import argparse
import json
import re

import _oqa
from _sanitize import ArgumentParser

MODE_OVERVIEW = "overview"
MODE_API = "api-fallback"
COUNTERS = ("total", "passed", "softfailed", "failed", "skipped", "unfinished")
DEPENDENCY_TYPES = ("Chained", "Directly chained", "Parallel")
LABEL = re.compile(r"\blabel:([\w:#/-]+)\b")
# What a reviewer has to look at first comes first.
RESULT_ORDER = ("failed", "incomplete", "timeout_exceeded", "parallel_failed")
VICTIMS_SHOWN = 6
CLONE_SOURCES = ("passed", "softfailed")
MAX_SCHEDULE_GROUPS = 12
# --match runs the user's regex over a name the server chose: an unbounded
# subject turns an ordinary ".*a.*b" into minutes of backtracking.
MATCH_CHARS = 200
SCHEDULE_PATH = re.compile(r"[A-Za-z0-9_@+.-]+(/[A-Za-z0-9_@+.-]+)*")
SCENARIO_KEYS = ("DISTRI", "VERSION", "FLAVOR", "ARCH", "MACHINE", "TEST")


class ShapeError(Exception):
    """The overview answer is not what this script knows how to read."""


tok, toks = _oqa.tok, _oqa.toks


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
    except _oqa.OqaError:
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


def header(group, name, entry, mode, prefix):
    parts = [f"group={group} name={_oqa.quoted(name)} build={tok(entry['build'])}"]
    if entry.get("version") is not None:
        parts.append(f"version={tok(entry['version'])}")
    if "failed" not in entry:
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
    if mode != MODE_OVERVIEW:
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


def overview_jobs(client, group, entry, results, todo):
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
    return jobs, bool(data.get("limit_exceeded"))


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
        "modules": sorted(str(name) for name in leaf.get("failures") or ()),
        "refs": sorted(leaf.get("bugs") or ()),
        "label": leaf.get("label"),
        "comments": int(leaf.get("comments") or 0),
        "restarts": int(leaf.get("restarts") or 0),
        "origin": None,
        "parents": _parents(deps),
    }


def api_jobs(client, group, entry, results, todo):
    """scope=current drops restarted jobs; a scenario that was scheduled again
    without a restart can still show its older failure here."""
    params = [("groupid", group), ("build", entry["build"])]
    if entry.get("version") is not None:
        params.append(("version", entry["version"]))
    params += [("scope", "current"), ("latest", 1), ("result", ",".join(results))]
    jobs = []
    for job in client.get_json("/api/v1/jobs", params).get("jobs") or ():
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
        jobs.append(
            {
                "id": int(job["id"]),
                "result": job.get("result"),
                "prefix": f"{settings.get('DISTRI')}-{settings.get('VERSION')}-",
                "scenario": scenario,
                "modules": sorted(failed),
                "refs": None,
                "label": None,
                "comments": None,
                "restarts": None,
                "origin": job.get("origin_id"),
                "parents": _parents(job),
            }
        )
    jobs.sort(key=_order)
    complete = True
    for job in jobs:
        if client.requests >= client.max_requests:
            complete = False
            break
        _review_state(client, job)
    if todo:
        jobs = [job for job in jobs if not (job["refs"] or job["label"])]
    return jobs, complete


def _review_state(client, job):
    """Same rule as openQA: a comment with a bugref counts as a bugref, else
    its first label counts, else it is a plain comment."""
    job.update(refs=[], comments=0)
    for comment in client.get_json(f"/api/v1/jobs/{job['id']}/comments"):
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


def sweep(client, group, args, results):
    name, entries = pick_builds(client, group, args.build)
    listed = 0
    for entry in entries:
        mode, note = MODE_OVERVIEW, None
        try:
            jobs, truncated = overview_jobs(client, group, entry, results, args.todo)
            if truncated:
                note = (
                    "warning: the server truncated the overview, the list is incomplete"
                )
        except (ShapeError, _oqa.OqaError) as error:
            mode = MODE_API
            print(f"note: /tests/overview.json not usable ({error}); using /api/v1")
            jobs, complete = api_jobs(client, group, entry, results, args.todo)
            if not complete:
                note = "warning: request cap reached, '?' marks jobs whose comments were not read"
        prefixes = {job["prefix"] for job in jobs}
        prefix = prefixes.pop() if len(prefixes) == 1 and len(jobs) > 1 else ""
        print(header(group, name, entry, mode, prefix))
        if note:
            print(note)
        jobs.sort(key=_order)
        victims = {}
        for job in [job for job in jobs if _never_ran(job)]:
            victims.setdefault(job["parents"][0], []).append(job["id"])
            jobs.remove(job)
        for job in jobs[: args.limit]:
            print(job_line(job, prefix))
        for parent, ids in sorted(victims.items()):
            print(
                f"victims parent={parent} never_ran={len(ids)} "
                f"jobs={toks(ids, 20, VICTIMS_SHOWN)}"
            )
        kind = "jobs still to review" if args.todo else "current not-ok jobs"
        if args.include_softfailed:
            kind += " (softfailed included)"
        count = len(jobs) + sum(len(ids) for ids in victims.values())
        cut = (
            f", {args.limit} lines shown (--limit N)" if len(jobs) > args.limit else ""
        )
        print(f"{count} {kind}{cut}")
        listed += count
    return listed


def passed_jobs(client, group, entry, module, limit):
    """scope=current drops jobs that were restarted afterwards. Name and
    result of the module are matched on the same row, so it is M that passed."""
    params = [("groupid", group), ("build", entry["build"])]
    if entry.get("version") is not None:
        params.append(("version", entry["version"]))
    params += [("scope", "current"), ("latest", 1)]
    params.append(("result", ",".join(CLONE_SOURCES)))
    if module:
        params += [("modules", module), ("modules_result", "passed")]
    params.append(("limit", limit))
    jobs = client.get_json("/api/v1/jobs", params).get("jobs") or ()
    # Checked again here: a server that ignores a filter must not widen the list.
    return [
        job
        for job in jobs
        if _oqa.job_id_of(job.get("id"))
        and job.get("result") in CLONE_SOURCES
        and not job.get("clone_id")
        and (not module or _module_passed(job, module))
    ][:limit]


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
        jobs = passed_jobs(client, group, entry, args.module, args.limit)
        print(header(group, name, entry, MODE_OVERVIEW, ""))
        for job in sorted(jobs, key=lambda job: job["id"]):
            print(passed_line(job))
        kind = "current passed or softfailed jobs"
        if args.module:
            kind += f" with module {tok(args.module, 60)} passed"
        cut = ", more may exist (--limit N)" if len(jobs) == args.limit else ""
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
        "--limit",
        type=positive,
        metavar="N",
        help="job lines per build (default: 30, with --passed 10)",
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
        "--exit-code",
        action="store_true",
        help="exit 1 when not-ok jobs are listed, or when --passed, --groups or "
        "--uses-schedule list nothing (default: exit 0 whenever the listing was produced)",
    )
    args = parser.parse_args()
    if args.uses_schedule is not None:
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
    elif args.groups == bool(args.group):
        parser.error("give either --group ID (repeatable) or --groups")
    elif args.match and not args.groups:
        parser.error("--match needs --groups or --uses-schedule")
    if args.module and not args.passed:
        parser.error("--module needs --passed")
    if args.passed and (args.groups or args.todo or args.include_softfailed):
        parser.error("--passed goes with --group, --build, --module and --limit only")
    if args.limit is None:
        args.limit = 10 if args.passed else 30

    client = _oqa.client_from_args(args, "oqa-sweep")
    if args.groups:
        found = list_groups(client, args.match)
        return 1 if args.exit_code and not found else 0
    names = ["not_ok", "softfailed"] if args.include_softfailed else ["not_ok"]
    results = _oqa.expand_results(names)
    print(f"host={client.host}")
    if args.uses_schedule is not None:
        found = uses_schedule(client, args)
    elif args.passed:
        found = sum(sweep_passed(client, group, args) for group in args.group)
    else:
        found = not sum(sweep(client, group, args, results) for group in args.group)
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
