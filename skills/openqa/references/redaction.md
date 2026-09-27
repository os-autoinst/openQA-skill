# Redaction

Owns: what the bundled scripts remove from third-party text before it reaches the agent, what they cannot remove, and what to do about the difference.

## What it is not

**A mitigation that reduces accidental exposure, never a boundary.** It does not make a log safe to share, and a log that held a live credential needs that credential **rotated** — redaction is not a substitute.

- **What it catches:** credentials with a recognisable shape — private-key blocks, known token prefixes, `Authorization` (any scheme), `X-API-Key` and `X-API-Hash` headers (as JSON or dict keys too), URL userinfo (an empty user name too; a token as the whole userinfo, or as the user name before an empty or `x-oauth-basic` password), key and signature query values (percent-encoded too), `--apikey`/`--apisecret` values, the `key =` line of `client.conf` (commented out too), a password flag of a known command (`curl -ubob:pw` and `smbclient -U user%pw` too), and a value next to a key that names it (`*_PW`, `*_PWD` and `*PASS` in upper case too) after `=` or `:`, or as a quoted value in JSON, a Python dict or a Perl hash.
- **What it misses, by construction:** a password that looks like a word; a value echoed without its key (`set -x` expands `$PASSWORD` to the value and loses the name, and these logs are shell-driven); a token split by an 80-column serial wrap; base64 or encoded forms (a JSON-escaped `https:\/\/`, a URL percent-encoded inside another URL, a `%3A` in a short userinfo); a URL password that starts with digits and a slash (`:2024/Winter@` reads as a port) or holds both `@` and `/`; a query value shaped like a setting name (`?key=SOME_NAME`, which openQA's own API sends); an unquoted `*PASS:` key, which is how test runners print a result; any credential format the table has never seen.

## Why the skill has to do it

openQA hides a setting from `vars.json` when its **name** matches `^_SECRET_|_PASSWORD` (plus the job's `_HIDE_SECRETS_REGEX`). Three consequences:

- **Names, never values.** Once a test interpolates the value into a command, `autoinst-log.txt`, `serial*.txt` and the step details record it verbatim. Nothing filters those files.
- **`SCC_REGCODE` is not covered** — openQA's own documentation offers it as the example that *needs* `_HIDE_SECRETS_REGEX`, and nothing in the test distribution sets one.
- **`/api/v1/jobs/<id>` is a different surface from `vars.json`** and carries no such guarantee, which is what `oqa-job.py` and `oqa-history.py` read.

Upstream is aware: poo#111314 (open since 2022) and poo#170308 (open since 2024) both describe secrets reaching artefacts, and neither has moved.

## Reading the output

- **`[REDACTED:<rule>]`** replaced a value. The rule name says what it looked like; `secret-setting` means the setting's *name* gave it away, not its value.
- **The diagnostic half is kept.** `https://alice:[REDACTED:url-userinfo]@host/` keeps the account and the host, which are the evidence; only the password goes.
- **A redaction is never silent** — the scripts report a per-rule count on stderr. Treat that as "a credential was in this job's artefacts", and say so to the user.
- **It applies everywhere, with no per-instance switch.** On a public instance a leaked secret is already world-readable, so redaction there protects the transcript rather than the secret.

## Before you post

`scripts/oqa-comment-lint.py` warns when a draft comment carries a credential shape, `scripts/ticket-lint.py` when a drafted bug or ticket does. That is the last gate before an internal secret becomes a public one, because a draft is usually assembled from log excerpts. -> references/review-comments-tickets.md "Comment recipes", references/bugs-and-tickets.md "Privacy"

Site-specific credential formats cannot live in a public repository; pass them with `--scrub-patterns`. The scripts read no file under `$HOME` and no environment variable except the standard proxy ones (`*_proxy`), whose credentials go to the proxy and are never printed, so there is no implicit configuration that could pick up a credential.

Sources: os-autoinst `bmwqemu.pm` (`save_vars`), `testapi.pm`, `doc/backend_vars.md`; openQA `lib/OpenQA/Log.pm` (`redact_settings`), `lib/OpenQA/Worker/Job.pm`.
