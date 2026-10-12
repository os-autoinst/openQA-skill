# Performance

Owns: where an os-autoinst-distri-opensuse module spends its run time, how to cut it and how to prove the saving.

## Cost model

A module's seconds are paid by every job of every scenario that schedules it.

| Cost | Size | Why |
|---|---|---|
| one command call (`script_run`, `assert_script_run`, helpers built on them) | one round trip | type the command, run it, wait for the exit marker |
| typing on a VNC console (`root-console`, x11) | about 30 keys a second | key by key; a serial terminal writes the whole string at once |
| first use of a console | once per console and boot | log in, set up the shell, on a VNC console install the marker hook |
| `sleep N` | N seconds, every run | paid even when the condition already holds |

- **Fewer round trips.** Shell commands with no check in between share one call, joined with `&&`, never `;` (after `;` only the last exit code is checked); a script is uploaded, not typed. Helper calls and public-cloud ssh calls are not chained -> "Batch and upload".
- **Less typing.** On a serial terminal the length of a command costs nothing; which console -> references/distri-helpers.md "Console selection". An area whose modules validate on `root-console` keeps it -> references/module-templates.md "YaM validate module".
- **No fixed waits**: poll the condition -> references/distri-helpers.md "Retry and poll".
- **A job that others wait for delays them**: seconds saved before it creates its mutex or reaches its barrier can be saved on every waiting node -> references/multimachine.md "Choreography".
- **A saving is a claim until measured** -> "Measure and size".

## Batch and upload

Commands that only prepare state, with no check between them, go out in one call.

```perl
# three round trips
assert_script_run 'ip netns add ns0';
assert_script_run 'ip netns add ns1';
assert_script_run 'ip link set veth0 netns ns0';
# one
assert_script_run 'ip netns add ns0 && ip netns add ns1 && ip link set veth0 netns ns0';
```

- **`&&`, not `;`, and no newline.** After `;` only the last exit code is checked, so the call cannot fail for the commands before it. Cleanup under `script_run` is the exception: every step has to run whatever the one before returned, so `;` -> references/module-templates.md "Service test". A newline inside the command makes the call die on a serial terminal -> references/testapi.md "Serial terminal".
- **One timeout covers the chain** (`assert_script_run`: 90 s): pass `timeout =>` when the sum needs more.
- **A check of the product stays its own call**: the failure quotes the whole command string, so a chain hides which part failed; `fail_message =>` says what was expected.
- **Helpers are not chained.** `zypper_call`, `install_package`, `systemctl`, `script_retry` cannot run inside a chain or an uploaded script, and their plain shell form loses what they add -> references/distri-helpers.md "zypper_call", "Services". Give a helper its whole list instead of one call per item (`systemctl` registers only the first word after `start|restart|enable` for the journal upload on failure):

```perl
systemctl("disable --now @timers");    # not: foreach my $timer (@timers) { systemctl(...) }
```

- **A multi-line script is uploaded, not typed as a here-doc or `echo` lines.** Run once: `script_output($script)` puts it in a file itself and stops at the first failing command -> references/testapi.md "Traps". A file that stays or runs again: `write_sut_file($path, $text)`, then `assert_script_run("bash -e $path")`; without `-e` only the last command counts -> references/distri-helpers.md "Files on the SUT". An upload is two or three round trips itself, so a short chain is cheaper; `write_sut_file` needs the SUT to reach the worker.
- **Public cloud**: one remote operation per ssh call, no `&&` chains -> references/area-conventions.md "Public cloud".
- Faster or not is measured -> "Measure and size". Where else the time goes (typing, fixed waits, waiting nodes) -> "Cost model".

## Measure and size

- **Before**: `scripts/oqa-log.py <job> --runtimes` prints the seconds per module and the slowest calls. Work on what that list shows, not on what looks slow in the code.
- **After**: the same scenario and arch on the same instance (-> references/clone-and-run.md "Where to run"), then `scripts/oqa-log.py <after> --runtimes --compare <before>`. Worker load varies: repeat both runs when the difference is small.
- **Cluster**: in a multimachine job compare every node, not only the parent.
- **Size**: seconds saved per run times the production jobs that run the module; verification clones do not count.
- **One idea per change**, verified before the next, so a regression is one revert.
- **Shared modules last and alone.** `console/system_prepare` and `console/consoletest_setup` run in hundreds of schedules and a support server gates its whole cluster: the largest saving and the widest breakage -> references/pr-review-rules.md "High-impact rare rules".
- **Coverage is not a cost to cut.** Dropping a check is a separate change with its own reason.
- **Do not memoise across modules** what a job can change: a migration job switches `VERSION` mid-run.

Sources: os-autoinst distribution.pm, testapi.pm, consoles/{video_base,serial_screen}.pm; os-autoinst-distri-opensuse lib/{utils,susedistribution,serial_terminal,package_utils,power_action_utils,opensusebasetest}.pm, lib/Utils/{Systemd,Logging}.pm, tests/migration/version_switch_upgrade_target.pm, schedule/
