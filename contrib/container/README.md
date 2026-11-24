# Agent container

One image holding opencode 2.x, this skill and the tools the skill calls, run as a systemd
user service. The agent works inside the container, and so does the opencode client you
talk to it through: the host lends it a terminal. A draft, like the rest of `contrib/`.

The launcher, the units and the build recipe are a copy of those the openSUSE packaging
skill ships, changed where openQA differs: other logins, no guard plugins, other tools.

| File | What it is |
|---|---|
| `Dockerfile` | the image, built by OBS from this repository |
| `opencode.json` | what the container adds to `../harness/opencode-v2/opencode.jsonc`: the MCP servers, the questions before a write, and the denies around opencode's own server and the logins |
| `CONTAINER.md` | what the agent is told about the container: no local test runs, what a refused command means, where reports go |
| `ssh_config`, `ssh_known_hosts` | how ssh reaches GitHub: its git user, the container's key, the host key |
| `image-check` | the last build step: a failure leaves no image |
| `rule-table.txt` | what the rules must say to a list of commands and tool calls: allow, ask or deny, and where they are known not to reach |
| `model-stub.py` | a stand-in model for `image-check`: it answers a turn with the tool call it is handed |
| `skill-container` | the launcher you run on the host, installed as `openqa-container` |
| `systemd/` | the user units the launcher installs: the agent, its socket relay and the nightly update |
| `systemd/examples/` | the drop-in `install` writes for one instance, for whoever sets an instance up by hand |

## What the image holds

- opencode, with `/etc/opencode` as its managed configuration: the permission rules of
  `opencode.json` and of the harness's `opencode.jsonc`, the skill, one sub-agent per
  playbook in `agents/`, and `CONTAINER.md` as instructions.
- `openqa-cli`, `openqa-clone-job` and `openqa-clone-custom-git-refspec`, gh, git, ssh,
  jq, curl, and a python3 with PyYAML and Pillow for the skill's scripts.
- What the lint gates of os-autoinst-distri-opensuse need: the package
  `os-autoinst-distri-opensuse-deps`, the Perl test modules its unit tests load,
  perltidy, tidyall, perlcritic with the community policies, yamllint, gitlint,
  ShellCheck, make and GNU parallel, and os-autoinst itself for its source tree in
  `/usr/lib/os-autoinst`.
- Three MCP servers: bugzilla (bugwarden), memory and sequentialthinking, with
  Node.js, which the last two run on.
- The SUSE CA certificates, for an openQA instance whose certificate that CA signs.
- socat, for the socket relay the units run: the way into the server for a client of
  your own.

What the image holds under `/etc/opencode` and `/home/agent` is owned by root, and the
units run the agent as your user on a read-only root file system: the files that hold its
rules are out of its reach. What is mounted when the container starts is the agent's: the
volumes, the cache, the logins. The opencode server that applies the rules is within its
reach too: see "Limits".

The logins are mounted into `/agent-logins`, a directory of their own at the top of the
file system: `OPENQA_CONFIG` and `GH_CONFIG_DIR` send `openqa-cli` and gh there, and the
Bugzilla server and ssh are configured for it. A command that reads everything below
`~/.config`, the home directory or `/var` does not come across them, and the rules deny a
command that names the directory, one of the two variables, or a login file by its name.
opencode's own read, grep and glob tools are refused a path outside the work directory
unless it lies below `/etc`, `/usr`, `/tmp`, `/var/tmp` or the home directory, and its
write tool a path in opencode's own data. The skill's own rules go on refusing, there too,
the places that hold a login on a workstation, `/etc/openqa`, `~/.config/openqa` and
`~/.config/gh` among them. All of that goes by the path as it is written: see "Limits".

The rules are text patterns, and `image-check` does not take their meaning on trust: at
every build it starts the server with a stand-in model and puts each line of
`rule-table.txt` through a real agent turn, a read that must go through, a write that must
ask, a login that must stay unread, made-up logins lying where the real ones are mounted.
A rule that stops meaning what the table says, after a change here or in a new opencode,
leaves no image. The table's last lines are the other kind: calls that are known to get
past the rules, kept there so that the limits below stay measured.
`OPENCODE_DISABLE_PROJECT_CONFIG=1` is set because a project's `opencode.json` can undo a
rule of the managed configuration, and `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` because a
`.claude` directory in the work directory would bring skills of its own.

Not in the image: qemu, a compiler, podman and sudo; `image-check` fails the build when
one of them is there. `os-autoinst-devel` is left out for that reason: it brings qemu and
gcc. isotovideo does not run a test in the container, and a verification run is a job
cloned to an openQA instance (`references/clone-and-run.md` "Where to run").
`CONTAINER.md` tells the agent so.

The lint gates were tried in the image without network, on a checkout of
os-autoinst-distri-opensuse: `make tidy-check`, `test-compile-changed`,
`test-compile-os-autoinst`, `unit-test`, `test-yaml-valid`, `test-metadata`,
`test-unused-modules-changed`, `test-dry` and `test_pod_errors` ran from the packages
alone. Two things to know:

- The compile and unit-test gates want the os-autoinst tree as `os-autoinst/` in the
  checkout. A checkout without one takes the packaged tree:
  `ln -s /usr/lib/os-autoinst os-autoinst`. `make test-check-strict` needs a script the
  package does not ship and wants a real checkout of os-autoinst there.
- `make test-jsonnet-valid` imports the Python module `_jsonnet`, which Tumbleweed does
  not package; the image has the `jsonnet` command instead.

The test distribution pins the version of perltidy, and the image has the one Tumbleweed
ships. They were the same when this was written. When they differ, the tidy gate refuses
to run and stays on the host until one follows the other.

## Run it

On the host: rootless podman, a systemd user session, gh, jq, git, ssh-keygen, socat and
python3, and working logins for openQA (an API key in your client configuration), gh
(github.com), the bugzilla MCP server and one opencode model integration. opencode 2.x is
needed there by `secrets`, which asks it for that login, and by `import`, which asks it
for a project's sessions. The launcher runs its own commands in `/` and takes them from
`/usr/local/bin:/usr/bin:/bin`, whatever your `PATH` holds; `SKILL_CONTAINER_PATH` names
other directories, and it sets the locale to `C`. The rest of your environment reaches them
as it is: see "Limits". That
opencode alone is looked up on your `PATH`; `OPENCODE` names another by its absolute
path. `secrets` runs it in `/` with your `PATH`, `import` in the project it copies from,
with the launcher's. A relative path given to an option is read against the directory you
started the launcher in.

Install the launcher under a name of its own, so that it can stand beside the packaging
skill's, and the units beside it:

```
install -D -m 0755 contrib/container/skill-container ~/.local/bin/openqa-container
mkdir -p ~/.local/bin/systemd
cp -r contrib/container/systemd/. ~/.local/bin/systemd/
```

In its own messages the launcher still calls itself `skill-container`.

```
openqa-container secrets --model-auth <integration> [--openqa-host HOST]...
                         [--openqa-conf FILE] [--bugzilla-key FILE] [--new-ssh-key]
openqa-container ssh-key
openqa-container install <instance> --workdir DIR [--as DIR] [--memory FILE] [--image IMAGE]
openqa-container up <instance> [--model provider/model]
openqa-container attach <instance> [--continue | --session ID]
openqa-container run <instance> [--continue | --session ID] <message>
openqa-container down <instance>
openqa-container uninstall <instance>
openqa-container password <instance>
openqa-container import <instance> --from DIR [--memory FILE]
openqa-container update <instance>
openqa-container idle <instance>
```

One instance is one user unit, `openqa-agent@<instance>`; its name is 1 to 64 letters,
digits, `_` and `-`, the first of them no `-`. Once installed it starts with
your user session: the template is wanted by `default.target`, which Quadlet applies to
every installed instance. Run `up` once after `install`: it makes the server password the
unit needs, and a start before that fails and is given up after five tries in ten minutes.
A start by systemd is not `up`: see "Limits".

- **`secrets`: run it yourself, never from an agent.** It copies into podman secrets:
  - the API key and secret of each openQA host you name with `--openqa-host`, and of
    openqa.opensuse.org when you name none. A host is the name of its section in your
    client configuration: the file `--openqa-conf` names, or `openqa/client.conf` below
    your configuration directory. No other place that `openqa-cli` itself reads is looked
    at: not `OPENQA_CONFIG`, `/etc/openqa` or a `client.conf.d`. The file has to be
    plain, sections, `key = value` lines and comments: `secrets` refuses one with a line
    that is indented or repeats a section or a key, or with a character other than a tab
    and printable ASCII, a carriage return among them, which `openqa-cli`'s own parser
    could read another way. Nothing else of the file is copied: no other host and no
    other setting of a section;
  - the github.com login of gh, read through gh, so a keyring works. Which token the
    agent gets is yours to choose: `secrets` copies the one gh uses where you run it.
    That is your host login's, with all its scopes, unless `GH_CONFIG_DIR` names another
    gh configuration directory, whose login is then the one copied, or `GH_TOKEN` or
    `GITHUB_TOKEN` holds a token, which then replaces the stored one;
  - the Bugzilla API key file;
  - what `opencode auth export <integration>` prints. An API-key integration is the
    plain case. An account login is copied as it is at that moment: host and container
    then each renew it on their own, and if one stops, log in again on the host and run
    `secrets`, `down` and `up`. Name the integration whose login serves the model's
    provider; `secrets` does not try the login, the first `run` does.

  Its first run also makes an SSH key of the container's own, for pushes to GitHub:
  `ssh-key` prints the public half. Add it to your account, or as a deploy key with
  write access to the one fork the agent pushes to, which gives it nothing else. A
  later run keeps that key; `--new-ssh-key` makes another, and the old one keeps
  pushing, from any copy of it, until you remove its public half.
  All logins are read before one is stored, and `secrets` prints the five secret names
  and nothing else. Run it outside the work directory, with the `PATH` you use for
  `install`, and with no `OPENCODE` that names a file the agent could have written.
- **`install`** writes the units of an instance for the work directory `--workdir`
  names, mounted at the same path or at `--as`, and a drop-in with the image and the
  name and e-mail address of your git configuration, without which git commits nothing
  in the container. It refuses until `~/.local/bin/openqa-container` is an identical
  copy of the launcher you run, so the update timer and your shell run the code you
  reviewed, and it takes the units from beside that copy alone, or from
  `/etc/skill-container/systemd`. It refuses a work directory that is not yours, your
  home directory, one above it, a dot-directory in it, or one that holds or lies in
  your configuration directory, your runtime directory, podman's storage or its
  volumes; one a symlink leads to; and one with no directory above it that is yours and
  closed to everyone else (mode 0700): the agent runs as you and can make a file there
  setuid to you. A directory under `/var/tmp` passes below one you made with mode 0700.
  It also refuses to mount the work directory at `/`, at a place that lies in or holds
  `/etc`, `/usr`, `/bin`, `/sbin`, `/lib`, `/lib64`, `/home/agent`, `/agent-logins`,
  `/boot`, `/dev`, `/proc`, `/sys`, `/run` or `/root`, anywhere in `/var`, and at `/tmp`
  itself: the image keeps its rules, the skill, its tools and the logins there, or
  reaches them from there by a link, and the agent writes the work directory, which
  mounted there would stand in for them. `/var/tmp` is refused with the rest of `/var`
  because the agent writes the volume mounted there: a link it leaves in it would move
  a mount point below it at the next start. `--as` names another place, and a work
  directory that lies under `/var` on the host needs it: one below `/tmp`, which is
  empty at every start, or a directory of its own such as `/work`.
  `--memory FILE` seeds the instance's memory volume once, from a graph with entities
  and relations only that is alone in its directory. It is seeded before anything is
  written, so a seeding that fails leaves an earlier install as it was. A write that
  fails after that, on a full disk for one, does not: run `install` again.
- **`up`** starts the instance behind a server password of its own and waits until the
  server answers; if it does not, the unit is stopped. It then removes the saved
  approvals and session rules it finds and imports the model login: it stops before it
  removes a kept login when the secret holds no list of logins with an id each, and
  when the login list, read again after the import, does not hold the secret's alone.
  The server listens inside the container only, with no port on the host.
- **`attach`** and **`run`** start an opencode client in a second container, made from
  the image the server runs, and remove it when the client ends. It joins the server's
  network and user namespace and gets the server password and, under `attach`, your
  terminal. It gets no login, no volume and no file of yours, and an empty read-only
  directory where the work directory is. A permission that asks is answered in
  `attach`; `run` refuses it, so a `run` writes nothing that the rules ask about.
  `attach` needs a terminal and passes on `-c`, `--continue`, `-s`, `--session` and
  `--prompt`; `run` passes on `-c`, `--continue`, `-s`, `--session`, `--fork`, `-m`,
  `--model`, `--agent`, `--format`, `--title` and `--thinking`, and its other words are
  the message. Both refuse any other argument that starts with `-`: opencode's
  `--auto`, `--yolo` and `--dangerously-skip-permissions` answer every permission with
  yes and are not among them. An answer of "always" is forgotten at the next `up`,
  `attach` or `run`. `run` prints the reply with control characters and colours
  removed, so no text of the agent's can hide the launcher's lines after it; `attach`
  is opencode's own terminal interface and is not filtered.
- **`down`** stops the instance, and a client still on it. **`uninstall`** also removes
  its units and settings. Volumes and secrets stay in both cases.
- **`password`** prints the server password of a running instance, for a client of your
  own, after removing the saved approvals and session rules as `attach` does. Run it
  yourself, never from an agent.
- **`import`** copies a project into the empty work directory of a running instance,
  with the memory graph and the project's opencode sessions. Run it yourself. It
  refuses your home directory, what holds it, a dot-directory in it, and what holds or
  lies in your configuration directory, your runtime directory, podman's storage or its
  volumes. At the top of the project it leaves out `.claude`, `.tmp*` and
  `skill-container-ws`. `--memory` names the graph, by default
  `~/.local/share/mcp-memory/memory.json`, which then has to exist and pass the checks
  `install` makes on one; the instance's memory volume must not be seeded yet. The
  transcripts and the graph come over as they are, the graph with every project's notes
  in it: whatever the agent reads of them is sent to the container's model provider.
- **`update`** pulls the image, unless its name starts with `localhost/`, and when the
  name then stands for a new image restarts the instance if no session is busy and no
  client that `attach` or `run` started is on it; `idle` answers whether that is the
  case now. Its timer is not enabled by `install`: enable it after one watched run.
- A client of your own reaches the server through the relay: a unit per instance
  listens on a socket in your runtime directory and forwards to the server through
  `podman exec`. Such a client does not pass the launcher: the approvals and session
  rules the launcher removes before `attach` and `run` stay for it, and `update` does
  not see it: a restart cuts its connection.

Sessions, the memory graph and `/var/tmp` live in the per-instance volumes
`openqa-<instance>-state`, `-memory`, `-toolstate` and `-scratch`: a newer image continues
where the last one stopped. The logins are one set and shared by the instances.
`podman volume rm` and `podman secret rm` remove them.

Your own settings for the container go into `~/.config/skill-container/openqa/`, mounted
read-only, and the units are written for `~/.config` as well: an `XDG_CONFIG_HOME` that
names another directory is not supported. The settings are an `opencode.json` with a
default model, an `AGENTS.md`, and the skill's site
policy as `openqa-policy.md`, which the image links to where the skill looks for it
(`references/site-policy.md` "Overlay lookup"). The policy file is where an instance other
than openqa.opensuse.org, its job groups and your trackers are named; none of that is in
the image. The agent opens the policy with the read tool: the skill's own rule on
openQA's client configuration also refuses a shell command that names the policy's
directory. Keep the settings directory to these files: opencode reads an agent file or a
permission rule from it after the image's rules, where it decides over them, and
`image-check` never sees it.

## Limits

The container keeps the agent away from the rest of your home directory. It is not a
boundary between the agent and what is inside the container.

- **What the agent reads goes to the model provider.** That includes the jobs, logs and
  bugs of every instance and tracker the logins open. Choose a provider that may see
  them before you name a non-public openQA host to `secrets`.
- **The logins are inside the container.** The agent can use them, and one set on
  reading them can: the denies match the text of a command, as `../harness/README.md`
  says. They refuse a command that names the logins' directory, a variable that holds
  its name, a login file's name, or one of the ways a tool prints its own login, and
  they refuse opencode's own tools that directory and `/` when a call names them. What
  names none of these reads the logins all the same: a shell command that walks the
  file system from `/` or uses a pattern such as `/a*/*/*`; a link to `/` or to the
  directory, made by one command and followed by the next or by opencode's read, grep
  or glob tool, which go by the path they are given; a tool's own library asked for
  its login.
- **An openQA key acts as you.** What it may do on its instance, the agent can do:
  comment, label, restart, schedule and cancel jobs. The rules ask before a command
  that writes; nothing checks which job or group it names.
- **The rules catch mistakes, not an agent set on evading them.** This skill has no
  guard program behind them: a rule is a pattern over a command's text. Every
  `openqa-cli` and every `gh` command asks, apart from the few that are refused,
  `gh pr merge` and those that would print a key or the token or pass one in an option
  or a header, and from the reads `opencode.json` names: `openqa-cli api` without a
  method option, a data or parameter file or a quoted option, `archive` and `monitor`,
  and for `gh` the subcommands `CONTAINER.md` lists and `gh api` without `-i`, a method,
  an input, a field option or a quoted option, and without the word `method` anywhere
  in it. openQA's job-cloning commands and older client scripts, `git push` and the
  Bugzilla tools that write ask as well. A command that only names one of these
  programs asks too, and so does a read started behind
  `timeout` or a variable assignment, and any command with a tab or a line continuation
  in it. A command spelled so that no pattern fits does not ask: a program started by
  another one (`bash -c`, a script, an interpreter), a variable that holds the
  program's name, a quote or a backslash inside a word (`g\h`, `pu""sh`), a git alias
  or hook, a program that speaks to the API itself. The last lines of `rule-table.txt`
  keep some of these on record. The rules also cost something: a command with `git`
  and later `push` in it asks, a commit message with that word included; one that
  searches for a login file's name is refused, and so is `gh` with the word `auth` and
  later `token`, `status` or `git-credential` after it.
  The agent's commands also run as the same user as the opencode server, and that
  server switches off every deny and every question for whoever has its password. A
  command starts without the password, and one that names the password, a process
  environment, or opencode with `--server` or one of its server subcommands is denied.
  Nothing else is: `ps e` or a read under `/proc` shows the password, and `curl`
  reaches the same API with it. Closing that needs the commands to run as another user
  than the server, which this image does not do.
- **The state volume holds what the agent wrote.** Its commands can write opencode's
  database. An approval saved there answers a question in every later session. Rules
  written onto a session answer every question of that session and switch off the
  denies of the configuration from its next prompt on, and here no plugin refuses in
  their place. `up`, `update`, `attach`, `run` and `password` remove the session rules they find and the
  saved approvals of every project the server lists, and stop when a list cannot be
  read, a rule stays, an id is none (letters, digits and `_`, at most 128) or the
  server refuses to list them (a 4xx with an error answer). A read or a removal that
  fails, as when another podman command holds the storage lock or the server answers
  with an error (5xx), is
  first tried again for up to five minutes in all, and under `up` and `update` so is
  the import of the model login; whether a removal the server refused found its item
  gone, the list, read again, says. That clears what was left behind; an agent set on
  keeping its rules puts them back.
- **A start by systemd is not `up`.** At boot, and when the unit restarts after a
  failure, nothing removes the saved approvals and session rules and nothing imports
  the model login again. The next `up`, or an `update` that restarts, does both;
  `attach` and `run` remove the approvals and rules.
- **A client runs what its server names, so the client runs in a container.**
  opencode's terminal interface loads, where the client runs, each plugin the server
  lists, and the agent can make the server list its own. The launcher therefore starts
  no opencode on the host for `attach` and `run`. Count on the agent running code in
  the client's container all the same: it has the server password, the server's
  network and, under `attach`, your terminal.
- **`attach` hands your terminal to a program the agent may steer.** Treat it like an
  ssh session to a machine you do not trust: type no password into it, and when one
  ends in a way you did not expect, close that terminal. An address drawn there is the
  agent's text; in your browser it is a page the agent chose.
- **The work directory is shared with the host, and the agent's files are yours.** The
  agent can leave there what runs when you use the directory yourself: a git hook or
  `core.fsmonitor`, an `.envrc`, a plugin for an opencode you start there. Give it a
  directory of its own and run nothing in it on the host. Keep the closed directory
  above it closed while the work directory exists.
- **`install` checks a path and podman mounts it a moment later.** Whoever writes a
  directory above the work directory or the graph can put a link there in between.
  `install` and `up` refuse when another user can write such a directory or another
  running container that your `podman ps` lists writes it. They do not know your other
  processes, a container kept elsewhere, or a mount podman does not list.
- **The GitHub token is your host login's, with all its scopes, unless you gave
  `secrets` another.** The rules ask before every `gh` command that is not one of the
  reads `opencode.json` names, and deny `gh pr merge`, the commands that print the token
  and a token passed in a header. They read text: what gets past them does on GitHub
  what the token allows.
- **The SSH key pushes wherever it may write**: every repository of your account, or
  the one it is a deploy key of. It is the container's own, so removing its public half
  revokes it alone. The host key in the image is the one GitHub publishes in its API's
  `meta` answer, as it was when this was written, and git starts ssh on the image's
  config alone: a changed host key stops every such push until the image is rebuilt.
  ssh started another way reads a config and host keys from the work directory, which
  the agent writes: podman makes the work directory the home directory of the user's
  password entry.
- Podman keeps the secrets unencrypted under your home directory, mode 0600, like the
  tools' own configuration files. The state volume holds the imported model
  credential: treat it like a secret. In the container it lies below the home
  directory, in opencode's database: the rules deny a command that names the database,
  and one that reads every file below `~/.local/share` prints it.
- **A graph given with `--memory` is seeded whole**: the agent sees what every project
  of yours wrote there, in a copy on its memory volume.
- **The server logs to your journal, and the agent can write to it.** Read a line of
  `journalctl --user -u openqa-agent@<instance>` as its text.
- **The launcher checks `PATH` and the loader's lists, nothing else of your
  environment.** A variable that names a path in the work directory can make the
  launcher, or a command it runs, load what the agent wrote there. Start the launcher
  outside the work directory.
- Nothing limits where the container connects to, and opencode's web tools fetch an
  address without a question.

The launcher is the packaging skill's with other logins, and that skill's
`contrib/container/README.md` gives the measurements behind these limits at more length.

## Build

OBS builds the image; a failed `image-check` fails the build. The project needs, for the
repository that builds it (here `containers`):

```
%if "%_repository" == "containers"
Type: docker
Repotype: none
Patterntype: none
BuildEngine: podman
Required: iproute2
%endif
```

`Required: iproute2` is there because the build brings the loopback interface up only
when the build root has `ip`, and `image-check` starts a server on it. The repository
takes its base image from `openSUSE:Containers:Tumbleweed` and its packages from
`openSUSE:Tumbleweed`. One package comes from elsewhere: `ca-certificates-suse` is built
in `SUSE:CA`, so add that project's Tumbleweed repository or aggregate the package.

The package holds one `_service`:

```xml
<services>
  <service name="obs_scm">
    <param name="scm">git</param>
    <param name="url">https://github.com/os-autoinst/openQA-skill.git</param>
    <param name="revision">REVISION</param>
    <param name="filename">skill</param>
    <param name="version">_none_</param>
    <param name="extract">contrib/container/Dockerfile</param>
    <param name="extract">contrib/container/opencode.json</param>
    <param name="extract">contrib/container/CONTAINER.md</param>
    <param name="extract">contrib/container/ssh_config</param>
    <param name="extract">contrib/container/ssh_known_hosts</param>
    <param name="extract">contrib/container/image-check</param>
    <param name="extract">contrib/container/model-stub.py</param>
    <param name="extract">contrib/container/rule-table.txt</param>
  </service>
  <service name="tar" mode="buildtime"/>
</services>
```

`REVISION` is one of two things:

- **A commit id.** Nothing of the skill changes in the image until someone commits a new
  one to the package.
- **`@PARENT_TAG@`**, for the latest release. The service then takes the nearest tag
  that the default branch reaches, with `git describe --tags --abbrev=0`. That is a tag
  of any name: obs-service-tar_scm 0.10.46 applies a `match-tag` parameter to a version
  only, not to a revision, so every tag of this repository has to be a release. A tag
  can be moved, which a commit id cannot: whoever may push tags here decides what the
  image runs, unless the repository's releases are immutable, a setting that fixes the
  tag of a published release.

Neither follows the branch: the image runs unattended on real logins, and what is merged
should not reach it before someone decided so. OBS does not watch the repository. With
`@PARENT_TAG@` a new release reaches the image when the service runs again: after a commit
to the package, after `osc api -X POST '/source/PROJECT/PACKAGE?cmd=runservice'`, or
through a service token
called from a release webhook. A changed package in Tumbleweed rebuilds the image from the
same revision without anyone asking. The revision has to hold `contrib/container/`:
`extract` fails on an older one. The commit the image was built from is in
`/etc/opencode/skill.obsinfo`.

`podman run --rm --network=none IMAGE image-check` repeats the check on a built image,
rule table included: that container's root is writable, and the check removes the made-up
logins it puts there. Started with `--read-only` it leaves the table out and says so.
