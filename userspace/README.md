# User space: nolibc and smolutils on the sh64 kernel

No libc exists for SH-5 Linux. The userland is smolutils built against the
kernel's nolibc with the sh64-linux gcc 6.5 toolchain (`../toolchain/`).

## nolibc

Branch `intern-nolibc-sh5-20261103` of the `linux` repository (one commit on
`v7.3-rc2`), also here as `nolibc-7.3-sh5-shmedia.patch`. It adds an SHmedia
block to `tools/include/nolibc/arch-sh.h`, selected on
`__SH5__ && __SHMEDIA__`; the existing code is the SHcompact ABI.

Syscall convention (from `arch/sh/kernel/cpu/sh5/entry.S`): number in r9
and in the trap value, arguments in r2-r7, `trapa Rn` with
`Rn = 0x100000 | (nargs << 16) | number`, result in r9. The low 9 bits of
the trap value select the handler, so numbers up to 511 work. `_start`
passes the initial stack pointer to `_start_c` in r2.

nolibc on a 32-bit `long` target requires the time64 syscalls, which the
sh64 table did not have; the kernel branch appends them (and statx,
openat2, ... 72 in all) from 394 onwards.

## Building a test program

```
make ARCH=sh64 CROSS_COMPILE=sh64-linux- INSTALL_HDR_PATH=$UAPI headers_install
sh64-linux-gcc -m5-32media-nofpu -mdiv=call -Os -nostdlib -static \
    -fno-stack-protector -include $NOLIBC/nolibc.h -I$NOLIBC -I$UAPI/include \
    -o hello hello.c -lgcc
echo hello | cpio -o -H newc > hello.cpio   # as /init
qemu-system-sh5 -M cayman -kernel vmlinux -initrd hello.cpio -append console=ttySC0 -nographic
```

`-mdiv=call` is required: see the gcc inline division bug in
`../toolchain/README.md`.

## smolutils

Branch `intern-sh5-smolutils-20261103` of the `smolutils` repository adds
`CPU=sh5` to `Makefile.sh`:

```
make -f Makefile.sh CPU=sh5 CROSS_COMPILE=sh64-linux- \
    NOLIBCDIR=$NOLIBC NOLIBCEXTDIR=/path/to/nolibc-extensions \
    UAPIDIR=$UAPI/include TARWAK=/path/to/tarwak sh-sh5.cpio.gz
qemu-system-sh5 -M cayman -kernel vmlinux -initrd sh-sh5.cpio.gz \
    -append "console=ttySC0 -- smolinit.getty=/dev/ttySC0 smolinit.hostname=cayman" -nographic
```

All 32 programs build. init, startup (devtmpfs, proc, sysfs, tmpfs mounts,
capability xattrs), getty and smolsh run; ls, df, cat, ps, free, uname work
(`../logs/linux-6.15-smolutils.txt`). The kernel config needs
`DEVTMPFS`, `TMPFS` and `TMPFS_XATTR` (in `cayman_qemu_defconfig`).
Options after `--` on the kernel command line become init's argv; options
without `--` go to its environment and smolutils ignores them.

## Kernel bugs found by running user space

All on branch `intern-sh5-revive-20261103`, one commit each:

| Symptom | Cause |
|---|---|
| `Bad page map`, execve fails with E2BIG | `set_pte` kept only the low 32 bits and sign-extended them, setting every `_PAGE_EXT()` software flag (`_PAGE_SPECIAL`, `_PAGE_WIRED`). The TLB refill masks bits 63:32 anyway; store the whole value. |
| every DTLB refill written to the ITLB | `set_thread_fault_code()` masked with `~0 >> n`, an arithmetic shift of -1, so stale fault codes were never cleared. |
| console writes block forever | `do_IRQ()` receives INTEVT >> 5 and the Cayman machvec had no `mv_irq_demux`, so the SCIF TXI event (0x760) became irq 59. |
| exec()ed child runs the parent's code | `enable_mmu()` is a no-op on sh64 and never seeded `asid_cache`; every mm got ASID 0 and shared TLB entries. |
| slab padding overwritten, PTEs read back as poison | `pgtable-2level.h` assumed 32-bit PTEs (1024 per page, 1 GiB pgd). sh64 PTEs are 8 bytes: half of all PTE slots were in the next page. |
| every WARN/panic trace ends in a jump to a truncated address | the unwinder's `char namebuf[128]` versus `KSYM_NAME_LEN` 512: stack overflow in `lookup_prev_stack_frame`. |
| (latent) | `flush_thread` computed init's register frame from the task_struct, and `switch_to` wrote `SR_FD` through it; the fast TLB miss stack was 128 bytes. |

Debugging aids: `qemu -d pcall` logs every syscall and return to user;
`-d int,guest_errors` shows faults, and the SHcompact-entry abort is now a
logged RESINST exception so the kernel reports the offending process.
