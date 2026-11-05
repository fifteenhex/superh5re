# Journal

Dated entries, newest last. Record what was done, the result, and how to
reproduce it. Confirmed facts move to `docs/`.

## Open questions

- Target FPGA board and clock.
- Bus: the SuperHyway interface definitions are not held; the core port
  carries the documented packet fields (`docs/bus-interface.md`) and needs
  a bridge to whatever the system uses.
- Failure (bus error) responses have no architectural event; see
  `docs/bus-interface.md`.
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
- 2026-11-03: ISA test kit (`tests/isa/`): 9 groups, 458064 checks, C
  references from the Vol. 2 pseudocode, FPU vectors from host generators
  with exact arithmetic; builds as a nolibc program and as a bare-metal
  image from the same sources. Groups were written by parallel agents from
  a shared harness; both modes pass on the current QEMU branch. Emulator
  bugs found: MABS saturation, default/signalling NaN conventions (QEMU
  asserted on the first NaN), tininess after rounding, flags of flushed
  denormals, FCMPEQ/FCMPUN quiet, FTRC flags and NaN result, FSRRA/FSINA/
  FCOSA/FIPR/FTRV flags and FIPR/FTRV accuracy (now accumulate in double),
  PTREL without IADDERR check. Kernel bugs found: no CPU_HAS_FPU (NULL
  xstate cache), restore_fpu with FD set, FPU state never saved on switch
  or fork (child saw zeros), fast TLB miss path clobbering r7-r14/r16-r17/
  r19-r27/r36-r43/r60-r62 (a user loop drifted one byte per page fault),
  fixmap faults outside the handled range (COW copy oopsed). Vector slot
  rule: the TLB miss handler must stay inside VBR+0x400..0x600 or
  trap_init loops forever; bulk code goes in subroutines outside the block.
  Harness pitfalls: register pointers must be sign-extended
  (`(u64)(s64)(long)p`), FP scratch use by gcc in integer code triggers the
  lazy FPU path, raw `.long` encodings for instructions gas lacks
  (FSINA/FCOSA/FSRRA) or refuses (.L shifts with s > 31). Not covered yet:
  exceptions and traps (TRAPA, address errors, FPU enable/exception path),
  privileged instructions (GETCON/PUTCON/GETCFG/PUTCFG, ICBI/OCB* only as
  no-ops), SHcompact.
- 2026-11-03: FPGA core design, up to the bus interface
  (`docs/core-design.md`, `docs/bus-interface.md`, `rtl/`). Documented
  facts used: Vol. 4 (control and configuration registers, MMU and cache
  implementation, LRU encoding, lookup policies, scratch registers for
  SHcompact), Vol. 1 ch. 2, 4-6, 9, 15-18 (state, encodings, memory
  model, events, MMU, caches), Vol. 2 App. A (opcode map), SA Vol. 3 §3.6
  (SuperHyway packet opcodes, fields, critical-word order, byte masks, via
  the DBUS mirror), Hot Chips 13 slides (refetched, checksum matched
  `refs/sources.md`; the PDF itself is still not in the repo). Decisions:
  pipeline F1 F2 D E1 E2 E3 W as documented, 8-byte fetch blocks, one
  2-instruction target buffer per TR, in-order completion, 4-entry store
  buffer, FPU exceptions decided in E1 (the architecture raises O/U/I
  early so no result is needed), SHmedia first with SHcompact as a later
  micro-op expansion using the documented scratch registers. The opcode
  extension table in `rtl/sh5_pkg.sv` is generated from the emulator's
  decode table because the PDF text extraction loses table columns; the
  first hand transcription had errors in 20 of 27 rows. `make -C rtl lint`
  (Verilator) is clean.
- 2026-11-03: core RTL implemented and brought up (`rtl/`, status table in
  `docs/core-design.md` §16). Verification: `tests/isa` bare kit 458064
  checks and `tests/exc` 398 checks pass on the Verilator model; the
  Linux 6.15 boot instruction stream matches QEMU for the first 6 million
  instructions (`tools/tracecmp.py`; register writes with
  `tools/regcmp.py` on `-d exec,nochain,cpu` windows, one-insn-per-tb).
  Bring-up recipe: `make -C rtl/tb/core build`, run a group with
  `--trace`, capture QEMU with `-accel tcg,one-insn-per-tb=on -d
  exec,nochain -D /dev/stdout | head -n N` (uncapped logs fill the disk),
  compare; for register-level diffs capture a window of `-d cpu` dumps
  with awk on the Trace count. Core bugs found that way: missing
  decode-stage kill on a taken branch, store data read before forwarding,
  no target-register write-back forwarding, loads overtaking stores still
  in E3, operands read in D going stale during long holds (now E1 snoops
  the write ports), deadlock between a pending exception and a waiting
  load (stores now enter the queue in E3, loads can issue from E3),
  PUTCON unable to write SR.BL, GETCON USR too early, TRAPA operand
  hazard, STLO.L in the upper word, FPU hazards before issue, 512 MB page
  mask. Linux boot stop found at 4.44 M instructions:
  `sh64_dcache_purge_all` passes a zero-extended address to ALLOCO
  (`(unsigned long long)(unsigned long)` in cache-sh5.c); Vol. 1 6.6.2
  checks ALLOCO like a store, so the core raises WADDERR; QEMU treats
  ALLOCO as a no-op and never noticed. Kernel cast changed to sign
  extension (kernel branch `intern-sh5-revive-20261103`; build with
  `ARCH=sh64`, otherwise Kconfig silently selects a 32-bit SuperH
  configuration). Open question: whether the evaluation chip checked
  ALLOCO addresses at all (the 2003 code ran on hardware).
  With that kernel, Linux 6.15 boots on the RTL model to the smolutils
  shell prompt (init, getty, smolsh) in 191 M cycles; the testbench
  needed the SCIF transmit interrupt (SCR.TIE level) for user-space tty
  output, which the kernel console path does not use.
  tests/exc results on QEMU: 43 deviations from the manual (listed in
  `tests/exc/README.md`), all fixed on the QEMU branch (two commits);
  QEMU still passes the ISA kit and boots NetBSD and Linux.
- 2026-11-03: caches and target-register preload added to the core
  (`rtl/sh5_icache.sv`, `rtl/sh5_dcache.sv`, buffers and prediction in
  `rtl/sh5_core.sv`; §8 and §4.4 of `docs/core-design.md`). Preload shares
  the I-cache port with fetch, is issued from E2 of a PT with the l-bit for
  cachable ITLB hits only, and the response is tagged with the TR number.
  A branch predicted taken in D writes the buffered block into the fetch
  queue; E1 compares the actual next PC with the followed one and
  redirects on a mismatch. The bare tests run with SR.MMU = 0, where
  preload is disabled by design, so only the Linux boot exercises it; the
  testbench summary line now counts predicted-taken branches and
  redirects. `tools/tracecmp.py --irq VEC` skips interrupt handlers that
  the two models enter at different instructions (TMU timing differs);
  with it the Linux 6.15 stream matches QEMU for 5.3 M instructions, up
  to a timer interrupt landing inside a context switch, after which the
  scheduler decisions differ.
  The first cache version served uncached fetches and words one at a
  time through its state machines, which made the MMU-off ISA kit 1.7x
  slower than the cacheless core (fetch had two words in flight before).
  Fixed by passing uncached fetches through the I-cache with two
  outstanding and by fast paths in the operand cache (uncached store
  queued, uncached load issued, in the accept cycle); the arith group
  went from 1.18 M to 0.77 M cycles, the full kit takes 310 M cycles
  (277 M without caches) and the Linux boot 207 M (191 M without caches,
  345 M with the first cache version). `tests/exc` has a new `mmu` test
  (430 checks in total) that maps 512 MB pages, turns the MMU and the
  caches on and checks prediction, preload, TR rewrite, a preload to an
  unmapped page, and code modification with the sequence of Vol. 1 6.7.1;
  QEMU passes it too.
- 2026-11-04: NetBSD 3.1 on the RTL model. Testbench additions
  (`rtl/tb/core/tb_core.cpp`): KSEG0 address translation in the ELF
  loader, the evbsh5 boot-parameter block (600 bytes, layout from
  `sys/arch/evbsh5/include/bootparams.h`) and a symbol-table image after
  the kernel, a stub that sets r2 = load address, r3 = symbol table, r4 =
  end of kernel and jumps to the entry (`evbsh5_init` expects the
  parameters at r4; with r4 elsewhere the kernel uses its defaults, whose
  RB_KDB flag drops into DDB at boot: "Kernel symbol table missing"),
  SCIF receive FIFO with `--expect/--send` console scripting, system FPGA
  registers (BDMR, CPUMR, DATE, INTMR), RTC R64CNT at 128 Hz of an
  assumed 256 MHz clock (the kernel calibrates its delay loop against it,
  `compute_ctc_tick_per_us`). The kernel reaches multi-user (`/etc/rc`
  complete, "Updating motd", date) in a few hours of simulation.
- 2026-11-04: SHcompact test kit `tests/compact` (README there). The
  SH-4 build runs on qemu-system-sh4 (`-M r2d`, built from the sh5 tree:
  `ninja qemu-system-sh4`) and validates the references: 135282 integer
  and memory checks and 29695 FPU checks pass. gcc's `-m5-compact` is the
  SH-5 compact ABI, not SH-4: arguments in r2-r9, libgcc trampolines
  (SHmedia code) for 64-bit arguments, SHmedia libgcc; the kit avoids all
  three. Found in QEMU: SH-4 ROTL/ROTR cleared T (fixed on the qemu branch,
  commit "target/sh4: ROTL and ROTR set T from the rotated bit"), DIV1
  borrow wrong for Rm = 0, FSRRA/FSCA missing, pair FMOV word order, FPU
  denormal and flag deviations (list in the kit README). Vol. 3 text
  extracted with a page-aware script (text kept outside the repo like the
  other volumes).
- 2026-11-04: SHcompact implemented in the core (`rtl/sh5_cexpand.sv`,
  design section 13). Bugs found by the kit on the first runs: DIV1 kept
  bit 31 of the shifted dividend in the 33-bit step; FSUB/FDIV operand
  order; FCNVDS/FCNVSD encodings swapped; conditional branch targets were
  aligned to 4 bytes (SHmedia rule) so BT/BF with odd half-word targets
  landed 2 bytes early; the packed-FPSCR marker used the `likely` field,
  which is bit 9 of every SHmedia GETCON (Rd >= 32). Verilator could not
  handle the first expander (one case per instruction writing a 16-entry
  step array: 10 case items lint in 0.1 s, 40 in 9 s, 204 never finished);
  the two-level form (kind decode, then a case on the kind and step)
  lints in a second.
  Final results on commit f1099f5: `tests/compact` 172323 checks, 0
  failures on the model (207 M cycles); ISA kit 458064/0; `tests/exc`
  430/0; Linux 6.15 boots to the shell (207 M cycles). NetBSD command:
  `./obj/Vsh5_core --elf netbsd-qemu --done "login:" --max-cycles
  8000000000` (kernel from `netbsd/`, md root image embedded); the login
  prompt appeared after 2.34 G cycles, about three hours of simulation.
  Scripted login on the final build (`--expect "login: " --send "root\n"
  --expect "# " --send "uname -a; ps\n" --done "cayman 3.1"`): root logs
  in, csh starts and `uname -a` answers `NetBSD cayman 3.1`; 2.66 G
  cycles, 823 M instructions (`rtl/tb/core/logs/netbsd-console7.txt`).
- 2026-11-05: the card system on fpgaslop (`docs/soc.md`). fpgaslop is a
  submodule (relative URL `../fpgaslop.git`, pinned to its main 3c02d16;
  `git -c protocol.file.allow=always submodule add` is needed for the
  local bare repo). Read first: fpgaslop `docs/notes-for-another-cpu-core.md`,
  `docs/timing-on-this-part.md`, smol68k's `fpga/nitefury/smol68k_board_top.sv`
  and `rtl/soc/smol68k_hostif.sv` (the shape copied here), and the req/ack
  contract (req held until ack, ack one cycle, the slave waits for req to
  fall; `len` = beats - 1 for burst reads; writes single beat because
  burst writes through `mem_cdc` need `wr_ready` pacing). New here:
  `rtl/soc/*` (bridge, peripherals in RTL, hub, host interface, top),
  `rtl/tb/board` (Verilator model of `sh5_top` driven through the host
  protocol), `host/sh5boot.c` (one deposit implementation for the
  testbench and `host/sh5ctl`), `fpga/nitefury/` (board top copied from
  smol68k's with sh5_top inside, build.tcl modelled on theirs, SUBSYSTEM_ID
  0x5a05). `make -C rtl lint-board` runs fpgaslop's lint-top.sh over the
  build script's file list with the Xilinx primitives stubbed and the
  three IP black-boxed: 34 files, 0 warnings. Pitfalls met: Verilator
  compiles a `.c` source as C++ (the header needs `extern "C"` and the
  file explicit casts); the host interface must go from the issue state
  straight to "wait for req to fall" (an extra state missed the one cycle
  the host drops req and hung the second DRAM write); the arbiter's
  `rst` is active high. A 5.5 MB kernel deposit costs 18.5 M simulated
  cycles (about 26 per 64-bit BAR write through hostif, memarb and the
  memory model).
