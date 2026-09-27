#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests for scripts/ticket-lint.py: bug or ticket draft JSON in, shape report out; no network.
# shellcheck disable=SC2016

here=$(cd "$(dirname "$0")" && pwd)
scripts="$here/../../skills/openqa/scripts"
fixtures="$here/fixtures/ticket-lint"
src="$scripts/ticket-lint.py"
fail=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

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
	python3 "$src" "$@" 2>&1
}

# variant FIXTURE CODE: the fixture's JSON after running CODE on it as `d`
variant() {
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
exec(sys.argv[2])
print(json.dumps(d))
' "$fixtures/$1.json" "$2"
}

# result: "<exit code> <finding ids>" of the lint output in $out and $rc
result() {
	echo "$rc $(sed -n 's/^  F \([^ ]*\) .*/\1/p' <<<"$out" | paste -sd' ')" | sed 's/ $//'
}

# try NAME EXPECTED FIXTURE CODE [ARGS]: lint a variant and compare "<rc> <ids>"
try() {
	local name=$1 expected=$2 fixture=$3 code=$4
	shift 4
	out=$(variant "$fixture" "$code" | lint "$@")
	rc=$?
	check "$name" "$expected" "$(result)"
}

# --- offline by construction -----------------------------------------------------
check "no network or process code" 0 "$(grep -Ec 'urllib\.request|http\.client|socket|subprocess|os\.system|import _oqa' "$src")"
check "licence header" "# SPDX-License-Identifier: GPL-2.0-or-later" "$(sed -n 2p "$src")"
python3 "$src" --help >/dev/null
check "--help exits 0" 0 $?

# --- clean drafts -------------------------------------------------------------------
out=$(lint "$fixtures/bug-clean.json")
rc=$?
check "a clean bug passes" "0" "$(result)"
check "success names what is not checked" "shape ok; whether the report is right is the refute pass's job" "$(tail -n 1 <<<"$out")"
check "the summary line counts title, body and notes" \
	"draft: bugzilla, summary 100/255 chars, body 1097 chars (target 1500, limit 3000), notes 121 chars (not filed)" \
	"$(head -n 1 <<<"$out")"
out=$(lint "$fixtures/ticket-clean.json")
rc=$?
check "a clean ticket passes" "0" "$(result)"

# --- fields -------------------------------------------------------------------------
for f in product component version severity; do
	try "bug without $f" "1 field" bug-clean "d['fields'].pop('$f')"
done
for f in project tracker category; do
	try "ticket without $f" "1 field" ticket-clean "d['fields'].pop('$f')"
done
try "an empty field counts as missing" "1 field" bug-clean "d['fields']['component'] = ''"
try "a bug with a priority" "1 field" bug-clean "d['fields']['priority'] = 'P2 - High'"
try "a ticket may carry a priority" "0" ticket-clean "d['fields']['priority'] = 'High'"
try "an unknown severity" "1 field" bug-clean "d['fields']['severity'] = 'Serious'"
try "a known severity" "0" bug-clean "d['fields']['severity'] = 'Minor'"

# --- title --------------------------------------------------------------------------
try "a two-line summary" "1 title" bug-clean "d['summary'] = 'a\nb'"
try "an empty subject" "1 title" ticket-clean "d['subject'] = '  '"
try "a 255-char summary" "0" bug-clean "d['summary'] = 'x' * 255"
try "a 256-char summary" "1 title" bug-clean "d['summary'] = 'x' * 256"

# --- sections and labels ---------------------------------------------------------------
try "a bug without Reproducible" "1 section" bug-clean "d['body'] = d['body'].replace('## Reproducible\n', '')"
try "a bug without Further details" "1 section" bug-clean "d['body'] = d['body'].replace('## Further details\n', '')"
try "a ticket without Observation" "1 section" ticket-clean "d['body'] = d['body'].replace('## Observation\n', '')"
try "sections out of order" "1 section" bug-clean \
	"d['body'] = d['body'].replace('## Reproducible', '## TMP').replace('## Expected result', '## Reproducible').replace('## TMP', '## Expected result')"
try "a bug without an Expected: line" "1 label" bug-clean "d['body'] = d['body'].replace('Expected: ', 'Wanted: ')"
try "a bug without an Actual: line" "1 label" bug-clean "d['body'] = d['body'].replace('Actual: ', 'Got: ')"

# --- size ---------------------------------------------------------------------------------
pad='
def pad(total):
    extra = total - len(d["body"])
    rows, rest = divmod(extra, 80)
    d["body"] += ("x" * 79 + "\n") * rows + "y" * rest'
try "a bug body of 3000 chars" "0" bug-clean "$pad
pad(3000)"
try "a bug body of 3001 chars" "1 size" bug-clean "$pad
pad(3001)"
try "a ticket body of 4000 chars" "0" ticket-clean "$pad
pad(4000)"
try "a ticket body of 4001 chars" "1 size" ticket-clean "$pad
pad(4001)"

# --- bugzilla markup ------------------------------------------------------------------------
add='d["body"] += "\n"'
try "a markdown link in a bug" "1 markdown" bug-clean "$add + '[job](https://openqa.example.org/tests/1)\n'"
try "bold in a bug" "1 markdown" bug-clean "$add + 'this is **important**\n'"
try "a fence in a bug" "1 markdown" bug-clean "$add + '\`\`\`\n'"
try "a table in a bug" "1 markdown" bug-clean "$add + '| a | b |\n|---|---|\n'"
try "html in a bug" "1 markdown" bug-clean "$add + 'line<br>\n'"
try "markdown inside a verbatim block is output" "0" bug-clean "$add + '    [job](https://openqa.example.org/tests/1) **x**\n'"
try "a ticket renders markdown" "0" ticket-clean "$add + 'this is **important**\n'"
try "an 81-char prose line in a bug" "1 long-line" bug-clean "$add + 'y' * 81 + '\n'"
try "an 80-char prose line in a bug" "0" bug-clean "$add + 'y' * 80 + '\n'"
try "a long URL on a short line" "0" bug-clean "$add + 'see https://openqa.example.org/tests/1/' + 'y' * 90 + '\n'"
try "long prose next to a URL" "1 long-line" bug-clean "$add + 'see ' + 'y' * 80 + ' https://openqa.example.org/tests/1\n'"
try "a long verbatim line" "0" bug-clean "$add + '    ' + 'y' * 200 + '\n'"

# --- placeholders, title references, notes -----------------------------------------------------
try "a placeholder in a bug" "1 placeholder" bug-clean "$add + 'Last good: <build>\n'"
try "TBD in a ticket" "1 placeholder" ticket-clean "$add + 'Owner: TBD\n'"
try "a placeholder in the summary" "1 placeholder" bug-clean "d['summary'] += ' in <module>'"
try "a placeholder inside a verbatim block" "0" bug-clean "$add + '    Problem: <none>\n'"
try "a placeholder inside a fence" "0" ticket-clean "$add + '\`\`\`\nvalue <none>\n\`\`\`\n'"
try "see summary" "1 see-title" bug-clean "$add + 'Details: see summary.\n'"
try "approver notes in the body" "1 notes" bug-clean "$add + 'Approver notes: searched twice.\n'"

# --- leaks ------------------------------------------------------------------------------------
token='"ghp_" + "B" * 36'
try "a token in the body" "1 credential" bug-clean "$add + 'token ' + $token + '\n'"
try "a token in the subject" "1 credential" ticket-clean "d['subject'] += ' ' + $token"
try "a private URL" "1 private-url" bug-clean "$add + 'see http://build.internal/log\n'"
try "a private URL in a private report" "0" bug-clean \
	"d['public'] = False; d['fields']['product'] = 'SUSE Linux Enterprise Server 16.0'; $add + 'see http://build.internal/log\n'"
try "public false on a public product" "1 field private-url" bug-clean "d['public'] = False; $add + 'see http://build.internal/log\n'"
try "public false on a public project" "1 field" ticket-clean "d['public'] = False"
try "a private address" "1 private-url" ticket-clean "$add + 'see http://10.0.0.1/log\n'"
try "--private-suffix adds a domain" "1 private-url" ticket-clean \
	"d['body'] = d['body'].replace('https://openqa.example.org/tests/590', 'the last good job')" \
	--private-suffix example.org
out=$(variant bug-clean "$add + 'see http://a\u001b[31m.internal/x\n'" | lint)
check "a hostile URL is echoed without escapes" "0" "$(grep -c $'\e' <<<"$out")"

# --- auto_review subjects -----------------------------------------------------------------
snippet="\"d['body'] += '\\\\nopenqa-query-for-job-label poo#1\\\\n'\""
ar() { echo "d['subject'] = 'test fails in toolbox auto_review:\"$1\"$2'; exec($snippet)"; }
try "a 16-char auto_review term" "0" ticket-clean "$(ar 'Login incorrect.' ':retry')"
try "a 15-char auto_review term" "1 auto-review" ticket-clean "$(ar 'Login incorrect' ':retry')"
try "an auto_review term that does not compile" "1 auto-review" ticket-clean "$(ar '(Login incorrect[' ':retry')"
try "force_result on the action tracker" "1 auto-review" ticket-clean "$(ar 'Login incorrect.' ':force_result:softfailed')"
try "force_result on the force-result tracker" "0" ticket-clean \
	"d['fields']['tracker'] = 'openqa-force-result'; $(ar 'Login incorrect.' ':force_result:softfailed')"
try "an auto_review ticket without the query snippet" "1 auto-review" ticket-clean \
	"d['subject'] = 'test fails in toolbox auto_review:\"Login incorrect.\":retry'"

# --- review fixes: links, slots, verbatim, fences -------------------------------------
try "--private-suffix matches the host itself" "1 private-url" bug-clean "$add + 'see https://corp.example.org/x\n'" --private-suffix corp.example.org
try "--private-suffix with a trailing dot" "1 private-url" bug-clean "$add + 'see https://qa.corp.example.org/x\n'" --private-suffix corp.example.org.
try "a private URL field" "1 private-url" bug-clean "d['fields']['url'] = 'http://10.0.0.1/tests/1'"
try "a token in a field" "1 credential" bug-clean "d['fields']['url'] = 'https://x.example.org/?t=' + $token"
try "an IPv6 private link" "1 private-url" bug-clean "$add + 'see http://[fd00::1]/log\n'"
try "a public IPv6 link" "0" bug-clean "$add + 'see http://[2606:4700::1111]/x\n'"
try "a shorter fence inside a longer one" "0" ticket-clean "$add + '\`\`\`\`\n\`\`\`\nOwner: TBD\n\`\`\`\`\n'"
try "an uppercase scheme" "1 private-url" bug-clean "$add + 'see HTTP://build.internal/x\n'"
try "a URL that does not parse" "1 private-url" bug-clean "$add + 'see http://[::1/x\n'"
try "a slot with capitals" "1 placeholder" bug-clean "$add + 'Failed: zypper_in, <step URL>\n'"
try "a slot with punctuation" "1 placeholder" bug-clean "$add + 'Workaround: <one line, run or cited>\n'"
try "a ticket slot inside a link" "1 placeholder" ticket-clean "$add + '[latest](<latest URL>)\n'"
try "an autolink is no slot" "0" ticket-clean "$add + 'see <https://openqa.example.org/tests/1>\n'"
try "a slot in inline code is output" "0" ticket-clean "$add + 'podman images shows \`<none>\`\n'"
try "a heading only in a verbatim block" "1 section" bug-clean "d['body'] = d['body'].replace('## Reproducible\n', '    ## Reproducible\n')"
try "a heading only in a fence" "1 section" ticket-clean "d['body'] = d['body'].replace('## Reproducible\n', '\`\`\`\n## Reproducible\n\`\`\`\n')"
try "an empty Expected: line" "1 label" bug-clean "d['body'] = '\n'.join('Expected:' if l.startswith('Expected:') else l for l in d['body'].split('\n'))"
try "an unclosed fence" "1 markdown" ticket-clean "$add + '\`\`\`\nlog\n'"
try "a tilde line inside a backtick fence" "1 placeholder" ticket-clean "$add + '\`\`\`\n~~~\n\`\`\`\nOwner: TBD\n'"
try "an identifier is no bold" "0" bug-clean "$add + 'calls __init__ and __main__\n'"
try "__bold__ words" "1 markdown" bug-clean "$add + 'this is __really bold__\n'"
try "not filed in prose" "0" bug-clean "$add + 'The earlier report was not filed.\n'"
try "approver notes in a verbatim block" "1 notes" bug-clean "$add + '    Approver notes: searched twice.\n'"
try "a blank field counts as missing" "1 field" bug-clean "d['fields']['component'] = '  '"
try "a false field counts as missing" "1 field" ticket-clean "d['fields']['category'] = False"
try "a null priority is no priority" "0" bug-clean "d['fields']['priority'] = None"
try "a second pair of quotes in an auto_review subject" "1 auto-review" ticket-clean \
	"d['subject'] = '[qe-\"core\"] test fails auto_review:\"Login incorrect.\":retry'; exec($snippet)"
try "an auto_review regex that matches every log" "1 auto-review" ticket-clean "$(ar '(?:Login incorrect.)?' ':retry')"
out=$(variant ticket-clean "$(ar $'(?\e[31mLogin incorrect.)' ':retry')" | lint)
check "a regex error is echoed without escapes" "0" "$(grep -c $'\e' <<<"$out")"
for run in "'[' * 60000" "'<a ' * 85000" "'__' + 'a ' * 60000"; do
	variant bug-clean "$add + $run + '\n'" >"$work/slow.json"
	timeout 10 python3 "$src" "$work/slow.json" >/dev/null 2>&1
	check "a long run of $run stays fast" "1" "$?"
done

# --- listing cap ----------------------------------------------------------------------------
out=$(variant bug-clean "d['body'] += ''.join('<a%d>\n' % n for n in range(45))" | lint)
check "more than 40 findings are cut" "40 ... 5 more not shown" "$(grep -c '^  F ' <<<"$out") $(tail -n 1 <<<"$out" | sed 's/^ *//')"

# --- broken input ---------------------------------------------------------------------------
for bad in 'not json' '[]' '{"kind": "jira", "fields": {}, "summary": "s", "subject": "s", "body": "b"}' '{"kind": "bugzilla", "fields": [], "summary": "s", "body": "b"}' \
	'{"kind": "bugzilla", "fields": {}, "subject": "s", "body": "b"}' \
	'{"kind": "progress", "fields": {}, "subject": "s", "body": "  "}' \
	'{"kind": "progress", "fields": {}, "subject": "s", "body": "b", "notes": 5}' \
	'{"kind": "progress", "fields": {}, "subject": "s", "body": "b", "public": "yes"}'; do
	lint <<<"$bad" >/dev/null
	check "not a draft exits 2: $bad" 2 $?
done
python3 -c 'print("[" * 100000)' | lint >"$work/out"
check "deep nesting exits 2 without a traceback" "2 0" "$? $(grep -c Traceback "$work/out")"
python3 -c 'print("{}" + " " * 270000)' >"$work/big.json"
check "an oversized FILE exits 2" "error: draft longer than 262144 characters" "$(lint "$work/big.json")"
out=$(lint - <"$fixtures/bug-clean.json")
rc=$?
check "'-' reads stdin" "0" "$(result)"
lint "$fixtures" >/dev/null
check "a directory exits 2" 2 $?
mkfifo "$work/fifo"
check "a FIFO is refused instead of blocking" 'error: "fifo": not a regular file' "$(cd "$work" && timeout 10 python3 "$src" fifo 2>&1)"
lint "$work/missing.json" >/dev/null
check "a missing file exits 2" 2 $?
out=$(lint "$work/"$'no\nsuch\e[31m.json')
check "a hostile file name stays on one line without escapes" "1 0" "$(wc -l <<<"$out") $(grep -c $'\e' <<<"$out")"

exit $fail
