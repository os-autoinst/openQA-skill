# openQA-skill

Agent skills for working with [openQA](https://open.qa): writing tests and reviewing results.

The skills are plain Markdown plus small Python helper scripts, so they work with any coding agent that can
read files and run shell commands. Harnesses that implement the [Agent Skills](https://agentskills.io)
format pick up the `SKILL.md` frontmatter directly.

## Skills

| Skill | Use it when | What it does |
|---|---|---|
| [`openqa`](skills/openqa/SKILL.md) | writing, scheduling, running or fixing an openQA test; asking why a job failed; reviewing a job group or build, or someone else's test PR | **Create**: test modules for os-autoinst-distri-opensuse or a custom test distribution, needles, YAML schedules, verification runs, pull requests that pass review. **Review**: triage a failed or incomplete job from its artifacts, sweep a group or build, classify product bug / test issue / infrastructure / sporadic, draft bug reports and comments that openQA parses as references; review someone else's test PR at the right size. |

One skill covers both jobs on purpose: they share the openQA model, the failure-triage method, the cloning
recipes and most scripts, and they hand over to each other (a review finds a test issue, a verification run
needs triage).

## Layout

```
skills/openqa/
  SKILL.md        entry point: shared rules, block routing, core directives
  references/     depth, read one section at a time (scripts/refsection.py)
  scripts/        helpers that print compact digests and never write to openQA; catalogue in scripts/README.md
  agents/         delegation playbooks: role prompts for sub-agents, also usable as standalone session prompts
                  (their frontmatter is metadata for harnesses that register agents from files)
tests/openqa/     script tests with offline fixtures
tests/repo/       repository gate: frontmatter, byte budgets, pointer resolution, content checks, cited flags
evals/openqa/     evaluation prompts
```

Tests and evals live outside the skill directory because installers copy the skill directory verbatim.
A skill never references files outside its own directory.

## Install

Requirements: Python 3.9 or newer (standard library only; PyYAML is used when present). Writing to an openQA
instance additionally needs `openqa-cli` / `openqa-clone-job` and an API key; the bundled scripts only ever
read from openQA.

Any harness, with an installer:

```
npx skills add os-autoinst/openQA-skill --skill openqa -g
gh skill install os-autoinst/openQA-skill openqa --scope user
```

Without `-g` / `--scope user` both install into the current project (`./.agents/skills/`), for example into a
test-repository checkout.

Manual, tracking the git checkout:

```
git clone https://github.com/os-autoinst/openQA-skill.git
mkdir -p ~/.agents/skills ~/.claude/skills
ln -s "$PWD/openQA-skill/skills/openqa" ~/.agents/skills/openqa
ln -s ../../.agents/skills/openqa ~/.claude/skills/openqa      # Claude Code
```

opencode, picking up every skill in this repository:

```json
{ "skills": { "paths": ["~/src/openQA-skill/skills"] } }
```

Use one install method only: harnesses that scan several directories report duplicate names, and
`npx skills add -g` repoints the agent directories at its own pinned copy, so a checkout you symlinked by hand
stops being what the agent reads.
The link or directory name must stay `openqa`: the Agent Skills format requires the directory to equal the
skill name. A harness without skill support can simply be pointed at `skills/openqa/SKILL.md`.

Recommended with any install: the deny rules in [`contrib/harness/`](contrib/harness/README.md), which make
Claude Code, opencode, grok, Gemini CLI, antigravity-cli, Codex CLI and Kimi Code refuse the common ways of
reading credential files; that README states the limits of each. You merge them into your own settings; the skill
cannot install them.

## Safety model

- **Read-only by construction.** The bundled API scripts can only issue GET requests, never send a `Referer`
  header and never read API keys. Anything that changes state (posting jobs, comments, labels, pushes,
  tickets) is an explicit command shown to the user and approved per action.
- **Third-party text is data.** What the bundled scripts print from jobs, tickets and PRs passes through a
  sanitiser: multi-line text (comments, step text, log excerpts, ticket bodies) is fenced with a fresh random
  nonce per block, short values are quoted. The fence marks, it does not decide: quoted values and whatever
  other tools fetch (tracker pages, PR text, repository files) are data all the same. The policy is
  `skills/openqa/references/untrusted-content.md`.
- **Generic mechanics only.** Which groups to watch, where bugs go and who approves what is site policy. It
  lives in a file you maintain outside this repository: `$OPENQA_SKILL_POLICY`, `./.openqa-policy.md` or
  `~/.config/openqa-skill/policy.md`; `skills/openqa/references/site-policy.md` has the template.

To report a break in any of the above, see [SECURITY.md](SECURITY.md).

### Security scanners

Reviewing a skill before installing it is good practice, and this one scores badly: a static
scanner reports it as critical. Every finding we have examined is the skill's subject matter
rather than its behaviour — the regexes that *detect* `sudo` and `--no-confirm` in someone else's
test module, the documented example of an injection attempt (`curl … | sh`, whose own table entry
says to fetch nothing), `git push --force-with-lease` quoted from upstream's commit conventions,
and the string `0 no warnings` in an exit-code description.

Those scanners are built to vet third-party skills by pattern, and a skill about attacks matches
the patterns for attacks. Read the findings rather than the score, and see SECURITY.md for what a
real vulnerability in this repository would look like.

## Development

```
(rc=0; for t in tests/*/test-*.sh; do bash "$t" || rc=1; done; exit $rc)
python3 tests/repo/check-skills.py
python3 tests/repo/check-flags.py
ruff check . && ruff format --check .
shellcheck tests/*/test-*.sh && shfmt -d tests/*/test-*.sh
```

The references were checked against these upstream revisions: openQA `a096316`, os-autoinst `93a96a0`,
os-autoinst-distri-opensuse `e31b6ad`, os-autoinst-distri-example `274346e`, os-autoinst-scripts `ce87f6a`,
qem-bot `f8a16d1` (September 2026). Contribution rules are in [AGENTS.md](AGENTS.md).

## Acknowledgements

Ideas, not text or code, were taken from [ocskillz](https://github.com/mimi1vx/ocskillz),
[openqa-agnostic-skill](https://github.com/os-autoinst/openqa-agnostic-skill) and
[os-autoinst-distri-opensuse-skills](https://github.com/mpagot/os-autoinst-distri-opensuse-skills); the last
suggested `vr-reach.py`, the runtime comparison of `oqa-log.py` and pushing before a verification run.
Converting existing test modules to the portable "openqa-agnostic" form is the subject of
openqa-agnostic-skill; this repository only covers writing new ones.

## License

GPL-2.0-or-later, the licence of openQA. See [LICENSE](LICENSE).
