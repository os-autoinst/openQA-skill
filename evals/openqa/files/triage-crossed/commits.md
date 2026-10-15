# Test commits between o3 jobs 6270503 (last good) and 6273000

repository: https://github.com/os-autoinst/os-autoinst-distri-opensuse
last good 6270503 (build 20261013): TEST_GIT_HASH 9774489af0c369db871b163d1e91de7b6aa7ed79
first bad 6271997 (build 20261014): TEST_GIT_HASH 29cf91b55936f19f10f4094bc18dc6d0b3cb67cc
this job  6273000 (build 20261014): TEST_GIT_HASH 529c03f8f906aeb0d28417aa2a3feeb00ad41d5d

`git log --no-merges --name-status 9774489af0c3..529c03f8f906`, newest first: 27 commits. The three
marked `(after first bad)` came after 29cf91b55936, so the first bad job did not run them.

## Commits (third-party text)

529c03f8f906 Add openqa_created_date tag to qesap public cloud tags (#27034) (after first bad)
    M	lib/sles4sap/qesap/utils.pm
    M	t/36_qesap_utils.t

6a0c146a057b Kernel: Validate kernel CLI length as per CPU architecture (after first bad)
    A	lib/Utils/Bootloader.pm
    M	lib/bootloader_setup.pm
    A	t/54_utils_bootloader.t
    A	t/data/mock_grub.cfg
    M	tests/kernel/install_ltp.pm

0562eaacb4f2 autoyast/autoyast_reboot: reboot from the VGA console on qemu (after first bad)
    M	tests/autoyast/autoyast_reboot.pm

29cf91b55936 Kernel::sysrq_test: Increase journalctl line limit for sysrq-l
    M	lib/Kernel/magic_sysrq.pm

3c88500e4e51 Kselftests: NET: Run netdevsim workaround also for Tumbleweed
    M	tests/kernel/kselftests_prepare.pm

16aff3514d37 xfstests/partition.pm: Find kernel config outside /boot
    M	tests/xfstests/partition.pm

bbde3394aa95 Fix: lsof was faster than service start
    M	tests/fips/squid/squid_web_proxy.pm

3422b80960dd support_server/setup: reduce setup time from 7m37s to ~5m10s (#26987)
    M	lib/iscsi.pm
    M	lib/mm_network.pm
    M	lib/mm_tests.pm
    M	tests/support_server/setup.pm

523ccb7d9142 Install package of suseconnect-ng for Leap migration testing
    M	tests/yam/migration/zypper_migration.pm

ffcbfdc91115 Fix version in sle_ibs_no_scc.jsonnet
    M	data/agama_auto/sle_ibs_no_scc.jsonnet

b90dd3c1a533 Remove soft-failure related with poo#195497
    M	tests/transactional/install_updates.pm

3bf1566a81dc Revert "console/curl_https: run curl as the regular user on the serial consol…"
    M	tests/console/curl_https.pm

2a3b337f426e Fix seahorse failure on TW
    M	tests/x11/seahorse.pm

5ad689183ef0 console/force_scheduled_tasks: use the serial terminal (#27001)
    M	tests/console/force_scheduled_tasks.pm

0248f2c86d81 kernel/wmp_simple: Accept some small swap use on HANA processes
    M	tests/kernel/wmp_simple.pm

3c66a454fbe0 xfstests: Change maintainer to kernel-qe
    M	lib/xfstests_ai_analysis.pm
    M	lib/xfstests_utils.pm
    M	tests/xfstests/enable_kdump.pm
    M	tests/xfstests/generate_report.pm
    M	tests/xfstests/install.pm
    M	tests/xfstests/partition.pm
    M	tests/xfstests/run.pm
    M	tests/xfstests/run_subtest.pm

3fdb2d099f22 Collect and upload Azure CLI command logs in ipaddr2 (#27021)
    M	lib/sles4sap/ipaddr2.pm
    M	t/22_ipaddr2.t

196f3676d24a console/curl_https: run curl as the regular user on the serial console (#27005)
    M	tests/console/curl_https.pm

7334e59f959d console/system_prepare: stop packagekit once instead of twice (#27002)
    M	tests/console/system_prepare.pm

f1e5b671ceae Fix match issue on wwid/lun size
    M	tests/console/validate_zfcp_multipath.pm

8c4ad0ceba07 CONTRIBUTING: add coding guidelines for infrastructure/product tests
    M	CONTRIBUTING.md

404fc6bf5c99 console/consoletest_finish: skip console logout in textmode (#27007)
    M	tests/console/consoletest_finish.pm

2362838d80e2 console/snapper_thin_lvm: use the text console (#27008)
    M	tests/console/snapper_thin_lvm.pm

b451e4fcb3d5 Make post-fail cleanup failures visible
    M	lib/sles4sap/publiccloud_basetest.pm
    M	tests/sles4sap/publiccloud/qesap_cleanup.pm

c4963f134ac7 irq_delivery_storage: run in the 2-host IRQ delivery schedule
    M	schedule/kernel/agama_irq_delivery_2hosts_baremetal.yaml
    D	schedule/kernel/agama_irq_delivery_storage_baremetal.yaml

0325e4f7fe59 irq_delivery_storage: check PCI storage interrupt delivery
    M	lib/Kernel/block_dev.pm
    A	schedule/kernel/agama_irq_delivery_storage_baremetal.yaml
    A	tests/kernel/irq_delivery_storage.pm

73a99ffb3965 Make cleanup failures visible and force softfail
    M	lib/sles4sap/publiccloud_basetest.pm
    M	tests/sles4sap/publiccloud/qesap_cleanup.pm
