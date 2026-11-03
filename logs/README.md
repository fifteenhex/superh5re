# Boot transcripts

Console output captured from `qemu-system-sh5 -M cayman ... -nographic`
with `tools/qrun.py` (input lines are echoed by the guest).

| File | Image | Result |
|---|---|---|
| `netbsd-3.1-cayman-32bit.txt` | CAYMAN_QEMU kernel (`netbsd/`) with the 32 MB root image | multi-user, root login, `ps`, `df`, `mount`, `ifconfig sm0`, ping to the user-network gateway |
| `netbsd-3.1-cayman-64bit.txt` | CAYMAN64_QEMU kernel, same root image | multi-user, root login; the 32-bit userland runs through COMPAT_NETBSD32 |
| `linux-5.7-cayman.txt` | Linux 5.7 `vmlinux` (`linux/`), `console=ttySC0` | boots to the root filesystem panic (no root device) |
| `linux-6.15-cayman.txt` | Linux 6.15 `vmlinux` (branch `intern-sh5-revive-20261103`), `console=ttySC0` | boots to the root filesystem panic |

The build host name and object directory in the kernel version strings were
replaced by `builder` and `/obj/`. The NetBSD clock reads a fixed date because
the RTC model returns the host time without a battery-backed year.
