#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests for scripts/review-lint.py: review JSON in, size report out; no network.
# shellcheck disable=SC2016

here=$(cd "$(dirname "$0")" && pwd)
scripts="$here/../../skills/openqa/scripts"
fixtures="$here/fixtures/review-lint"
src="$scripts/review-lint.py"
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

# draft EVENT BODY [COMMENT...]: review JSON with a commit_id; comment N sits at tests/x.pm line N
draft() {
	python3 -c '
import json, sys
event, body, *comments = sys.argv[1:]
print(json.dumps({"commit_id": "0" * 40, "event": event, "body": body,
    "comments": [{"path": "tests/x.pm", "line": n, "body": text} for n, text in enumerate(comments, 1)]}))
' "$@"
}

lint() {
	python3 "$src" "$@" 2>&1
}

# result: "<exit code> <finding ids>" of the lint output in $out and $rc
result() {
	echo "$rc $(sed -n 's/^  F \([^ ]*\) .*/\1/p' <<<"$out" | paste -sd' ')" | sed 's/ $//'
}

text() {
	printf "%${1}s" "" | tr ' ' "${2:-x}"
}

# --- offline by construction -----------------------------------------------------
check "no network or process code" 0 "$(grep -Ec 'urllib|http\.client|socket|subprocess|os\.system|import _oqa' "$src")"
check "licence header" "# SPDX-License-Identifier: GPL-2.0-or-later" "$(sed -n 2p "$src")"
python3 "$src" --help >/dev/null
check "--help exits 0" 0 $?

# --- the review that prompted this ------------------------------------------------
out=$(lint "$fixtures/posted-26762.json" --lines 331 --late)
rc=$?
check "the posted 26762 review: no commit, over budget, one long body, bare ids, shorthand, long sentences, late" \
	"1 commit over-chars long-comment bare-id jargon long-sentence late" "$(result)"
out=$(lint "$fixtures/right-26762.json" --lines 331 --late)
rc=$?
check "its blocking-only rewrite passes even late" "0" "$(result)"
check "success names what is not checked" "size ok: 0/4 items, 0/1500 chars; the findings themselves are not checked" "$(tail -n 1 <<<"$out")"
out=$(draft COMMENT "" "fix it" "$(printf 'and this:\n```suggestion\nfixed\n```')" | lint --lines 12)
check "the item count survives a code block" "size ok: 2/3 items, 15/600 chars; the findings themselves are not checked" "$(tail -n 1 <<<"$out")"

# --- budget: count ------------------------------------------------------------------
# edge NAME COUNT LINES [ARGS]: COUNT items at the top of a size bucket, then one line later
edge() {
	local name=$1 count=$2 lines=$3
	shift 3
	local items=()
	for n in $(seq "$count"); do items+=("point $n"); done
	out=$(draft COMMENT "" "${items[@]}" | lint --lines "$lines" "$@")
	rc=$?
	check "$name: $count items on $lines lines is over" "1 over-count" "$(result)"
	out=$(draft COMMENT "" "${items[@]}" | lint --lines "$((lines + 1))" "$@")
	rc=$?
	check "$name: $count items on $((lines + 1)) lines is not" "0" "$(result)"
}
edge "tests <=20" 4 20
out=$(draft COMMENT "" 1 2 3 4 5 | lint --lines 100)
rc=$?
check "tests 21-100: 5 items on 100 lines" "0" "$(result)"
out=$(draft COMMENT "" 1 2 3 4 5 6 | lint --lines 100)
rc=$?
check "tests 21-100: 6 items on 100 lines is over" "1 over-count" "$(result)"
edge "lib <=20" 3 20 --lib
edge "lib 21-100" 5 100 --lib
edge "lib 101-300" 6 300 --lib
out=$(draft COMMENT "" 1 2 3 4 | lint --lines 300)
rc=$?
check "tests 101-300: 4 items" "0" "$(result)"
out=$(draft COMMENT "" 1 2 3 4 5 | lint --lines 101)
rc=$?
check "tests over 100 lines: 5 items" "1 over-count" "$(result)"
out=$(draft COMMENT "" 1 2 3 4 5 6 7 8 9 | lint --lines 400 --lib)
rc=$?
check "lib over 300 lines: 9 items" "1 over-count" "$(result)"
out=$(draft COMMENT "" 1 2 3 4 5 6 7 8 | lint --lines 400 --lib)
rc=$?
check "lib over 300 lines: 8 items" "0" "$(result)"
out=$(draft COMMENT "" "a" "b" "c" | lint --lines 5 --replies 1)
rc=$?
check "a thread reply counts as an item" "1 over-count" "$(result)"
check "  and is shown" 1 "$(grep -c '; replies 1$' <<<"$out")"
lint --lines 5 --replies -1 <<<'{"event": "APPROVE"}' >/dev/null
check "negative --replies exits 2" 2 $?
out=$(draft COMMENT "x" "a" "b" "c" | lint --lines 5)
rc=$?
check "a body counts as an item" "1 over-count" "$(result)"
long="blocking: $(text 900)"
out=$(draft COMMENT "" "$long 1" "$long 2" "$long 3" "$long 4" "$long 5" | lint --lines 10)
rc=$?
check "blocking comments count against no budget" "0" "$(result)"
out=$(draft COMMENT "" "Blocking: $(text 900)" | lint --lines 10)
rc=$?
check "the prefix is case-insensitive" "0" "$(result)"

# --- budget: characters ----------------------------------------------------------
out=$(draft COMMENT "" "$(text 300)" "$(text 300 y)" | lint --lines 20)
rc=$?
check "600 chars on 20 lines" "0" "$(result)"
out=$(draft COMMENT "" "$(text 300)" "$(text 301 y)" | lint --lines 20)
rc=$?
check "601 chars on 20 lines" "1 over-chars" "$(result)"
out=$(draft COMMENT "" "$(text 500)" "$(text 501 y)" | lint --lines 100)
rc=$?
check "1001 chars on 100 lines" "1 over-chars" "$(result)"
out=$(draft COMMENT "" "$(text 500)" "$(text 501 y)" | lint --lines 101)
rc=$?
check "1001 chars on 101 lines" "0" "$(result)"
out=$(draft COMMENT "" "$(text 500)" "$(text 500 y)" "$(text 500 z)" | lint --lines 300)
rc=$?
check "1500 chars on 300 lines" "0" "$(result)"
out=$(draft COMMENT "" "$(text 500)" "$(text 500 y)" "$(text 501 z)" | lint --lines 300)
rc=$?
check "1501 chars on 300 lines" "1 over-chars" "$(result)"
out=$(draft COMMENT "" "$(text 500)" "$(text 500 y)" "$(text 501 z)" | lint --lines 400)
rc=$?
check "1501 chars on 400 lines" "1 over-chars" "$(result)"
out=$(draft COMMENT "" "see https://example.org/$(text 900)" | lint --lines 10)
rc=$?
check "URLs are not prose" "0" "$(result)"
out=$(draft COMMENT "" "$(printf 'Change it:\n```suggestion\n%s\n```' "$(text 900)")" | lint --lines 10)
rc=$?
check "suggestion blocks are not prose" "0" "$(result)"
accents=$(python3 -c 'print("e\u0301" * 400)')
out=$(draft COMMENT "" "$accents" | lint --lines 400)
rc=$?
check "decomposed accents count once" "0" "$(result)"
out=$(draft COMMENT "" "$(text 600)$(python3 -c 'print("\u200b" * 100, end="")')" | lint --lines 400)
rc=$?
check "zero-width characters do not count" "0" "$(result)"

# --- one item ---------------------------------------------------------------------
out=$(draft COMMENT "" "$(text 600)" | lint --lines 200)
rc=$?
check "a 600-char comment" "0" "$(result)"
out=$(draft COMMENT "" "$(text 601)" | lint --lines 200)
rc=$?
check "a 601-char comment is long" "1 long-comment" "$(result)"
out=$(draft COMMENT "$(text 601)" | lint --lines 200)
rc=$?
check "a 601-char body alone is long" "1 long-comment" "$(result)"
out=$(draft COMMENT "" "blocking: $(text 990)" | lint --lines 10)
rc=$?
check "a 1000-char blocking comment" "0" "$(result)"
out=$(draft COMMENT "" "blocking: $(text 991)" | lint --lines 10)
rc=$?
check "a 1001-char blocking comment is long" "1 long-comment" "$(result)"
out=$(draft COMMENT "$(text 300)" "fix it" | lint --lines 200)
rc=$?
check "a 300-char body beside comments" "0" "$(result)"
out=$(draft COMMENT "$(text 301)" "fix it" | lint --lines 200)
rc=$?
check "a 301-char body beside comments is long" "1 long-body" "$(result)"
out=$(draft COMMENT "" "$(printf '```foo``` is wrong\n%s' "$(text 700)")" | lint --lines 200)
rc=$?
check "a line-leading code span is not a fence" "1 long-comment" "$(result)"
out=$(draft COMMENT "" "$(printf '\t```\n%s' "$(text 700)")" | lint --lines 200)
rc=$?
check "a tab-indented fence is not a fence" "1 long-comment" "$(result)"

# --- nits ---------------------------------------------------------------------------
out=$(draft COMMENT "" "fix it" "nit: a" "nit: b" | lint --lines 50)
rc=$?
check "2 nits" "0" "$(result)"
out=$(draft COMMENT "" "fix it" "nit: a" "nit: b" "nit: c" | lint --lines 400 --lib)
rc=$?
check "3 nits are too many" "1 nits" "$(result)"
out=$(draft COMMENT "nit: a" "fix it" "nit: b" "nit: c" | lint --lines 400 --lib)
rc=$?
check "a nit in the body counts" "1 nits" "$(result)"
out=$(draft COMMENT "" "fix it" "nit: $(text 145)" | lint --lines 50)
rc=$?
check "a 150-char nit, prefix included" "0" "$(result)"
out=$(draft COMMENT "" "fix it" "nit: $(text 146)" | lint --lines 50)
rc=$?
check "a 151-char nit is long" "1 long-nit" "$(result)"
out=$(draft COMMENT "" "fix it" "$(printf 'nit: a\nand b')" | lint --lines 50)
rc=$?
check "a two-line nit is long" "1 long-nit" "$(result)"
out=$(draft COMMENT "" "fix it" "$(printf 'nit: rename a\nnit: rename b')" | lint --lines 50)
rc=$?
check "two one-line nits in one nit: comment are not long" "0" "$(result)"
out=$(draft COMMENT "" "fix it" "$(printf 'nit: a\n\nThe reason is b.')" | lint --lines 50)
rc=$?
check "a nit: comment with a paragraph that is no nit is long" "1 long-nit" "$(result)"
out=$(draft COMMENT "" "fix it" "$(printf 'nit: a\rand b')" | lint --lines 50)
rc=$?
check "a lone CR ends a line" "1 long-nit" "$(result)"
out=$(draft COMMENT "" "fix it" "$(printf 'nit: typo\n```suggestion\nfixed\n```')" | lint --lines 50)
rc=$?
check "a nit with a suggestion block is one line" "0" "$(result)"
out=$(draft COMMENT "" "nit: a" | lint --lines 50)
rc=$?
check "nits alone" "1 lone-nits" "$(result)"
out=$(draft COMMENT "nit: a" | lint --lines 50)
rc=$?
check "a nit alone in the body" "1 lone-nits" "$(result)"
out=$(draft COMMENT "Looks good overall." "nit: a" | lint --lines 50)
rc=$?
check "a body is not a change request for nits" "1 lone-nits" "$(result)"
out=$(draft COMMENT "" "blocking: broken" "nit: a" | lint --lines 50)
rc=$?
check "a nit beside a blocking finding" "0" "$(result)"
# A nit: opening a later paragraph, list item or line is a nit as well.
out=$(lint "$fixtures/posted-nits.json" --lines 1)
rc=$?
posted="$(result) $(grep -c '; blocking 0, nit 2,' <<<"$out")"
out=$(lint "$fixtures/right-nits.json" --lines 1)
rc=$?
check "two nits after a remark in the body: counted, long, alone, in shorthand; the rewrite as a change request passes" \
	"1 long-nit long-nit lone-nits jargon long-sentence 1 / 0" "$posted / $(result)"
out=$(draft COMMENT "" "fix it" "$(printf 'Rename it.\n\nnit: a\n\nnit: b\n\nnit: c')" | lint --lines 400 --lib)
rc=$?
check "3 nits in later paragraphs are too many" "1 nits" "$(result)"
out=$(draft COMMENT "" "$(printf 'Rename it.\n\nnit: %s' "$(text 145)")" | lint --lines 50)
rc=$?
check "a 150-char nit in a later paragraph counts and is short" "0 1" "$rc $(grep -c ', nit 1,' <<<"$out")"
out=$(draft COMMENT "" "$(printf 'Rename it.\n\nnit: %s' "$(text 146)")" | lint --lines 50)
rc=$?
check "a 151-char nit in a later paragraph is long" "1 long-nit" "$(result)"
out=$(draft COMMENT "" "$(printf 'Rename it.\n\nnit: a\nand b')" | lint --lines 50)
rc=$?
check "a two-line nit in a later paragraph is long" "1 long-nit" "$(result)"
out=$(draft COMMENT "$(printf 'Placement is fine.\n\nnit: a')" | lint --lines 50)
rc=$?
check "a nit after a remark in the body is still alone" "1 lone-nits" "$(result)"
out=$(draft COMMENT "" "$(printf -- '- nit: a\n- nit: b\n\nhttps://example.org/x')" | lint --lines 50)
rc=$?
check "a comment of two nit list items and a link is not a change request" "1 lone-nits" "$(result)"
check "  and holds two nits" 1 "$(grep -c ', nit 2,' <<<"$out")"
out=$(draft COMMENT "" "$(printf 'Rename it, see the nit: below.\nnit: a')" | lint --lines 50)
rc=$?
check "nit: opening a line is a nit, inside a line it is not" "0 1" "$rc $(grep -c ', nit 1,' <<<"$out")"

# --- prefixes -------------------------------------------------------------------------
out=$(draft COMMENT "" "**nit:** a" | lint --lines 50)
rc=$?
check "an emphasised nit prefix" "1 prefix" "$(result)"
out=$(draft COMMENT "" "Nitpick: a" | lint --lines 50)
rc=$?
check "a nitpick prefix" "1 prefix" "$(result)"
out=$(draft COMMENT "" "**blocking:** broken" | lint --lines 50 --late)
rc=$?
check "an emphasised blocking prefix is not blocking" "1 prefix late" "$(result)"
out=$(draft COMMENT "" "$(printf '\n  blocking: broken')" | lint --lines 50 --late)
rc=$?
check "leading whitespace before the prefix" "0" "$(result)"
out=$(draft COMMENT "" "Nitrogen is missing" "Blocking the port here hangs the job" | lint --lines 50)
rc=$?
check "prose opening with Nitrogen or Blocking is not a prefix" "0" "$(result)"
# U+200B as UTF-8 bytes: printf's \u depends on the locale, and under LC_ALL=C it stays literal text.
out=$(draft COMMENT "" "$(printf '\xe2\x80\x8bblocking: broken')" | lint --lines 50 --late)
rc=$?
check "a zero-width space before the prefix" "0" "$(result)"
out=$(draft COMMENT "" "$(printf '> x\n\nblocking: y')" | lint --lines 50 --late)
rc=$?
check "the prefix after a quote" "1 prefix late" "$(result)"

# --- form -----------------------------------------------------------------------------
out=$(draft COMMENT "" "same   point" "Same point" | lint --lines 50)
rc=$?
check "the same text twice" "1 duplicate" "$(result)"
sugg=$(printf '```suggestion\nuse strict;\n```')
out=$(draft COMMENT "" "$sugg" "$sugg" | lint --lines 50)
rc=$?
check "the same suggestion on two lines" "0" "$(result)"
# block MARKER N: a comment with an N-line fenced block
block() {
	printf 'see:\n%s\n%s\n%s\nafter' "$1" "$(for _ in $(seq "$2"); do echo "log line"; done)" "${1%%[a-z]*}"
}
out=$(draft COMMENT "" "$(block '```' 10)" | lint --lines 50)
rc=$?
check "a 10-line code block" "0" "$(result)"
out=$(draft COMMENT "" "$(block '```' 11)" | lint --lines 50)
rc=$?
check "an 11-line code block is pasted" "1 pasted-block" "$(result)"
out=$(draft COMMENT "" "$(block '~~~' 11)" | lint --lines 50)
rc=$?
check "an 11-line tilde block is pasted" "1 pasted-block" "$(result)"
out=$(draft COMMENT "" "$(printf 'see:\n```\n%s\n```' "$(text 800)")" | lint --lines 50)
rc=$?
check "an 800-char code line" "0" "$(result)"
out=$(draft COMMENT "" "$(block '   ```' 11)" | lint --lines 50)
rc=$?
check "an indented 11-line block is pasted" "1 pasted-block" "$(result)"
out=$(draft COMMENT "" "$(printf 'see:\n```\n%s\n```' "$(text 801)")" | lint --lines 50)
rc=$?
check "an 801-char code line is pasted" "1 pasted-block" "$(result)"
out=$(draft COMMENT "" "$(block '```suggestion' 12)" | lint --lines 50)
rc=$?
check "a 12-line suggestion block is not pasted" "0" "$(result)"
out=$(draft COMMENT "" "$(printf 'see:\n```\ncode')" | lint --lines 50)
rc=$?
check "an unclosed fence" "1 unclosed-fence" "$(result)"
out=$(draft COMMENT "" "$(printf '> a\n> b\nno')" | lint --lines 50)
rc=$?
check "two quoted lines" "0" "$(result)"
out=$(draft COMMENT "" "$(printf '> a\n>\n> b\nwhy')" | lint --lines 50)
rc=$?
check "a bare > line is not quoted text" "0" "$(result)"
out=$(draft COMMENT "" "$(printf '> a\n> b\n> c\nno')" | lint --lines 50)
rc=$?
check "three quoted lines" "1 quotes" "$(result)"
out=$(draft COMMENT "" "$(printf '> %s\nno' "$(text 300)")" | lint --lines 50)
rc=$?
check "a 300-char quote" "0" "$(result)"
out=$(draft COMMENT "" "$(printf '> %s\nno' "$(text 301)")" | lint --lines 50)
rc=$?
check "a 301-char quote" "1 quotes" "$(result)"
out=$(draft COMMENT "" "fix it" | lint --lines 50 --late)
rc=$?
check "late: a non-blocking comment" "1 late" "$(result)"
out=$(draft APPROVE "" "fix it" | lint --lines 50)
rc=$?
check "an approval with a comment" "1 event" "$(result)"
out=$(draft REQUEST_CHANGES "" "fix it" | lint --lines 50)
rc=$?
check "request changes without a blocking comment" "1 event" "$(result)"
out=$(draft COMMENT "" | lint --lines 50)
rc=$?
check "an empty comment review" "1 event" "$(result)"
check "  suggests approving or nothing" 1 "$(grep -c 'approve if the user wants to, or post nothing' <<<"$out")"
out=$(draft COMMENT "" | lint --lines 50 --late)
rc=$?
check "an empty late review" "1 event" "$(result)"
check "  says to post nothing" 1 "$(grep -c 'nothing blocking, so post nothing' <<<"$out")"
out=$(draft APPROVE "" | lint --lines 50)
rc=$?
check "an empty approval" "0" "$(result)"
out=$(lint --lines 50 <<<'{"event": "APPROVE"}')
rc=$?
check "no commit_id" "1 commit" "$(result)"
out=$(lint --lines 50 <<<'{"commit_id": "abc", "event": "APPROVE", "body": null}')
rc=$?
check "a null body is empty" "0" "$(result)"

# --- wording: prose for the author -------------------------------------------------------
out=$(lint "$fixtures/posted-shorthand.json" --lines 40)
rc=$?
posted=$(result)
out=$(lint "$fixtures/right-shorthand.json" --lines 40)
rc=$?
check "a stub body beside one comment in skill shorthand trips each wording check; the rewrite passes" \
	"1 stub-body bare-id id-range cross-repo plain-ref jargon jargon glob long-sentence / 0" "$posted / $(result)"
# beside CONTROL TEXT: the result of CONTROL, which trips one check, and TEXT as the next comment
beside() {
	out=$(draft COMMENT "" "$1" "$2" | lint --lines 50)
	rc=$?
	result
}
# words N: N words, no full stop
words() {
	printf "%$(($1 - 1))s" "" | sed 's/ /word /g'
	printf 'end'
}
out=$(draft COMMENT "" "The failure is in job 6230398." | lint --lines 50)
rc=$?
check "bare-id: a job id in prose" "1 bare-id" "$(result)"
check "  says how to write it" 1 "$(grep -c '"6230398" is a bare number; write each job as its full URL' <<<"$out")"
out=$(draft COMMENT "" 'The failure is in `6230398`.' | lint --lines 50)
rc=$?
check "bare-id: a job id alone in a code span" "1 bare-id" "$(result)"
check "bare-id: a link, a URL, a version, a date, a setting, other code and a 5-digit number are not ids" "1 bare-id" \
	"$(beside "Job 6230398 fails." "[6230398](https://openqa.opensuse.org/tests/6230398), https://openqa.opensuse.org/tests/6230399, kernel 6.12.0-160000.38, snapshot 20261012, BUILD=1234567, \`sleep 1000000\`, 12345")"
check "bare-id: a number glued to a host or a user is not an id" "1 bare-id" \
	"$(beside "Job 6230398 fails." "Ping host:1234567 as user@1234567.")"
check "bare-id: a size or a duration with its unit is not an id" "1 bare-id" \
	"$(beside "Job 6230398 fails." "It takes ~0.6% of 2097148 kB, 2097148 MB, 2097148 GB, 2097148 KiB, 1234567 ms, 1234567% and 1234567 bytes.")"
check "bare-id: an id whose URL the same paragraph holds, in code or not, is not bare" "1 bare-id" \
	"$(beside "Job 6230398 fails." "Job 24800131 (https://openqa.opensuse.org/tests/24800131) fails, \`24800135\` (https://openqa.opensuse.org/tests/24800135) too.")"
check "bare-id: a [label] that a definition opening a paragraph resolves, and the definition, are not bare" "1 bare-id" \
	"$(beside "Job 6230398 fails." "$(printf 'Job [24800133] fails.\n\n[24800133]: https://openqa.opensuse.org/tests/24800133')")"
check "bare-id: the text of an HTML anchor is link text" "1 bare-id" \
	"$(beside "Job 6230398 fails." '<a href="https://openqa.opensuse.org/tests/latest?test=boot">job 24800132</a> fails.')"
check "bare-id: a [label] without a definition and one defined inside a paragraph are not links" "1 bare-id bare-id" \
	"$(beside "Job 6230398 fails." "$(printf 'Job [24800133] fails.\nnot defined:\n[24800133]: https://openqa.opensuse.org/tests/1')")"
out=$(draft COMMENT "" "Runs 5123456/57/58/59 pass." | lint --lines 50)
rc=$?
check "id-range: shortened job ids, reported once" "1 id-range" "$(result)"
out=$(draft COMMENT "" 'Jobs `5123456/57` pass.' | lint --lines 50)
rc=$?
check "id-range: shortened job ids alone in a code span" "1 id-range" "$(result)"
check "id-range: a path and a URL with ids are not ranges" "1 id-range" \
	"$(beside "Jobs 5123456/57 pass." "See data/1234567/1 and https://openqa.opensuse.org/tests/5123456/57.")"
out=$(draft COMMENT "" "This needs os-autoinst#3114 first." | lint --lines 50)
rc=$?
check "cross-repo: a repository without its owner" "1 cross-repo" "$(result)"
check "  says that GitHub resolves no repository from it" 1 \
	"$(grep -c '"os-autoinst#3114": GitHub resolves no repository from it; write owner/repo#<n>, or #<n> for this one' <<<"$out")"
check "cross-repo: owner/repo#n, #n, gh#owner/repo#n, a name GitHub cannot own, a tracker in a link and code are not" "1 cross-repo" \
	"$(beside "See os-autoinst#3114." "os-autoinst/os-autoinst#3114, #26918, gh#os-autoinst/openQA#5000, case foo_sh#27, [boo#1234](https://bugzilla.opensuse.org/show_bug.cgi?id=1234), \`foo#1\`")"
out=$(draft COMMENT "" "The soft-failure needs bsc#1234567, the feature jsc#PED-1234." | lint --lines 50)
rc=$?
check "plain-ref: bug and ticket references outside a link" "1 plain-ref" "$(result)"
check "  both of them" 1 "$(grep -c '"bsc#1234567" and 1 more stays plain text on GitHub; write it as a link' <<<"$out")"
check "plain-ref: a reference as link text, in code or as a URL is not plain" "1 plain-ref" \
	"$(beside "See poo#123456." "[bsc#1234567](https://bugzilla.suse.com/show_bug.cgi?id=1234567), \`record_soft_failure('poo#123456')\`, https://progress.opensuse.org/issues/123456")"
out=$(draft COMMENT "" "The VR at head passes." | lint --lines 50)
rc=$?
check "jargon: VR and at head, each with its own fix" "1 jargon jargon" "$(result)"
check "jargon: the words spelled out, code, vr-reach.py, VRAM, ahead and a heading are not" "1 jargon" \
	"$(beside "Please add a VR." "The verification run of the latest commit of this PR, \`4b81f19\`, passes; \`VR\`, vr-reach.py, VRAM, ahead and the heading stay.")"
out=$(draft COMMENT "" "$(words 31)." | lint --lines 50)
rc=$?
check "long-sentence: 31 words" "1 long-sentence" "$(result)"
check "long-sentence: 30 words, a code span as one word and a URL as none" "1 long-sentence" \
	"$(beside "$(words 31)." "$(words 29) \`a b c\` https://openqa.opensuse.org/tests/1. $(words 30)!")"
check "long-sentence: list items end a sentence" "1 long-sentence" \
	"$(beside "$(words 31)." "$(printf -- '- %s\n- %s' "$(words 20)" "$(words 20)")")"
out=$(draft COMMENT "" "$(words 30) \`a b c\`" | lint --lines 50)
rc=$?
check "long-sentence: 30 words and a code span" "1 long-sentence" "$(result)"
check "long-sentence: a line break ends a sentence, as GitHub keeps it" "1 long-sentence" \
	"$(beside "$(words 31)." "$(for _ in $(seq 11); do echo "SP7 x86_64 passed"; done)")"
for abbreviation in e.g. i.e. vs.; do
	out=$(draft COMMENT "" "$(words 15) $abbreviation $(words 15)." | lint --lines 50)
	rc=$?
	check "long-sentence: no sentence ends after $abbreviation" "1 long-sentence" "$(result)"
done
out=$(draft COMMENT "See inline." "fix it" | lint --lines 50)
rc=$?
check "stub-body: a body that only points at the comments" "1 stub-body" "$(result)"
stub=$(result)
out=$(draft COMMENT "One point inline; the aarch64 jobs also need a verification run." "fix it" | lint --lines 50)
rc=$?
check "stub-body: a body with a point of its own, beside the stub" "0 / 1 stub-body" "$(result) / $stub"
out=$(draft COMMENT "See inline." | lint --lines 50)
rc=$?
check "stub-body: not without inline comments, where the review would be left empty" "0" "$(result)"
for own in "Please add a comment explaining the sleep." "The new module needs a comment header."; do
	out=$(draft COMMENT "$own" "fix it" | lint --lines 50)
	rc=$?
	check "stub-body: a body that asks for a comment makes a point of its own: $own" "0" "$(result)"
done
out=$(draft COMMENT "" "The *_product_increment*.yaml schedules need it." | lint --lines 50)
rc=$?
check "glob: a glob in prose" "1 glob" "$(result)"
out=$(draft COMMENT "" "Wait 2*60 and 3*60 seconds." | lint --lines 50)
rc=$?
check "glob: a star between digits" "1 glob" "$(result)"
check "glob: a glob in code, bold, emphasis, a product, a list bullet and an escaped star are not" "1 glob" \
	"$(beside "Edit schedule/*.yaml too." "$(printf '`*_product_increment*.yaml`, **Note.** *really*, 2 * 3, tests/\\*.pm:\n* item')")"
check "fenced code, a suggestion and a quote are not prose" "1 jargon" \
	"$(beside "Please add a VR." "$(printf '> VR 6230398 at head\n\nAgreed.\n```suggestion\nmy $vr = 6230398;    # bsc#1 os-autoinst#3 *_x*\n```')")"

# --- hostile or broken input ------------------------------------------------------------
out=$(python3 -c '
import json
print(json.dumps({"commit_id": "0", "event": "COMMENT", "comments": [
    {"path": "a\u001b[31m\nINJECTED=1", "line": 1, "body": "x"},
    {"path": "\u200b" * 460 + "ghp_" + "B" * 36, "line": 2, "body": "x"}]}))' | lint --lines 5)
rc=$?
check "a hostile path stays on one clean line" "1 duplicate" "$(result)"
check "no escape, injected line or token reaches the output" "0 0 0" \
	"$(grep -c $'\e' <<<"$out") $(grep -c '^INJECTED' <<<"$out") $(grep -c 'ghp_B' <<<"$out")"
many=()
for _ in {1..45}; do many+=(x); done
out=$(draft COMMENT "" "${many[@]}" | lint --lines 5)
check "more than 40 findings are cut" "40 ... 5 more not shown" "$(grep -c '^  F ' <<<"$out") $(tail -n 1 <<<"$out" | sed 's/^ *//')"
for bad in 'not json' '[]' '{"body": "x"}' '{"event": "COMMENT", "body": 5}' '{"event": "COMMENT", "commit_id": 5}' \
	'{"event": "COMMENT", "comments": {}}' '{"event": "COMMENT", "comments": [{"path": "a", "line": 1}]}' \
	'{"event": "COMMENT", "comments": [{"path": "a", "line": 1, "body": "  "}]}' \
	'{"event": "COMMENT", "comments": [{"line": 1, "body": "x"}]}' \
	'{"event": "COMMENT", "comments": [{"path": "a", "body": "x"}]}' \
	'{"event": "COMMENT", "comments": [{"path": "a", "line": true, "body": "x"}]}'; do
	lint --lines 5 <<<"$bad" >/dev/null
	check "not a review exits 2: $bad" 2 $?
done
python3 -c 'print("[" * 100000)' | lint --lines 5 >"$work/out"
check "deep nesting exits 2 without a traceback" "2 0" "$? $(grep -c Traceback "$work/out")"
lint --lines -1 <<<'{"event": "APPROVE"}' >/dev/null
check "negative --lines exits 2" 2 $?
python3 -c 'print("{\"event\": \"APPROVE\"}" + " " * 270000)' | lint --lines 5 >/dev/null
check "an oversized draft on stdin exits 2" 2 $?
python3 -c 'print("{\"event\": \"APPROVE\"}" + " " * 270000)' >"$work/big.json"
check "an oversized FILE exits 2" "error: draft longer than 262144 characters" "$(lint "$work/big.json" --lines 5)"
# Reads stop at the cap: under a memory limit an uncapped read of 400 MB fails with MemoryError.
truncate -s 400M "$work/sparse.json"
out=$(ulimit -v 500000 && lint "$work/sparse.json" --lines 5)
check "a 400 MB FILE is read only up to the cap" "error: draft longer than 262144 characters" "$out"
out=$(ulimit -v 500000 && head -c 400M /dev/zero | lint --lines 5)
check "400 MB on stdin are read only up to the cap" "error: draft longer than 262144 characters" "$out"
printf '{"commit_id": "0", "event": "COMMENT", "body": "caf\xe9 \xff"}' >"$work/bytes.json"
out=$(lint "$work/bytes.json" --lines 5)
rc=$?
check "bytes that are not UTF-8 are read" "0 0" "$rc $(grep -c Traceback <<<"$out")"
check "'-' reads stdin like FILE" "$out" "$(lint - --lines 5 <"$work/bytes.json")"
lint "$fixtures" --lines 5 >/dev/null
check "a directory exits 2" 2 $?
mkfifo "$work/fifo"
check "a FIFO is refused instead of blocking" 'error: "fifo": not a regular file' "$(cd "$work" && timeout 10 python3 "$src" fifo --lines 5 2>&1)"
ln -s /dev/zero "$work/zero.json"
check "a device is refused" 'error: "zero.json": not a regular file' "$(cd "$work" && lint zero.json --lines 5)"
lint "$work/missing.json" --lines 5 >/dev/null
check "a missing file exits 2" 2 $?
out=$(lint "$work/"$'no\nsuch\e[31m.json' --lines 5)
check "a hostile file name stays on one line without escapes" "1 0" "$(wc -l <<<"$out") $(grep -c $'\e' <<<"$out")"

# Every wording pattern is linear: the largest draft the cap allows, each check firing on every line.
python3 - "$work/worst.json" <<'PY'
import json, sys
unit = "`x` [a](b) 1234567 5123456/57 os#1 bsc#1 jsc#A-1 VR at head *_a*.y " + "w " * 30 + "[(`` ```\n\nnit: c\n- d. e! f?\n"
unit += "[l] <a href=u>b</a> https://x/2097148 2097148 kB e.g. \\*.y <a x 1234567\n\n[l]: u\n[m]: v\n\n"
body = unit * (262144 // len(unit))
while len(json.dumps({"commit_id": "0", "event": "COMMENT", "body": body})) > 262144:
    body = body[: -len(unit)]
open(sys.argv[1], "w").write(json.dumps({"commit_id": "0", "event": "COMMENT", "body": body}))
PY
out=$(timeout 20 python3 "$src" "$work/worst.json" --lines 5 2>&1)
rc=$?
check "the largest draft the cap allows, each wording check firing on every line: done in time, each check reported once" \
	"1: bare-id id-range cross-repo plain-ref jargon jargon glob long-sentence" \
	"$rc: $(sed -n 's/^  F \(bare-id\|id-range\|cross-repo\|plain-ref\|jargon\|glob\|long-sentence\) .*/\1/p' <<<"$out" | paste -sd' ')"

exit $fail
