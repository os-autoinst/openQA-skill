# os-autoinst test API

Owns: the test API as os-autoinst executes it. Distri wrappers: `zypper_call` -> references/distri-helpers.md "zypper_call"; `script_retry` -> references/distri-helpers.md "Retry and poll".

Contents: Module contract; Hook order; test_flags; Function cheat sheet; Variables; Result recording; Uploads and URLs; Serial terminal; Traps

## Module contract

- **Only `run` is required.** Inherited: `test_flags` `{}`, the three hooks no-ops, `is_applicable` 1 (false = not scheduled).
- **Header `use Mojo::Base 'basetest', -signatures; use testapi;`** — `use base 'basetest'` enables neither strict nor signatures unless the schedule sets `ENABLE_MODERN_PERL_FEATURES=1` before `loadtest`.
- **Omit `package`** — the file is evaluated inside `package <basename>`; a hand-written one must equal the basename.
- **Basename unique across all test directories** — a second path with the same basename dies at `loadtest`; the same file twice is fine (`name#1`).
- **`run($self, $run_args)`** gets the `OpenQA::Test::RunArgs` object of `loadtest(..., run_args => $obj)` (Perl only) — the way to parametrise a module scheduled twice; `set_var` in schedule code is global, last write wins.
- **SUT-touching calls only inside modules** — in schedule code they die `isotovideo is not initialized`; `get_var`/`set_var`/`check_var` are safe there.
- Distri base classes -> references/distri-helpers.md "Base classes"; skeletons -> references/module-templates.md "Common shape".

## Hook order

`pre_run_hook` -> `run` -> `post_run_hook` (one `try`) -> serial-failure scan (`BACKEND=qemu` only) -> `post_fail_hook` if died or result is `fail` -> scheduler applies `test_flags`.

| Event | Consequence |
|---|---|
| `die` in `pre_run_hook`, `run` or `post_run_hook` | rest of the three skipped; module fails (even if only `post_run_hook` died); `post_fail_hook` runs |
| `die` in `post_fail_hook` | caught, logged as `post_fail_hook failed:`, on newer os-autoinst also a failed box `Failed` `(post)`: `# Post fail hook died: $msg`; rest of the hook lost |
| `$self->result('fail')`, no `die` | execution continues; then `post_fail_hook` runs and the module fails |
| `_SKIP_POST_FAIL_HOOKS=1` | `post_fail_hook` not called |

- **Cleanup goes in both `post_run_hook` and `post_fail_hook`** (each is skipped in the other's case); in `post_fail_hook` only non-fatal calls, most valuable first (`upload_logs $f, failok => 1`) -> references/module-templates.md "Service test".
- **Select the console first in `run`** — a rollback re-selects the milestone's console, otherwise the failed module's console stays -> references/distri-helpers.md "Console selection".

## test_flags

Hashref; only these six keys are read:

| Flag | Effect as executed |
|---|---|
| `fatal => 1` | failure stops the job; later modules get `skip`, except `always_run` ones |
| `fatal` absent | non-fatal only on a snapshot-capable backend, fatal elsewhere; write `fatal => 0` to continue anyway |
| `milestone => 1` | after success save snapshot `lastgood` (snapshot backends; not when the next module is `milestone` + `fatal`) |
| `no_rollback => 1` | no rollback after this module (cancels its own `always_rollback` too) |
| `always_rollback => 1` | roll back to `lastgood` even on success; without snapshot support the whole run dies unless `FAIL_ON_ALWAYS_ROLLBACK_NOT_SUPPORTED=0` |
| `always_run => 1` | runs even after a fatal stop (teardown, log collection) |
| `ignore_failure => 1` | ignored by os-autoinst; openQA leaves the module out of the job result |

- **Rollback needs an earlier `milestone` module that passed** and `no_rollback` unset; otherwise the next module inherits the wreck. A rollback shows as a `Snapshot` box on the next module.
- **Snapshot-capable:** `qemu` unless `QEMU_DISABLE_SNAPSHOTS` or any `HDDMODEL*` is `nvme`; `svirt` with `VIRSH_VMM_FAMILY` `kvm`/`hyperv`/`vmware`. Elsewhere default flags are fatal.
- **`force_soft_failure` changes the result, not control flow**: after a `die`, `fatal` and rollback still apply.
- Which flags to pick -> references/module-templates.md "Choosing test_flags".

## Function cheat sheet

Timeouts: seconds, multiplied by `TIMEOUT_SCALE` (do not inflate calls for slow workers). "dies" = exception that fails the module. `[, $t]` = positional timeout accepted; `timeout => $t` also works.

### Commands

`script_sudo`, `become_root`, `become_user`, `ensure_installed`, `x11_start_program` only dispatch to the distri -> references/distri-helpers.md "Install or remove packages".

| Call | Timeout | Returns | Dies |
|---|---|---|---|
| `script_run($cmd [, $t] [, quiet => 1, output => 'note'])` | 30 | exit code; `undef` only for `timeout => 0` (type and leave) | on timeout; never on non-zero exit |
| `assert_script_run($cmd [, $t [, $msg]] \| [fail_message => $msg, quiet => 1])` | 90 | nothing | timeout, non-zero exit |
| `script_output($script [, $t] [, proceed_on_failure => 1, type_command => 1, quiet => 1])` | 90 | output, trimmed | timeout; non-zero exit unless `proceed_on_failure` |
| `validate_script_output($script, sub { m/../ } \| qr/../ [, $t] [, title =>, fail_message =>, proceed_on_failure =>])` | 90 | 0; box with script, check, output | check false (coderef sees the output in `$_`); check neither coderef nor `qr`; whatever `script_output` throws |
| `background_script_run($cmd [, quiet => 1])` | - | PID | `PID marker not found` |

- `quiet => 1` drops the result box; `_QUIET_SCRIPT_CALLS=1` makes that the default.

### Serial and typing

| Call | Default | Returns / dies |
|---|---|---|
| `wait_serial($re \| [@re] [, $t] [, expect_not_found => 1, no_regex => 1, quiet => 1])` | 90 | text up to the match, else `undef` (inverted by `expect_not_found`); never dies |
| `type_string($s [, max_interval => 1..250, wait_screen_change => N, wait_still_screen => N, secret => 1, lf => 1])` | `max_interval` 250; lower = slower | dies only if `wait_still_screen` is set and the screen does not settle within `timeout` (30) |
| `enter_cmd($s, ...)` | same | `type_string` + `lf => 1` |
| `type_password([$s], ...)` | `$password`, `max_interval` 100 | string not logged |
| `send_key($key [, hold_duration => $s, wait_screen_change => 1])` | - | `ret esc tab spc up ...`; combos `'alt-n'`, `'ctrl-alt-f3'`; `hold_duration` keeps the key down `$s` seconds (older os-autoinst ignores it) |

- A plain string given to `wait_serial` is still a regex unless `no_regex => 1`. Matched output is consumed; later calls see only newer text.
- Exported: `$serialdev` (`ttyS0`; `hvc0` or `ttysclp0` by backend), `$username`, `$password`.
- `is_serial_terminal` is export-on-request: `use testapi qw(is_serial_terminal :DEFAULT);`

### Screen and mouse

Needle strategy -> references/needles-gui.md "GUI idioms".

| Call | Timeout | Returns / dies |
|---|---|---|
| `assert_screen($tag \| [@tags] [, $t] [, no_wait => 1])` | 30 | match hashref on first match, so a generous timeout is free on the good path; dies `no candidate needle with tag(s) ... matched` |
| `check_screen(...)` same args | **0** (one look) | match or `undef`; a non-zero timeout is paid in full whenever the screen is absent |
| `assert_and_click($tag [, timeout =>, button => 'left', dclick => 1, point_id =>])`, `assert_and_dclick` | 30 | dies like `assert_screen` |
| `click_lastmatch([button =>, dclick =>, ...])` | - | `undef` if nothing matched before |
| `wait_screen_change { ... };` | 10 | 1 changed, 0 timeout |
| `wait_still_screen([$still] [, $t] [, similarity_level => 47])` | stilltime 7, timeout 30 | 1 still, 0 timeout (0 at once if timeout < stilltime) |
| `send_key_until_needlematch($tag, $key [, $count = 20 [, $t = 1]])` | - | dies after `$count` presses |

- ARRAYREF = any of the tags (`match_has_tag($tag)` then tells which matched); one string with spaces = a needle carrying all of them.
- `assert_screen_change`/`assert_still_screen` are the dying variants of the `wait_*` pair.

### Consoles and VM

| Call | Notes |
|---|---|
| `select_console($name [, @args])` | dies with the backend error; first selection runs the distri's `activate_console` (login); names are distri-defined -> references/distri-helpers.md "Console selection" |
| `reset_consoles` | next select re-activates (after anything that kills logins) -> references/distri-helpers.md "Reboot" |
| `check_shutdown([$t = 60])`, `assert_shutdown([$t])` | only watch, never initiate; backends lacking `is_shutdown` sleep the timeout and report success |

## Variables

| Call | Behaviour |
|---|---|
| `get_var($name [, $default])` | default only when **undefined**; `0` and `''` come back as-is, so `get_var('X', 1)` is false for `X=0` |
| `get_required_var($name)` | dies when undefined; `''` passes |
| `check_var($name, $value)` | defined and string-`eq`; `check_var('X', 1)` is false for `X=true` and for unset |
| `set_var($name, $value [, reload_needles => 1])` | runtime, seen by later modules of this job; `reload_needles` re-runs needle selection |
| `get_var_array($name [, $default])`, `check_var_array($name, $value)` | list split on `,` or `;` (not `\|`, despite the POD) |

- **Secrets:** names starting `_SECRET_`, containing `_PASSWORD` or matching `_HIDE_SECRETS_REGEX` stay out of `vars.json`; type them with `type_password` or `secret => 1`.
- Where settings come from -> references/scheduling.md "Settings precedence"; naming and documenting a new one -> references/scheduling.md "Adding a variable".

## Result recording

| Call | Effect on the module result |
|---|---|
| `record_info($title [, $output] [, result => 'ok' \| 'fail' \| 'softfail'])` | **none, ever** — a coloured box. Other values die. `$output` is positional: `record_info('T', result => 'fail')` dies with an odd-argument error |
| `record_soft_failure($reason)` | `softfail` unless already `fail`; execution continues, so the workaround must follow. Reference in `$reason` -> references/contributing-gates.md "Soft-failure reference" |
| `force_soft_failure($reason)` | `softfail` even over `fail`; for `post_fail_hook` |
| `die $msg` | fails now; box `Failed`: `# Test died: $msg` |
| `parse_extra_log(Format => $file)` | uploads `$file`, adds its cases as extra results; `JUnit XUnit LTP IPA TAP` |

- **A module ends `softfail` when** `record_soft_failure` ran, a matched needle has a `workaround` property, or a distri `serial_failures` pattern of type `soft` hit (qemu only), and nothing failed.
- **Step budget:** every box, screenshot and serial wait is a step; beyond `MAX_TEST_STEPS` (50000) the job is `incomplete` — bound polling loops.

## Uploads and URLs

| Call | Behaviour |
|---|---|
| `upload_logs($file [, failok => 1, timeout => 90, log_name => 'x.log'])` | dies on failure unless `failok` (then a missing file is fine); returns the stored name, `<module>-<basename>` or `log_name` |
| `upload_asset($file [, $public [, $nocheck]])` | private by default; `$public` = fixed name replacing the previous asset; asserted with a fixed 90 s unless `$nocheck` |
| `get_test_data($relpath)` | content of `CASEDIR/data/$relpath`, read on the worker; `undef` if missing |
| `save_tmp_file($relpath, $content)` | written on the worker (e.g. edited test data); the SUT fetches `autoinst_url("/files/$relpath")` |
| `data_url($name)` | URL of `data/$name` (a directory comes as cpio archive); `ASSET_<n>`/`REPO_<n>` -> that asset/repo |
| `autoinst_url([$path])` | `http://<host>:<QEMUPORT+1>/<JOBTOKEN>$path`; host `10.0.2.2` on qemu, else `WORKER_HOSTNAME` |

- **Uploads are `curl` run inside the SUT on the selected console** — they need a shell prompt, `curl` and a route to the worker; with `OFFLINE_SUT=1` they become an info box.
- Log-collection helpers -> references/distri-helpers.md "Log upload"; `data/` layout -> references/scheduling.md "Files from data".

## Serial terminal

Text-only consoles (`root-virtio-terminal`, `root-sut-serial`): fast and screenless, but a real tty. Selecting one -> references/distri-helpers.md "Console selection".

- **Stdout is a tty, stderr is captured**: `cmd </dev/null 2>>$log | cat` - `| cat` alone leaves stderr in.

- **Unavailable:** needle calls, clicks, mouse, `save_screenshot` (no-op), `hold_key`/`release_key`, `send_key` other than `'ret'`.
- **Signals:** `is_serial_terminal() ? type_string('', terminate_with => 'ETX') : send_key 'ctrl-c';` — `'EOT'` is ctrl-d.
- **The prompt must be the distri's `serial_term_prompt`** (`# `; os-autoinst-distri-opensuse: `# ` root, `$ ` user) — `script_run`/`script_output` wait up to 90 s for that literal, then type anyway: a custom `PS1` or a foreground program costs 90 s per call.
- **Never wait for the prompt yourself after a command** — it eats the prompt the next `script_run` needs.
- **No newline inside a `script_run` command** — the echo check dies `typing command '...' timed out`. Multi-line scripts -> references/performance.md "Batch and upload".
- **Drop `> /dev/$serialdev`** — `wait_serial` reads the terminal, not `serial0` (the redirect is deprecated on VNC consoles too).

## Traps

- **`script_run` returns an exit code and 0 is false** — `if (script_run 'cmd')` means "if it failed". Write `if (script_run('which ansible-community') == 0)`; use `assert_script_run` when the command must succeed. It throws on timeout (default 30 s); `die_on_timeout` is gone and silently ignored.
- **No trailing `&`** — `script_run`/`assert_script_run` die on it. `my $pid = background_script_run "$cmd >/tmp/out.log 2>&1";` — unredirected output corrupts the PID marker.
- **`script_output` runs under `bash -e -o pipefail`** (plus `-x` on VNC consoles): any failing command or pipe stage, a `grep` without hits included, makes it die `script failed with : <output>` — pass `proceed_on_failure => 1` where a failure is an answer, not a filter kept alive by `|| true` (next point). VNC consoles capture stdout only (add `2>&1`), may mix in kernel messages (match with a regex, not `eq`) and fetch scripts of 80+ characters by `curl` from the worker — without SUT network pass `type_command => 1`.
- **No filter on a command's output: capture it, then match in Perl** — behind `| grep`, `awk`, `sed`, `cut`, `head`, `tail` or `wc` the log shows only what the filter made of it, so a failure or an unexpected result leaves no reason. `my ($k8s_version) = script_output('kubectl version') =~ /[Ss]erver.*:\s*(.*)/;`; a plain check: `validate_script_output('curl --fail -v http://localhost/', qr/index/);` records command, pattern and output in one box. `| tee` that keeps a log is fine; in `assert_script_run` write `(set -o pipefail; cmd | tee /tmp/cmd.log)` unless `consoletest_setup` (sets `pipefail`) ran earlier, or `tee`'s exit code hides the producer's.
- **Commands must return to the same shell prompt.** The exit code comes from a marker appended to the command or, on bash VNC consoles (`PRETTY_SERIAL_MARKER`, default 1), from a `PROMPT_COMMAND` hook appended to `~/.bashrc` and `~/.profile`. After `su`, `ssh`, a nested shell, a pager or a REPL no marker arrives -> timeout. Use `become_root`/`become_user`; for an interactive region hold `my $guard = $testapi::distri->pretty_serial_marker_guard(0);` and use `enter_cmd` + `wait_serial`.
- **Quoting has two layers.** Perl double quotes eat `$VAR`, `@x` and `$(`: single-quote shell text or escape (`"echo \$HOME >> $logfile"`). The shell may get `; echo <marker>` appended: an unbalanced quote, a trailing `#` or `;`, or an open here-doc swallows it -> timeout.
- **`type_string` presses no Enter, `enter_cmd` does; neither waits nor checks** — follow with `wait_serial(qr/READY/, timeout => 30) or die 'not ready';` or use the `script_run` family.
- **Named args only:** `assert_and_click`, `assert_and_dclick`, `click_lastmatch`, `mouse_drag`. `assert_and_click('tag', 60)` dies `Odd name/value argument`; write `timeout => 60`.
- **`wait_screen_change` with a timeout:** `wait_screen_change(sub { send_key 'alt-n' }, 20)`; `0` becomes 10. The triggering action goes inside the block or the change is missed.
- **`record_info ..., result => 'fail'` leaves the module green** — to fail, `die` -> "Result recording".
