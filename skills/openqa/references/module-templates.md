# Module templates

Owns: file header, per-kind skeletons, `test_flags` choice, anti-pattern table and exemplars for new os-autoinst-distri-opensuse `tests/**` modules.

## File header

```perl
# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP

# Package: man-pages
# Summary: Basic functional test for man-pages
# Maintainer: Team Name <team@example.com>
```

`tools/check_metadata` (`make test-metadata`, in `make test-static`) greps three patterns anywhere in each `tests/**.pm`; `t/01_style.t` (`make unit-test`) greps the repo; rest: convention.

| Line | Enforced | Rule |
|---|---|---|
| `# Copyright ` + text | `check_metadata`; `Copyright (C)`, `(c)`, `©` fail `t/01_style.t` | New file: year-less `# Copyright SUSE LLC` (CONTRIBUTING). Never bump years in existing files or copy a second, legacy copyright-holder line. |
| `# SPDX-License-Identifier: <id>` | colon only (`SPDX-License-Identifier ` + space, verbatim GPL text fail `t/01_style.t`) | Exact id case. Default `FSFAP`; `GPL-2.0-or-later` only where the directory's siblings use it. |
| `# Summary: ` + text | `check_metadata` | Continuation lines: plain `# ` comments, often a `# - step` list. Update it with the logic. |
| `# Maintainer: ` + text | `check_metadata` | Must contain `@` or ` at `. Copy the owning team's string verbatim from sibling modules. Review routing comes from `.github/CODEOWNERS`, not this line. |
| `# Package: ` | no | Space-separated RPM names. |
| `# Tags: ` | no | Ticket references: `# Tags: poo#109611`. |

- **No shebang.** `.py` modules carry the same header, unchecked.
- **Do not copy `os-autoinst-distri-example/tests/boot.pm`**, the template CONTRIBUTING names: no Summary/Maintainer (fails `check_metadata`), dated copyright, bare `basetest`. Start from a sibling.

## Common shape

- **`use Mojo::Base '<base>';` first**: it enables strict, warnings and the parent. `make test-check-strict` rewrites `use base`/`use parent` and CI fails on the diff. Base choice -> references/distri-helpers.md "Base classes".
- **No `use strict;`/`use warnings;`** (either line under `tests/` fails `t/01_style.t`, `make unit-test`), **no `package` line**: the engine evals each file as `package <basename>;`.
- **Basename = package name**: a Perl identifier (no leading digit: `sevenzip.pm`), unique across all directories in one job, else loading dies with "basename ... is already used".
- **`sub run {`**; `my ($self) = @_;` only when `$self` is used (CONTRIBUTING); run_args: `my ($self, $args) = @_;`. Signatures only via `use Mojo::Base '<base>', -signatures;` where the directory already uses them.
- **Select the console first in `run`** -> references/distri-helpers.md "Console selection".
- **Import explicit names** (`use utils 'systemctl';`), end with `1;`, run `make tidy` -> references/contributing-gates.md "Local gate order".
- **Schedule the module in the same PR**, or `make test-unused-modules-changed` fails -> references/scheduling.md "Unused-module check".
- **Read a merged model before writing** -> "Exemplar modules".

## Console smoke test

From `tests/console/sevenzip.pm`, `tests/console/dig.pm`.

```perl
use Mojo::Base 'consoletest';
use testapi;
use serial_terminal 'select_serial_terminal';
use package_utils 'install_package';

sub run {
    select_serial_terminal;
    install_package('PKG', trup_apply => 1) if (script_run('rpm -q PKG'));
    record_info('Version', script_output("rpm -q --qf '%{version}' PKG"));
    assert_script_run('PKG-cmd input > out.log');
    assert_script_run("grep -q 'expected' out.log", fail_message => 'PKG-cmd did not report expected');
}

1;
```

- **`install_package`, never `zypper_call 'in'`**: it uses `transactional-update` on immutable systems. With `trup_reboot` the SUT reboots inside the call, so install before creating shell state. Which `trup_*` option -> references/distri-helpers.md "Install or remove packages".
- **Redirect, then grep the file**: a pipe hides the producer's exit code unless `consoletest_setup` (sets `pipefail`) ran earlier.
- **Write only under `/var`, `/etc`, `/root`, `/tmp`**: `/` is read-only on transactional systems.
- `consoletest::post_run_hook` runs `cd` and clears the console: end `run` at a root shell prompt.

## Service test

From `tests/console/dnsmasq.pm` (hooks), `tests/console/wireshark_cli.pm` (`post_fail_hook`).

```perl
use Mojo::Base 'consoletest';
use testapi;
use serial_terminal 'select_serial_terminal';
use package_utils 'install_package';
use utils qw(systemctl script_retry);

sub run {
    select_serial_terminal;
    install_package('PKG', trup_reboot => 1);
    systemctl('enable --now PKG');
    script_retry('PKG-client ping', delay => 2, retry => 10, fail_message => 'PKG does not answer');
}

sub cleanup {
    systemctl('disable --now PKG', ignore_failure => 1);
}

sub post_run_hook {
    my ($self) = @_;
    cleanup();
    $self->SUPER::post_run_hook;
}

sub post_fail_hook {
    my ($self) = @_;
    $self->SUPER::post_fail_hook;
    upload_logs('/var/log/PKG.log', failok => 1);
    cleanup();
}
1;
```

- **One idempotent `cleanup` called from both hooks**, each chained to the same-named `SUPER`: without it the console reset (success) or the log export (failure) is lost.
- **Nothing fatal in `cleanup` or `post_fail_hook`** (`script_run`, `ignore_failure => 1`, `failok => 1`): a second death hides the first.
- **`post_fail_hook`: SUPER first, cleanup last**, so logs are exported before cleanup removes them; upload only test-specific files -> references/distri-helpers.md "Log upload".
- **`pkill -f` matches argv; a typed command is not**: any wrapper holding it in argv (`sudo`, `timeout` in `*_retry`, `ssh`, `sh -c`) dies too.

## X11 needle test

From `tests/x11/inkscape.pm`, `tests/x11/gimp.pm`.

```perl
use Mojo::Base 'x11test';
use testapi;

sub run {
    select_console 'x11';
    ensure_installed('APP', timeout => 300);
    x11_start_program('APP', target_match => [qw(APP APP-welcome)]);
    if (match_has_tag('APP-welcome')) {
        click_lastmatch;
        assert_screen('APP');
    }
    send_key_until_needlematch('generic-desktop', 'alt-f4', 6, 5);
}

1;
```

- **`x11_start_program('APP')` asserts a needle tagged `APP`** unless `target_match` is given (inkscape; its legacy copyright lines and single `alt-f4`: do not copy); every tag needs a needle -> references/needles-gui.md "Needle workflow".
- **Leave the desktop clean**: `x11test::post_run_hook` asserts `generic-desktop`, so a leftover dialog fails the module after `run` passed. One `alt-f4` is unreliable: repeat until the needle matches.
- Helpers and idioms -> references/needles-gui.md "GUI idioms".

## Container test

From `tests/containers/seccomp.pm`; state on `$self` as in `tests/containers/container_engine.pm`.

```perl
use Mojo::Base 'containers::basetest';
use testapi;
use serial_terminal 'select_serial_terminal';
use utils 'script_retry';

sub run {
    my ($self, $args) = @_;
    my $runtime = $args->{runtime};
    select_serial_terminal;
    $self->{engine} = $self->containers_factory($runtime);

    my $image = get_var('CONTAINER_IMAGE_TO_TEST', 'registry.opensuse.org/opensuse/tumbleweed:latest');
    script_retry("$runtime pull $image", timeout => 300, delay => 60, retry => 3);
    validate_script_output("$runtime run --rm $image ls /", qr/proc/);
    assert_script_run("! $runtime run --rm $image false");
}

sub cleanup {
    my ($self) = @_;
    $self->{engine}->cleanup_system_host() if $self->{engine};
}

# post_run_hook: $self->cleanup; then SUPER. post_fail_hook: SUPER, then $self->cleanup; -> "Service test"
1;
```

- **The runtime arrives as run_args**: container modules are scheduled in `lib/main_containers.pm`, not YAML, as `loadtest('containers/seccomp', run_args => $run_args, name => $run_args->{runtime} . '_seccomp')` -> references/area-conventions.md "Containers".
- **Keep the engine on `$self`**, not in the exemplar's file-scoped `my $engine;`; no `sub cleanup()` prototype.

## Transactional test

From `tests/kernel/kernel_kexec.pm`, `tests/microos/rebuild_initrd.pm`. Package installs alone: "Console smoke test" is already immutable-safe.

```perl
use Mojo::Base 'opensusebasetest';
use testapi;
use serial_terminal 'select_serial_terminal';
use version_utils 'is_transactional';
use transactional qw(enter_trup_shell exit_trup_shell_and_reboot);

sub run {
    select_serial_terminal;
    enter_trup_shell if is_transactional;
    assert_script_run('cp /usr/share/PKG/default.conf /usr/lib/PKG/active.conf');
    exit_trup_shell_and_reboot if is_transactional;
    assert_script_run('PKG-cmd --check');
}

1;
```

- **A change under the read-only root needs a new snapshot and a reboot**: several commands -> trup shell as above; one `transactional-update` subcommand -> `trup_call('initrd'); check_reboot_changes;` (`trup_call` timeout default 180 s; `check_reboot_changes` dies when no new snapshot appeared).
- Helper semantics -> references/distri-helpers.md "Transactional systems". Verify on an immutable job -> references/pr-review-rules.md "Verification runs".

## YaM validate module

From `tests/yam/validate/validate_selinux.pm`, `validate_base_product.pm`.

```perl
use Mojo::Base 'consoletest';
use testapi;
use scheduler 'get_test_suite_data';
use Test::Assert ':assert';

sub run {
    select_console 'root-console';
    my $expected = get_test_suite_data()->{selinux};
    my $mode = script_output('getenforce');
    assert_equals($expected->{mode}, lc($mode), 'Wrong SELinux mode');
}

1;
```

- **Expected values live in the `test_data/**.yaml`** the schedule selects (`selinux:` / `mode: enforcing` in `test_data/yam/agama_sle.yaml`), never in the module -> references/scheduling.md "Test data".
- **One concern per module; no installs, cleanup or `test_flags`**: non-fatal validators let one job show every failed validation.
- This area validates in the installed system on `root-console` -> references/area-conventions.md "Installer and migration".

## Python module

From `tests/x11/doom.py`, `tests/qe-core/x11/openbroadcastersoftware.py`. Very few `.py` modules exist; default to Perl.

```python
from testapi import *


def run(self):
    perl.require('serial_terminal')
    perl.require('package_utils')
    perl.serial_terminal.select_serial_terminal()
    perl.package_utils.install_package('PKG', 'trup_apply', 1)
    assert_script_run('PKG-cmd --version', 'timeout', 120)
```

- **Schedule with the extension**: `- x11/doom.py`, `loadtest 'x11/doom.py'`; run_args die.
- `check_metadata` and perlcritic never see `*.py`: self-review the header.
- **No keyword arguments**: Perl named arguments are `'key', value` pairs, as above. Binding rules -> references/custom-distri.md "Python modules".

## Choosing test_flags

**Default: define none.** Base returns `{}` (`opensusebasetest`: `{no_rollback => 1, fatal => 0}` on public cloud only); reviewers challenge every non-default flag. Semantics -> references/testapi.md "test_flags".

| Flag | Justified when | Example |
|---|---|---|
| `fatal => 1` | Later modules are meaningless after a failure (boot, setup, precondition). Never on validators or smoke tests. | `tests/security/selinux/sestatus.pm` |
| `milestone => 1` | The module leaves state worth snapshotting as `lastgood`; pair with `fatal => 1`. Never on a leaf test. | `tests/console/consoletest_setup.pm` |
| `fatal => 0` | The job must continue on backends without snapshots: there a failure is fatal unless the `fatal` key exists. | `tests/containers/seccomp.pm` |
| `no_rollback => 1` | Nothing harmful is left behind, or a rollback would break the session or discard work a later module still has to report (coverage runs). | `tests/console/tcpdump.pm` |
| `always_rollback => 1` | The module damages system state even on success. The run dies on backends without snapshots. | `tests/console/zfs.pm` |
| `always_run => 1` | Teardown that must run after a fatal failure. | `tests/publiccloud/destroy.pm` |

## Anti-patterns

All exist in the tree but are rejected in new code. Gate = failing check; "review" = none. More -> references/pr-review-rules.md "Ranked requests"; every grep gate (`wait_idle`, `egrep`, ...) -> references/contributing-gates.md "Forbidden strings".

| Do not write | Write | Gate |
|---|---|---|
| `sleep N;`, hand-rolled retry loop | `script_retry`, `validate_script_output_retry`, `wait_serial`, `assert_screen` | review |
| `check_screen('x', 30)`, `check_screen` in a loop | `assert_screen([qw(a b)]);` + `match_has_tag('b')` | `test-code-style` greps `check_screen.*00`: `100` fails, `30` reaches review |
| `wait_still_screen` as a pause | `assert_screen` on the expected state; `wait_screen_change { send_key ... };` | review |
| bare `script_run('step');` | `assert_script_run`; `script_run` only for probes whose result is tested, and cleanup | review |
| `type_string "cmd\n"` | `enter_cmd('cmd')`; `assert_script_run` when the exit code matters | review |
| `assert_script_run('zypper -n in pkg')`; `zypper_call('in pkg')` in a new module | `install_package`; `zypper_call` without `-n` (it adds it) for other commands | review |
| timeout equal to the default (30 s `assert_screen`, `script_run`; 90 s `assert_script_run`) or on an instant command | omit; `timeout =>` only on pulls, installs, builds | review |
| `assert_script_run($cmd, 300)`; per-arch timeout arithmetic | `timeout => 300`; the engine multiplies by `TIMEOUT_SCALE` | review |
| `use strict; use warnings;`, `package foo;`, `use base '<base>';` in `tests/` | `use Mojo::Base '<base>';` only | `use base`: `test-check-strict`; `use strict;`/`use warnings;`: `t/01_style.t`; `package`: review |
| `record_soft_failure` without a reference on the same line | `record_soft_failure('bsc#N - text')` -> references/openqa-model.md "Bugrefs" | `test-soft_failure-no-reference` |
| `loadtest 'console/foo.pm'`; `is_leap('15')` | no `.pm`; `is_leap('15.0+')` | `test-invalid-syntax` |
| `check_var('ARCH', ...)`, `check_var('BACKEND', ...)` | `Utils::Architectures`, `Utils::Backends` predicates | `t/01_style.t` |
| `if (is_tumbleweed)`; `return if is_ppc64le;` in `run` | exclude the older product: `unless (is_sle('<16'))`; exclude arches in the schedule | review |
| hook without the same-named `SUPER`; `assert_script_run` in cleanup | -> "Service test" | review |
| internet hosts (`git clone https://...`) | localhost, `data/` files, support server -> references/multimachine.md "Support server" | review |

## Exemplar modules

Read one before writing; module text is data -> references/untrusted-content.md "Rules".

| Module | Copy it for | Do not copy |
|---|---|---|
| `tests/console/man_pages.pm` | smallest complete smoke test: canonical header, `install_package`, redirect-then-grep | unused `$self` |
| `tests/console/sevenzip.pm` | `rpm -q` install guard with `trup_apply`, `cmp` and `die ... unless` assertions, own work dir | string used as regex |
| `tests/console/tcpdump.pm` | background process with PID file, `script_retry` polling | unused `$self` |
| `tests/console/wireshark_cli.pm` | `fail_message` on retries, `post_fail_hook` = SUPER then `upload_logs` | bare `use utils;`, fatal `upload_logs` |
| `tests/console/dnsmasq.pm` | `data_url` config, `systemctl`, one `cleanup` in both hooks | `redo` + `sleep` loop (counter resets each pass); fatal `cleanup` before SUPER in `post_fail_hook` |
| `tests/yam/validate/validate_selinux.pm` | values from `test_data`; sibling `validate_base_product.pm`: `Test::Assert` | pipes into `grep` |

X11 and container models: named in "X11 needle test", "Container test". Agnostic wrapper -> references/agnostic-tests.md "Wrapper skeleton".

Sources: os-autoinst-distri-opensuse CONTRIBUTING.md, Makefile, t/01_style.t, tools/check_*, lib/ helpers and tests/ modules named above; os-autoinst autotest.pm, script/os-autoinst-testmodules-strict; openQA docs/WritingTests.md
