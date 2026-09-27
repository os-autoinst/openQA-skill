# Harness snippets: keep credential files away from the agent

The skill's rule is that credentials stay inside the tools: an agent never reads openQA's
`client.conf`, gh's `hosts.yml`, osc or tea configs or `.netrc`, never prints a token and never
passes a key on a command line (`skills/openqa/references/untrusted-content.md`, "Rules" 4).
These snippets make the harness refuse such calls as well, so the rule does not rest on the
model alone.

**You install them yourself.** An agent must not change its own permissions, and most harnesses
refuse to let it. **Merge, do not replace**: each file holds only the keys to add to your
existing settings. Each snippet uses only documented syntax and was checked against the version
named below.

gh keeps its token in the desktop keyring, reached over D-Bus, so no file rule stops
`gh auth token`: only the command rules do, and a fake `$HOME` does not isolate it either.
The same goes for the tools that print their own secrets: `gh auth git-credential`, `git
credential fill` and the credential helpers' `get`, `secret-tool lookup`, `osc config
--dump-full`, osc's `-H` and `--http-debug`, `osc token`, `tea login helper` and `tea login
edit`, and `git-obs login list` are denied by name in every snippet; most also catch osc's
option clusters and abbreviations, its `http_debug` settings and its token API path.

All but the Codex and agy snippets, which match argv prefixes, also refuse a command with a
password in a URL (`user:password@` before the host) and an `Authorization:` header after `-H`,
`--header` or an option cluster such as `-sH`, or anywhere in an `openqa-cli` call, which also
takes `-a`. The glob snippets (Claude Code, opencode, grok) match any `://`, a later `:` and a
later `@`, so a PR body with a link and a mention is refused as well: pass such text as a file
(`--body-file`).

They all match text, not intent. A path spelled with a glob or a variable, split quoting, a line
continuation (only the Kimi hook joins one), a relative path after `cd` or under a shell tool's
own working-directory argument (only the Kimi hook resolves Kimi's `cwd`), a recursive read of an
ancestor directory such as `grep -r token ~`, a script written first and run later, or a program
that opens the file itself gets past every one of them. So does a global option in front of a
printer's subcommand (`osc -A obs token`, `tea --debug login edit`) for the glob, Codex and agy
rules, and a key the agent reads from its environment for all but Codex, which drops `*KEY*`,
`*SECRET*` and `*TOKEN*` variables from commands. For a hard boundary, run the agent in the
harness's sandbox (or a container) that does not mount these files.

| Harness | Snippet | Goes into |
|---|---|---|
| Claude Code | `claude/settings.json` | `permissions.deny` of `~/.claude/settings.json` |
| opencode | `opencode/opencode.jsonc` | `permission` of `~/.config/opencode/opencode.jsonc` (or `.json`) |
| grok | `grok/config.toml` | `[permission]` of `~/.grok/config.toml` |
| Gemini CLI | `gemini/openqa-credentials.toml` | copy to `~/.gemini/policies/openqa-credentials.toml` |
| antigravity-cli (`agy`) | `agy/settings.json` | `~/.gemini/antigravity-cli/settings.json`; replace `/home/USER` |
| OpenAI Codex CLI | `codex/config.toml`, `codex/openqa-credentials.rules` | `~/.codex/config.toml`; `~/.codex/rules/` |
| Kimi Code | `kimi/config.toml`, `kimi/openqa-credentials.py` | `~/.kimi-code/config.toml`; `~/.kimi-code/hooks/` |

## Claude Code

Checked on Claude Code 2.1.283 in print mode (`-p`), with a `--settings` file and a dummy file: the `Read(...)` rules stop
the Read tool, and the `Bash(*...*)` rules stop a command that names the path. **A `Read` rule
alone did not stop `cat` of the same file** in that run, which contradicts the permissions
documentation (a `Read` deny also covers `cat`, `head` and the other file commands it recognises).
Keep the command rules either way: they also catch readers it does not recognise, such as `python3`.
A rule that ends in `:*` is Claude Code's legacy prefix form and never matches as a glob, so none
of these does. Paths use `~/` for the home directory and `//` for an absolute path;
`$OPENQA_CONFIG` cannot be named, so a config kept there needs its own `Read(//...)` line.

## opencode

Checked on 1.18.32: `opencode debug config` loads all 69 rules, and `opencode debug agent build
--tool read` refuses the credential paths in a throw-away home. The last matching rule wins, so
keep these after any `"*"` rule. The `.env` lines are deliberate: the built-in ones only ask, and
an "always" answer to a read prompt would otherwise approve every read for the session.
- A project's own `opencode.json` can re-allow what the global file denies; only
  `OPENCODE_DISABLE_PROJECT_CONFIG=1` prevents that.
- The grep tool ignores `read` rules; `external_directory` asks before it searches outside the
  project, which is why that block is here. It does nothing when opencode starts in `$HOME`.
- A statement that only sets a variable (`export MOJO_CLIENT_DEBUG=1; ...`, `declare -x`) is not
  matched; the same assignment in front of a command is.
- The read tool sees a path relative to the worktree, so inside an openQA checkout its
  `etc/openqa/` is refused as well; read those files with a shell command.

## grok

Checked on 1.0.32: `grok inspect --json` loads all 65 rules with none skipped (an unknown rule is
skipped silently, so compare the count after merging). A leading `~/` is literal text in grok, so
home paths use `**/`; this is also why the Claude Code snippet, which grok reads from
`~/.claude/settings.json` too, does not cover grok. A deny beats every allow and still applies
under always-approve. For rules a user cannot edit away, the same table goes into a root-owned
`/etc/grok/requirements.toml`.

## Gemini CLI

Written against the policy engine of `google-gemini/gemini-cli` main at `2fe7c2d` (0.63 nightly)
and checked with a copy of its rule loader and matcher; the CLI itself was not run. A file in
`~/.gemini/policies/` is the user tier: priority 999 there outranks "allow for all future
sessions" answers and YOLO mode, only the admin tier (`/etc/gemini-cli/policies/`) outranks it.
`settings.json` `tools.exclude` is deprecated and cannot match a path. File tools already refuse
paths outside the workspace; do not start Gemini in `$HOME`. The `--policy` flag and the
`policyPaths` setting replace the user tier, and drop this file with it.

## antigravity-cli (`agy`)

Written from the permissions documentation of antigravity.google and the key shape of a live
1.2.5 settings file; not run. Targets are absolute paths, so replace `/home/USER`. Invalid entries
are ignored with only a log line: check `/permissions`, Global, deny after merging. `command()`
rules match a command prefix, so they cannot catch a path anywhere in a command, and cannot
express `MOJO_CLIENT_DEBUG` reliably (an `export` or another assignment can come first): they
cover the gh commands and the tools that print their own secrets only. The file rules are
enforced by the operating system only for commands that run in the terminal sandbox, which
`enableTerminalSandbox` turns on, and `allowNonWorkspaceAccess: false` keeps file tools in the
workspace. In the sandbox the denied files are closed to `openqa-cli` too, so a write you approved
must run outside it. Whether the rules survive `--dangerously-skip-permissions` is not verified: do not use
that flag with this skill.

## OpenAI Codex CLI

Codex has no file-read tool: everything goes through its shell, so the two files guard that.
- `openqa-credentials.rules`: `forbidden` rules for `gh auth token`, `gh auth status`,
  `--apikey` right after an `openqa-cli` subcommand or its `--o3`/`--osd`, `env
  MOJO_CLIENT_DEBUG=1`, the tools that print their own secrets (osc's abbreviated options
  included) and common readers of the exact credential files.
  Checked on 0.154.0 with `codex execpolicy check --rules`; `forbidden` holds even with
  `--dangerously-bypass-approvals-and-sandbox`. A rule matches an argv prefix, so a flag before the
  path (`cat -n`), another option before `--apikey`, `--apikey=K`, a relative path after `cd` or
  a `~` inside `bash -lc` is not caught.
- `config.toml`: a permission profile whose denies Codex's sandbox enforces on every command:
  `.netrc`, `.git-credentials` and a workspace root's `.env` and `.env.local` always, and in
  `credentials-strict` the tools' own configs and osc's cookie jar as well. Both hold literal
  paths only: one unreadable directory under a denied glob fails every command, so a `.env` below
  the workspace root stays readable. Both extend `:workspace`: commands can write only in the
  project and `/tmp` (not `/var/tmp`), `sudo` does not work, and the project's `.git` is
  read-only, so `git commit` fails inside Codex. A commented `".git" = "write"` line lifts that,
  at a price: the agent can then write `.git/hooks` and `.git/config`, which run outside the
  sandbox on your next git command. `~/.local/state/osc` stays writable because osc locks its
  cookie jar on every call.
  Checked on 0.154.0 with `codex sandbox -P` on dummy files in a throw-away home (a home under
  `/tmp` does not work: bubblewrap cannot bind the denies there). The strict profile also stops
  `openqa-cli`, gh, osc and tea from authenticating, so turn it on per session.
  The profile is dropped by `-s`, `-c sandbox_mode=...`, `--approve-for-me` and
  `--dangerously-bypass-approvals-and-sandbox`: leave those off.

## Kimi Code

Kimi Code 0.42.0 parses `[permission]` rules but does not enforce them, so this harness gets a
hook: `openqa-credentials.py` runs before every file, shell, fetch and MCP tool call and blocks
(exit 2) the ones that name a credential file or print a secret, checking each simple command
(split at `;`, `&`, `|` and newlines outside quotes) on its own. An error inside the hook blocks
too, and so does a call over 1 MB, a command or MCP argument over 64 KB or a path over 4096
characters, which keeps the hook inside its timeout: Kimi lets the call run when the hook times
out, cannot be spawned, or exits with any code other than 2 (127 without `python3`, 1 on a syntax
error).
`kimi doctor config` validates the entry (one invalid `[[hooks]]` entry disables all hooks).
Checked on 0.42.0 with `kimi doctor` and the hook's own tests in `tests/repo/test-harness.sh`.
Kimi runs the hook in its own working directory, not the session's, so the hook resolves paths
against both, and each word of a Bash command against the call's `cwd`; a path assembled at run
time or a relative path after `cd` still gets past it.
