# SUSE's openQA tests
#
# Copyright (C) 2020 SUSE LLC
# SPDX-License-Identifier GPL-2.0-or-later
# This program is free software; you can redistribute it
#
# Summary: Fixture in which every rule that fits one file fires once
# Maintainer: QE Team

use base 'consoletest';
use strict;
use testapi;
use utils;
use version_utils 'is_leap';

sub run {
    select_console 'root-console';
    if (check_var('ARCH', 'x86_64')) {
        assert_script_run 'rpm -qa | egrep kernel';
    }
    wait_idle;
    check_screen 'desktop', 100;
    check_screen 'desktop', 5;
    record_soft_failure 'something is broken';
    loadtest 'console/foo.pm';
    zypper_call 'in vim' if is_leap('15');
    script_run 'daemon --foreground &';
    assert_and_click 'button', 60;
    sleep 5;
    assert_script_run 'zypper -n in vim';
    zypper_call 'in -y vim';
    type_string "ls\n";
    assert_script_run 'make', timeout => 90;
    assert_script_run 'mkdir /tmp/t; cd /tmp/t';
}
