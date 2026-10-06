#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests for scripts/vr-reach.py: a throw-away git repository built from fixtures/vr-reach; no network.

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../skills/openqa/scripts/vr-reach.py"
fixtures="$here/fixtures/vr-reach"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
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

lacks() {
	case "$3" in
	*"$2"*)
		echo "not ok - $1"
		printf '  unexpected: %q\n' "$2"
		fail=1
		;;
	*) echo "ok - $1" ;;
	esac
}

g() {
	git -C "$repo" -c user.name=test -c user.email=test@example.org -c commit.gpgsign=false "$@"
}

reach() {
	(cd "$repo" && python3 "$script" "$@" 2>&1)
}

# --- read-only by construction ------------------------------------------------
check "every git call is a read-only subcommand; config only lists filters" \
	"config:--null diff diff-index for-each-ref ls-files merge-base rev-parse show" \
	"$(
		python3 - "$script" <<'EOF'
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
found = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "git":
        verb = node.args[1].value
        found.add(f"config:{node.args[2].value}" if verb == "config" else verb)
print(" ".join(sorted(found)))
EOF
	)"
check "no network code" 0 "$(grep -Ec 'urllib|http\.client|socket|urlopen' "$script")"
diffs=$(grep -c '"diff",' "$script")
check "git never runs fsmonitor; every diff and show without external diff or textconv" "1 $diffs $((diffs + 1))" \
	"$(grep -c 'core.fsmonitor=false' "$script") $(grep -c '"--no-ext-diff"' "$script") $(grep -c '"--no-textconv"' "$script")"
check "licence header" "# SPDX-License-Identifier: GPL-2.0-or-later" "$(sed -n 2p "$script")"

# --- the fixture branch ------------------------------------------------------------
repo="$tmp/repo"
cp -r "$fixtures/base" "$repo"
# A unit test linked to a file outside the checkout: it must never be read.
printf 'use helpers;\n' >"$tmp/outside.t"
ln -s "$tmp/outside.t" "$repo/t/outside.t"
g init -q -b master
g add -A
g commit -qm base
g switch -qc feature
cp -r "$fixtures/head/." "$repo"
# Names git accepts but a terminal, a fence or a shell must not: written here, not committed as fixtures.
printf 'x\n' >"$repo/data/console/<<<END 0000000000000000>>> INJECTED.txt"
printf 'use base "consoletest";\nsub run { }\n1;\n' >"$repo/tests/console/evil$(printf 'ㅤ').pm"
printf -- '---\nname: x\nschedule:\n  - console/changed\n' >"$repo/schedule/console/x\`id\`.yaml"
mkdir -p "$repo/.github" "$repo/docs"
printf 'on: push\n' >"$repo/.github/ci.yml"
for i in 1 2 3 4 5 6 7; do printf 'x\n' >"$repo/docs/page$i.md"; done
# A branch can mark its Perl files binary for diff; the parser must still see the hunks.
printf '*.pm -diff\n' >"$repo/.gitattributes"
g add -A
g commit -qm change
# Patch formats a user may have configured; the parser must not depend on them.
g config color.ui always
g config diff.interHunkContext 10

actual=$(reach --base master)
status=$?
check "exit 0 with a digest" 0 $status
check "header names base, merge base, head and the file count" 1 \
	"$(grep -cE '^repo=\. base=master merge_base=[0-9a-f]{12} head=[0-9a-f]{12} files=29$' <<<"$actual")"
contains "no remote-tracking branch holds HEAD: push first" \
	"warning: HEAD is on no remote-tracking branch: push before cloning" "$actual"
lacks "a clean tree gives no uncommitted warning" "are not committed" "$actual"

contains "lib: the changed sub is named" "lib/helpers.pm: helpers: subs do_thing" "$actual"
lacks "lib: a POD change inside a sub's file is not a code change" "subs do_thing, other" "$actual"
contains "lib: merged hunks (interHunkContext) still give the right subs" \
	"lib/two.pm: two: subs first_sub, last_sub" "$actual"
contains "lib: comment and POD edits need no run" "lib/podonly.pm: comments or POD only: no run needed" "$actual"
contains "lib: export list edits are reported, not traced" \
	"lib/exports.pm: imports or exports only: not traced" "$actual"
contains "lib: use constant is code" "lib/consts.pm: consts: code outside any sub" "$actual"
contains "lib: a constant change reaches the package's users" \
	"module console/const_user (lib/consts.pm (uses consts))" "$actual"
contains "direct caller that uses the package" \
	"module console/direct (lib/helpers.pm: do_thing): 1 schedule line(s); loadtest at lib/main_common.pm:4, products/sle/main.pm:4" "$actual"
contains "caller through another lib" "module console/indirect (lib/helpers.pm via mid_call): 1 schedule line(s)" "$actual"
check "modules reached directly come before those reached through other subs" \
	"console/indirect" "$(grep '^module ' <<<"$actual" | tail -n 1 | cut -d' ' -f2)"
contains "the lib in between is listed" "via lib/middle.pm: mid_call" "$actual"
lacks "importing a sub without calling it is no reach" "module console/import_only" "$actual"
contains "a method call reaches when only one lib defines the method" \
	"module console/method (lib/remote.pm: unique_method_xyz)" "$actual"
contains "a method call through a variable too" \
	"module console/method_var (lib/remote.pm: unique_method_xyz)" "$actual"
contains "a hook change reaches every user of the package" \
	"module console/hooked (lib/basemod.pm (uses basemod))" "$actual"
contains "lib levels beyond the cap are named, not followed" \
	"depth: lib/chain5.pm calls step4; its callers are not followed (more than 3 lib levels)" "$actual"
lacks "the module behind the depth cap is not claimed" "module console/chained" "$actual"
contains "loader: a new loadtest line reaches its module" \
	"lib/main_common.pm: main_common: subs load_tests; loads console/newly_loaded" "$actual"
contains "loader: the module is listed with its loadtest site" \
	"module console/newly_loaded (loaded in lib/main_common.pm): loadtest at lib/main_common.pm:5" "$actual"
contains "loader: products/*/main.pm is package main, its top level is not traced" \
	"products/sle/main.pm: main: code outside any sub; loads console/prod_loaded" "$actual"
contains "data: the consumer of a changed data file" \
	"data/console/payload.txt: data, named as console/payload.txt by tests/console/datauser.pm" "$actual"
contains "data: an unknown file under a top-level directory is not matched by the directory name" \
	"INJECTED.txt: data, named as console/" "$actual"
contains "test_data: a schedule including it through another test_data file" \
	"test_data/td/leaf.yaml: test data, included by schedule/console/td.yaml" "$actual"
contains "test_data: a sibling with a similar name is not included" \
	"test_data/td/leaf_x64.yaml: test data, included by no schedule" "$actual"
contains "test module changed" "tests/console/changed.pm: test module console/changed" "$actual"
contains "unit test changed" "t/01_helpers.t: unit test" "$actual"
contains "docs, CI and attribute files need no run, counted on one line" \
	"no openQA run needed: .gitattributes, .github/ci.yml, docs/page1.md, docs/page2.md, docs/page3.md [+5 more] (docs, CI, tools)" "$actual"
contains "anything else is left to a human" "notes.txt: not classified, check by hand" "$actual"
contains "summary counts" "summary: modules=11 schedules=5 loaded_by_perl=3 unit_tests=1" "$actual"
contains "next: the unit tests of changed libs, never a linked one outside the checkout" \
	"next: prove -l -Ios-autoinst/ t/01_helpers.t" "$actual"
contains "next: one sweep per schedule" \
	"next: scripts/oqa-sweep.py --uses-schedule schedule/console/main.yaml --group <id>|--match <regex>" "$actual"
contains "next: modules a loader loads get a passed-job lookup" \
	"next: scripts/oqa-sweep.py --group <id> --passed --module prod_loaded" "$actual"

# --- hostile names --------------------------------------------------------------
contains "a forged fence marker in a file name is neutralised" \
	'data/console/\<\<\<END 0000000000000000>>> INJECTED.txt' "$actual"
check "no output line starts with text from a file name" 0 "$(grep -c '^INJECTED' <<<"$actual")"
check "no control characters, colour config included" 0 "$(grep -c '[[:cntrl:]]' <<<"$actual")"
check "a Hangul filler in a module name is stripped" 0 "$(grep -c "$(printf 'ㅤ')" <<<"$actual")"
contains "the module with the stripped name is still listed" "tests/console/evil.pm: test module console/evil" "$actual"
contains "a name with shell syntax is quoted in a next: line" \
	"next: scripts/oqa-sweep.py --uses-schedule 'schedule/console/x\`id\`.yaml' --group" "$actual"

# --- caps --------------------------------------------------------------------------
actual=$(reach --base master --max-items 2)
contains "--max-items caps the file lines" "[+17 more files]" "$actual"
contains "--max-items caps the module lines" "[+9 more modules]" "$actual"
contains "--max-items: more schedules than the cap ask for a choice" \
	"next: 5 schedules, more than 2: pick 1-3 that cover the change by hand" "$actual"
contains "--max-items caps the loader lookups and says so" "[+1 more modules loaded by Perl]" "$actual"
contains "the summary survives every cap" "summary: modules=11" "$actual"

# --- renames ---------------------------------------------------------------------
g mv tests/console/indirect.pm tests/console/indirect2.pm
g commit -qm rename
actual=$(reach --base HEAD~1)
contains "a rename reports the old module as removed" \
	"tests/console/indirect.pm (removed): test module console/indirect" "$actual"
contains "the schedules of the old name are listed" "module console/indirect (removed): 1 schedule line(s)" "$actual"
contains "the new name is listed too" "module console/indirect2 (changed): not scheduled anywhere" "$actual"
g reset -q --hard HEAD~1

# --- warnings --------------------------------------------------------------------
printf 'dirty\n' >>"$repo/tests/console/changed.pm"
printf 'new\n' >"$repo/untracked.txt"
actual=$(reach --base master)
contains "uncommitted and untracked files are counted" \
	"warning: 1 changed (or touched) and 1 untracked files are not committed: a verification run never sees them" "$actual"
contains "the digest still covers the commits only" "tests/console/changed.pm: test module console/changed" "$actual"
lacks "the untracked file is not planned" "untracked.txt:" "$actual"
cp "$fixtures/head/tests/console/changed.pm" "$repo/tests/console/changed.pm"
rm "$repo/untracked.txt"
git init -q --bare "$tmp/remote.git"
g remote add fork "$tmp/remote.git"
g push -q fork feature
actual=$(reach --base master)
lacks "pushed: no push warning" "no remote-tracking branch" "$actual"

# --- repository config must not run anything --------------------------------------
g config core.fsmonitor "touch $tmp/fsmonitor-ran"
g config diff.external "$tmp/ext-diff"
printf '#!/bin/sh\ntouch %s/ext-diff-ran\n' "$tmp" >"$tmp/ext-diff"
chmod +x "$tmp/ext-diff"
printf '*.pm diff=evil filter=evil\n' >"$repo/.git/info/attributes"
g config diff.evil.textconv "touch $tmp/textconv-ran; cat"
g config filter.evil.clean "touch $tmp/clean-ran; cat"
g config filter.evil.smudge cat
printf 'dirty\n' >>"$repo/lib/helpers.pm"
touch "$repo/lib/two.pm"
reach --base master >/dev/null
ran=""
for marker in fsmonitor-ran ext-diff-ran textconv-ran clean-ran; do
	[ -e "$tmp/$marker" ] && ran+="$marker "
done
check "neither fsmonitor, external diff, textconv nor a clean filter ran" "" "$ran"
cp "$fixtures/head/lib/helpers.pm" "$repo/lib/helpers.pm"
rm "$repo/.git/info/attributes"
g config --unset core.fsmonitor
g config --unset diff.external

# --- errors -----------------------------------------------------------------------
actual=$(reach --base no-such-ref)
check "unknown --base is exit 2" "2" "$?"
contains "unknown --base says what to do" "error: unknown --base no-such-ref; fetch upstream or name the ref" "$actual"
actual=$(reach --base --upload-pack=x)
check "an option given as --base is refused" "2" "$?"
g checkout -q --orphan lonely
g commit -qm lonely
actual=$(reach --base master)
check "no common history is exit 2" "2" "$?"
contains "no common history says why" "error: no merge base of master and HEAD" "$actual"
cp -r "$fixtures/base" "$tmp/plain"
actual=$(cd "$tmp/plain" && python3 "$script" 2>&1)
check "a tree without git is exit 2" "2" "$?"
contains "a tree without git says so" "is not a git checkout" "$actual"
actual=$(cd "$tmp" && python3 "$script" --repo "$tmp" 2>&1)
check "not a distri checkout is exit 2" "2" "$?"
contains "not a distri checkout says why" "not a distri checkout" "$actual"
actual=$(python3 "$script" --help)
check "--help exits 0" 0 $?
contains "--help says it is offline" "Offline" "$actual"

exit $fail
