#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Proves every check in check-flags.py can fail: each case breaks one thing in a
# throw-away copy of the repository and expects that check, by name, to report it.
# The backticks in the injected text are Markdown, not command substitution.
# shellcheck disable=SC2016

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
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

# fresh: a clean copy of what the gate reads
fresh() {
	rm -rf "$work/repo"
	mkdir -p "$work/repo/tests/repo"
	cp -r "$root/skills" "$work/repo/"
	cp "$here/check-flags.py" "$work/repo/tests/repo/"
	skill=$work/repo/skills/openqa
}

gate() {
	python3 "$work/repo/tests/repo/check-flags.py" "$@"
}

# reports <name> <check>: the gate exits 1 and names that check
reports() {
	local out rc
	out=$(gate)
	rc=$?
	check "$1" "1 1" "$rc $(grep -c "^$2: " <<<"$out" | sed 's/^[1-9][0-9]*$/1/')"
}

fresh
gate >/dev/null
check "a clean copy passes" 0 $?

fresh
sed -i 's/^    args = parser.parse_args(argv)$/    parser.add_argument("--zz-probe", action="store_true")\n&/' \
	"$skill/scripts/refsection.py"
reports "index: a new flag makes the section stale" index
gate --write >/dev/null
check "--write brings the section up to date" 0 "$(gate | grep -c '^index: ')"
check "and the section now shows the flag" 1 "$(grep -c -- '--zz-probe' "$skill/scripts/README.md")"
check "--write changes only the section" 2 \
	"$(diff "$root/skills/openqa/scripts/README.md" "$skill/scripts/README.md" | grep -c '^[<>]')"

fresh
sed -i '/^## Script flags$/d' "$skill/scripts/README.md"
reports "index: a missing section" index

fresh
printf '\n## Script flags\n' >>"$skill/SKILL.md"
reports "index: a copy of the section in SKILL.md" index

# refsection.py prints a title at any level, by prefix and whatever its case.
fresh
printf '\n###  Script Flags (all)' >>"$skill/SKILL.md"
reports "index: a copy under another level and spelling of the heading" index

fresh
printf '\n```\n## Script flags\n```\n' >>"$skill/SKILL.md"
gate >/dev/null
check "index: the heading quoted in a code fence is no copy" 0 $?

fresh
sed -i 's| -> scripts/README.md "Script flags"||' "$skill/SKILL.md"
reports "index: SKILL.md no longer points at the section" index

fresh
sed -i 's|-> \(scripts/README.md "Script flags"\)|\1|' "$skill/SKILL.md"
reports "index: the section named without an arrow is no pointer" index

fresh
sed -i 's/ `--quiet` leaves the stderr summary out\.//' "$skill/scripts/README.md"
reports "meaning: a flag the README never explains" meaning

fresh
printf '\nRun `oqa-log.py --no-such-flag`.\n' >>"$skill/references/review-tooling.md"
reports "citations: a flag the script does not have" citations

fresh
printf '\n```\nscripts/oqa-log.py JOB --no-such-flag\n```\n' >>"$skill/references/review-tooling.md"
reports "citations: also inside a fenced block" citations

fresh
printf '\nSee `scripts/missing-script.py`.\n' >>"$skill/references/review-tooling.md"
reports "citations: a script that does not exist" citations

fresh
printf '\nFlags: `scripts/oqa-job.py --help`.\n' >>"$skill/references/review-tooling.md"
reports "no-help: a reference that sends the agent to --help" no-help
check "and the finding names the section to point at" 1 \
	"$(gate | grep -c '^no-help: .*; point at scripts/README.md "Script flags" instead$')"

fresh
printf '\nAnything else: `--help`.\n' >>"$skill/agents/job-triage.md"
reports "no-help: a bare --help in a playbook" no-help

fresh
printf '\nFlags: `scripts/oqa-job.py -h`.\n' >>"$skill/references/review-tooling.md"
reports "no-help: the short -h form" no-help

# One case per branch: a script that fails both would hide either branch being gone.
fresh
printf 'import argparse, sys\np = argparse.ArgumentParser()\np.print_help = lambda file=None: sys.exit(3)\np.parse_args()\n' \
	>"$skill/scripts/broken.py"
reports "help: a parser whose --help exits non-zero" help

fresh
printf 'print("usage: hand-rolled")\n' >"$skill/scripts/noparser.py"
reports "help: a script with no argparse parser" help

# --- defects found in review, each with the input that demonstrated it --------------

fresh
mkdir -p "$work/repo/skills/zz"
printf -- '---\nname: zz\n---\n# zz\n' >"$work/repo/skills/zz/SKILL.md"
gate >/dev/null
check "a second skill without scripts needs no section" 0 $?
printf '\n## Script flags\n' >>"$work/repo/skills/zz/SKILL.md"
gate >/dev/null
check "and may use the heading for something else" 0 $?

# A second skill with its own _sanitize.py must never see openqa's.
fresh
zz=$work/repo/skills/zz
mkdir -p "$zz/scripts"
printf -- '---\nname: zz\n---\n# zz\n\nFlags -> scripts/README.md "Script flags"\n' >"$zz/SKILL.md"
printf 'FLAG = "--zz-own"\n' >"$zz/scripts/_sanitize.py"
printf 'import argparse\nimport _sanitize\np = argparse.ArgumentParser()\np.add_argument(getattr(_sanitize, "FLAG", "--leaked"), action="store_true")\np.parse_args()\n' \
	>"$zz/scripts/tool.py"
printf '# Scripts\n\n## Script flags\n\n## tool.py - t\n\n`--zz-own`\n\n## _sanitize.py - s\n' >"$zz/scripts/README.md"
gate --write >/dev/null
check "skills never share imported modules" "1 0" \
	"$(grep -c -- '^- `tool.py \[--zz-own\]`$' "$zz/scripts/README.md") $(grep -c -- '--leaked' "$zz/scripts/README.md")"
check "a skill without refsection.py is sent to the script's section" 1 \
	"$(grep -c 'What a flag means: that script.s section below\.$' "$zz/scripts/README.md")"

fresh
check "repeating a flag and giving it several words read differently" "1 1 1" \
	"$(grep -c -- '`oqa-sweep.py \[--group ID\]\.\.\. ' "$skill/scripts/README.md") $(grep -c -- '--job JOB\.\.\. ' "$skill/scripts/README.md") $(grep -c -- '--kind {console,' "$skill/scripts/README.md")"
check "a lookup miss that exits 1 is shown" 1 "$(grep -c -- 'with --module: no reference found' "$skill/scripts/README.md")"

# A look-alike --host keeps its own line and is not listed as the shared one.
fresh
sed -i 's/^    parser.add_argument(\n\?        "--body",/&/; /^    args = parser.parse_args()$/i\    parser.add_argument("--host", help="tracker host")' "$skill/scripts/oqa-ref.py"
gate --write >/dev/null
check "a script's own --host is not the shared one" "1 0" \
	"$(grep -c -- '^- `oqa-ref.py REF .*\[--host HOST\]' "$skill/scripts/README.md") $(grep -c -- '^- `--host HOST` on .*oqa-ref' "$skill/scripts/README.md")"

fresh
sed -i '/^    args = parser.parse_args()$/i\    parser.add_argument("--exit-code", action="store_true", help="x")' "$skill/scripts/oqa-ref.py"
reports "meaning: the preamble explains shared flags only" meaning

fresh
sed -i 's/oqa-job.py JOB_URL|ID \[--steps N\]/oqa-job.py JOB_URL|ID [--stepz N]/' "$skill/scripts/README.md"
reports "citations: a synopsis in an indented block" citations

fresh
printf '\nRun `./scripts/oqa-log.py 1 --no-such-flag`.\n' >>"$skill/references/review-tooling.md"
reports "citations: a script called through a path" citations

fresh
printf '\nChain `oqa-sweep.py --group 1 && oqa-job.py 5 --steps 3`.\n' >>"$skill/references/review-tooling.md"
gate >/dev/null
check "citations: each command of a chain is its own" 0 $?

fresh
printf '\nIf unsure, run oqa-job.py with --help.\n' >>"$skill/references/review-tooling.md"
reports "no-help: plain prose" no-help

fresh
printf '\nMore: `oqa-job.py --help`.\n' >>"$skill/scripts/README.md"
reports "no-help: scripts/README.md too" no-help

fresh
printf 'raise RuntimeError("boom")\n' >"$skill/scripts/raises.py"
out=$(gate)
check "help: a script that raises is a finding, not a crash" "1 0" \
	"$(grep -c '^help: .*raises.py: importing it raised RuntimeError' <<<"$out") $(grep -c Traceback <<<"$out")"

fresh
printf 'import sys\nsys.stdin.read()\nimport argparse\nargparse.ArgumentParser().parse_args()\n' >"$skill/scripts/reads-stdin.py"
printf '\n## reads-stdin.py - r\n' >>"$skill/scripts/README.md"
timeout 60 python3 "$work/repo/tests/repo/check-flags.py" --write >/dev/null < <(sleep 90)
check "a script reading stdin does not hang the gate" 0 $?

fresh
printf 'import argparse, pathlib\nargparse.ArgumentParser().parse_known_args()\npathlib.Path(__file__).with_name("SIDE_EFFECT").write_text("x")\n' \
	>"$skill/scripts/known.py"
printf '\n## known.py - k\n' >>"$skill/scripts/README.md"
gate --write >/dev/null
check "parse_known_args stops the script before its work" 0 "$(find "$skill/scripts" -name SIDE_EFFECT | wc -l)"

exit $fail
