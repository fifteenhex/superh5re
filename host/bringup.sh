#!/bin/sh
# bringup.sh <bdf> [logdir] - the first hour on a card, in order, stopping
# at the first step that fails (docs/soc.md, "Bring-up"). Each step proves
# one layer: the PCIe path, the clocking, the DRAM path, the core, the
# whole system. Run from the repository root; needs sudo for BAR0.
#
#   ./host/bringup.sh 0000:01:00.0
set -u
bdf=${1:?usage: bringup.sh <bdf> [logdir]}
log=${2:-bringup-$(date +%Y%m%d-%H%M%S)}
here=$(dirname "$0")
ctl=$here/sh5ctl
mkdir -p "$log"

step() {
	name=$1; shift
	echo "== $name: $*"
	"$@" 2>&1 | tee "$log/$name.txt"
	rc=$?
	if [ $rc -ne 0 ]; then
		echo "== $name FAILED (rc $rc); the log is in $log/"
		exit $rc
	fi
}

make -C "$here" >/dev/null || exit 1
[ -f "$here/../tests/exc/exc.elf" ] || make -C "$here/../tests/exc" || exit 1

step probe   sudo "$ctl" "$bdf" probe
step status  sudo "$ctl" "$bdf" status
step memtest sudo "$ctl" "$bdf" memtest
step exc     sudo "$ctl" "$bdf" run "$here/../tests/exc/exc.elf" --done "isa: DONE" --timeout 60
if [ -f "$here/../tests/isa/isatest-bare.elf" ]; then
	step isa sudo "$ctl" "$bdf" run "$here/../tests/isa/isatest-bare.elf" --done "isa: DONE" --timeout 300
fi
if [ -f "$here/../tests/compact/compact-sh5.elf" ]; then
	step compact sudo "$ctl" "$bdf" run "$here/../tests/compact/compact-sh5.elf" --done "isa: DONE" --timeout 300
fi
echo "== all steps passed; logs in $log/. Next: sh5ctl $bdf boot <vmlinux> --initrd <cpio.gz> --cmdline \"console=ttySC0 -- smolinit.getty=/dev/ttySC0 smolinit.hostname=cayman\""
