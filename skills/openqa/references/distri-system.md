# Distri system

Owns: os-autoinst-distri-opensuse `lib/` helpers that change or reach into the system under test (packages through zypper, reboots, transactional snapshots, registration, log upload, files on the SUT): real arguments and defaults from the `sub` bodies, and the raw idiom each replaces.

## zypper_call

```perl
zypper_call($command, exitcode => [0], timeout => 700, log => undef);
if (zypper_call("se -x python311-Django", exitcode => [0, 104]) == 104) {   # tests/console/django.pm
```

- **Pass the command without `zypper`, `-n` or `-y`**: it runs `zypper -n $command`.
- **Never pipe to grep**: `| grep` outside backticks dies (`Exit code is from PIPESTATUS[0], not grep`). Parse with `zypper_search($params)` / `zypper_repos($params)`, which return an arrayref of hashes (`name`, `status`, `type`, with `-s` also `version arch repository`; repos: `alias name enabled ...`).
- **List every tolerated exit code** and branch on the return value: `[0, 104]` nothing found, `[0, 107]` failing RPM scriptlet, `[0, 102, 103]` for `patch`. Any other code uploads `/var/log/zypper.log` and dies.
- Defaults use `||`: `timeout => 0` or an empty `exitcode` silently become 700 and `[0]`.
- **Exit 4 is re-run up to 5 times** (a solver conflict stops at once, HTTP 502 dies); on FLAVORs matching `-(Updates|Incidents)` also 8, 105, 106, 139, 141, each with an automatic soft failure. An unreachable repo thus costs five runs.
- `zypper_ar($url, name => $alias, priority => N, no_gpg_check => 0)` imports keys, skips an existing alias and refreshes only that repo; without `name`, `$url` must be a `.repo` file.
- `zypper_version_cmp($v1, $v2)` returns -1/0/1; use it instead of regex-matching version output.
- **Replaces**: `assert_script_run 'zypper -n ...'` (no retry, no log upload, 90 s default timeout).

## Reboot

**Classic system**: `power_action` triggers, `wait_boot` (a method) supervises; afterwards no console is logged in, so select one again.

```perl
power_action('reboot', textmode => 1);        # use power_action_utils 'power_action';
$self->wait_boot(bootloader_time => 300);     # tests/console/journalctl.pm
select_serial_terminal;
```

- `power_action($action, observe => 0, keepconsole => 0, textmode => check_var('DESKTOP', 'textmode'))`; `$action` is `reboot` or `poweroff`. Without `keepconsole` it first selects `root-console` (textmode) or `x11`, so a console module on a desktop job passes `textmode => 1`. `observe => 1` only supervises a reboot started elsewhere. It does not wait for the boot.
- `wait_boot(bootloader_time => 100, ready_time => 300)` (300 on pvm/ipmi, 500 on ipmi/hyperv) handles bootloader, disk unlock, s390x/pvm reconnect.
- **Transactional system**: not the pair above. `install_package(..., trup_reboot => 1)`, `check_reboot_changes` or `process_reboot(trigger => 1)` reboot, log in and **re-select the previous console themselves** -> "Transactional systems".
- **Replaces**: `assert_script_run 'reboot'` (exit marker never arrives); `enter_cmd 'reboot'; sleep ...`.

## Transactional systems

`use transactional;` Everything lands in a new snapshot that is inactive until reboot or `apply`.

| Helper | Contract |
|---|---|
| `trup_call($cmd, timeout => 180, exit_code => 0, proceed_on_failure => 0)` | runs `transactional-update -n $cmd` after waiting for `rollback.service`; dies on timeout or unexpected exit code; `proceed_on_failure => 1` returns the code instead. `--continue` in `$cmd` chains onto the pending snapshot |
| `check_reboot_changes($expected // 1)` | dies unless a new default snapshot exists (with `0`: unless none does); reboots if one does |
| `reboot_on_changes()` | same comparison without the assertion |
| `process_reboot(trigger => 0, expected_grub => 1, expected_passphrase => 0)` | `trigger => 1` issues the reboot, else only observes; uses `root-console` needles (grub, login) even in a serial-only module, then switches back. `expected_grub` defaults to 0 on VMware |

- Packages -> distri-helpers.md "Install or remove packages"; anything else `trup_call`, not raw `transactional-update` strings.
- Already transactional-aware: `install_package`, `uninstall_package`, `fully_patch_system`, `add_suseconnect_product`.
- Module shape -> references/module-templates.md "Transactional test".

## Registration

`use registration;` — SLE only, always behind `is_sle(...)`; SLE 16 has almost no modules, so real code gates on `is_sle('<16')`.

```perl
add_suseconnect_product("PackageHub", undef, undef, undef, 300, 1) if is_sle;   # tests/console/django.pm
```

- `add_suseconnect_product($name, $version, $arch, $params, $timeout, $retry)` is **positional**; defaults `${VERSION_ID}`, `${CPU}` (shell variables from `/etc/os-release`), `''`, 300, 3 retries with growing sleeps, then dies. On transactional systems it runs `transactional-update register -p` with job `ARCH`, ignoring `$arch` and `$timeout`.
- `get_addon_fullname($short)` maps `phub`, `sdk`, `desktop`, `legacy`, `contm`, `ha`, `we` ... to SCC names; `sdk` is `sle-sdk` before 15, else `sle-module-development-tools`.
- `remove_suseconnect_product($name)` retries 5 times. Undo registrations in cleanup; in tree guarded by `is_sle('<16') && !main_common::is_updates_tests()`.

## Log upload

**`opensusebasetest::post_fail_hook` already uploads** (do not duplicate): health check, process list, `journalctl -b`, `dmesg`, `/etc/sysconfig`, one journal per unit started via `systemctl()`, `problem_detection_logs.tar.xz`, network and unit listings, the solver test case after a `zypper_call` failure, core dumps with `COLLECT_COREDUMPS`. `NOLOGS=1` disables everything.

- Add a module `post_fail_hook` only for component-specific files and **call `$self->SUPER::post_fail_hook` first**; a hook without it drops every log above.
- `save_and_upload_log($cmd, $file, {timeout => N, screenshot => 1, noupload => 1, logname => 'x'})` runs `$cmd | tee $file`, ignores the exit code, uploads with `failok`. **Options are a hashref**; the flat list the POD shows is silently lost.
- `tar_and_upload_log($sources, $dest, {timeout => N, screenshot => 1, noupload => 1, gzip => 1})` writes **bzip2** (POD says xz) unless a `gzip` key is present, even `gzip => 0`; name the archive to match.
- `save_ulog($string, $name)` (`Utils::Logging`) writes worker-side without SUT network; `serial_terminal::upload_file($src, $dst)` moves a file over the serial line into `ulogs/`.
- **Only non-fatal calls inside `post_fail_hook`** (`script_run`, `upload_logs(..., failok => 1)`): a dying `assert_script_run` aborts the remaining collection.

## Files on the SUT

Fixtures live under `data/`; fetch them from the worker, never from the internet at run time. `data_url`, `curl -f`, directory-as-cpio -> references/scheduling.md "Files from data"; YAML test data -> references/scheduling.md "Test data".

- `write_sut_file($path, $contents)` (`utils`) places Perl-generated content: curl to `/tmp`, then `mv -Zf` into place. Replaces typed heredocs.
- `download_script($src, $dest)` fetches from `data/` and `chmod a+x`; with `OFFLINE_SUT` it types the file instead. Not exported by default: `use utils qw(download_script);`.
- `serial_terminal::download_file($src, $dst, force => 0)` copies worker to SUT over the serial line (no network); `$src` with `data/` resolves against `CASEDIR`, else `ASSETDIR`; dies if `$dst` exists.

Sources: os-autoinst-distri-opensuse lib/utils.pm, lib/power_action_utils.pm, lib/opensusebasetest.pm, lib/transactional.pm, lib/registration.pm, lib/main_common.pm, lib/Utils/Logging.pm, lib/serial_terminal.pm; os-autoinst testapi.pm
