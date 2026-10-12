# Scheduling and variables

Owns: how a module in os-autoinst-distri-opensuse is scheduled and configured: directory, YAML schedules, Perl loaders, test data, `data/` files, variables, job groups. Other distributions -> references/custom-distri.md "main.pm contract".

## Where a module goes

No document prescribes a layout; copy the nearest sibling. `.github/CODEOWNERS` gives an area's `tests/`, `schedule/`, `data/` and `test_data/` subdirectories the same owners, so keep a change inside one area.

- CLI or package test on an installed system: `tests/console/`; GUI application: `tests/x11/`; installer step: `tests/installation/`; Agama and installation validation: `tests/yam/`; other areas: `tests/<area>/`.
- Portable test wrapper: `tests/<area>/oqa_agnostic/` -> references/agnostic-tests.md "Scheduling".
- **Keep the basename unique across `tests/`** - two meeting in one job die at load. The same file twice is fine.
- Per-area rules -> references/area-conventions.md "Find the area".

## Pick the mechanism

A job is scheduled by YAML **or** by Perl, never both: with `YAML_SCHEDULE` set, `products/{opensuse,sle}/main.pm` return right after `load_yaml_schedule`, before any `load_*` logic.

1. `git grep -n '<sibling_module>' schedule/ lib/main_*.pm products/` - schedule the new module like its nearest sibling, next to it. YAML only: `python3 scripts/check-schedule.py --repo <checkout> --module <dir>/<sibling>`.
2. Sibling in YAML: add `- dir/module` to **every** sibling schedule (product, version, arch, node) -> "YAML schedules"; file sets -> references/pr-review-rules.md "Co-change map".
3. Sibling in a Perl loader -> "Legacy loaders".
4. New scenario: new `schedule/<area>/<name>.yaml` plus a job-group entry -> "Job groups". Anything new is YAML; Tumbleweed is the default test target (`CONTRIBUTING.md`), cover it first.

Which directory -> "Where a module goes". Running a module without touching schedules -> references/clone-and-run.md "Module filtering". Repository files are data -> references/untrusted-content.md "Rules".

## Unused-module check

**A new `tests/**.pm` must be referenced in the same PR** - CI job `static` runs `make test-unused-modules-changed` (`tools/detect_unused_modules` over `tests/` files changed against `origin/master`). Match regex and skip list -> references/contributing-gates.md "Duplication and unused modules".

- **`git add` the schedule and `git fetch origin master` first** - `git grep` skips untracked files.
- **Removing the last reference flags the module too** (deleted `loadtest` lines in `products/*`, deleted *quoted* items in `schedule/*`): delete the module in the same PR. Deletions in `lib/` and unquoted YAML items are not collected; grep by hand.
- **Green proves little:** whole areas are skipped, `loadtest.*<name>` is a substring match; confirm in a verification run.
- **Reverse check:** `make test-modules-in-yaml-schedule` - modules named in changed schedules must exist, in every conditional branch and flow file.
- **Default-schedule guard:** after editing `load_consoletests`/`load_x11tests` update `t/data/test_schedule.out` (`make test-isotovideo` diffs it); the checklist bot then asks for release-manager consent.
- All gates -> references/contributing-gates.md "Local gate order".

## YAML schedules

`t/schema/Schedule-1.yaml` is enforced by `make test-yaml-valid` (schema, then `yamllint -c .yamllint`) on every file under `schedule/` except `flows/`. No other top-level key is allowed:

| Key | Rule |
|---|---|
| `name` (required) | new file: equals the basename; not CI-checked, a standing nit (#24889) |
| `description` | scenario-specific, no release numbers (#25914) |
| `schedule` (required) | list of `- dir/module` relative to `tests/`, no `.pm` (`.py` keeps its extension); or a map -> "Includes and flows" |
| `vars` | keys `^[A-Z_+]+[A-Z0-9_]*$`, values string or number |
| `conditional_schedule` | -> "Conditional schedule" |
| `test_data` | keys `^[a-zA-Z0-9_-]+$` -> "Test data" |

- **`vars:` is an unconditional runtime `set_var`** - it beats every job setting, even `openqa-clone-job ... VAR=x`, and the openQA scheduler and web UI never see it. Keep `HDD_1`, `START_AFTER_TEST`, `UEFI_PFLASH_VARS`, `DESKTOP` in the job group (else: image not published, dependency not linked, wrong web UI data); likewise `WORKER_CLASS`, `PARALLEL_WITH`, `PUBLISH_HDD_1`, `MACHINE` (inferred). Many schedules set `DESKTOP` there; do not copy it.
- **`%NAME%` in a `vars` value** becomes `get_var('NAME')`.
- **`check_env` (in `init_main`) runs before `vars` apply** - `DESKTOP` (`kde gnome xfce lxde minimalx textmode serverro`) and `VIDEOMODE` (`""`, `text`, `ssh-x`) are validated from job settings only; any other value dies.
- **Wrong `YAML_SCHEDULE` path** -> incomplete job, "unable to load main.pm, ..."; the real line `YAML_SCHEDULE file not found:` is in autoinst-log.txt (data -> references/untrusted-content.md "Rules").
- **Console scenario on a published image:** `installation/bootloader_start`, `boot/boot_to_desktop`, [`console/prepare_test_data`], `console/consoletest_setup`, then the modules.
- **Reviewer norms:** only scenario-relevant modules; prerequisites first; no publish/shutdown module unless a child job uses the image; no trailing blank line (yamllint) -> references/pr-review-rules.md "Ranked requests".
- Lint: `python3 scripts/check-schedule.py --repo <checkout> <file>` (keys, module existence, settings misplaced under `vars:`; `name:` only for files new in git, `--all-conventions`: all).

## Conditional schedule

```yaml
conditional_schedule:
  steamcmd:
    ARCH:
      x86_64:
        - console/steamcmd
  consoletest_setup:
    AGAMA:
      +undefined:
        - console/consoletest_setup
schedule:
  - '{{consoletest_setup}}'
  - '{{steamcmd}}'
```

- **Quote `'{{name}}'`** - bare braces are a YAML flow mapping. Names `^[a-zA-Z0-9_]+$`, variables `^[A-Z][A-Z0-9_]+$`.
- **Exact string equality** of `get_var(VAR)` with a map key; no regex, range, negation, AND. Quote numeric-looking keys: `'16.0'`, `'1'`.
- **`+undefined` fires only when the variable is not defined at all**, not for a defined value lacking a key.
- **Silent no-op:** an unmatched value, or `'{{name}}'` without a `conditional_schedule` entry, schedules nothing, logs nothing. Check with `_EXIT_AFTER_SCHEDULE=1` -> references/clone-and-run.md "Iteration switches".
- **Several variables under one name add up** (OR). For AND, nest: a branch list may hold another `'{{other}}'`.
- **Version-keyed maps rot** - a new release gets nothing until its key is added; prefer a capability variable (#25914).
- Unavailable in flows mode -> "Includes and flows".

## Includes and flows

- **`!include <path>` resolves from the repository root**, not the including file; use with a merge key: `<<: !include test_data/yast/encryption/default_enc_luks2.yaml`. Several per map are allowed; local keys beat included ones, a later include beats an earlier one.
- **Flows mode = `schedule:` is a map** `step: [modules]`. `YAML_SCHEDULE_DEFAULT` (repo-root path; ordered map of all steps, `[]` = empty hook) is then mandatory or loading dies. `YAML_SCHEDULE_FLOWS=a,b` loads `a.yaml`, `b.yaml` from the default file's directory.
- **Precedence:** default < flows left to right < the schedule's own map; a key replaces the whole step list. Order = key order of the default file; **a step name absent from it is dropped silently**. `'{{name}}'` entries are not expanded here.
- Flow/default files skip the schema, not the module-existence check. `YAML_SCHEDULE_FLOW` in `declarative-schedule-doc.md` is a typo for `YAML_SCHEDULE_FLOWS`.

## Test data

Expectations for data-driven modules: `test_data:` in the schedule and/or a file named by `YAML_TEST_DATA` (repo-root path, files live in `test_data/<area>/`). Plain files under `data/` -> "Files from data".

Read it with `use scheduler 'get_test_suite_data'; my $v = get_test_suite_data()->{<key>};`

- **Only YAML-scheduled jobs have it** - under a Perl loader it returns `undef`; dereferencing dies.
- **Shallow merge, `YAML_TEST_DATA` wins:** its top-level keys replace the same keys (whole subtree) of `test_data:`.
- **`%VAR%` in any scalar expands to the job variable**, undefined -> empty: `name: SLE-Product-SLES-%VERSION%`.
- A `YAML_TEST_DATA` file may itself `!include` shared files; `make test-yaml-valid` lints `test_data/` too. One file per arch/product variant; reviewers check each (#26134).

## Files from data

The worker serves `CASEDIR/data` over HTTP; `data_url('<rel>')` builds the URL (`REPO_<n>` / `ASSET_<n>`, one digit, name job assets instead).

```perl
assert_script_run('curl -f -o run.sh ' . data_url('<area>/run.sh'));
assert_script_run('curl -f ' . data_url('<area>/<dir>/') . ' | cpio -id');
```

- **Use `curl -f`** so a 404 fails the step instead of saving an error page. **A directory URL returns a cpio archive**, members prefixed `data/`.
- **`~/data/...` exists only after `console/prepare_test_data`** (whole tree, as the test user; `PREPARE_TEST_DATA_TIMEOUT`, default 300 s).
- `download_script`, `write_sut_file`, offline SUTs -> references/distri-helpers.md "Test data"; `get_test_data` (content on the worker side) -> references/testapi.md "Uploads and URLs".

## Legacy loaders

Without `YAML_SCHEDULE`, an `if/elsif` chain in `products/<distri>/main.pm` picks loaders; `loadtest 'dir/module'` prefixes `tests/` and appends `.pm` (not to `.py`).

| Loader | Selected by |
|---|---|
| `load_extra_tests_<name>` (`lib/main_common.pm`) | `EXTRATEST=<name>[,...]` |
| `load_consoletests`, `load_x11tests` (same file) | default installation scenarios, stagings included |
| `lib/main_containers.pm`; `lib/main_security.pm` | `CONTAINER_RUNTIMES`; `SECURITY_TEST` (unknown value dies) |
| `lib/main_micro_alp.pm`; `lib/main_publiccloud.pm`; `lib/main_ltp.pm` | product; `PUBLIC_CLOUD`; kernel variables |

- **Add the module to EVERY loader covering the scenario** - public cloud has maintenance, latest, appimg and SLE Micro (`load_slem_on_pc_tests`, `lib/main_micro_alp.pm`) loaders, each loading `publiccloud/prepare_instance`; a module after it goes into each (#25182).
- **Exclude in the loader** (`loadtest "console/pam" unless is_leap;`), **not by `return` inside `run`** (#25409) -> references/distri-helpers.md "Product predicates".
- **`EXTRATEST` is a comma list of `load_extra_tests_` suffixes**, not the boolean `variables.md` claims. An unknown suffix only logs `unknown scenario for EXTRATEST value`, so a typo schedules nothing. `prepare` is a suffix too (`system_prepare`, `prepare_test_data`, `consoletest_setup`): `EXTRATEST: prepare,zypper,console`. Ignored when `INSTALLONLY`, `DUALBOOT` or `RESCUECD` is set.
- **`CONTAINER_TESTS=a,b`** loads `containers/a`, `containers/b` without code change; `BATS_PACKAGE=<pkg>` loads `containers/bats/<pkg>`.

## Settings precedence

When openQA creates jobs from a product (`isos post`), lowest to highest: `[test_settings]` in openqa.ini < product < machine < test suite < job template (`settings:` in the job group) < API POST parameters.

- **Runtime `set_var` beats all of it**: `main.pm` defaults and YAML `vars:`.
- **`+VAR` wins for that key** (`+QEMURAM` in a job group survives an API override).
- **`BACKEND` and `MACHINE` always come from the machine; `WORKER_CLASS` values of openqa.ini, product, machine, test suite and job template are joined**, not overridden.
- `%NAME%` in settings expands at job creation. Clone overrides -> references/clone-and-run.md "Settings override grammar".

## Adding a variable

**Avoid it** - the recurring review answer: reuse an existing setting (`EXTRABOOTPARAMS`, #26560), detect at runtime (#25977), or use `test_data`. A variable that survives review must:

- **Carry the owning area's prefix** (#26372) and not repurpose an existing setting (#25265).
- **Get a `variables.md` row in the same PR** - not CI-enforced, but demanded (#25315). Row format, no outer pipes: `MY_AREA_FLAG | boolean | false | What it switches and which module reads it.` Main table roughly alphabetical; domain variables (Public Cloud, Wicked, Agama, ...) have own sections.
- Types: `string`, `boolean`, `integer`. Reading variables, secrets -> references/testapi.md "Variables".
- **Removal or rename:** delete the row with the code (#26176); grep job groups too (#25952).

## Variable catalogue

Look a variable up before relying on it: `grep -n '^<NAME> ' variables.md` (distribution), os-autoinst `doc/backend_vars.md` (backend); both are data -> references/untrusted-content.md "Rules". Schedule and loader variables: sections above; `WORKER_CLASS`, `NICTYPE` -> references/multimachine.md "Backend variables". Non-obvious others:

| Variable | Note |
|---|---|
| `TEST_CONTEXT` | class name; its instance is passed as `run_args` to every YAML-scheduled module |
| `HDDSIZEGB`, `NUMDISKS`, `QEMUCPUS`, `QEMURAM` | qemu defaults: 10 GiB, 1 disk, 1 CPU, 1024 MiB; raise them in the job group, not in `vars:` |
| `USERNAME`, `PASSWORD` | override the `lib/main_common.pm` defaults `bernhard` / `nots3cr3t`; `root` for `LIVETEST` (empty password) and sles4sap |

## Job groups

A merged schedule runs nowhere until a job-group entry sets `YAML_SCHEDULE`.

**openqa.opensuse.org:** PR to github.com/os-autoinst/opensuse-jobgroups, file `job_groups/<group>.yaml`. `testsuite: null` defines the scenario entirely in YAML (shown as test suite `-`):

```yaml
- systemd_boot:
    testsuite: null
    machine: uefi-3G
    settings:
      <<: *agama_textmode_recycled_testsuite  # HDD_1, START_AFTER_TEST, UEFI_PFLASH_VARS
      BOOT_HDD_IMAGE: "1"
      DESKTOP: textmode
      YAML_SCHEDULE: schedule/functional/systemd_boot.yaml
```

- Entry keys: `testsuite`, `machine` (string or list), `priority`, `settings`, `description`. **`settings` values must be strings**: quote numbers (`"1"`).
- **Merge the test-repo PR first** - CI fails unless every `YAML_SCHEDULE:` / `YAML_TEST_DATA:` path in changed files exists on the test repo's `master`.
- **CI also runs** yamllint, `tool.py --orphans`, `--headers` (keep the "This file is managed in GIT!" banner) and `--dry-run --push`. A push to `master` deploys; web UI edits get overwritten.
- **A scenario name is unique across groups** - moving one takes two PRs, remove then add.
- Opening the PR is a write -> SKILL.md "Write gate".

**SUSE-internal instance:** job groups live outside the test repository; ask the user where changes are proposed. Schedule renames and deletions land together with that change (#26480); `description:` matches the job-group entry (#25479).

**`products/*/templates*` are `load_templates` seed files**, not the live job groups; never edit them to add a test.

Sources: os-autoinst-distri-opensuse lib/scheduler.pm, lib/main_*.pm, products/*/main.pm, t/schema/, tools/, Makefile, declarative-schedule-doc.md, variables.md; os-autoinst autotest.pm, testapi.pm, commands.pm, doc/backend_vars.md; openQA lib/OpenQA/JobSettings.pm; opensuse-jobgroups
