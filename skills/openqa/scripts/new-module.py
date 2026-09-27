#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Scaffold an os-autoinst-distri-opensuse test module with a CI-clean header and the idiomatic skeleton for its kind.
"""Writes tests/<dir>/<name>.pm (or .py) into a distri checkout, then prints the schedule line and the next checks."""

import os
import re
import sys

from _sanitize import ArgumentParser, one_lines, sanitize

# Header shape: tests/console/man_pages.pm:1-8 (year-less copyright per CONTRIBUTING.md "Copyright SUSE LLC").
HEADER = """\
# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP

{package}# Summary: {summary}
# Maintainer: {maintainer}
"""

# Modelled on tests/console/man_pages.pm (minus its unused "my ($self) = @_;").
CONSOLE = """\
use Mojo::Base 'consoletest';
use testapi;
use serial_terminal 'select_serial_terminal';
use package_utils 'install_package';

sub run {{
    select_serial_terminal;

    install_package('{pkgs}', trup_apply => 1) if script_run('rpm -q {pkgs}');
    record_info('Version', script_output('rpm -q {pkgs}'));
    assert_script_run '{pkg} --version';
}}

1;
"""

# Same exemplar; without --package there is nothing to install.
CONSOLE_NOPKG = """\
use Mojo::Base 'consoletest';
use testapi;
use serial_terminal 'select_serial_terminal';

sub run {{
    select_serial_terminal;

    assert_script_run '{name} --version';
}}

1;
"""

# Modelled on tests/console/dnsmasq.pm (cleanup shared by both hooks, each chained to SUPER); the fail hook calls
# SUPER first as tests/console/systemd_resolved.pm does, so logs are exported before the package is removed.
SERVICE = """\
use Mojo::Base 'consoletest';
use testapi;
use serial_terminal 'select_serial_terminal';
use package_utils qw(install_package uninstall_package);
use utils 'systemctl';

sub run {{
    select_serial_terminal;

    install_package('{pkgs}', trup_reboot => 1);
    systemctl('enable --now {pkg}');
    systemctl('is-active {pkg}');
}}

sub cleanup {{
    systemctl('disable --now {pkg}', ignore_failure => 1);
    uninstall_package('{pkgs}', trup_reboot => 1);
}}

sub post_fail_hook {{
    my ($self) = @_;
    $self->SUPER::post_fail_hook;
    cleanup();
}}

sub post_run_hook {{
    my ($self) = @_;
    cleanup();
    $self->SUPER::post_run_hook;
}}

1;
"""

# Modelled on tests/x11/gimp.pm (close idiom) and tests/x11/inkscape.pm (ensure_installed with a named timeout).
X11 = """\
use Mojo::Base 'x11test';
use testapi;

sub run {{
    select_console 'x11';
    ensure_installed('{pkgs}', timeout => 300);
    x11_start_program('{pkg}');
    send_key_until_needlematch 'generic-desktop', 'alt-f4', 6, 5;
}}

1;
"""

# Modelled on tests/containers/seccomp.pm.
CONTAINER = """\
use Mojo::Base 'containers::basetest';
use testapi;
use serial_terminal 'select_serial_terminal';
use utils 'script_retry';

my $engine;

sub run {{
    my ($self, $args) = @_;
    my $runtime = $args->{{runtime}};

    select_serial_terminal;
    $engine = $self->containers_factory($runtime);

    my $image = get_var('CONTAINER_IMAGE_TO_TEST', 'registry.opensuse.org/opensuse/tumbleweed:latest');
    script_retry("$runtime pull $image", timeout => 300, delay => 60, retry => 3);
    validate_script_output "$runtime run --rm $image cat /etc/os-release", qr/ID=/;
}}

sub cleanup {{
    $engine->cleanup_system_host();
}}

sub post_fail_hook {{
    my ($self) = @_;
    cleanup();
    $self->SUPER::post_fail_hook;
}}

sub post_run_hook {{
    my ($self) = @_;
    cleanup();
    $self->SUPER::post_run_hook;
}}

sub test_flags {{
    return {{fatal => 0}};
}}

1;
"""

# Modelled on tests/microos/rebuild_initrd.pm (trup_call + check_reboot_changes).
TRANSACTIONAL = """\
use Mojo::Base 'consoletest';
use testapi;
use transactional;

sub run {{
    select_console 'root-console';

    trup_call('pkg install {pkgs}');
    check_reboot_changes;
    assert_script_run 'rpm -q {pkgs}';
}}

1;
"""

# Modelled on tests/yam/validate/validate_selinux.pm (expected values come from the schedule's test_data).
YAM_VALIDATE = """\
use Mojo::Base 'consoletest';
use scheduler 'get_test_suite_data';
use testapi;

sub run {{
    select_console 'root-console';

    my $expected = get_test_suite_data()->{{{name}}};
    assert_script_run "grep -q '$expected->{{value}}' /etc/os-release";
}}

1;
"""

# Modelled on tests/x11/doom.py; named Perl arguments become positional pairs (openQA docs/WritingTests.md).
PYTHON = """\
from testapi import *


def run(self):
    perl.require('serial_terminal')
    perl.serial_terminal.select_serial_terminal()
    assert_script_run('{pkg} --version', 'timeout', 120)
"""

KINDS = {
    "console": ("tests/console/man_pages.pm", CONSOLE),
    "service": ("tests/console/dnsmasq.pm", SERVICE),
    "x11": ("tests/x11/gimp.pm", X11),
    "container": ("tests/containers/seccomp.pm", CONTAINER),
    "transactional": ("tests/microos/rebuild_initrd.pm", TRANSACTIONAL),
    "yam-validate": ("tests/yam/validate/validate_selinux.pm", YAM_VALIDATE),
    "python": ("tests/x11/doom.py", PYTHON),
}

_PATH = re.compile(
    r"^tests/((?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+)/([A-Za-z_][A-Za-z0-9_]*)\.(pm|py)$"
)
_PACKAGES = re.compile(r"^[A-Za-z0-9._+-]+( [A-Za-z0-9._+-]+)*$")
_ONE_LINE = re.compile(r"^[^\x00-\x1f\x7f]+$")


class UsageError(Exception):
    pass


def render(kind, name, summary, maintainer, package):
    pkgs = package or name
    body = KINDS[kind][1]
    if kind == "console" and not package:
        body = CONSOLE_NOPKG
    header = HEADER.format(
        package=f"# Package: {package}\n" if package else "",
        summary=summary,
        maintainer=maintainer,
    )
    return header + "\n" + body.format(name=name, pkgs=pkgs, pkg=pkgs.split()[0])


def validate(args):
    match = _PATH.match(args.path)
    if not match:
        raise UsageError(
            "--path must look like tests/<dir>/<name>.pm with <name> a Perl identifier"
        )
    directory, name, ext = match.groups()
    if (ext == "py") != (args.kind == "python"):
        raise UsageError(
            "--kind {} needs a .{} path".format(
                args.kind, "py" if args.kind == "python" else "pm"
            )
        )
    for flag, value in (("--summary", args.summary), ("--maintainer", args.maintainer)):
        # sanitize() also redacts: report a credential as one, not as stray characters.
        cleaned = sanitize(value, max_line=0, max_bytes=0)
        rules = sorted(set(re.findall(r"\[REDACTED:([a-z-]+)\]", cleaned)))
        if rules:
            raise UsageError(f"{flag}: contains a credential ({', '.join(rules)})")
        if value != cleaned:
            raise UsageError(
                "--summary and --maintainer must not contain control or invisible characters"
            )
    if not _ONE_LINE.match(args.summary.strip() or "\n"):
        raise UsageError("--summary must be one non-empty line")
    # tools/check_metadata: grep -E '# Maintainer: .+(@| at ).+'
    if not _ONE_LINE.match(args.maintainer) or not re.search(r".@.", args.maintainer):
        raise UsageError("--maintainer must be one line containing an address with '@'")
    if args.package and not _PACKAGES.match(args.package):
        raise UsageError("--package must be space-separated RPM names")
    if args.kind in ("service", "x11", "transactional") and not args.package:
        raise UsageError(f"--kind {args.kind} needs --package")
    return directory, name


def same_basename(tests_dir, target, filename):
    hits = []
    for root, _dirs, files in os.walk(tests_dir):
        if filename in files:
            path = os.path.join(root, filename)
            if os.path.realpath(path) != target:
                hits.append(os.path.relpath(path, os.path.dirname(tests_dir)))
    return sorted(hits)


def main(argv=None):
    parser = ArgumentParser(
        description="Scaffold an os-autoinst-distri-opensuse test module. Refuses to overwrite. "
        "Exit codes: 0 written/printed, 2 usage or runtime error.",
    )
    parser.add_argument("--kind", required=True, choices=sorted(KINDS))
    parser.add_argument(
        "--path",
        required=True,
        help="tests/<dir>/<name>.pm (.py for --kind python), relative to --repo",
    )
    parser.add_argument("--summary", required=True, help="one line for '# Summary:'")
    parser.add_argument(
        "--maintainer",
        required=True,
        help="e.g. 'QE Team <qe-team@example.com>' (must contain @)",
    )
    parser.add_argument(
        "--package",
        help="space-separated RPM names for '# Package:' and the install step",
    )
    parser.add_argument(
        "--repo", default=".", help="distri checkout (default: current directory)"
    )
    parser.add_argument(
        "--stdout", action="store_true", help="print the module instead of writing it"
    )
    args = parser.parse_args(argv)

    try:
        directory, name = validate(args)
    except UsageError as error:
        print(f"new-module.py: {error}", file=sys.stderr)
        return 2

    text = render(
        args.kind, name, args.summary.strip(), args.maintainer.strip(), args.package
    )
    if args.stdout:
        sys.stdout.write(sanitize(text, max_line=0, max_bytes=0))
        return 0

    repo = os.path.realpath(args.repo)
    tests_dir = os.path.join(repo, "tests")
    target = os.path.realpath(os.path.join(repo, args.path))
    if not os.path.isdir(tests_dir):
        print(
            one_lines(
                [
                    f"new-module.py: {args.repo} has no tests/ directory, not a distri checkout"
                ]
            ),
            end="",
            file=sys.stderr,
        )
        return 2
    tests_real = os.path.realpath(tests_dir)
    # tests/ itself may be a symlink that leaves the checkout.
    if (
        os.path.commonpath([tests_real, repo]) != repo
        or os.path.commonpath([target, tests_real]) != tests_real
    ):
        print(
            one_lines(
                [f"new-module.py: {args.path} resolves outside {args.repo}/tests"]
            ),
            end="",
            file=sys.stderr,
        )
        return 2
    try:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "x", encoding="utf-8") as handle:
            handle.write(text)
    except FileExistsError:
        print(f"new-module.py: {args.path} exists, not overwriting", file=sys.stderr)
        return 2
    except OSError as error:
        # str(error) names the resolved path, where "https://" has lost a slash.
        print(
            one_lines([f"new-module.py: {args.path}: {error.strerror}"]),
            end="",
            file=sys.stderr,
        )
        return 2

    suffix = ".py" if args.kind == "python" else ""
    entry = f"{directory}/{name}{suffix}"
    checker = os.path.join(
        os.path.dirname(os.path.realpath(__file__)), "check-module.py"
    )
    lines = [f"wrote {args.path} (kind {args.kind}, after {KINDS[args.kind][0]})"]
    if args.kind == "container":
        lines.append(
            f"schedule: loadtest('{entry}', run_args => $run_args, name => $run_args->{{runtime}} . '_{name}'); in lib/main_containers.pm"
        )
    else:
        lines.append(f"schedule: - {entry}")
    for other in same_basename(tests_dir, target, os.path.basename(target)):
        lines.append(
            f"warning: basename also used by {other}; both cannot be loaded in one job"
        )
    lines.append("next:")
    lines.append("  replace the placeholder commands in run with the real checks")
    if args.kind == "x11":
        lines.append(
            f"  needle tagged '{(args.package or name).split()[0]}' must exist in the needles repository"
        )
    if args.kind == "yam-validate":
        lines.append(
            f"  add '{name}: {{value: ...}}' to the test_data YAML of the schedule"
        )
    lines.append(f"  {checker} {args.path}")
    if args.kind != "python":
        lines.append(f"  tools/tidy {args.path}")
        lines.append(f"  tools/check_metadata {args.path}")
        lines.append(f"  perl tools/check_os_autoinst_compile {args.path}")
    lines.append(
        "  make test-yaml-valid test-unused-modules-changed   # after the schedule entry is committed"
    )
    lines.append(
        "note: the year-less 'Copyright SUSE LLC' line is intended (CONTRIBUTING.md); "
        "do not copy a sibling's year"
    )
    lines.append(
        "note: 'make test-compile-changed' and 'make test-metadata-changed' skip new untracked files"
    )
    sys.stdout.write(sanitize("\n".join(lines) + "\n"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
