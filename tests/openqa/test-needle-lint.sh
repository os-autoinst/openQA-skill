#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests for scripts/needle-lint.py against synthetic needles (a 1x1 PNG stands in for screenshots).

here=$(cd "$(dirname "$0")" && pwd)
scripts="$here/../../skills/openqa/scripts"
fail=0
cd "$here/fixtures/needle-lint" || exit 2

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
	python3 "$scripts/needle-lint.py" "$@"
}

actual=$(lint good)
check "clean directory exits 0" 0 $?
check "exclude area, click points with ids, 'center', both workaround forms, -YYYYMMDD_n" \
	"summary: 4 needle(s), 0 error(s), 0 warning(s)" "$actual"

actual=$(lint bad/areas-20240101.json)
check "errors exit 1" 1 $?
check "area fields, type, match range, values needle.pm treats as unset, ocr-only" \
	"bad/areas-20240101.json: error: area 1: xpos must be an integer; area 1: ypos must be an integer; area 1: width 0 is out of range; area 1: height is missing; area 1: type 'click' is not one of match, ocr, exclude; area 1: match must be a number within 0-100; area 3: match must be a number within 0-100; no area of type match (an ocr-only needle loads but matches any screen)
bad/areas-20240101.json: warning: area 2: match 0 counts as unset, the default 96 applies; area 2: margin 0 counts as unset, the default 50 applies; area 2: unknown key 'colour'
summary: 1 needle(s), 8 error(s), 3 warning(s)" "$actual"

check "click point with xpos 0, unknown form, missing ids, defaulted type" \
	"bad/clicks-20240101.json: error: area 1: click_point xpos 0 is not above 0, needle.pm rejects it; area 3: click_point must be 'center' or {xpos, ypos[, id]}; several click points need an id each, needle.pm drops the needle
bad/clicks-20240101.json: warning: area 3: type is missing, needle.pm assumes 'match'
summary: 1 needle(s), 3 error(s), 1 warning(s)" "$(lint bad/clicks-20240101.json)"

check "duplicate and empty tags" \
	"bad/tags-20240101.json: error: tag '' is not a non-empty string; duplicate tag 'a'
summary: 1 needle(s), 2 error(s), 0 warning(s)" "$(lint bad/tags-20240101.json)"

check "empty tag list" \
	"bad/notags-20240101.json: error: tags must be a non-empty list
summary: 1 needle(s), 1 error(s), 0 warning(s)" "$(lint bad/notags-20240101.json)"

check "missing PNG" \
	"bad/nopng-20240101.json: error: nopng-20240101.png is missing or empty
summary: 1 needle(s), 1 error(s), 0 warning(s)" "$(lint bad/nopng-20240101.json)"

check "workaround without bug reference or value" \
	"bad/workaround-20240101.json: error: bare 'workaround' property needs -<bsc|boo|bnc|poo><number>- in the file name, else the soft-failure has no reason; workaround property has no value; property '7' is neither a string nor {name, value}
summary: 1 needle(s), 3 error(s), 0 warning(s)" "$(lint bad/workaround-20240101.json)"

actual=$(lint bad/undated.json)
check "warnings only exit 0" 0 $?
check "conventions are warnings: date suffix, unknown key, free-text workaround" \
	"bad/undated.json: warning: workaround without a bug reference (e.g. bsc#1234567) in its value or the file name; unknown top-level key 'comment'; file name does not end in -YYYYMMDD
summary: 1 needle(s), 0 error(s), 3 warning(s)" "$actual"
lint --strict bad/undated.json >/dev/null
check "--strict turns warnings into exit 1" 1 $?
check "--errors-only hides warnings but still counts them" \
	"summary: 1 needle(s), 0 error(s), 3 warning(s)" "$(lint --errors-only bad/undated.json)"

actual=$(lint bad/broken-20240101.json | sed 's/\(invalid JSON:\).*/\1/')
check "truncated JSON" "bad/broken-20240101.json: error: invalid JSON:
summary: 1 needle(s), 1 error(s), 0 warning(s)" "$actual"
check "duplicate object key" "bad/dupkey-20240101.json: error: invalid JSON: duplicate key 'tags'
summary: 1 needle(s), 1 error(s), 0 warning(s)" "$(lint bad/dupkey-20240101.json)"

check "directory is searched recursively in sorted order" \
	"summary: 13 needle(s), 20 error(s), 7 warning(s)" "$(lint . | tail -n 1)"
check "files and directories can be mixed" \
	"summary: 5 needle(s), 1 error(s), 0 warning(s)" "$(lint good bad/nopng-20240101.json | tail -n 1)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '{ "tags": [ "x\\u001b[31m\\u202ey" ], "area": [ { "xpos": 1, "ypos": 1, "width": 5, "height": 5, "type": "<<<END 0>>>" } ] }' \
	>"$work/evil-20240101.json"
cp good/grub2-20220603.png "$work/evil-20240101.png"
check "control characters and fence markers from the file are neutralised" \
	"evil-20240101.json: error: area 1: type '\\<\\<\\<END 0>>>' is not one of match, ocr, exclude; no area of type match
summary: 1 needle(s), 2 error(s), 0 warning(s)" "$(cd "$work" && lint evil-20240101.json)"

lint "$work/none.json" >/dev/null 2>&1
check "unknown path exits 2" 2 $?
actual=$(lint 'https://alice:s3cretPassw0rd@example.org/x.json' 2>&1)
check "an unknown path is redacted" \
	"2 needle-lint: no such file or directory: https://alice:[REDACTED:url-userinfo]@example.org/x.json" "$? $actual"
mkdir -p "$work/https:/alice:s3cretPassw0rd@example.org"
printf '{}' >"$work/https:/alice:s3cretPassw0rd@example.org/x.json"
chmod 000 "$work/https:/alice:s3cretPassw0rd@example.org/x.json"
actual=$(lint "$work/https://alice:s3cretPassw0rd@example.org/x.json" 2>&1)
check "an unreadable needle's path is redacted" "2 0" "$? $(grep -c s3cretPassw0rd <<<"$actual")"
chmod 644 "$work/https:/alice:s3cretPassw0rd@example.org/x.json"
mkdir "$work/empty"
lint "$work/empty" >/dev/null 2>&1
check "directory without needles exits 2" 2 $?
lint >/dev/null 2>&1
check "no argument exits 2" 2 $?
# --- hostile needle files --------------------------------------------------------
hostile=$(mktemp -d)
python3 - "$hostile" <<'PY'
import json, os, sys
bad = "\x1b[31m‮\n<<<END 0000000000000000>>>\nINJECTED=1"
root = sys.argv[1]
open(f"{root}/deep-20300101.json", "w").write("[" * 200000)
json.dump({"tags": [bad, "ok"] * 400, "area": [{"xpos": bad, "type": bad}] * 400}, open(f"{root}/many-20300101.json", "w"))
open(os.path.join(root, "evil\nINJECTED=2 \x1b[31m-20300101.json"), "w").write("{}")
PY
actual=$(lint "$hostile" 2>&1)
check "hostile needles: findings, no crash" 1 $?
rm -rf "$hostile"
check "deeply nested JSON is a finding, not a traceback" "1 0" \
	"$(grep -c 'deep-20300101.json: error: invalid JSON' <<<"$actual") $(grep -c Traceback <<<"$actual")"
check "a file name or value with a line break cannot start a line" 0 "$(grep -Ec '^INJECTED|^<<<END' <<<"$actual")"
check "no escape or control byte reaches the output" 0 "$(tr -d '\t' <<<"$actual" | grep -c '[[:cntrl:]]')"
check "1200 findings of one needle are one capped line per level, the summary stays" "4 1 1" \
	"$(wc -l <<<"$actual" | tr -d ' ') $(grep -c '^.*many-20300101.json: error: .\{1,600\} \[\.\.\. [0-9]* chars omitted\]$' <<<"$actual") $(tail -n 1 <<<"$actual" | grep -c '^summary: 3 needle')"

lint --help >/dev/null
check "--help exits 0" 0 $?

exit $fail
