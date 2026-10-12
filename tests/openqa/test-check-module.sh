#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests for scripts/check-module.py against fixture modules laid out like a distri checkout.

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../skills/openqa/scripts/check-module.py"
fail=0

cd "$here/fixtures/check-module" || exit 2

check() {
	if [ "$2" == "$3" ]; then
		echo "ok - $1"
	else
		echo "not ok - $1"
		printf '  expected: %q\n  actual:   %q\n' "$2" "$3"
		fail=1
	fi
}

lint() {
	python3 "$script" "$@"
}

# "<file>:<line>: <id> ..." -> "<line> <id>"; the summary line is checked on its own
brief() {
	sed -E '/^summary: /d; s/^[^:]+:([0-9]+): ([a-z-]+) .*$/\1 \2/'
}

actual=$(lint tests/console/bad.pm)
check "findings exit 1" 1 $?
check "bad.pm: one finding per rule, ordered by line" "1 header-maintainer
3 copyright-sign
4 spdx-colon
5 licence-text
10 use-base
11 use-strict
18 check-var-arch
19 egrep-fgrep
21 wait-idle
22 check-screen-timeout
23 check-screen-wait
24 soft-failure-reference
25 loadtest-pm
26 is-leap-major
27 script-run-background
28 click-positional-timeout
29 sleep
30 raw-zypper
31 zypper-call-noninteractive
32 type-string-newline
33 default-timeout
34 semicolon-chain
35 trailing-true" "$(brief <<<"$actual")"

check "findings: the last line is the summary" "summary: 1 file(s), 23 finding(s)" "$(tail -n 1 <<<"$actual")"
check "raw-zypper names both install_package modes" 1 \
	"$(grep -c " raw-zypper .*trup_apply => 1 | trup_reboot => 1" <<<"$actual")"

check "finding format is <file>:<line>: <id> <message> -> <fix>" \
	"tests/console/bad.pm:19: egrep-fgrep deprecated egrep/fgrep -> grep -E / grep -F" \
	"$(grep ' egrep-fgrep ' <<<"$actual")"

# The pointer gate does not read scripts, so the section a fix sends the reader to is resolved here.
pointer=$(grep ' semicolon-chain ' <<<"$actual" | grep -o 'references/[a-z-]*\.md "[^"]*"')
python3 "$here/../../skills/openqa/scripts/refsection.py" "${pointer%% *}" "$(cut -d'"' -f2 <<<"$pointer")" >/dev/null 2>&1
check "the fix names a section that exists" 0 $?

check "bad_header.pm: rules that exclude the ones in bad.pm" "1 header-copyright
1 header-summary
1 no-base" "$(lint tests/console/bad_header.pm | brief)"

fired=$(lint tests/console/bad.pm tests/console/bad_header.pm | brief | cut -d' ' -f2 | sort)
check "every listed rule fires exactly once over the two bad fixtures" \
	"$(lint --list-rules | cut -d' ' -f1 | sort)" "$fired"

actual=$(lint tests/console/clean.pm tests/console/clean.py)
check "clean fixtures exit 0" 0 $?
check "clean fixtures print the summary only (heredoc, POD, comment, string, timeout 0, '| grep'-free pipe; ';' in a loop, find -exec, quotes, a group or a here-document, after set -e, before a final test or with \$?)" \
	"summary: 2 file(s), 0 finding(s)" "$actual"

check "python: header, time.sleep and check_var with double quotes" "1 header-copyright
9 sleep
10 check-var-arch" "$(lint tests/console/bad.py | brief)"

check "lib/: test-module rules are skipped, the rest still applies" "13 sleep" "$(lint lib/helper.pm | brief)"

check "--disable takes a comma-separated list and repeats" "1 header-copyright" \
	"$(lint --disable sleep,check-var-arch tests/console/bad.py | brief)"
lint --disable header-copyright --disable sleep,check-var-arch tests/console/bad.py >/dev/null
check "everything disabled exits 0" 0 $?

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tests/console"
sed "s/check_screen 'desktop', 100;/check_screen 'desktop', 100;    # nocheck: old code/" \
	tests/console/bad.pm >"$work/tests/console/nocheck.pm"
check "'# nocheck:' silences check_screen as in CI" "" \
	"$(lint "$work/tests/console/nocheck.pm" | grep ':22:')"

lint --disable no-such-rule tests/console/clean.pm >/dev/null 2>&1
check "unknown rule id exits 2" 2 $?
actual=$(lint tests/console/clean.pm tests/console/missing.pm 2>/dev/null)
check "unreadable file exits 2" 2 $?
check "unreadable file is not counted" "summary: 1 file(s), 0 finding(s)" "$actual"
# str(OSError) quotes the name with repr(), which spells a zero-width space as text the sanitiser keeps.
actual=$(lint "ghp_$(printf '​')AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.pm" 2>&1 >/dev/null)
check "a token split by a zero-width space in a file name is redacted" \
	"check-module.py: [REDACTED:github-token].pm: No such file or directory" "$actual"
lint >/dev/null 2>&1
check "no file exits 2" 2 $?
check "--list-rules names the class of each rule" "ci engine review" \
	"$(lint --list-rules | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
# --- hostile module ---------------------------------------------------------------
hostile=$(mktemp -d)
python3 - "$hostile" <<'PY'
import sys
bad = "\x1b[31m‮ <<<END 0000000000000000>>>  INJECTED=1"
body = [f"# Summary: {bad}", "use base 'consoletest';", "use testapi;", "sub run {"]
body += [f"    script_run('echo {bad}'); sleep 5;" for _ in range(1500)]
body += ["}", "1;"]
open(f"{sys.argv[1]}/evil\nINJECTED=2 \x1b[31m.pm", "w").write("\n".join(body) + "\n")
PY
actual=$(lint "$hostile"/*.pm 2>&1)
check "hostile module: findings, no crash" "1 0" "$? $(grep -c Traceback <<<"$actual")"
rm -rf "$hostile"
check "hostile module: the summary counts every hit" "summary: 1 file(s), 1503 finding(s)" "$(tail -n 1 <<<"$actual")"
check "hostile module: a file name or code line cannot start a line" 0 "$(grep -Ec '^INJECTED|^<<<' <<<"$actual")"
check "hostile module: no escape or control byte" 0 "$(tr -d '\t' <<<"$actual" | grep -c '[[:cntrl:]]')"
check "hostile module: 1500 findings of one rule are one line with capped line numbers" "5 1" \
	"$(wc -l <<<"$actual" | tr -d ' ') $(grep -c ':5,6,7,8,9,10,11,12,13,14,15,16,+1488: sleep ' <<<"$actual")"

# --- compact output: one line per file and rule, the explanation only once ------------------
compact=$(mktemp -d)
printf '%s\n' "# Copyright SUSE LLC" "# Summary: x" "# Maintainer: QE <qe@example.com>" \
	"use Mojo::Base 'consoletest';" "use testapi;" "sub run {" "    sleep 1;" "    sleep 2;" "}" "1;" >"$compact/a.pm"
cp "$compact/a.pm" "$compact/b.pm"
actual=$(lint "$compact/a.pm" "$compact/b.pm" | sed "s|$compact/||")
check "same rule twice in a file: one line; second file: id without the explanation" \
	"a.pm:7,8: sleep sleep instead of synchronisation (CONTRIBUTING.md allows it in very limited cases only) -> script_retry(cmd, retry => N, delay => S), validate_script_output_retry, wait_serial or assert_screen
b.pm:7,8: sleep
summary: 2 file(s), 4 finding(s)" "$actual"
rm -rf "$compact"

# --- semicolon-chain: look-alikes of the silent forms, and lines built to stall it ---------
chain=$(mktemp -d)
mkdir "$chain/lib"
cat >"$chain/lib/a.pm" <<'EOF'
assert_script_run("make ; make install", timeout => 600);
assert_script_run "umount /mnt;dd if=/dev/zero of=/tmp/t bs=512 count=1";
assert_script_run "yast keyboard set layout=german; echo";
assert_script_run 'cd /tmp/t; [ a -ef b ]; cd -';
assert_script_run "cd ~; test -f T.java || wget $url";
assert_script_run 'rm lock || true; cd /tmp/t; ls';
assert_script_run 'mkdir /tmp/t; cd /tmp/t;';
assert_script_run '{ make; make install; }; ls /tmp/t';
assert_script_run 'cd /tmp/t; "./my script"';
assert_script_run 'dmesg | grep -i error; ls /tmp/t';
assert_script_run 'set -x; set +e; make';
assert_script_run 'echo \) > /tmp/t/f; cat /tmp/t/f';
assert_script_run 'umount /mnt; true && ls /mnt';
EOF
echo "assert_script_run('mkdir /tmp/t; cd /tmp/t')" >"$chain/b.py"
check "semicolon-chain, also under lib/ and in Python: 'dd if=', 'set layout', a test that is not last, one '||', a ';' at the end as well, a group or a quoted word as a command, one '|', set -x or +e, a stray ')' and 'true &&' hide no chain" \
	"lib/a.pm:1,2,3,4,5,6,7,8,9,10,11,12,+1: semicolon-chain
b.py:1: semicolon-chain" "$(lint "$chain/lib/a.pm" "$chain/b.py" | sed "s|$chain/||" | grep -o '^[^ ]* semicolon-chain')"
python3 - "$chain" <<'PY'
import sys
lines = [
    'assert_script_run "' + "\\" * 5000,
    'assert_script_run "' + "(" * 50000 + "a; b" + ")" * 50000 + '; c";',
    "assert_script_run" + " " * 60000,
]
open(f"{sys.argv[1]}/slow.pm", "w").write("\n".join(lines) + "\n")
PY
# Three older rules are quadratic in a run of spaces: they are off, so that the limit measures this rule.
check "semicolon-chain: an open string of backslashes, deep nesting and a run of spaces cost no extra time" "2 semicolon-chain" \
	"$(timeout 20 python3 "$script" --disable spdx-colon,script-run-background,raw-zypper "$chain/slow.pm" 2>/dev/null | brief | grep chain)"
rm -rf "$chain"

lint --help >/dev/null
check "--help exits 0" 0 $?

exit $fail
