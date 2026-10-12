# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP

# Package: iproute2 iputils
# Summary: Connect two network namespaces with a veth pair and ping across it over IPv6
# Maintainer: QE Team <qe-team@example.com>

use Mojo::Base 'consoletest';
use testapi;
use utils 'zypper_call';

sub run {
    select_console 'root-console';

    zypper_call 'in iproute2 iputils';

    assert_script_run 'ip netns add ns0';
    assert_script_run 'ip netns add ns1';
    assert_script_run 'ip link add veth0 type veth peer name veth1';
    assert_script_run 'ip link set veth0 netns ns0';
    assert_script_run 'ip link set veth1 netns ns1';
    assert_script_run 'ip -n ns0 link set lo up';

    assert_script_run 'ip -n ns0 addr add fd00::1/64 dev veth0; ip -n ns1 addr add fd00::2/64 dev veth1; ip -n ns0 link set veth0 up; ip -n ns1 link set veth1 up';

    # duplicate address detection keeps a new IPv6 address tentative for a moment
    sleep 10;
    assert_script_run 'ip netns exec ns0 ping -6 -c 3 fd00::2', fail_message => 'no connectivity between the namespaces';
}

1;
