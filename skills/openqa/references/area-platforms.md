# Area platforms

Owns: per-area differences in os-autoinst-distri-opensuse for the platform areas (containers, public cloud, kernel, virtualization): base class, libraries, schedules, title, runs, asks, triage. `#N` = merged PR there that shows the ask. Finding the area -> area-conventions.md "Find the area"

## Containers
- **Base class**: `consoletest` for plain CLI; `containers::basetest` for `containers_factory` engines and its hooks; `select_user_serial_terminal` for rootless; no needles. Helpers: `containers::{k8s,common,bats,helm,utils}`.
- **Scheduling is Perl, not `schedule/*.yaml`** (only image creation and a few SL Micro flows use YAML): `lib/main_containers.pm` (driven by `CONTAINER_RUNTIMES`) or `lib/main_micro_alp.pm`; unschedule there rather than skip in the module (#26708). Opt-in flags: `CONTAINER[S]_*`, e.g. `loadtest 'containers/<x>' if get_var('CONTAINERS_<FLAG>');`
- **Asks**: the platform's own mechanism (readiness probe, `kubectl wait`) over outside scripting (#25409); no re-implemented distribution upgrade, a pre/post pair via `$run_args->{phase}` like `containers/upgrade` (#25058); soft-failure scoped to product, version, bug (#26342); no leading underscore on test-module subs (#25375); truthiness, not definedness, of optional settings (#25435).
- **Title**: plain, or `containers:` / `<module>:`. **Runs**: shared modules (`container_engine`, `host_configuration`) need runs across host products and runtimes.
- **Triage**: `bci_version_check` failing with `Stale build`, or its pull timing out: the moving totest tag already points to a newer build. A timing race, not PRODUCT: the job is obsolete, the newer build's run counts.

## Public cloud
- **Shape**: `publiccloud::basetest`; `my ($self, $args) = @_;`; `$args->{my_instance}`, `$args->{my_provider}` (set by `publiccloud/prepare_instance`); early-return guards before any console switch (#26179).
- **Remote work**: `$instance->ssh_assert_script_run`, `ssh_script_retry`, `upload_log`; packages only via `publiccloud::zypper` (`pc_zypper_call`, `pc_pkg_call`) (#25353); predicates `is_ec2 is_azure is_gce` in `publiccloud::utils`.
- **Scheduling is Perl**: `loadtest '..', run_args => $args` in every loader of `prepare_instance`: `load_{maintenance,latest}_publiccloud_tests`, `load_publiccloud_appimg_tests` (`lib/main_publiccloud.pm`), `load_slem_on_pc_tests` (`lib/main_micro_alp.pm`) (#26179). LTP jobs are YAML instead: `schedule/publiccloud/ltp_{latest,maintenance}.yaml` (`YAML_SCHEDULE`). Opt-in = new `PUBLIC_CLOUD_<X>` branch + `variables.md` row. Branches without an instance `return;` before `publiccloud/destroy`. Check the loader diff for deleted or commented-out `loadtest` (#26556).
- **Teardown** is `publiccloud/destroy` (`always_run`); modules never destroy the instance. Own resources: override `cleanup` (both hooks run it), non-asserting (#26642).
- **Asks**: one remote operation per ssh call, no `&&` chains; no unbounded loops - they cost money; every reboot justified (all #25535); provider-specific module guarded `if is_ec2()` (#26642); test logic in `tests/publiccloud/`, not `publiccloud::instance` methods (#26176); lib code works on transactional and classic systems (#26710).
- **Shared with SAP**: grep `schedule/sles4sap/` for lib users; add one SAP run (#25182).
- **Unit tests required**: `t/NN_publiccloud*.t`.
- **Triage**: a step often says only `fail`; the cause is in the uploads -> job-triage.md "Artifact map".
  - **img-proof**: its log ulog holds pytest's output, each failed test and why.
  - **Registration** (`registercloudguest`, `guestregister.service`; ulogs `*-cloudregister.log.txt`, `*-guestregister-journal.log.txt`): an error of the client or the image is PRODUCT; the cloud's update servers failing for other images and products at the same time is an outage, INFRA.
  - **Provisioning**: OpenTofu `Error:` in the `TFM apply output` step and the `tf_apply_output` ulog. A capacity shortage (`STOCKOUT`, `InsufficientInstanceCapacity`, `SkuNotAvailable`, `AllocationFailed`) is INFRA once the other zones (GCE, `ZONE UNAVAILABLE`) and `PUBLIC_CLOUD_ALTERNATE_REGIONS` (`REGION UNAVAILABLE`) failed too; any other error stops at once.
  - **SSH**: `nc` `timed out`, no answer: not booted or no route, see `destroy-console.txt`; `refused`: up, sshd not listening.
  - **SLE Micro** up to 5.4 has no cloud-init and no provider agent (`check_services`): a cloud-init expectation there is TEST.
  - **The image** under test is `PUBLIC_CLOUD_BUILD` (with `_KIWI`) or `PUBLIC_CLOUD_IMAGE_ID`/`_URI`, not `BUILD`: a change there is the product change, in the settings diff.

## Kernel
- **Prefix commit and title with the component, never Conventional Commits** (`docs/KERNEL_README.md`, #26595): lib package `Kernel::hba:`, `LTP:`, `Kselftests: BPF:`; test module base name `blktests:`; test family `kernel/nvme:`; only truly area-wide `kernel:`.
- **Commit body**: what and why (failure mode, alternatives ruled out); a bare ticket link is rejected. Atomic commits: removal / refactor / feature (#26015).
- **Shape**: `opensusebasetest`; `post_fail_hook` as in `tests/kernel/blktests.pm`: `select_serial_terminal; export_logs_basic;` (`Utils::Logging`). Known issues via `LTP::WhiteList` (`LTP_KNOWN_ISSUES`), not `record_soft_failure`.
- **Variables**: module POD after `1;` (`=head1 Configuration`, `=head2 <VAR>`) for `tests/kernel`; `variables.md` rows for xfstests.
- **Scheduling**: `schedule/kernel/`, `schedule/storage/`; LTP flows via `loadtest_kernel` (`LTP::utils`) in `lib/main_ltp.pm`. Prefer unconditional scheduling + runtime detection over a new variable or `FLAVOR`-keyed `conditional_schedule` (#24920).
- **Lib asks**: small utilities without asserts or test-specific file names (#25952); no fixed `/tmp` names shared by parallel instances (#25441).
- **Renames**: grep POD, `loadtest`, `products/*/main.pm`, other areas' tests; clone an affected production job with new settings (#25369).
- **Triage**, in this order (433 closed kernel QA investigations: test code 23%, the suite itself 16%, job settings or schedule 15%, product 13%):
  - **Suite**: LTP, xfstests and kselftests failures were often already fixed upstream (92 cases). Read the suite's upstream history for the failing test at the revision the job ran (-> suite-results.md "Suite revision") before a local fix or a kernel bug.
  - **Settings**: a split or migrated YAML schedule, temp or scratch devices, repo or asset URLs, a setting the job generator dropped. Diff `vars.json` against the last good job before the test code.
  - **Timeouts**, the most common symptom: compare the test's runtime with its timeout and with the kernel flavour (debug kernels run slower) before raising a limit. A kselftest `not ok ... # TIMEOUT <n> seconds` is the runner's per-test limit: check the test's runtime in the last good run and its declared subtest count against those reported before calling it a hang.
  - **Loop devices**: xfstests on loop devices backed by files in the root filesystem; ENOSPC or an abort of the root filesystem is a setup or space problem first, not a filesystem bug.
  - **Version gates**: a test that needs a newer kernel or a backport, selftests or kernel-devel built for another kernel than the running one, a package missing in the image, a read-only root on immutable products.
  - **Build errors**: a suite or kselftest compile error that appears with one kernel-source build and not its neighbours points to a backport missing in it; compare the same build step across those builds.
  - **One build, many tests**: a shared library, runner, parent job or package bump; check the common step before each test. A harness can report passed subtests as a failure or the reverse: read the raw subtest results -> suite-results.md "Where results live"
  - **Environment interference** (firewall rules, network modules or devices an earlier test left): propose runs that exclude one suspect at a time; each is a write.
  - **Intended change**: a kernel or package that drops or changes a feature on purpose (a config option turned off, an interface, default or behaviour dropped upstream, also through a stable update). Check the kernel config, its changelog or the package news before PRODUCT; the fix is often a suite or schedule change.
  - **Product** last, naming the last good and first bad kernel. The first stated theory was wrong in 35%; when build and tests both changed and the evidence leaves the class open, a crossed run decides -> job-history.md "History and investigation".
  - Known failures go to `LTP_KNOWN_ISSUES` with the bug link; a sporadic one is recorded with its rate and the builds it covers.

## Virtualization
- **Base class**: `virt_feature_test_base` (a `consoletest`) with `sub run_test` - its `run` wraps yours, checks guest health, writes the JUnit log when `VIRT_AUTOTEST` is set. Console: `select_backend_console` (`virt_autotest::utils`).
- **Scheduling**: `schedule/virt_autotest/*.yaml`; maintenance-update feature tests also go into `get_virt_features_definition` and the loaders of `lib/main_common.pm`, version guards in each (#25205).
- **Asks**: a generic crash detector is `record_info(.., result => 'fail')`, soft-failure is for one known bug; show the captured output, never made-up text (both #26316).
- **Runs**: simulated-failure path (#25205); maintenance-update and development product (#26316).
- **Triage**: host logs are uploads (`collect_virt_system_logs`, mostly from `post_fail_hook`): `*-libvirt_daemons.tar.gz`, `*-qemu.tar.gz` (per-guest qemu logs), `*-xen.tar.gz`, `*-journalctl-b.txt`; a core dump comes with `core.<binary>....txt` (`coredumpctl info`). `COREDUMPS found` from the hook can be the primary evidence: qemu crashed on the host.

Sources: os-autoinst-distri-opensuse docs/KERNEL_README.md, lib/main_containers.pm, lib/main_micro_alp.pm, lib/main_publiccloud.pm, lib/main_ltp.pm, lib/main_common.pm, lib/containers/basetest.pm, lib/publiccloud/{basetest,instance,utils,zypper}.pm, lib/LTP/{utils,WhiteList}.pm, lib/virt_feature_test_base.pm, lib/virt_autotest/utils.pm, tests/kernel/blktests.pm, tests/publiccloud/{img_proof,destroy}.pm, tests/containers/bci_version_check.pm; the merged pull requests cited as #N
