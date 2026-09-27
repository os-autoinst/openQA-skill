#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Replace credential-shaped values in third-party text before an agent reads them.
"""A mitigation, not a boundary.

openQA hides settings whose NAME matches `^_SECRET_|_PASSWORD` from `vars.json`. It
does nothing about a value a test interpolated into a command, which is what
`autoinst-log.txt`, `serial*.txt` and the step details actually record. This catches
credentials with a recognisable shape on the way past; it cannot catch a password that
looks like a word, a value echoed without its key (`set -x` expands `$PASSWORD` to the
value and loses the name), or a token split across a line wrap. A log known to have
held a live credential needs that credential rotated, not redacted.
"""

import re
import sys
from collections import Counter

MARK = "[REDACTED:{}]"

# Running total across a process, so a script can say on stderr that a secret was
# present. A silent redactor teaches people to trust it; a loud one tells them to
# rotate the credential.
_TOTAL = Counter()

# Cheap pre-filter: a line without one of these cannot match any rule, so the regex
# table never runs on the overwhelming majority of log lines.
TRIGGERS = (
    "://",
    "-----begin",
    "auth",
    "bearer",
    "basic",
    "ghp_",
    "gho_",
    "ghu_",
    "ghs_",
    "ghr_",
    "github_pat_",
    "glpat-",
    "xox",
    "ey",
    "pass",
    "pw",
    "secret",
    "token",
    "key",
    "credential",
    "regcode",
    "sig",
    "x-api",
    "curl",
    "wget",
    "ipmitool",
    "mysql",
    "sshpass",
    "smbclient",
    "helm",
    "podman",
    "docker",
    "kubectl",
    "skopeo",
    # every prefix the aws-key-id rule alternates over; a missing one disables it
    "a3t",
    "agpa",
    "aida",
    "aipa",
    "akia",
    "anpa",
    "anva",
    "aroa",
    "asia",
)

# Values that are not secrets however they are spelled. Without these the table
# redacts its way through a normal log and gets switched off.
PLACEHOLDERS = frozenset(
    [
        "none",
        "null",
        "true",
        "false",
        "empty",
        "unset",
        "changeme",
        "placeholder",
        "password",
        "passwd",
        "secret",
        "token",
        "redacted",
        "xxx",
        "test",
        "example",
        "dummy",
        "foo",
        "bar",
        "nots3cr3t",
    ]
)
_UUID = re.compile(
    r"\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z"
)
_PATH = re.compile(r"\A[~.]{0,2}/[\w./+-]*\Z")
_TEMPLATE = re.compile(
    r"\A(?:[$%]\{[^}]*\}|\$\([^)]*\)|\{\{[^}]*\}\}|<[^>]*>|%\w+%|\$\w+)\Z"
)
# openQA invalidates JOBTOKEN when the job finishes, so it is dead by the time anyone
# reads the log; redacting it only trains people to ignore the warnings.
_ALLOW_KEYS = re.compile(r"\A(JOBTOKEN|NAME|CASEDIR|NEEDLES_DIR)\Z", re.IGNORECASE)


# openQA hides a setting from vars.json when its NAME matches this shape. It does not
# hide SCC_REGCODE - its own documentation offers that as the example needing
# _HIDE_SECRETS_REGEX, which nothing in the test distribution actually sets. And
# oqa-job.py reads settings off /api/v1/jobs/<id>, a different surface from vars.json
# with no such guarantee, so the check has to happen here.
_SECRET_KEY = re.compile(
    r"(?i)_SECRET_|PASSW|SECRET|TOKEN|REGCODE|APIKEY|API_KEY|ACCESS_KEY|CREDENTIAL|PRIVATE_KEY"
    r"|PWD|(?<![A-Z])PW(?![A-Z])|PASS(?![A-Z])"
)


def is_secret_key(name):
    """True when a setting's NAME says its value is a credential."""
    name = str(name)
    return bool(_SECRET_KEY.search(name)) and not _ALLOW_KEYS.match(name)


def setting_value(name, value, shown):
    """The value to print for a setting, redacted when the name gives it away."""
    if is_secret_key(name):
        _TOTAL["secret-setting"] += 1
        return MARK.format("secret-setting")
    return shown


def _is_placeholder(value):
    """True when a value cannot be a live credential, whatever its shape."""
    bare = value.strip("'\"")
    if len(bare) < 6 or bare.lower() in PLACEHOLDERS:
        return True
    if _TEMPLATE.match(bare) or _PATH.match(bare):
        return True
    # A UUID is the common false positive. A hex digest is deliberately NOT vetoed: this
    # runs only after the key name said "credential", and a 32-hex API_KEY is a real key.
    return bool(_UUID.match(bare))


def _keep_head(match):
    """Redact the secret group, keep what makes the line useful for triage."""
    return match.group(1) + MARK.format(match.lastgroup or "secret")


# A documentation slot ($VAR, ${VAR}, {{ var }}, <var>, %VAR%) is not a value; a
# percent-encoded one (%2B...) is.
_SLOT = r"(?![$<]|\{\{|%(?![0-9A-Fa-f]{2}))"

# (id, pattern, replacement). Order matters: a specific rule must win over a general
# one, so a token inside an Authorization header is reported as that rule.
RULES = (
    # Tier A - a literal prefix that cannot occur by accident.
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,255}\b"), None),
    ("github-pat", re.compile(r"\bgithub_pat_[A-Za-z0-9]{22}_[A-Za-z0-9]{59}\b"), None),
    ("gitlab-token", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}\b"), None),
    (
        "aws-key-id",
        re.compile(
            r"\b(?:A3T[A-Z0-9]|AKIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ASIA)[A-Z0-9]{16}\b"
        ),
        None,
    ),
    ("slack-token", re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{10,48}\b"), None),
    (
        "jwt",
        re.compile(
            r"(?<![A-Za-z0-9_-])ey[A-Za-z0-9_-]{17,}\.ey[A-Za-z0-9_-]{17,}\.[A-Za-z0-9_-]{10,}"
        ),
        None,
    ),
    # Tier B - the structure carries the signal; keep the diagnostic half. Which host
    # and which account a job used is evidence; the password is not.
    # A token used as the whole userinfo (https://<token>@host; "git@" is too short, and a
    # host name there is a spoof of the real host), or as the user name before an empty or
    # filler password. Before url-userinfo, which would redact only the filler.
    (
        "url-token",
        re.compile(
            r"([a-zA-Z][a-zA-Z0-9+.-]{0,30}://)"
            r"(?:(?![A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+@)[A-Za-z0-9._~+%-]{16,256}(?=@)"
            r"|[^/\s:@\[]{1,256}(?=:(?:x-oauth-basic|x-access-token)?@))"
        ),
        r"\1" + MARK.format("url-token"),
    ),
    # A password never holds "://"; stopping there keeps a line of URLs linear.
    (
        "url-userinfo",
        re.compile(
            r"([a-zA-Z][a-zA-Z0-9+.-]{0,30}://[^/\s:@\[]{0,64}:)"
            r"(?!\d{1,5}(?:[/?#\s]|$))(?:(?!://)[^\s@\"]|@(?=[^\s/@\"]*@)){1,512}@"
        ),
        r"\1" + MARK.format("url-userinfo") + "@",
    ),
    (
        "auth-header",
        re.compile(
            r"(?i)((?:Authorization|Proxy-Authorization)['\"]?\s*:\s*['\"]?(?:[A-Za-z][\w-]*\s+)?)[^\s'\"]{8,}"
        ),
        r"\1" + MARK.format("auth-header"),
    ),
    (
        "curl-user",
        re.compile(
            r"(?i)((?:curl|wget)\b[^\n]{0,200}?(?:\s-u[= ]?|\s--user[= ])['\"]?[^\s:'\"]{1,64}:)[^\s'\"]{1,256}"
        ),
        r"\1" + MARK.format("curl-user"),
    ),
    (
        "password-flag",
        re.compile(
            r"(?i)((?:ipmitool\b[^\n]{0,200}?\s-P|(?:mysql|sshpass|smbclient)\b[^\n]{0,200}?\s-p|smbclient\b[^\n]{0,200}?\s-U\s*[^\s%]{1,64}%|(?:helm|podman|docker|kubectl|skopeo)\b[^\n]{0,80}?\blogin\b[^\n]{0,200}?\s-p|[^\n]{0,200}?\s--password)[ =]?)\S{4,}"
        ),
        r"\1" + MARK.format("password-flag"),
    ),
    (
        "registry-auth",
        re.compile(r'("auth"\s*:\s*")[A-Za-z0-9+/=]{16,}(")'),
        r"\1" + MARK.format("registry-auth") + r"\2",
    ),
    # openQA signs requests with X-API-Key and X-API-Hash; a debug dump shows both.
    (
        "api-key-header",
        re.compile(
            r"(?i)((?:X-API-(?:Key|Hash)|X-Auth-Key|Api-Key)['\"]?\s*:\s*['\"]?)[^\s'\"]{6,}"
        ),
        r"\1" + MARK.format("api-key-header"),
    ),
    # openqa-cli --apikey K --apisecret S; a <slot> or $VAR in documentation stays.
    (
        "api-flag",
        re.compile(
            r"(?i)(--api-?(?:key|secret)(?:\s+|=)['\"]?)" + _SLOT + r"[^\s'\"]{6,}"
        ),
        r"\1" + MARK.format("api-flag"),
    ),
    # openQA's job_settings route passes a setting NAME as ?key=, and a JMESPath filter
    # reads Tags[?Key==`Name`]; neither is a value.
    (
        "url-query",
        re.compile(
            r"(?i)([?&](?:key|api[-_]?key|sig|signature|x-amz-signature|x-amz-credential"
            r"|x-amz-security-token|auth)=)" + _SLOT + r"(?!=)"
            r"(?!(?-i:[A-Z0-9]*[_*][A-Z0-9_*]*(?:[&#\s'\"]|$)))[^&\s#'\"]{6,}"
        ),
        r"\1" + MARK.format("url-query"),
    ),
    # client.conf and similar INI files: "key = ...", commented out or quoted too (the
    # "secret =" line is keyed). A value that runs into code or starts a path is not a key.
    (
        "ini-key",
        re.compile(
            r"(?im)^(\s*(?:[#;]\s*)?key\s*=\s*['\"]?)(?!/)[A-Za-z0-9+/=_-]{6,}(?=['\"]?\s*$)"
        ),
        r"\1" + MARK.format("ini-key"),
    ),
)

# Tier C - only fires next to a key that names a credential, and only after the vetoes.
# `sanitize()` sees "hunter2", never "PASSWORD=hunter2", so this is the only rule that
# can know an SCC_REGCODE value is secret.
# JSON, Python and Perl forms too, where a string value is quoted and anything else is
# code. The short names count in upper case only: "pass=12|skip=0" and "TPASS:" are
# test results.
_KEYED = re.compile(
    r"(?i)(?<![A-Z0-9_])([A-Z0-9_]{0,40}(?:PASSWORD|PASSWD|SECRET|TOKEN|APIKEY|API_KEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL|REGCODE"
    r"|(?-i:PWD|(?<![A-Z])PW(?![A-Z])|PASS(?![A-Z0-9_]|\s*:)))[A-Z0-9_]{0,40})"
    r"((?:['\"]\s*(?:=>|[:=])|\s*=>)\s*(?=['\"])|\s+[:=]\s*|:\s*|=)(['\"]?)([^\s'\"]+)"
)

# A marker in the SOURCE text is an attacker dressing a secret as already-redacted.
_IS_MARK = re.compile(r"\[REDACTED:[a-z-]+\]")
_PEM_BEGIN = re.compile(r"-----BEGIN[ A-Z0-9_-]{0,64}PRIVATE KEY(?: BLOCK)?-----")
_PEM_END = re.compile(r"-----END[ A-Z0-9_-]{0,64}PRIVATE KEY(?: BLOCK)?-----")


def _keyed_sub(match, found):
    key, sep, quote, value = match.groups()
    # A more specific rule already replaced this value; keep its name, which tells the
    # reader what kind of credential it was.
    if _IS_MARK.fullmatch(value):
        return match.group(0)
    if _ALLOW_KEYS.match(key) or _is_placeholder(value):
        return match.group(0)
    found["keyed-assignment"] += 1
    return f"{key}{sep}{quote}{MARK.format('keyed-assignment')}"


# Site-specific credential formats cannot live in a public repository. They arrive
# through an explicit argument, never an environment variable or a file under $HOME:
# implicit configuration is how a script picks up a credential by accident.
_SITE = []


def load_patterns(path):
    """Add one regex per line from a file; '#' comments and blank lines ignored."""
    added = 0
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                _SITE.append(re.compile(line))
            except re.error as error:
                raise ValueError(f"{path}:{number}: {error}") from None
            added += 1
    return added


def redact(text):
    """Return (text with credential-shaped values replaced, per-rule counts).

    Line structure is preserved: callers number lines and account for omitted bytes.
    """
    found = Counter()
    out, in_pem = [], False
    for line in text.split("\n"):
        if in_pem:
            if _PEM_END.search(line):
                in_pem = False
            out.append("")  # keep the line count: callers number lines
            continue
        if _PEM_BEGIN.search(line):
            # A key body is many lines of base64 that no line rule would match; swallow
            # to the END marker rather than emitting it one harmless-looking line at a time.
            in_pem = True
            found["private-key"] += 1
            out.append(MARK.format("private-key"))
            continue
        low = line.lower()
        if any(trigger in low for trigger in TRIGGERS):
            for name, pattern, replacement in RULES:
                line, hits = pattern.subn(replacement or MARK.format(name), line)
                if hits:
                    found[name] += hits
            line = _KEYED.sub(lambda m: _keyed_sub(m, found), line)
        for pattern in _SITE:
            line, hits = pattern.subn(MARK.format("site"), line)
            if hits:
                found["site"] += hits
        out.append(line)
    if in_pem:
        # Fail closed: a BEGIN with no END means the body is still ahead of us.
        out.append(MARK.format("private-key"))
    _TOTAL.update(found)
    return "\n".join(out), found


def total():
    """What this process has redacted so far."""
    return Counter(_TOTAL)


def reset():
    _TOTAL.clear()


def summary(found):
    """One line for stderr, so a redaction is visible and the secret gets rotated."""
    if not found:
        return ""
    parts = ", ".join(f"{name}={count}" for name, count in sorted(found.items()))
    return f"redacted {sum(found.values())}: {parts}"


def main(argv=None):
    # imported here: _sanitize imports this module
    from _sanitize import ArgumentParser

    parser = ArgumentParser(
        description="Replace credential-shaped values on stdin. A mitigation, not a boundary: "
        "shapeless passwords, values echoed without their key and tokens split across a line "
        "wrap all survive. Rotate a credential that reached a log; do not assume this caught it.",
        epilog="Exit codes: 0 nothing redacted, 1 at least one redaction, 2 usage error.",
    )
    parser.add_argument("--quiet", action="store_true", help="no summary on stderr")
    parser.add_argument(
        "--scrub-patterns",
        metavar="FILE",
        help="extra regexes, one per line, for credential formats this table does not know",
    )
    args = parser.parse_args(argv)
    if args.scrub_patterns:
        try:
            load_patterns(args.scrub_patterns)
        except (OSError, ValueError) as error:
            parser.error(str(error))
    text, found = redact(sys.stdin.buffer.read().decode("utf-8", "replace"))
    sys.stdout.write(text)
    if found and not args.quiet:
        print(summary(found), file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
