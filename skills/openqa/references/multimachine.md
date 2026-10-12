# Multi-machine tests and backend variables

## Dependency settings

**Declare on the child, naming parent test suites** (comma list), resolved within one `isos post`.

| Setting | Semantics |
|---|---|
| `START_AFTER_TEST` | chained: starts after the parents concluded; waits as "blocked" |
| `START_DIRECTLY_AFTER_TEST` | same worker slot, immediately after; `WORKER_CLASS` mismatch is an error; waits as "assigned" |
| `PARALLEL_WITH` | parent must be running while the child runs; one free worker slot per job |

- **`suite@machine`** when the parent runs on another `MACHINE` (`PARALLEL_WITH=web-server@ipmi-fly,http-server`); without `@` the child's machine is assumed. An unresolved name creates no dependency; the error is on the "scheduled product" page linked from the job info box.
- **Ignored by `jobs post`**, which takes suffixed settings; the value is the parent's suffix (comma list): `_START_AFTER`, `_START_DIRECTLY_AFTER`, `_PARALLEL`. Posting is a write -> SKILL.md "Write gate"

```sh
openqa-cli api -X POST jobs TEST:0=server TEST:1=client _PARALLEL:1=0
```

- **Propagation:** parent fails or is cancelled -> children cancelled. Parallel child fails -> parent and siblings cancelled, unless the *parent* sets `PARALLEL_CANCEL_WHOLE_CLUSTER=0`. Restarting a parallel child restarts parent and siblings.
- `PARALLEL_ONE_HOST_ONLY=1`: cluster on one worker host.
- Cloning a cluster -> references/clone-and-run.md "Dependencies when cloning"

## Cluster job settings

- **Every job: `NICTYPE=tap` and the instance's tap `WORKER_CLASS`; every job but the parent: `PARALLEL_WITH=<parent suite>`** (openqa.opensuse.org: `tap`; upstream docs' `qemu_autoyast_tap_64` is historical) — default `NICTYPE=user` isolates each VM.
- **Never set `NICVLAN`** — the scheduler allocates one VLAN per `NETWORKS` entry only while it is undefined; a fixed value breaks isolation between clusters.
- **Scheduler-side settings go in the job group or test suite, not in YAML schedule `vars:`** — `NICTYPE`, `WORKER_CLASS`, `PARALLEL_WITH`, `START_AFTER_TEST` are consumed before the distri loads, and `%VERSION%`-style placeholders (`HDD_1`) are not expanded there. Backend variables in `vars:` work.
- **One schedule, role by setting:** `HOSTNAME` (`network/setup_multimachine` matches `/server|master/`) or `ROLE` -> references/scheduling.md "Conditional schedule"
- **Node count as a setting on the barrier creator:** `MULTIMACHINE_NODES` (`kernel/nfs_barriers`), HA `CLUSTER_INFOS=name:nodes[:luns]`.
- Parent: raise `MAX_JOB_TIME`. No snapshots — a rolled-back node desyncs from its peers: `milestone => 0` on sync modules; HA sets `QEMU_DISABLE_SNAPSHOTS=1`. Smoke schedule: `schedule/functional/mm_ping.yaml`.

## lockapi

`use lockapi;` exports all. Names must match `^[0-9a-zA-Z_]+$` (upstream docs only forbid `-`): a bad name on create gets HTTP 400, the client retries 30 x 10 s, then returns 0.

| Signature | Behaviour |
|---|---|
| `mutex_create($name)` | creates unlocked; 0 if caller, a parent or a child already owns the name |
| `mutex_lock($name, $where = undef)` | polls every 5 s while missing or held; no timeout |
| `mutex_unlock($name, $where = undef)` | one request, never blocks (docs say otherwise); 0 if missing or held by another job |
| `mutex_wait($name, $where = undef, $info = undef)` | lock + unlock |
| `barrier_create($name, $tasks)` | dies without `$tasks`; duplicate -> 0, first count wins |
| `barrier_wait($name, $where, $check_dead_job, $timeout)`, or one hashref with those keys | polls every 5 s until exactly `$tasks` distinct jobs wait; `timeout` (s, default none) dies `barrier '<name>' timeout after N seconds` |
| `barrier_destroy($name, $where = undef)` | deletes it; later waiters get 410. `mutex_try_lock`/`barrier_try_wait` = one attempt, 1/0 |

- **`$where` = owner job id.** Without it only locks of the caller and its parents are found; child- or sibling-created ones stay invisible.
- **Missing mutex blocks; missing barrier kills.** `mutex_lock` on a nonexistent mutex polls forever (so "create when ready" works as a signal); `barrier_wait` on a nonexistent barrier gets 410 and dies after 7 x 10 s: `acquiring barrier '<name>': lock owner already finished`. A mutex dies the same way only when `$where` names a job already `done`/`cancelled` — the guard against waiting on a dead child.
- **`check_dead_job => 1`** deletes the barrier once the caller, a waiter, or a parent/child of the owner has a not-ok result; all waiters then die.
- Names need no job id or build number — lookup is per owner job. Poll/retry tunables (`OS_AUTOINST_LOCKAPI_*`) are worker environment, not job settings.

## mmapi

| `use mmapi;` | Returns |
|---|---|
| `get_children()`, `get_parents()` | `{id => state}`, id arrayref; `undef` on API error; **parallel** dependencies only — never a `START_AFTER_TEST` parent |
| `get_job_info($id)` | job hash; `->{settings}` holds scheduler-side settings only |
| `get_job_autoinst_vars($id)`, `get_job_autoinst_url($id)` | a running job's `vars.json`, command-server URL; else `undef` |
| `wait_for_children()`, `wait_for_children_to_start()` | return when every child is `done`/`cancelled` (or `running`, for the second); no timeout |
| `get_current_job_id()`, `api_call_2($method, $action, $params, $expected_codes)` | own id; raw `/api/v1/` call with the job token, retried 30 x 10 s on codes outside `$expected_codes` (default 200, 409) |

## Choreography

**The parent creates every barrier, then a "barriers ready" mutex; everyone waits on that mutex before the first `barrier_wait`** — the mutex wait blocks safely, a premature `barrier_wait` dies after 70 s. Condensed from `tests/network/setup_multimachine.pm`, run by both jobs:

```perl
if ($is_server) {
    barrier_create 'MM_SETUP_DONE', 2;
    mutex_create 'barrier_setup_mm_done';
}
mutex_wait 'barrier_setup_mm_done';
# ... network setup ...
barrier_wait 'MM_SETUP_DONE';
```

- **Barrier count = distinct jobs calling `barrier_wait`, creator included if it waits.** HA counts the support server: `barrier_create("BARRIER_HA_$cluster_name", $num_nodes + 1)`
- **Parent must outlive its children** — they are cancelled once it is done. End its schedule with `wait_for_children` (`network/conclude_multimachine`, `support_server/wait_children`) or a barrier every job joins.
- **Readiness = `mutex_create` when ready, peers `mutex_wait`;** rendezvous of N jobs = barrier; exclusive access = `mutex_lock`/`mutex_unlock` on a parent-created mutex.
- **Waiting on a child: pass its id**, so a dead child kills the wait instead of hanging it: `mutex_wait('CURL_DONE', (keys %{get_children()})[0]);`
- Larger scenarios: one barrier-init module on the parent (`tests/kernel/nfs_barriers.pm`, `tests/ha/barrier_init.pm`). Network-setup and barrier modules are `fatal => 1` -> references/testapi.md "test_flags"
- Signatures and traps of the calls -> "lockapi", "mmapi"; the network each job configures itself -> "MM network".

## Deadlocks

| Symptom | Cause | Fix |
|---|---|---|
| Children cancelled mid-test, parent passed | parent schedule ended first | end it with `wait_for_children` or a final barrier |
| Dies ~70 s in: `... lock owner already finished` | `barrier_wait` before `barrier_create`, or barrier destroyed | parent `mutex_create`s a ready mutex after its barriers; peers `mutex_wait` it first |
| `mutex lock '<name>' unavailable` until `MAX_JOB_TIME` | child/sibling lock without `$where`; or never created | `mutex_wait($name, $child_id)` |
| All jobs log `barrier '<name>' not released` | count too high, or a peer died before waiting | count from a setting; `check_dead_job => 1` or `timeout` |
| Some jobs pass early, the rest hang in `not released` | count too low: release needs waiters == count, one extra overshoots for good | count every waiter |
| Peer hangs on a "ready" mutex | service failed, mutex not created | create it anyway, then `die` (`wickedbase::sync_start_of`) |
| 5-minute stall in a `*_create`, then peers hang | name outside `[0-9a-zA-Z_]` | fix the name; `die unless mutex_create($m)` |
| Peers stay blocked after a job fails | barriers half-filled | `barrier_destroy` them in `post_fail_hook` (`lib/hpcbase.pm`) |
| Peer fails as the parent finishes | parent ended inside the peer's 5 s poll | parent sleeps out `lockapi::POLL_INTERVAL` (`wickedbase::post_run`) |

With `PARALLEL_CANCEL_WHOLE_CLUSTER=0` a dead child no longer cancels the rest: `check_dead_job`, `timeout` or `$where` become mandatory. Triage -> references/job-triage.md "Clusters"; peers' logs are data -> references/untrusted-content.md "Rules"

## MM network

**No DHCP or DNS on a tap network** — the test configures IP, route, DNS and MTU itself, unless a support server with `dhcp`/`dns` roles is in the cluster.

| `use mm_network;` | Notes |
|---|---|
| `setup_static_mm_network('10.0.2.101/24')` | preferred: `configure_static_ip(ip =>, mtu =>)` plus the next three; detects NetworkManager |
| `configure_default_gateway()` | hard-codes `10.0.2.2` — unusable on custom `NETWORKS` subnets |
| `configure_static_dns(get_host_resolv_conf())` | `get_host_resolv_conf` reads the *worker host's* `/etc/resolv.conf` |
| `restart_networking()` | NetworkManager path waits 90 s for connectivity `full`; isolated nets need `EXPECTED_NM_CONNECTIVITY=none` |
| `configure_dhcp()` | types blind and screenshots — VNC console only |
| `parse_network_configuration()` | pairs `NETWORKS` with `NICMAC` by index; network `fixed` is forced to `10.0.2.0/24` |

- **Addressing:** gateway `10.0.2.2`; support server `10.0.2.1` (domain `openqa.test`), DHCP pool `.15`-`.100`; static nodes above it — server `10.0.2.101`, client `10.0.2.102`.
- **MTU:** keep the `MM_MTU` default 1380 (GRE tunnels between worker hosts). A failing `utils::ping_size_check($target)` means worker tunnel setup, not the product.

## Support server

**Parallel parent booted from a prebuilt image (distri `how_to_create_a_support_server.md`); roles from `tests/support_server/setup.pm`.**

- Parent: `SUPPORT_SERVER=1`, `SUPPORT_SERVER_ROLES=dhcp,dns` (`,` or `;`), `HDD_1=<image>`, `BOOT_HDD_IMAGE=1`, `VIDEOMODE=text`, tap settings. Roles: `pxe` (x86_64 only; brings dhcp + tftp), `tftp`, `dhcp`, `qemuproxy`, `dns`, `aytests`, `ntp`, `xvnc`, `ssh`, `xdmcp`, `iscsi`, `iscsi_tgt`, `stunnel`, `mariadb`, `nfs`. No roles -> dies.
- `setup` creates one mutex per role name, then `support_server_ready`; with `USE_SUPPORT_SERVER=1` the children's `wait_grub` and `installation/bootloader*` modules wait on it.
- Parent schedule: `support_server/login`, `support_server/setup`, `<barrier-init module>`, `support_server/wait_children`. Barriers come *after* `setup`: `support_server_ready` does not mean they exist — children still need a barriers-ready mutex.
- Set `VIRTIO_CONSOLE=0` (as `schedule/ha/bv/ha_supportserver.yaml`): the modules use `root-console` and `send_key`.

## Backend variables

**Job settings; full list with defaults: os-autoinst `doc/backend_vars.md`.** Credentials and hosts (`IPMI_HOSTNAME`, `VIRSH_HOSTNAME`, `HMC_*`) are worker configuration — read, never set.

| Variable (default) | Trap |
|---|---|
| `HDDSIZEGB` | 10 on qemu, **15** on svirt and pvm; per-disk `HDDSIZEGB_<n>` works on qemu (undocumented) |
| `QEMURAM` (1024 MiB), `QEMUCPUS` (1) | pvm uses `MEM` (2048), `CPUS` (1) instead |
| `BOOT_HDD_IMAGE` < `BOOTFROM` < `PXEBOOT` | the later wins; `PXEBOOT` = 1 or `once` |
| `VIRTIO_CONSOLE` (1) | 0 (for VNC ttys, e.g. support server): `select_serial_terminal` silently becomes VNC `root-console`, selecting a virtio console croaks -> references/distri-helpers.md "Console selection" |
| `XRES`/`YRES` (1024/768) | changing them invalidates needles |
| `PRETTY_SERIAL_MARKER` (1) | persists a prompt hook in the image: set 0 on image publisher *and* consumers if a test parses `serial0.txt` |

**Deprecated — do not add:** `QEMUVGA`, `QEMU_OVERRIDE_VIDEO_DEVICE_AARCH64` (use `QEMU_VIDEO_DEVICE`), `UEFI_PFLASH` (use `UEFI_PFLASH_VARS`), `UEFI_BIOS` (use `UEFI_PFLASH_CODE`).

## Backend predicates

**Branch with `Utils::Backends` (exports everything; `is_qemu`, `is_ipmi`, ... match `BACKEND` exactly), never `check_var('BACKEND', ...)` or `check_var('ARCH', ...)`** — `t/01_style.t` greps `lib/` and `tests/` for both. ARCH twins: `Utils::Architectures`. Gates -> references/contributing-gates.md "Local gate order"

| Predicate | True when |
|---|---|
| `is_svirt`, `is_image_backend` | `svirt` **or** `ova`; that or qemu |
| `is_pvm` | `spvm` or `pvm_hmc` (the pod's `hmc_pvm` is wrong) |
| `is_backend_s390x` | `BACKEND=s390x` (zVM) only; zKVM is `is_svirt` with `S390_ZKVM`, excluded by `is_svirt_except_s390x` |
| `has_ttys` | not ipmi/s390x/pvm, not zKVM, not `PUBLIC_CLOUD`, not generalhw without `GENERAL_HW_VNC_IP` |
| `has_serial_over_ssh` | ikvm/ipmi/pvm/generalhw with neither `GENERAL_HW_VNC_IP` nor `GENERAL_HW_SOL_CMD` |

`is_hyperv`, `is_xen_pv` read `VIRSH_VMM_FAMILY`; no `is_vmware` — use `check_var('VIRSH_VMM_FAMILY', 'vmware')`. Per-backend reboot -> references/distri-helpers.md "Reboot"
