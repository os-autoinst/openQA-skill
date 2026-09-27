#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Proves the credentials check of check-skills.py can fail: each case plants one line in a
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

# plant NAME EXPECTED LINE: add LINE to a reference of a clean copy, run the check
plant() {
	rm -rf "$work/repo"
	mkdir -p "$work/repo/tests/repo"
	cp -r "$root/skills" "$work/repo/"
	cp "$here/check-skills.py" "$work/repo/tests/repo/"
	printf '%s\n' "$3" >>"$work/repo/skills/openqa/references/redaction.md"
	out=$(python3 "$work/repo/tests/repo/check-skills.py" --only credentials)
	check "$1" "$2" "$(sed -n 's/^credentials: [^ ]*: \([^:]*\):.*/\1/p' <<<"$out" | head -1)"
}

plant "the clean tree passes" "" "Credentials stay inside the tools."

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

exit $fail
