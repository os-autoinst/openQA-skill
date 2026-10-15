# PR os-autoinst/os-autoinst-distri-opensuse#27002: console/system_prepare: stop packagekit once instead of twice
head commit: f197fdd5e2601e3ca4004e0af37cd252a464bb55; base: 5e213890772f31926194743fec422962700e7470; changed lines: +4 -2
files:
  4	2	tests/console/system_prepare.pm

## PR description (third-party text)

`tests/console/system_prepare.pm` stops packagekit twice on desktop systems:
once before the `SUSEConnect` calls, and again at the end of the module.

`quit_packagekit()` masks and stops packagekit:

    script_run("systemctl mask packagekit; systemctl stop packagekit; while pgrep packagekitd; do sleep 1; done", timeout => 60);

The mask is persistent, so after the early call nothing in the module can start
packagekit again: the module only runs `SUSEConnect` and `zypper`, neither of
which starts packagekitd. The trailing call therefore repeats the same masking
and stopping work for desktop systems.

Keep the trailing call only for textmode, where the early call is skipped, so
packagekit is still stopped exactly once in every case.

## Risk

The early call runs only when `DESKTOP` is not `textmode`; the trailing call now
runs only when `DESKTOP` is `textmode`. The two guards are exact complements, so
every system that stopped packagekit before still stops it, and no system stops
it twice. On desktop, `quit_packagekit` already masked packagekit, which is what
the trailing call was there to ensure for the modules that follow.

## Verification

Verification runs use `CASEDIR=jdoe#pr-system-prepare-quit-packagekit`,
`_GROUP_ID=0`. The time is the `system_prepare` execution time in the source job
and in the verification run; `Saved` is source minus verification. The average
covers the runs where both jobs finished; the remaining rows are still running.
Rows marked `*` had `system_prepare` pass but the job failed later in an
unrelated module.

| Target | Test | Source | Verification | Saved |
|--------|------|--------|--------------|------:|
| Tumbleweed x86_64 uefi qemu (desktop) | `RAID0_gpt_uefi` | [6267551](https://openqa.opensuse.org/tests/6267551) 2s | [6268250](https://openqa.opensuse.org/tests/6268250) 1s | 1s |
| Tumbleweed aarch64 qemu (desktop) | `create_hdd_gnome` | [6268194](https://openqa.opensuse.org/tests/6268194) 24s | [6268292](https://openqa.opensuse.org/tests/6268292) 6s | 18s |
| Tumbleweed ppc64le qemu (OFW) KDE | `extra_tests_on_kde` | [6266644](https://openqa.opensuse.org/tests/6266644) 98s | [6268253](https://openqa.opensuse.org/tests/6268253) 93s | 5s |
| Tumbleweed x86_64 qemu textmode | `textmode` | [6265829](https://openqa.opensuse.org/tests/6265829) 2s | [6268466](https://openqa.opensuse.org/tests/6268466) 1s | 1s |
| Tumbleweed x86_64 uefi qemu (desktop) | `gnome+apparmor` | [6265790](https://openqa.opensuse.org/tests/6265790) - | [6268467](https://openqa.opensuse.org/tests/6268467) - | - |
| Tumbleweed x86_64 USBboot_64 qemu (desktop) | `kde` | [6267067](https://openqa.opensuse.org/tests/6267067) - | [6268468](https://openqa.opensuse.org/tests/6268468) - | - |
| Tumbleweed x86_64 virtio qemu (JeOS) | `jeos-combustion` | [6266304](https://openqa.opensuse.org/tests/6266304) 0s | [6268469](https://openqa.opensuse.org/tests/6268469) 1s | -1s |
| Tumbleweed x86_64 Laptop_64 qemu (desktop) | `gnome` | [6265852](https://openqa.opensuse.org/tests/6265852) 34s | [6268470](https://openqa.opensuse.org/tests/6268470) 42s | -8s |
| Tumbleweed x86_64 uefi-usb-4G qemu (GNOME-Live) | `gnome-live` | [6266340](https://openqa.opensuse.org/tests/6266340) 32s | [6268471](https://openqa.opensuse.org/tests/6268471) 41s | -9s |
| Tumbleweed x86_64 qemu (Rescue-CD) | `rescue` | [6266336](https://openqa.opensuse.org/tests/6266336) 1s | [6268472](https://openqa.opensuse.org/tests/6268472) 1s | 0s |
| Tumbleweed x86_64 uefi qemu | `create_hdd_textmode_uefi` | [6265823](https://openqa.opensuse.org/tests/6265823) 3s | [6268473](https://openqa.opensuse.org/tests/6268473) 2s | 1s |
| Tumbleweed aarch64 qemu (desktop) | `upgrade_Leap_15.1_gnome` | [6267606](https://openqa.opensuse.org/tests/6267606) 9s | [6268474](https://openqa.opensuse.org/tests/6268474) 8s | 1s |
| Tumbleweed aarch64 RPi4 generalhw | `jeos-ltp-containers` | [6267923](https://openqa.opensuse.org/tests/6267923) - | [6268475](https://openqa.opensuse.org/tests/6268475) - | - |
| Tumbleweed aarch64 qemu (JeOS sdboot) | `jeos` | [6267992](https://openqa.opensuse.org/tests/6267992) 1s | [6268476](https://openqa.opensuse.org/tests/6268476) 0s | 1s |
| Tumbleweed ppc64le qemu (OFW) | `minimalx` | [6266568](https://openqa.opensuse.org/tests/6266568) 99s | [6268477](https://openqa.opensuse.org/tests/6268477) 91s | 8s |
| Tumbleweed i586 qemu (desktop) | `gnome` | [6265744](https://openqa.opensuse.org/tests/6265744) 35s | [6268478](https://openqa.opensuse.org/tests/6268478) 36s | -1s |
| SLE 16.0 x86_64 qemu (desktop gnome) | `create_hdd_gnome` | [24617376](https://openqa.example.org/tests/24617376) 2s | [24809573](https://openqa.example.org/tests/24809573) 1s | 1s |
| SLE 16.0 aarch64 qemu (desktop gnome) | `create_hdd_gnome` | [24617055](https://openqa.example.org/tests/24617055) 2s | [24809582](https://openqa.example.org/tests/24809582) 1s | 1s |
| SLE 16.0 s390x svirt | `create_hdd_textmode` | [24617051](https://openqa.example.org/tests/24617051) 2s | [24809592](https://openqa.example.org/tests/24809592) 2s | 0s |
| SLE 16.0 ppc64le qemu | `create_hdd_textmode` | [24805588](https://openqa.example.org/tests/24805588) 97s | [24809585](https://openqa.example.org/tests/24809585) 97s | 0s |
| SLE 12-SP5 x86_64 qemu | `qam-minimal` | [24667616](https://openqa.example.org/tests/24667616) 15s | [24809586](https://openqa.example.org/tests/24809586) 15s | 0s |
| SLE 16.0 x86_64 qemu | `create_hdd_textmode` | [24791808](https://openqa.example.org/tests/24791808) 2s | [24815721](https://openqa.example.org/tests/24815721) 2s | 0s |
| SLE 15-SP4 x86_64 qemu | `qam-minimal` | [24790982](https://openqa.example.org/tests/24790982) 1s | [24815722](https://openqa.example.org/tests/24815722) 1s | 0s |
| SLE 12-SP5 aarch64 qemu | `supp_sles12sp5_unregistered` | [24795173](https://openqa.example.org/tests/24795173) 1s | [24815723](https://openqa.example.org/tests/24815723) 1s | 0s |
| SLE 15-SP4 s390x zVM | `qam-minimal-full` | [24791797](https://openqa.example.org/tests/24791797) 1s | [24815724](https://openqa.example.org/tests/24815724) 2s | -1s |
| SLE 15-SP4 ppc64le qemu | `qam-minimal-full` | [24791017](https://openqa.example.org/tests/24791017) 80s | [24815725](https://openqa.example.org/tests/24815725) 78s | 2s |
| SLE 15-SP5 x86_64 ipmi | `qam-gfxdrivers` | [24808940](https://openqa.example.org/tests/24808940) 112s | [24815726](https://openqa.example.org/tests/24815726) 111s | 1s |
| SLE 15-SP6 s390x svirt * | `create_hdd_textmode_cc_dev` | [24795437](https://openqa.example.org/tests/24795437) 3s | [24815727](https://openqa.example.org/tests/24815727) - | - |
| SLE 15-SP6 x86_64 uefi | `create_hdd_textmode_cc` | [24795774](https://openqa.example.org/tests/24795774) 4s | [24815728](https://openqa.example.org/tests/24815728) 4s | 0s |
| SLE 15-SP7 x86_64 ipmi | `qam-gfxdrivers` | [24797571](https://openqa.example.org/tests/24797571) 113s | [24815729](https://openqa.example.org/tests/24815729) 122s | -9s |
| SLE 16.0 x86_64 uefi (Security) | `agama_create_hdd_textmode_qesec` | [24793522](https://openqa.example.org/tests/24793522) 1s | [24815730](https://openqa.example.org/tests/24815730) 1s | 0s |
| SLE 16.1 x86_64 qemu (Immutable) | `agama_create_hdd_immutable_textmode_qesec` | [24807259](https://openqa.example.org/tests/24807259) 0s | [24815731](https://openqa.example.org/tests/24815731) 0s | 0s |
| SLE 16.0 x86_64 qemu (HA) | `create_hdd_ha_textmode` | [24792722](https://openqa.example.org/tests/24792722) 2s | [24815732](https://openqa.example.org/tests/24815732) 2s | 0s |
| SLE 15-SP7 x86_64 qemu (SAP) | `qam-create_hdd_sles4sap_gnome` | [24792145](https://openqa.example.org/tests/24792145) 1s | [24815733](https://openqa.example.org/tests/24815733) 1s | 0s |
| SLE 12-SP5 s390x svirt | `mru-install-minimal-with-addons` | [24795121](https://openqa.example.org/tests/24795121) 6s | [24815734](https://openqa.example.org/tests/24815734) 4s | 2s |
| SLE 15-SP7 x86_64 qemu | `mru-install-minimal-with-addons` | [24792323](https://openqa.example.org/tests/24792323) 1s | [24815735](https://openqa.example.org/tests/24815735) 1s | 0s |
| **average (30 paired runs, ppc64le/OFW excluded)** | | **19s** | **19s** | **0s** |


The module time is dominated by unrelated work (`SUSEConnect` registration and
`wait_quit_zypper`), so the `Saved` column is mostly run-to-run noise; the
average difference across the table is about 0s. What this PR actually removes
is the trailing `quit_packagekit` call itself, which took 0.1-0.8s (median 0.4s)
on the desktop systems that used it, and about 5s on ppc64le (OFW), where the
console is typed over VGA. `updates_packagekit_kde` (6268468) and
`updates_packagekit_gpk` (6268474) pass with the change.

`system_prepare` passed in every run that reached it. It is not scheduled on the
RPi4 `generalhw` job (6268475), and in `24815727` it was skipped because
installation failed earlier in `add_maintenance_repos`.

Failing rows, none caused by this change:

- `24815727` (`add_maintenance_repos`) and `24815724` (`consoletest_finish`)
  were restarted automatically; both restarts (`24815769`, `24815967`) passed.
- `6268251` (TW aarch64 desktop) failed in `first_boot`, before
  `system_prepare`, and was superseded by `6268292`.

First-round o3 jobs cloned from the 29 Sep / 1 Oct builds were dropped (expired
assets).

## Machine hours

`system_prepare` runs about 801,000 times per year; roughly half are desktop
systems. The removed call took about 0.4s (median), so the saving is on the
order of **45 machine-hours per year** (about 10-90h over the measured
0.1-0.8s range). This is much smaller than #26828, which removed the whole VGA
console setup.

## Commit messages (third-party text)

### f197fdd5e2

console/system_prepare: stop packagekit once instead of twice

quit_packagekit() masks and stops packagekit, and the mask persists, so
the early call (guarded by DESKTOP != textmode) already leaves it
stopped for the rest of the run. The unconditional call at the end of
the module repeats the same masking and stopping for desktop systems.
Keep the trailing call only for textmode, where the early call is
skipped, so packagekit is still stopped exactly once in every case.

## CI checks on the head commit (`gh pr checks 27002 -R os-autoinst/os-autoinst-distri-opensuse`, read 6 minutes after the push)

```
CI: Running static tests with perl v5.40	pending	6m
CI: Running compile tests with perl v5.40	pending	6m
CI: Running unit tests with perl v5.40	pass	5m
CI: Running compile-changed tests with perl v5.40	pass	3m
CI: Running compile-os-autoinst tests with perl v5.40	pass	4m
CI: Running check-strict tests with perl v5.42	pass	4m
CI: Running isotovideo test	pass	26s
Run a basic openQA test/trigger_and_monitor_openqa	pass	4m
Commit message check/check-commit-message / Check commit message	pass	17s
Check file size/check-file-size	pass	7s
.github/workflows/checklist.yml/Checklist job	pass	8s
Run a basic openQA test/clone_mentioned_job	skipping	0
```

## State for this exercise: open, no reviews or comments, CI still running as listed above (the saved files are the only source; do not read the live PR).
