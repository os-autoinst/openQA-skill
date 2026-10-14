# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP

# Package: vim
# Summary: Fixture with look-alikes that must not be reported
# Maintainer: QE Team <qe-team@example.com>

use Mojo::Base 'consoletest';
use testapi;
use serial_terminal 'select_serial_terminal';
use utils qw(zypper_call script_retry);
use package_utils 'install_package';

sub run {
    select_serial_terminal;

    install_package('vim', trup_reboot => 1);
    zypper_call 'ar -n fixture http://example.invalid/repo fixture';
    # sleep 5; would be wrong here, so poll instead
    script_retry('sh -c "sleep 1; test -e /tmp/ready"', retry => 5, delay => 2);
    script_run('daemon --foreground &', 0);
    assert_script_run 'zypper lr | tee /tmp/repos.txt';
    assert_script_run 'make', timeout => 300;
    record_soft_failure 'bsc#1234567 - vim crashes on start' if script_run('vim --version');
    my $script = <<'EOT';
sleep 3
zypper -n in vim
EOT
    assert_script_run "cat > /tmp/s.sh <<'END'\n$script\nEND";
    my $sleeper = $testapi::distri->sleep_helper;
    enter_cmd "exit" unless check_screen('desktop', 0);
    assert_and_click 'button', timeout => 60;
    assert_script_run 'for f in a b; do test -e /tmp/$f; done';
    assert_script_run 'while pgrep -f fixture; do pkill -f fixture; done';
    assert_script_run 'until test -e /tmp/ready; do touch /tmp/ready; done';
    assert_script_run 'if [ -d /tmp/fixture ]; then ls /tmp/fixture; fi';
    assert_script_run 'case $(uname -m) in x86_64) true;; *) false;; esac';
    assert_script_run "find /tmp/fixture -name '*.tmp' -exec md5sum {} \\; > /tmp/fixture.sums";
    assert_script_run "sed -i 's/a/b/; s/c/d/' /tmp/fixture/conf";
    assert_script_run 'bash -c "cd /tmp/fixture; ls"';
    assert_script_run "echo \"include $script;\" >> /tmp/fixture/conf";
    assert_script_run 'echo `cd /tmp; pwd`';
    assert_script_run '(cd /tmp; ls) | tee /tmp/fixture.list';
    assert_script_run '{ echo secret; echo secret; } | smbpasswd -a -s fixture';
    assert_script_run 'set -e; cd /tmp; ls';
    assert_script_run 'set -xo errexit; cd /tmp; ls';
    assert_script_run 'set -o pipefail; ls /tmp/fixture | tee /tmp/fixture.log';
    assert_script_run "cat > /tmp/fixture/dhcpd.conf <<EOF\ndefault-lease-time 600;\nmax-lease-time 7200;\nEOF";
    assert_script_run 'grep -q zfs /proc/filesystems; test "$?" == "1"';
    assert_script_run 'ls /tmp/absent; test $? -eq 2 && touch /tmp/fixture/ok';
    assert_script_run 'ls /tmp/fixture | cat -v; ( exit ${PIPESTATUS[0]} )';
    assert_script_run 'touch /etc/fixture; test ! -f /etc/fixture';
    assert_script_run 'touch /etc/fixture; [ ! -f /etc/fixture ]';
    assert_script_run 'touch /etc/fixture; [[ ! -f /etc/fixture ]]';
    assert_script_run 'umount /mnt/fixture; true';
    assert_script_run 'rm /tmp/fixture/lock || true; ls /tmp/fixture';
    assert_script_run 'ls /tmp/fixture;';
    assert_script_run 'ls /tmp/fixture ; ';
}

1;

=head1 Notes

sleep 5;
use base 'x';
assert_script_run 'cd /tmp; ls';

=cut
