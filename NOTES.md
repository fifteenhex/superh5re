# Journal

Dated entries, newest last. Record what was done, the result, and how to
reproduce it. Confirmed facts move to `docs/`.

## Open questions

- Scope of the first core: SHmedia only, or SHmedia + SHcompact.
- Target FPGA board.
- Deferred, pending decision: adding the MPR 1999 article and Hot Chips 13
  slides to `refs/`; rebuilding the Yumpu-only documents from page images;
  importing the binutils 2.30 CGEN SH-5 description and `sim/sh64` sources.
- Missing documents, see `refs/sources.md`: System Architecture volumes 1
  (Yumpu flipbook only) and 2 (not found), ABI spec, datasheets, assembly
  syntax (Yumpu only), SuperHyway interface definitions.

## 2026-11-01

- Repository created.
- Added the five SH-5 manuals to `refs/manuals/` (see its README for titles,
  IDs and checksums).

  ```
  for f in sh5_arch sh5_compact sh5_debug sh5_impl sh5_media; do
    curl -sL -o $f.pdf https://docs.alexrp.com/sh/$f.pdf; done
  python3 tools/pdfstrings.py <pdf> 4      # first text streams
  python3 tools/pdfgrep.py <pdf> 'regex'   # streams whose text matches
  ```
- Surveyed the web for further SH-5 material; results in `refs/sources.md`.
  The 2004 SuperH, Inc. document catalogue (via the Wayback Machine) confirms
  the four CPU Core PDFs are the original files (sizes match).

## 2026-11-02

- Read the netbsd-3 `sys/arch/sh5` and `sys/arch/evbsh5` sources. Facts in
  `docs/cayman-platform.md`; QEMU plan in `docs/plan-qemu-netbsd.md`.
- QEMU: new `sh5` target and `cayman` machine (branch `intern-sh5-20261102`
  in the qemu repository). The NetBSD 3.1 `netbsd-CAYMAN` kernel boots to
  the `root device:` prompt with SCIF console; autoconfiguration finds cpu,
  pbridge, intc, cprc, tmu, scif, rtc, femi and sysfpga. The kernel's
  built-in boot flags include RB_KDB, so it stops in DDB first; `c` continues.

  ```
  qemu-system-sh5 -M cayman -kernel netbsd-CAYMAN -nographic -d int,guest_errors,unimp -D boot.log
  ```
  Open: CTC/TMU calibration reads 2x (PLL reported 1024 MHz), no root
  device (needs sm0 ethernet + NFS, or a kernel with an md root).
- Found and worked around a NetBSD/sh5 checksum bug (see
  `docs/cayman-platform.md`); with it patched, DHCP over the emulated sm0
  completes. Shipped kernel cannot mount root without an NFS server, so the
  next step is a self-built kernel with an md root. NetBSD 3.1 cross tools
  (`build.sh -m evbsh5 tools`) build on a modern host with
  `HOST_CFLAGS="-O -fcommon -Wno-error -std=gnu89 -DARG_MAX=262144"` plus
  renaming `getline` in `usr.bin/ctags` and `usr.bin/gencat`; gcc must be
  built with `-j1` (parallel build produced a bad `tree.o`).
- DDB is reachable by answering `ddb` at the `root device:` prompt; the
  emulator passes the kernel symbol table so DDB shows symbols. `qrun.py`
  (in the work area, not yet in the repo) drives the console with
  expect/send steps.
- 2026-11-02: NetBSD 3.1 boots to a single-user shell on the QEMU `cayman`
  machine using a self-built CAYMAN_QEMU kernel with a 12 MB memory-disk
  root (`netbsd/README.md`). Verified: ps, df, mount, sysctl, ifconfig and
  ping to the slirp gateway. Remaining emulator work found on the way:
  SR.ASID/MD/MMU/WATCH/STEP are read-only to PUTCON; RTC 64 Hz register
  runs at 128 Hz; .L shifts mask the count to 5 bits; LDLO/LDHI byte
  placement. Open: `uname` and `tail` are not in /rescue (expected), RTC
  date read reports "bad date in battery clock", multi-user boot untested,
  SHcompact and the 64-bit kernel untested.
- 2026-11-02 (later): both kernels reach multi-user with a console login
  (`netbsd/README.md`). Fixes needed: boot parameters must carry unsigned
  physical addresses (the kernel's own defaults sign-extend them, but the
  64-bit pmap then compares sign-extended page frame numbers with the PTEL
  PPN and PHYS_TO_VM_PAGE fails); LP64 needs 512-byte mbufs; 32-bit
  processes on the 64-bit kernel must live below 2 GB (TEA is sign-extended
  from bit 31); `MEMORY_RBFLAGS=0` or the memory-disk root forces single
  user. 64-bit kernel: `ifconfig`/`route` fail through COMPAT_NETBSD32.
  Open: timing-dependent user process crashes (SIGBUS/SIGSEGV in sh, tset,
  grep, csh; fault addresses are ASCII text, so a pointer was overwritten
  with string data) and one hang in `/etc/rc` with a process looping on
  wait4() = ECHILD. Six consecutive boots were clean, so neither is
  deterministic. Checked and found consistent with the manuals: LDLO/LDHI/
  STLO/STHI byte mappings, IMASK set to the interrupt level on launch,
  SR.FD in the TB flags, TLB invalidation by slot cookie (every putcfg to
  the TLB arrays flushes the QEMU TLB). QEMU `-d pcall` logs user syscalls
  and RTE, `-d guest_errors` logs user faults with a register dump;
  `tools/qrun.py` gained `mon:` steps and `--on-timeout`.
- 2026-11-02 (debugging the user process crashes): QEMU `-d guest_errors`
  dumps registers and both TLB arrays at a user fault; `-d mmu` logs TLB
  writes, ASID changes and user TLB misses; `-d pcall` logs syscalls/RTE;
  `info tlb` in the monitor. Findings:
  - Crash site in sh is `forkchild`/`forkparent` (jobs.c): `jp->ps` holds
    string bytes ("r/lo", "/usr") or an odd pointer, and the child's copy
    of `mflag` (optlist[4], in .data) is non-zero while the parent's is 0.
    Two different pages (heap, .data) differ between parent and child.
  - Processes forked by init also die: the kernel hits a copyinstr fault
    for the exec path, then traps with IADDERR because trap.c zero-extends
    `pcb_onfault` (fixed in the patch set; Vol.1: EAs outside the
    sign-extended neff range raise IADDERR/RADDERR/WADDERR).
  - A duplicate-TLB-entry check found only benign cases: the STB1 cache-op
    helper maps the window page in slot 63 with ASID 1 while the generic
    SH entry for the same page and PA is still present.
  - Crashes are not deterministic even with `-icount`: the RTC model
    returns host time. Boots crash in roughly half the runs; the hang in
    `/etc/rc` is a process looping on wait4() = ECHILD.
  - Kernel TLB invalidation protocol (slot cookies, R bit) checked against
    stb1_locore.S and pmap.c; QEMU flushes its TLB on every TLB array
    write, so it cannot hold a translation the arrays do not.
  - Core dumps can be fetched over the console (`tools/nbcore.py`); the
    root login shell is csh, so run `exec sh` first.
- 2026-11-02 (resolved): the random user process crashes and the rc hang
  were caused by the emulator never setting the USR dirty bits. NetBSD
  saves/restores FP register groups only when USR.FPRS says they were
  written; gcc uses FP registers as integer scratch, so FP state leaked
  between processes. With dirty-bit tracking (QEMU commit "track
  USR.GPRS/USR.FPRS dirty bits") 16 consecutive 32-bit boots and 4 64-bit
  boots were clean; a boot takes about 40 s. Experiments that ruled things
  out before that: whole-TLB flush on every kernel invalidation still
  crashed (so not TLB bookkeeping); LDLO/LDHI/STLO/STHI mappings match the
  manual. Open on the 64-bit kernel: syslogd dumps core (COMPAT_NETBSD32),
  ifconfig/route fail. RTC model uses host time (non-deterministic boots).
- 2026-11-03: Linux 5.7 boots on the QEMU Cayman machine to the root
  filesystem panic (`linux/README.md`). Toolchain: binutils 2.30 and gcc
  6.5.0 for `sh64-linux`; gcc 6.5 needed a one-line backend fix (every
  SHmedia constant was deemed illegitimate, cc1 recursed to death on
  `return 0`). Emulator fixes on the way: loads into R63 are prefetches
  (no exception), the CPU VCR is also visible at offset 8, the board
  patches the Linux zero page. Kernel: eighteen files patched, all bit
  rot (see the README table); the patched tree is also branch
  `intern-sh5-cayman-20261103` of the `linux` repo (one commit on `v5.7`).
  Debugging recipe that worked: read the
  printk ring from guest memory (`tools/printkbuf.py`), `-d exec,cpu
  -dfilter` on one function for an instruction trace, gdbstub
  watchpoints/breakpoints (`tools/gdbwatch.py`), and a bare-metal harness
  (`tests/lib64`) that runs the kernel's string routines standalone.
  Note: the harness must be compiled with the same macros as the kernel;
  the strcpy bug only showed with kconfig.h's `__LITTLE_ENDIAN`.
- 2026-11-03: Linux 6.15 (newest release buildable with gcc 6.5; 6.16
  requires gcc 8.1) boots to the root filesystem panic with the SH-5 port
  revived: branch `intern-sh5-revive-20261103` of `linux` (reverts of the
  removal commits, API port, nine bug fixes; `linux/README.md` has the
  table). Boot-stopping bugs in order found: `pmd_page_vaddr` `__va()`,
  `trap_init` clobbering r28-r30, hard-coded `task_struct.stack` offset in
  `switchto.S`, no irq descriptors under SPARSE_IRQ, gcc inline division
  (missing early clobbers, `toolchain/README.md`), `__div_table` ISA bit,
  `__const_udelay` overflow. Pitfalls: the fast TLB miss handler must not
  call out-of-line functions; `-d int` shows nested faults with `(panic)`
  when SR.BL is set; a console pipeline through `tail` showed nothing
  because `timeout` killed it first, redirect QEMU output to a file.
  Open: gcc patch untested (needs gmp/mpfr/mpc sources to rebuild gcc);
  still no sh64 root filesystem.
- 2026-11-03: smolutils user space runs on the 6.15 sh64 kernel
  (`userspace/README.md`, `logs/linux-6.15-smolutils.txt`). nolibc got an
  SHmedia block (branch `intern-nolibc-sh5-20261103` of `linux`, on
  v7.3-rc2), smolutils an sh5 target (branch `intern-sh5-smolutils-20261103`;
  the gitolite branch `intern-sh5-20261103` of smolutils was pushed by
  mistake from another session's `intern-inc-strings` branch and can be
  deleted). Kernel fixes in order found: set_pte dropping/sign-extending
  the software flag bits, sticky thread fault code (`~0 >> n`), missing
  mv_irq_demux (SCIF TXI landed on irq 59), ASID allocator never seeded on
  sh64, 32-bit PTE geometry for 64-bit PTEs, unwinder namebuf overflow,
  flush_thread frame pointer, fast TLB miss stack size. Recipe that found
  the PTE geometry bug: CONFIG_SLUB_DEBUG_ON reported "Padding overwritten
  @offset=4080", which was PTE index 0x3fe * 8 of the stack page, written
  one page past the table. QEMU: SHcompact entry is now a logged RESINST
  instead of an abort. Open: gcc division patch still untested (needs
  mpfr/mpc), smolutils networking not tried (SMC91X present, no dhcp run).
