# PR os-autoinst/os-autoinst-distri-opensuse#26824: Kernel::bootloader_setup: Kernel: Validate kernel CLI length as per CPU architecture
head commit: 4b81f193cb39f6daead2f65f666bc36f25fc6ec7; base: 6658dd0542429ae792c2116b34f5b3452e3ed363; changed lines: +479 -1
files:
  93	0	lib/Utils/Bootloader.pm
  4	0	lib/bootloader_setup.pm
  78	0	t/54_utils_bootloader.t
  301	0	t/data/mock_grub.cfg
  3	1	tests/kernel/install_ltp.pm

## PR description (third-party text)

- Add kernel command line length checking logic in a new utility module `lib/Utils/Bootloader.pm` with the function `check_kernel_arg_len`.
- Make the check optional in `add_custom_grub_entries` by accepting a  `check_kernel_arg_len` parameter.
- Pass `check_kernel_arg_len => 1` when invoking `add_custom_grub_entries` from `tests/kernel/install_ltp.pm`.
- Add static per-architecture lookup table using the values from the upstream kernel sources `(arch/*/include/{asm,uapi/asm}/setup.h)`, verified against torvalds/linux and, for s390x, against the actual openSUSE kernel-source  config `(CONFIG_COMMAND_LINE_SIZE=4096)`. x86_64, aarch64, ppc64(le) and riscv64 share the 2048 default; only s390x needs an override, so it is the sole entry in `COMMAND_LINE_SIZE_BY_ARCH`.



- Related ticket: https://progress.opensuse.org/issues/134486
- Needles: N/A
- Verification run: https://openqa.example.org/tests/overview?distri=sle&build=%3Ajdoe

## State for this exercise: open, no reviews or comments, CI green (the saved files are the only source; do not read the live PR).
