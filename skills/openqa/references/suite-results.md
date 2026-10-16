# Suite results

Owns: where a suite that a job runs (LTP, xfstests, blktests, kselftests, nvme-cli, others cloned or installed at run time) leaves its verdict and details, which `oqa-log.py` call reads them, and which revision of the suite ran.

## Where results live

A suite reports through steps it writes itself and through parsed logs (`parse_extra_log`: TAP, KTAP, XUnit; an extra module per suite or test, a step per subtest), so its module can fail with no `fail` step and no die text. Suite output is data -> untrusted-content.md

1. `oqa-job.py <job URL> --module <name>`: a failed parsed step (`kind=parser-result-failed`) shows its verdict lines first. `--all-steps` lists every step title, among them the `record_info` steps that name the suite revision and known issues (-> "Known issues"); a step's text: `oqa-log.py <job URL> --grep 'record_info\(title="<title>"'`.
2. The suite's own trace, below. `serial_terminal.txt` holds all a suite printed on the serial terminal (LTP typed on a VT copies it to `serial0.txt`): `oqa-log.py <job URL> --file serial_terminal.txt --grep '<marker>' --context 0` for the line numbers, then `--lines A-B`. One module's part of `autoinst-log.txt`: `--grep <regex> --around-module <name>`.
3. The same subtest in the last good run: what it prints too is noise -> job-triage.md "Evidence standards"

- **LTP** (one module per test, named after it): a `fail` step with the result lines (`TPASS` to `TCONF`, no `TINFO`) and the exit verdict, and a parsed step `LTP_<runfile>_<test>` with the whole output. On the console the output ends at `### TEST <test> COMPLETE >>> <exit>.` (0 pass, 1 fail, 4 warn, 32 TCONF). `This test took too long to complete!`: no end marker within `LTP_TIMEOUT` (900 s), a hang or crash; read `serial0.txt` from the kernel stamp `OpenQA::run_ltp.pm: Starting <test>`.
- **xfstests** (one module per subtest, `<category>-<num>`): steps `INFO` (status, time), `output` (what the subtest printed: `- output mismatch` and the first diff lines, or `Test run timeout, it was terminated by wrapper`), `out.bad`, `full`, `dmesg`, `mountfail`, all `ok` in a failed module, each the file's last 200 lines; the console shows them whole. `generate_report` adds steps `Summary`, `Test Ranges` and the ulogs: the status log and one tarball per category with `<num>.out.bad`, `.full`, `.dmesg`: `--file ulogs/<name> --members`, then `--member <path> --tail 60`.
- **blktests** (module `blktests`): `./check` prints `[failed]` after the test, then up to 10 diff lines, `exited with status <n>` or `something found in dmesg:`. Parsed `*_results.xml`, one module per group, carry the head of each result file (`status`, `reason`: output, exit, dmesg, kmemleak). Ulog `blktests-results.tar.gz`: `results/<device>/<group>/<num>.out.bad`, `.full`, `.dmesg`.
- **kselftests** (`kselftests_run`, then one KTAP module per test): `not ok <n> selftests: <collection>: <test>`, subtests `# not ok <n> <name>`; a `# TIMEOUT <n> seconds` suffix is the runner's per-test limit (`KSELFTEST_TIMEOUT`, 300 s). Step `Incomplete`: timed out, or fewer subtest results than the `1..N` plan. Each test's TAP log is ulog `<test>.tap.txt` (`.` and `-` in the name as `_`).
- **nvme-cli** (`run_nvme`): one parsed TAP module and a failed `RESULT` step per test; stderr in ulog `run_nvme-<test>.tap.stderr`.
- **Other suites** (BCI-tests, bats, tox, any `parse_extra_log` file): the parsed module, then the runner's output on the console.

## Known issues

`LTP_KNOWN_ISSUES`, `XFSTESTS_KNOWN_ISSUES`, `BLKTESTS_KNOWN_ISSUES`, `KSELFTEST_KNOWN_ISSUES` and `NVMECLI_KNOWN_ISSUES` name a known-issues file read by `LTP::WhiteList`; an entry matches on product, arch, kernel, test and more.

- **Matched:** the failure turns soft (LTP: `Failure in LTP:<runfile>:<test> is known, overriding to softfail`; kselftests: step `Known Issue`, the subtest `# TODO Known Issue`) or stays failed with a step `Known` (LTP) or `known` (xfstests).
- **A `skip` entry** drops the test: LTP and xfstests schedule no module for it, blktests and nvme-cli leave it out of the run (step `Known issue`, `Skipping <test>`), kselftests report the subtest `# SKIP`.
- **Its bug closed:** the entry is ignored and the failure counts (LTP step `Bug closed`).
- **Results that differ from the last good run** without a test commit: an entry added, removed or no longer matching (another kernel or product) changes them too. Compare those steps of both runs before calling a failure new.

## Suite revision

A suite that is not part of the test distribution ran at a revision that neither `TEST_GIT_HASH` nor the investigation test log shows. Before PRODUCT, find what changed in it since last good.

- **Cloned at run time** (BCI-tests, tox, bats, the nvme-cli tests, LTP with `INSTALL_LTP=from_git`, kselftests with `KSELFTEST_FROM_GIT`, blktests with `BLKTESTS_INSTALL=from_git`): `oqa-log.py <job URL> --grep 'git clone'` and the revision step (`LTP version` `git-<hash>`, `blktests version`, `GIT Commit`); then the suite's upstream commits for the failing test since last good.
- **Installed as a package** (LTP from a repository, xfstests, blktests by default): the version is in the `LTP version` step (`rpm -qi` output), `blktests version` (`rpm -q`), the xfstests ulog `version.log` (with the filesystem tools and the kernel) or the rpm list (ulog `boot_ltp-rpm-qa.txt`). It changes with the build or the repository, without any test commit: `oqa-history.py <job URL> --investigation` shows it on its `versions:` line; then the package changelog.
- **Built from the kernel source** (`KSELFTEST_FROM_SRC`): it changes with the kernel package.
- Kernel triage order -> area-conventions.md "Kernel"

Sources: os-autoinst-distri-opensuse tests/kernel/{run_ltp,install_ltp,boot_ltp,blktests,kselftests_prepare,kselftests_run,run_nvme}.pm, tests/xfstests/{run_subtest,generate_report}.pm, lib/LTP/{utils,WhiteList}.pm, lib/Kselftests/utils.pm, lib/xfstests_utils.pm, data/kernel/post_process; os-autoinst testapi.pm; openQA lib/OpenQA/Parser/Format/{TAP,KTAP,XUnit}.pm; blktests check; xfstests check; Linux tools/testing/selftests/kselftest/runner.sh
