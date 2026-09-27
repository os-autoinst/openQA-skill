#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests for scripts/_oqa.py: offline fixtures plus a throw-away HTTP server on 127.0.0.1; no outside network.

here=$(cd "$(dirname "$0")" && pwd)
scripts="$here/../../skills/openqa/scripts"
fixtures="$here/fixtures/_oqa"
fail=0

check() {
	if [ "$2" == "$3" ]; then
		echo "ok - $1"
	else
		echo "not ok - $1"
		printf '  expected: %q\n  actual:   %q\n' "$2" "$3"
		fail=1
	fi
}

# py <python source>: run a snippet with the scripts directory importable
py() {
	(cd "$scripts" && FIXTURES="$fixtures" python3 -c "$1" 2>&1)
}

oqa() {
	python3 "$scripts/_oqa.py" "$@"
}

# --- read-only by construction ------------------------------------------------
check "source names no write method" 0 "$(grep -Ewc 'POST|PUT|DELETE|PATCH' "$scripts/_oqa.py")"
check "source names no Referer or credential" 0 \
	"$(grep -Eic 'referer|api.?key|api.?secret|client\.conf' "$scripts/_oqa.py")"
check "exactly one request constructor, pinned to GET" 'method="GET"' \
	"$(grep -o 'urllib.request.Request(.*' "$scripts/_oqa.py" | grep -o 'method="[A-Z]*"')"
check "no request body is ever passed" 0 "$(grep -Ec 'data=|urlopen\(' "$scripts/_oqa.py")"

actual=$(py '
import inspect
import _oqa
names = set()
for _, member in inspect.getmembers(_oqa.Client, inspect.isfunction):
    names |= set(inspect.signature(member).parameters)
print(sorted(names & {"method", "data", "body", "headers", "json", "files", "auth", "verb"}))
print(sorted(name for name, item in inspect.getmembers(_oqa, inspect.isfunction)
             if {"method", "verb"} & set(inspect.signature(item).parameters)))
print(sorted(name for name in dir(_oqa.Client) if name.startswith(("post", "put", "delete", "patch", "send", "write"))))
')
check "the client takes no method, body or header parameter and has no write verb" "$(printf '[]\n[]\n[]')" "$actual"
check "only _oqa.py talks to the network; nothing but check-schedule.py spawns a process or reads the environment" "" \
	"$(grep -ElI 'urllib\.request|http\.client|import socket|urlopen|subprocess|os\.system|os\.popen|os\.environ|getenv|expanduser|netrc|pickle|\beval\(|\bexec\(' \
		"$scripts"/*.py | grep -v '/_oqa\.py$' | grep -v '/check-schedule\.py$')"
# check-schedule.py asks the local git which schedule files are new; that is its only process.
check "check-schedule.py: one subprocess call, git with an argument list, no shell, no network" "1 1 0" \
	"$(grep -c 'subprocess\.run(' "$scripts/check-schedule.py") $(grep -A2 'subprocess\.run(' "$scripts/check-schedule.py" | grep -c '\["git", "-C", repo, "-c", "core.fsmonitor=false", ') $(grep -Ec 'shell=|os\.system|os\.popen|urllib|http\.client|import socket|urlopen|getenv|expanduser|netrc|pickle|\beval\(|\bexec\(' "$scripts/check-schedule.py")"
check "no script reaches into a private name of _oqa or _sanitize" "" \
	"$(grep -En '(_oqa|_sanitize|client)\._[a-z]|from _(oqa|sanitize) import .*\b_[a-z]' "$scripts"/*.py | grep -v '/_oqa\.py:')"
check "the Accept header is one of three constants" "OqaError unsupported Accept value: text/plain X-Evil: 1" \
	"$(py '
import _oqa
try:
    _oqa.Client(fixture_dir="/nonexistent").get_bytes("/x", accept="text/plain\r\nX-Evil: 1")
except _oqa.OqaError as error:
    print("OqaError", error)
')"
check "_oqa.py itself reads no environment, home directory or credential file" 0 \
	"$(grep -Ec 'os\.environ|getenv|expanduser|netrc|subprocess|os\.system' "$scripts/_oqa.py")"

# --- arguments ----------------------------------------------------------------
actual=$(py '
from _oqa import normalize_host as n
for value in ("o3", " openqa.example.org ", "https://OpenQA.Example.org/tests/1?x=1",
              "http://localhost:9526/", "127.0.0.1:9526", "http://[::1]:9526"):
    print(n(value))
')
check "normalize_host accepts alias, bare name, URL and local http" \
	"$(printf '%s\n' https://openqa.opensuse.org https://openqa.example.org https://openqa.example.org \
		http://localhost:9526 http://127.0.0.1:9526 'http://[::1]:9526')" "$actual"

actual=$(py '
from _oqa import OqaError, normalize_host as n
for value in ("http://openqa.example.org", "ftp://openqa.example.org", "file:///etc/passwd",
              "https://user:secret@openqa.example.org", "localhost.example.org:80", "https://", "https://[bad"):
    try:
        print("ACCEPTED", n(value))
    except OqaError:
        print("refused")
')
check "normalize_host refuses plain http, other schemes, userinfo and junk" \
	"$(printf 'refused\n%.0s' 1 2 3 4 5 6 7)" "$actual"

actual=$(py '
from _oqa import OqaError, normalize_host as n, parse_job_url as p
hostile = ("https://openqa.example.org#@evil.example.org/tests/1", "https://evil.example.org?@openqa.example.org/tests/1",
           "https://openqa.example.org@evil.example.org/tests/1", "https://openqa.example.org\\@evil.example.org/tests/1",
           "https://openqa.example.org./tests/1", "https://openqa.example.org:/tests/1", "https://openqa.example.org:0/tests/1",
           "https://openqa.example.org:99999/tests/1", "https://орenqa.example.org/tests/1",
           "https://openqa%2eexample.org/tests/1", "https://-openqa.example.org/tests/1", "https://openqa_.example.org/tests/1",
           "http://localhost.evil.example.org/tests/1", "http://127.0.0.1.evil.example.org/tests/1",
           "HTTPS://openqa.example.org/tests/1", "file:///tests/1", "ftp://openqa.example.org/tests/1",
           "https://openqa.example.org/tests/" + "9" * 5000, "9" * 5000, "١٢", "https://openqa.example.org/tests/١")
for value in hostile:
    try:
        print("ACCEPTED", p(value))
    except OqaError:
        print("refused")
for value in ("openqa.example.org#@evil.example.org", "evil.example.org?x=/", "openqa.example.org\nHost: evil.example.org"):
    try:
        print("ACCEPTED", n(value))
    except OqaError:
        print("refused")
print(*p("https://openqa.example.org/tests/1/../../api/v1/jobs?x=1#@evil.example.org"))
print(*p("https://xn--e1afmkfd.example.org:8443/t7"))
')
check "hostile job URLs and hosts are refused without a traceback" \
	"$(printf 'refused\n%.0s' {1..24} && printf '%s\n' 'https://openqa.example.org 1' 'https://xn--e1afmkfd.example.org:8443 7')" "$actual"

# Userinfo shapes a redaction rule can miss: no user name, digits and a slash, over 256 characters.
actual=$(py '
from _oqa import OqaError, normalize_host as n, parse_job_url as p
for f, value in ((n, "https://:s3cretPassw0rd@openqa.example.org"), (n, "http://u:2024/s3cretPassw0rd@openqa.example.org"),
                 (p, "https://:s3cretPassw0rd@openqa.example.org/tests/1"), (n, "https://u:" + "s3cretPassw0rd" * 30 + "@openqa.example.org")):
    try:
        print("ACCEPTED", f(value))
    except OqaError as error:
        print(error)
')
check "a host or job URL with userinfo is refused without echoing it" "$(
	cat <<'EOF'
not a usable host: a value holding '@' (not echoed)
only https is allowed (http for localhost): a value holding '@' (not echoed)
not a usable host: a value holding '@' (not echoed)
not a usable host: a value holding '@' (not echoed)
EOF
)" "$actual"

actual=$(py '
from _oqa import OqaError, parse_job_url as p
for value in ("https://openqa.example.org/tests/123", "https://openqa.example.org/t124",
              "https://openqa.example.org/tests/125#step/boot/3", "https://openqa.example.org/tests/126/file/x.txt",
              "127", "http://localhost:9526/tests/128"):
    print(*p(value))
for value in ("http://openqa.example.org/tests/1", "https://openqa.example.org/group_overview/1", "12a", ""):
    try:
        print("ACCEPTED", p(value))
    except OqaError:
        print("refused")
')
check "parse_job_url" "$(
	cat <<'EOF'
https://openqa.example.org 123
https://openqa.example.org 124
https://openqa.example.org 125
https://openqa.example.org 126
https://openqa.opensuse.org 127
http://localhost:9526 128
refused
refused
refused
refused
EOF
)" "$actual"

actual=$(py '
from _oqa import FAILURE_RESULTS, RESULT_GROUPS, RESULTS, OqaError, expand_results as e
print(",".join(e(["not_complete", "failed", "incomplete"])))
print(len(e(["not_ok"])), len(e(["ok", "not_ok", "none"])) == len(RESULTS), sorted(RESULT_GROUPS))
print(set(FAILURE_RESULTS) <= set(RESULT_GROUPS["not_ok"]))
try:
    e(["broken"])
except OqaError as error:
    print(error)
')
check "result meta-groups expand without duplicates" "$(
	cat <<'EOF'
incomplete,timeout_exceeded,failed
9 True ['aborted', 'complete', 'not_complete', 'not_ok', 'ok']
True
unknown result: broken
EOF
)" "$actual"

actual=$(py '
from _oqa import fixture_name as f
print(f("/api/v1/jobs/42"))
print(f("/api/v1/jobs/42", {"follow": 1}))
print(f("/tests/42/file/autoinst-log.txt"))
print(f("/tests/overview.json", [("groupid", 1), ("result", ["failed", "incomplete"])]))
long = f("/api/v1/jobs", {"ids": ",".join(str(n) for n in range(1000, 1100))})
print(len(long), long == f("/api/v1/jobs", {"ids": ",".join(str(n) for n in range(1000, 1100))}))
')
check "fixture_name is readable, stable and bounded" "$(
	cat <<'EOF'
api_v1_jobs_42
api_v1_jobs_42_follow=1
tests_42_file_autoinst-log.txt
tests_overview.json_groupid=1_result=failed_result=incomplete
133 True
EOF
)" "$actual"

# --- current failures ---------------------------------------------------------
actual=$(oqa --fixture-dir "$fixtures" failures 7 20300101)
check "failures exits 1 when there are findings" 1 $?
check "failures digest is compact, sorted and deterministic" "$(cat "$fixtures/expected-failures.txt")" "$actual"
check "no escape or other control byte reaches the output" 0 "$(LC_ALL=C grep -c '[[:cntrl:]]' <<<"$actual")"
check "no zero-width character reaches the output" 0 "$(grep -c $'\342\200\213' <<<"$actual")"
check "fake fence markers are neutralised" 0 "$(grep -Ec '<<< *(UNTRUSTED|END)' <<<"$actual")"
check "oversized field is cut" 0 "$(grep -c 'm\{61\}' <<<"$actual")"

actual=$(oqa --fixture-dir "$fixtures/empty" failures 'Synthetic Group' --todo)
check "no findings exits 0" 0 $?
check "group name, todo=1, server-chosen build and truncation warning" "$(
	cat <<'EOF'
host=https://openqa.opensuse.org group="Synthetic Group" build="20300102"
warning: the server truncated the overview, the list is incomplete
current_failures=0
requests: 1
EOF
)" "$actual"

actual=$(py '
import os, _oqa
client = _oqa.Client(fixture_dir=os.environ["FIXTURES"])
found = _oqa.current_failures(client, 7, "20300101")
print(found["build"], found["limit_exceeded"], [job["id"] for job in found["jobs"]])
print(sorted(found["jobs"][2].items()))
')
check "current_failures row shape" "$(
	cat <<'EOF'
20300101 False [1001, 1002, 1003, 1004]
[('arch', 'x86_64'), ('bugs', ['boo#1200001', 'bsc#1100002']), ('comments', 1), ('distri', 'opensuse'), ('failures', ['aaa_base', 'zypper_up']), ('flavor', 'DVD'), ('id', 1003), ('label', None), ('restarts', 2), ('result', 'failed'), ('state', 'done'), ('test', 'zypper_checks'), ('version', 'Tumbleweed')]
EOF
)" "$actual"

# --- clone chains -------------------------------------------------------------
actual=$(oqa --fixture-dir "$fixtures" chain 100)
check "chain exits 0 when the newest job is ok" 0 $?
check "chain walks origin_id back and clone_id forward" \
	"$(printf 'id   state  result\n90   done   failed\n100  done   incomplete\n110  done   passed')" "$actual"

actual=$(oqa --fixture-dir "$fixtures" chain https://openqa.example.org/t200)
check "chain exits 1 when the newest job is not ok" 1 $?
check "a restart loop terminates and hostile result text is cleaned" \
	"$(printf 'id   state  result\n201  done   failed\n200  done   failed')" "$actual"

actual=$(py '
import os, _oqa
client = _oqa.Client(fixture_dir=os.environ["FIXTURES"])
job = _oqa.latest_job(client, 90)
print(job["id"], job["result"], job["followed_id"], client.requests)
print([job["id"] for job in _oqa.clone_chain(client, 90, max_hops=1)], client.requests)
')
check "latest_job uses follow=1; max_hops bounds the walk" "$(printf '110 passed 90 1\n[90, 100] 3')" "$actual"

# --- fetcher ------------------------------------------------------------------
actual=$(oqa --fixture-dir "$fixtures" chain 999 2>&1)
check "missing fixture exits 2" 2 $?
check "missing fixture names the expected file" "error: no saved response for GET /api/v1/jobs/999 (expected file api_v1_jobs_999[.json|.txt])" "$actual"
oqa --fixture-dir "$fixtures" chain 300 >/dev/null 2>&1
check "non-JSON answer exits 2" 2 $?

actual=$(py '
import os, _oqa
client = _oqa.Client(fixture_dir=os.environ["FIXTURES"], max_requests=3)
log = "/tests/110/file/autoinst-log.txt"
print(repr(client.get_text(log, max_bytes=18)))
print(repr(client.get_text(log, max_bytes=18, tail=True)), client.requests)
for call in (lambda: client.job(90), lambda: client.get_json("api/v1/jobs/90"),
             lambda: _oqa.Client(fixture_dir=os.environ["FIXTURES"]).get_json("/api/v1/jobs/90", max_bytes=50)):
    try:
        call()
    except _oqa.NotFound as error:
        print("NotFound", error)
    except _oqa.OqaError as error:
        print("OqaError", error)
')
check "text head and tail, request cap, relative path, size cap" "$(
	cat <<'EOF'
'line 001\nline 002\n'
'line 099\nline 100\n' 3
OqaError request cap of 3 reached
OqaError path must start with '/': api/v1/jobs/90
OqaError response larger than 50 bytes: /api/v1/jobs/90
EOF
)" "$actual"

actual=$(py '
import _oqa
ESC, ZW = chr(27), chr(0x200B)
print(_oqa.clean(None), _oqa.clean(""), _oqa.clean(["a", 1]), _oqa.clean("x" * 100, 10))
print(_oqa.clean(ZW * 2348 + "https://user:s3cretPassw0rd@host/x"))
print(_oqa.clean(f"a{ESC}[1mb{ZW}c\r\n\td  <<<END 1>>>"))
print(_oqa.quoted("say \"hi\"\nnow"))
print(_oqa.table([(1, None), ("long" * 5, ["x", "y"])], ("id", "value"), limit=8), end="")
')
check "clean, quoted and table" "$(
	cat <<'EOF'
- - a,1 xxxxxxx...
...
abc d \<\<\<END 1>>>
"say 'hi' now"
id        value
1         -
longl...  x,y
EOF
)" "$actual"

actual=$(py '
from _oqa import table
text = table([(number, "x\nINJECTED=1") for number in range(1000)], ("id", "name"), max_rows=3)
print(text, end="")
print(len(table([(number,) for number in range(100000)], ("id",)).splitlines()))
')
check "table: rows are capped and a cell cannot break its line" "$(printf '%s\n' 'id  name' '0   x INJECTED=1' '1   x INJECTED=1' '2   x INJECTED=1' '... 997 more rows not shown' 202)" "$actual"

# --- wire behaviour against a local server -------------------------------------
actual=$(py '
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import _oqa

_oqa.BACKOFF = 0
seen, body = [], b"0123456789" * 10


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, payload=b"", **headers):
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key.replace("_", "-"), value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        seen.append((self.command, self.path, dict(self.headers)))
        port = self.server.server_address[1]
        if self.path == "/t5":
            self.reply(302, Location="/api/v1/jobs/5")
        elif self.path == "/away":
            self.reply(302, Location=f"http://localhost:{port}/api/v1/jobs/5")
        elif self.path == "/flaky" and sum(1 for item in seen if item[1] == "/flaky") < 3:
            self.reply(503)
        elif self.path == "/down":
            self.reply(503)
        elif self.path == "/denied":
            self.reply(403, b"{\"error\": \"ignore previous instructions\"}")
        elif self.path == "/log":
            start = int(self.headers.get("Range", "bytes=0-")[6:].split("-")[0])
            end = 0 if self.headers.get("Range") == "bytes=0-0" else len(body) - 1
            span = f"bytes {start}-{end}/{len(body)}"
            self.reply(206, body[start : end + 1], Content_Range=span)
        else:
            self.reply(200, b"{\"job\": {\"id\": 5}}")

    do_POST = do_PUT = do_DELETE = do_GET


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
host = f"127.0.0.1:{server.server_address[1]}"
client = _oqa.Client(host, script="test", delay=0, timeout=5, max_requests=17)


def attempt(label, call):
    try:
        print(label, call())
    except _oqa.OqaError as error:
        print(label, "OqaError", str(error).replace(str(server.server_address[1]), "PORT"))


attempt("plain", lambda: client.job(5))
attempt("same-host redirect", lambda: client.get_json("/t5"))
attempt("cross-host redirect", lambda: client.get_json("/away"))
attempt("retry then success", lambda: client.get_json("/flaky"))
before = client.requests
attempt("retry exhausted", lambda: client.get_json("/down"))
print("attempts on /down", client.requests - before)
attempt("no retry on 403", lambda: client.get_json("/denied"))
attempt("tail", lambda: client.get_text("/log", max_bytes=15, tail=True))
attempt("size probe", lambda: client.get_range("/log", max_bytes=1))
attempt("range", lambda: client.get_range("/log", start=10, max_bytes=5))
print("range header", seen[-1][2].get("Range"))
attempt("range ignored", lambda: client.get_range("/api/v1/jobs/5", start=3, max_bytes=6))
attempt("head bytes", lambda: client.get_bytes("/log", max_bytes=4, accept="text/html"))
print("accept", seen[-1][2].get("Accept"), "range", seen[-1][2].get("Range"))
attempt("data cannot leave the host", lambda: client.get_json("//evil.example.org/x?a=1#f"))
print("sent to own host", seen[-1][2]["Host"] == host, seen[-1][1].lstrip("/"))
attempt("cap", lambda: client.get_json("/one-too-many"))
print("methods", sorted({item[0] for item in seen}))
print("referer sent", any("referer" in (key.lower() for key in item[2]) for item in seen))
print("agents", sorted({item[2].get("User-Agent") for item in seen}))
print("compression asked for", sorted({item[2].get("Accept-Encoding", "identity") for item in seen} - {"identity"}))
print("unexpected headers", sorted({key.lower() for item in seen for key in item[2]}
                                   - {"accept", "accept-encoding", "connection", "host", "range", "user-agent"}))
server.shutdown()
')
check "GET only, fixed agent, no Referer, redirect policy, bounded retries, ranged tail, public range API" "$(
	cat <<'EOF'
plain {'id': 5}
same-host redirect {'job': {'id': 5}}
cross-host redirect OqaError refusing redirect to another host: http://localhost
retry then success {'job': {'id': 5}}
retry exhausted OqaError HTTP 503: /down
attempts on /down 3
no retry on 403 OqaError HTTP 403: /denied
tail 567890123456789
size probe (b'0', 100, True)
range (b'01234', 100, True)
range header bytes=10-14
range ignored (b'{"job"', 0, False)
head bytes b'0123'
accept text/html range None
data cannot leave the host {'job': {'id': 5}}
sent to own host True evil.example.org/x%3Fa%3D1%23f
cap OqaError request cap of 17 reached
methods ['GET']
referer sent False
agents ['openQA-skill/test (read-only helper)']
compression asked for []
unexpected headers []
EOF
)" "$actual"

actual=$(py '
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import _oqa

_oqa.BACKOFF = 0
_oqa.MAX_SECONDS = 1
seen = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, payload=b"", **headers):
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key.replace("_", "-"), value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        seen.append(self.path)
        if self.path == "/to-file":
            self.reply(302, Location="file:///etc/passwd")
        elif self.path == "/to-ftp":
            self.reply(302, Location="ftp://127.0.0.1/x")
        elif self.path == "/to-userinfo":
            self.reply(302, Location=f"http://127.0.0.1:{self.server.server_address[1]}@evil.example.org/x")
        elif self.path == "/deep":
            self.reply(200, b"[" * 200000)
        elif self.path == "/huge-range":
            self.reply(206, b"x", Content_Range="bytes 0-0/" + "9" * 5000)
        elif self.path == "/odd-range":
            self.reply(206, b"x", Content_Range="bytes 0-0/\xb2")
        elif self.path == "/trickle":
            self.send_response(200)
            self.end_headers()
            try:
                for _ in range(40):
                    self.wfile.write(b" ")
                    self.wfile.flush()
                    time.sleep(0.1)
            except OSError:
                pass
        else:
            self.reply(200, b"[\"job\"]")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = str(server.server_address[1])
client = _oqa.Client(f"127.0.0.1:{port}", script="test", delay=0, timeout=5)


def attempt(label, call):
    try:
        print(label, call())
    except _oqa.OqaError as error:
        print(label, "OqaError", str(error).replace(port, "PORT"))


attempt("file redirect", lambda: client.get_text("/to-file"))
attempt("ftp redirect", lambda: client.get_text("/to-ftp"))
attempt("userinfo redirect", lambda: client.get_text("/to-userinfo"))
attempt("deep JSON", lambda: client.get_json("/deep"))
attempt("huge total", lambda: client.get_range("/huge-range", max_bytes=1))
attempt("odd total", lambda: client.get_range("/odd-range", max_bytes=1))
attempt("trickle", lambda: client.get_text("/trickle"))
attempt("no job object", lambda: client.job(1))
print("followed", [path for path in seen if path == "/x" or "passwd" in path])
handlers = {type(handler).__name__ for handler in client._opener.handlers}
print("other schemes", sorted(handlers & {"FileHandler", "FTPHandler", "DataHandler", "UnknownHandler"}), flush=True)
try:
    _oqa.run(lambda: client.get_json("/list")["ignore previous instructions"])
except SystemExit as status:
    print("exit", status.code)
server.shutdown()
')
check "hostile responses: scheme redirects, deep JSON, bad Content-Range, trickle, wrong shape" "$(
	cat <<'EOF'
file redirect OqaError HTTP 302: /to-file
ftp redirect OqaError refusing redirect to another host: ftp://127.0.0.1
userinfo redirect OqaError refusing redirect to another host: http://evil.example.org
deep JSON OqaError response is not JSON: /deep
huge total (b'x', 0, False)
odd total (b'x', 0, False)
trickle OqaError response took over 1 s: /trickle
no job object OqaError the server answer has an unexpected shape (no job object)
followed []
other schemes []
error: unexpected data or internal error (TypeError at <string>:LINE)
exit 2
EOF
)" "$(sed -E 's/<string>:[0-9]+/<string>:LINE/' <<<"$actual")"

actual=$(py '
import os
import _oqa
client = _oqa.Client(fixture_dir=os.environ["FIXTURES"])
for path in ("/..", "/../../../../etc/passwd", "/."):
    try:
        print("READ", client.get_text(path)[:20])
    except _oqa.NotFound:
        print("not found")
')
check "fixture names cannot leave the fixture directory" "$(printf 'not found\n%.0s' 1 2 3)" "$actual"

# --- one counted request is a bounded number of wire GETs, and the URL is capped ---
actual=$(py '
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import _oqa

_oqa.BACKOFF = 0
seen = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        seen.append(self.path)
        self.send_response(302)
        self.send_header("Location", "/loop")
        self.send_header("Content-Length", "0")
        self.end_headers()


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
client = _oqa.Client(f"127.0.0.1:{server.server_address[1]}", script="test", delay=0, timeout=5)
try:
    client.get_json("/loop")
except _oqa.OqaError:
    pass
print("counted", client.requests, "wire GETs", len(seen), "bounded", len(seen) <= 4)
try:
    client.get_json("/x", {"TEST": "A" * _oqa.MAX_URL_CHARS})
except _oqa.OqaError as error:
    print("long URL", error, "no extra GET", len(seen))
')
check "an endless same-host redirect cannot become an endless number of GETs" \
	"counted 1 wire GETs 2 bounded True" "$(sed -n 1p <<<"$actual")"
check "a server-controlled setting cannot make the next request line unbounded" \
	"long URL request URL longer than 8192 characters no extra GET 2" "$(sed -n 2p <<<"$actual")"

# --- command line -------------------------------------------------------------
oqa --help >/dev/null
check "--help exits 0" 0 $?
oqa failures --help >/dev/null
check "subcommand --help exits 0" 0 $?
oqa >/dev/null 2>&1
check "missing command exits 2" 2 $?
oqa --host http://openqa.example.org failures 1 >/dev/null 2>&1
check "plain http host exits 2 before any request" 2 $?

exit $fail
