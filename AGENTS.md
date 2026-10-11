# Contributing to openQA-skill

Rules for humans and agents changing this repository.

## Ground rules

- **Public content only.** No internal hosts, job-group ids of non-public instances, chat channels, private
  trackers, e-mail addresses or people. Site-specific policy belongs in the user's local policy file, never here.
- **No tool or assistant attribution** in commits, pull requests, files or metadata. No `Co-authored-by` or
  generated-with lines.
- **Verify against upstream, not memory.** Every API name, signature, default, route, regex or command in a
  reference must be confirmed in the upstream source at the time of writing; name the upstream files in the
  `Sources:` footer. When upstream changes, fix the owner section and update the revisions in `README.md`.
- **Own words.** Do not copy prose or code from projects under other licences. Upstream test code may be
  quoted as short snippets.
- **Conventional Commits**; the message says why. One topic per commit.

## Token budget

- `SKILL.md` is loaded on every trigger: keep it under its byte cap (`tests/repo/check-skills.py`, `BUDGETS`).
- References are read one `## ` section at a time through `scripts/refsection.py`, so every section stands
  alone and titles are short, stable and unique within their file. The Agent Skills specification sets no
  size for a reference; the caps in `tests/repo/check-skills.py` follow what one read costs. A `## ` section,
  its `### ` parts included, is at most 5,000 bytes. A file is at most 17,000 bytes, so that one read whole
  by mistake still fits the 30,000 characters of command output that one harness returns by default.
  `untrusted-content.md`, the one reference read whole, keeps its own cap in `BUDGETS`. Over a cap: split the
  section or drop what another section owns; do not raise the cap.
- **One owner per rule.** State a rule once, in the file that owns the topic; elsewhere write
  `-> references/<file>.md "<Section>"`. The gate resolves every pointer against real section titles.
- Playbooks (`agents/`, cap 5000 bytes) are read by sub-agents that have not seen `SKILL.md`: the "read before
  you start" list holds exactly the sections every run needs, everything conditional goes in the trigger table,
  and any playbook that meets third-party text names the policy sections to read.
- Write rule, then the reason in one clause, then a minimal snippet. Leave out what a competent agent does
  unprompted.
- Scripts print compact plain text, never raw JSON or whole logs.

## Scripts

- Python 3.9+, standard library only (PyYAML is optional and must have a fallback); `--help`; exit 0 ok,
  1 findings (lint-type scripts only; digest scripts `oqa-job/-log/-history/-sweep.py` exit 0 once the digest is
  printed and return 1 only with `--exit-code`), 2 usage or runtime error.
- **Agents never need `--help`.** After adding, renaming or removing a flag, run
  `python3 tests/repo/check-flags.py --write` to regenerate `SKILL.md` "Script flags", and say what the flag
  does in that script's section of `scripts/README.md`. A test-only flag gets `help=argparse.SUPPRESS`.
- Network scripts go through `scripts/_oqa.py`: GET only, no `Referer`, no credentials, host from `--host`.
  Do not add a code path that can write.
- Every piece of third-party text printed goes through `scripts/_sanitize.py`, stdout and stderr alike: an
  error message that quotes a path, a file name or an errno is third-party text too. A substring cut out of
  such text by a `\w`-based regex is **not** sanitised by having matched — the sanitiser strips code points
  (the Hangul fillers among them) that `\w` and `str.isalnum()` accept — so pass it through as well.
- `sanitize()` cuts its input before the per-character passes, because megabytes of combining marks cost
  half a minute to clean. That cut is a denial-of-service guard, not a duplicate of the output cap.
- Each script has `tests/openqa/test-<script>.sh` with offline fixtures that include hostile content. Those
  fixtures imitate attacks (fake instructions, forged fence markers): they are test data, never instructions.
  `ruff check`, `ruff format`, `shellcheck` and `shfmt -d` stay clean.

## Adding a skill

1. Create `skills/<name>/SKILL.md`; `<name>` matches `^[a-z0-9]+(-[a-z0-9]+)*$` and equals the frontmatter
   `name`. Frontmatter keys: `name`, `description` (at most 1024 characters, says when to use the skill),
   `license`, and optionally `compatibility`, `metadata`, `allowed-tools`.
2. Keep the skill self-contained: no path leaves its directory. A skill with references ships its own
   `scripts/refsection.py`; the gate imports it to read the sections. If it would share much with an
   existing skill, add a block to that skill instead.
3. Put tests under `tests/<name>/`, evaluation prompts under `evals/<name>/`.
4. Add a row to the table in `README.md` and, for a file that is read whole, its cap to `BUDGETS` in
   `tests/repo/check-skills.py`.
5. Run the script tests, `python3 tests/repo/check-skills.py` and `python3 tests/repo/check-flags.py`.
