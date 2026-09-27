#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests for contrib/harness/: every snippet parses and denies the same credential locations, the
# Kimi hook blocks and passes what it should (fail closed), and the Codex rules decide as documented.
# The paths and commands below are test input for the hook, never executed.
# shellcheck disable=SC2016

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
harness=$root/contrib/harness
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
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

# --- every snippet parses ----------------------------------------------------------
for f in "$harness"/*/*; do
	name=${f#"$harness"/}
	case $f in
	*.md | *.rules) continue ;;
	esac
	parsed=$(
		python3 - "$f" <<'PY'
import json, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
try:
    if path.endswith(".toml"):
        try:
            import tomllib
        except ImportError:
            print("ok (no tomllib before Python 3.11)")
            sys.exit()
        tomllib.loads(text)
    elif path.endswith(".py"):
        compile(text, path, "exec")
    else:
        json.loads("\n".join(l for l in text.splitlines() if not l.lstrip().startswith("//")))
    print("ok")
except Exception as error:
    print(f"broken: {error}")
PY
	)
	check "$name parses" "ok" "${parsed%% *}"
done

# --- every harness denies the same locations, and no snippet names a real home ---------
for dir in "$harness"/*/; do
	name=$(basename "$dir")
	all=$(cat "$dir"*)
	# Path forms, not bare words: "openqa" alone also matches openqa-credentials and openqa-cli.
	for location in openqa osc oscrc tea netrc git-credentials; do
		case $location in
		openqa) form='\.config/(\([a-z|]*)?openqa|etc/openqa' ;;
		osc) form='\.config/(\([a-z|]*)?osc\b' ;;
		oscrc) form='\.oscrc|[*|(/]oscrc\b' ;;
		tea) form='\.config/(\([a-z|]*)?tea\b' ;;
		netrc) form='\.netrc' ;;
		git-credentials) form='\.git-credentials' ;;
		esac
		check "$name denies $location" 1 "$(grep -c -m1 -E -- "$form" <<<"$all")"
	done
	check "$name denies gh's credentials" 1 "$(grep -c -m1 -E '[/(|"]gh\b|hosts\.yml' <<<"$all")"
	check "$name names no real home directory" 0 "$(grep -c -E '/home/[a-z]' <<<"$all")"
	# Claude Code reads a trailing ":*" as its legacy prefix form, so such a glob never matches.
	check "$name has no glob rule ending in :*" 0 "$(grep -c -E ':\*\)?"' <<<"$all")"
done

# --- kimi doctor does not compile the hook matcher; a broken one disables the hook silently ---
matcher=$(sed -n 's/^matcher = "\(.*\)"$/\1/p' "$harness/kimi/config.toml")
# Kimi evaluates it as a JavaScript RegExp; a pattern that throws there never matches.
if command -v node >/dev/null; then
	named=$(node -e 'const r = new RegExp(process.argv[1]); console.log(["Bash", "Read"].filter((t) => r.test(t)).join(" "))' "$matcher" 2>&1)
else
	named=$(python3 -c 'import re, sys; m = re.compile(sys.argv[1]); print(*[t for t in ("Bash", "Read") if m.fullmatch(t)])' "$matcher" 2>&1)
fi
check "kimi matcher compiles and names Bash and Read" "Bash Read" "$named"

# --- the Kimi hook --------------------------------------------------------------------
home=$work/home
mkdir -p "$home/.kimi-code" "$home/proj"
# hook NAME EXPECTED_EXIT JSON; Kimi runs the call when the hook outlasts its timeout (config.toml)
hook() {
	env -i PATH=/usr/bin:/bin HOME="$home" KIMI_CODE_HOME="$home/.kimi-code" \
		timeout 10 python3 "$harness/kimi/openqa-credentials.py" <<<"$3" >/dev/null 2>"$work/err"
	check "kimi hook: $1" "$2" "$?"
}
# bash_call COMMAND [CWD]: a Bash call from a session in $home/proj, optionally with its own cwd
bash_call() { python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "tool_input": dict(zip(["command", "cwd"], sys.argv[2:])), "cwd": sys.argv[1]}))' "$home/proj" "$@"; }
hook "reading .netrc" 2 "$(bash_call 'cat ~/.netrc')"
hook "gh auth token" 2 "$(bash_call 'gh auth token')"
hook "gh auth status --show-token" 2 "$(bash_call 'gh auth status --show-token')"
hook "gh auth status -at" 2 "$(bash_call 'gh auth status -at')"
hook "gh auth status -th HOST" 2 "$(bash_call 'gh auth status -th github.com')"
hook "gh auth status alone" 2 "$(bash_call 'gh auth status')"
hook "an Authorization header" 2 "$(bash_call "curl -H 'Authorization: Bearer x' https://x.example.org")"
hook "an Authorization header as --header=" 2 "$(bash_call 'curl --header="Authorization: token x" https://x.example.org')"
hook "an Authorization header through openqa-cli -a" 2 "$(bash_call "openqa-cli api -a 'Authorization: Bearer u:k:s' --host o3 mcp")"
hook "a search for Authorization: in code" 0 "$(bash_call 'grep -rn Authorization: lib/')"
hook "a password in a URL" 2 "$(bash_call 'git clone https://user:dummy@github.com/o/r')"
hook "an ssh remote is no password" 0 "$(bash_call 'git clone git@github.com:o/r')"
hook "reading .git-credentials" 2 "$(bash_call 'cat ~/.git-credentials')"
hook "--apikey on a command line" 2 "$(bash_call 'openqa-cli api --apikey K jobs')"
hook "MOJO_CLIENT_DEBUG" 2 "$(bash_call 'MOJO_CLIENT_DEBUG=1 openqa-cli api jobs')"
for printer in 'git credential fill' 'osc config --dump-full' 'osc --http-full-debug ls' 'tea login helper get' \
	'tea login git-credential get' 'git-credential-store get' 'git-obs login list --show-tokens' \
	'gh auth git-credential get' 'git-obs login list' 'git obs -G x login list' 'git-obs login gitcredentials-helper get' \
	'tea logins git-credential get' 'tea login edit' 'tea -q login e' 'osc config --dump-f' 'osc --http-debug ls' \
	'osc --http-f ls' 'OSC_HTTP_DEBUG=1 osc ls' 'osc -H ls' 'osc -A obs -H api /' 'osc token' 'osc -A x token --create' \
	'osc config general pass' 'git credential-store get' 'git-credential-oauth get' "echo 'a;b' && osc token" \
	'osc -qH ls' 'osc -A obs -vH api /' 'osc api /person/someone/token' 'osc -A https://api.example.org token' \
	'osc "token"' '/usr/bin/osc -q config general passx'; do
	hook "a tool printing its own secret: $printer" 2 "$(bash_call "$printer")"
done
hook "an ordinary openqa-cli read" 0 "$(bash_call 'openqa-cli api --host o3 jobs')"
for ordinary in 'osc -h' 'osc -q ls' 'osc ls && echo token' 'osc ci -m "fix token handling"' \
	"osc sr -m 'rotate the token'" 'osc -A obs config general apiurl' 'osc ls | grep -H x' 'git credential-cache exit' 'tea pr list'; do
	hook "not a printer: $ordinary" 0 "$(bash_call "$ordinary")"
done
# tool_call TOOL JSON_ARGS: a call of any other tool from a session in $home/proj
tool_call() { printf '{"tool_name":"%s","tool_input":%s,"cwd":"%s"}' "$1" "$2" "$home/proj"; }
for tool in ReadMediaFile Write Edit; do
	hook "$tool of .netrc" 2 "$(tool_call "$tool" "{\"path\":\"$home/.netrc\"}")"
	hook "$tool of a project file" 0 "$(tool_call "$tool" '{"path":"notes.txt"}')"
done
hook "a Glob in the openQA config" 2 "$(tool_call Glob "{\"path\":\"$home/.config/openqa\",\"pattern\":\"*\"}")"
hook "a Glob in the project" 0 "$(tool_call Glob '{"path":".","pattern":"*.py"}')"
hook "a FetchURL of a credential file" 2 "$(tool_call FetchURL "{\"url\":\"file://$home/.netrc\"}")"
hook "a FetchURL of a web page" 0 "$(tool_call FetchURL '{"url":"https://openqa.opensuse.org/tests/1"}')"
# A session started in ~/.config: a relative path in a Bash call without its own cwd
printf '{"session_id":"s-1","workDir":"%s"}\n' "$home/.config" >"$home/.kimi-code/session_index.jsonl"
session_bash() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"session_id":"s-1","cwd":"%s"}' "$1" "$home/proj"; }
hook "a relative path in the session's directory" 2 "$(session_bash 'cat openqa/client.conf')"
hook "an ordinary file in the session's directory" 0 "$(session_bash 'cat notes.txt')"
printf '{"session_id":"s-1","wor\n' >>"$home/.kimi-code/session_index.jsonl"
hook "a session index line cut short is skipped" 0 "$(session_bash 'cat notes.txt')"
hook "the session's directory still counts after a cut line" 2 "$(session_bash 'cat openqa/client.conf')"
rm "$home/.kimi-code/session_index.jsonl"
hook "an ordinary git command" 0 "$(bash_call 'git log --oneline -3')"
hook "process.env is not a .env file" 0 "$(bash_call "node -e 'console.log(process.env.HOME)'")"
hook "Read of client.conf" 2 "{\"tool_name\":\"Read\",\"tool_input\":{\"path\":\"$home/.config/openqa/client.conf\"},\"cwd\":\"$home/proj\"}"
hook "Read of a project file" 0 "{\"tool_name\":\"Read\",\"tool_input\":{\"path\":\"notes.txt\"},\"cwd\":\"$home/proj\"}"
hook "a Grep over the home directory" 2 "{\"tool_name\":\"Grep\",\"tool_input\":{\"path\":\"$home\",\"pattern\":\"key\"},\"cwd\":\"$home/proj\"}"
hook "a Grep over the project" 0 "{\"tool_name\":\"Grep\",\"tool_input\":{\"path\":\"$home/proj\",\"pattern\":\"key\"},\"cwd\":\"$home/proj\"}"
hook "an MCP argument naming a credential file" 2 '{"tool_name":"mcp__fs__read","tool_input":{"path":"/etc/openqa/client.conf"},"cwd":"/"}'
hook "input that is not JSON fails closed" 2 'not json'
hook "input over 1 MB" 2 "$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__x__say", "tool_input": {"text": "a" * (1 << 20)}}))')"
hook "a command over 64 KB" 2 "$(bash_call "echo $(printf 'a%.0s' {1..65536})")"
hook "a path over 4096 characters" 2 "$(python3 -c 'import json; print(json.dumps({"tool_name": "Read", "tool_input": {"path": "/" + "a/" * 2500}}))')"
hook "an MCP argument over 64 KB" 2 "$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__x__run", "tool_input": {"command": "a" * 65537}}))')"
hook "64 KB of separators in time" 0 "$(bash_call "echo $(printf ';%.0s' {1..65000})")"
hook "64 KB of osc words in time" 0 "$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__x__run", "tool_input": {"command": "osc config x;" * 5000}}))')"
hook "gh auth status after 60 KB of words in time" 2 "$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__x__run", "tool_input": {"command": "osc -h " * 8500 + "; gh auth status"}}))')"
hook "a relative path in the call's cwd" 2 "$(bash_call 'cat hosts.yml' "$home/.config/gh")"
hook "a quoted relative path in the call's cwd" 2 "$(bash_call 'grep -r key "openqa"' "$home/.config")"
hook "a relative path up from the call's cwd" 2 "$(bash_call 'cat ../openqa/client.conf' "$home/.config/x")"
hook "a relative path from / as cwd" 2 "$(bash_call 'cat etc/openqa/client.conf' /)"
hook "a relative cwd" 2 "$(bash_call 'cat hosts.yml' ../.config/gh)"
hook "a checkout's etc/openqa is not /etc/openqa" 0 "$(bash_call 'cat etc/openqa/client.conf' "$home/src/openQA")"
hook "an ordinary command with a cwd" 0 "$(bash_call 'ls .. notes.txt' "$home/proj")"
check "kimi hook: a block says why on stderr" 1 "$(
	hook_err=$(env -i PATH=/usr/bin:/bin HOME="$home" python3 "$harness/kimi/openqa-credentials.py" <<<"$(bash_call 'gh auth token')" 2>&1 >/dev/null)
	grep -c 'Denied by openqa-credentials hook' <<<"$hook_err"
)"

# --- the Codex rules, when codex is installed -------------------------------------------
if command -v codex >/dev/null; then
	rules=$harness/codex/openqa-credentials.rules
	mkdir -p "$work/codex"
	decide() { CODEX_HOME=$work/codex codex execpolicy check --resolve-host-executables --rules "$rules" "$@" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision") or "none")' 2>/dev/null; }
	check "codex rules: cat of .netrc" forbidden "$(decide cat /home/USER/.netrc)"
	check "codex rules: head by absolute path" forbidden "$(decide /usr/bin/head /etc/openqa/client.conf)"
	check "codex rules: gh auth token" forbidden "$(decide gh auth token)"
	check "codex rules: gh auth status -at" forbidden "$(decide gh auth status -at)"
	check "codex rules: gh auth status --hostname HOST -t" forbidden "$(decide gh auth status --hostname github.com -t)"
	check "codex rules: --apikey" forbidden "$(decide openqa-cli api --apikey K jobs)"
	check "codex rules: an ordinary openqa-cli read" none "$(decide openqa-cli api --host o3 jobs)"
	check "codex rules: git credential fill" forbidden "$(decide git credential fill)"
	check "codex rules: osc config --dump-full" forbidden "$(decide osc config --dump-full)"
	check "codex rules: tea login helper get" forbidden "$(decide tea login helper get)"
	check "codex rules: tea login git-credential get" forbidden "$(decide tea login git-credential get)"
	check "codex rules: git-credential-store get" forbidden "$(decide git-credential-store get)"
	check "codex rules: git-obs --show-tokens" forbidden "$(decide git-obs login list --show-tokens)"
	check "codex rules: cat of .git-credentials" forbidden "$(decide cat /home/USER/.git-credentials)"
	check "codex rules: gh auth git-credential" forbidden "$(decide gh auth git-credential get)"
	check "codex rules: osc config --dump-f" forbidden "$(decide osc config --dump-f)"
	check "codex rules: osc --http-d" forbidden "$(decide osc --http-d ls)"
	check "codex rules: osc -H" forbidden "$(decide osc -H ls)"
	check "codex rules: osc -qH" forbidden "$(decide osc -qH ls)"
	check "codex rules: osc token" forbidden "$(decide osc token --create)"
	check "codex rules: tea login e" forbidden "$(decide tea login e)"
	check "codex rules: tea logins edit" forbidden "$(decide tea logins edit)"
	check "codex rules: git obs login gitcredentials-helper" forbidden "$(decide git obs login gitcredentials-helper get)"
	check "codex rules: git-credential-oauth get" forbidden "$(decide git-credential-oauth get)"
	check "codex rules: an ordinary osc command" none "$(decide osc ls openSUSE:Factory)"
	check "codex rules: an ordinary tea command" none "$(decide tea pr list)"
	check "codex rules: an ordinary git command" none "$(decide git status)"
else
	echo "ok - codex rules: codex not installed, rules not evaluated"
fi

exit $fail
