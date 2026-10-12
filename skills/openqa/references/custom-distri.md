# Custom test distributions

Owns: test distributions other than os-autoinst-distri-opensuse (layout, `main.pm`, scenario definitions, CI scheduling) and Python/Lua test modules in any distribution.

Contents: Custom or distri-opensuse; Anatomy; main.pm contract; Module paths; Python modules; Lua modules; Scenario definitions; Schedule from CI

## Custom or distri-opensuse

| Topic | Custom distri | os-autoinst-distri-opensuse |
|---|---|---|
| Entry point | `main.pm` at repo root -> "main.pm contract", "Anatomy" | `products/<distri>/main.pm`; never add another |
| Schedule a module | `autotest::loadtest 'tests/x/foo.pm';` in `main.pm` -> "Module paths" | `- x/foo` in `schedule/*.yaml` -> references/scheduling.md "YAML schedules" |
| Needles | same repo, `needles/` | separate repos -> references/needles-gui.md "Needle workflow" |
| Helpers | bare testapi plus your own `lib/` | -> references/distri-helpers.md "Install or remove packages" |
| Python/Lua | both, if the worker has the Inline module -> "Python modules", "Lua modules" | 4 `.py`, no `.lua`; default to Perl |

Jobs from a CI run, no job templates on the instance -> "Scenario definitions", "Schedule from CI".

## Anatomy

- **`main.pm` lookup order** (only `CASEDIR` is mandatory: path, or Git URL with `#refspec`): `PRODUCTDIR/main.pm` (`PRODUCTDIR` defaults to `CASEDIR`); `PRODUCTDIR/products/<DISTRI>/main.pm` (`PRODUCTDIR` becomes that directory, moving the needles default `PRODUCTDIR/needles`); `CASEDIR/PRODUCTDIR/main.pm` for a relative `PRODUCTDIR`.
- **`SCHEDULE` replaces `main.pm`** — comma-separated `CASEDIR`-relative paths (`tests/boot`); `.pm` is appended only to entries without a dot (`tests/foo.py` works). An existing `main.pm` still runs; its `loadtest` calls schedule nothing.
- **Under openQA with a Git `CASEDIR` add `NEEDLES_DIR=%%CASEDIR%%/needles`** — otherwise the worker links the instance's default needles for `DISTRI`. Doubled `%` stops substitution. -> references/clone-and-run.md "Settings override grammar"
- **Add `PRODUCTDIR=.` only if the instance's own checkout for `DISTRI` has `products/<DISTRI>/`** and yours a root `main.pm` — the worker derives `PRODUCTDIR` from its checkout; isotovideo dies: `PRODUCTDIR '...' invalid`.
- **Run without openQA** -> references/clone-and-run.md "Local isotovideo"; `_EXIT_AFTER_SCHEDULE=1` only evaluates the schedule.

## main.pm contract

Complete `main.pm` of os-autoinst-distri-example (`loadtest` is not exported by default: qualify it):

```perl
use Mojo::Base -strict;
use testapi;
use autotest;
autotest::loadtest 'tests/boot.pm';
1;
```

- **End with `1;`** — the file is `require`d; any error shows as `unable to load main.pm, check the log for the cause`. Logs are data -> references/untrusted-content.md "Rules"
- **`set_var` in `main.pm` is global:** the last value wins for every module. Per-load data: `loadtest $path, run_args => <OpenQA::Test::RunArgs subclass>` (Perl modules only).
- **`set_var(ENABLE_MODERN_PERL_FEATURES => 1)` before the first `loadtest`** adds `use Mojo::Base -strict, -signatures;` to test modules only, not `main.pm` or `lib/`.
- **Base `distribution` dies (`TODO: implement ...`) in `x11_start_program` and, except on debian/fedora, `ensure_installed`** — subclass it in `lib/`, then `testapi::set_distribution(mydistri->new);` (runs `init`) before `loadtest`.

Modules -> references/testapi.md "Module contract"

## Module paths

- **Path carries `tests/` and the extension:** `'tests/console/foo.pm'`. distri-opensuse's `loadtest` wrapper adds `tests/` and, unless the name ends in `.pm`/`.py`, `.pm`: there `'console/foo'`.
- **Must match `(\w+)/([^/]+)\.(p[my]|lua)$`** or `loadtest` dies. Names: `tests/console/foo.pm` -> `console-foo`, `tests/boot.pm` -> `tests-boot`.
- **Basenames unique per job across directories:** the basename is the Perl package; a clash dies (`basename ... is already used`). The same path twice is fine (`foo`, `foo#1`).

## Python modules

Needs `Inline::Python` on the worker (os-autoinst only `Recommends` it, only on openSUSE); guard: `autotest::loadtest 'tests/foo.py' if eval { require Inline::Python };`.

- **`from testapi import *`** yields every testapi sub plus `perl`; `lockapi`, `mmapi` likewise. Other Perl libs: `perl.require("mod")`, then `perl.mod.func(...)`.
- **Every hook takes `self`** (`def test_flags(self): return {"fatal": 1}`) — all top-level `def`s are bound as Perl methods; `def run():` dies with `TypeError: run() takes 0 positional arguments ...`.
- **No keyword arguments to Perl subs** — alternate positional `"key", value`: `assert_script_run("true", "timeout", 120)`. distri-opensuse's `tests/ha/check_hae_active.py` passes `trup_apply=1`: do not copy.
- **`run_args` dies** (`run_args is not supported in Python test modules`); distri-opensuse YAML schedules pass one when `TEST_CONTEXT` is set — keep `.py` out of those jobs.

## Lua modules

Needs `Inline::Lua` on the worker (os-autoinst never pulls it in); guard `loadtest` with `eval { require Inline::Lua }`. Not schedulable in distri-opensuse: its wrapper makes `tests/foo.lua.pm`.

- **Bridged: only `run`, `test_flags` (`return {fatal = 1}`), `post_fail_hook`**, called without arguments (`self` is `nil`); other hooks never run. Named arguments alternate positionally: `check_screen('tag', 0, 'no_wait', 1)`.
- **`use("testapi")` imports `@EXPORT` into Lua globals;** `use("mod", {"f", "@arr"})` picks names, the only way to `@EXPORT_OK`. Sigils are stripped; non-subs are copied at `use` time.
- **At most one `.lua` module per job** (unverified, from `autotest.pm`): all files are `dofile`d into one Lua state at load and every wrapper calls the global `run()`, so the last file wins.
- **Lua libraries load from `<module dir>/../lib/?.lua`** — `tests/foo.lua` -> `lib/`, `tests/x/foo.lua` -> `tests/lib/`.

## Scenario definitions

`scenario-definitions.yaml` replaces the instance's medium, machine and template tables for one request; nothing is stored. Upstream: experimental.

```yaml
products:
  example: {distri: example, flavor: DVD, arch: x86_64, version: "0"}
machines:
  64bit: {backend: qemu, settings: {HDDSIZEGB: "20"}}
job_templates:
  simple_boot: {product: example, machine: 64bit, settings: {DESKTOP: textmode}}
```

- **Schema `JobScenarios-01`:** only `job_templates` is required; unknown keys fail, except top-level `.name` keys for YAML anchors. Machines and templates accept `priority`.
- **Setting values are strings, keys uppercase:** unquoted `20`/`true` fails with `YAML validation failed:`.
- **Template key becomes `TEST`.** A template naming a `product` is silently skipped unless `flavor`, `arch`, `version` (or `'*'`) equal the request and `distri` equals the **lower-cased** `DISTRI`.
- **Precedence, later wins:** template < product < machine (+`BACKEND`) < request parameters; `WORKER_CLASS` is merged. Request `TEST=a,b` and `MACHINE=` filter templates.

## Schedule from CI

Writes to an instance -> SKILL.md "Write gate". Credentials -> references/openqa-model.md "Auth and roles".

```sh
openqa-cli schedule --monitor --host https://openqa.opensuse.org \
  --param-file SCENARIO_DEFINITIONS_YAML=scenario-definitions.yaml \
  DISTRI=example VERSION=0 FLAVOR=DVD ARCH=x86_64 TEST=simple_boot \
  BUILD="$REPO#$REF" _GROUP_ID=0 \
  CASEDIR="https://github.com/$REPO.git#$REF" NEEDLES_DIR=%%CASEDIR%%/needles
```

- **Exit codes:** `0` scheduled and, with `--monitor`, all jobs passed/softfailed; `1` scheduling or an API request failed; `2` a monitored job ended otherwise.
- **`--param-file KEY=path`** sends a local file; or `SCENARIO_DEFINITIONS_YAML_FILE=<URL> async=1`: without `async=1`, or for a host outside `scenario_definitions_allowed_hosts` (default: `github.com`, `raw.githubusercontent.com`), the URL is read as a path on the openQA host: `Unable to load YAML:`.
- **GitHub Actions:** upstream triggers on `pull_request_target` (forks get no secrets otherwise) and builds `CASEDIR` from `github.event.pull_request.head.*`; a checked-out YAML is the base branch's.

Sources: os-autoinst autotest.pm, OpenQA/Isotovideo/Utils.pm, distribution.pm; os-autoinst-distri-example; openQA docs/WritingTests.md, lib/OpenQA/{CLI/schedule,Schema/Result/ScheduledProducts,Worker/Engines/isotovideo}.pm; os-autoinst-distri-opensuse lib/main_common.pm
