#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Build (never run) the clone command for an openQA verification run, with the known hazards handled.
"""Prints one command line, then at most 8 short lines about what it does.

Nothing is executed. Only --test-hash uses the network: one GET of the job's vars.json
through _oqa.py, from the host of the job URL. The printed command is for review.
"""

import argparse
import os
import re
import shlex
import sys
from urllib.parse import urlsplit

# python3 -I leaves the script's own directory off sys.path; the sibling modules live there.
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import _oqa
import _secrets
from _sanitize import ArgumentParser, sanitize

PRODUCTION_HOSTS = ("openqa.opensuse.org", "openqa.suse.de", "openqa.debian.net")
# A single argv string can be ~128 kB; nothing here needs more than a long SCHEDULE.
MAX_ARG = 8192
VARS_BYTES = 256 * 1024
# What marks a public-cloud job in os-autoinst-distri-opensuse: is_public_cloud(), is_ec2() and siblings.
PUBLIC_CLOUD_KEYS = ("PUBLIC_CLOUD", "PUBLIC_CLOUD_PROVIDER")
HELPER_DEFAULTS = "--skip-chained-deps --parental-inheritance --within-instance"
# --set must not fight the options that own these keys.
MANAGED_KEYS = {
    "_GROUP": "_GROUP=0 is always set",
    "_GROUP_ID": "_GROUP=0 is always set",
    "CASEDIR": "use --fork/--branch, --pr or --test-hash",
    "BUILD": "use --label",
    "SCHEDULE": "use --schedule",
}

# Same shape as the regex in OpenQA::Script::CloneJob, but anchored: upstream is
# unanchored, so "myVAR=1" is silently applied as "VAR=1". The scope accepts the
# same language as upstream's X+(Y+X)? written so that a failing match cannot
# split the run in quadratically many ways.
_TEST_CHARS = r"\w _*.,:/#@"
_SETTING = re.compile(
    rf"([A-Z0-9_]+(?:\[\])?)(?::([{_TEST_CHARS}](?:[{_TEST_CHARS}+-]*[{_TEST_CHARS}])?))?(\+)?=(.*)"
)
_TEST_SUFFIX = re.compile(rf"[{_TEST_CHARS}+-]+")
_PR_URL = re.compile(
    r"https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)/pull/([0-9]+)(?:[/#?].*)?"
)
_NETLOC = re.compile(
    r"(?:[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?|\[[0-9a-f:.]+\])(?::[0-9]{1,5})?",
    re.IGNORECASE,
)
_GITHUB_USER = re.compile(r"[A-Za-z0-9-]+")
_GITHUB_REPO = re.compile(r"[A-Za-z0-9._-]+")
_GIT_HASH = re.compile(r"[0-9a-f]{7,40}")
_GIT_PATH = re.compile(r"(?:/[A-Za-z0-9._~+-]+)+")
_MODULE_EXT = (".pm", ".py", ".lua")
# Literal stand-ins for a fork that is not known yet; emitted verbatim.
_USER_PLACEHOLDER = "<user>"
_BRANCH_PLACEHOLDER = "<branch>"


class UsageError(Exception):
    pass


def check_clean(name, value):
    if len(value) > MAX_ARG:
        raise UsageError(f"{name}: longer than {MAX_ARG} characters ({len(value)})")
    # sanitize() strips invisible characters before it redacts, so a credential split up
    # with them shows here too; neither message below may then echo the value.
    cleaned = sanitize(value, max_line=0, max_bytes=0)
    rules = sorted(set(re.findall(r"\[REDACTED:([a-z-]+)\]", cleaned)))
    if rules:
        raise UsageError(
            f"{name}: contains a credential ({', '.join(rules)}); keep it out of the "
            "command line, in the tool's own config or the job's settings"
        )
    if value != cleaned or "\n" in value:
        raise UsageError(
            f"{name}: contains control or invisible characters: {shown(value)}"
        )


def shown(value):
    # Userinfo can hold a password no redaction rule recognises, a secret setting any value.
    if any(
        _secrets.is_secret_key(n)
        for n in re.findall(r"\w+", value.partition("=")[0], re.ASCII)
    ):
        return "a credential setting (not echoed)"
    return "a value holding '@' (not echoed)" if "@" in value else ascii(value)


def parse_job(values):
    if len(values) > 2:
        raise UsageError("--job takes a job URL, or a host and a job id")
    ref = values[0]
    if not re.match(r"https?://", ref):
        host = ref.split("/", 1)[0].split(":", 1)[0]
        # openqa-clone-job assumes http:// for a bare host; the production hosts need https.
        ref = ("https://" if host in PRODUCTION_HOSTS else "http://") + ref
    try:
        parts = urlsplit(ref)
    except ValueError:
        parts = None
    # "https://known.host@other.host/tests/1" would fetch from other.host.
    if not parts or not _NETLOC.fullmatch(parts.netloc):
        raise UsageError(
            f"--job: not a plain host name (no user@, ASCII only) in {shown(values[0])}"
        )
    if len(values) == 2:
        job_id = values[1]
        if parts.path.strip("/"):
            raise UsageError(
                "--job: give either a job URL or a bare host plus an id, not both"
            )
    else:
        match = re.match(r"/(?:tests/|t)([0-9]+)(?:/|$)", parts.path)
        if not match:
            raise UsageError(f"--job: no /tests/<id> or /t<id> in {shown(values[0])}")
        job_id = match.group(1)
    if not re.fullmatch(r"[0-9]+", job_id):
        raise UsageError(f"--job: job id must be a number, got {shown(job_id)}")
    return parts.hostname, f"{parts.scheme}://{parts.netloc}", job_id


def parse_setting(arg):
    match = _SETTING.fullmatch(arg)
    # By name, whatever the value looks like: redaction only knows credential shapes.
    name = re.match(r"\w*", arg, re.ASCII).group()
    if _secrets.is_secret_key(name) and not (match and match.group(4) == ""):
        raise UsageError(
            f"--set {name}: a credential setting; keep it out of the command line, "
            "in the tool's own config or the job's settings"
        )
    if not match:
        raise UsageError(
            f"--set {shown(arg)}: expected KEY=VALUE, KEY= or KEY+=VALUE with an uppercase "
            "[A-Z0-9_] key (openqa-clone-job ignores or misparses anything else)"
        )
    key = match.group(1)
    if key in MANAGED_KEYS:
        raise UsageError(f"--set {key}: {MANAGED_KEYS[key]}")
    return {
        "arg": arg,
        "key": key,
        "scope": match.group(2),
        "plus": bool(match.group(3)),
        "value": match.group(4),
    }


def check_schedule(value, settings):
    """Return hazard fragments; raise UsageError for entries os-autoinst cannot load."""
    entries = value.split(",")
    lacks_prefix, bare, seen = [], [], {}
    for entry in entries:
        if not entry or re.search(r"\s", entry):
            raise UsageError("--schedule: empty entry or whitespace in the comma list")
        if entry.startswith("/") or ".." in entry.split("/"):
            raise UsageError(
                f"--schedule {shown(entry)}: must be a relative path within CASEDIR"
            )
        # os-autoinst appends .pm only when the entry has no dot at all.
        if "." in entry and not entry.endswith(_MODULE_EXT):
            raise UsageError(
                f"--schedule {shown(entry)}: a dot disables the implicit .pm; end it with .pm, .py or .lua"
            )
        path = entry if "." in entry else entry + ".pm"
        directory, _, filename = path.rpartition("/")
        basename = filename.rsplit(".", 1)[0]
        if seen.setdefault(basename, directory) != directory:
            raise UsageError(
                f"--schedule: basename {shown(basename)} used from two directories; os-autoinst dies on that"
            )
        if not directory:
            bare.append(entry)
        elif not entry.startswith("tests/"):
            lacks_prefix.append(entry)
    found = []
    if lacks_prefix:
        found.append(
            f"{' '.join(lacks_prefix)} lacks the tests/ prefix (paths are relative to CASEDIR; "
            "only YAML schedules omit it)"
        )
    if bare and not any(re.fullmatch(r"ASSET_[0-9]+_URL", s["key"]) for s in settings):
        found.append(
            f"bare name {' '.join(bare)} needs an ASSET_<n>_URL sideload or a wheel"
        )
    if any(s["key"] == "INCLUDE_MODULES" and s["value"] for s in settings):
        found.append("INCLUDE_MODULES is discarded")
    return found


def github_casedir(user, repo, ref):
    return f"https://github.com/{user}/{repo}.git#{ref}"


def test_git_url(base_url, job_id, fixture_dir):
    """(TEST_GIT_URL, whether it is a public-cloud job) from the job's vars.json, read from
    the host of the job URL. The file also holds the job's token: nothing else of it is
    kept, and no value is echoed."""
    where = f"--test-hash: vars.json of job {job_id}"
    try:
        client = _oqa.Client(
            base_url, script="vr-clone-cmd", fixture_dir=fixture_dir, max_requests=1
        )
        data = client.get_json(f"/tests/{job_id}/file/vars.json", max_bytes=VARS_BYTES)
    except _oqa.OqaError as error:
        raise UsageError(f"{where}: {error}") from None
    url = data.get("TEST_GIT_URL") if isinstance(data, dict) else None
    if not isinstance(url, str) or not url:
        raise UsageError(f"{where} has no TEST_GIT_URL")
    try:
        parts = urlsplit(url) if url.isascii() else None
    except ValueError:
        parts = None
    if not (
        parts
        and parts.scheme in ("http", "https")
        and _NETLOC.fullmatch(parts.netloc)
        and _GIT_PATH.fullmatch(parts.path)
        and not (parts.query or parts.fragment or "#" in url or "?" in url)
        and sanitize(url, max_line=0, max_bytes=0) == url
    ):
        raise UsageError(
            f"{where}: TEST_GIT_URL is not a plain http(s) Git URL (not echoed)"
        )
    return url, any(str(data.get(key) or "0") != "0" for key in PUBLIC_CLOUD_KEYS)


def build(args):
    for name, value in vars(args).items():
        for item in value if isinstance(value, list) else [value]:
            if isinstance(item, str):
                check_clean("--" + name.replace("_", "-"), item)

    pr_form = args.pr is not None
    fork_form = bool(args.fork or args.branch)
    if pr_form and fork_form:
        raise UsageError("--pr and --fork/--branch are mutually exclusive")
    if fork_form and not (args.fork and args.branch):
        raise UsageError("--fork USER and --branch REF go together")
    if args.test_hash is not None and (pr_form or fork_form):
        raise UsageError(
            "--test-hash pins CASEDIR itself: not with --pr or --fork/--branch"
        )
    if args.test_hash is not None and not _GIT_HASH.fullmatch(args.test_hash):
        raise UsageError(
            f"--test-hash: not a commit hash (7-40 lowercase hex digits): {shown(args.test_hash)}"
        )
    if bool(args.needles_fork) != bool(args.needles_branch):
        raise UsageError("--needles-fork and --needles-branch go together")
    plain_form = not (pr_form or fork_form or args.test_hash)
    if plain_form and not (args.set or args.schedule is not None or args.needles_fork):
        raise UsageError(
            "nothing to change: give --pr URL, --fork USER --branch REF, --test-hash SHA "
            "or a setting (--set, --schedule, --needles-fork)"
        )
    for name, value, pattern in (
        ("--fork", args.fork, _GITHUB_USER),
        ("--needles-fork", args.needles_fork, _GITHUB_USER),
        ("--repo-name", args.repo_name, _GITHUB_REPO),
        ("--needles-repo-name", args.needles_repo_name, _GITHUB_REPO),
    ):
        if pattern is _GITHUB_USER and value == _USER_PLACEHOLDER:
            continue
        if value and not pattern.fullmatch(value):
            raise UsageError(
                f"{name}: not a GitHub name: {shown(value)} (unknown yet? pass the literal '<user>')"
            )
    for name, value in (
        ("--branch", args.branch),
        ("--needles-branch", args.needles_branch),
    ):
        if value is not None and (not value or re.search(r"\s", value)):
            raise UsageError(f"{name}: must be a non-empty ref without whitespace")

    hostname, base_url, job_id = parse_job(args.job)
    job_url = f"{base_url}/tests/{job_id}"
    settings = [parse_setting(item) for item in args.set]
    if args.needles_fork and any(s["key"] == "NEEDLES_DIR" for s in settings):
        raise UsageError("--set NEEDLES_DIR conflicts with --needles-fork")

    hazards, notes = [], []
    public_cloud = False
    extra = ["_GROUP=0"]
    overrides = ["_GROUP"]

    if pr_form:
        match = _PR_URL.fullmatch(args.pr)
        if not match:
            raise UsageError(
                "--pr: expected https://github.com/<org>/<repo>/pull/<number>"
            )
        org, repo, number = match.groups()
        # The helper cuts the URLs with ${url%%/pull*} and ${url%%/t*}.
        if org.startswith("pull") or repo.startswith("pull"):
            raise UsageError(
                "--pr: the helper mis-parses an org/repo starting with 'pull'; use --fork/--branch"
            )
        if hostname.startswith("t"):
            raise UsageError(
                "--job: the helper mis-parses a host starting with 't'; use --fork/--branch"
            )
        if args.label:
            extra.append(f"BUILD={args.label}")
            overrides.append("BUILD")
    else:
        if fork_form:
            label = f"{args.fork}/{args.repo_name}#{args.branch}"
            suffix, what = "@" + label, "ref"
            casedir = github_casedir(args.fork, args.repo_name, args.branch)
        else:
            if args.test_hash:
                label = f"tests-{args.test_hash[:12]}"
                url, public_cloud = test_git_url(base_url, job_id, args.fixture_dir)
                casedir = f"{url}#{args.test_hash}"
            else:
                keys = [s["key"].removesuffix("[]") for s in settings]
                keys += ["SCHEDULE"] * (args.schedule is not None)
                keys += ["NEEDLES_DIR"] * bool(args.needles_fork)
                label = "set-" + "-".join(dict.fromkeys(keys))
                casedir = None
            label = args.label or label
            suffix, what = "-" + label, "label"
        extra += [s["arg"] for s in settings]
        extra.append(f"BUILD={args.label or label}")
        overrides.append("BUILD")
        # TEST is validated server-side; settings scoped to the old TEST name must come first.
        plain = suffix
        if fork_form:
            plain = plain.replace(_USER_PLACEHOLDER, "u").replace(
                _BRANCH_PLACEHOLDER, "b"
            )
        if _TEST_SUFFIX.fullmatch(plain):
            extra.append(f"TEST+={suffix}")
            overrides.append("TEST+=")
        else:
            hazards.append(
                f"{what} has characters not allowed in TEST: no TEST+= suffix, clone shares the scenario history"
            )
        if casedir:
            extra.append("CASEDIR=" + casedir)
            overrides.append("CASEDIR")

    if args.needles_fork:
        extra.append(
            "NEEDLES_DIR="
            + github_casedir(
                args.needles_fork, args.needles_repo_name, args.needles_branch
            )
        )
        overrides.append("NEEDLES_DIR")
    if args.schedule is not None:
        found = check_schedule(args.schedule, settings)
        if found:
            hazards.append("SCHEDULE: " + "; ".join(found))
        extra.append(f"SCHEDULE={args.schedule}")
        overrides.append("SCHEDULE")
    if pr_form:
        extra += [s["arg"] for s in settings]
        if any("'" in item for item in extra):
            raise UsageError(
                "a single quote breaks the helper's eval of extra arguments; use --fork/--branch"
            )
        if any(s["scope"] for s in settings):
            hazards.append(
                "KEY:<TEST>= runs after the helper's TEST+=, so the scope must name the suffixed TEST"
            )

    deletes = [s["key"] for s in settings if not s["value"]]
    overrides += [
        s["key"]
        + (":" + s["scope"] if s["scope"] else "")
        + ("+=" if s["plus"] else "")
        for s in settings
        if s["value"]
    ]
    has_needles = "NEEDLES_DIR" in overrides

    if pr_form:
        command = ["openqa-clone-custom-git-refspec"]
        if args.dry_run_flag:
            # -n alone prints nothing and -n -v traces GITHUB_TOKEN plus whole JSON bodies.
            command.append("--clone-job-args=--export-command")
        command.append(f"https://github.com/{org}/{repo}/pull/{number}")
        target = base_url
        how = f"helper adds {HELPER_DEFAULTS}"
        notes.append(
            "helper never sets NEEDLES_DIR; "
            + (
                "it is passed as an extra argument"
                if has_needles
                else "production needles are used"
            )
        )
        notes.append(
            "an '@openqa: Clone <url>' line in the PR body replaces the --job URL (helper reads the PR)"
        )
    else:
        command = ["openqa-clone-job"]
        if args.dry_run_flag:
            command.append("--export-command")
        if args.skip_chained_deps:
            command.append("--skip-chained-deps")
        # A run that only changes settings or the tests' commit belongs on the job's instance.
        if args.within_instance or not fork_form:
            command.append("--within-instance")
            target = base_url
            how = "no asset download, no missing-asset check"
        else:
            target = "http://localhost"
            how = f"assets downloaded from {base_url}; use --within-instance to stay on the source host"
        if plain_form:
            notes.append(
                "tests run at the instance's newest commit unless the job's CASEDIR pins one; "
                "--test-hash pins them"
            )
        elif not has_needles:
            notes.append(
                "no NEEDLES_DIR: a custom CASEDIR still uses production needles"
            )
        if args.test_hash and len(args.test_hash) < 40:
            notes.append(
                "a short hash is found by deepening the clone; the full TEST_GIT_HASH is fetched at once"
            )
        if args.parent_publishes and not args.skip_chained_deps:
            hazards.append(
                "parent publishes assets and --skip-chained-deps is missing: the cloned parent "
                "re-publishes the production file name"
            )
        if public_cloud and args.skip_chained_deps:
            hazards.append(
                "public-cloud job with --skip-chained-deps: the image its upload parent "
                "published may have been deleted since"
            )
    command += [job_url] + extra
    if _USER_PLACEHOLDER in (args.fork, args.needles_fork) or _BRANCH_PLACEHOLDER in (
        args.branch,
        args.needles_branch,
    ):
        notes.append("replace <user>/<branch> before running")

    if target == base_url and hostname in PRODUCTION_HOSTS:
        hazards.append(
            f"{hostname} is a production instance: shared workers, public results"
        )

    lines = [
        f"creates: clone of job {job_id} on {target}, outside any job group ({how})"
    ]
    summary = "overrides: " + " ".join(overrides)
    if pr_form:
        summary += f" (helper derives TEST+= {'' if args.label else 'BUILD '}CASEDIR PRODUCTDIR)"
    if deletes:
        summary += "; deletes: " + " ".join(deletes)
    lines.append(summary)
    lines += ["note: " + note for note in notes]
    lines += ["hazard: " + hazard for hazard in hazards]
    if args.dry_run_flag:
        lines.append(
            "approval: --export-command only reads and prints; without it this is a write needing approval"
        )
    else:
        lines.append(
            f"approval: running this posts jobs to {target}, a write; get the user's approval first"
        )
    return shlex.join(command), lines, bool(hazards)


def main(argv=None):
    parser = ArgumentParser(
        prog="vr-clone-cmd.py",
        description="Build, but never run, the command line that clones an openQA job as a verification run "
        "of a test-distribution branch or pull request, with changed settings only, or with the tests "
        "of another commit (a crossed run). _GROUP=0 is always included.",
        epilog="A fork that is not known yet: pass the literal '<user>' to --fork/--needles-fork and "
        "'<branch>' to --branch/--needles-branch; they are emitted verbatim with a note to replace them. "
        "Output: the command, then creates/overrides/note/hazard/approval lines (8 at most). "
        f"Exit codes: 0 no hazard, 1 command printed with hazard lines, 2 usage error, also an "
        f"argument over {MAX_ARG} characters.",
    )
    parser.add_argument(
        "--job",
        nargs="+",
        required=True,
        metavar="JOB",
        help="job URL (/tests/ID or /tID), or HOST and ID; the clone's instance and vars.json come from it",
    )
    parser.add_argument(
        "--pr",
        metavar="URL",
        help="GitHub PR URL: emit the openqa-clone-custom-git-refspec form",
    )
    parser.add_argument(
        "--fork",
        metavar="USER",
        help="GitHub account of the fork, or the literal '<user>': emit the openqa-clone-job form",
    )
    parser.add_argument(
        "--branch",
        metavar="REF",
        help="branch, tag or commit in the fork, or the literal '<branch>'",
    )
    parser.add_argument(
        "--test-hash",
        metavar="SHA",
        help="crossed run: pin CASEDIR to TEST_GIT_URL of the job's vars.json at this commit (one GET)",
    )
    parser.add_argument(
        "--repo-name",
        default="os-autoinst-distri-opensuse",
        metavar="NAME",
        help="test repo name in the fork (default %(default)s)",
    )
    parser.add_argument(
        "--needles-fork", metavar="USER", help="GitHub account of the needles fork"
    )
    parser.add_argument(
        "--needles-branch",
        metavar="REF",
        help="ref in the needles fork; adds NEEDLES_DIR",
    )
    parser.add_argument(
        "--needles-repo-name",
        default="os-autoinst-needles-opensuse",
        metavar="NAME",
        help="default %(default)s",
    )
    parser.add_argument(
        "--schedule",
        metavar="LIST",
        help="comma list for SCHEDULE, paths relative to CASEDIR",
    )
    parser.add_argument(
        "--skip-chained-deps", action="store_true", help="do not clone chained parents"
    )
    parser.add_argument(
        "--within-instance",
        action="store_true",
        help="source and target host are the same",
    )
    parser.add_argument(
        "--label",
        metavar="BUILD",
        help="BUILD value (default <user>/<repo>#<ref>; tests-<SHA> with --test-hash; "
        "set-<KEY>... for settings only)",
    )
    parser.add_argument(
        "--set",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="extra setting; KEY= deletes, KEY+= appends; alone, a settings-only clone",
    )
    parser.add_argument(
        "--dry-run-flag",
        action="store_true",
        help="add the option that prints instead of posting (--export-command)",
    )
    parser.add_argument(
        "--parent-publishes",
        action="store_true",
        help="declare that a chained parent of the job publishes assets",
    )
    # Answers the vars.json GET from saved responses in DIR (tests only).
    parser.add_argument("--fixture-dir", metavar="DIR", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        command, lines, has_hazards = build(args)
    except UsageError as error:
        print(f"vr-clone-cmd.py: {error}", file=sys.stderr)
        return 2
    print(sanitize("\n".join([command] + lines), max_line=0, max_bytes=0))
    return 1 if has_hazards else 0


if __name__ == "__main__":
    sys.exit(main())
