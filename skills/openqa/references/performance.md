# Performance

Owns: why an os-autoinst-distri-opensuse module is slow and how to size a fix. The mechanics have their own owners: console choice -> references/distri-helpers.md "Console selection"; waits and retries -> references/distri-helpers.md "Retry and poll"; generated files -> references/distri-helpers.md "Test data"; node waits -> references/multimachine.md "Choreography".

Runtime is paid once per job per architecture, so a saving is paid back on every run. Spend the effort where the module runs most, not where it looks worst.

## Cost model

| Cost | Order | Why |
|---|---|---|
| one testapi call | ~0.3 s | type the command, run it, wait for the exit marker: a round trip |
| a long command | ~1 s per 25 characters | the serial terminal types character by character |
| a VGA console start | tens of seconds | wait for the VGA, log in, set up the prompt, install serial markers |
| `sleep N` | N s | guessed, and paid on every run and architecture |
| a service restart | seconds | a daemon start/stop, not a function call |

- **Round trips add up.** Independent commands belong in one call; long commands belong in a file (see "Batch and upload").
- **The console is the next cost.** `select_serial_terminal` instead of `select_console 'root-console'` -> references/distri-helpers.md "Console selection".
- **A sleep is a fixed cost** even when its condition is already true; poll for the condition -> references/distri-helpers.md "Retry and poll", references/module-templates.md "Anti-patterns".
- **In a multimachine cluster the parent's saving is the cluster's saving.** The nodes wait on the parent's mutex or barrier, so a second off the parent is also a second off every waiting node -> references/multimachine.md "Choreography".

## Batch and upload

Independent commands belong in one round trip.

```perl
# before: three round trips
script_run "ip netns add ns0";
script_run "ip netns add ns1";
script_run "ip link set veth0 netns ns0";
# after: one
script_run "ip netns add ns0; ip netns add ns1; ip link set veth0 netns ns0";
```

A loop that calls the test API once per item is the same mistake:

```perl
# before
foreach my $timer (@timers) { systemctl("disable --now '$timer'"); }
# after
systemctl("disable --now @timers");
```

Generated content goes in with `write_sut_file` and runs with a short command, because a here-doc or a long `echo` is typed on the serial console -> references/distri-helpers.md "Test data":

```perl
write_sut_file('/tmp/setup.sh', "set -ex\n" . join("\n", @cmds) . "\n");
assert_script_run('bash /tmp/setup.sh', timeout => 120);
```

`set -e` makes the uploaded script stop on its first failure.

## Measure and size

- Per-module seconds and the slowest calls: `oqa-log.py JOB --runtimes` -> references/job-triage.md "Triage order".
- A saving is a claim: measure the module on the same product and architecture before and after -> references/clone-and-run.md "Where to run".
- In a multimachine job, measure the whole cluster, not only the parent.
- To size the yearly win, count how often the scenario runs and multiply. Count production jobs, not your own verification clones.

## Change one thing

One idea per change, verified before the next, so a regression is a single revert. Rank by saving and by risk, and leave the shared early modules (`system_prepare`, `consoletest_setup`, a multimachine support server) for last: they run in thousands of jobs.

## Pitfalls

- **Verify the effect, not the exit code.** A command can exit 0 and still do nothing; assert the result you need.
- **Do not cache outside the module.** State that can change mid-run (the os release, the network manager) is not safe to memoise globally.
- **Do not trade coverage for time.** A module that checks less is weaker, not faster; dropping a check is a separate change.

## Sources

os-autoinst-distri-opensuse `lib/utils.pm` (`write_sut_file`), `lib/serial_terminal.pm` (`select_serial_terminal`), `lib/opensusebasetest.pm`, `lib/consoletest.pm`; os-autoinst `distribution.pm` (`script_output` here-doc), `testapi.pm` (`type_string` `max_interval`); openQA docs/WritingTests.md
