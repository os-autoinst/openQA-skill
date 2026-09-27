#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests for scripts/oqa-comment-lint.py: pure text in, text out; no network.

here=$(cd "$(dirname "$0")" && pwd)
scripts="$here/../../skills/openqa/scripts"
fixtures="$here/fixtures/oqa-comment-lint"
src="$scripts/oqa-comment-lint.py"
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

contains() {
	case "$3" in
	*"$2"*) echo "ok - $1" ;;
	*)
		echo "not ok - $1"
		printf '  missing: %q\n  in:      %q\n' "$2" "$3"
		fail=1
		;;
	esac
}

# lint <fixture> [args]: lint a draft file through stdin
lint() {
	local name=$1
	shift
	python3 "$src" "$@" <"$fixtures/$name.txt" 2>&1
}

# parsed <python expression over m>: the ported parsers, with the scripts directory importable
parsed() {
	(cd "$scripts" && python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("lint", "oqa-comment-lint.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
refs = lambda text: [match.group("match") for match in m.BUGREF.finditer(text)]
labels = lambda text: [match.group("match") for match in m.LABEL.finditer(text)]
'"$1" 2>&1)
}

# --- offline by construction -----------------------------------------------------
check "no network or process code" 0 "$(grep -Ec 'urllib\.request|http\.client|socket|urlopen|subprocess|os\.system|import _oqa' "$src")"
check "licence header" "# SPDX-License-Identifier: GPL-2.0-or-later" "$(sed -n 2p "$src")"
# shellcheck disable=SC2016
check "the source regexes are quoted in comments" 5 \
	"$(grep -Ec '^# +(\$BUGREF_REGEX = qr|BUGREF_REGEX => qr|.*LABEL_REGEX => qr|.*FLAG_REGEX => qr|next unless \$label =~)' "$src")"

# --- usage ----------------------------------------------------------------------
python3 "$src" --help >/dev/null
check "--help exits 0" 0 $?
actual=$(python3 "$src" --text "" 2>&1)
check "empty draft is a usage error" "2 error: empty draft" "$? $actual"
actual=$(python3 "$src" --text "boo#1000001 short title")
status=$?
check "--text works like stdin" "0 $(lint good | sed 1d)" "$status $(sed 1d <<<"$actual")"
check "FILE works like stdin" "$(lint good)" "$(python3 "$src" "$fixtures/good.txt")"
check "FILE '-' reads stdin" "$(lint good)" "$(python3 "$src" - <"$fixtures/good.txt")"
actual=$(python3 "$src" "$fixtures/good.txt" --text x 2>&1)
check "FILE with --text is a usage error" 2 $?
actual=$(python3 "$src" "$fixtures/no-such
INJECTED=1.txt" 2>&1)
check "unreadable FILE exits 2 on one line" "2 1" "$? $(wc -l <<<"$actual" | tr -d ' ')"

# --- the ported regexes, against results taken from openQA's own Perl functions ------
# shellcheck disable=SC2016
check "find_bugrefs parity (table verified with OpenQA::Utils)" "$(
	cat <<'EOF'
['bootloader_uefi#1']
['ghostscript#2']
[]
[]
[]
['boo#1253385']
['poo#207036']
['boo#123']
[]
[]
[]
['gh#os-autoinst/openQA#1234', 'poo#1', 'jsc#PED-9', 'bsc#77', 'poo#5']
['boo#1', 'bsc#2', 'poo#3', 'kde#4;fdo#5', 'bnc#6', 'pio#repo#7', 'pio#ns/repo#8', 'ffo#a/b#9']
EOF
)" "$(parsed '
for text in ("**TL;DR:**\nbootloader_uefi#1: foo", "ghostscript#2 fails", "`bootloader_uefi#1`: foo",
             "installation/bootloader_uefi#1: x", "kdump#1", "generic/347: boo#1253385", "coredump01 - poo#207036",
             "boo#123.", "see (boo#123)", "label:boo#123", "label:force_result:softfailed:bsc#1234",
             "gh#os-autoinst/openQA#1234,poo#1 jsc#PED-9 bsc#12\"x bsc#12a <b>bsc#77</b> <strong>poo#5</strong> <toolongtag>poo#6",
             "boo#1\nbsc#2\n\tpoo#3,kde#4;fdo#5 bnc#6. pio#repo#7 pio#ns/repo#8 ffo#a/b#9"):
    print(refs(text))
')"
check "find_labels / find_flags / force_result parity" "$(
	cat <<'EOF'
['foo', 'a/b-c', 'x', 'linked:poo#1']
['carryover', 'carry']
('softfailed', 'bsc')
('passed', 'desc_1')
None
EOF
)" "$(parsed '
text = "label:foo.bar label:a/b-c: label:x label:linked:poo#1 flag:carryover flag:carry-over Label:nope mylabel:zz label: spaced"
print(labels(text))
print([match.group("match") for match in m.FLAG.finditer(text)])
for label in ("force_result:softfailed:bsc#1234", "force_result:passed:desc_1:more", "force_result"):
    found = m.FORCE_RESULT.match(label)
    print(found.groups() if found else None)
')"
check "href_to_bugref and bugurl parity" "$(
	cat <<'EOF'
see gh#os-autoinst/openQA#966 and poo#12345,
(https://bugzilla.suse.com/show_bug.cgi?id=55) [x](https://github.com/a/b/pull/7) "https://pagure.io/foo/issue/3"
ggo#GNOME/gnome-shell#5244 jsc#PED-123 HTTPS://BUGZILLA.SUSE.COM/show_bug.cgi?id=9
bsc#42 https://github.com/123 https://forge.fedoraproject.org/o/r#12
['https://bugzilla.novell.com/show_bug.cgi?id=42 https://github.com/123 https://forge.fedoraproject.org/o/r/work_items/12']
https://gitlab.gnome.org/GNOME/gnome-shell/issues/5244 https://pagure.io/ns/repo/issue/8 https://bugzilla.suse.com/show_bug.cgi?id=6
EOF
)" "$(parsed '
for text in ("see https://github.com/os-autoinst/openQA/issues/966 and https://progress.opensuse.org/issues/12345,",
             "(https://bugzilla.suse.com/show_bug.cgi?id=55) [x](https://github.com/a/b/pull/7) \"https://pagure.io/foo/issue/3\"",
             "https://gitlab.gnome.org/GNOME/gnome-shell/-/issues/5244 https://jira.suse.com/browse/PED-123 HTTPS://BUGZILLA.SUSE.COM/show_bug.cgi?id=9",
             "https://bugzilla.novell.com/show_bug.cgi?id=42 https://github.com/123 https://forge.fedoraproject.org/o/r/work_items/12"):
    print(m.href_to_bugref(text)[0])
print(m.href_to_bugref(text)[2])
print(*(m.bugurl(match) for match in m.BUGREF.finditer("ggo#GNOME/gnome-shell#5244 pio#ns/repo#8 bnc#6")))
')"

# --- reports ----------------------------------------------------------------------
actual=$(lint good)
status=$?
check "good draft: no empty labels, flags or force_result lines, exit 0" "0 $(
	cat <<'EOF'
bugrefs: 1
  "boo#1000001" -> "https://bugzilla.opensuse.org/show_bug.cgi?id=1000001" (product bug)
counts as reviewed: yes (bugref)
will carry over: yes (bugref) - the WHOLE text is copied onto the next job of the scenario that fails in the same modules
warnings: 0
EOF
)" "$status $actual"

actual=$(lint near-miss)
check "near misses: exit 1" 1 $?
contains "near misses: nothing is parsed" "bugrefs: 0" "$actual"
contains "near misses: not reviewed" "counts as reviewed: no" "$actual"
contains "ref in parentheses" 'W near-miss-bugref line 1: "bsc#1234567" is NOT a bugref (preceded by "(")' "$actual"
contains "ref glued to a quote" "W near-miss-bugref line 1: \"poo#424242\" is NOT a bugref (followed by \"'\")" "$actual"
contains "upper-case marker" 'W unknown-tracker line 1: "BSC#7654321": markers are lower case, write "bsc#7654321"' "$actual"
contains "unknown tracker prefix" 'W unknown-tracker line 1: "bug#123456": unknown tracker prefix, openQA knows: bnc bsc boo' "$actual"
contains "missing hash" 'W near-miss-bugref line 1: "bsc 1234567" is NOT a bugref, write "bsc#1234567"' "$actual"
check "near misses: five warnings" "warnings: 5" "$(grep '^warnings:' <<<"$actual")"

actual=$(lint accidental)
check "accidental bugref: exit 1" 1 $?
contains "accidental bugref is reported the way openQA stores it" '"bootloader_uefi#1" -> "https://bugzilla.opensuse.org/show_bug.cgi?id=tloader_uefi/issues/1" (product bug)' "$actual"
contains "accidental bugref warning" 'W accidental-bugref line 1: "bootloader_uefi#1" is parsed as a boo reference' "$actual"
check "a module name in backticks is left alone" 0 "$(grep -c ghostscript <<<"$actual")"

actual=$(lint force-good)
check "force_result with a separate bugref: exit 0" 0 $?
contains "force_result valid" 'force_result: result "softfailed" is valid; description seen by openQA: "bsc"; needs the operator role; the job must be done or cancelled' "$actual"
contains "description capture pitfall" 'N force_result description: only "bsc" is captured (\w* stops at "#")' "$actual"
contains "carries over through the separate bugref" "will carry over: yes (bugref)" "$actual"

actual=$(lint force-bad)
check "invalid force_result: exit 1" 1 $?
contains "invalid result name" 'force_result: INVALID result "soft"' "$actual"
contains "invalid result: server answer" "HTTP 400 \"Invalid result 'soft' for force_result\"" "$actual"
contains "force_result without label: prefix" "W force-result-invalid line 2: force_result without the label: prefix is plain text" "$actual"
contains "force_result alone is not carried over" "will carry over: no (labels alone are never carried over" "$actual"

actual=$(lint label-only)
check "label with a bugref inside: exit 1" 1 $?
contains "label counts as reviewed" "counts as reviewed: yes (label)" "$actual"
contains "label containing a bugref" 'W label-bugref line 1: "label:poo#424242" is a label, not a bugref: no bug icon and NO carry-over; write "poo#424242" on its own' "$actual"

# A label is [\w:#/-]+ and Python's \w covers the Hangul fillers, which are invisible.
actual=$(lint label-invisible)
check "invisible label: reported" 1 "$(grep -c 'W label-bugref' <<<"$actual")"
check "invisible label: the hint is sanitised like every other quote" 0 \
	"$(LC_ALL=C grep -cP '\xe3\x85\xa4|\xe1\x85\x9f|\xe1\x85\xa0|\xef\xbe\xa0' <<<"$actual")"
check "invisible label: report stays plain ASCII" 0 "$(LC_ALL=C grep -cP '[^\x09\x0a\x20-\x7e]' <<<"$actual")"

actual=$(lint labels)
contains "only the first label counts" '"second" (ignored as a label, only the first one counts)' "$actual"
contains "label cut at an illegal character" 'W label-cut line 2: the label ends before "."' "$actual"
contains "capitalised label with a space" 'W near-miss-label line 1: "Label: sporadic" is not parsed' "$actual"
contains "unknown flag" 'W unknown-flag line 2: "flag:carry" has no effect, the only flag is flag:carryover' "$actual"

actual=$(lint flag)
check "flag:carryover: exit 0" 0 $?
contains "flag:carryover carries over without being reviewed" "counts as reviewed: no" "$actual"
contains "flag:carryover verdict" "will carry over: yes (flag:carryover)" "$actual"

actual=$(lint plain)
check "plain comment: exit 0" 0 $?
contains "plain comment verdicts" "will carry over: no (no bugref and no flag:carryover)" "$actual"

actual=$(lint urls --private-suffix devel.example)
check "urls: exit 1" 1 $?
contains "tracker URL is rewritten like on save" "on save openQA rewrites 1 tracker URL(s) into short refs" "$actual"
check "one URL per line: nothing is mangled" 0 "$(grep -c 'W url-rewrite' <<<"$actual")"
contains "two URLs on one line are merged by the rewrite" "W url-rewrite line 1: on save openQA's URL rewriting mangles" \
	"$(python3 "$src" --text 'https://bugzilla.opensuse.org/show_bug.cgi?id=123 see https://github.com/o/r/issues/5')"
contains "rewritten URL counts as a test issue" '"poo#424242" -> "https://progress.opensuse.org/issues/424242" (test issue)' "$actual"
contains "tracker URL in parentheses stays a link" 'W tracker-url line 1: "https://bugzilla.opensuse.org/show_bug.cgi?id=1000001" stays a plain link' "$actual"
contains "private suffix" 'W private-url line 2: "http://tracker.corp/ticket/5"' "$actual"
contains "private address" 'W private-url line 2: "https://192.168.1.10/x"' "$actual"
contains "--private-suffix" 'W private-url line 2: "https://gitlab.devel.example/x"' "$actual"
check "without --private-suffix that host passes" 0 "$(lint urls | grep -c 'devel.example')"

actual=$(lint pasted-log)
check "pasted log: exit 1" 1 $?
contains "pasted log warning" "W pasted-log: 5 lines look like log output" "$actual"

actual=$(lint long)
check "long draft: exit 1" 1 $?
contains "long draft warning" "W too-long: 21 lines, 1491 chars (limits 15/1000)" "$actual"

# --- placeholder refs ----------------------------------------------------------------
for draft in 'epiphany: poo#<id> crashes' 'see <poo#id or boo#id>' 'bsc#N' 'boo#TBD' 'poo#?' 'poo#XXXX later'; do
	actual=$(python3 "$src" --text "$draft")
	check "placeholder '$draft': exit 1" 1 $?
	contains "placeholder '$draft': unreviewed, with the reason" "W placeholder-bugref line 1: " "$actual"
	contains "placeholder '$draft': not counted as a bugref" "counts as reviewed: no" "$actual"
done
actual=$(lint placeholder)
check "placeholders: one warning each, explained once; real refs with repo or Jira id are not flagged" \
	'  W placeholder-bugref line 1: "poo#<id>" is a placeholder: not parsed, on its own the job stays unreviewed and nothing carries over; find or file the ticket first and write its number
  W placeholder-bugref line 2: "poo#id"
  W placeholder-bugref line 2: "boo#id"
  W placeholder-bugref line 2: "bsc#N"
  W placeholder-bugref line 2: "boo#TBD"
  W placeholder-bugref line 2: "gh#os-autoinst/os-autoinst#<n>"' "$(grep placeholder-bugref <<<"$actual")"
contains "placeholders: the real refs still count" "bugrefs: 3" "$actual"
actual=$(python3 "$src" --text 'shampoo#x and zoo#keeper, boo#1000001 is real')
check "placeholder: a marker inside a word is not one" "0 0" "$? $(grep -c placeholder-bugref <<<"$actual")"
actual=$(lint placeholder-hostile)
check "hostile placeholder: reported" 2 "$(grep -c 'W placeholder-bugref' <<<"$actual")"
check "hostile placeholder: nothing echoed raw" 0 "$(LC_ALL=C grep -cP '\x1b|\xe2\x80\xae|<<<END' <<<"$actual")"

actual=$(lint hostile)
check "hostile draft: exit 1" 1 $?
contains "control characters are reported" "W control-chars:" "$actual"
check "control: the fixture does contain an escape" 1 "$(LC_ALL=C grep -cP '\x1b' "$fixtures/hostile.txt")"
check "nothing of the draft is echoed raw" 0 "$(LC_ALL=C grep -cP '\x1b|\xe2\x80\x8b|<<<END' <<<"$actual")"

# --- hostile size and shape: pasted third-party text must not stall or flood the lint ------
work=$(mktemp -d)
python3 - "$work" <<'PY'
import sys
line = lambda unit: (unit * 1000)[:1000]
drafts = {
    "markers": "\n".join([line("gh")] * 64),
    "split": "\n".join([line("gh" + " " * 400)] * 64),
    "roots": "\n".join([line("https://github.com/ ")] * 64),
    "refs": "\n".join([line("(bsc#1 Ab#123 bsc 123 poo#? label:boo#1 flag:x force_result http://a/ ")] * 64),
    "word": "boo#1000001 " + "gh" * 501,
}
for name, text in drafts.items():
    open(f"{sys.argv[1]}/{name}.txt", "w").write(text)
open(f"{sys.argv[1]}/bytes.txt", "wb").write(b"boo#1000001 caf\xe9 \xff\xfe\n")
PY
for name in markers split roots refs; do
	actual=$(timeout 20 python3 "$src" "$work/$name.txt" 2>&1)
	check "64 kB of '$name': done in time, exit 1, short report" "1 1" \
		"$? $([ "$(wc -c <<<"$actual")" -le 20000 ] && echo 1)"
done
contains "long lists are cut, the count stays exact" "  ... " "$actual"
actual=$(timeout 20 python3 "$src" "$work/word.txt" 2>&1)
check "a line over the cap is refused" "2 error: draft has a line longer than 1000 characters" "$? $actual"
actual=$(python3 "$src" <"$work/bytes.txt" 2>&1)
check "stdin that is not UTF-8: linted, no traceback" "0 1 0" \
	"$? $(grep -c '^bugrefs: 1' <<<"$actual") $(grep -c Traceback <<<"$actual")"
check "FILE that is not UTF-8: same" "$actual" "$(python3 "$src" "$work/bytes.txt" 2>&1)"
mkfifo "$work/fifo"
ln -s /dev/zero "$work/zero.txt"
for name in fifo zero.txt; do
	actual=$(timeout 10 python3 "$src" "$work/$name" 2>&1)
	check "FILE $name: refused at once" "2 1" "$? $(grep -c 'not a regular file' <<<"$actual")"
done

# --- hostile FILE argument ----------------------------------------------------------------
mkdir "$work/dir"
actual=$(timeout 10 python3 "$src" "$work/dir" 2>&1)
check "FILE that is a directory: refused" "2 1" "$? $(grep -c 'not a regular file' <<<"$actual")"
ln -s "$work/dir" "$work/dirlink"
actual=$(timeout 10 python3 "$src" "$work/dirlink" 2>&1)
check "FILE that links to a directory: refused" "2 1" "$? $(grep -c 'not a regular file' <<<"$actual")"
ln -s ../../nowhere/at/all "$work/broken.txt"
actual=$(timeout 10 python3 "$src" "$work/broken.txt" 2>&1)
check "FILE that is a broken link: refused, path quoted" "2 1" \
	"$? $(grep -c '^error: "[^"]*broken.txt": No such file' <<<"$actual")"
# 300 invisible characters inside a URL password: a cut before redaction showed its start.
padded=$(python3 -c 'print("https://user:" + "\u200b" * 300 + "DummyPassw0rdXYZ@host.example.org/x", end="")')
actual=$(timeout 10 python3 "$src" "$padded" 2>&1)
check "a missing FILE holding a padded URL password: redacted, not cut open" "2 0 1" \
	"$? $(grep -c DummyPa <<<"$actual") $(grep -c 'REDACTED:url-userinfo' <<<"$actual")"
ln -s loop-b "$work/loop-a"
ln -s loop-a "$work/loop-b"
actual=$(timeout 10 python3 "$src" "$work/loop-a" 2>&1)
check "FILE that is a link loop: refused, no traceback" "2 0" "$? $(grep -c Traceback <<<"$actual")"
# A chain of links to a real file outside the directory is still just a file the caller named.
printf 'bsc#1234567 fine\n' >"$work/target.txt"
ln -s target.txt "$work/chain-1"
ln -s "$work/chain-1" "$work/chain-2"
check "FILE reached through a link chain: linted like the target" \
	"$(python3 "$src" "$work/target.txt")" "$(timeout 10 python3 "$src" "$work/chain-2")"
# 400 MB: the read must stop at the cap instead of loading the file.
python3 -c 'import sys; f = open(sys.argv[1], "wb"); f.truncate(400 * 1024 * 1024)' "$work/huge.txt"
actual=$(timeout 20 python3 "$src" "$work/huge.txt" 2>&1)
check "FILE of 400 MB: refused by the cap, not read" "2 error: draft longer than 65536 characters" "$? $actual"
rm -f "$work/huge.txt"
printf 'bsc#1234567 fine\n' >"$work/-dash.txt"
actual=$(timeout 10 python3 "$src" "$work/-dash.txt" 2>&1)
check "FILE whose basename starts with '-': read as a path, not an option" 0 "$?"
actual=$(cd "$work" && timeout 10 python3 "$src" -dash.txt 2>&1)
check "a bare '-dash.txt' stays an argparse usage error" "2 1" "$? $(grep -c 'unrecognized arguments' <<<"$actual")"

# --- the URL rewrite is quadratic in the line length; the line cap is what bounds it -------
python3 - "$work" <<'PY'
import sys
unit = "https://github.com/1/"
open(f"{sys.argv[1]}/href-long.txt", "w").write((unit * 10000)[:200000])
open(f"{sys.argv[1]}/href-worst.txt", "w").write("\n".join([(unit * 60)[:1000]] * 65))
PY
actual=$(timeout 30 python3 "$src" "$work/href-long.txt" 2>&1)
check "200 kB of tracker roots on one line: refused before any rewriting" \
	"2 error: draft longer than 65536 characters" "$? $actual"
start=$SECONDS
timeout 60 python3 "$src" "$work/href-worst.txt" >/dev/null 2>&1
check "the worst draft the caps allow still finishes at once" "fast" \
	"$([ $((SECONDS - start)) -le 10 ] && echo fast || echo "slow: $((SECONDS - start))s")"
rm -rf "$work"

exit $fail
