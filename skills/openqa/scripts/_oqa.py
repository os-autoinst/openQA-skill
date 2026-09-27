#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Shared read-only openQA access for the scripts in this directory: GET-only fetcher, common queries, compact output.
"""Read-only openQA helpers. Import from a sibling script; there is no write path.

Wiring a script:

    import _oqa

    def main():
        parser = ArgumentParser(...)
        _oqa.add_common_args(parser)            # --host, --fixture-dir
        args = parser.parse_args()
        client = _oqa.client_from_args(args, "my-script")
        ...
        return 0                                # 0 ok, 1 findings

    if __name__ == "__main__":
        _oqa.run(main)                          # OqaError -> "error: ..." on stderr, exit 2

Fetching (every call is one GET, counted against the per-run request cap):

    Client(host=DEFAULT_HOST, *, script="_oqa", fixture_dir=None,
           max_requests=60, delay=0.3, timeout=30)
    client.host                                 normalised base URL, e.g. https://openqa.opensuse.org
    client.requests                             GETs issued so far
    client.get_json(path, params=None, *, max_bytes=8 MiB) -> parsed JSON
    client.get_text(path, params=None, *, max_bytes=256 KiB, tail=False) -> str
        tail=True returns the END of a large file (one extra 1-byte probe,
        because openQA answers a suffix range with the file head); its
        first line may be cut.
    client.get_bytes(path, params=None, *, max_bytes=256 KiB, accept="text/plain") -> bytes
        the first max_bytes of the body, undecoded; accept is one of
        text/plain, text/html, application/json.
    client.get_range(path, params=None, *, start=0, max_bytes=256 KiB)
        -> (bytes, total, ranged): bytes start..start+max_bytes-1 of a file.
        total is the file size from Content-Range. ranged=False: the server
        ignored Range, the bytes are the HEAD of the file and total is 0.
        get_range(path, max_bytes=1) is the cheap size probe.
    client.job(job_id) -> the "job" object of /api/v1/jobs/<id>

    path is an unencoded absolute path ("/api/v1/jobs/42/comments"); it is
    percent-encoded here, so text taken from a response can never change the
    host or smuggle a query. params is a dict or a list of (key, value)
    pairs; a list/tuple value repeats the key. Errors raise OqaError; a 404
    raises NotFound (a subclass). Error text never contains response bodies.
    get_text() output is RAW third-party text: pass it through sanitize()
    and fence() before printing.

Arguments given by the user (never apply these to fetched data):

    normalize_host("o3" | "openqa.example.org" | "https://host/any/path") -> "https://host"
        https only; http is accepted for localhost, 127.0.0.1 and ::1.
    parse_job_url("https://host/tests/123#step/x/1" | "https://host/t123" | "123",
                  default_host=DEFAULT_HOST) -> (host, 123)

Queries:

    current_failures(client, group, build=None, results=FAILURE_RESULTS, todo=False)
        -> {"build": str | list | None, "limit_exceeded": bool, "jobs": [row, ...]}
        One request to /tests/overview.json. It picks the latest job per
        scenario and drops cloned jobs BEFORE filtering by result, so a
        failure that was restarted and then passed is not reported.
        /api/v1/jobs?result=failed&latest=1 filters first and returns such
        superseded failures; do not use it for this. group is a numeric id
        or a group name; build=None lets the server pick the latest build;
        results may contain meta-groups; todo=True keeps only jobs without
        bugref or label. Rows are sorted by id and have the keys
        id distri version flavor test arch result state failures bugs label
        comments restarts ("test" carries an "@machine" suffix when openQA
        needs it; failures and bugs are sorted lists; comments counts
        comments with neither bugref nor label, automated ones included).
    latest_job(client, job_id) -> newest job of the restart chain, one request
        (?follow=1); the result has "followed_id" when it differs from job_id.
    clone_chain(client, job_id, max_hops=10) -> [job, ...] oldest to newest,
        walking origin_id back and clone_id forward, one request per hop.

Results:

    RESULTS, RESULT_GROUPS (complete, not_complete, aborted, ok, not_ok),
    FAILURE_RESULTS (failed, incomplete, timeout_exceeded, parallel_failed)
    expand_results(["not_ok", "softfailed"]) -> concrete result names, no duplicates.
    /api/v1/jobs does NOT expand meta-groups server side; expand first.

Output (all third-party text must go through one of these or sanitize/fence):

    clean(value, limit=80) -> one sanitised line; None -> "-", list -> comma-joined
    quoted(value, limit=80) -> clean() wrapped in double quotes
    tok(value, limit=80) -> clean() bare when it cannot be mistaken for prose, else quoted()
    toks(values, limit=80, most=8) -> comma-joined tok()s, "+N" for the rest, "-" when empty
    distri_frame(lines) -> "func at file line N" for the first Perl stack frame
        outside os-autoinst, arguments dropped, or None; sanitise it like any other text
    table(rows, headers, limit=60, max_rows=200, drop_empty=False) -> aligned
        plain-text table, every cell clean()ed, rows beyond max_rows only
        counted; drop_empty leaves out columns that are "-" in every row
    sanitize, fence                             re-exported from _sanitize

Offline tests: --fixture-dir DIR (or Client(fixture_dir=DIR)) disables the
network completely. Each GET reads DIR/<fixture_name(path, params)>, also
tried with ".json" and ".txt" appended; a missing file behaves like a 404:
"no saved response for GET <path>?<query> (expected file <name>[.json|.txt])".
Examples:
    /api/v1/jobs/42                       -> api_v1_jobs_42
    /api/v1/jobs/42 {"follow": 1}         -> api_v1_jobs_42_follow=1
    /tests/42/file/autoinst-log.txt       -> tests_42_file_autoinst-log.txt
"""

import argparse
import hashlib
import http.client
import json
import os
import re
import sys
import time
import traceback
import urllib.error
import urllib.request
from urllib.parse import quote, urlencode, urlsplit

import _secrets
from _sanitize import ArgumentParser, excerpt, fence, sanitize

__all__ = [
    "DEFAULT_HOST",
    "FAILURE_RESULTS",
    "RESULTS",
    "RESULT_GROUPS",
    "Client",
    "NotFound",
    "OqaError",
    "add_common_args",
    "clean",
    "client_from_args",
    "clone_chain",
    "current_failures",
    "distri_frame",
    "expand_results",
    "fence",
    "fixture_name",
    "job_id_of",
    "latest_job",
    "normalize_host",
    "parse_job_url",
    "quoted",
    "run",
    "sanitize",
    "table",
    "tok",
    "toks",
]

DEFAULT_HOST = "https://openqa.opensuse.org"
HOST_ALIASES = {"o3": DEFAULT_HOST}
LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")

ACCEPTED = ("text/plain", "text/html", "application/json")
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_TEXT_BYTES = 256 * 1024
MAX_URL_CHARS = 8192
RETRIES = 2
BACKOFF = 2
RETRY_STATUS = (429, 502, 503, 504)
MAX_SECONDS = 180

# Mirrors lib/OpenQA/Jobs/Constants.pm.
RESULTS = (
    "none",
    "passed",
    "softfailed",
    "failed",
    "incomplete",
    "skipped",
    "obsoleted",
    "parallel_failed",
    "parallel_restarted",
    "user_cancelled",
    "user_restarted",
    "timeout_exceeded",
)
_ABORTED = (
    "skipped",
    "obsoleted",
    "parallel_failed",
    "parallel_restarted",
    "user_cancelled",
    "user_restarted",
)
_NOT_COMPLETE = ("incomplete", "timeout_exceeded")
RESULT_GROUPS = {
    "complete": ("passed", "softfailed", "failed"),
    "not_complete": _NOT_COMPLETE,
    "aborted": _ABORTED,
    "ok": ("passed", "softfailed"),
    "not_ok": ("failed", *_NOT_COMPLETE, *_ABORTED),
}
FAILURE_RESULTS = ("failed", "incomplete", "timeout_exceeded", "parallel_failed")


class OqaError(Exception):
    """Usage or runtime problem; scripts exit 2 on it."""


class NotFound(OqaError):
    """The server answered 404 (or the fixture file does not exist)."""


_LABEL = r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?"
_NETLOC = re.compile(
    rf"^(?:{_LABEL}(?:\.{_LABEL})*|\[[0-9a-f:.]+\])(?::[0-9]{{1,5}})?$"
)


def _argument(value):
    # Userinfo can hold a password no redaction rule recognises.
    return "a value holding '@' (not echoed)" if "@" in value else clean(value)


def normalize_host(value):
    value = HOST_ALIASES.get(value.strip(), value.strip())
    if "://" not in value:
        local = value.startswith(("localhost", "127.0.0.1", "[::1]"))
        value = ("http://" if local else "https://") + value
    try:
        parts = urlsplit(value)
        # ASCII names only (IDN as punycode), no userinfo, no trailing dot, and
        # a "/" before any "?" or "#": "host#@other" must not read as another host.
        usable = (
            _NETLOC.match(parts.netloc.lower())
            and parts.port != 0
            and re.match(r"[a-z]+://[^/?#]*(?:/|$)", value)
        )
    except ValueError:
        usable = False
    if not usable:
        raise OqaError(f"not a usable host: {_argument(value)}")
    allowed = ("https", "http") if parts.hostname in LOCAL_HOSTS else ("https",)
    if parts.scheme not in allowed:
        raise OqaError(
            f"only https is allowed (http for localhost): {_argument(value)}"
        )
    return f"{parts.scheme}://{parts.netloc.lower()}"


_JOB_URL = re.compile(r"^(https?://[^/?#\s]+)/(?:tests/|t)([0-9]{1,18})(?:[/?#].*)?$")


def parse_job_url(text, default_host=DEFAULT_HOST):
    text = text.strip()
    if re.fullmatch(r"[0-9]{1,18}", text):
        return normalize_host(default_host), int(text)
    match = _JOB_URL.match(text)
    if not match:
        raise OqaError(f"not a job id or job URL: {_argument(text)}")
    return normalize_host(match.group(1)), int(match.group(2))


def expand_results(names):
    expanded = []
    for name in names:
        if name not in RESULT_GROUPS and name not in RESULTS:
            raise OqaError(f"unknown result: {clean(name)}")
        for result in RESULT_GROUPS.get(name, (name,)):
            if result not in expanded:
                expanded.append(result)
    return expanded


def _pairs(params):
    items = params.items() if isinstance(params, dict) else params or ()
    pairs = []
    for key, value in items:
        values = value if isinstance(value, (list, tuple)) else (value,)
        pairs.extend((key, str(item)) for item in values)
    return pairs


def fixture_name(path, params=None):
    query = "&".join(f"{key}={value}" for key, value in _pairs(params))
    name = path.strip("/") + ("?" + query if query else "")
    slug = re.sub(r"[^A-Za-z0-9.=-]+", "_", name) or "_"
    if len(slug) > 150:
        slug = f"{slug[:120]}_{hashlib.sha256(name.encode()).hexdigest()[:12]}"
    return slug


class _SameHostRedirects(urllib.request.HTTPRedirectHandler):
    # A redirect is followed inside opener.open(), so it never reaches Client._count():
    # these bound how many wire GETs one counted request can become.
    max_redirections = 2
    max_repeats = 1

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        old, new = urlsplit(req.full_url), urlsplit(newurl)
        if (new.scheme, new.netloc.lower()) != (old.scheme, old.netloc.lower()):
            # Only the parsed scheme and host: a Location may carry credentials.
            raise OqaError(
                f"refusing redirect to another host: "
                f"{clean(new.scheme)}://{clean(new.hostname or '')}"
            )
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class Client:
    def __init__(
        self,
        host=DEFAULT_HOST,
        *,
        script="_oqa",
        fixture_dir=None,
        max_requests=60,
        delay=0.3,
        timeout=30,
    ):
        self.host = normalize_host(host)
        self.fixture_dir = fixture_dir
        self.max_requests = max_requests
        self.delay = delay
        self.timeout = timeout
        self.requests = 0
        self._agent = f"openQA-skill/{script} (read-only helper)"
        # Built by hand: build_opener() would add the file, ftp and data handlers.
        self._opener = urllib.request.OpenerDirector()
        for handler in (
            urllib.request.ProxyHandler,
            urllib.request.HTTPHandler,
            urllib.request.HTTPSHandler,
            urllib.request.HTTPDefaultErrorHandler,
            urllib.request.HTTPErrorProcessor,
            _SameHostRedirects,
        ):
            self._opener.add_handler(handler())

    def get_json(self, path, params=None, *, max_bytes=MAX_JSON_BYTES):
        body, _ = self._get(path, params, max_bytes + 1, "application/json")
        if len(body) > max_bytes:
            raise OqaError(f"response larger than {max_bytes} bytes: {clean(path)}")
        try:
            return json.loads(body)
        except (ValueError, RecursionError):
            raise OqaError(f"response is not JSON: {clean(path)}") from None

    def get_bytes(
        self, path, params=None, *, max_bytes=MAX_TEXT_BYTES, accept="text/plain"
    ):
        if accept not in ACCEPTED:
            raise OqaError(f"unsupported Accept value: {clean(accept)}")
        return self._get(path, params, max_bytes, accept)[0]

    def get_range(self, path, params=None, *, start=0, max_bytes=MAX_TEXT_BYTES):
        span = f"bytes={start}-{start + max_bytes - 1}"
        body, total = self._get(path, params, max_bytes, "text/plain", span)
        return body, total, bool(total)

    def get_text(self, path, params=None, *, max_bytes=MAX_TEXT_BYTES, tail=False):
        if tail:
            _, total, _ = self.get_range(path, params, max_bytes=1)
            start = max(total - max_bytes, 0)
            body = self.get_range(path, params, start=start, max_bytes=max_bytes)[0]
        else:
            body = self.get_bytes(path, params, max_bytes=max_bytes)
        return body.decode("utf-8", "replace")

    def job(self, job_id):
        return _job(self.get_json(f"/api/v1/jobs/{int(job_id)}"), int(job_id))

    def _get(self, path, params, limit, accept, byte_range=None):
        """Return (at most limit bytes of the body, total size or 0 if unknown)."""
        if not path.startswith("/"):
            raise OqaError(f"path must start with '/': {clean(path)}")
        if self.fixture_dir is not None:
            self._count()
            return self._read_fixture(path, params, limit, byte_range)
        query = urlencode(_pairs(params))
        url = self.host + quote(path, safe="/") + ("?" + query if query else "")
        # Query values can come from the server's own answers, so a reply must not
        # be able to make the next request line megabytes long.
        if len(url) > MAX_URL_CHARS:
            raise OqaError(f"request URL longer than {MAX_URL_CHARS} characters")
        headers = {"User-Agent": self._agent, "Accept": accept}
        if byte_range:
            headers["Range"] = byte_range
        for attempt in range(RETRIES + 1):
            if self.requests:
                time.sleep(self.delay + BACKOFF * attempt)
            self._count()
            request = urllib.request.Request(url, headers=headers, method="GET")
            try:
                with self._opener.open(request, timeout=self.timeout) as response:
                    content_range = response.headers.get("Content-Range", "")
                    total = re.search(r"/([0-9]{1,18})$", content_range)
                    body = self._read(response, limit, path)
                    return body, int(total.group(1)) if total else 0
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    raise NotFound(f"HTTP 404: {clean(path)}") from None
                if error.code not in RETRY_STATUS or attempt == RETRIES:
                    raise OqaError(f"HTTP {error.code}: {clean(path)}") from None
            except (OSError, http.client.HTTPException) as error:
                if attempt == RETRIES:
                    reason = clean(getattr(error, "reason", error))
                    raise OqaError(f"{reason}: {clean(path)}") from None
        raise AssertionError("unreachable")

    def _read(self, response, limit, path):
        # The socket timeout restarts with every byte; a trickling server must not.
        deadline = time.monotonic() + MAX_SECONDS
        chunks, size = [], 0
        while size < limit:
            chunk = response.read1(min(65536, limit - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
            if time.monotonic() > deadline:
                raise OqaError(f"response took over {MAX_SECONDS} s: {clean(path)}")
        return b"".join(chunks)

    def _count(self):
        if self.requests >= self.max_requests:
            raise OqaError(f"request cap of {self.max_requests} reached")
        self.requests += 1

    def _read_fixture(self, path, params, limit, byte_range):
        name = fixture_name(path, params)
        for suffix in ("", ".json", ".txt"):
            try:
                with open(os.path.join(self.fixture_dir, name + suffix), "rb") as file:
                    data = file.read()
            except OSError:
                continue
            start = int(byte_range[6:].partition("-")[0]) if byte_range else 0
            return data[start : start + limit], len(data)
        query = urlencode(_pairs(params))
        request = clean(path + ("?" + query if query else ""), 200)
        raise NotFound(
            f"no saved response for GET {request} (expected file {name}[.json|.txt])"
        )


def job_id_of(value):
    """A job id from a response as int, or None: ids are printed and put into paths."""
    return value if type(value) is int and 0 < value < 10**18 else None


def _job(data, job_id=None):
    job = data.get("job") if isinstance(data, dict) else None
    if not isinstance(job, dict):
        raise OqaError("the server answer has an unexpected shape (no job object)")
    job["id"] = job_id or job_id_of(job.get("id"))
    if job["id"] is None:
        raise OqaError("the server answer has an unexpected shape (job id)")
    return job


def latest_job(client, job_id):
    return _job(client.get_json(f"/api/v1/jobs/{int(job_id)}", {"follow": 1}))


def clone_chain(client, job_id, max_hops=10):
    chain = [client.job(job_id)]
    seen = {chain[0]["id"]}
    for key, end in (("origin_id", 0), ("clone_id", -1)):
        for _ in range(max_hops):
            next_id = job_id_of(chain[end].get(key))
            if not next_id or next_id in seen:
                break
            seen.add(next_id)
            chain.insert(0 if end == 0 else len(chain), client.job(next_id))
    return chain


def current_failures(client, group, build=None, results=FAILURE_RESULTS, todo=False):
    params = [("groupid" if str(group).isdigit() else "group", group)]
    if build:
        params.append(("build", build))
    params.append(("result", expand_results(results)))
    if todo:
        params.append(("todo", 1))
    data = client.get_json("/tests/overview.json", params)
    jobs = []
    for distri, versions in (data.get("results") or {}).items():
        for version, flavors in versions.items():
            for flavor, tests in flavors.items():
                for test, archs in tests.items():
                    for arch, leaf in archs.items():
                        if isinstance(leaf, dict) and job_id_of(leaf.get("jobid")):
                            jobs.append(
                                {
                                    "id": leaf["jobid"],
                                    "distri": distri,
                                    "version": version,
                                    "flavor": flavor,
                                    "test": test,
                                    "arch": arch,
                                    "result": leaf.get("overall"),
                                    "state": leaf.get("state"),
                                    "failures": sorted(leaf.get("failures") or ()),
                                    "bugs": sorted(leaf.get("bugs") or ()),
                                    "label": leaf.get("label"),
                                    "comments": leaf.get("comments") or 0,
                                    "restarts": leaf.get("restarts") or 0,
                                }
                            )
    jobs.sort(key=lambda job: job["id"])
    return {
        "build": data.get("build"),
        "limit_exceeded": bool(data.get("limit_exceeded")),
        "jobs": jobs,
    }


def clean(value, limit=80):
    if value is None:
        return "-"
    if isinstance(value, (list, tuple)):
        value = ",".join(str(item) for item in value)
    return excerpt(str(value), limit) or "-"


def quoted(value, limit=80):
    return '"' + clean(value, limit).replace('"', "'") + '"'


_BARE = re.compile(r"[\w.:#@/+%=-]+", re.ASCII)


def tok(value, limit=80):
    text = clean(value, limit)
    return text if _BARE.fullmatch(text) else quoted(value, limit)


def toks(values, limit=80, most=8):
    items = [tok(value, limit) for value in values[:most]]
    if len(values) > most:
        items.append(f"+{len(values) - most}")
    return ",".join(items) or "-"


_FRAME = re.compile(r"^\s*([\w:]+)(?:\(.*\))?(?: called)? at (\S+) line (\d+)")


def distri_frame(lines):
    for line in lines:
        match = _FRAME.match(line[:4000])
        if match and not re.search(r"^/usr/|/os-autoinst/|/perl5/", match.group(2)):
            return f"{match.group(1)} at {match.group(2)} line {match.group(3)}"
    return None


def table(rows, headers, limit=60, max_rows=200, drop_empty=False):
    lines = [
        [clean(cell, limit) for cell in row] for row in [headers, *rows[:max_rows]]
    ]
    if drop_empty and rows:
        keep = [
            index
            for index in range(len(headers))
            if any(line[index] != "-" for line in lines[1:])
        ]
        lines = [[line[index] for index in keep] for line in lines]
    widths = [max(len(line[index]) for line in lines) for index in range(len(lines[0]))]
    text = "".join(
        "  ".join(cell.ljust(width) for cell, width in zip(line, widths)).rstrip()
        + "\n"
        for line in lines
    )
    if len(rows) > max_rows:
        text += f"... {len(rows) - max_rows} more rows not shown\n"
    return text


def add_common_args(parser):
    parser.add_argument(
        "--host",
        default=DEFAULT_HOST,
        help=f"openQA instance: URL, host name or the alias o3 (default: {DEFAULT_HOST})",
    )
    # Answers every request from saved responses in DIR, never the network. A test hook,
    # so it stays out of --help and out of the flag index in SKILL.md.
    parser.add_argument("--fixture-dir", metavar="DIR", help=argparse.SUPPRESS)


def client_from_args(args, script, **kwargs):
    return Client(args.host, script=script, fixture_dir=args.fixture_dir, **kwargs)


def run(main):
    try:
        code = main()
        # Say that a credential was in this job's artefacts, so it gets rotated.
        # Silence here is what teaches people to trust the redactor.
        note = _secrets.summary(_secrets.total())
        if note:
            print(note, file=sys.stderr)
        sys.exit(code)
    except OqaError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(2)
    except Exception as error:  # noqa: BLE001
        # No traceback and no message: both can carry raw third-party text.
        frame = traceback.extract_tb(error.__traceback__)[-1]
        where = f"{os.path.basename(frame.filename)}:{frame.lineno}"
        print(
            f"error: unexpected data or internal error ({type(error).__name__} at {where})",
            file=sys.stderr,
        )
        sys.exit(2)


def _main():
    parser = ArgumentParser(
        prog="_oqa.py",
        description="Self-check of the shared read-only openQA helpers (GET only). "
        "Other scripts import this module; see its docstring.",
    )
    add_common_args(parser)
    commands = parser.add_subparsers(dest="command", required=True)
    failures = commands.add_parser(
        "failures",
        help="current failures of a build, superseded (restarted) jobs excluded; exit 1 if any",
    )
    failures.add_argument("group", help="job group id or name")
    failures.add_argument(
        "build", nargs="?", help="build (default: latest of the group)"
    )
    failures.add_argument(
        "--todo", action="store_true", help="only jobs without bugref or label"
    )
    chain = commands.add_parser(
        "chain",
        help="restart chain of a job, oldest to newest; exit 1 if the newest is not ok",
    )
    chain.add_argument("job", help="job id or URL (a URL also selects the host)")
    args = parser.parse_args()

    if args.command == "chain":
        args.host, job_id = parse_job_url(args.job, args.host)
        client = client_from_args(args, "_oqa")
        jobs = clone_chain(client, job_id)
        rows = [(job["id"], job.get("state"), job.get("result")) for job in jobs]
        print(table(rows, ("id", "state", "result")), end="")
        return 0 if jobs[-1].get("result") in (*RESULT_GROUPS["ok"], "none") else 1

    client = client_from_args(args, "_oqa")
    found = current_failures(client, args.group, args.build, todo=args.todo)
    print(
        f"host={client.host} group={quoted(args.group)} build={quoted(found['build'])}"
    )
    if found["limit_exceeded"]:
        print("warning: the server truncated the overview, the list is incomplete")
    columns = ("id", "result", "test", "arch", "failures", "bugs", "label", "restarts")
    rows = [[job[key] or None for key in columns] for job in found["jobs"]]
    if rows:
        print(table(rows, columns, drop_empty=True), end="")
    print(f"current_failures={len(found['jobs'])}")
    print(f"requests: {client.requests}")
    return 1 if found["jobs"] else 0


if __name__ == "__main__":
    run(_main)
