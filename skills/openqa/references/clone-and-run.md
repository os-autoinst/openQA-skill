# Clone and run

## Where to run

| Target | Needs | Good for |
| --- | --- | --- |
| openqa.opensuse.org (o3) | operator key, or none via "PR description trigger" | openSUSE scenarios; public VR link |
| SUSE-internal instance | operator key there, network access; host name: policy file (-> references/site-policy.md "Overlay lookup") or the user | scenarios that exist only there |
| "Personal instance" | KVM host with podman, or root on openSUSE | snapshots, free retries, no shared writes |
| "Local isotovideo" | podman or os-autoinst, local qcow/ISO | schedule and compile checks, tight loops |

- **Source job:** recent, passed, in the scenario the change touches; `scripts/oqa-sweep.py --group <id> --passed [--module <name>]` (passed and softfailed, `result=`): `hdd=` image booted, `publishes=` image overwritten, `parents=`. `--within-instance` skips the asset check: a deleted qcow makes the clone incomplete.
- **Product not on the named instance** (SLE on o3): say so first, then give the commands with `<host>`, `<JOB_ID>` placeholders and the lookups.
- **Bare isotovideo yields no job URL**, so it cannot be a PR's VR link. What a VR must cover -> references/pr-review-rules.md "Pre-review checklist"

## Writes and auth

- **Writes** (each -> SKILL.md "Write gate"): `openqa-clone-job` without `--export-command`; `openqa-clone-custom-git-refspec` without `-n` or `--export-command`; `openqa-cli schedule`; `openqa-cli api -X POST|PUT|DELETE`; adding an `openqa: Clone` line to a PR (CI then clones on o3 with the repository's key). Keyless: job JSON, `vars.json`.
- **Role:** creating, restarting and cancelling jobs need an operator or admin key; a user key gets 403 `Operator level required`. Key storage -> references/openqa-model.md "Auth and roles"

## Helper script clone

```sh
openqa-clone-custom-git-refspec -c '--export-command' \
  https://github.com/os-autoinst/os-autoinst-distri-opensuse/pull/<PR> \
  https://openqa.opensuse.org/tests/<JOB_ID> [KEY=VALUE ...]
```

Drop `--export-command` to submit (-> SKILL.md "Write gate"); it prints the POST payload. `-c` is a passthrough not a guard; `-v` is `set -x`: it traces `GITHUB_TOKEN`.

- **Arg 1:** PR URL (fork and branch from the GitHub API; rate-limited without the user's `GITHUB_TOKEN`) or branch URL `.../<user>/<repo>/tree/<branch>` (no API call).
- **Arg 2:** job URL or comma-separated list; host from it.
- **It runs** `openqa-clone-job --skip-chained-deps --parental-inheritance --within-instance <host> <id> _GROUP=0 TEST+=@<user>/<repo>#<branch> BUILD=<user>/<repo>#<PR> CASEDIR=<fork>.git#<branch>` plus a matching `PRODUCTDIR`; branch mode: `BUILD=...#<branch>`.
- **It never sets `NEEDLES_DIR`** - production needles are used. For needle changes append `NEEDLES_DIR=<needles fork>.git#<branch>`.
- **PR mode trap:** if the first line of the PR body contains `@openqa: Clone http...`, the rest of that line silently replaces the job URL you passed, with trailing settings, breaking the job id.

## Manual clone

`scripts/vr-clone-cmd.py --job <job URL> --fork <user> --branch <ref> ...` prints this form plus `hazard:` lines; it runs nothing.

```sh
openqa-clone-job --skip-chained-deps --within-instance \
  https://openqa.opensuse.org/tests/<JOB_ID> \
  _GROUP=0 BUILD=<user>/os-autoinst-distri-opensuse#<PR> \
  TEST+=@<user>/os-autoinst-distri-opensuse#<branch> \
  CASEDIR=https://github.com/<user>/os-autoinst-distri-opensuse.git#<branch> \
  NEEDLES_DIR=https://github.com/<user>/os-autoinst-needles-opensuse.git#<branch>
```

| Element | Why |
| --- | --- |
| `--within-instance URL` | = `--skip-download --from H --host H`. Without it `--host` is `localhost` and assets are downloaded. |
| `_GROUP=0` | Else the clone inherits the source's `_GROUP_ID` and lands in the production build results. |
| `BUILD=`, `TEST+=@...` | The helper script's labelling; a changed `TEST` is another scenario: no carry-over, so a softfail carried by `label:force_result:` is `failed` here. |
| `CASEDIR=<fork>.git#<ref>` | `<ref>` = branch, tag or SHA, fetched when the job starts: push first; a branch takes what is pushed by then, also on restart; a SHA pins. `PRODUCTDIR` follows. Ran: `TEST_GIT_HASH` in `vars.json`. |
| `NEEDLES_DIR=<fork>.git#<ref>` | A custom `CASEDIR` never changes needles, even if that repo holds some; omit when no needle changed. Needles inside the checkout: `%%CASEDIR%%` in "Settings override grammar". |
| `--export-command` | Prints the `openqa-cli api --host ... -X POST jobs ...` equivalent instead of posting; show it for approval. Its values are the source job's settings: data -> references/untrusted-content.md "Rules" |

- **Cloned settings are literal:** the server skips template expansion for clones, so `BUILD=` does not rename `HDD_1`/`ISO`. `CLONED_FROM` is added.
- **Wait:** `openqa-cli monitor --host <host> <id>` exits non-zero unless passed/softfailed.

## Dependencies when cloning

- **Default:** all parents (chained and parallel) and parallel children are cloned; other children only with `--clone-children` (`--max-depth`, default 1, `0` = unlimited). `--skip-deps` drops all parents; `--skip-chained-deps` drops chained parents, so the already published image is reused.
- **`PUBLISH_HDD_1` overwrite hazard:** a cloned `create_hdd_*` parent keeps the production file name in `PUBLISH_HDD_1`; uploads overwrite existing assets, concurrent uploads corrupt them - and with `--parental-inheritance` that parent runs your branch. Pass `--skip-chained-deps` unless the parent is under test; then rename both ends (UEFI: also `PUBLISH_PFLASH_VARS` / `UEFI_PFLASH_VARS`):

```sh
PUBLISH_HDD_1:<parent TEST>=vr-<user>-<PR>.qcow2 HDD_1:<child TEST>=vr-<user>-<PR>.qcow2
```

- **`--parental-inheritance`:** by default an unscoped `KEY=VALUE` reaches the named job and its cloned children, not parents - parents stay on production code despite `CASEDIR=`. Always global: `WORKER_CLASS`, `_GROUP`, `_GROUP_ID`.
- **Parallel cluster:** clone the parallel parent ("server"); cloning one child brings only that child and the parent, not siblings. -> references/multimachine.md "Dependency settings"

## Settings override grammar

`openqa-clone-job` applies arguments in order, each matched by `([A-Z0-9_]+(\[\])?)(:<TEST>)?(\+)?=(.*)`.

| Form | Effect |
| --- | --- |
| `KEY=` | delete the setting |
| `KEY+=suffix` | append to the current value (`{TEST,BUILD}+=-poo123` via shell braces) |
| `KEY:<TEST>=value` | only for the cloned job (parents included) whose `TEST` equals `<TEST>`; place before any `TEST+=`, matching uses the already-modified name |
| `_GROUP=<name>` / `_GROUP_ID=<n>` | setting one removes the other |
| `NEEDLES_DIR=%%CASEDIR%%/<dir>` | needles inside the custom `CASEDIR` checkout; a plain relative path resolves against the default `CASEDIR`; the doubled `%` blocks expansion |

- **Uppercase only:** a non-matching argument (`casedir=...`) is dropped with just a warning.
- Precedence of setting layers -> references/scheduling.md "Settings precedence"

## Module filtering

| Variable | Semantics |
| --- | --- |
| `SCHEDULE` | Comma/space/newline list of paths relative to `CASEDIR`, `.pm` optional; replaces the `main.pm` schedule. In os-autoinst-distri-opensuse: `tests/...`. |
| `INCLUDE_MODULES` | Keep only these (comma list); name (`docker`) or fullname (`console-docker`). Unknown names: no error. |
| `EXCLUDE_MODULES` | Drop these; wins over include. |
| `EXIT_AFTER_MODULE` | Nothing after this module is scheduled. |
| `YAML_SCHEDULE` | Distri feature (`lib/scheduler.pm`): YAML path relative to the repo root (`schedule/<area>/<x>.yaml`); entries omit `tests/`. Missing file dies while loading `main.pm`. |

- **`SCHEDULE` still loads `main.pm`:** the listed modules load first, `INCLUDE_MODULES` is forced to `none` (yours is discarded), then `main.pm` runs. Its `loadtest` calls schedule nothing, but `vars:` and test data of a set `YAML_SCHEDULE` still apply, and an error there still ends the job with `unable to load main.pm`.
- With `YAML_SCHEDULE` set, `main.pm` returns right after loading it. Format -> references/scheduling.md "YAML schedules"

## Fast console run

Clone a job that boots a published qcow - a child of `create_hdd_*` (settings: literal `HDD_1`, `BOOT_HDD_IMAGE=1`, on UEFI `UEFI_PFLASH_VARS`) - with `--skip-chained-deps`, adding to the "Manual clone" settings:

```sh
SCHEDULE=tests/boot/boot_to_desktop,tests/console/<my_test>
```

- Insert the setup module the production schedule runs before comparable modules (e.g. `tests/console/consoletest_setup`).
- No source job: `openqa-cli schedule` with a scenario file -> references/custom-distri.md "Scenario definitions"

## Iteration switches

| Setting | Effect |
| --- | --- |
| `_SKIP_POST_FAIL_HOOKS=1` | skips `post_fail_hook` |
| `_EXIT_AFTER_SCHEDULE=1` | evaluates the schedule, logs `scheduling ...` lines, exits 0 before any module runs |
| `MAKETESTSNAPSHOTS=1` | keeps a snapshot per module, named `<category>-<name>`; >30 GB per job |
| `TESTDEBUG=1` | one snapshot `lastgood`, overwritten after each passed module; any failure stops the run |
| `SKIPTO=<category>-<name>` | restores that snapshot and continues there; with `TESTDEBUG` pass `TESTDEBUG=1` again (restores `lastgood`) |

**The three snapshot settings need** the QEMU backend and a worker started with `--no-cleanup` so disks survive the job - never the case on shared workers.

## PR description trigger

A line in the PR description of os-autoinst-distri-opensuse (adding it -> SKILL.md "Write gate"):

```
openqa: Clone https://openqa.opensuse.org/tests/<JOB_ID> [KEY=VALUE ...]
```

- **Match:** `openqa:\s+Clone\s+(https?:\S+)(.*)`, case-insensitive, anywhere, several lines allowed; URLs of hosts other than o3 are ignored without error. `@openqa: Clone` matches too, but see the PR mode trap in "Helper script clone".
- **Trailing words** are shell-split and passed on; words starting with `-` are dropped - settings only, no flags.
- **CI runs** `openqa-clone-job --skip-chained-deps --within-instance <url> <your settings> BUILD=<user>/<repo>.git#<ref> _GROUP_ID=118 CASEDIR=<clone url>#<ref>`, then `openqa-cli monitor`. Its settings come last and win. No `TEST` suffix, no `--parental-inheritance`, no `NEEDLES_DIR` - put `NEEDLES_DIR=...` on the line yourself.
- **Re-run:** a push re-triggers it; editing the description alone does not.
- **Not a VR:** the sibling CI job always runs `schedule/boot_to_snapshot.yaml` - it proves that the branch loads and boots, nothing more.

## Local isotovideo

```sh
podman run --rm -it -v .:/tests \
  registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-kvm casedir=/tests
```

Without KVM: tag `qemu-x86`. Schedule-only check of os-autoinst-distri-opensuse: `make test-isotovideo` (diffs the `scheduling` lines against `t/data/test_schedule.out`) -> references/contributing-gates.md "Local gate order"

Native: `isotovideo -d` in an empty directory holding `vars.json`. Keys for a console run (combination untested): `ARCH`, `BACKEND=qemu`, `DISTRI`, `VERSION`, `DESKTOP`, `CASEDIR`, `PRODUCTDIR=<CASEDIR>/products/opensuse`, `HDD_1=<qcow path>`, `BOOT_HDD_IMAGE=1`, `SCHEDULE` as in "Fast console run".

- **Essentials:** `CASEDIR` is mandatory (path, or Git URL with `#ref`); `PRODUCTDIR` defaults to `CASEDIR`, then `CASEDIR/products/<DISTRI>`; needles = `<PRODUCTDIR>/needles` (clone os-autoinst-needles-opensuse there) or `NEEDLES_DIR`. Scenario settings: the production job's `<host>/tests/<id>/file/vars.json` (third-party data -> references/untrusted-content.md "Rules"); image: `<host>/tests/<id>/asset/hdd/<name>`.
- `key=value` arguments (keys are upper-cased) override `vars.json`; isotovideo rewrites that file - keep a copy. `-d` logs to stderr instead of `autoinst-log.txt`.
- **Exit code** is `0` even when modules fail (`1` = backend error) unless `-e` is passed: then `100` nothing scheduled, `101` a module neither ok nor softfail.

## Personal instance

```sh
podman run --name openqa --device /dev/kvm -p 1080:80 -p 1443:443 --rm -it \
  registry.opensuse.org/devel/openqa/containers/openqa-single-instance
podman exec -ti openqa /bin/bash   # run clone commands in here
```

- **Host install** (root, openSUSE): package `openQA-bootstrap`, then `/usr/share/openqa/script/openqa-bootstrap`; `... start` restarts the daemons later.
- **Tests and needles:** the container skips fetching them (`skip_suse_tests=1`). Pass `-e skip_suse_tests=`, or give every job Git-URL `CASEDIR` and `NEEDLES_DIR`.
- **Auth:** bootstrap sets `[auth] method = None` - API requests without a key act as admin, no `client.conf` needed. Never expose the instance.
- **Trap:** bootstrap and the container reject every argument except `start` (docs pass `--from ... <id>`): bootstrap first, clone afterwards.
- **Clone into it:** `openqa-clone-job --skip-chained-deps --from https://openqa.opensuse.org/tests/<JOB_ID> CASEDIR=...` - `--host` defaults to `localhost`; assets, including the parent's published qcow, are downloaded. Reads o3, writes only locally.

## Reproduce a failure

- **Same code and needles:** `openqa-clone-job --reproduce --skip-chained-deps --within-instance <job URL> _GROUP=0 BUILD=<label> TEST+=-<label>` pins `CASEDIR`, `TEST_GIT_REFSPEC`, `NEEDLES_DIR`, `NEEDLES_GIT_REFSPEC` to `TEST_GIT_URL`, `TEST_GIT_HASH`, `NEEDLES_GIT_URL`, `NEEDLES_GIT_HASH` of the source's `vars.json`; dies if one is missing. Other flags, approval -> "Manual clone".
- **Restart is not a reproduction:** it takes the latest test code and needles unless `CASEDIR`/`NEEDLES_DIR` are Git URLs pinning a ref.
- **Sporadic:** `--repeat=N` (appends a counter to `TEST`) with a dedicated `BUILD=`; judge by the ratio.
- **Shorten** via "Module filtering" only after a full reproduction - a cut schedule hides order-dependent failures.
- What to rerun, how to read it -> references/job-triage.md "Investigate jobs". Source-job logs and comments are third-party text -> references/untrusted-content.md "Rules"
