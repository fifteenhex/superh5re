# Linux 5.7 on the QEMU Cayman machine

Linux 5.7 is the last release with the SH-5 (sh64) port (removed in 5.8).
Toolchain: see `../toolchain/README.md` (binutils 2.30, gcc 6.5.0 with the
SHmedia constant fix).

## Build

The same tree is kept as a git branch: `intern-sh5-cayman-20261103` in the
`linux` repository, one commit on top of `v5.7` (the patch below plus the
defconfig as `arch/sh/configs/cayman_qemu_defconfig`). From the tarball:

```
tar xJf linux-5.7.tar.xz && cd linux-5.7
patch -p1 < ../linux/patches/linux-5.7-sh64-cayman.patch
cp ../linux/cayman_qemu_defconfig arch/sh/configs/
make ARCH=sh64 CROSS_COMPILE=sh64-linux- cayman_qemu_defconfig
make -j8 ARCH=sh64 CROSS_COMPILE=sh64-linux- vmlinux
qemu-system-sh5 -M cayman -kernel vmlinux -append console=ttySC0 -nographic
```

`ARCH=sh64` selects `CONFIG_SUPERH64`. The ELF entry point is the physical
address of `_stext`; QEMU enters with the MMU off and the kernel maps itself
at 0xa0000000 (PAGE_OFFSET 0x20000000). QEMU writes `-append` to the zero
page at `_stext - 0x1000 + 0x100` and `-initrd` to INITRD_START/SIZE.

## Result

Boots to `VFS: Unable to mount root fs on unknown-block(2,0)` in 2.2 s of
guest time with the SCIF console (`ttySC0`), TMU clocksource, INTC, Cayman
system FPGA and SMSC SuperIO detected. No root filesystem exists yet (see
`../refs/sources.md`, Linux userland section).

## Patch contents (all sh64 bit rot in 5.7, the port had not been booted
for years)

| File | Problem |
|---|---|
| `arch/sh/kernel/vmlinux.lds.S` | `_end` 4-byte aligned; `head_64.S` clears BSS in quadwords until `r22 == _end` and runs off the end of memory. |
| `arch/sh/kernel/head_64.S` | `cpu_init()` never called (head_32 does); without `cpu_probe()` the TLB descriptors are zero and `__update_tlb` reuses ITLB slot 0, the kernel mapping. Reload TR0 after the call. |
| `arch/sh/include/asm/pgalloc.h` | pmd entries stored as bare pointers but `pmd_present()` tests `_PAGE_PRESENT`; every vmalloc/ioremap TLB miss failed. Store `_KERNPG_TABLE` flags. |
| `arch/sh/include/asm/pgtable_64.h` | `_PAGE_FLAGS_HARDWARE_MASK` used `NEFF_MASK` (bits 63:32) and dropped the whole PTEL; TLB entries were loaded with PPN 0. |
| `arch/sh/lib64/strcpy.S`, `memset.S` | `#if __BYTE_ORDER == __LITTLE_ENDIAN` compares an undefined macro with kconfig.h's 1234 and assembled the big-endian variant (byterev, swapped shifts): strcpy lost the last 1-7 bytes of every string. Use `__LITTLE_ENDIAN__`. |
| `arch/sh/kernel/process_64.c` | kernel thread function and argument stored zero-extended; `ret_from_kernel_thread` does `ptabs` on it and raises IADDERR. |
| `arch/sh/kernel/ptrace_64.c` | `user_{en,dis}able_single_step` dereference `thread.uregs`, NULL for kernel threads; `copy_process` calls it for every fork. |
| `arch/sh/kernel/cpu/irq/intc-sh5.c` | enabled interrupts at the end of `plat_irq_setup` ("Interrupts were enabled early"); the timer fired before the IRQ descriptors existed. |
| `arch/sh/kernel/syscalls_64.S` | `sys_time` etc. renamed `sys_*_time32` long ago. |
| `arch/sh/Makefile` | link libgcc (`__ashldi3`, `__lshrdi3`). |
| `arch/sh/Kconfig` | `CPU_SH5` selects `SH_INTC` (`intc_finalize` undefined). |
| `arch/sh/kernel/cpu/sh5/fpu.c`, `arch/sh/mm/extable_64.c`, `cache-sh5.c`, `arch/sh/include/asm/syscall_64.h`, `arch/sh/kernel/signal_64.c`, `fs/io_uring.c` | compile errors: missing includes, pointer/integer casts, `ksig` API, `ssize_t` is `int` on sh64. |

Configuration changes relative to `cayman_defconfig`: `SH_CAYMAN` (the
defconfig did not select a board), `MEMORY_SIZE=0x08000000`, serial SCIF
console, SMC91X, no FB/SCSI/PCI, `LOG_BUF_SHIFT=20` (the log is read from
guest memory with `tools/printkbuf.py` when the console is not up yet).

Still open: `WARNING at mm/percpu.c:1689` (first percpu chunk marked
immutable but not fully populated) appears on every percpu allocation.
