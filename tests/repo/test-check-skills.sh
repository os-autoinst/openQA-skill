#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Proves the checks of check-skills.py can fail: each case changes one thing in a
# throw-away copy of the repository and expects the check to report it, or not to.
# The backticks and $VAR in the planted text are Markdown, not shell expansion.
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

fresh() {
	rm -rf "$work/repo"
	mkdir -p "$work/repo/tests/repo"
	cp -r "$root/skills" "$work/repo/"
	cp "$here/check-skills.py" "$work/repo/tests/repo/"
	skill=$work/repo/skills/openqa
}
gate() { timeout 20 python3 "$work/repo/tests/repo/check-skills.py" --only "$1"; }
# finds NAME CHECK TEXT: the gate exits 1 and CHECK reports a finding that contains TEXT
finds() {
	local out rc
	out=$(gate "$2")
	rc=$?
	check "$1" "1 1" "$rc $(grep "^$2: " <<<"$out" | grep -c -F -- "$3" | sed 's/^[1-9][0-9]*$/1/')"
}
filler() { head -c "$1" /dev/zero | tr '\0' x | fold -w 100; }

# plant NAME EXPECTED LINE [FILE]: add LINE to FILE (default a reference) of a clean copy, run the check
plant() {
	fresh
	printf '%s\n' "$3" >>"$skill/${4:-references/redaction.md}"
	out=$(timeout 10 python3 "$work/repo/tests/repo/check-skills.py" --only credentials)
	[ $? -ne 124 ] || out="credentials: -: timed out: "
	check "$1" "$2" "$(sed -n 's/^credentials: [^ ]*: \([^:]*\):.*/\1/p' <<<"$out" | head -1)"
}

plant "the clean tree passes" "" "Credentials stay inside the tools."
# The public-content patterns, tested on host names built at run time so this file passes them.
# Slack's webhook host stays flagged too (its path is a credential); only test-_secrets.sh may name it.
check "a Slack workspace and the webhook host are internal services" "1 1" "$(
	python3 - "$here/check-skills.py" <<'EOF'
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("check_skills", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
pattern = next(re.compile(p) for p, label in module.PUBLIC_PATTERNS if label == "internal service")
host = "slack" + ".com"
print(*(int(bool(pattern.search(url))) for url in ("https://example." + host + "/archives", "https://hooks." + host + "/services/x")))
EOF
)"

plant "reading client.conf" "reads a credential file" 'Run `grep key ~/.config/openqa/client.conf` to see the key.'
plant "reading gh hosts.yml" "reads a credential file" '    cat ~/.config/gh/hosts.yml'
plant "reading client.conf with sudo" "reads a credential file" '    sudo cat /etc/openqa/client.conf'
plant "reading it with python open()" "reads a credential file" '    with open(os.path.expanduser("~/.config/openqa/client.conf")) as f:'
plant "reading it with configparser" "reads a credential file" '    cfg.read("/usr/etc/openqa/client.conf.d/o3.conf")'
plant "reading it with perl" "reads a credential file" "    perl -ne 'print if /secret/' ~/.config/openqa/client.conf"
plant "reading .git-credentials" "reads a credential file" '`cat ~/.git-credentials`'
plant "searching a config directory" "reads a credential file" '    grep -r key /etc/openqa/'
plant "encoding .netrc after &&" "reads a credential file" 'cd ~ && base64 .netrc'
plant "reading in a command substitution" "reads a credential file" 'KEY=$(grep key ~/.config/openqa/client.conf)'
plant "prose naming read commands passes" "" 'Never cat, grep, source or head client.conf; read more about hosts.yml in the tail of this file.'
plant "a command and a file in separate spans pass" "" 'Use `grep` or `less` on logs, never on `client.conf`.'
plant "a warning that names the files passes" "" 'Never read `client.conf`, `hosts.yml` or `gh auth token` output.'
plant "naming open() and read() passes" "" 'Both open() and configparser.read() refuse `client.conf` here.'

plant "piping out gh's token" "prints gh's token" 'curl -H "Authorization: token $(gh auth token)" https://api.github.com'
plant "gh auth token on a code line" "prints gh's token" '    gh auth token'
plant "gh auth token in backticks" "prints gh's token" 'export GITHUB_TOKEN=`gh auth token`'
plant "gh auth token piped in a span" "prints gh's token" '`gh auth token | wl-copy`'
plant "gh auth status -t" "prints gh's token" '    gh auth status -t'
plant "gh auth status with combined flags" "prints gh's token" '`gh auth status -at | grep Token`'
plant "gh auth status --show-token" "prints gh's token" '    gh auth status --hostname github.com --show-token'
plant "a table cell naming gh auth token passes" "" '| gh auth token | denied |'
plant "a span naming gh auth status -t passes" "" '`gh auth status -t` and `--show-token` are denied.'

plant "a key on the command line" "passes a key on the command line" 'openqa-cli api --apikey 0123456789ABCDEF jobs'
plant "a slot for the key is still a key" "passes a key on the command line" 'openqa-cli api --apikey <key> --apisecret $SECRET jobs'
plant "a variable for the key is still a key" "passes a key on the command line" 'openqa-cli api --apisecret "$OPENQA_API_SECRET" jobs'
plant "prose naming the flags passes" "" 'openqa-cli takes --apikey and --apisecret; never use them.'

plant "a concrete auth header" "a concrete auth header value" "curl -H 'Authorization: Bearer abcdef0123456789' https://x.example.org"
plant "a token variable in a header" "a concrete auth header value" 'curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com'
plant "a tracker API key header" "a concrete auth header value" "curl -H 'X-Redmine-API-Key: 0123456789abcdef0123456789abcdef' https://x.example.org"
plant "an X-Auth-Token header" "a concrete auth header value" 'curl -H "X-Auth-Token: ${TOKEN}" https://x.example.org'
plant "a PRIVATE-TOKEN header" "a concrete auth header value" 'curl -H "PRIVATE-TOKEN: 0123456789abcdefABCD01" https://x.example.org'
plant "describing a header passes" "" 'openQA signs with `X-API-Key: <key>` and `X-API-Hash: HMAC-SHA1`; `Authorization: Negotiate` carries no key.'

plant "a password in a URL" "a password in a URL" 'git clone https://bob:hunter2hunter2@git.example.org/r'
plant "a token variable as the password" "a password in a URL" 'git clone https://oauth2:$GITHUB_TOKEN@github.com/o/r'
plant "a redacted example passes" "" '`https://alice:[REDACTED:url-userinfo]@host/`'
plant "a port or an ssh remote passes" "" 'git@github.com:o/r.git and https://host:8080/p@x'

plant "a token as the whole userinfo" "a token in a URL" 'git clone https://ghp_0123456789abcdefghijABCDEFGHIJ0123@github.com/o/r'
plant "a token variable as the userinfo" "a token in a URL" 'git clone https://$GITHUB_TOKEN@github.com/o/r'
plant "an api_key query value" "a token in a URL" 'curl "https://bugzilla.example.org/rest/bug?api_key=0123456789abcdefABCD"'
plant "a key query value" "a token in a URL" 'curl "https://x.example.org/api?format=json&key=0123456789ABCDEF"'
plant "a setting name as key passes" "" 'GET /api/v1/job_settings/jobs?key=*_TEST_ISSUES or ?key=PUBLIC_CLOUD_IMAGE_LOCATION'
plant "a user name in a URL passes" "" 'https://bob@git.example.org/r and https://$USER@host/'

plant "echoing a token variable" "prints the environment or a token variable" '    echo "$GITHUB_TOKEN"'
plant "printenv of a key variable" "prints the environment or a token variable" '`printenv OPENQA_API_KEY`'
plant "printf of a secret variable" "prints the environment or a token variable" 'printf %s "${OPENQA_API_SECRET}" | wl-copy'
plant "env piped to grep" "prints the environment or a token variable" '    env | grep TOKEN'
plant "prose naming echo and env passes" "" 'Never echo `$GITHUB_TOKEN`, run `printenv` or pipe env | grep in an example.'

plant "MOJO_CLIENT_DEBUG before a command" "turns on MOJO_CLIENT_DEBUG" 'MOJO_CLIENT_DEBUG=1 openqa-cli api jobs'
plant "naming MOJO_CLIENT_DEBUG passes" "" 'No `MOJO_CLIENT_DEBUG` (prints auth headers); `env MOJO_CLIENT_DEBUG=1` is denied.'

# command starts after ; and ||, and sudo with options
plant "a read after a semicolon" "reads a credential file" '    cd ~; cat .netrc'
plant "a read after ||" "reads a credential file" '    test -f x || cat ~/.netrc'
plant "sudo with options" "reads a credential file" '    sudo -u geekotest cat /etc/openqa/client.conf'
plant "exporting MOJO_CLIENT_DEBUG" "turns on MOJO_CLIENT_DEBUG" '    export MOJO_CLIENT_DEBUG=1'
plant "exporting it off passes" "" '    export MOJO_CLIENT_DEBUG=0'

# shipped scripts are checked too
plant "a read in a script" "reads a credential file" '    cat ~/.config/openqa/client.conf' scripts/oqa-job.py

# quoted arguments, redirects, pathlib and more files
plant "a quoted alternation before the file" "reads a credential file" "    grep -E 'key|secret' ~/.config/openqa/client.conf"
plant "an awk program before the file" "reads a credential file" "    awk -F' = ' '/^key/ {print \$2; exit}' ~/.config/openqa/client.conf"
plant "a redirect in a command substitution" "reads a credential file" 'KEY=$(< ~/.config/openqa/client.conf)'
plant "open() of a pathlib expression" "reads a credential file" '    with open(Path.home() / ".config/openqa/client.conf") as f:'
plant "pathlib read_text()" "reads a credential file" '    Path("~/.config/openqa/client.conf").expanduser().read_text()'
plant "git's credential store under .config" "reads a credential file" '    cat ~/.config/git/credentials'
plant "the environment of a process" "reads a credential file" '    cat /proc/self/environ'
plant "a slot before a path passes" "" 'The packaged default is <prefix>/etc/openqa/client.conf.'

# gh auth token behind a prefix
plant "gh auth token after an assignment" "prints gh's token" '    GH_HOST=github.com gh auth token'
plant "gh auth token after &&" "prints gh's token" '    cd repo && gh auth token'
plant "gh auth token with flags, piped" "prints gh's token" 'Run `gh auth token -h github.com | wl-copy`'
plant "a table cell naming gh auth token with flags passes" "" '| `gh auth token -h github.com` | denied |'

# environment dumps
plant "a bare printenv" "prints the environment or a token variable" '    printenv'
plant "a bare env" "prints the environment or a token variable" '    env'
plant "export -p" "prints the environment or a token variable" '    $ export -p'
plant "env running a command passes" "" '    env LC_ALL=C sort names.txt'

# prose naming the key flags
plant "a flag followed by a word passes" "" 'Never pass --apikey because it lands in the shell history.'
plant "a flag followed by a noun passes" "" 'openqa-cli has --apikey/--apisecret options; never use either.'
plant "--api-key followed by a noun passes" "" 'The old --api-key option is gone.'

# tokens in a URL
plant "a PAT variable as the userinfo" "a token in a URL" 'git clone https://$GH_PAT@github.com/o/r'
plant "a token query value" "a token in a URL" 'curl "https://x.example.org/repos/o/r?token=0123456789abcdef0123"'
plant "an access_token query value" "a token in a URL" 'curl "https://x.example.org/api?format=json&access_token=0123456789abcdef0123"'
plant "a word ending in PAT passes" "" '    echo "$COMPAT"'

# 60 sudo options must not backtrack exponentially
plant "sudo with 60 options stays linear" "" "    sudo$(printf ' -u%.0s' {1..60}) x"

# tools that print their own secrets
plant "piping into git credential fill" "runs a credential printer" "    printf 'protocol=https\nhost=github.com\n\n' | git credential fill"
plant "secret-tool lookup" "runs a credential printer" '    secret-tool lookup service osc'
plant "gh auth git-credential" "runs a credential printer" '    gh auth git-credential get'
plant "osc config --dump-full in a span" "runs a credential printer" '`osc config --dump-full | grep pass`'
plant "osc token in a substitution" "runs a credential printer" '    echo "$(osc token)"'
plant "curl -u with a password" "passes a key on the command line" 'curl -u bob:hunter2hunter2 https://x.example.org'
plant "curl --oauth2-bearer" "passes a key on the command line" 'curl --oauth2-bearer "$GITHUB_TOKEN" https://x.example.org'
plant "prose naming the printers passes" "" 'The harness denies `git credential fill`, `secret-tool lookup`, `osc token` and `osc config --dump-full`.'
plant "a table row naming a printer passes" "" '| git credential fill | denied |'
plant "curl -u without a password passes" "" 'curl --negotiate -u : https://x.example.org'

# pin behaviour that no other plant covers
plant "a lower-case HTTP/2 header" "a concrete auth header value" '< authorization: Bearer 0123456789abcdef0123'
plant "another file in the config directory passes" "" '    cat /etc/openqa/workers.ini'
plant "a read after a prompt" "reads a credential file" '    $ cat ~/.netrc'
plant "declare -x MOJO_CLIENT_DEBUG" "turns on MOJO_CLIENT_DEBUG" '    declare -x MOJO_CLIENT_DEBUG=1'
plant "MOJO_CLIENT_DEBUG=0 before a command passes" "" 'MOJO_CLIENT_DEBUG=0 openqa-cli api jobs'

fresh
out=$(gate frontmatter,budget,pointers)
check "a clean copy passes frontmatter, budget and pointers" "0 ok - all repository checks pass" "$? $out"
# The gate imports the skill's scripts; python would cache them next to the files it checks.
find "$work/repo" -name __pycache__ -prune -exec rm -rf {} +
PYTHONDONTWRITEBYTECODE='' gate budget,pointers >/dev/null
check "the gate leaves no cache in the tree it checks" "" "$(find "$work/repo" -name __pycache__)"

fresh
sed -i 's/^license: .*/&\nversion: 1/' "$skill/SKILL.md"
finds "frontmatter: a key outside the specification" frontmatter "key 'version'"
fresh
sed -i 's/^name: .*/name: open_qa/' "$skill/SKILL.md"
finds "frontmatter: a name that is not the directory name" frontmatter "differs from directory"
fresh
sed -i "s/^license: /  $(filler 40)\n&/" "$skill/SKILL.md"
finds "frontmatter: a description over 1024 characters" frontmatter "description must be 1-1024"
fresh
sed -i '2,$s/^---$/--/' "$skill/SKILL.md"
finds "frontmatter: a frontmatter that is never closed" frontmatter "missing frontmatter"

# Sizes are bytes of what one read returns: a section as refsection.py cuts it, or a whole file.
ref=references/redaction.md
# line HEADING: where the reference has that heading in the clean tree
line() { grep -n -x -F -- "$1" "$root/skills/openqa/$ref" | cut -d: -f1; }
fresh
printf 'caf\303\251\n' >>"$skill/$ref" # one character of two bytes
filler 5200 >>"$skill/$ref"
finds "budget: a section over the section cap" budget \
	"redaction.md:$(line '## Before you post'): section \"Before you post\" is"
listed=$(python3 "$skill/scripts/refsection.py" --list redaction.md | awk '/## Before you post$/ { print $1 }')
check "budget: the size is the one refsection.py --list prints" 1 \
	"$(gate budget | grep -c -F "section \"Before you post\" is $listed bytes")"
fresh
printf '\n### Part\n' >>"$skill/$ref"
filler 5200 >>"$skill/$ref"
finds "budget: a ### part counts toward its ## section" budget 'section "Before you post" is'
fresh
{
	printf '# Deep\n\n### Part\n'
	filler 5200
} >"$skill/references/deep.md"
finds "budget: a ### part outside any ## section is capped too" budget 'deep.md:3: section "Part" is'
fresh
printf '\n## What it is not\n' >>"$skill/$ref"
filler 5200 >>"$skill/$ref"
finds "budget: a section that repeats a title is measured too" budget \
	"redaction.md:$(($(wc -l <"$root/skills/openqa/$ref") + 2)): section \"What it is not\" is"
# sized BYTES: a clean copy whose reference ends in a section of exactly BYTES
sized() {
	fresh
	printf '\n## Sized\n' >>"$skill/$ref"
	head -c $(($1 - 10)) /dev/zero | tr '\0' x >>"$skill/$ref" # the heading line is 9, the last newline 1
}
sized 5000
check "budget: a section exactly at the section cap passes" "ok - all repository checks pass" "$(gate budget)"
sized 5001
finds "budget: one byte over the section cap, and by how much" budget \
	'section "Sized" is 5001 bytes, 1 over the section cap 5000'
# whole BYTES: a clean copy with a new reference of exactly BYTES, each section under its cap
whole() {
	fresh
	{
		printf '# Whole\n'
		for n in 1 2 3 4; do
			printf '\n## Part %s\n' "$n"
			filler 4000
		done
		head -c $(($1 - 16208)) /dev/zero | tr '\0' x # 8 for the title, 4050 for each part so far
	} >"$skill/references/whole.md"
}
whole 17000
check "budget: a reference exactly at the file cap passes" "ok - all repository checks pass" "$(gate budget)"
whole 17001
check "budget: a reference over the file cap" \
	"budget: skills/openqa/references/whole.md: 17001 bytes exceeds cap 17000 by 1" "$(gate budget)"
fresh
filler 200 >>"$skill/references/untrusted-content.md"
finds "budget: the reference read whole keeps its own cap" budget "untrusted-content.md: "
fresh
filler 1500 >>"$skill/agents/pr-preflight.md"
finds "budget: a playbook over its cap" budget "agents/pr-preflight.md: "
# bodied BYTES LINES: a clean copy whose SKILL.md keeps its frontmatter and has a body of BYTES in LINES lines
bodied() {
	fresh
	sed -n '1,/^---$/p' "$root/skills/openqa/SKILL.md" >"$skill/SKILL.md"
	{
		head -c $(($1 - $2)) /dev/zero | tr '\0' x
		yes '' | head -n "$2"
	} >>"$skill/SKILL.md"
}
bodied 12700 1
check "budget: a SKILL.md body exactly at its cap passes, whatever the frontmatter adds" \
	"ok - all repository checks pass" "$(gate budget)"
over="budget: skills/openqa/SKILL.md: body of 12701 bytes exceeds cap 12700 by 1"
bodied 12701 1
check "budget: a SKILL.md body one byte over its cap" "$over" "$(gate budget)"
bodied 12600 1
printf -- '---\n%096d\n' 0 >>"$skill/SKILL.md"
check "budget: a rule inside the body does not end the count" "$over" "$(gate budget)"
awk '/^---$/ && ++n == 2 { $0 = "--- " } 1' "$skill/SKILL.md" >"$work/SKILL.md"
mv "$work/SKILL.md" "$skill/SKILL.md"
check "budget: nor does the count start there when the closing line of the frontmatter has a trailing space" \
	"$over" "$(gate budget)"
fresh
{
	head -c 12696 /dev/zero | tr '\0' x
	printf '\n---\n'
} >"$skill/SKILL.md"
check "budget: a SKILL.md without frontmatter is all body, a rule in it included" "$over" "$(gate budget)"
bodied 1 1
yes "$(printf '\303\251')" | head -n 6350 | tr -d '\n' >>"$skill/SKILL.md"
check "budget: the body is counted in bytes, not characters" "$over" "$(gate budget)"
bodied 12700 2
sed -i 's/$/\r/' "$skill/SKILL.md"
check "budget: the carriage returns of a CRLF body count" \
	"budget: skills/openqa/SKILL.md: body of 12702 bytes exceeds cap 12700 by 2" "$(gate budget)"
fresh
sed -i "s/^license: .*/&\nmetadata: $(filler 5000 | tr -d '\n')/" "$skill/SKILL.md"
check "budget: the frontmatter of SKILL.md is not counted, even past the cap of a file" \
	"ok - all repository checks pass" "$(gate budget)"
front=$(sed -n '1,/^---$/p' "$root/skills/openqa/SKILL.md" | wc -l)
lines="budget: skills/openqa/SKILL.md: 500 lines exceeds cap 499 by 1"
bodied 600 $((499 - front))
check "budget: a SKILL.md of 499 lines passes" "ok - all repository checks pass" "$(gate budget)"
printf x >>"$skill/SKILL.md"
check "budget: a last line without a newline is a line" "$lines" "$(gate budget)"
bodied 600 $((500 - front))
check "budget: a SKILL.md of 500 lines, frontmatter included" "$lines" "$(gate budget)"

# add LINE... to FILE of a clean copy
add() {
	fresh
	local file=$1
	shift
	printf '%s\n' "$@" >>"$skill/$file"
}
add "$ref" '-> testapi.md "No such section"'
finds "pointers: a section that does not exist" pointers "'testapi.md' has no section \"No such section\""
add agents/job-triage.md '-> nosuch.md "Traps"'
finds "pointers: a file that does not exist" pointers "no such file 'nosuch.md'"
add "$ref" '-> references/SKILL.md "Write gate"'
finds "pointers: references/ names a reference only" pointers "no such file 'references/SKILL.md'"
add "$ref" '-> docs/testapi.md "Traps"'
finds "pointers: a file is the whole path as written" pointers "no such file 'docs/testapi.md'"
add "$ref" 'As testapi.md "No such section" says.'
finds "pointers: a pointer without an arrow is resolved" pointers "'testapi.md' has no section \"No such section\""
add SKILL.md '-> testapi.md "Traps", module-templates.md "Common shape", scheduling.md "Nope"'
finds "pointers: the third file of a chain is resolved" pointers "'scheduling.md' has no section \"Nope\""
add agents/test-author.md '-> module-templates.md "Console smoke test" / "Nope"'
finds "pointers: a title after a slash is resolved" pointers "'module-templates.md' has no section \"Nope\""
add "$ref" '-> "Nope"'
finds "pointers: a same-file pointer is resolved" pointers "'redaction.md' has no section \"Nope\""
add "$ref" '-> "What it is not" / "Nope"'
finds "pointers: a same-file title after a slash is resolved" pointers "'redaction.md' has no section \"Nope\""
add "$ref" '-> "What it is not"' '```' '-> nosuch.md "X"' '## What it is not' '```'
check "pointers: a same-file pointer that resolves, and fenced text, pass" \
	"ok - all repository checks pass" "$(gate pointers)"
add agents/job-triage.md '-> "Rules"'
finds "pointers: a playbook pointer without its file" pointers "needs its file"
add "$ref" '-> testapi.md "Traps" and "Hook order"'
finds "pointers: a section title left outside the pointer" pointers '"Hook order" is a section of'
add "$ref" '-> testapi.md "Traps" and "Before you post"'
finds "pointers: a title of the line's own file left outside the pointer" pointers \
	"\"Before you post\" is a section of 'redaction.md'"
add "$ref" '-> testapi.md "os-autoinst test API"'
finds "pointers: a pointer to a whole file" pointers "is the whole of 'testapi.md'"
add "$ref" '## what it is NOT' '-> "Before you post"'
finds "pointers: a title that repeats another, whatever the case" pointers \
	"repeats line $(line '## What it is not')"
add SKILL.md '## reading this skill'
printf '## SCRIPTS\n' >>"$skill/scripts/README.md"
out=$(gate pointers)
check "pointers: a repeated title in SKILL.md and in scripts/README.md" "1 1" \
	"$(grep -c '/SKILL.md:.* repeats line' <<<"$out") $(grep -c '/scripts/README.md:.* repeats line 1$' <<<"$out")"
add "$ref" '## notes.md'
finds "pointers: a title that refsection.py would read as a file" pointers 'heading "notes.md" ends in .md'
add SKILL.md '`scripts/missing-script.py`'
finds "pointers: a script SKILL.md names but does not ship" pointers "script 'missing-script.py' does not exist"
# refsection.py reads scripts/README.md too, and finds a script's notes by the script's name
add SKILL.md '-> scripts/README.md "refsection.py", "oqa-job.py - one job, ready to classify"'
check "pointers: the clean tree resolves, scripts/README.md included" \
	"ok - all repository checks pass" "$(gate pointers)"
add SKILL.md '-> scripts/README.md "nosuch.py"'
finds "pointers: a section scripts/README.md does not have" pointers "'scripts/README.md' has no section \"nosuch.py\""
add SKILL.md '-> README.md "refsection.py"'
finds "pointers: scripts/README.md is named with its directory" pointers "no such file 'README.md'"
add SKILL.md '-> scripts/README.md "refsection.py"'
printf '## Refsection.py --list - the outline\n' >>"$skill/scripts/README.md"
finds "pointers: a script name that two sections of scripts/README.md start with, whatever the case" pointers \
	"'scripts/README.md' has no section \"refsection.py\""

# An agent starts at SKILL.md or a playbook: a file that neither names is never opened.
# orphan: a clean copy with a new reference that only another reference points to
orphan() {
	fresh
	printf '# Orphan\n\n## One\n\n-> "Two"\n\n## Two\n\nText.\n' >"$skill/references/orphan.md"
	printf '%s\n' '-> orphan.md "One"' >>"$skill/$ref"
}
unnamed="references/orphan.md: neither SKILL.md nor a playbook points here"
orphan
finds "pointers: a reference only another reference points to" pointers "$unnamed"
orphan
printf '%s\n' '-> orphan.md "One"' >>"$skill/agents/job-triage.md"
check "pointers: a playbook names a reference" "ok - all repository checks pass" "$(gate pointers)"
orphan
printf '%s\n' 'Read `references/orphan.md` in full.' >>"$skill/SKILL.md"
check "pointers: a reference read whole is named by its path, with references/ too" \
	"ok - all repository checks pass" "$(gate pointers)"
orphan
printf '%s\n' 'Keep `orphan.md.bak`, `orphan.md5` and `references/orphan.md-old`.' >>"$skill/SKILL.md"
finds "pointers: a longer file name does not name the reference" pointers "$unnamed"
orphan
printf '%s\n' '```' 'python3 scripts/refsection.py orphan.md "One"' '```' >>"$skill/SKILL.md"
finds "pointers: a name inside a code fence names nothing" pointers "$unnamed"
orphan
cp "$skill/agents/job-triage.md" "$skill/agents/orphan.md"
printf '%s\n' 'Playbook `agents/orphan.md`.' >>"$skill/SKILL.md"
check "pointers: a playbook's path names the playbook, not the reference of that name" \
	"pointers: skills/openqa/$unnamed" "$(gate pointers)"
unnamed="agents/orphan.md: neither SKILL.md nor a reference names this playbook"
fresh
cp "$skill/agents/job-triage.md" "$skill/agents/orphan.md"
finds "pointers: a playbook nothing names" pointers "$unnamed"
printf '%s\n' 'Then hand over `agents/orphan.md`.' >>"$skill/agents/group-review.md"
finds "pointers: a playbook only another playbook names" pointers "$unnamed"
printf '%s\n' 'Playbook `orphan.md`.' >>"$skill/SKILL.md"
finds "pointers: a playbook is named by its agents/ path only" pointers "$unnamed"
printf '%s\n' 'Playbook `agents/orphan.md`.' >>"$skill/$ref"
check "pointers: a reference names a playbook" "ok - all repository checks pass" "$(gate pointers)"

# A "## " section of a reference needs a chain of pointers that starts in SKILL.md, a playbook
# or the reference read whole, or an entry in UNROUTED.
last=$(wc -l <"$root/skills/openqa/$ref")
unreached() { printf 'no pointer reaches section "%s": point to it, or list it in UNROUTED' "$1"; }
add "$ref" '## New topic'
finds "pointers: a new section no pointer reaches" pointers "redaction.md:$((last + 1)): $(unreached 'New topic')"
add "$ref" '## New topic' '-> "New topic", redaction.md "New topic", references/redaction.md "New topic"'
finds "pointers: a section that points only at itself is not reached" pointers "$(unreached 'New topic')"
add "$ref" '-> "Same file"' '## Same file' '## Bare name' '## With directory'
printf '%s\n' '-> redaction.md "Bare name"' >>"$skill/agents/job-triage.md"
printf '%s\n' '-> references/redaction.md "With directory"' >>"$skill/SKILL.md"
check "pointers: the last line of a section, a playbook and SKILL.md reach, by either spelling of the file" \
	"ok - all repository checks pass" "$(gate pointers)"
add "$ref" '## One' '-> "Two"' '## Two' '-> "One"'
check "pointers: two sections that point only at each other are not reached" "2" \
	"$(gate pointers | grep -c -e "$(unreached One)" -e "$(unreached Two)")"
printf '%s\n' '-> redaction.md "One"' >>"$skill/agents/job-triage.md"
check "pointers: a pointer leads on from a section that is reached" "ok - all repository checks pass" "$(gate pointers)"
add "$ref" '## New topic'
sed -i '2a -> "New topic"' "$skill/$ref"
finds "pointers: a pointer above the first section of a reference reaches nothing" pointers \
	"redaction.md:$((last + 2)): $(unreached 'New topic')"
add "$ref" '## New topic'
sed -i '2a -> redaction.md "New topic"' "$skill/references/untrusted-content.md"
check "pointers: any line of the reference read whole reaches" "ok - all repository checks pass" "$(gate pointers)"
add references/untrusted-content.md '## New topic'
check "pointers: a section of the reference read whole needs no pointer" \
	"ok - all repository checks pass" "$(gate pointers)"
add "$ref" '### Part'
check "pointers: a ### part needs no pointer" "ok - all repository checks pass" "$(gate pointers)"
fresh
printf 'One line\342\200\250to the gate.\n-> "New topic"\n## New topic\n' >>"$skill/$ref"
check "pointers: a line separator inside a line does not shift the line numbers" \
	"ok - all repository checks pass" "$(gate pointers)"
# listed FILE TITLE...: a clean copy whose gate lists these sections of FILE in UNROUTED
listed() {
	fresh
	local file=$1 title
	shift
	for title in "$@"; do
		sed -i "/^if __name__ ==/i UNROUTED.setdefault(\"openqa\", {}).setdefault(\"$file\", set()).add(\"$title\")" \
			"$work/repo/tests/repo/check-skills.py"
	done
}
listed redaction.md Listed
printf '%s\n' '## Listed' '-> "Listed", "New topic"' '## New topic' >>"$skill/$ref"
check "pointers: a listed section needs no pointer, may point at itself and leads on" \
	"ok - all repository checks pass" "$(gate pointers)"
printf '%s\n' '-> redaction.md "Listed"' >>"$skill/SKILL.md"
finds "pointers: an UNROUTED entry that is routed by now" pointers \
	"references/redaction.md:$((last + 1)): UNROUTED lists \"Listed\", which SKILL.md:$(wc -l <"$skill/SKILL.md") points to"
listed redaction.md Listed
finds "pointers: an UNROUTED entry whose section is gone" pointers \
	'references/redaction.md: UNROUTED lists "Listed", which does not exist'
listed redaction.md Part Redaction
printf '%s\n' '### Part' >>"$skill/$ref"
finds "pointers: an UNROUTED entry that names a ### part" pointers \
	"references/redaction.md:$((last + 1)): UNROUTED lists \"Part\", which is not a \"## \" section"
finds "pointers: an UNROUTED entry that names the file title" pointers \
	'references/redaction.md:1: UNROUTED lists "Redaction", which is not a "## " section'
listed gone.md Listed
finds "pointers: an UNROUTED entry whose file is gone" pointers \
	"references/gone.md: UNROUTED lists this file, which does not exist"
listed untrusted-content.md Rules
finds "pointers: an UNROUTED entry in the reference read whole" pointers \
	"references/untrusted-content.md: UNROUTED lists this file, which is read whole"
listed redaction.md Listed
printf '%s\n' '## Listed' >>"$skill/$ref"
cp -r "$skill" "$work/repo/skills/zz"
finds "pointers: UNROUTED lists the sections of one skill only" pointers \
	"skills/zz/references/redaction.md:$((last + 1)): $(unreached Listed)"
fresh
sed -i '/^if __name__ ==/i UNROUTED["nosuch"] = {}' "$work/repo/tests/repo/check-skills.py"
finds "pointers: an UNROUTED key that is no skill" pointers \
	"skills/nosuch: UNROUTED lists this skill, which does not exist"

fresh
mkdir -p "$work/repo/skills/zz"
printf -- '---\nname: zz\ndescription: A second skill.\nlicense: GPL-2.0-or-later\n---\n\n# zz\n' >"$work/repo/skills/zz/SKILL.md"
out=$(gate frontmatter,budget,pointers)
check "a second skill without references or scripts passes" "0 ok - all repository checks pass" "$? $out"
printf -- '\n-> SKILL.md "zz"\n' >>"$work/repo/skills/zz/SKILL.md"
finds "pointers: without refsection.py no pointer can be resolved" pointers "zz/scripts/refsection.py: missing"
mkdir "$work/repo/skills/zz/references"
printf '# R\n\n## One\n\nText.\n' >"$work/repo/skills/zz/references/r.md"
finds "budget: references without refsection.py cannot be measured" budget "zz/scripts/refsection.py: missing"
# The gate imports each skill's refsection.py: nothing the first skill imported may reach the second.
mkdir "$work/repo/skills/zz/scripts"
printf 'MARK = []\n' >"$work/repo/skills/zz/scripts/_sanitize.py"
cat >"$work/repo/skills/zz/scripts/refsection.py" <<'EOF'
from _sanitize import MARK  # the first skill's _sanitize has no MARK

try:
    import _secrets as MARK  # only the first skill ships one
except ImportError:
    pass


def parse(lines):
    return MARK
EOF
out=$(gate budget)
check "budget: each skill is measured by its own scripts" "0 ok - all repository checks pass" "$? $out"

# No CI job runs the evals, so the gate reads evals.json, which is edited by hand.
# evals: a clean copy with the evals, which fresh leaves out
evals() {
	fresh
	cp -r "$root/evals" "$work/repo/"
	json=$work/repo/evals/openqa/evals.json
}
# edit STATEMENT...: run each Python STATEMENT on data, the parsed evals.json of the copy
edit() {
	python3 - "$json" "$@" <<'EOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
for statement in sys.argv[2:]:
    exec(statement)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(data, handle)
EOF
}
evals
out=$(gate evals)
check "evals: the clean tree passes, with evals that list no files" "0 ok - all repository checks pass" "$? $out"
fresh
check "evals: a skill without evals passes" "ok - all repository checks pass" "$(gate evals)"
evals
printf '{"skill_name": "openqa", "evals": [\n' >"$json"
finds "evals: an evals.json that does not parse" evals "evals/openqa/evals.json: not valid JSON: "
evals
printf '{"skill_name": "openqa", "notes": "caf\351", "evals": []}\n' >"$json"
finds "evals: an evals.json that is not UTF-8" evals "evals/openqa/evals.json: not valid JSON: "
shape="evals/openqa/evals.json: must be an object with a non-empty list 'evals'"
evals
edit 'data = data["evals"]'
finds "evals: an evals.json that is a list" evals "$shape"
evals
edit 'data["evals"] = []'
finds "evals: an evals.json without evals" evals "$shape"
evals
edit 'data["skill_name"] = "open-qa"'
finds "evals: a skill_name that is not the directory name" evals "skill_name 'open-qa' differs from directory 'openqa'"
evals
cp -r "$work/repo/evals/openqa" "$work/repo/evals/zz"
finds "evals: evals of a skill that does not exist" evals "evals/zz/evals.json: skill 'zz' does not exist"
evals
edit 'data["evals"][0]["id"] = data["evals"][1]["id"] = 99'
finds "evals: an id that two evals share" evals "evals[1]: id 99 repeats evals[0]"
evals
edit 'data["evals"][0]["name"] = data["evals"][1]["name"] = "twice"'
finds "evals: a name that two evals share" evals "evals[1]: name 'twice' repeats evals[0]"
evals
edit 'data["evals"][0]["id"] = "99"' 'data["evals"][1]["id"] = True'
check "evals: an id that is a string or true" 2 "$(gate evals | grep -c "evals\[[01]\]: 'id' must be an integer")"
evals
edit 'del data["evals"][0]["prompt"]'
finds "evals: an eval without a prompt" evals "evals[0]: 'prompt' must be a non-empty string"
evals
edit 'data["evals"][0]["expected_output"] = " "'
finds "evals: an expected output of blanks" evals "evals[0]: 'expected_output' must be a non-empty string"
evals
edit 'data["evals"][0]["assertions"] = []'
finds "evals: an eval without assertions" evals "evals[0]: 'assertions' must be a non-empty list of strings"
evals
edit 'data["evals"][0]["assertions"].append(1)'
finds "evals: an assertion that is not a string" evals "evals[0]: 'assertions' must be a non-empty list of strings"
evals
edit 'data["evals"][0]["files"] = "files/hostile-job/"'
finds "evals: files that are not a list" evals "evals[0]: 'files' must be a list of paths"
evals
edit 'data["evals"].insert(0, "prompt")'
finds "evals: an eval that is not an object" evals "evals[0]: must be an object"
evals
edit 'data["evals"][0]["files"] = ["files/nosuch/"]'
finds "evals: a files entry that does not exist" evals "evals[0]: 'files' entry 'files/nosuch/' does not exist"
unused="evals/openqa/files/unused: no eval lists this directory"
evals
mkdir "$work/repo/evals/openqa/files/unused"
finds "evals: a fixture directory no eval lists" evals "$unused"
touch "$work/repo/evals/openqa/files/unused/log.txt"
edit 'data["evals"][0]["files"] = ["files/unused/log.txt"]'
check "evals: one file of a fixture directory lists the directory" "ok - all repository checks pass" "$(gate evals)"
evals
mkdir "$work/repo/evals/openqa/files/unused"
edit 'data["evals"][0]["files"] = ["files/"]'
check "evals: files/ as a whole lists every fixture directory" "ok - all repository checks pass" "$(gate evals)"
evals
touch "$work/repo/evals/openqa/files/unused"
check "evals: a file directly in files/ needs no eval" "ok - all repository checks pass" "$(gate evals)"

exit $fail
