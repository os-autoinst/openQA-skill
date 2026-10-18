#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests for scripts/_secrets.py: credential-shaped values are replaced, and normal log
# content is not. The negative cases matter more than the positive ones - a redactor
# that eats evidence gets switched off, and then it protects nothing.

here=$(cd "$(dirname "$0")" && pwd)
scripts="$here/../../skills/openqa/scripts"
fixtures="$here/fixtures/_secrets"
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

# redacts <name> <printf-format> <rule expected in the summary>
redacts() {
	local out
	# shellcheck disable=SC2059
	out=$(printf -- "$2" | python3 "$scripts/_secrets.py" 2>&1)
	case "$out" in
	*"[REDACTED:$3]"*) echo "ok - $1" ;;
	*)
		echo "not ok - $1"
		printf '  wanted rule %q in: %q\n' "$3" "$out"
		fail=1
		;;
	esac
}

# keeps <name> <printf-format>: nothing may be redacted
keeps() {
	local out rc
	# shellcheck disable=SC2059
	out=$(printf -- "$2" | python3 "$scripts/_secrets.py" 2>/dev/null)
	rc=$?
	# exit 0 is "nothing redacted"; a crash exits 1 with empty output, which must not pass
	[ "$rc" -eq 0 ] || out="exit $rc, [REDACTED: or a crash: $out"
	case "$out" in
	*"[REDACTED:"*)
		echo "not ok - $1"
		printf '  false positive: %q\n' "$out"
		fail=1
		;;
	*) echo "ok - $1" ;;
	esac
}

# hides <name> <printf-format> <text>: a marker alone is not enough, that text must be gone
hides() {
	local out
	# shellcheck disable=SC2059
	out=$(printf -- "$2" | python3 "$scripts/_secrets.py" 2>/dev/null)
	case "$out" in
	*"$3"*)
		echo "not ok - $1"
		printf '  %q survived in: %q\n' "$3" "$out"
		fail=1
		;;
	*"[REDACTED:"*) echo "ok - $1" ;;
	*)
		echo "not ok - $1"
		printf '  no redaction marker (a crash?) in: %q\n' "$out"
		fail=1
		;;
	esac
}

# --- read-only by construction ---------------------------------------------------
src="$scripts/_secrets.py"
check "source names no network, process or environment access" 0 \
	"$(grep -Ec 'urllib|http\.client|import socket|urlopen|subprocess|os\.system|os\.environ|getenv|expanduser|netrc' "$src")"
check "licence header" "# SPDX-License-Identifier: GPL-2.0-or-later" "$(sed -n 2p "$src")"

# --- credentials that must not reach the agent -----------------------------------
redacts "github token" 'fatal: token ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA rejected\n' github-token
redacts "gitlab token" 'glpat-AAAAAAAAAAAAAAAAAAAA\n' gitlab-token
redacts "aws access key id" 'aws_access_key_id = AKIAIOSFODNN7EXAMPLE\n' aws-key-id
redacts "slack token" 'xoxb-1234567890-abcdefghij\n' slack-token
redacts "jwt" 'Cookie: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP\n' jwt
redacts "google oauth access token" '+ gcloud storage ls --access-token-file=- <<< ya29.a0AfH6SMBc0123456789abcd\n' google-oauth-token
redacts "google api key" 'export MAPS_KEY_FILE_CONTENT=AIzaSyA1234567890abcdefghijklmnopqrstuv\n' google-api-key
# Fake token-shaped values are joined at run time: no committed line holds one whole, which push
# protection and other secret scanners refuse even when the value is a test fake.
slack_hook="https://hooks.slack.com/services/""T0000AAAA/B0000BBBB/abcdefghijklmnopqrstuvwx"
slack_bot="xox""b-1234567890123-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx"
redacts "slack webhook" "curl -X POST $slack_hook\n" slack-webhook
actual=$(printf -- 'post to %s\n' "$slack_hook" |
	python3 "$scripts/_secrets.py" 2>/dev/null)
check "a slack webhook keeps its host, loses its path" "post to https://hooks.slack.com/services/[REDACTED:slack-webhook]" "$actual"
for case in 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP|jwt' \
	'Authorization: Bearer ya29.a0AfH6SMBc0123456789abcd|google-oauth-token' \
	'GET /maps?key=AIzaSyA1234567890abcdefghijklmnopqrstuv&z=1|google-api-key'; do
	actual=$(printf -- '%s\n' "${case%|*}" | python3 "$scripts/_secrets.py" 2>&1)
	check "a header or query value keeps the specific rule's name: ${case#*|}" \
		"redacted 1: ${case#*|}=1" "$(head -n 1 <<<"$actual")"
done
for case in "Authorization: Bearer $slack_bot|AbCdEfGhIjKlMnOpQrStUvWx" \
	"GET /x?auth=$slack_bot|AbCdEfGhIjKlMnOpQrStUvWx" \
	'Authorization: Bearer [REDACTED:jwt]hunter2hunter2hunter2|hunter2hunter2'; do
	actual=$(printf -- '%s\n' "${case%|*}" | python3 "$scripts/_secrets.py" 2>/dev/null)
	check "no secret tail survives a partial or forged marker: ${case%%|*}" 0 "$(grep -c "${case#*|}" <<<"$actual")"
done
redacts "a long slack bot token, whole" "$slack_bot\n" slack-token
actual=$(printf -- 'gcloud printed ya29.c.b0AXv0zTOabcdefghijklmnopqrstuvwxyz0123456789\n' | python3 "$scripts/_secrets.py" 2>/dev/null)
check "a service-account ya29.c. token is redacted whole" "gcloud printed [REDACTED:google-oauth-token]" "$actual"
keeps "a ya29 host name" 'resolved ya29.example.com\n'
keeps "a name that starts like a google api key" 'Aizawa-san uploaded the logs\n'
keeps "a short ya29 word" 'ya29.1 is a version string\n'
keeps "the slack webhook docs path without a secret" 'see https://hooks.slack.com/services/ for the API\n'
redacts "url userinfo" 'zypper ar https://alice:hunter2@example.org/repo x\n' url-userinfo
redacts "authorization header" '> Authorization: Bearer abcdefghijklmnop\n' auth-header
redacts "curl -u" '+ curl -u alice:s3cretvalue https://example.org/api\n' curl-user
redacts "password flag of a known command" '+ helm registry login ex.io -u bob -p Sup3rS3cret\n' password-flag
redacts "registry auth blob" '{"auths":{"x":{"auth":"dXNlcjpwYXNzd29yZA=="}}}\n' registry-auth
redacts "keyed assignment" 'SCC_REGCODE=ABCD1234EFGH5678\n' keyed-assignment
redacts "keyed assignment with spaces" 'SCC_REGCODE = ABCD1234EFGH5678\n' keyed-assignment
keeps "an empty shell assignment does not take the next word" "openqa-clone-job URL SCC_REGCODE= 'BUILD=alice/repo#fix'\n"
redacts "private key block" '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n' private-key

# The body of a key is base64 that no line rule would match; it must not survive.
actual=$(printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----\n' |
	python3 "$scripts/_secrets.py" 2>/dev/null)
check "the key body is swallowed, not printed line by line" 0 "$(grep -c MIIEowIBAAKCAQEA <<<"$actual")"

# A BEGIN with no END means the body is still ahead: fail closed.
actual=$(printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n' | python3 "$scripts/_secrets.py" 2>/dev/null)
check "an unterminated key block fails closed" 0 "$(grep -c MIIEowIBAAKCAQEA <<<"$actual")"

# --- what must survive, or the redactor destroys the evidence it exists to show ---
keeps "the conventional openQA password" 'EXTRABOOTPARAMS=... live.password=nots3cr3t\n'
keeps "a sha256 digest" 'checksum e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n'
keeps "a uuid on the kernel command line" 'root=UUID=123e4567-e89b-12d3-a456-426614174000 ro\n'
# shellcheck disable=SC2016
keeps "a shell template" 'ARM_CLIENT_SECRET=${AZURE_SECRET}\n'
keeps "an empty-ish value" 'TOKEN=none\n'
keeps "a socket path" 'SSH_AUTH_SOCK=/tmp/ssh-XXXX/agent.1234\n'
keeps "needle candidates" 'candidates: bootloader-20260919:96%% inst-welcome:88%%\n'
keeps "an ordinary log line" '[debug] loading console/opencode on openqaworker20\n'
keeps "a git hash" 'TEST_GIT_HASH=3f718db6c0de4a2b1e5f8a9c7d6e5f4a3b2c1d0e\n'
keeps "a public repo url with no userinfo" 'zypper ar https://download.opensuse.org/tumbleweed/repo/oss/ oss\n'

# The negative fixture is the control for over-redaction: it must stay byte-identical.
actual=$(python3 "$scripts/_secrets.py" <"$fixtures/clean-log.txt" 2>/dev/null)
check "a whole realistic log survives untouched" "$(cat "$fixtures/clean-log.txt")" "$actual"
check "and reports nothing" "" "$(python3 "$scripts/_secrets.py" --quiet <"$fixtures/clean-log.txt" 2>&1 >/dev/null)"

# --- the summary, so a redaction is never silent ----------------------------------
actual=$(printf 'curl -u a:secretvalue https://x/ and ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' |
	python3 "$scripts/_secrets.py" 2>&1 >/dev/null)
check "stderr names every rule that fired" "redacted 2: curl-user=1, github-token=1" "$actual"
printf 'curl -u a:secretvalue https://x/\n' | python3 "$scripts/_secrets.py" >/dev/null 2>&1
check "exit code 1 when something was redacted" 1 $?
printf 'nothing to see\n' | python3 "$scripts/_secrets.py" >/dev/null 2>&1
check "exit code 0 when nothing was" 0 $?
check "--quiet prints no summary" "" \
	"$(printf 'curl -u a:secretvalue https://x/\n' | python3 "$scripts/_secrets.py" --quiet 2>&1 >/dev/null)"

# --- settings are keyed by name, which no value-shape rule can know ---------------
actual=$(python3 -c "
import sys; sys.path.insert(0, '$scripts')
import _secrets
for key in ('SCC_REGCODE', '_SECRET_DOCKER', 'ROOT_PASSWORD', 'JOBTOKEN', 'CASEDIR', 'BUILD',
            '_HANA_MASTER_PW', 'OPENWEBUI_ADMIN_PWD', 'MITIGATION_GIT_REPO_PASS', 'ADMINPASS',
            'PASSTHROUGH_VF_COUNT', 'UNIFIED_GUEST_REG_CODES', 'UNIFIED_GUEST_REG_EXTS_CODES',
            'REG_CODE', 'REGION_CODE', 'EXIT_CODE'):
    print(key, _secrets.is_secret_key(key))
")
check "openQA's own names, plus the regcodes, short password names and job token it misses" "$(
	cat <<'EOF'
SCC_REGCODE True
_SECRET_DOCKER True
ROOT_PASSWORD True
JOBTOKEN True
CASEDIR False
BUILD False
_HANA_MASTER_PW True
OPENWEBUI_ADMIN_PWD True
MITIGATION_GIT_REPO_PASS True
ADMINPASS True
PASSTHROUGH_VF_COUNT False
UNIFIED_GUEST_REG_CODES True
UNIFIED_GUEST_REG_EXTS_CODES True
REG_CODE True
REGION_CODE False
EXIT_CODE False
EOF
)" "$actual"

# --- structure and cost -----------------------------------------------------------
actual=$(printf 'a\nb\nc\n' | python3 "$scripts/_secrets.py" 2>/dev/null | wc -l)
check "line structure is preserved" 3 "$actual"
SECONDS=0
python3 -c "
import sys; sys.path.insert(0, '$scripts')
import _secrets
_secrets.redact('worker openqaworker20 ran module foo at 12:00:00\n' * 20000)
"
check "20k ordinary lines stay well under a second of budget" 1 "$((SECONDS < 10))"

# --- defects found in review, each with the input that demonstrated it ------------
keeps "a psql port, not a password" 'psql -h db -p 5432 -U openqa -c x\n'
keeps "a container uid:gid, not credentials" 'podman run --rm -u 1000:1000 registry/img\n'
keeps "a published port" 'docker run -p 8080:80 img\n'
redacts "docker login --password, which no trigger used to reach" '+ docker login --password Sup3rS3cretVal reg.ex\n' password-flag
redacts "mysql -p, which no trigger used to reach" '+ mysql -pMyP4ssw0rdX -e x\n' password-flag
redacts "an aws prefix outside the two in TRIGGERS" 'principal AROAIOSFODNN7EXAMPLE listed\n' aws-key-id
# shellcheck disable=SC2016
redacts "a password containing a template character" 'ROOT_PASSWORD=Sup3r$ecret!\n' keyed-assignment
redacts "a 32-hex api key, which the digest veto used to drop" 'API_KEY=0123456789abcdef0123456789abcdef\n' keyed-assignment
redacts "a secret dressed as already-redacted" 'TOKEN=[REDACTED:x]REALSECRETVALUE\n' keyed-assignment

# --- shapes an agent produces when it handles a credential itself ------------------
redacts "a password with a slash" 'git clone https://bob:ab/cd3fgh@git.example.org/r\n' url-userinfo
redacts "a password with an @" 'curl https://bob:p@ssw0rdX@host/x\n' url-userinfo
actual=$(printf 'curl https://bob:p@ssw0rdX@host/x\n' | python3 "$scripts/_secrets.py" 2>/dev/null)
check "no part of a password with an @ survives" 0 "$(grep -c ssw0rdX <<<"$actual")"
redacts "a token as the whole userinfo" 'git clone https://a1b2c3d4e5f6a7b8c9d0e1f2@github.com/o/r\n' url-token
redacts "an Authorization value without a scheme word" 'Authorization: abcdefghijk123\n' auth-header
redacts "openQA's X-API-Key header" 'X-API-Key: 0123456789ABCDEF\n' api-key-header
redacts "openQA's X-API-Hash header" 'X-API-Hash: 3f2a9c0d1e4b5a6c7d8e\n' api-key-header
redacts "openqa-cli --apikey with a space" 'openqa-cli api --apikey 0123456789ABCDEF jobs\n' api-flag
redacts "openqa-cli --apisecret with a space" 'openqa-cli api --apisecret FEDCBA9876543210 jobs\n' api-flag
redacts "a signed URL" 'GET https://s3.example.org/b/o?X-Amz-Signature=abcdef0123456789&x=1\n' url-query
redacts "an api key in a query" 'GET https://maps.example.org/q?key=AIzaSyA1234567890\n' url-query
redacts "the key line of client.conf" 'key = 0123456789ABCDEF\n' ini-key
keeps "a port before an @ in the path" 'https://registry.npmjs.org:443/@scope/pkg\n'
keeps "a git@ userinfo" 'git clone https://git@github.com/o/r\n'
# shellcheck disable=SC2016 # a literal $SECRET, as documentation writes it
keeps "an --apikey slot in documentation" 'openqa-cli api --apikey <key> --apisecret $SECRET jobs\n'
keeps "a Perl hash key" 'my %%h = (key => "value123");\n'
keeps "an e-mail address" 'maintainer: alice@example.org\n'
keeps "a short query value" 'https://example.org/q?key=abc\n'
keeps "a query slot in documentation" 'https://example.org/q?key=<your-key>\n'
keeps "a variable that ends in key" 'monkey = 12345678\n'
keeps "a Perl hash key on its own line" '    key => "value123",\n'
# shellcheck disable=SC2016 # literal slots, as documentation writes them
keeps "INI slots in documentation" 'key = <your-api-key>\nkey = ${OPENQA_KEY}\n'
redacts "a signed query with no scheme on the line" 'path?sig=abcdef0123456789\n' url-query

# --- more shapes that got through, and evidence that did not ----------------------
keeps "a setting name in openQA's job_settings query" 'GET /api/v1/job_settings/jobs?key=*_TEST_ISSUES&list_value=1\n'
keeps "another setting name in that query" 'https://openqa.opensuse.org/api/v1/job_settings/jobs?key=INCIDENT_ID\n'
redacts "an openQA api key in a query" 'GET https://openqa.example.org/api/v1/jobs?key=0123456789ABCDEF\n' url-query
# shellcheck disable=SC2016 # JMESPath quotes with backticks
keeps "a JMESPath filter on a tag" 'aws ec2 describe-instances --query Reservations[].Instances[].Tags[?Key==`Name`].Value\n'
keeps "a line of Python in a traceback" '    key = hashlib.sha256(data).hexdigest()\n'
keeps "a Python constant built from a path" 'KEY = BASE_DIR / "keys" / "id.pem"\n'
keeps "a key file in stunnel.conf" 'key = /etc/stunnel/stunnel.pem\n'
redacts "a base64 key line" 'key = c2VjcmV0dmFsdWU=\n' ini-key
redacts "a commented-out key line" '# key = 0123456789ABCDEF\n' ini-key
redacts "a key line commented out with ;" '; key = 0123456789ABCDEF\n' ini-key
redacts "a quoted key line" 'key = "0123456789ABCDEF"\n' ini-key
keeps "compact JSON with a port and an e-mail" '{"url":"http://db.example.org:5432","owner":"alice@example.org"}\n'
keeps "an IPv6 URL with an @ in the path" 'https://[2001:db8::1]:8443/@scope/pkg\n'
redacts "a password before an IPv6 host" 'curl http://bob:s3cretpw@[::1]:8080/x\n' url-userinfo
redacts "userinfo in compact JSON" '{"url":"https://bob:hunter2hunter2@host/x"}\n' url-userinfo
redacts "an empty user name" 'redis-cli -u redis://:Sup3rS3cretX@redis.example.org:6379/0\n' url-userinfo
long=$(printf '%0300d' 0 | tr 0 x)
hides "a URL password longer than 256 characters" "https://bob:${long}@host/x\n" xxxxxxxx
redacts "a *_PW name" '_HANA_MASTER_PW=Sup3rS3cretX\n' keyed-assignment
redacts "a *_PWD name" 'OPENWEBUI_ADMIN_PWD=Sup3rS3cretX\n' keyed-assignment
redacts "a *PASS name" 'MITIGATION_GIT_REPO_PASS=Sup3rS3cretX\n' keyed-assignment
keeps "a Go test verdict" '--- PASS: TestParseConfig (0.00s)\n'
keeps "an LTP verdict" 'tst_test.c:1734: TPASS: getpid() returned 4242\n'
keeps "an automake verdict" 'PASS: test-suite-runner\n'
keeps "the shell's working directory" 'PWD=/var/lib/openqa/pool/1\n'
keeps "an img-proof summary" 'tests=12|pass=12|skip=0|fail=0|error=0\n'
# shellcheck disable=SC2016 # Perl source, quoted in a ticket
keeps "a Perl counter named after passes" '$pass_count = pattern_count_in_file($data, $re);\n'
redacts "a keyed value in JSON" '{"ROOT_PASSWORD": "Sup3rS3cretVal"}\n' keyed-assignment
redacts "a keyed value in a Python dict" "{'api_token': 'abcd1234efgh5678'}\n" keyed-assignment
redacts "a keyed value in a Perl hash" "password => 'Sup3rS3cretVal',\n" keyed-assignment
# shellcheck disable=SC2016 # Perl source, quoted in a ticket
keeps "a Perl hash value that is a variable" 'password => $testapi::password,\n'
keeps "a Perl hash value that is a call" "passwd => get_var('ETC_PASSWD'),\n"
keeps "a JSON literal next to a credential key" '"password_mode": false,\n'
redacts "an Authorization header in JSON" '{"Authorization": "Bearer abcdefghijklmnop"}\n' auth-header
redacts "an X-API-Key header in a Python dict" "{'X-API-Key': '0123456789ABCDEF'}\n" api-key-header
actual=$(printf '%s\n' '{"Authorization":"Bearer abcdefghijkl","Host":"openqa.example.org"}' '{"X-API-Key":"0123456789ABCDEF","Host":"openqa.example.org"}' | python3 "$scripts/_secrets.py" 2>/dev/null)
check "a header value in compact JSON keeps the fields after it" 2 "$(grep -c '"Host":"openqa.example.org"' <<<"$actual")"
hides "a Negotiate token, not its scheme word" 'Authorization: Negotiate YIIGhgYGKwYBBQUCoIIGejCCBnag\n' YIIGhg
hides "an NTLM token" 'Proxy-Authorization: NTLM TlRMTVNTUAABAAAAB4IIog==\n' TlRMTVNT
redacts "a percent-encoded signature" 'GET https://s3.example.org/b/o?sig=%%2BabcdefABCDEF0123\n' url-query
keeps "a Jinja slot in a query" 'https://example.org/q?key={{api_key}}\n'
keeps "a Windows variable in a query" 'https://example.org/q?key=%%API_KEY%%\n'
hides "a token before x-oauth-basic" 'git clone https://0123456789abcdef0123456789abcdef01234567:x-oauth-basic@github.com/o/r\n' 0123456789abcdef
hides "a token before an empty password" 'git clone https://0123456789abcdef0123456789abcdef01234567:@github.com/o/r\n' 0123456789abcdef
redacts "a 16-character token as the userinfo" 'curl https://abcdEFGH12345678@api.example.org/x\n' url-token
redacts "a token with URL punctuation as the userinfo" 'git clone https://abc.defGHI~jkl+mno%%2Fpqr@git.example.org/r\n' url-token
keeps "a host name as the userinfo, which spoofs the real host" 'https://openqa.opensuse.org@evil.example.org/tests/1\n'
keeps "a dotted user name" 'git clone ssh://firstname.lastname@git.example.org/r\n'
hides "the tail of a keyed value longer than 256 characters" "TOKEN=${long}TAILPART\n" TAILPART
redacts "curl -u with the value attached" '+ curl -ubob:Sup3rS3cretX https://example.org/api\n' curl-user
redacts "smbclient -U user%%password" '+ smbclient //srv/share -U bob%%Sup3rS3cretX -c ls\n' password-flag

# --- a second review: flags that name no password, and keys that do ---------------
keeps "a password read from stdin" '+ podman login --password-stdin quay.io\n'
keeps "a password read from a file" '+ podman login --password-file /run/secrets/reg quay.io\n'
redacts "a --password value after =" 'mytool --password=Sup3rS3cretX\n' password-flag
keeps "a mysql port" 'mysql -h db -P 3306 -e x\n'
keeps "mysql and mariadb take a password only attached: a word after -p is the database" \
	'mysql -u root -p mydatabase\nmariadb -u root -p wordpress < dump.sql\n'
redacts "mariadb with an attached password" 'mariadb -uroot -pS3cretPassX\n' password-flag
hides "sshpass takes its password after a space" 'sshpass -p S3cretPassX ssh host\n' S3cretPassX
keeps "an ipmitool port" 'ipmitool -I lanplus -H bmc -p 6230 chassis status\n'
keeps "an sshpass prompt" 'sshpass -P assword: -f /run/pw ssh root@host.example.org uptime\n'
keeps "an smbclient port" 'smbclient //srv/share -p 4450 -N -c ls\n'
redacts "smbclient --user=user%%password" '+ smbclient //srv/share --user=bob%%Sup3rS3cretX -c ls\n' password-flag
redacts "a *_PASS name in YAML" 'ROOT_PASS: Sup3rS3cretX\n' keyed-assignment
hides "a quoted *_PASS value in YAML" "MITIGATION_GIT_REPO_PASS: 'Sup3rS3cretX'\n" Sup3rS3cretX
keeps "an automake unexpected pass" 'XPASS: test-suite-runner\n'
keeps "setting names without _ in openQA's job_settings query" 'GET /api/v1/job_settings/jobs?key=VERSION\nGET /api/v1/job_settings/jobs?key=MACHINE&list_value=1\n'
redacts "an api key that starts with letters" 'GET https://openqa.example.org/api/v1/jobs?key=ABCDEF0123456789\n' url-query
keeps "prose after Authorization:" 'Authorization: required for this endpoint\n'
hides "a Basic credential" 'Authorization: Basic dXNlcjpwYXNzd29yZA==\n' dXNlcjpw
keeps "compact single-quoted fields with a port and an e-mail" "{'url':'http://db.example.org:5432','owner':'alice@example.org'}\n"
keeps "compact single-quoted fields with an e-mail" "{'url':'http://db.example.org','owner':'alice@example.org'}\n"
redacts "userinfo in single-quoted fields" "{'url':'https://bob:hunter2hunter2@host/x'}\n" url-userinfo
# A service-account key is JSON-escaped onto one line; the log after it is still evidence.
actual=$(printf '%s\n' '{"private_key": "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBg\n-----END PRIVATE KEY-----\n"}' 'next line survives' |
	python3 "$scripts/_secrets.py" 2>/dev/null)
check "a key on one line swallows only that line" "$(printf '[REDACTED:private-key]\nnext line survives')" "$actual"

# --- a repository URL whose query string is its access token ----------------------
qtok="AbCdEf0123""GhIjKl4567""MnOp_-89QrStUv"
repo="https://updates.example.com/SUSE/Updates/SLE-Module-Basesystem/15-SP5/x86_64/update/"
actual=$(printf 'zypper ar %s?%s update\n' "$repo" "$qtok" | python3 "$scripts/_secrets.py" 2>/dev/null)
check "a bare query token goes, the repository path stays" "zypper ar $repo?[REDACTED:url-bare-query] update" "$actual"
check "and the summary names the rule" "redacted 1: url-bare-query=1" \
	"$(printf 'zypper ar %s?%s update\n' "$repo" "$qtok" | python3 "$scripts/_secrets.py" 2>&1 >/dev/null)"
actual=$(printf '%s\n' \
	"2026-10-16 10:00:00 <1> susetest(4242) [zypp::media] MediaCurl.cc(evaluateCurlCode):1047 Download (curl) error for '${repo}repodata/repomd.xml?$qtok':" \
	"  3 | SLE-Module-Basesystem15-SP5-Updates | Yes | (r ) Yes | Yes | $repo?$qtok" |
	python3 "$scripts/_secrets.py" 2>/dev/null)
check "a token after a file name in zypp.log and in zypper lr -u" "$(
	printf '%s\n' \
		"2026-10-16 10:00:00 <1> susetest(4242) [zypp::media] MediaCurl.cc(evaluateCurlCode):1047 Download (curl) error for '${repo}repodata/repomd.xml?[REDACTED:url-bare-query]':" \
		"  3 | SLE-Module-Basesystem15-SP5-Updates | Yes | (r ) Yes | Yes | $repo?[REDACTED:url-bare-query]"
)" "$actual"
for pad in '= update' '==' '=).' '==. Next' '=, next' '=#top'; do
	actual=$(printf 'zypper ar %s?%s%s\n' "$repo" "$qtok" "$pad" | python3 "$scripts/_secrets.py" 2>/dev/null)
	check "a bare query token with base64 padding where the query ends goes whole: '$pad'" "zypper ar $repo?[REDACTED:url-bare-query]${pad##*=}" "$actual"
done
for key in token access_token auth sig signature X-Amz-Signature X-Goog-Signature credentials; do
	hides "a token as the value of ?$key=" "GET ${repo}repodata/repomd.xml?$key=$qtok&arch=x86_64\n" "$qtok"
done
for url in 'https://bugzilla.opensuse.org/show_bug.cgi?id=123' "$repo?arch=x86_64&dist=sle" \
	'https://openqa.opensuse.org/tests/latest?arch=x86_64&distri=opensuse&flavor=DVD&machine=64bit&test=textmode&version=Tumbleweed' \
	'https://download.opensuse.org/tumbleweed/repo/oss/repodata/repomd.xml?mirrorlist' \
	'https://example.org/docs?a-long-word-as-a-query' 'https://example.org/app.js?17000000000000000' \
	"$repo?ABCDEFGH12345678=value" "$repo?ABCDEFGH12345678===" "$repo?ABCDEFGH12345678==value" \
	"$repo?ABCDEFGH12345678=/path/to/file" "$repo?ABCDEFGH12345678=+x" "$repo?ABCDEFGH12345678=.x" \
	"$repo?ABCDEFGH12345678=&page=2" "$repo?ABCDEFGH12345678=;page=2" "$repo?ABCDEFGH12345678=,x"; do
	keeps "an ordinary query: ${url#*\?}" "GET $url\n"
done

# --- the job's own token, which vars.json and the worker log carry ----------------------
jobtoken="Qz7xKp2L""m9vRt4Wd"
for line in "   \"JOBTOKEN\" : \"$jobtoken\"," "    JOBTOKEN=$jobtoken" "X-API-JobToken: $jobtoken" \
	"{\"JOBTOKEN\":\"$jobtoken\",\"TEST\":\"textmode\"}"; do
	actual=$(printf '%s\n' "$line" | python3 "$scripts/_secrets.py" 2>/dev/null)
	check "a job token goes, the rest of the line stays: ${line%%"$jobtoken"*}" \
		"${line/"$jobtoken"/[REDACTED:job-token]}" "$actual"
done
# Every output path of oqa-log.py --file vars.json goes through the redactor.
printf '{\n   "ARCH" : "x86_64",\n   "JOBTOKEN" : "%s",\n   "TEST" : "textmode"\n}\n' "$jobtoken" >"$work/tests_4242_file_vars.json"
for mode in "--grep JOBTOKEN" "--grep $jobtoken" "--lines 1-5" "--tail 3" "--errors" "--grep ARCH --context 2"; do
	# shellcheck disable=SC2086 # a mode is one or more arguments
	actual=$(python3 "$scripts/oqa-log.py" --fixture-dir "$work" https://openqa.example.org/tests/4242 --file vars.json $mode 2>&1)
	# the header line proves the mode ran, rather than failing with a usage error
	check "oqa-log.py --file vars.json ${mode/"$jobtoken"/<token>} prints no job token" "1 0" \
		"$(grep -c '^job=4242 host=https://openqa.example.org mode=' <<<"$actual") $(grep -c "$jobtoken" <<<"$actual")"
done
actual=$(python3 "$scripts/oqa-log.py" --fixture-dir "$work" https://openqa.example.org/tests/4242 --file vars.json --lines 1-5 2>&1)
check "and shows the line it was on" 1 "$(grep -c '"JOBTOKEN" : "\[REDACTED:job-token\]"' <<<"$actual")"
# autoinst_url() puts it right after host:port of every command-server URL.
cmdsrv="http://10.0.2.2:20013/$jobtoken"
for line in "[debug] [pid:4242] <<< testapi::assert_script_run(cmd=\"curl --form upload=@/var/log/zypper.log --form upname=zypper_up-zypper.log $cmdsrv/uploadlog/zypper_up-zypper.log\", timeout=90)" \
	"# curl -f -O $cmdsrv/data/console/test.sh; echo xYz-\$?-" \
	"autoyast=$cmdsrv/files/autoyast/autoinst.xml" "$cmdsrv/upload_asset/disk.qcow2" \
	"ws://127.0.0.1:20013/$jobtoken/ws" "[info] [pid:4242] cmdsrv: daemon reachable under http://*:20013/$jobtoken/" \
	"[debug] [pid:4242] stopping command server: http://127.0.0.1:20013/$jobtoken/"; do
	actual=$(printf '%s\n' "$line" | python3 "$scripts/_secrets.py" 2>/dev/null)
	check "a command-server URL loses its job token: ${line%%"$jobtoken"*}" \
		"${line/"$jobtoken"/[REDACTED:job-token]}" "$actual"
done
keeps "a long path segment of an ordinary URL" 'http://registry.example.org:5000/containerimagesxyz/tags/list\nhttps://github.com/openSUSEQAToolsRepo/files/x\nhttp://10.0.2.2:20013/shortToken/data\n'

# --- os-autoinst's own plumbing, thousands of lines per autoinst-log.txt ---------------
keeps "os-autoinst's json_cmd_token" '[debug] [pid:4242] <<< consoles::serial_screen::type_string(text="\\n", key="ret", json_cmd_token="AbCdEfGh", cmd="backend_send_key")\n[debug] [pid:4242] read_json(7) json_cmd_token=HgFeDcBa\n'
# shellcheck disable=SC2016 # a regex, as os-autoinst logs it
keeps "a password prompt regex" '[debug] [pid:4242] <<< testapi::wait_serial(regexp=qr/Password:\\s*$/ui, timeout=30)\n[debug] [pid:4242] <<< consoles::serial_screen::read_until(pattern="(?^ui:Password:\\\\s*\\$)", timeout=30)\n'
hides "a real token beside a json_cmd_token" 'json_cmd_token="AbCdEfGh", api_token="Sup3rS3cretX"\n' Sup3rS3cretX
hides "a password that starts with a backslash" 'ROOT_PASSWORD=\\Sup3rS3cretX\n' Sup3rS3cretX

# --- a registration code on the command line of a registration command ---------------
regcode="AbCd1234""EfGh5678"
for line in "SUSEConnect -r $regcode" "SUSEConnect --regcode $regcode" "SUSEConnect --regcode=$regcode" \
	"+ SUSEConnect -p sle-module-web-scripting/15.6/x86_64 --gpg-auto-import-keys -r $regcode" \
	"[debug] <<< testapi::assert_script_run(cmd=\"SUSEConnect --url https://scc.example.org -r $regcode\", timeout=200)" \
	"Test died: command 'SUSEConnect -r $regcode' failed at sle/tests/console/suseconnect.pm line 37." \
	"# suseconnect --debug -r $regcode; echo TaG-\$?-" \
	"transactional-update -n register -p sle-module-live-patching/15.6/x86_64 -r $regcode" \
	"transactional-update register --regcode $regcode -e user@example.org" \
	"sudo registercloudguest --force-new -r '$regcode'" \
	"cmd=\"sudo registercloudguest --force-new -r \\\"$regcode\\\"\""; do
	actual=$(printf '%s\n' "$line" | python3 "$scripts/_secrets.py" 2>/dev/null)
	check "a registration code goes, the rest of the line stays: ${line%%"$regcode"*}" \
		"${line/"$regcode"/[REDACTED:regcode]}" "$actual"
done
keeps "SUSEConnect --list-extensions: the placeholder where a code goes, plain and coloured" \
	'Activate with: SUSEConnect -p sle-module-live-patching/15.6/x86_64 -r ADDITIONAL REGCODE\nActivate with: SUSEConnect -p sle-ha/15.6/x86_64 -r \033[32m\033[1mADDITIONAL REGCODE\033[0m\n'
for line in 'regcode=AbCd1234EfGh5678' '{"regcode": "AbCd1234EfGh5678"}'; do
	hides "a registration code after its key: $line" "$line\n" AbCd1234EfGh5678
done
codes="AbCd1234""EfGh,IjKl5678""MnOp|"
for line in "    UNIFIED_GUEST_REG_CODES=$codes" "   \"UNIFIED_GUEST_REG_EXTS_CODES\" : \"$codes\"," \
	"          'guest_registration_code' => '$codes'," "ansible-playbook registration.yaml -e reg_code='$codes' -e email_address=''"; do
	# the codes after the first comma, which a value cut at the comma would leave
	hides "registration codes held in a setting: ${line%%"$codes"*}" "$line\n" "${codes#*,}"
done
for line in "  \"product\": { \"id\": \"SLES\", \"registrationCode\": \"$regcode\" }," \
	"    registrationCode: '$regcode'," "agama config set product.registrationCode=$regcode"; do
	hides "Agama's registrationCode: ${line%%"$regcode"*}" "$line\n" "$regcode"
done
keeps "an Agama profile template" "    registrationCode: '{{SCC_REGCODE}}',\n"
# An AutoYaST profile as the test filled it in and uploaded it.
for case in "    <reg_code>$regcode</reg_code>|regcode" "<REGCODE>$regcode</REGCODE>|regcode" \
	"<ay:registration_code a=\"b\">$regcode</ay:registration_code>|regcode" \
	"      <user_password>$regcode</user_password>|keyed-assignment" "<passwd>$regcode</passwd>|keyed-assignment"; do
	line=${case%|*}
	actual=$(printf '%s\n' "$line" | python3 "$scripts/_secrets.py" 2>/dev/null)
	check "an XML element named for a credential: ${line%%"$regcode"*}" "${line/"$regcode"/[REDACTED:${case#*|}]}" "$actual"
done
keeps "XML elements that hold no credential" "<reg_code></reg_code>\n<reg_code/>\n<reg_code>{{SCC_REGCODE}}</reg_code>\n<reg_code>##Registration-Code##</reg_code>\n<user_password>!</user_password>\n<group_password>x</group_password>\n<password>linux</password>\n<user_password>nots3cr3t</user_password>\n<passwd_encryption>sha512</passwd_encryption>\n<password>ENTER PASSWORD HERE</password>\n"
# An Agama profile as agama config show prints it, and a Jsonnet guest profile once filled.
actual=$(printf '{\n  "product": {\n    "id": "SLES",\n    "registrationCode": "%s",\n    "registrationEmail": ""\n  }\n}\n%s\n%s\n' \
	"$regcode" "  product: { id: 'SLES', registrationCode: '$regcode' }," "    registrationCode: \"$regcode\"," |
	python3 "$scripts/_secrets.py" 2>&1 >/dev/null)
check "registrationCode in a profile dump and in Jsonnet with a bare key" "redacted 3: keyed-assignment=3" "$actual"

# --- JSON escaped into a string, a template filled by sed, an unquoted Perl value ---------
# shellcheck disable=SC2016 # literal $..., as the log prints it
for line in "echo '{\\\"product\\\": {\\\"registrationCode\\\": \\\"$regcode\\\"}}' > /tmp/profile.json" \
	"[debug] <<< testapi::script_run(cmd=\"agama config load <<< '{\\\"registrationCode\\\":\\\"$regcode\\\"}'\")" \
	"\"settings\": \"{\\\"SCC_REGCODE\\\" : \\\"$regcode\\\"}\"" "ROOT_PASSWORD=\\\"$regcode\\\" ./setup.sh"; do
	actual=$(printf '%s\n' "$line" | python3 "$scripts/_secrets.py" 2>/dev/null)
	check "a JSON-escaped key: ${line%%"$regcode"*}" "${line/"$regcode"/[REDACTED:keyed-assignment]}" "$actual"
done
keeps "a JSON-escaped template slot" '{\\"registrationCode\\": \\"{{SCC_REGCODE}}\\"}\n'
# shellcheck disable=SC2016 # literal $..., as the log prints it
for line in "sed -i 's/##Registration-Code##/$regcode/g' /root/combustion/script" \
	"sed -ri 's/##Registration-Password##/$regcode/g;' /tmp/autoyast.xml" \
	"sed -i -e 's|{{SCC_REGCODE}}|$regcode|g' \\" "sed -e 's/@REGCODE@/$regcode/;s/a/b/' f" \
	"[debug] <<< testapi::assert_script_run(cmd=\"sed -i 's/ROOT_PASSWORD/$regcode/g' /root/x.exp\")" \
	"sed -i \"s/\\\$AD_DOMAIN_PASSWORD/$regcode/\" /etc/samba/x.conf"; do
	actual=$(printf '%s\n' "$line" | python3 "$scripts/_secrets.py" 2>/dev/null)
	check "a code filled into a template by sed: ${line%%"$regcode"*}" "${line/"$regcode"/[REDACTED:keyed-assignment]}" "$actual"
done
keeps "sed filling in openQA's public default password" "sed -i 's/ROOT_PASSWORD/nots3cr3t/g' /root/x.exp\n"
keeps "sed changing a setting that names a password" "sed -i 's/#PasswordAuthentication/PasswordAuthentication/' /etc/ssh/sshd_config\n"
keeps "sed with a space in the substitution" "sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config\n"
# shellcheck disable=SC2016 # literal slots, as the source writes them
keeps "sed filling in a variable" 'sed -i "s/{{SCC_REGCODE}}/$SCC_REGCODE/" profile.xml\n'
# shellcheck disable=SC2016 # Perl source, quoted in a ticket
keeps "a Perl substitution of a variable" '$profile =~ s/\\{\\{PASSWORD\\}\\}/$testapi::password/g;\n'
keeps "sed on a word that only starts like PASS" "sed 's/PASSED/OK12345/' result.txt\n"
for line in "my %args = (regcode => $regcode, email => 'a@example.org');" "    'SCC_REGCODE' => $regcode," \
	"{ api_token => $regcode }"; do
	actual=$(printf '%s\n' "$line" | python3 "$scripts/_secrets.py" 2>/dev/null)
	check "an unquoted Perl value: ${line%%"$regcode"*}" "${line/"$regcode"/[REDACTED:keyed-assignment]}" "$actual"
done
keeps "unquoted Perl values that are code" "password => DEFAULT_PASSWORD,\ntoken_timeout => 300,\ntoken => generate_token2(),\npassword => undef,\npassword_hash => sha512,\nregcode => get_required_var('SCC_REGCODE'),\ntoken => \$t1234567,\n"
keeps "an unquoted Perl constant with an underscore" "token => CHECKSUM_SHA256,\nPASSWORD => SLE_15_SP6 }\n"
SECONDS=0
python3 -c "
import sys; sys.path.insert(0, '$scripts')
import _secrets
for line in (' s/' + 'PASSWORD' * 8 + 'x') * 3400, ' s/PASS/' * 30000, 'password => ' + 'a1' * 120000, '\\\\\"password\\\\\": ' * 16000:
    _secrets.redact(line)
"
check "sed templates, bare Perl values and escaped keys on 240k-character lines stay linear" 1 "$((SECONDS < 10))"
# Every "login" within reach of each "docker" was tried with its own window: 1.2 s a line.
actual=$(python3 -c "
import sys, time; sys.path.insert(0, '$scripts')
import _secrets
rule = next(pattern for name, pattern, _ in _secrets.RULES if name == 'password-flag')
line = ('docker login ' * 21846)[:262144]
start = time.perf_counter()
for _ in range(2):
    rule.search(line)
print(time.perf_counter() - start < 1.4, rule.search('docker --config /x login -u bob -p Sup3rS3cretX reg') is not None)
")
check "password-flag: two 256k-character lines of 'docker login ' take under 1.4 s, a real login still matches" "True True" "$actual"

# --- the live system's root password on the installer's boot command line --------------
for value in "Zq9x""Wv" "Xk""9q" "hun""ter2"; do
	for line in "[    0.000000] Kernel command line: BOOT_IMAGE=/boot/x86_64/loader/linux live.password=$value console=ttyS0" \
		"linux /boot/x86_64/loader/linux root=live:CDLABEL=Install live.password=$value inst.auto=http://10.0.2.2/profile.jsonnet" \
		"[debug] [pid:4242] <<< testapi::type_string(string=\" live.password=$value \", max_interval=250)"; do
		actual=$(printf '%s\n' "$line" | python3 "$scripts/_secrets.py" 2>/dev/null)
		check "live.password=, ${#value} characters: ${line%%" live.password="*}" \
			"${line/"live.password=$value"/live.password=[REDACTED:live-password]}" "$actual"
	done
done
# shellcheck disable=SC2016 # literal slots, as documentation writes them
keeps "a live.password slot in documentation" 'live.password=$PASSWORD\nlive.password=<password>\n'
# oqa-job.py --settings and the settings diff of oqa-history.py --investigation print a
# setting by name; both go through setting_value().
cp "$here"/fixtures/oqa-job/api_v1_jobs_500*.json "$here"/fixtures/oqa-history/*5000* "$work/"
python3 -c '
import json, sys
work, codes = sys.argv[1:]
for name in ("api_v1_jobs_500.json", "api_v1_jobs_500_details.json"):
    with open(f"{work}/{name}") as handle:
        data = json.load(handle)
    data["job"]["settings"]["UNIFIED_GUEST_REG_CODES"] = codes
    with open(f"{work}/{name}", "w") as handle:
        json.dump(data, handle)
name = f"{work}/tests_5000_investigation_ajax.json"
with open(name) as handle:
    data = json.load(handle)
data["diff_to_last_good"] = (
    f"-   \"UNIFIED_GUEST_REG_CODES\" : \"{codes[1:]}\",\n"
    f"+   \"UNIFIED_GUEST_REG_CODES\" : \"{codes}\",\n" + data["diff_to_last_good"]
)
with open(name, "w") as handle:
    json.dump(data, handle)
' "$work" "$codes"
actual=$(python3 "$scripts/oqa-job.py" --fixture-dir "$work" https://openqa.example.org/tests/500 --settings REG_CODES 2>&1)
check "oqa-job.py --settings masks registration codes held in a setting" \
	"0 UNIFIED_GUEST_REG_CODES=[REDACTED:secret-setting]" \
	"$(grep -c "${codes%%,*}" <<<"$actual") $(grep -o 'UNIFIED_GUEST_REG_CODES=[^ ]*' <<<"$actual")"
actual=$(python3 "$scripts/oqa-history.py" --fixture-dir "$work" 5000 --investigation --max-items 6 2>&1)
check "oqa-history.py --investigation masks them in the settings diff" \
	"0 UNIFIED_GUEST_REG_CODES: [REDACTED:secret-setting] -> [REDACTED:secret-setting]" \
	"$(grep -c "${codes%%,*}" <<<"$actual") $(grep -o 'UNIFIED_GUEST_REG_CODES: .*' <<<"$actual")"
keeps "-r of other commands after a registration command" 'SUSEConnect --status; rm -r /tmp/registration-cache\nSUSEConnect -s && cp -r /etc/zypp /tmp/zypp-backup\nSUSEConnect -d | grep -r Deregistered /var/log/messages\n'
keeps "-r of other commands" 'zypper -r repo-oss-update in vim\ngrep -r SUSEConnect /etc/zypp/credentials.d\ntransactional-update pkg install vim -r repo-oss-update\n'
# connect-ng's flags are case-sensitive and define -r alone (cmd/suseconnect/suseconnect.go).
keeps "an upper-case -R is no registration code flag" 'SUSEConnect -R ABCD1234EFGH5678\nregistercloudguest -R ABCD1234EFGH5678\n'
# shellcheck disable=SC2016 # literal slots, as documentation writes them
keeps "a registration code slot in documentation" 'SUSEConnect -r <regcode>\nSUSEConnect -r $SCC_REGCODE\nregistercloudguest -r ${REGCODE}\n'

# --- an Azure subscription id, an account identifier with its own rule name -----------
sub="0a1b2c3d""-4e5f-6a7b-8c9d-""0e1f2a3b4c5d"
for line in "GET /metadata/identity/oauth2/token?resource=https%3A%2F%2Fmanagement.azure.com%2Fsubscriptions%2F$sub%2FresourceGroups%2Frg" \
	"az vm show --ids /subscriptions/$sub/resourceGroups/openqa-rg/providers/Microsoft.Compute/virtualMachines/vm" \
	"subscriptionId=$sub" "  \"subscriptionId\": \"$sub\"," "ARM_SUBSCRIPTION_ID=$sub"; do
	actual=$(printf '%s\n' "$line" | python3 "$scripts/_secrets.py" 2>/dev/null)
	check "a subscription id goes, the rest of the line stays: ${line%%"$sub"*}" \
		"${line/"$sub"/[REDACTED:azure-subscription]}" "$actual"
done
check "a subscription id is counted under its own name" "redacted 1: azure-subscription=1" \
	"$(printf 'subscriptionId=%s\n' "$sub" | python3 "$scripts/_secrets.py" 2>&1 >/dev/null)"
keeps "a UUID that is not a subscription" "root=UUID=$sub ro\nThe subscription $sub expired\n"

# A rule alternative is dead unless its own literal passes the TRIGGERS pre-filter.
actual=$(python3 -c "
import sys; sys.path.insert(0, '$scripts')
import _secrets
for rule, literal, line in (
    ('password-flag', 'ipmitool', 'ipmitool -I lanplus -H bmc -U admin -P Sup3rS3cretX chassis status'),
    ('password-flag', 'mysql', 'mysql -u root -pSup3rS3cretX db'),
    ('password-flag', 'sshpass', 'sshpass -p Sup3rS3cretX ssh root@host.example.org uptime'),
    ('password-flag', 'smbclient', 'smbclient //fileserver/share -U bob%Sup3rS3cretX -c ls'),
    ('password-flag', 'helm', 'helm registry login reg.example.org -u bob -p Sup3rS3cretX'),
    ('password-flag', 'podman', 'podman login -u bob -p Sup3rS3cretX quay.example.org'),
    ('password-flag', 'docker', 'docker login -u bob -p Sup3rS3cretX'),
    ('password-flag', 'kubectl', 'kubectl oidc-login -u bob -p Sup3rS3cretX'),
    ('password-flag', 'skopeo', 'skopeo login -u bob -p Sup3rS3cretX quay.example.org'),
    ('password-flag', '--password', 'mytool --password Sup3rS3cretX'),
    ('keyed-assignment', 'password', 'ROOT_PASSWORD=Sup3rS3cretX'),
    ('keyed-assignment', 'passwd', 'ROOT_PASSWD=Sup3rS3cretX'),
    ('keyed-assignment', 'secret', 'CLIENT_SECRET=Sup3rS3cretX'),
    ('keyed-assignment', 'token', 'GIT_TOKEN=Sup3rS3cretX'),
    ('keyed-assignment', 'apikey', 'APIKEY=Sup3rS3cretX'),
    ('keyed-assignment', 'api_key', 'API_KEY=Sup3rS3cretX'),
    ('keyed-assignment', 'access_key', 'ACCESS_KEY=Sup3rS3cretX'),
    ('keyed-assignment', 'private_key', 'PRIVATE_KEY=Sup3rS3cretX'),
    ('keyed-assignment', 'credential', 'CREDENTIAL=Sup3rS3cretX'),
    ('keyed-assignment', 'regcode', 'SCC_REGCODE=Sup3rS3cretX'),
    ('keyed-assignment', 'pwd', 'DB_PWD=Sup3rS3cretX'),
    ('keyed-assignment', 'pw', 'DB_PW=Sup3rS3cretX'),
    ('keyed-assignment', 'pass', 'DB_PASS=Sup3rS3cretX'),
    ('keyed-assignment', 'reg_', 'UNIFIED_GUEST_REG_CODES=Sup3rS3cretX'),
    ('keyed-assignment', 'registration', 'guest_registration_code=Sup3rS3cretX'),
    ('keyed-assignment', 'registration', 'registrationCode=Sup3rS3cretX'),
    ('live-password', 'password', 'live.password=Zq9x'),
    ('regcode', 'suseconnect', 'SUSEConnect -r Sup3rS3cretX'),
    ('regcode', 'transactional-update register', 'transactional-update register -r Sup3rS3cretX'),
    ('regcode', 'registercloudguest', 'registercloudguest -r Sup3rS3cretX'),
    ('azure-subscription', 'subscriptions/', '/subscriptions/0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d/'),
    ('google-oauth-token', 'ya29', 'ya29.A0AfH6SMBc0123456789abcdQRST'),
    ('google-api-key', 'aiza', 'AIzaSyA1234567890abcdefghijklmnopqrstuv'),
    ('slack-webhook', 'hooks.slack', 'hooks.slack.com/services/' + 'T0000AAAA/B0000BBBB/abcdefghijklmnopqrstuvwx'),
):
    hits = [trigger for trigger in _secrets.TRIGGERS if trigger in line.lower()]
    _, found = _secrets.redact(line)
    if not hits or any(trigger not in literal for trigger in hits) or found != {rule: 1}:
        print(literal, hits, dict(found))
")
check "every command and key word reaches its rule through its own trigger" "" "$actual"

# Each input targets one rule's repetition; the first eight cost seconds before they were bounded.
actual=$(python3 -c "
import sys, time; sys.path.insert(0, '$scripts')
import _secrets
rules = {name: pattern for name, pattern, _ in _secrets.RULES}
for name, pattern, text in (
    ('jwt', rules['jwt'], '-ey' * 34000),
    ('pem', _secrets._PEM_BEGIN, '-----BEGIN' * 10000),
    ('url-userinfo', rules['url-userinfo'], 'x://h:' + 'a@' * 500000),
    ('url-userinfo', rules['url-userinfo'], 'x://h:' * 100000),
    ('password-flag', rules['password-flag'], 'pass' + ':a' * 131072),
    ('url-query', rules['url-query'], '?key=' + 'A*' * 50000),
    ('google-oauth-token', rules['google-oauth-token'], 'ya29.' * 60000),
    ('google-api-key', rules['google-api-key'], 'AIza' * 80000),
    ('slack-webhook', rules['slack-webhook'], 'hooks.slack.com/services/' * 20000),
    ('url-bare-query', rules['url-bare-query'], 'https://h/?' + 'A1' * 130000 + '==='),
    ('regcode', rules['regcode'], 'SUSEConnect ' * 20000),
    ('regcode', rules['regcode'], 'transactional-update -n -n -n -n ' * 8000),
    ('regcode', rules['regcode'], 'SUSEConnect -r ' * 16000),
    ('job-token', rules['job-token'], 'http://' + 'h' * 250000),
    ('job-token', rules['job-token'], 'http://h:20013/' * 16000),
):
    start = time.monotonic()
    pattern.subn('', text)
    if time.monotonic() - start > 1:
        print(name)
")
check "adversarial input stays linear in the rule it targets" "" "$actual"

# A key block must not change how many lines the caller sees.
actual=$(printf -- 'a\n-----BEGIN RSA PRIVATE KEY-----\nAAA\nBBB\n-----END RSA PRIVATE KEY-----\nz\n' |
	python3 "$scripts/_secrets.py" 2>/dev/null | wc -l)
check "a swallowed key block keeps the line count" 6 "$actual"

# The scan must stay linear: sanitize() keeps up to 256 KiB of a single line.
SECONDS=0
python3 -c "
import sys; sys.path.insert(0, '$scripts')
import _secrets
_secrets.redact('key' * 80000)
"
check "one 240k-character line stays linear" 1 "$((SECONDS < 10))"

# A log is not always valid UTF-8.
printf 'TOKEN=\377\376 abc\n' | python3 "$scripts/_secrets.py" >/dev/null 2>&1
check "invalid utf-8 is replaced, not a traceback" 0 $?

# --- site formats, which a public repository cannot carry ---------------------------
printf '# a site format\nSUSE-[A-Z0-9]{8}-[A-Z0-9]{4}\n' >"$work/patterns.txt"
actual=$(printf 'regcode SUSE-ABCD1234-EF56 accepted\n' |
	python3 "$scripts/_secrets.py" --scrub-patterns "$work/patterns.txt" 2>/dev/null)
check "a site pattern is applied" "regcode [REDACTED:site] accepted" "$actual"
printf 'x(\n' >"$work/bad.txt"
python3 "$scripts/_secrets.py" --scrub-patterns "$work/bad.txt" </dev/null >/dev/null 2>&1
check "a bad site regex is a usage error, not a traceback" 2 $?
python3 "$scripts/_secrets.py" --scrub-patterns "$work/missing.txt" </dev/null >/dev/null 2>&1
check "a missing patterns file is a usage error" 2 $?

python3 "$scripts/_secrets.py" --help >/dev/null
check "--help exits 0" 0 $?
python3 "$scripts/_secrets.py" --bogus </dev/null >/dev/null 2>&1
check "bad option exits 2" 2 $?

exit $fail
