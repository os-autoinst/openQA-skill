#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests for scripts/vr-clone-cmd.py: every input form, every hazard line, every refusal.

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../skills/openqa/scripts/vr-clone-cmd.py"
fixtures="$here/fixtures/vr-clone-cmd"
fail=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pr=https://github.com/os-autoinst/os-autoinst-distri-opensuse/pull/6529
lab=https://openqa.example.org/tests/4242
fork=(--fork alice --branch fix/foo)

# run ARGS...: stdout in $out, first line in $cmd, stderr in $err, exit code in $rc
run() {
	out=$(COLUMNS=200 python3 "$script" "$@" 2>"$work/err")
	rc=$?
	err=$(<"$work/err")
	cmd=${out%%$'\n'*}
}

ok() {
	echo "ok - $1"
}

not_ok() {
	echo "not ok - $1"
	shift
	printf '  %s\n' "$@"
	fail=1
}

check() {
	if [ "$2" == "$3" ]; then ok "$1"; else not_ok "$1" "expected: $2" "actual:   $3"; fi
}

has() {
	if [[ "$3" == *"$2"* ]]; then ok "$1"; else not_ok "$1" "missing: $2" "in:      $3"; fi
}

lacks() {
	if [[ "$3" != *"$2"* ]]; then ok "$1"; else not_ok "$1" "unwanted: $2" "in:       $3"; fi
}

golden() {
	local name=$1 want_rc=$2
	shift 2
	run "$@"
	check "$name: exit code" "$want_rc" "$rc"
	check "$name: output" "$(<"$fixtures/$name.out")" "$out"
}

refused() {
	local name=$1 message=$2
	shift 2
	run "$@"
	check "$name: exit code 2" 2 "$rc"
	check "$name: nothing on stdout" "" "$out"
	has "$name: reason on stderr" "$message" "$err"
}

# --- whole-output forms ---
golden fork-basic 0 --job "$lab#step/foo/1" "${fork[@]}" --skip-chained-deps --within-instance
golden pr-basic 0 --job https://openqa.example.org/t4242 --pr "$pr/files"
golden fork-worst 1 --job openqa.opensuse.org 4242 --fork alice --branch 'fix(foo)' \
	--repo-name os-autoinst-distri-example --parent-publishes --within-instance \
	--schedule console/foo,bar --set INCLUDE_MODULES=foo --set 'DESKTOP=text mode' \
	--set QEMURAM= --set 'EXTRA+=,x' --set WORKER_CLASS:client=w2 --label poo123
golden pr-worst 1 --job openqa.suse.de/tests/77 --pr "${pr%/*}/1" --needles-fork bob \
	--needles-branch nb --schedule console/foo --set WORKER_CLASS:client=w2 --dry-run-flag \
	--label poo123

for name in fork-worst pr-worst; do
	lines=$(wc -l <"$fixtures/$name.out")
	if [ "$lines" -le 9 ]; then ok "$name: command plus at most 8 lines"; else not_ok "$name: $lines lines"; fi
done

# --- --job forms ---
run --job "$lab" "${fork[@]}"
url_form=$cmd
run --job https://openqa.example.org 4242 "${fork[@]}"
check "host + id gives the same command as a job URL" "$url_form" "$cmd"
run --job openqa.opensuse.org/tests/5 "${fork[@]}"
has "bare production host gets https" " https://openqa.opensuse.org/tests/5 " "$cmd"
run --job localhost:9526/tests/5 "${fork[@]}" --within-instance
has "bare other host gets http like openqa-clone-job, port kept" " http://localhost:9526/tests/5 " "$cmd"
refused "job URL without id" "no /tests/<id>" --job https://openqa.example.org/group_overview/1 "${fork[@]}"
refused "non-numeric id" "must be a number" --job openqa.example.org 12a "${fork[@]}"
refused "URL plus id" "not both" --job "$lab" 4242 "${fork[@]}"

# --- form selection ---
refused "neither --pr nor --fork" "either --pr URL or both" --job "$lab"
refused "--fork without --branch" "either --pr URL or both" --job "$lab" --fork alice
refused "--pr with --fork" "mutually exclusive" --job "$lab" --pr "$pr" "${fork[@]}"
refused "not a PR URL" "expected https://github.com" --job "$lab" --pr "${pr%/pull/*}/tree/foo"
refused "bad fork name" "not a GitHub name" --job "$lab" --fork 'al/ice' --branch x
has "bad fork name: the placeholder is named" "pass the literal '<user>'" "$err"

# --- placeholders for a fork that is not known yet ---
golden fork-placeholder 0 --job "$lab" --fork '<user>' --branch '<branch>' \
	--needles-fork '<user>' --needles-branch '<branch>' --within-instance
run --job "$lab" --fork '<user>' --branch fix/foo
check "placeholder user with a real branch: exit 0" 0 "$rc"
has "placeholder user: emitted verbatim and quoted for the shell" "'CASEDIR=https://github.com/<user>/os-autoinst-distri-opensuse.git#fix/foo'" "$cmd"
has "placeholder user: TEST suffix is kept" "'TEST+=@<user>/os-autoinst-distri-opensuse#fix/foo'" "$cmd"
has "placeholder user: note to replace it" "note: replace <user>/<branch> before running" "$out"
run --job "$lab" "${fork[@]}"
lacks "real fork: no placeholder note" "replace <user>" "$out"
refused "other angle-bracket names stay refused" "not a GitHub name" --job "$lab" --fork '<me>' --branch x
refused "placeholder as repo name" "not a GitHub name" --job "$lab" --fork alice --branch x --repo-name '<user>'

run --job "$lab" --fork alice --branch 0123abc --repo-name os-autoinst-distri-example
has "--repo-name changes CASEDIR" "'CASEDIR=https://github.com/alice/os-autoinst-distri-example.git#0123abc'" "$cmd"

# --- _GROUP=0 and labels ---
run --job "$lab" "${fork[@]}"
has "fork form has _GROUP=0" " _GROUP=0 " "$cmd"
has "default label is <user>/<repo>#<ref>" "'BUILD=alice/os-autoinst-distri-opensuse#fix/foo'" "$cmd"
has "TEST gets a recognisable suffix" "'TEST+=@alice/os-autoinst-distri-opensuse#fix/foo'" "$cmd"
run --job "$lab" --pr "$pr"
has "PR form passes _GROUP=0 explicitly" " _GROUP=0" "$cmd"
lacks "PR form leaves BUILD to the helper by default" "BUILD=" "$cmd"
run --job "$lab" --pr "$pr" --label poo123
has "PR form --label becomes an extra BUILD argument" " BUILD=poo123" "$cmd"
run --job "$lab" "${fork[@]}" --label 'poo 123'
has "--label with a space is shell-quoted" "'BUILD=poo 123'" "$cmd"

# --- needles ---
run --job "$lab" "${fork[@]}" --needles-fork bob --needles-branch nb
has "fork form adds NEEDLES_DIR" "'NEEDLES_DIR=https://github.com/bob/os-autoinst-needles-opensuse.git#nb'" "$cmd"
lacks "no production-needles note when needles are set" "production needles" "$out"
run --job "$lab" "${fork[@]}" --set NEEDLES_DIR=https://gitlab.example/needles.git#nb
lacks "NEEDLES_DIR via --set counts as set" "production needles" "$out"
run --job "$lab" --pr "$pr" --needles-fork bob --needles-branch nb --needles-repo-name my-needles
has "PR form adds NEEDLES_DIR with --needles-repo-name" "'NEEDLES_DIR=https://github.com/bob/my-needles.git#nb'" "$cmd"
has "PR form reminds that the helper never sets NEEDLES_DIR" \
	"note: helper never sets NEEDLES_DIR; it is passed as an extra argument" "$out"
refused "--needles-fork alone" "go together" --job "$lab" "${fork[@]}" --needles-fork bob
refused "NEEDLES_DIR twice" "conflicts" --job "$lab" "${fork[@]}" --needles-fork bob --needles-branch nb \
	--set NEEDLES_DIR=x

# --- --schedule ---
run --job "$lab" "${fork[@]}" --schedule tests/boot/boot_to_desktop,tests/console/foo.pm
check "valid schedule: exit code 0" 0 "$rc"
has "valid schedule is passed through" " SCHEDULE=tests/boot/boot_to_desktop,tests/console/foo.pm" "$cmd"
lacks "valid schedule: no hazard" "hazard:" "$out"
run --job "$lab" "${fork[@]}" --schedule tests/boot/boot_to_desktop,console/foo
check "missing tests/ prefix: exit code 1" 1 "$rc"
has "missing tests/ prefix: hazard names the entry" "hazard: SCHEDULE: console/foo lacks the tests/ prefix" "$out"
lacks "missing tests/ prefix: good entry not named" "boot_to_desktop lacks" "$out"
run --job "$lab" "${fork[@]}" --schedule tests/boot/boot_to_desktop,foo
has "bare module name: hazard" "hazard: SCHEDULE: bare name foo needs an ASSET_<n>_URL sideload" "$out"
run --job "$lab" "${fork[@]}" --schedule tests/boot/boot_to_desktop,foo --set ASSET_1_URL=https://example.org/foo.pm
check "bare module name with ASSET_1_URL: exit code 0" 0 "$rc"
run --job "$lab" "${fork[@]}" --schedule tests/console/foo --set INCLUDE_MODULES=foo
has "INCLUDE_MODULES with SCHEDULE: hazard" "hazard: SCHEDULE: INCLUDE_MODULES is discarded" "$out"
refused "dot without module extension" "disables the implicit .pm" --job "$lab" "${fork[@]}" --schedule tests/console/foo.bar
refused "same basename from two directories" "two directories" --job "$lab" "${fork[@]}" \
	--schedule tests/console/foo,tests/x11/foo
refused "absolute schedule path" "relative path within CASEDIR" --job "$lab" "${fork[@]}" --schedule /tests/console/foo
refused "empty schedule entry" "empty entry" --job "$lab" "${fork[@]}" --schedule tests/console/foo,
refused "SCHEDULE via --set" "use --schedule" --job "$lab" "${fork[@]}" --set SCHEDULE=console/foo

# --- dependency and host flags ---
run --job "$lab" "${fork[@]}"
lacks "no --skip-chained-deps unless asked" "--skip-chained-deps" "$cmd"
lacks "no --within-instance unless asked" "--within-instance" "$cmd"
has "without --within-instance the target is localhost" "on http://localhost," "$out"
run --job "$lab" "${fork[@]}" --skip-chained-deps --within-instance
has "--within-instance is directly followed by the job URL" "--skip-chained-deps --within-instance $lab _GROUP=0" "$cmd"
run --job "$lab" "${fork[@]}" --parent-publishes
check "parent publishes without --skip-chained-deps: exit code 1" 1 "$rc"
has "parent publishes without --skip-chained-deps: hazard" \
	"hazard: parent publishes assets and --skip-chained-deps is missing" "$out"
run --job "$lab" "${fork[@]}" --parent-publishes --skip-chained-deps
check "parent publishes with --skip-chained-deps: exit code 0" 0 "$rc"
run --job "$lab" --pr "$pr" --parent-publishes
check "PR form always skips chained parents: exit code 0" 0 "$rc"

# --- production hosts ---
for host in openqa.opensuse.org openqa.suse.de openqa.debian.net; do
	run --job "https://$host/tests/1" "${fork[@]}" --skip-chained-deps --within-instance
	check "$host within instance: exit code 1" 1 "$rc"
	has "$host within instance: hazard" "hazard: $host is a production instance" "$out"
done
run --job https://openqa.opensuse.org/tests/1 --pr "$pr"
has "PR form on o3: hazard" "hazard: openqa.opensuse.org is a production instance" "$out"
run --job https://openqa.opensuse.org/tests/1 "${fork[@]}" --skip-chained-deps
check "o3 as source only: exit code 0" 0 "$rc"
lacks "o3 as source only: no production hazard" "production instance" "$out"

# --- --set ---
run --job "$lab" "${fork[@]}" --set FOO=1 --set BAR= --set 'BAZ+=x y' --set WORKER_CLASS:client=w2
has "settings keep their order and come before TEST+=" \
	" _GROUP=0 FOO=1 BAR= 'BAZ+=x y' WORKER_CLASS:client=w2 'BUILD=" "$cmd"
has "overrides line lists appends, scopes and deletions" \
	"overrides: _GROUP BUILD TEST+= CASEDIR FOO BAZ+= WORKER_CLASS:client; deletes: BAR" "$out"
check "scoped setting in fork form is no hazard" 0 "$rc"
eval "set -- $cmd"
check "printed command survives shell parsing" "BAZ+=x y" "$6"
canary="$work/canary"
run --job "$lab" --fork alice --branch "fix;\$(id>$canary)\`id>$canary\`" --label "b \"q\" \$(touch $canary)" \
	--set "FOO=\$(touch $canary)" --set "BAR=\`touch $canary\`" --set "BAZ=a;touch $canary|b&c>$canary"
eval "set -- $cmd"
check "shell metacharacters in every value arrive verbatim" \
	"FOO=\$(touch $canary) BAR=\`touch $canary\` BAZ=a;touch $canary|b&c>$canary BUILD=b \"q\" \$(touch $canary)" "$4 $5 $6 $7"
check "parsing the printed command runs nothing" no "$([ -e "$canary" ] && echo yes || echo no)"
refused "userinfo in the job URL" "not a plain host name" --job 'https://openqa.suse.de@evil.example.org/tests/1' "${fork[@]}"
# shellcheck disable=SC2016
refused "command substitution in the host" "not a plain host name" --job 'https://ev$(id)il.example.org/tests/1' "${fork[@]}"
refused "separator in a bare host" "not a plain host name" --job 'openqa.example.org;id' 1 "${fork[@]}"
refused "homoglyph host" "not a plain host name" --job 'https://Ð¾penqa.example.org/tests/1' "${fork[@]}"
refused "broken IPv6 literal" "not a plain host name" --job 'https://[bad/tests/1' "${fork[@]}"
refused "lowercase key" "uppercase" --job "$lab" "${fork[@]}" --set foo=1
refused "mixed-case key (upstream would set VAR)" "uppercase" --job "$lab" "${fork[@]}" --set myVAR=1
refused "setting without =" "expected KEY=VALUE" --job "$lab" "${fork[@]}" --set FOO
refused "_GROUP via --set" "_GROUP=0 is always set" --job "$lab" "${fork[@]}" --set _GROUP=5
refused "BUILD via --set" "use --label" --job "$lab" "${fork[@]}" --set BUILD=x
refused "CASEDIR via --set" "use --fork" --job "$lab" --pr "$pr" --set CASEDIR=x
run --job "$lab" --pr "$pr" --set DESKTOP=textmode --set WORKER_CLASS:client=w2
has "PR form appends settings after the job URL" " $lab _GROUP=0 DESKTOP=textmode WORKER_CLASS:client=w2" "$cmd"
check "PR form scoped setting: exit code 1" 1 "$rc"
has "PR form scoped setting: hazard" "hazard: KEY:<TEST>= runs after the helper's TEST+=" "$out"

# --- ref not usable in TEST ---
run --job "$lab" --fork alice --branch 'fix(foo)'
check "ref with characters outside the TEST alphabet: exit code 1" 1 "$rc"
lacks "ref with characters outside the TEST alphabet: no TEST+=" "TEST+=" "$cmd"
has "ref with characters outside the TEST alphabet: hazard" "hazard: ref has characters not allowed in TEST" "$out"
has "ref with characters outside the TEST alphabet: CASEDIR kept" "#fix(foo)'" "$cmd"

# --- dry run and approval ---
run --job "$lab" "${fork[@]}" --within-instance --dry-run-flag
has "fork form dry run uses --export-command" "openqa-clone-job --export-command --within-instance $lab" "$cmd"
has "dry run: approval line says nothing is posted" "approval: --export-command only reads and prints" "$out"
run --job "$lab" --pr "$pr" --dry-run-flag
has "PR form dry run goes through --clone-job-args" \
	"openqa-clone-custom-git-refspec --clone-job-args=--export-command $pr $lab" "$cmd"
run --job "$lab" "${fork[@]}" --within-instance
has "approval reminder names the target host" \
	"approval: running this posts jobs to https://openqa.example.org, a write; get the user's approval first" "$out"
run --job "$lab" --pr "$pr"
has "PR form carries the approval reminder" "approval: running this posts jobs to" "$out"
has "PR form warns about the PR-body marker" "note: an '@openqa: Clone <url>' line in the PR body replaces" "$out"

# --- input the helper would mis-parse ---
refused "PR form with a single quote" "single quote" --job "$lab" --pr "$pr" --set "FOO=it's"
refused "PR form with a host starting with t" "host starting with 't'" --job https://testing.example.org/tests/1 --pr "$pr"
refused "PR form with an org starting with pull" "starting with 'pull'" --job "$lab" \
	--pr https://github.com/pullman/repo/pull/3
run --job "$lab" "${fork[@]}" --set "FOO=it's"
check "fork form quotes a single quote itself" 0 "$rc"

# --- hostile input ---
refused "escape sequence in a ref" "control or invisible" --job "$lab" --fork alice --branch $'fix\e[31m'
refused "zero-width character in a setting" "control or invisible" --job "$lab" "${fork[@]}" --set $'FOO=a​b'
refused "newline in a label" "control or invisible" --job "$lab" "${fork[@]}" --label $'a\nhazard: none'

# A credential in an argument is refused before any message could echo it.
refused "a password in the job URL" "contains a credential (url-userinfo)" --job 'https://u:s3cretPassw0rd@openqa.example.org/tests/1' "${fork[@]}"
lacks "a password in the job URL: not echoed" "s3cretPassw0rd" "$err"
refused "a token as a URL's userinfo in a setting" "contains a credential (url-token)" --job "$lab" "${fork[@]}" --set 'ASSET_1_URL=https://a1b2c3d4e5f6a7b8c9d0e1f2@host/x'
lacks "a token in a setting: not echoed" "a1b2c3d4e5f6a7b8c9d0e1f2" "$err"
refused "a secret setting" "contains a credential (keyed-assignment)" --job "$lab" "${fork[@]}" --set 'SCC_REGCODE=ABCD1234EFGH5678'
lacks "a secret setting: not echoed" "ABCD1234EFGH5678" "$err"
split="FOO=ghp_"$'\xe2\x80\x8b'"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
refused "a token split by an invisible character" "contains a credential (github-token)" --job "$lab" "${fork[@]}" --set "$split"
lacks "a split token: not echoed" "AAAAAAAAAAAA" "$err"
# A setting whose name says credential is refused whatever its value looks like; deleting it is fine.
refused "a secret setting appended with +=" "--set SCC_REGCODE: a credential setting" --job "$lab" "${fork[@]}" --set 'SCC_REGCODE+=ABCD1234EFGH5678'
lacks "a secret setting appended with +=: not echoed" "ABCD1234EFGH5678" "$err"
refused "a secret array setting" "--set SCC_REGCODE: a credential setting" --job "$lab" "${fork[@]}" --set 'SCC_REGCODE[]=ABCD1234EFGH5678'
lacks "a secret array setting: not echoed" "ABCD1234EFGH5678" "$err"
# shellcheck disable=SC2016
refused "a secret setting from a \$VAR" "--set SCC_REGCODE: a credential setting" --job "$lab" "${fork[@]}" --set 'SCC_REGCODE=$SCC_KEY'
refused "a secret setting whose key is not uppercase" "--set scc_regcode: a credential setting" --job "$lab" "${fork[@]}" --set 'scc_regcode+=/AbCd+EfGh/1234'
lacks "a secret setting whose key is not uppercase: not echoed" "AbCd" "$err"
run --job "$lab" "${fork[@]}" --set 'SCC_REGCODE='
check "deleting a secret setting: exit code 0" 0 "$rc"
has "deleting a secret setting: listed" "deletes: SCC_REGCODE" "$out"
# Userinfo shapes a redaction rule can miss: the value is not echoed at all.
refused "a password with no user name in the job URL" "--job: " --job 'https://:s3cretPassw0rd@openqa.example.org/tests/1' "${fork[@]}"
lacks "a password with no user name: not echoed" "s3cretPassw0rd" "$err"
refused "a password with a slash in the job URL" "--job: " --job 'https://u:2024/Winter@openqa.example.org/tests/1' "${fork[@]}"
lacks "a password with a slash: not echoed" "Winter" "$err"
refused "a URL with a password as the job id" "--job: " --job openqa.example.org 'https://:s3cretPassw0rd@x/1' "${fork[@]}"
lacks "a URL with a password as the job id: not echoed" "s3cretPassw0rd" "$err"

# A value holding "@" is never echoed, whatever the message.
run --job "$lab" "${fork[@]}" --schedule 'tests/x,admin:Hunter2pw@files.example.txt'
lacks "an @ in a --schedule entry: not echoed" "Hunter2pw" "$err"
run --job "$lab" --fork 'alice:Hunter2pw@x' --branch fix
lacks "an @ in --fork: not echoed" "Hunter2pw" "$err"
run --job "$lab" "${fork[@]}" --label $'admin:Hunter2pw\xe2\x80\x8b@files.example'
lacks "an @ in a label with an invisible character: not echoed" "Hunter2pw" "$err"

# A scope that never reaches the "=" used to split in quadratically many ways: 16 kB took 20 s.
bomb="A:$(python3 -c 'print("a" * 8192)')"
refused "setting longer than the cap" "longer than 8192 characters" --job "$lab" "${fork[@]}" --set "$bomb"
bomb="A:$(python3 -c 'print("a" * 8000)')"
start=$SECONDS
run --job "$lab" "${fork[@]}" --set "$bomb"
check "a setting that never reaches '=' is rejected at once" "2 fast" \
	"$rc $([ $((SECONDS - start)) -le 5 ] && echo fast || echo "slow: $((SECONDS - start))s")"
has "a setting that never reaches '=' names the form" "expected KEY=VALUE" "$err"

# --- usage ---
run --help
check "--help: exit code 0" 0 "$rc"
has "--help documents the exit codes" "Exit codes: 0 no hazard, 1 command printed with hazard lines" "$out"
run "${fork[@]}"
check "missing --job: exit code 2" 2 "$rc"

exit $fail
