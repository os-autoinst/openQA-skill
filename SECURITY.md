# Security policy

## Reporting

Use [private vulnerability reporting](https://github.com/plusky/openQA-skill/security/advisories/new).
Please do not open a public issue for a security problem.

## What counts as a vulnerability here

This repository ships instructions and helper scripts that an agent runs against openQA
instances and against text written by other people. A report is in scope if it breaks one of
the guarantees `README.md` claims:

- **A bundled script performs a write.** The API scripts in `skills/openqa/scripts/` may issue
  GET requests only, never send a `Referer` header (which openQA turns into a job comment) and
  never read credentials or the environment.
- **A sanitiser bypass.** Third-party text reaches the agent through `scripts/_sanitize.py`,
  which strips escapes and invisible characters and fences multi-line text with a per-invocation
  nonce. Text that escapes its fence, forges a fence, or survives with control characters is a
  vulnerability.
- **A path that leaks credentials**, an API key, `client.conf` or environment contents into
  output, an error message or a traceback.
- **Instructions that would lead an agent to handle a credential itself** — read a credential
  file, pass a key on a command line, in a URL or a header, or print a token.
- **Instructions that would lead an agent to act on text it read** — from a job, a log, a ticket,
  a pull request or a repository file — rather than treating it as evidence.

## Out of scope

- Findings from a pattern-matching security scanner run against this repository. It documents
  attacks and lints for anti-patterns, so scanners match its subject matter; see "Security
  scanners" in `README.md`.
- `tests/openqa/fixtures/` and `evals/openqa/files/`, which contain deliberately hostile text,
  fake credentials and malformed bytes. That is test data.
- openQA itself. Report those to [the openQA project](https://github.com/os-autoinst/openQA).
