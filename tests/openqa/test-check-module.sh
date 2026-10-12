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

# "<file>:<line>[,<line>...]: <id> ..." -> "<lines> <id>"; the summary line is checked on its own
brief() {
	sed -E '/^summary: /d; s/^[^:]+:([0-9,+]+): ([a-z-]+) .*$/\1 \2/'
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

# --- rules that no longer run one regex over the line report what that regex did ------------
cat >"$work/tests/console/calls.pm" <<'EOF'
# Copyright SUSE LLC
# Summary: x
# Maintainer: QE <qe@example.com> # Maintainer: none
use Mojo::Base 'consoletest';
use testapi;
my $t = 100; check_screen 'desktop', $t;
check_screen 'desktop', $t;    # nocheck: 100 nocheck: old
check_screen 'desktop', $t;    # nocheck: old, 100 tries
$n++; record_soft_failure 'no ticket';
record_soft_failure 'no ticket'
  if $n;
$n++; record_soft_failure 'no ticket'
  if $n;
script_run( "daemon &" );
script_run "daemon &", 0 ;
script_run("daemon &", timeout => 0 ) ;
assert_script_run( 'zypper in vim' );
zypper_call( 'in -y vim' );
type_string( "ls\n" );
assert_and_click 'a'; assert_and_click 'b', 5;
assert_and_click 'a' and click_lastmatch 5;
click_lastmatch( 5 ) ;
assert_and_click( 'a', 5 ) ;
click_lastmatch timeout => 5;
check_screen('desktop', 30)
  or die;
my @a = (1, 2) if check_screen 'desktop';
check_screen 'a', 0; check_screen 'desktop', 30;
retry(timeout => 30, sub { script_run 'ls' });
script_run 'ls', timeout => 30
  if $n;
assert_script_run 'a' unless script_run 'b', timeout => 90;
script_run 'a', timeout => 5; script_run 'b', timeout => 30;
$out =~ s/'//g; script_run "sleep 2";
$out =~ s/"//g; sleep 2;
my $a = <<EOT;
sleep 3
EOT
my $b = <<EOT;
sleep 3
EOT
sleep 4;
1;
print <<EOT;
text
EOT
EOF
check "as the regexes did: the first '# Maintainer: ', the last 'nocheck:' and the last ';' of a line decide, '( ' opens a call, every click call and every statement is tried, the first call of a statement and what follows it count, a quote that never closes hides nothing and the other kind still closes, a here-document ends at the next line with its tag" \
	"8 check-screen-timeout
9 soft-failure-reference
14 script-run-background
17 raw-zypper
18 zypper-call-noninteractive
19 type-string-newline
20,21,22,23 click-positional-timeout
28 check-screen-wait
32 default-timeout
35,42 sleep
44 trailing-true" "$(lint "$work/tests/console/calls.pm" | brief)"

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

# --- semicolon-chain: look-alikes of the silent forms ---------------------------------------
chain=$(mktemp -d)
mkdir "$chain/lib"
cat >"$chain/lib/a.pm" <<'EOF'
assert_script_run("make ; make install", timeout => 600);
assert_script_run "umount /mnt;dd if=/dev/zero of=/tmp/t bs=512 count=1";
assert_script_run "yast keyboard set layout=german; echo";
assert_script_run 'cd /tmp/t; [ a -ef b ]; cd -';
assert_script_run "cd /tmp/t; test -f T.java || wget $url";
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
cat >"$chain/lib/home.pm" <<'EOF'
assert_script_run 'clear; make';
assert_script_run 'cd; rm -rf /tmp/t';
assert_script_run 'cd ~ ; rm -rf t';
assert_script_run 'echo "start: $(date)"; make';
assert_script_run 'clear; cd; echo go; make';
assert_script_run 'cd /tmp/t; make';
assert_script_run 'cd ~/t; make';
assert_script_run 'cdpy; python getParameter.py';
assert_script_run 'make clear; make';
assert_script_run 'echo 3 > /proc/sys/vm/drop_caches; sync';
assert_script_run 'echo go | tee /tmp/t/log; make';
assert_script_run 'echo go && rm /tmp/t/lock; make';
assert_script_run 'clear; rm /tmp/t/lock; make';
EOF
cat >"$chain/lib/value.pm" <<'EOF'
assert_script_run 'export PATH=/opt/bin:$PATH; tool';
assert_script_run "LD=$dir/${type}/exe:\$LD;export LD;$dir/run";
assert_script_run 'F=/tmp/t/f; N="a b"; touch $F';
assert_script_run 'TFAIL=$(awk 1 /tmp/t/log); echo $TFAIL';
assert_script_run 'h=`hostname`; grep -q $h /etc/hosts';
assert_script_run 'X="$(cat /tmp/t/f)"; make';
assert_script_run 'F=/tmp/t/f; rm $(cat $F)';
assert_script_run 'JOBS=4 make; make install';
assert_script_run 'f=/etc/t; [ ! -f $f ] && f=/usr$f; cat $f';
assert_script_run '[ -f /tmp/t/lock ] && rm /tmp/t/lock; make';
assert_script_run 'test -f /etc/t && f=$(cat /etc/t); make';
assert_script_run '[[ -d /usr/etc ]] && export D=/usr/etc; make';
assert_script_run 'test -e /etc/t && f=/etc/t; cat $f';
EOF
check "semicolon-chain: silent behind clear, cd home, an echo that writes nothing and an assignment, also one behind a test ('[', '[[' or 'test') and '&&'; cd to a directory, an echo with '>', '|' or '&&', a value from \$( ) or backticks, behind a test as well, an assignment in front of a command and a command behind a test are reported" \
	"lib/home.pm:6,7,8,9,10,11,12,13: semicolon-chain
lib/value.pm:4,5,6,7,8,10,11: semicolon-chain" "$(lint "$chain/lib/home.pm" "$chain/lib/value.pm" | sed "s|$chain/||" | grep -o '^[^ ]* semicolon-chain')"
cat >"$chain/lib/words.pm" <<'EOF'
assert_script_run 'grep --ignore-case error /tmp/t/log; ls /tmp/t';
assert_script_run 'journalctl --until today > /tmp/t/log; ls /tmp/t';
assert_script_run 'kubectl wait pod t --for condition=Ready; kubectl get pod t';
assert_script_run 'gfortran -c t.for ; ls t.o';
assert_script_run 'ovs-vsctl --if-exists del-br br0; ovs-vsctl add-br br0';
assert_script_run 'crudini --set -e /tmp/t/conf a b c; cat /tmp/t/conf';
assert_script_run 'ls /tmp/t |while read f; do rm $f; done';
assert_script_run 'make;if [ -f /tmp/t/a ]; then ls; fi';
assert_script_run 'make&&for f in a b; do rm $f; done';
assert_script_run '(for f in a b; do rm $f; done); ls';
assert_script_run 'echo `for f in a b; do echo $f; done` > /tmp/t/f; ls';
assert_script_run "sh -c 'until test -e /tmp/t/f; do date; done'; ls";
assert_script_run 'bash -c "case $1 in a) true;; esac"; ls';
assert_script_run 'make;set -e; cd /tmp/t; ls';
assert_script_run 'ls /tmp/t/a; if [ -f /tmp/t/b ]; then ls; fi';
assert_script_run 'echo wait for it > /tmp/t/log; make';
assert_script_run 'echo wait on it > /tmp/t/log; make';
assert_script_run 'git commit -m "fix for boo#1"; git push';
assert_script_run 'git commit -m "fix of boo#1"; git push';
assert_script_run 'mount /dev/vdb /mnt; grep -c for /mnt/t; make';
assert_script_run 'mount /dev/vdb /mnt; grep -c four /mnt/t; make';
assert_script_run '{ for f in a b; do rm $f; done; }; ls';
assert_script_run '! for f in a b; do test -e /tmp/t/$f; done';
assert_script_run 'time while pgrep make; do date; done';
assert_script_run 'make; time -p ! until test -e /tmp/t/f; do date; done';
EOF
check "semicolon-chain: a keyword or set that starts no command hides no chain ('--ignore-case', '--until', '--for', 'a.for', '--if-exists', '--set -e', 'for' behind a word, in quotes or not, each next to the same command with another word); one behind '|', ';', '&', '(', '{ ', a backtick or a quote still does, with blanks, 'time' or '!' in between or not" \
	"lib/words.pm:1,2,3,4,5,6,16,17,18,19,20,21: semicolon-chain" "$(lint "$chain/lib/words.pm" | sed "s|$chain/||" | grep -o '^[^ ]* semicolon-chain')"
cat >"$chain/lib/quotes.pm" <<'EOF'
assert_script_run 'echo set -e > /tmp/t/run.sh; chmod +x /tmp/t/run.sh';
assert_script_run 'echo "wait" for it > /tmp/t/log; make';
assert_script_run 'echo `date` if any > /tmp/t/log; make';
assert_script_run "awk '{if (\$2) print \$2}' /tmp/t/a > /tmp/t/b; make";
assert_script_run "bash -c ' for f in a b; do rm \$f; done'; ls";
assert_script_run "bash -c 'for f in a b; do " . $rm . "; done'";
EOF
check "semicolon-chain: 'set -e' behind a word, a keyword behind the quote or backtick that closes a text and one behind a '{' without a blank hide no chain; a keyword behind the quote that opens a text, or that never closes on the line, still does" \
	"lib/quotes.pm:1,2,3,4: semicolon-chain" "$(lint "$chain/lib/quotes.pm" | sed "s|$chain/||" | grep -o '^[^ ]* semicolon-chain')"
cat >"$chain/lib/joined.pm" <<'EOF'
assert_script_run "curl -f " . autoinst_url . "/data/t.sh -o /tmp/t/t.sh; chmod +x /tmp/t/t.sh";
assert_script_run('D=`dirname ' . $self->key . '`; mkdir -p $D');
assert_script_run "tar xf " . data_url("t/a.tar") . " -C /tmp/t" . "; make", 600;
assert_script_run "cd " . $dir . "; make";
assert_script_run "curl -f " . autoinst_url . "/data/t.sh -o /tmp/t/t.sh";
assert_script_run "bash -c 'cd " . $dir . "; make'";
assert_script_run "make " . $target, 600, 'no target; see the log';
assert_script_run "ls " . shell_quote("a; b");
assert_script_run "make " . $target if $log eq $dir . "/a; b";
EOF
echo "assert_script_run('umount {}; true'.format(mnt))" >"$chain/c.py"
check "semicolon-chain: a ';' in a string that '.' joins to the first one is a chain, behind a word, a method or a call with a string of its own, each of them one word ('cd' with one is no 'cd' home); no chain are strings joined without ';', a ';' inside quotes that open in an earlier string, a string behind ',', inside a call or behind 'if', and '.' in Python" \
	"lib/joined.pm:1,2,3,4: semicolon-chain" "$(lint "$chain/lib/joined.pm" "$chain/c.py" | sed "s|$chain/||" | grep -o '^[^ ]* semicolon-chain')"
cat >"$chain/lib/heredoc.pm" <<'EOF'
assert_script_run 'rm -f /tmp/t/out; grep -q x <<< "$v"';
assert_script_run 'rm -f /tmp/t/out; grep -q x < "$v"';
assert_script_run 'rm -f /tmp/t/out; n=$((1<<4)); make';
assert_script_run 'rm -f /tmp/t/out; n=$((1+4)); make';
assert_script_run "cd /tmp/t; cat > f <<-EOF\n\ta;\n\tEOF";
assert_script_run "cd /tmp/t; cat > f << 'EOF'\na;\nEOF";
assert_script_run "cd /tmp/t; cat > f <<\"EOF\"\na;\nEOF";
assert_script_run "cd /tmp/t; cat > f <<$tag\na;\n$tag";
EOF
check "semicolon-chain: a here-string and a shift are no here-document and hide no chain, each next to the same command without '<<'; '<<-', a blank, a quoted tag and a tag from a variable still open one" \
	"lib/heredoc.pm:1,2,3,4: semicolon-chain" "$(lint "$chain/lib/heredoc.pm" | sed "s|$chain/||" | grep -o '^[^ ]* semicolon-chain')"
cat >"$chain/lib/herestring.pm" <<'EOF'
script_run 'tr a b <<<EOT';
sleep 5;
my $t = <<EOT;
sleep 6
EOT
1;
EOF
check "a here-string in a command blanks no line of the module: the sleep behind '<<<EOT' is found, the one in the here-document is not" \
	"2 sleep" "$(lint "$chain/lib/herestring.pm" | brief)"
# --- lines built to stall a rule or the reading of the file --------------------------------
python3 - "$chain" <<'PY'
import sys
blank = " " * 60000
lines = [
    'assert_script_run "' + "\\" * 5000,
    'assert_script_run "' + "(" * 50000 + "a; b" + ")" * 50000 + '; c";',
    "assert_script_run" + blank,
    "# Maintainer: " * 16000,
    " " * 150000 + "x SPDX-License-Identifier FSFAP",
    "script_run" + blank + 'x; script_run "top -b &";',
    'script_run "top -b &", 0' + " " * 100000,
    "zypper_call" + blank + 'x; zypper_call "in -y vim";',
    "type_string" + " " * 120000 + 'x; type_string "ls\\n";',
    "assert_and_click" + " " * 20000 + "; assert_and_click 'button', 60;",
    "click_lastmatch" + blank + "x; click_lastmatch 60;",
    "click_lastmatch 60" + " " * 90000 + "x; click_lastmatch 60;",
    "assert_and_click " * 12000 + "; assert_and_click 'button', timeout => 30;",
    "check_screen " * 20000,
    "check_screen" + ",1" * 120000,
    "check_screen 00 " * 3000 + "# nocheck:",
    "script_run 'a', timeout => 30 " * 2000,
    "record_soft_failure " * 46000,
    "record_soft_failure '" + "a" * 140000 + "';",
    '"' + '\\"' * 40000 + " 'sleep 5';",
    "'" + "\\'" * 40000 + ' "sleep 5";',
    "assert_script_run '" + "cd ; A=1 ; " * 20000 + "ls';",
    "assert_script_run 'echo" + blank + "> /tmp/t; export" + blank + "; ls';",
    "assert_script_run 'make;" + blank + "time" + blank + "-p" + blank + "!" + blank + "ls';",
    "assert_script_run '" + 'make "a" for b; ' * 20000 + "ls';",
    "assert_script_run 'make; cat <<" + blank + "; ls';",
    "assert_script_run 'make'" + " . $x . 'a'" * 20000 + " . '; ls';",
    "assert_script_run 'make'" + blank + "." + blank + "'; ls';",
    "assert_script_run 'make' . f" + "(" * 50000 + "x" * 60000,
    "assert_script_run 'make' . f(\"" + '\\"' * 40000,
    "assert_script_run 'test -f a" + blank + "& make; ls';",
    "assert_script_run '[ -f a ]" + blank + "&&" + blank + "x=1" + blank + "; make';",
]
lines += ["<<EOT"] * 20000
lines += ["# Copyright SUSE LLC", "# Summary: x", "# Maintainer: QE <qe@example.com>", "use Mojo::Base 'consoletest';", "1;"]
open(f"{sys.argv[1]}/slow.pm", "w").write("\n".join(lines) + "\n")
PY
# The file takes a fifth of the limit; put back, each pattern or loop that was replaced takes twice the limit.
check "no line stalls the script: an open string of backslashes or quotes, deep nesting, a run of spaces behind each call, a call or its argument repeated, a chain of 40,000 commands, a run of spaces behind a ';', 'time', '-p', '!' and '<<', 20,000 keywords behind a closing quote, 40,000 joined strings and terms, a run of spaces around '.', a call and a string in a call behind '.' that never close, a run of spaces behind a test and around its '&&', here-documents that never end" \
	"2,23,24,25,26,27,28,31 semicolon-chain
5 spdx-colon
6,7 script-run-background
8 zypper-call-noninteractive
9 type-string-newline
10,11,12 click-positional-timeout
13 default-timeout
19 soft-failure-reference" "$(timeout 20 python3 "$script" "$chain/slow.pm" 2>/dev/null | brief)"
{
	printf "script_run 'a', timeout => %05000d;\nscript_run 'a', timeout => 030;\n" 9
	printf '%s\n' '# Copyright SUSE LLC' '# Summary: x' '# Maintainer: QE <qe@example.com>' "use Mojo::Base 'consoletest';" '1;'
} >"$chain/digits.pm"
check "default-timeout: a timeout of 5,000 digits is read, and leading zeros make no other number" \
	"2 default-timeout" "$(python3 "$script" "$chain/digits.pm" 2>&1 | brief)"
{
	printf "record_soft_failure '%s';\n" 'https://fate.suse.com/320678' 'https://fateXsuse.com/320678'
	printf '%s\n' '# Copyright SUSE LLC' '# Summary: x' '# Maintainer: QE <qe@example.com>' "use Mojo::Base 'consoletest';" '1;'
} >"$chain/fate.pm"
check "soft-failure-reference: only the FATE host itself is a reference" \
	"2 soft-failure-reference" "$(python3 "$script" "$chain/fate.pm" 2>&1 | brief)"
rm -rf "$chain"

check "the module of the speed-up eval has the two findings its prompt is about, and no other" "26 semicolon-chain
29 sleep" "$(lint "$here/../../evals/openqa/files/slow-module/tests/console/netns_veth.pm" | brief)"

lint --help >/dev/null
check "--help exits 0" 0 $?

exit $fail
