#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests for scripts/check-schedule.py against a miniature distri checkout, in both parser modes.

here=$(cd "$(dirname "$0")" && pwd)
scripts="$here/../../skills/openqa/scripts"
repo="$here/fixtures/check-schedule/repo"
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

lint() {
	python3 "$scripts/check-schedule.py" "$@"
}

modes=(fallback)
if python3 -c 'import yaml' 2>/dev/null; then
	modes+=(yaml)
else
	echo "ok - yaml mode # skip PyYAML is not importable"
fi

# Errors come first, each class in file order.
bad="schedule/bad.yaml:3: schema: unknown top-level key 'machine' (allowed: name, description, schedule, vars, test_data, conditional_schedule)
schedule/bad.yaml:8: schema: vars key 'lower_case' must match [A-Z_+]+[A-Z0-9_]*
schedule/bad.yaml:12: module: 'tests/console/sshd' starts with tests/; entries are relative to tests/
schedule/bad.yaml:14: module: tests/console/missing.pm does not exist
schedule/bad.yaml:21: module: tests/x11/game.pm does not exist
schedule/bad.yaml:23: format: trailing blank line
schedule/bad.yaml:2: convention: name 'something_else' differs from the file basename 'bad'
schedule/bad.yaml:5: placement: HDD_1 under vars: belongs in the job settings (declarative-schedule-doc.md forbids it there)
schedule/bad.yaml:6: placement: WORKER_CLASS under vars: belongs in the job settings (openQA reads it before vars: are applied)
schedule/bad.yaml:7: placement: PUBLISH_HDD_2 under vars: belongs in the job settings (openQA reads it before vars: are applied)
schedule/bad.yaml:13: convention: 'console/sshd.pm' ends in .pm; drop the extension
schedule/bad.yaml:15: conditional: {{nope}} has no entry in conditional_schedule; it schedules nothing"

for label in "${modes[@]}"; do
	opts=(--repo "$repo" --all-conventions)
	[ "$label" == fallback ] && opts+=(--fallback)

	actual=$(lint "${opts[@]}" schedule/good.yaml)
	check "$label: clean schedule exits 0" 0 $?
	check "$label: clean schedule with .py module, !include and +undefined branch" "summary: 1 file(s), 0 error(s), 0 warning(s) mode=$label" "$actual"

	actual=$(lint "${opts[@]}" schedule/bad.yaml)
	check "$label: errors exit 1" 1 $?
	check "$label: every class is reported with its line" "$bad
summary: 1 file(s), 6 error(s), 6 warning(s) [schema=2 module=3 format=1 conditional=1 placement=3 convention=2] mode=$label" "$actual"

	actual=$(lint "${opts[@]}" --errors-only schedule/bad.yaml | grep -c -E ': (placement|convention|conditional): ')
	check "$label: --errors-only hides warnings" 0 "$actual"

	actual=$(lint "${opts[@]}" schedule/noname.yaml)
	check "$label: missing name and missing final newline" "schedule/noname.yaml:1: schema: required key 'name' is missing
schedule/noname.yaml:4: format: no newline at end of file
summary: 1 file(s), 2 error(s), 0 warning(s) [schema=1 format=1] mode=$label" "$actual"

	actual=$(lint "${opts[@]}" schedule/steps.yaml schedule/flows/default.yaml)
	check "$label: keyed schedule and flow file get their modules checked, flow skips the schema" "schedule/steps.yaml:8: module: tests/installation/gone.pm does not exist
schedule/flows/default.yaml:8: module: tests/installation/removed.pm does not exist
summary: 2 file(s), 2 error(s), 0 warning(s) [module=2] mode=$label" "$actual"

	actual=$(lint "${opts[@]}" --module console/sshd)
	check "$label: --module with references exits 0" 0 $?
	check "$label: --module lists file, line and section" "module: console/sshd (tests/console/sshd.pm present)
schedule/bad.yaml:13: schedule
schedule/good.yaml:11: schedule
schedule/noname.yaml:4: schedule
summary: 3 reference(s) mode=$label" "$actual"

	actual=$(lint "${opts[@]}" --module tests/installation/first_boot.pm)
	check "$label: --module accepts tests/ and .pm, finds branches and flows" "module: installation/first_boot (tests/installation/first_boot.pm present)
schedule/good.yaml:17: conditional_schedule
schedule/flows/default.yaml:7: flow
summary: 2 reference(s) mode=$label" "$actual"

	actual=$(lint "${opts[@]}" --module x11/game.py)
	check "$label: --module with a .py module" "module: x11/game.py (tests/x11/game.py present)
schedule/good.yaml:12: schedule
summary: 1 reference(s) mode=$label" "$actual"

	actual=$(lint "${opts[@]}" --module console/nowhere)
	check "$label: --module without references exits 1" 1 $?
	check "$label: --module reports a missing module file" "module: console/nowhere (tests/console/nowhere.pm missing)
summary: 0 reference(s) mode=$label" "$actual"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tests/console" "$work/schedule"
touch "$work/tests/console/sshd.pm"
printf 'name: other\nvars:\n  DESKTOP: gnome\nschedule:\n  - console/sshd\n' >"$work/schedule/warn.yaml"
printf 'name: "evil\\e[31m\\u202e"\nschedule:\n  - console/sshd\n' >"$work/schedule/evil.yaml"

actual=$(lint --repo "$repo" --fallback --all-conventions --max-findings 2 schedule/bad.yaml)
check "--max-findings caps the list, errors first, the summary still counts everything" "schedule/bad.yaml:3: schema: unknown top-level key 'machine' (allowed: name, description, schedule, vars, test_data, conditional_schedule)
schedule/bad.yaml:8: schema: vars key 'lower_case' must match [A-Z_+]+[A-Z0-9_]*
[... 10 more not shown, raise --max-findings]
summary: 1 file(s), 6 error(s), 6 warning(s) [schema=2 module=3 format=1 conditional=1 placement=3 convention=2] mode=fallback" "$actual"
actual=$(lint --repo "$repo" --fallback --max-findings 1 --module console/sshd)
check "--max-findings also caps --module references" "module: console/sshd (tests/console/sshd.pm present)
schedule/bad.yaml:13: schedule
[... 2 more not shown, raise --max-findings]
summary: 3 reference(s) mode=fallback" "$actual"

actual=$(cd "$work" && lint --fallback --all-conventions)
check "warnings only exit 0" 0 $?
check "no files: every schedule below the current directory" "schedule/evil.yaml:1: convention: name 'evil\\e[31m\\u202e' differs from the file basename 'evil'
schedule/warn.yaml:1: convention: name 'other' differs from the file basename 'warn'
schedule/warn.yaml:3: placement: DESKTOP under vars: belongs in the job settings (declarative-schedule-doc.md forbids it there)
summary: 2 file(s), 0 error(s), 3 warning(s) [placement=1 convention=2] mode=fallback" "$actual"
lint --fallback --strict --repo "$work" >/dev/null
check "--strict turns warnings into exit 1" 1 $?

# --- name convention: only for files that are new in git ---------------------------
actual=$(GIT_DIR="$work/no-such-git-dir" lint --repo "$work" --fallback schedule/warn.yaml | grep -c ': convention: name ')
check "git cannot tell: the name convention is reported" 1 "$actual"
if command -v git >/dev/null; then
	gitrepo="$work/checkout"
	mkdir -p "$gitrepo/tests/console" "$gitrepo/schedule/sub"
	touch "$gitrepo/tests/console/sshd.pm"
	for name in tracked edited staged sub/untracked; do
		printf 'name: other\nschedule:\n  - console/sshd.pm\n' >"$gitrepo/schedule/$name.yaml"
	done
	printf 'name: other\nschedule:\n  - console/sshd\n' >"$gitrepo/schedule/evil
INJECTED=1.yaml"
	(
		cd "$gitrepo" && git init -q . && git add tests schedule/tracked.yaml schedule/edited.yaml &&
			git -c user.name=t -c user.email=t@example.com commit -q -m fixtures &&
			git add schedule/staged.yaml && echo '  - console/sshd' >>schedule/edited.yaml
	) >/dev/null 2>&1
	actual=$(lint --repo "$gitrepo" --fallback | grep ': convention: name ')
	check "git checkout: name convention only for untracked and added files" "schedule/evil INJECTED=1.yaml:1: convention: name 'other' differs from the file basename 'evil INJECTED=1'
schedule/staged.yaml:1: convention: name 'other' differs from the file basename 'staged'
schedule/sub/untracked.yaml:1: convention: name 'other' differs from the file basename 'untracked'" "$actual"
	check "git checkout: the other conventions still apply to tracked files" 1 \
		"$(lint --repo "$gitrepo" --fallback schedule/tracked.yaml | grep -c "ends in .pm")"
	check "git checkout: an edited tracked file given by name stays quiet" 0 \
		"$(cd "$gitrepo" && lint --fallback schedule/edited.yaml | grep -c ': convention: name ')"
	check "git checkout: --all-conventions reports tracked files too" 5 \
		"$(lint --repo "$gitrepo" --fallback --all-conventions | grep -c ': convention: name ')"
	check "git checkout: the lint leaves the index alone" "A  schedule/staged.yaml" \
		"$(git -C "$gitrepo" status --porcelain | grep staged)"
	# hostile repo-local config: a clean filter and an fsmonitor hook that would leave a marker
	echo '*.yaml filter=evil' >"$gitrepo/.gitattributes"
	git -C "$gitrepo" config filter.evil.clean "touch '$work/ran-filter'; cat"
	git -C "$gitrepo" config core.fsmonitor "touch '$work/ran-fsmonitor'; false"
	touch "$gitrepo/schedule/tracked.yaml" "$gitrepo/schedule/edited.yaml"
	actual=$(lint --repo "$gitrepo" --fallback | grep -c ': convention: name ')
	check "git checkout: commands from the repository config never run" "3 0" \
		"$actual $(find "$work" -maxdepth 1 -name 'ran-*' | wc -l)"
	# hostile partial clone: the tree of HEAD is missing and the promisor remote's uploadpack is a command
	tree=$(git -C "$gitrepo" rev-parse 'HEAD^{tree}')
	rm -f "$gitrepo/.git/objects/${tree:0:2}/${tree:2}"
	git -C "$gitrepo" config core.repositoryformatversion 1
	git -C "$gitrepo" config extensions.partialClone origin
	git -C "$gitrepo" config remote.origin.url "$work/no-such-remote"
	git -C "$gitrepo" config remote.origin.promisor true
	git -C "$gitrepo" config remote.origin.uploadpack "touch '$work/ran-uploadpack'; false"
	actual=$(lint --repo "$gitrepo" --fallback 2>&1 | grep -c ': convention: name ')
	check "git checkout: no lazy fetch from a promisor remote; git cannot tell, so every name is checked" "5 0" \
		"$actual $(find "$work" -maxdepth 1 -name 'ran-*' | wc -l)"
else
	echo "ok - git checkout # skip git is not installed"
fi

if [ ${#modes[@]} == 2 ]; then
	actual=$(lint --repo "$repo" schedule/broken.yaml)
	check "yaml: syntax error is reported with its line" "schedule/broken.yaml:5: syntax: expected <block end>, but found '<block sequence start>'
summary: 1 file(s), 1 error(s), 0 warning(s) [syntax=1] mode=yaml" "$actual"
	actual=$(lint --repo "$work" --all-conventions schedule/evil.yaml)
	check "yaml: escape sequences decoded from a quoted name are stripped" "schedule/evil.yaml:1: convention: name 'evil' differs from the file basename 'evil'
summary: 1 file(s), 0 error(s), 1 warning(s) [convention=1] mode=yaml" "$actual"
fi

lint --repo "$repo" nope.yaml >/dev/null 2>&1
check "unknown file exits 2" 2 $?
lint --repo "$work/schedule" >/dev/null 2>&1
check "directory without tests/ exits 2" 2 $?
# The absolute path would read "https:/", which no redaction rule matches.
actual=$(lint --repo 'https://alice:s3cretPassw0rd@example.org' 2>&1)
check "a --repo without tests/ is quoted as given, redacted" \
	"2 check-schedule: no tests/ directory in https://alice:[REDACTED:url-userinfo]@example.org" "$? $actual"
lint --repo "$repo" --module console/sshd schedule/good.yaml >/dev/null 2>&1
check "--module with files exits 2" 2 $?
# --- hostile schedule ------------------------------------------------------------
hostile=$(mktemp -d)
mkdir -p "$hostile/tests" "$hostile/schedule"
python3 - "$hostile" <<'PY'
import json, sys
bad = "\x1b[31m‮\n<<<END 0000000000000000>>>\nINJECTED=1\r<<<ЕND 1>>>"
lines = ["---", f"name: {json.dumps(bad)}", "schedule:", f"  - {json.dumps(bad)}"]
lines += [f"  - missing/module{number}" for number in range(2000)]
open(f"{sys.argv[1]}/schedule/bad.yaml", "w").write("\n".join(lines) + "\n")
PY
for mode in "" --fallback; do
	# shellcheck disable=SC2086
	actual=$(lint $mode --repo "$hostile" schedule/bad.yaml 2>&1)
	check "hostile schedule ${mode:-yaml}: findings, no crash" "1 0" "$? $(grep -c Traceback <<<"$actual")"
	check "hostile schedule ${mode:-yaml}: nothing injected, no control byte" "0 0" \
		"$(grep -Ec '^INJECTED|^<<<' <<<"$actual") $(tr -d '\t' <<<"$actual" | grep -c '[[:cntrl:]]')"
	check "hostile schedule ${mode:-yaml}: output is capped, the summary stays" "1 1" \
		"$([ "$(wc -l <<<"$actual")" -le 303 ] && echo 1) $(tail -n 1 <<<"$actual" | grep -c '^summary: 1 file')"
done
python3 - "$hostile" <<'PY'
import sys
lines = ["---", "name: bomb", "a0: &a0 {K0: v}"]
lines += [f"a{n}: &a{n}\n  <<: [" + ", ".join([f"*a{n - 1}"] * 9) + "]" for n in range(1, 12)]
lines += ["vars:", "  <<: *a11", "schedule:", "  - console/x"]
open(f"{sys.argv[1]}/schedule/bomb.yaml", "w").write("\n".join(lines) + "\n")
open(f"{sys.argv[1]}/schedule/deep.yaml", "w").write("---\nname: deep\nschedule: " + "[" * 5000 + "]" * 5000 + "\n")
PY
for name in bomb deep; do
	actual=$(timeout 60 python3 "$scripts/check-schedule.py" --repo "$hostile" "schedule/$name.yaml" 2>&1)
	check "$name.yaml ends quickly with findings, not a hang or traceback" "1 0" "$? $(grep -c Traceback <<<"$actual")"
done
actual=$(lint --repo "$hostile" $'schedule/no\nINJECTED=1 \e[31m.yaml' 2>&1)
check "a missing file with a hostile name is reported on one clean line" "2 1 0" \
	"$? $(wc -l <<<"$actual" | tr -d ' ') $(grep -c '[[:cntrl:]]' <<<"$actual")"
rm -rf "$hostile"
# a branch can carry links: to a device that never ends, to a file outside the checkout
links=$(mktemp -d)
mkdir -p "$links/tests/console" "$links/schedule"
touch "$links/tests/console/sshd.pm"
printf 'name: real\nschedule:\n  - console/sshd\n' >"$links/schedule/real.yaml"
ln -s /dev/zero "$links/schedule/zero.yaml"
ln -s /etc/hostname "$links/schedule/outside.yaml"
ln -s real.yaml "$links/schedule/inside.yaml"
mkfifo "$links/schedule/fifo.yaml"
actual=$(timeout 60 python3 "$scripts/check-schedule.py" --repo "$links" --all-conventions 2>&1)
status=$?
check "device, FIFO and outside link are reported and not read; a link inside the checkout is" "1 $(
	cat <<'EOF2'
schedule/fifo.yaml:1: format: not a regular file of the checkout, not read
schedule/outside.yaml:1: format: not a regular file of the checkout, not read
schedule/zero.yaml:1: format: not a regular file of the checkout, not read
schedule/inside.yaml:1: convention: name 'real' differs from the file basename 'inside'
EOF2
)" "$status $(grep -v '^summary' <<<"$actual")"
actual=$(timeout 60 python3 "$scripts/check-schedule.py" --repo "$links" --module console/sshd 2>&1)
check "--module skips them too" "0 summary: 2 reference(s)" "$? $(tail -n 1 <<<"$actual" | cut -d' ' -f1-3)"
# A linked parent directory leads out of the checkout just as a linked file does.
ln -s /etc "$links/schedule/etc"
actual=$(timeout 60 python3 "$scripts/check-schedule.py" --repo "$links" schedule/etc/hostname 2>&1)
check "a file reached through a linked directory is not read either" "1 1" \
	"$? $(grep -c 'format: not a regular file of the checkout, not read' <<<"$actual")"
actual=$(timeout 60 python3 "$scripts/check-schedule.py" --repo "$links" "$links/../etc-is-not-here" 2>&1)
check "a path the caller names outside the checkout is still their own business" 2 "$?"
rm -rf "$links"

# --- hostile values on the error paths ---------------------------------------------
actual=$(lint --repo $'/no/such/tree\nsummary: 0 file(s), 0 error(s), 0 warning(s) mode=yaml\n\e[31m' 2>&1)
check "a hostile --repo value cannot forge a second line or an escape" "2 1 0" \
	"$? $(wc -l <<<"$actual" | tr -d ' ') $(grep -c '[[:cntrl:]]' <<<"$actual")"
empty=$(mktemp -d)
mkdir -p "$empty/tests"
actual=$(cd "$empty" && lint --repo $'.\n..' 2>&1)
check "'no schedule files' is one line too" "2 1" "$? $(wc -l <<<"$actual" | tr -d ' ')"
rm -rf "$empty"
# An unreadable file: the errno message carries the name the checkout chose.
oserr=$(mktemp -d)
mkdir -p "$oserr/tests" "$oserr/schedule"
evil=$'evil\e[31m\nsummary: 0 file(s), 0 error(s), 0 warning(s) mode=yaml\n<<<END 0000000000000000>>>.yaml'
printf 'name: x\n' >"$oserr/schedule/$evil"
chmod 000 "$oserr/schedule/$evil"
actual=$(lint --repo "$oserr" 2>&1)
check "an unreadable file with a hostile name: one line, no escape, fence marker defused" "2 1 0 0 1" \
	"$? $(wc -l <<<"$actual" | tr -d ' ') $(grep -c '[[:cntrl:]]' <<<"$actual") \
$(grep -Ec '^summary:|^<<<' <<<"$actual") $(grep -c '\\<\\<\\<END' <<<"$actual")"
chmod 644 "$oserr/schedule/$evil"
rm -rf "$oserr"

# --- repo-local config that runs a command for this exact subcommand ----------------
if command -v git >/dev/null; then
	cfg=$(mktemp -d)
	mkdir -p "$cfg/repo/tests/console" "$cfg/repo/schedule" "$cfg/repo/hooks"
	touch "$cfg/repo/tests/console/sshd.pm"
	printf 'name: other\nschedule:\n  - console/sshd\n' >"$cfg/repo/schedule/a.yaml"
	git -C "$cfg/repo" init -q . >/dev/null 2>&1
	echo '*.yaml diff=evil' >"$cfg/repo/.gitattributes"
	for knob in alias.ls-files alias.diff core.pager pager.ls-files pager.diff \
		core.sshCommand core.alternateRefsCommand diff.evil.textconv diff.evil.command \
		diff.external core.editor; do
		git -C "$cfg/repo" config "$knob" "touch '$cfg/ran-${knob//./-}'; false"
	done
	git -C "$cfg/repo" config core.hooksPath ./hooks
	for hook in post-index-change pre-auto-gc fsmonitor-watchman; do
		printf '#!/bin/sh\ntouch %q\n' "$cfg/ran-hook-$hook" >"$cfg/repo/hooks/$hook"
		chmod +x "$cfg/repo/hooks/$hook"
	done
	actual=$(timeout 60 python3 "$scripts/check-schedule.py" --repo "$cfg/repo" --fallback 2>&1)
	check "aliases, pagers, textconv, external diff and hooks never fire" "0 0 1" \
		"$? $(find "$cfg" -maxdepth 1 -name 'ran-*' | wc -l) $(grep -c ': convention: name ' <<<"$actual")"
	rm -rf "$cfg"
else
	echo "ok - repo-local config # skip git is not installed"
fi

# An unreadable schedule file is reported by its sanitised path: str(OSError) would quote a
# file name split by an invisible character with repr(), out of redaction's reach.
split=$(mktemp -d)
cp -r "$repo/." "$split/"
locked="$split/schedule/ghp_"$'\xe2\x80\x8b'"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.yaml"
printf 'name: x\n' >"$locked"
chmod 000 "$locked"
actual=$(lint --repo "$split" --fallback 2>&1)
check "an unreadable file with a split token: exit 2, token not echoed" "2 0" "$? $(grep -c AAAAAAAAAAAA <<<"$actual")"
rm -rf "$split"

# A file outside --repo is shown as typed: its abspath() form reads "https:/", which no
# redaction rule matches, so a password in a URL-shaped path would print in full.
outside=$(mktemp -d)
mkdir -p "$outside/https:/alice:s3cretPassw0rd@example.org" "$outside/repo/tests" "$outside/norepo/https:/alice:s3cretPassw0rd@example.org/tests"
cp -r "$repo/." "$outside/repo/"
printf 'schedule: []\n' >"$outside/https:/alice:s3cretPassw0rd@example.org/y.yaml"
actual=$(cd "$outside" && python3 "$scripts/check-schedule.py" --repo repo --all-conventions --fallback 'https://alice:s3cretPassw0rd@example.org/y.yaml' 2>&1)
check "a finding in a file outside the repo does not show a URL password" 0 "$(grep -c s3cretPassw0rd <<<"$actual")"
chmod 000 "$outside/https:/alice:s3cretPassw0rd@example.org/y.yaml"
actual=$(cd "$outside" && python3 "$scripts/check-schedule.py" --repo repo --all-conventions --fallback 'https://alice:s3cretPassw0rd@example.org/y.yaml' 2>&1)
check "an unreadable file outside the repo: exit 2, no URL password" "2 0" "$? $(grep -c s3cretPassw0rd <<<"$actual")"
actual=$(cd "$outside/norepo" && python3 "$scripts/check-schedule.py" --repo 'https://alice:s3cretPassw0rd@example.org' --fallback 2>&1)
check "no schedule files: exit 2, no URL password" "2 0" "$? $(grep -c s3cretPassw0rd <<<"$actual")"
rm -rf "$outside"

lint --help >/dev/null
check "--help exits 0" 0 $?

exit $fail
