#!/bin/sh
# check-card.sh <bdf> [logdir] - the regression on the card: every test
# image and both kernels, each with the result it must print, each timed.
# Runs after a flash, before anyone trusts a bitstream (docs/soc.md, "On
# the card"). Needs sudo for BAR0; run from the repository root, or set
# SH5_TESTS, SH5_LINUX, SH5_INITRD, SH5_NETBSD to the images.
#
#   ./host/check-card.sh 0000:41:00.0
#
# Exit status: the number of failed steps.
set -u
bdf=${1:?usage: check-card.sh <bdf> [logdir]}
log=${2:-check-card-$(date +%Y%m%d-%H%M%S)}
here=$(cd "$(dirname "$0")" && pwd)
ctl=$here/sh5ctl
tests=${SH5_TESTS:-$here/../tests}
linux=${SH5_LINUX:-$here/../linux/vmlinux}
initrd=${SH5_INITRD:-$here/../linux/sh-sh5.cpio.gz}
netbsd=${SH5_NETBSD:-$here/../linux/netbsd-qemu}
mkdir -p "$log"
fails=0
make -C "$here" >/dev/null || exit 1

# step NAME EXPECT COMMAND...: run, keep the output, pass if EXPECT appears
step() {
	name=$1; expect=$2; shift 2
	start=$(date +%s)
	"$@" > "$log/$name.txt" 2>&1
	rc=$?
	secs=$(( $(date +%s) - start ))
	if grep -q -- "$expect" "$log/$name.txt" && [ $rc -eq 0 ]; then
		printf "%-10s PASS  %4ds  %s\n" "$name" "$secs" "$(grep -o 'seen after.*' "$log/$name.txt" | head -1)"
	else
		printf "%-10s FAIL  %4ds  rc %d; log in %s/%s.txt\n" "$name" "$secs" "$rc" "$log" "$name"
		fails=$((fails + 1))
	fi
}
skip() { printf "%-10s SKIP  %s\n" "$1" "$2"; }

step probe   "superh5 "              sudo "$ctl" "$bdf" probe
step memtest "memtest passed"        sudo "$ctl" "$bdf" memtest
step exc     "SUMMARY 438 tests, 0 failures" \
	sudo "$ctl" "$bdf" run "$tests/exc/exc.elf" --done "isa: DONE" --timeout 60
step isa     "SUMMARY 458064 tests, 0 failures" \
	sudo "$ctl" "$bdf" run "$tests/isa/isatest-bare.elf" --done "isa: DONE" --timeout 300
if [ -f "$tests/compact/compact-sh5.elf" ]; then
	step compact "SUMMARY 172323 tests, 0 failures" \
		sudo "$ctl" "$bdf" run "$tests/compact/compact-sh5.elf" --done "isa: DONE" --timeout 300
else skip compact "no $tests/compact/compact-sh5.elf"; fi
if [ -f "$linux" ] && [ -f "$initrd" ]; then
	step linux "cpu type	: SH5-101" \
		sudo "$ctl" "$bdf" run "$linux" --initrd "$initrd" \
		--cmdline "console=ttySC0 -- smolinit.getty=/dev/ttySC0 smolinit.hostname=cayman" \
		--expect "smolsh / >" --send 'cat /proc/cpuinfo\n' --expect "smolsh / >" --send 'echo FIN\n' \
		--done FIN --timeout 300
else skip linux "no $linux / $initrd"; fi
if [ -f "$netbsd" ]; then
	step netbsd "NetBSD cayman 3.1" \
		sudo "$ctl" "$bdf" run "$netbsd" --expect "login: " --send 'root\n' \
		--expect "# " --send 'uname -a\n' --expect "# " --send 'echo FIN\n' --done FIN --timeout 400
else skip netbsd "no $netbsd"; fi
echo "check-card: $fails failed; logs in $log/"
exit $fails
