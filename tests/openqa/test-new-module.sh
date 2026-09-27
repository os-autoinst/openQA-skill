#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests for scripts/new-module.py: skeletons per kind, header gates, refusal to overwrite, next-step output.

here=$(cd "$(dirname "$0")" && pwd)
scripts="$here/../../skills/openqa/scripts"
fixtures="$here/fixtures/new-module"
fail=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/tests/console" "$work/empty"
cd "$work/repo" || exit 2

check() {
	if [ "$2" == "$3" ]; then
		echo "ok - $1"
	else
		echo "not ok - $1"
		printf '  expected: %q\n  actual:   %q\n' "$2" "$3"
		fail=1
	fi
}

new() {
	python3 "$scripts/new-module.py" "$@"
}

common=(--summary 'Check that my-tool starts' --maintainer 'QE Team <qe-team@example.com>')

for kind in console service x11 container transactional yam-validate python; do
	ext=pm
	[ "$kind" == python ] && ext=py
	actual=$(new --stdout --kind "$kind" --path "tests/demo/my_tool.$ext" "${common[@]}" --package 'my-tool my-tool-data')
	check "$kind: --stdout exits 0" 0 $?
	check "$kind: skeleton matches the reviewed fixture" "$(cat "$fixtures/$kind.$ext")" "$actual"
	# The three greps of tools/check_metadata in the distri.
	grep -q '# Summary: .\+' <<<"$actual" &&
		grep -E -q '# Maintainer: .+(@| at ).+' <<<"$actual" &&
		grep -q '# Copyright .\+' <<<"$actual"
	check "$kind: header passes the check_metadata greps" 0 $?
done
check "--stdout writes nothing" "" "$(find tests -type f)"

actual=$(new --stdout --kind console --path tests/demo/my_tool.pm "${common[@]}")
check "console without --package drops '# Package:' and the install step" \
	"$(cat "$fixtures/console-nopackage.pm")" "$actual"

python3 "$scripts/check-module.py" "$fixtures"/*.pm "$fixtures"/*.py
check "every skeleton is clean for check-module.py" 0 $?

actual=$(new --kind console --path tests/console/my_tool.pm "${common[@]}" --package my-tool)
check "writing exits 0" 0 $?
check "written file equals --stdout" \
	"$(new --stdout --kind console --path tests/console/my_tool.pm "${common[@]}" --package my-tool)" \
	"$(cat tests/console/my_tool.pm)"
check "output: schedule line and next checks" "wrote tests/console/my_tool.pm (kind console, after tests/console/man_pages.pm)
schedule: - console/my_tool
next:
  replace the placeholder commands in run with the real checks
  $(realpath "$scripts")/check-module.py tests/console/my_tool.pm
  tools/tidy tests/console/my_tool.pm
  tools/check_metadata tests/console/my_tool.pm
  perl tools/check_os_autoinst_compile tests/console/my_tool.pm
  make test-yaml-valid test-unused-modules-changed   # after the schedule entry is committed
note: the year-less 'Copyright SUSE LLC' line is intended (CONTRIBUTING.md); do not copy a sibling's year
note: 'make test-compile-changed' and 'make test-metadata-changed' skip new untracked files" "$actual"

before=$(cat tests/console/my_tool.pm)
actual=$(new --kind service --path tests/console/my_tool.pm "${common[@]}" --package my-tool 2>&1)
check "existing file exits 2" 2 $?
check "existing file is reported" "new-module.py: tests/console/my_tool.pm exists, not overwriting" "$actual"
check "existing file is untouched" "$before" "$(cat tests/console/my_tool.pm)"

actual=$(new --kind python --path tests/x11/my_tool.py "${common[@]}" | sed -n 2p)
check "python: schedule entry keeps .py" "schedule: - x11/my_tool.py" "$actual"

actual=$(new --kind container --path tests/containers/my_tool.pm "${common[@]}" | sed -n 2p)
check "container: schedule line is a loadtest with run_args" \
	"schedule: loadtest('containers/my_tool', run_args => \$run_args, name => \$run_args->{runtime} . '_my_tool'); in lib/main_containers.pm" \
	"$actual"

actual=$(new --kind yam-validate --path tests/yam/validate/my_tool.pm "${common[@]}" | grep -c -e 'basename also used by tests/' -e "add 'my_tool: {value: ...}'")
check "two same-named modules are warned about; yam-validate names the test_data key" 3 "$actual"

new --kind x11 --path tests/x11/gui_tool.pm "${common[@]}" --package gui-tool | grep -q "needle tagged 'gui-tool'"
check "x11: names the needle tag x11_start_program will assert" 0 $?

usage() {
	local title=$1
	shift
	new "$@" >/dev/null 2>&1
	check "$title exits 2" 2 $?
}
usage "maintainer without an address" --stdout --kind console --path tests/console/a.pm --summary S --maintainer 'QE Team'
usage "multi-line summary" --stdout --kind console --path tests/console/a.pm --summary $'a\nb' --maintainer 'a@b.c'
usage ".pm path for --kind python" --stdout --kind python --path tests/console/a.pm --summary S --maintainer 'a@b.c'
usage "path outside tests/" --stdout --kind console --path lib/a.pm --summary S --maintainer 'a@b.c'
usage "path with .." --stdout --kind console --path tests/../a.pm --summary S --maintainer 'a@b.c'
usage "module name that is no identifier" --stdout --kind console --path tests/console/my-tool.pm --summary S --maintainer 'a@b.c'
usage "service without --package" --stdout --kind service --path tests/console/a.pm --summary S --maintainer 'a@b.c'
usage "package list with shell characters" --stdout --kind console --path tests/console/a.pm --summary S --maintainer 'a@b.c' --package "vim'; reboot"
usage "unknown kind" --stdout --kind nope --path tests/console/a.pm --summary S --maintainer 'a@b.c'
usage "--repo without tests/" --repo "$work/empty" --kind console --path tests/console/a.pm --summary S --maintainer 'a@b.c'
check "failed runs wrote nothing" "" "$(find "$work/empty" -type f)"

usage "bidi override in the maintainer" --stdout --kind console --path tests/console/a.pm --summary S --maintainer $'a@b.c \u202e'
usage "escape sequence in the summary" --stdout --kind console --path tests/console/a.pm --summary $'S\e[31m' --maintainer 'a@b.c'

# --- writes stay inside the checkout ------------------------------------------------
mkdir -p "$work/outside" "$work/linked"
ln -s "$work/outside" "$work/repo/tests/escape"
ln -s "$work/outside/dangling.pm" "$work/repo/tests/console/dangling.pm"
ln -s "$work/outside" "$work/linked/tests"
usage "directory symlink out of the checkout" --kind console --path tests/escape/a.pm --summary S --maintainer 'a@b.c'
usage "dangling file symlink out of the checkout" --kind console --path tests/console/dangling.pm --summary S --maintainer 'a@b.c'
usage "tests/ itself is a symlink out of the checkout" --repo "$work/linked" --kind console --path tests/console/a.pm --summary S --maintainer 'a@b.c'
usage "absolute path" --kind console --path /tests/console/a.pm --summary S --maintainer 'a@b.c'
check "nothing was written through a symlink" "" "$(find "$work/outside" -mindepth 1)"

# --- a credential in an argument ------------------------------------------------------
actual=$(new --stdout --kind console --path tests/console/a.pm --summary 'see https://alice:s3cretPassw0rd@example.org' --maintainer 'a@b.c' 2>&1)
check "a credential in the summary is named as one" "2 new-module.py: --summary: contains a credential (url-userinfo)" "$? $actual"
actual=$(new --stdout --kind console --path tests/console/a.pm --summary $'S\e[31m' --maintainer 'a@b.c' 2>&1)
check "an escape sequence is still reported as a control character" \
	"new-module.py: --summary and --maintainer must not contain control or invisible characters" "$actual"
cred=https://alice:s3cretPassw0rd@example.org
mkdir -p "$work/https:/alice:s3cretPassw0rd@example.org" "$work/https:/bob:s3cretPassw0rd@example.org/tests"
ln -s "$work/outside" "$work/https:/alice:s3cretPassw0rd@example.org/tests"
touch "$work/https:/bob:s3cretPassw0rd@example.org/tests/afile"
actual=$(new --repo "$cred" --kind console --path tests/console/a.pm --summary S --maintainer 'a@b.c' 2>&1)
check "a --repo without tests/ is not echoed raw" "2 0" "$? $(grep -c s3cretPassw0rd <<<"$actual")"
actual=$(new --repo "$work/$cred" --kind console --path tests/console/a.pm --summary S --maintainer 'a@b.c' 2>&1)
check "a --repo whose tests/ leaves it is not echoed raw" "2 0" "$? $(grep -c s3cretPassw0rd <<<"$actual")"
actual=$(new --repo "$work/${cred/alice/bob}" --kind console --path tests/afile/sub/a.pm --summary S --maintainer 'a@b.c' 2>&1)
check "a write error names --path, not the resolved path" "2 new-module.py: tests/afile/sub/a.pm: Not a directory" "$? $actual"
check "nothing was written for a --repo with a credential" "" "$(find "$work/outside" -mindepth 1)"

new --help >/dev/null
check "--help exits 0" 0 $?

exit $fail
