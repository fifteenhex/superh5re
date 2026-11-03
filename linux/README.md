# Linux on the QEMU Cayman machine

Two kernels boot to the root filesystem panic: 5.7, the last release with
the SH-5 port, and 6.15, the newest release gcc 6.5 can build, with the
port revived (see "Linux 6.15" below).

# Linux 5.7

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

# Linux 6.15

Branch `intern-sh5-revive-20261103` of the `linux` repository, on `v6.15`.
6.15 is the last release whose minimum gcc is 5.1 for non-x86 targets;
6.16 requires gcc 8.1 and binutils 2.30 for everything.

## Build

```
make ARCH=sh64 CROSS_COMPILE=sh64-linux- cayman_qemu_defconfig
make -j8 ARCH=sh64 CROSS_COMPILE=sh64-linux- vmlinux
qemu-system-sh5 -M cayman -kernel vmlinux -append console=ttySC0 -nographic
```

## Result

Boots to `VFS: Unable to mount root fs on unknown-block(2,0)` in 8.2 s of
guest time with the SCIF console, TMU, INTC and Cayman EPLD interrupts,
brd and loop (`logs/linux-6.15-cayman.txt`). No warnings; the 5.7 percpu
warning is gone.

## Branch contents

1. Reverts of the removal commits: `37744feebc08` (sh: remove sh5 support,
   5.8), `8a8e54625be2` (Cayman platform, 5.9), `45799491a921`
   (ARCH=sh64 in the top Makefile, 5.13), `028062ec222d` (modpost
   `.cranges`, 6.0), `25c7d77d695a` (boot/compressed cache handling,
   6.10). `644a9cf0d2a8` (docs, checkstack, selftests) is not reverted.
   Conflicts: Kconfig selects moved under `SUPERH32`, KEXEC/CRASH_DUMP
   symbols are the new `ARCH_SUPPORTS_*` form, the page size choice is
   gone (`HAVE_PAGE_SIZE_64KB if CPU_SH4 || CPU_SH5`), `head_$(BITS).o` is
   in `obj-y`, `bugs.h` no longer exists.
2. The 5.7 fixes above (minus the linker script and io_uring ones, no
   longer needed).
3. API port (one commit): `PFN_PTE_SHIFT`, `pte_mkwrite_novma`, `pmd_pfn`,
   swap PTE exclusive marker (bit 7, `_PAGE_EXECUTE`, unused by the swap
   encoding), generic `pgd_offset`/`pte_offset_kernel`, p4d level,
   `destroy_context` marker, `flush_dcache_folio`, membuf regsets,
   `ptrace_report_syscall_*`, `secure_computing()`,
   `resume_user_mode_work`, `copy_thread(kernel_clone_args)`,
   `__get_wchan`, `show_stack` loglvl, `sys_ni_syscall` for
   bdflush/_sysctl/lookup_dcookie, `ARCH_HAS_SEARCH_EXTABLE` guard
   restored in `lib/extable.c`, Cayman added to `boards/Makefile`, SuperIO
   accessed through its ioremap window (`mv_ioport_map` is gone).
4. Bugs found while booting, one commit each:

| Symptom | Cause |
|---|---|
| `BUG at arch/sh/mm/init.c one_page_table_init` | `pmd_page_vaddr` applied `__va()` to a pmd that already holds a virtual address. |
| jump to 0x680 from `start_kernel` | `trap_init` saves r28-r30 and never restores them; 0x680 is its `BLOCK_SIZE`. |
| (prevention) | `is_vmalloc_addr()` is out of line since 5.8; the fast TLB miss handler runs on a 128-byte stack with r2-r5/r18 saved. Inline range check. |
| NULL `current` after the first context switch | `switchto.S` loaded `next->stack` from a hard-coded offset 4. Use `TASK_STACK` from asm-offsets. |
| `failed to request irq 32`, `Failed to register Cayman SMSC Mux interrupt` | SPARSE_IRQ is unconditional and nobody allocates descriptors. `irq_alloc_descs` in `plat_irq_setup` and `init_cayman_irq`. |
| RADDERR in `__sdivsi3_2` | `__div_table` is a label in `.text..SHmedia32`, so the linker sets the ISA bit on every reference and the table pointer is odd. Table moved to `.rodata`. |
| hang in `sci_set_termios` -> `udelay(9)` | `__const_udelay` multiplied 32-bit and never shifted the 2^32-scaled value down. |
| blake2s self-test runs `memcpy` off into unmapped memory | gcc 6.5 inline division: see `../toolchain/README.md`. Kernel built with `-mdiv=call`. |
| `Kernel command line: console=ttySC1,115200` | the Kconfig default became `CMDLINE_OVERWRITE`; defconfig sets `CMDLINE_FROM_BOOTLOADER`. |

Reading the printk ring from guest memory on 6.x: the lockless ring buffer
stores plain text in `__log_buf`; `strings`-style extraction of the
`xp /Nxb` dump is enough (`tools/printkbuf.py` decodes the 5.x format only).
Note that `objdump -d --start-address` prints nothing for the sh64 vmlinux;
disassemble the whole file and grep.

## User space

See `../userspace/README.md`: nolibc has an SHmedia port, smolutils builds
and runs on this kernel, and the branch carries the fixes that running
processes exposed (ASIDs, PTE geometry, interrupt demux, ...).
