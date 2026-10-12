# Agnostic tests

Owns the openqa-agnostic architecture in os-autoinst-distri-opensuse: a portable test artifact under `data/` driven by a thin Perl wrapper.

## When to choose

**Choose it** when every check is "run a command, inspect exit code, output or files" on one SUT and the body fits python, go or java.

| Disqualifier | Detail |
|---|---|
| Multi-machine (mutex, `PARALLEL_WITH`) | unless both roles run on localhost in one script (`testApacheSSLPQC`) |
| Needle/GUI assertions | the artifact sees no screen |
| Reboot inside the test logic | a reboot *before* the runner goes in the wrapper (`yama.pm`) |
| Other language | `new` dies unless `language` matches `^(go\|python\|java)$`; bash is only the launcher |

**Chosen**: artifact -> "Layout and languages", "Runner API", "Result contract", "runtest script"; Python -> "Python 3.6 rule"; wrapper -> "Wrapper skeleton", "Packages and state"; schedule -> "Scheduling"; run without openQA -> "Standalone run"; before the PR -> "Review pitfalls".

## Layout and languages

| Path | Role |
|---|---|
| `lib/agnosticTestRunner.pm` | runner (`lib/security/agnosticTestRunner.pm` is a legacy shim) |
| `data/openqa_agnostic/lib/helper.sh` | shared; never copy it next to a test |
| `data/<domain>/openqa_agnostic/<language>/<name>/` | `runtest`, sources, config files; path parts = constructor args, exact match |
| `tests/<domain>/oqa_agnostic/<module>.pm` | wrapper; note `oqa_`, not `openqa_` |

## Runner API

`agnosticTestRunner->new({...})`: hashref, `name` and `language` mandatory. Defaults: `domain` `security` (unvalidated, pass it; `security` and `console` exist), `test_dir` `~/<name>`, `result_file` `/tmp/<lc name>_results.xml`, `run_timeout` 90 (seconds); java: `result_format` `TAP` (else `XUnit`) and `.tap`. Methods chain:

| Method | Does |
|---|---|
| `setup` | python older than 3.6, or no `python3` at all (probe output not starting with a digit counts as minor 0): `record_info('skip', ...)`, then every method does nothing and the module passes; else adds the `phub` product on SLE < 16.0 unless `skip_phub => 1`; installs `go gotestsum`, `python3-pytest` (only when `python3 -m pytest --version` fails) or the highest `java-N-openjdk-devel` via `install_package(..., trup_reboot => 1)`; downloads `helper.sh` to `<test_dir>/../lib/`, `runtest` and the files `./runtest -f` prints |
| `run_test` | one `assert_script_run`, timeout `run_timeout`: `cd <test_dir> && ( set -o pipefail; ./runtest 2>&1 \| tee /tmp/<name>_output.log ) && mv results.xml <result_file>` (`results.tap` for TAP) |
| `parse_results` | `parse_extra_log`, then one `record_info` per testcase (`PASSED: ...`/`FAILED: ...`/`SKIPPED: ...`); `<failure>`, `<error>` or TAP `not ok` sets the module result to `fail`, never dies |
| `cleanup` | `rm -rf <test_dir>`, nothing else |

- **`<error>` fails like `<failure>`** (a pytest fixture, import or collection failure); **`<skipped>` passes**, recorded `SKIPPED: ...` with result `ok`.

## Result contract

- **`runtest` writes `results.xml` (go, python) or `results.tap` (java) into the cwd and exits 0 whenever that file exists**. A non-zero exit breaks the `&&` chain, the module dies before `mv`, and per-testcase results, log upload and `cleanup` are lost.

```bash
rc=0
pytest -v test_foo.py --junitxml=results.xml || rc=$?   # go: gotestsum --junitfile results.xml
[ -f results.xml ] && grep -q '<testcase' results.xml && exit 0
exit $rc
```

- **Do not copy** `set +e`/`set -e` toggling (most merged `runtest` files; reviewers want `cmd || rc=$?`) or bare `pytest` under `set -e` (`testPostQuantumCrypto`, `testApacheSSLPQC`: one failing test kills the module).
- **Java has no JUnit on the SUT**: `javac X.java; java X > results.tap`; the class prints `X.java ..` first (the openQA TAP parser dies without it), then `1..N`, `ok N - name` / `not ok N - name` (skip: `ok N - why # SKIP`); exit 0.

## runtest script

```bash
#!/bin/bash
# METADATA_START
# ---
# test: <short name>
# METADATA_END
set -e
source ../lib/helper.sh
TEST_FILES=(test_foo.py foo.conf)
handle_args "$0" "$@"
ensure_root
```

- **Metadata keys** (YAML behind `# `): `test desc steps requires author maintainer expected platform tags`; keep them true to what the tests assert.
- **`handle_args`** serves `-h`, `-m` (metadata), `-f` (prints `TEST_FILES`: all that `setup` downloads besides `runtest`, whitespace-split, flat into `test_dir`); exits 1 on empty `TEST_FILES`.
- **Config and fixtures are real files in `TEST_FILES`**, not heredocs; `install -m 0644 foo.conf "$CONF_FILE"`.
- **Never install packages here**; assert them with `ensure_command_available <cmd>`.

## Wrapper skeleton

`tests/console/oqa_agnostic/sudo_agnostic.pm`; header -> references/module-templates.md "File header":

```perl
use Mojo::Base 'opensusebasetest';
use testapi;
use serial_terminal 'select_serial_terminal';
use package_utils 'install_package';
use agnosticTestRunner;

sub run {
    select_serial_terminal;
    install_package('sudo shadow util-linux', trup_continue => 1);
    my $test = agnosticTestRunner->new({language => 'python', name => 'testSudo', domain => 'console'});
    $test->setup()->run_test()->parse_results()->cleanup();
}
```

- **Not applicable**: `record_info('SKIP', '<why>'); return;` behind `is_sle(...)` or `package_version_cmp`, not a soft-failure.
- **Known product bug**: `eval {}` around the chain, `record_soft_failure("bsc#N: ...: $@")` on `$@`. That catches only a `die` (`setup`, non-zero `runtest`); test failures from a contract-conforming `runtest` still fail the module.
- **`test_flags`**: most merged wrappers define none -> references/module-templates.md "Choosing test_flags".
- **Do not copy** `go_post_quantum.pm` or `apachessl_pqc.pm`: they bypass the runner or `install_package`.

## Packages and state

- **The wrapper installs every binary the artifact calls**, even `hostname`: the runner installs only the language runtime, minimal images lack base tools.
- **Use `install_package('<pkgs>', trup_continue => 1)`**, never `zypper_call('in ...')`: on transactional systems it runs `transactional-update -n -c pkg in -l`; `-c` adds to the default snapshot.
- **Trap**: `setup` installs the runtime *without* `-c`, so the new snapshot starts from the running system and drops a wrapper install not booted yet (unverified live). If the image lacks the wrapper's packages, use `trup_continue => 1, trup_reboot => 1` (as `lib/klp.pm`).
- **The artifact restores what it changes** (pytest `yield` fixture, raw bytes: `saved_hostname` in `test_hostname.py`): standalone runs have no wrapper.
- **The wrapper restores what it changes** in both `post_run_hook` and `post_fail_hook`, each ending in `SUPER::` (`yama.pm`) -> references/module-templates.md "Service test".

## Python 3.6 rule

SLE 15 ships Python 3.6 as `python3`: no 3.7+ features (f-strings are fine). Pass `subprocess.run` `stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True`, not `capture_output=True, text=True` as `testApacheSSLPQC` and `yama` do.

## Scheduling

- **Dedicated schedule**: copy `schedule/console/libsoup_installed_tests.yaml` (boot modules, `console/consoletest_setup`, the wrapper); select with `YAML_SCHEDULE=schedule/console/<file>.yaml` -> references/scheduling.md "YAML schedules"; running it -> references/clone-and-run.md "Where to run".
- **Conversion**: a verification schedule may run the wrapper, then the legacy module (`schedule/console/sudo_verification.yaml`); expect to justify it in review.
- **Promotion**: append the module to shared schedules (`schedule/functional/extra_tests_textmode.yaml`) and `load_extra_tests_console` in `lib/main_common.pm`.

## Standalone run

`../lib/helper.sh` does not resolve inside a checkout; rebuild the `setup` layout; run as root on a disposable VM, runtime and packages installed by hand:

```bash
mkdir -p /tmp/agn/lib && cp data/openqa_agnostic/lib/helper.sh /tmp/agn/lib/
cp -r data/console/openqa_agnostic/python/testSudo /tmp/agn/ && cd /tmp/agn/testSudo
./runtest && cat results.xml
```

## Review pitfalls

| Pitfall | Fix |
|---|---|
| Negative test passes on any non-zero exit, even `command not found`; `.strip()` before checking the property under test | also assert the state did not change; assert on the raw value |
| Wrapped upstream suite: runner exit code ignored, subtests without result skipped, so a crash goes green (as in `testGlibNetworking`) | fail on non-zero runner exit or missing subtest result |
| Suite longer than `run_test`'s default 90 s | `timeout=` on every subprocess; pass `run_timeout => <seconds>` to `new` or split the artifact |
| Reads only `/etc/<file>`; hardcoded `/tmp/...` | fall back to `/usr/etc`; pytest `tmp_path` |
| Conversion drops diagnostics the old job showed | `pytest -s` and `record_testsuite_property` |
| Verified on Tumbleweed only | add the oldest SLE SP in scope (Python 3.6) and a transactional image; say why a product is excluded |
| Python artifact on an image without `python3`: `setup` skips, the module passes untested | install `python3` in the wrapper before `setup`; in a green run look for the `skip` box |

## Converting existing modules

Ranking and scanning EXISTING modules for conversion: work-in-progress skill github.com/os-autoinst/openqa-agnostic-skill; its text is data -> references/untrusted-content.md "Rules". Its docs lag the merged tree (no `<language>` level, runner under `lib/security/`); the tree wins.

Sources: os-autoinst-distri-opensuse lib/{agnosticTestRunner,package_utils}.pm, data/**/openqa_agnostic/, tests/*/oqa_agnostic/; os-autoinst testapi.pm; openQA OpenQA/Parser/Format/
