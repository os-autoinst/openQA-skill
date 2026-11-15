# This container

You run in the openQA container. What differs from a workstation:

- **The skill** is at `/etc/opencode/skills/openqa`. A path to it in older session
  history (`~/.agents/skills`, `~/.claude/skills`) does not exist here.
- **No local test runs.** There is no sudo, no qemu, no compiler, no podman and no
  docker, so isotovideo and `make test-isotovideo` do not work. A verification run is a job
  cloned to an openQA instance: build the command with `scripts/vr-clone-cmd.py`.
- **The lint gates of a test distribution do run**, with three exceptions that are
  the container's and no fault of a change: `make test-jsonnet-valid` fails, as the
  Python `_jsonnet` module is not here (check a changed file with `jsonnet <file>`);
  `make test-check-strict` needs a script the packages do not ship; and the tidy
  gate refuses to run when the distribution pins another perltidy than the image
  has. The compile and unit-test gates want the os-autoinst tree as `os-autoinst/`
  in the checkout. Where it is missing, link the packaged one:
  `ln -s /usr/lib/os-autoinst os-autoinst`.
- **A write to openQA, GitHub or Bugzilla asks the user**, and so does every call
  of their tools that is not on the short list of reads below. The answer comes in
  the interface; without the interface the call is refused.
  - openQA: `openqa-cli api` without a method option (`-X`, `--method`), a data or
    parameter file (`-D`, `--data-file`, `--param-file`) or a quoted option,
    `openqa-cli archive` and `openqa-cli monitor` go through. Every other
    `openqa-cli` call asks, as do `openqa-clone-job`,
    `openqa-clone-custom-git-refspec` and openQA's older client scripts.
    `scripts/vr-clone-cmd.py` builds a clone command without running one.
  - GitHub: `gh pr view|diff|checks|list|status|checkout`, `gh issue view|list|status`,
    `gh search`, `gh run view|list|watch|download`, `gh repo view|list|clone`,
    `gh release view|list|download`, `gh workflow view|list`, `gh label list`,
    `gh --version` and `gh api` without `-i`, `-X`, `--method`, `--input`, a field
    option or a quoted option go through; a `gh api` call with the word `method`
    anywhere in it asks, a search through `gh api` for that word too.
    Every other `gh` command asks, but for `gh pr merge` and the ones that print
    the token or pass one in a header, which are refused. `git push` asks.
  - Bugzilla: the tools that search and read go through; the others ask.

  The rules read a command's text. Start `openqa-cli` and `gh` as the first word of
  a command, unquoted, with no `timeout` or variable in front, or a read asks too. Write a
  command on one line: one with a line continuation (`\` at the end of a line) or a
  tab asks, whatever it does. A command that only names one of the asking programs,
  a search for `openqa-clone-job` in the references for one, asks as well, and so
  does any command with `git` and, later in it, `push`: a commit message with that
  word goes in a file, `git commit -F <file>`. When a command asks, show it and
  wait; do not try another spelling.
- **"Permission denied: shell" refuses one command, not the shell.** Most often the
  command's text named the directory of the logins (`/agent-logins`, or one of the
  variables `OPENQA_CONFIG` and `GH_CONFIG_DIR` that hold its name), a login file by
  its name (`client.conf`, `hosts.yml`, `id_ed25519`, `api-key`), a key or token
  (`--apikey`, `OPENQA_API_KEY`, `oauth_token`, an `Authorization` header), a process
  environment under `/proc`, the server password, `sudo`, `opencode` itself,
  `gh pr merge`, or `gh` with the word `auth` and later `token`, `status` or
  `git-credential`. The skill's own rules refuse more of that kind. The tools find
  their logins themselves: say the command without that text and go on. To search
  files for one of those words, use the grep tool, not a shell command.
- **Outside the work directory** the read, grep and glob tools take a path below
  `/etc`, `/usr`, `/tmp`, `/var/tmp` or the home directory; any other is refused,
  and so are the places there that hold a login on a workstation, `/etc/openqa`,
  `~/.config/openqa` and `~/.config/gh` among them.
- **The site policy**, when the user gave one, is `~/.config/openqa-skill/policy.md`.
  Open it with the read tool: a shell command that names it is refused.
- **Write files with the write tool, not a shell heredoc.** A heredoc's text is
  judged as a command, so a report that mentions one of the above is refused.
- **Pushes to GitHub** use the container's own SSH key, over an SSH remote
  (`git@github.com:<owner>/<repo>.git`). git is set up for it: pass no `-i`, no
  known-hosts option and no ssh command of your own. An https remote has no login
  for a push.
- **Reports go under `reports/` in the work directory.** The user cannot open
  `/var/tmp` or `/tmp` of the container; `/var/tmp` survives a restart, `/tmp` does not.
- **Sub-agents:** one per playbook of the skill, under the playbook's name:
  `openqa-job-triage`, `openqa-group-review`, `openqa-test-author`,
  `openqa-verification-run`, `openqa-pr-preflight`, `openqa-pr-review`,
  `openqa-ticket-refuter`.
