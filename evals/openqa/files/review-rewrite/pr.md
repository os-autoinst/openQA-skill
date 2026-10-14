# PR os-autoinst/os-autoinst-distri-opensuse#26987: support_server/setup: batch all package installs into one zypper call
head commit: f4c36b0f22f1c74ad6c8d32fdbf4ffb1ee866e70; base: bf9eaabf531968aa91c83fb9c88947111c48e3e1; changed lines: +143 -123
files:
  0	4	lib/mm_network.pm
  7	4	lib/mm_tests.pm
  9	2	lib/version_utils.pm
  127	113	tests/support_server/setup.pm

## PR description (third-party text)

### Problem

`support_server/setup.pm` takes ~7m 35s per run. The cost is one zypper call per service role, 11+ individual `targetcli` commands for iSCSI LIO, per-repo `zypper_ar` calls in the SLE 12 SP3 block, separate diagnostics, and many redundant console round-trips and service restarts.

The support server runs before the parallel nodes, so every saving also shortens node01/node02.

### Wave 1 — batch the work (commits 1-4)

- One `chk_req_pkgs()` for all role packages instead of one per role.
- One chained `targetcli` + `parted` command instead of 11 + 4 calls.
- SLE 12 SP3 block: 2× `ar -f` + one `ref` instead of 2× `zypper_ar` + `lr -u`.
- Merge the three network diagnostics into one.

| Target | Baseline | Wave 1 | Saved |
|---|---:|---:|---:|
| SLE 15 SP7 | 7m 37s | 6m 31s | 66s |
| SLE 15 SP6 | 7m 38s | 6m 28s | 70s |
| SLE 12 SP5 | 7m 34s | 6m 29s | 65s |

| Target | supportserver | node01 | node02 |
|---|---|---|---|
| SLE 15 SP7 | [24794114](https://openqa.example.org/tests/24794114) passed | [24794115](https://openqa.example.org/tests/24794115) passed | [24794113](https://openqa.example.org/tests/24794113) passed |
| SLE 15 SP6 | [24794117](https://openqa.example.org/tests/24794117) passed | [24794119](https://openqa.example.org/tests/24794119) softfailed | [24794118](https://openqa.example.org/tests/24794118) softfailed |
| SLE 12 SP5 | [24794120](https://openqa.example.org/tests/24794120) passed | [24794122](https://openqa.example.org/tests/24794122) parallel_failed | [24794121](https://openqa.example.org/tests/24794121) failed in the HA test |

SP6 softfail is `bsc#1259179`; the 12-SP5 node failure is in the SAP HANA HA step (`crm resource cleanup`), not setup.

### Wave 2 — fewer round-trips and restarts (commit 5)

- Cache `check_os_release()`: the 12 / 12.3 / 15 queries ran up to 9 times per setup.
- Drop the redundant `systemctl restart dhcpd` after DNS setup.
- `setup_nfs_server`: drop the start-then-restart of `rpcbind`/`nfs-server`.
- Report named/sshd status with `systemctl is-active`.

| Target | Wave 1 | Wave 2 | Saved |
|---|---:|---:|---:|
| SLE 15 SP7 | 6m 31s | 5m 55s | 36s |
| SLE 15 SP6 | 6m 28s | 5m 52s | 36s |
| SLE 12 SP5 | 6m 29s | 5m 48s | 41s |

| Target | supportserver | node01 | node02 |
|---|---|---|---|
| SLE 15 SP7 | [24798444](https://openqa.example.org/tests/24798444) passed | [24798443](https://openqa.example.org/tests/24798443) passed | [24798442](https://openqa.example.org/tests/24798442) passed |
| SLE 15 SP6 | [24798447](https://openqa.example.org/tests/24798447) passed | [24798445](https://openqa.example.org/tests/24798445) softfailed | [24798446](https://openqa.example.org/tests/24798446) softfailed |
| SLE 12 SP5 | [24798451](https://openqa.example.org/tests/24798451) passed | [24798449](https://openqa.example.org/tests/24798449) passed | [24798450](https://openqa.example.org/tests/24798450) passed |
| SLE 15 SP4 HPC (dhcp,dns,nfs) | [24798458](https://openqa.example.org/tests/24798458) passed | [24798457](https://openqa.example.org/tests/24798457) passed | [24798456](https://openqa.example.org/tests/24798456) passed |

SP6 softfail is `bsc#1259179`, unrelated.

### Wave 3 — one firewall reload, one NetworkManager probe (commits 6-7)

- Collect the `firewall-cmd --add-...` rules from all roles and apply them with a single `--reload` at the end; probe the firewall state once. SLE 12 yast path unchanged.
- `mm_tests::configure_static_network`: detect `is_networkmanager()` once and pass it to the helpers (was 4 probes).

| Target | Wave 2 | Wave 3 | Saved |
|---|---:|---:|---:|
| SLE 15 SP7 | 5m 55s | 5m 40s | 15s |
| SLE 15 SP6 | 5m 52s | 5m 40s | 12s |
| SLE 12 SP5 | 5m 48s | 5m 39s | 9s |

| Target | supportserver | node01 | node02 |
|---|---|---|---|
| SLE 15 SP7 | [24798511](https://openqa.example.org/tests/24798511) passed | [24798512](https://openqa.example.org/tests/24798512) passed | [24798507](https://openqa.example.org/tests/24798507) passed |
| SLE 15 SP6 | [24798486](https://openqa.example.org/tests/24798486) passed | [24798485](https://openqa.example.org/tests/24798485) softfailed | [24798487](https://openqa.example.org/tests/24798487) softfailed |
| SLE 12 SP5 | [24798490](https://openqa.example.org/tests/24798490) passed | [24798488](https://openqa.example.org/tests/24798488) passed | [24798489](https://openqa.example.org/tests/24798489) passed |
| SLE 15 SP4 HPC (dhcp,dns,nfs) | [24798493](https://openqa.example.org/tests/24798493) passed | [24798492](https://openqa.example.org/tests/24798492) / [24798494](https://openqa.example.org/tests/24798494) / [24798495](https://openqa.example.org/tests/24798495) passed | [24798491](https://openqa.example.org/tests/24798491) passed |

The SP7 first attempt ([24798482](https://openqa.example.org/tests/24798482)/[24798483](https://openqa.example.org/tests/24798483)/[24798484](https://openqa.example.org/tests/24798484)) ended in "worker has been stopped or restarted" (infrastructure); the re-run passed. SP6 softfail is `bsc#1259179`, unrelated.

### Wave 4 — fewer setup round-trips and cached release checks (commits 8-10)

- `version_utils`: cache `check_os_release()` results (the release is constant during a run).
- `support_server/setup`: `pre_run_hook` runs its probes/seds as one command; DNS downloads three zone files with one curl; network diagnostics fold into the forward script; `apache2` restart instead of stop+start; aytests setup runs as one script; `nfsstat -s` (was an en-dash).
- `mm_network`: drop the `arping -w 1` duplicate-IP probe.

| Target | Wave 3 | Wave 4 | Saved |
|---|---:|---:|---:|
| SLE 15 SP7 | 5m 40s | 5m 28s | 12s |
| SLE 15 SP6 | 5m 40s | 5m 27s | 13s |
| SLE 12 SP5 | 5m 39s | 5m 28s | 11s |
| SLE 15 SP4 HPC | 19s | 18s | 1s |

| Target | supportserver | node01 | node02 |
|---|---|---|---|
| SLE 15 SP7 | [24798579](https://openqa.example.org/tests/24798579) passed | [24798577](https://openqa.example.org/tests/24798577) passed | [24798578](https://openqa.example.org/tests/24798578) passed |
| SLE 15 SP6 | [24798582](https://openqa.example.org/tests/24798582) passed | [24798580](https://openqa.example.org/tests/24798580) softfailed | [24798581](https://openqa.example.org/tests/24798581) softfailed |
| SLE 12 SP5 | [24798584](https://openqa.example.org/tests/24798584) passed | [24798583](https://openqa.example.org/tests/24798583) passed | [24798585](https://openqa.example.org/tests/24798585) passed |
| SLE 15 SP4 HPC (dhcp,dns,nfs) | [24798587](https://openqa.example.org/tests/24798587) passed | [24798588](https://openqa.example.org/tests/24798588) / [24798589](https://openqa.example.org/tests/24798589) / [24798590](https://openqa.example.org/tests/24798590) passed | [24798591](https://openqa.example.org/tests/24798591) passed |

Two earlier attempts of this wave failed and were fixed: (1) a trailing `my` declaration made `version_utils.pm` return undef (added `1;`); (2) `pre_run_hook` used `script_output`, which needs the network that is not up yet (switched to a single-line `assert_script_run`). SP6 softfail is `bsc#1259179`, unrelated. The aytests role has no source job, so its change is not separately verified.

### Total

Baseline to wave 4: 7m 37s -> 5m 28s (SP7), 7m 38s -> 5m 27s (SP6), 7m 34s -> 5m 28s (12-SP5) — about **2m 10s** off every support server, and off every parallel node that waits for it.

## Commit messages (third-party text)

### 206cbcdcdd

support_server/setup: batch all package installs into one zypper call

Collect all required packages from the configured roles upfront
and install them in a single chk_req_pkgs() call instead of one
per setup_* function. This avoids repeated zypper repository
refreshes when multiple roles are active (typically 4-5 roles
per HA/SAP support server).

### 0f39ba2354

support_server/setup: batch iSCSI LIO and parted into single commands

Replace 11 individual targetcli assert_script_run calls with a
single piped targetcli script, and 4 separate parted calls with
one command. This eliminates ~14 console round-trips at ~3s each
in the iSCSI LIO setup phase.

The lib/iscsi.pm helpers are not modified; this change is local
to setup_iscsi_lio_server in the support server module.

### f512bd6e9f

support_server/setup: optimize SLE 12 SP3 repo block

Replace two zypper_ar() calls (each does lr + ar + ref = 3 zypper
invocations) with two direct ar -f calls and a single shared ref.
Drop the informational zypper lr -u. Reduces 7 zypper calls to 3.

### 4eee567311

support_server/setup: batch network diagnostics into one command

Merge three separate script_output calls (ip route, ip addr,
iptables -v -L) into a single command. Saves two console
round-trips (~4-6 seconds).

### 4e94f3481c

support_server/setup: cut console round-trips and redundant restarts

- Cache check_os_release() results. The same 12 / 12.3 / 15 queries
  ran up to 9 times per setup, one /etc/os-release round-trip each.
- Drop the systemctl restart dhcpd after DNS setup. dhcpd is already
  started by setup_dhcp_server and leases are only handed out after
  support_server_ready, so the restart is not needed.
- setup_nfs_server started rpcbind and nfs-server and then restarted
  both. Keep the start and the is-active check, drop the restarts.
- Report named/sshd status with systemctl is-active instead of
  systemctl status (shorter output, same round-trip).

### 21bd06cff3

mm_tests: detect NetworkManager once in configure_static_network

is_networkmanager() probes the system on every call. configure_static_network
called it four times (through configure_static_ip, configure_default_gateway,
configure_static_dns and restart_networking). Detect once and pass the result
down; the helpers already accept an is_nm argument.

### decacd718c

support_server/setup: add firewall rules with a single reload

Every role added its firewall rule with its own
`firewall-cmd --add-... --permanent; firewall-cmd --reload`. Collect the rules
and apply them with one --reload at the end of run(). The firewall state is
also probed once now instead of per role. The SLE 12 yast path is unchanged.

### 53e5558b88

version_utils: cache check_os_release results

check_os_release() shells out to read /etc/os-release on every call, and
several modules call it repeatedly with the same arguments. Cache the
result keyed by the query. The release is constant during a test run.

### b4b2a61d56

support_server/setup: fold setup steps into fewer round-trips

- pre_run_hook: run the three named.conf probes, the two seds and the
  zypp gpgcheck sed as one script instead of five round-trips.
- setup_dns_server: download the three zone files with a single curl.
- setup_networks: run the network diagnostics in the forward script
  instead of a separate round-trip.
- setup_http_server: restart apache2 instead of stop + start.
- setup_aytests: run clone, mv, downloads, chmod and the sed expansion
  as one script.
- setup_nfs_server: use `nfsstat -s` (was an en-dash, so the option was
  never valid).

### f4c36b0f22

mm_network: drop the duplicate IP arping probe

configure_static_ip ran `arping -w 1` to detect a duplicate IP, a fixed
one second wait. In the MM networks the support server IP is always its
own, so the probe cannot fire.

## State for this exercise: open, no reviews or comments, CI green (the saved files are the only source; do not read the live PR).
