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
  Board testbench results: tests/exc 430/0 (0.43 M cycles), ISA kit
  arith 5312/0 and branch 16093/0, SHcompact kit branch+sys 822/0; the
  Linux stream matches the core testbench for the first 1.5 M
  instructions. Performance through the bridge is poor: about 14 cycles
  per instruction over that window (every fetch miss and every
  write-back is a serialised req/ack transaction; write-backs are four
  single-beat writes), so the Linux boot that takes 207 M cycles on the
  core testbench needs several times that here and the kernel's first
  console output (which the core testbench does not reach within 60 M
  cycles either) was not seen within the runs made. The full SHcompact
  kit timed out at 400 M cycles with its groups still running. Next
  steps for the memory path: burst write-backs (mem_cdc/req_to_axi4
  support write bursts with wr_ready pacing), a second outstanding
  transaction in the bridge, a fast deposit path for simulation only.
- 2026-11-05: first Vivado runs of the board top, through fpgaslop's
  remote worker (`python3 fpgaslop/vivado/vc.py build --project
  superh5re-board --source <staging dir with fpga/ rtl/ fpgaslop/, no
  rtl/tb> --out out/vivado-remote --tcl fpga/nitefury/build.tcl -v -- 
  -synth_only -build_id <hash>00000000`; `--attach` rejoins; reports land
  in `--out`). Synthesis only, xc7a200t, Vivado 2026.1.
  Run 1 (commit 67af625): 715 k LUTs, 690 k flops, 17 RAMB36, five times
  the part. Every cache array and the hub's 4 KB console FIFO had become
  flops: the arrays were read combinationally in the same cycle as the
  address (hit check from `tag_*[w][idx]` with idx from the request at
  the port), which no block RAM can do. Also two implicit nets
  (`d_redirect`, `e1_redirect` used in the IFU instance above their
  declarations; Verilator accepts forward references, Vivado makes
  1-bit wires; `fpgaslop/tools/checkdecl.py --assign rtl/*.sv` finds them,
  its only other report, `e3_q.ea`, is a struct member).
  Fix (commit f1fb748): `rtl/sh5_ram_sdp.sv`, caches restructured for a
  synchronous read (`docs/core-design.md` §8.1), hub FIFO in its own
  process, GETCFG of a cache array holds E1 (cfg_req/cfg_rvalid), ICBI
  has a ready. Run 2: 88.5 k LUTs (66 %), 49 k flops (18 %), 54 RAMB36 +
  6 RAMB18, 56 DSPs (`docs/soc.md`, "Synthesis"); core-clock paths have
  16 ns slack at 40 ns before placement. sh5_mm then changed from two
  64 x 64 multipliers (the lane operands were sign-extended to 64 bits
  before the multiply) to 33 x 33; not yet synthesised.
  Regression after the cache change: tests/exc 430/0 on both
  testbenches, ISA kit 458064/0 by group (the whole kit needs more than
  the default 200 M cycles: run the groups, or `--max-cycles 400000000`),
  SHcompact kit 172323/0 in exactly the same cycle count (it runs with
  the MMU off, caches unused), board testbench exc + arith.
  A Linux boot on the core testbench then panicked ("Attempted to kill
  init", exit code 0) right after the smolutils init banner; the same
  happened on the previous commit, and the two traces from "Run /init"
  on differ only in a TMU count read (one cycle apart). The cause was
  the command line: init exits unless it is given `-- smolinit.getty=
  /dev/ttySC0 smolinit.hostname=cayman` (`userspace/README.md`). The
  complete core-testbench command is
  `./obj/Vsh5_core --elf <linux-sh5>/vmlinux --initrd <smolutils-sh5>/
  sh-sh5.cpio.gz --cmdline "console=ttySC0 -- smolinit.getty=/dev/ttySC0
  smolinit.hostname=cayman" --done /bin/smolsh --max-cycles 300000000`.
  Earlier the same day the board testbench booted that Linux to the
  getty in 3.13 G cycles (`rtl/tb/board/logs/board-linux-console2.txt`)
  and ran the full SHcompact kit in 1.05 G cycles.
  Full build (commit 8a0aba28, `-build_id 8a0aba2800000000`): bitstream
  in about 15 minutes, every constraint met (post-route 85774 LUTs,
  47399 flops, 53 BRAM tiles, 44 DSPs; 2.5 ns slack on the 40 ns core
  clock, the worst path is 84 % routing). `sh5.bit`, `sh5.bin`, the
  reports and SHA256SUMS were handed over in
  `/workspace/files/superh5re-fpga-8a0aba28/`. The card has not been
  programmed yet (`docs/soc.md`, "Implementation"). superh5re is not on
  the gitolite server, so the work is on origin only.
- 2026-11-06: for the bench day. `host/sh5ctl` grew probe (card page
  decoded), status (core clock measured from the hub's cycle counter),
  peek/poke/memtest, `run ELF --done STR`; order and expected output in
  `docs/soc.md` "Bring-up". The worst core-clock path (2.5 ns slack at
  40 ns) is 39 logic levels from the IFU queue through the SHcompact
  expander and decode to the fetch enable, 31 of its 37 ns routing:
  a faster clock needs a fetch/decode pipeline register, not fanout
  work; left at 25 MHz. Bridge: Store16/32 to RAM are burst writes now
  (fpgaslop carries write bursts since `porting-write-bursts.md`; the
  board top's `wr_ready` takes the crossing's ready, tied high it
  deadlocks). tests/exc gained `cache` (write-back operand cache stress,
  438 checks on QEMU, core and board; its first version taught that OCI
  loses dirty lines and that a non-sign-extended EA in OCBP is an address
  error on the core). Cross compiler: `sh5work/xprefix2/bin` (the one in
  `xprefix` lacks cc1). `qemu-system-sh5` is `qemu-sh5/build/`.
  The Vivado worker went offline on 2026-11-05 15:45 UTC, after the full
  build of 8a0aba28; the build of 9b5a6db6 (write bursts) could not be
  started. The handed-over bitstream is 8a0aba28 and is self-consistent
  (single-beat writes, wr_ready tied high); `host/sh5ctl` from master
  works with it. Rebuild when the worker is back:
  `python3 fpgaslop/vivado/vc.py build --project superh5re-board --source
  /tmp/sh5build --out out/vivado-full2 --tcl fpga/nitefury/build.tcl -v
  -- -build_id <hash>00000000` (staging: `rsync -a --exclude .git
  --exclude tb --exclude obj --exclude logs fpga rtl fpgaslop
  /tmp/sh5build/`). `host/bringup.sh <bdf>` runs the first-day sequence.
  Board testbench, single-beat writes: NetBSD to root login and `uname -a`
  in 1.77 G cycles (`rtl/tb/board/logs/board-netbsd-console.txt`). Two
  Linux boots (with and without write bursts) were cycle-identical, which
  led to the kernel config: `CONFIG_CACHE_OFF=y`. Every Linux run so far
  (207 M cycles on the core testbench, 3.13 G through the board) ran with
  both caches off; only tests/exc and NetBSD have exercised them. Rebuilt
  with `CONFIG_CACHE_WRITEBACK=y` (`linux-sh5/vmlinux-wb`; the old image
  kept as `vmlinux-cacheoff`, `config-cacheoff`): boots on QEMU, and on
  the core testbench to the shell in 195.6 M cycles (bus latency 1 there,
  so little gain); the board run is the one that matters. Handed over as
  `/workspace/files/superh5re-linux-wb/` with the boot command. The
  smolutils shell drops input typed before its first prompt, and its
  `uname` takes no options.
  Board testbench with the write-back kernel: shell prompt 314 M cycles
  after release, 9.58 M memory transactions (cache-off kernel: 3.13 G
  cycles, 262 M transactions); 12.6 s at 25 MHz on the card.
  The same boot through the pre-burst bridge (commit 75448e8): 332.6 M
  cycles, 11.26 M transactions; the write bursts are worth 5.5 % of the
  cycles and 15 % of the transactions.

- 2026-11-07: first day on the card (NiteFury II in `epyc`, account
  `clanker`, J-Link EDU Mini on the JTAG header, OpenOCD 0.12; the
  staging tree is `~clanker/sh5/`: host/, tests/, openocd/ (fpgaslop's
  flash.sh), bitstream*/, linux/). The proxy bitstream
  `bscan_spi_xc7a200t.bit` was fetched into `~/.cache/fpgaslop/`.
  Flash procedure that worked: `flash.sh detect`, `flash.sh sram`,
  `flash.sh backup` (16 MB of the previous design kept in
  `~clanker/sh5/flash-backup-20261107.bin`), `flash.sh image sh5.bin`.
  No cold power cycle was needed: `flash.sh reboot` (PROGRAM_B, the FPGA
  reconfigures from flash) followed by `echo 1 > /sys/bus/pci/devices/
  0000:41:00.0/remove; echo 1 > /sys/bus/pci/rescan` re-enumerated the
  card with the new subsystem id (0x5a05) on this AMD platform; the
  fpgaslop warning about JTAG loads not enumerating is about SRAM loads.
  Results with 8a0aba28: probe correct (FPGASLOP, superh5, build id,
  DDR3 calibrated), core clock measured 25.000 MHz from the hub's cycle
  counter, memtest 1 MB passed (12.5 MB/s write, 2.4 MB/s read through
  the BAR). tests/exc: no console output, bus error flagged.
  Debugging without visibility: poked hand-assembled programs into DRAM
  (`sh5ctl poke`, `release <pc>`), used the card page's completed
  read/write counters (slop_id WR_COUNT = {wr_done, rd_done} of
  req_to_axi4) as the only instrumentation: an uncached loop fetches at
  1.39 M reads/s (one per 18 cycles) with no error; any load or store,
  to RAM or to the SCIF, sets the bus-error bit and lands nowhere.
  Built 6700d74a with hub debug registers (0x040..0x070: last request,
  first failing request, counts, last response, retired PC/insn;
  `sh5ctl dbg`): the failing requests were Load8/Store8 with the right
  opcode and mask and ADDRESS 0; a `beq r2, r63` eight instructions
  after `movi 1, r2` was taken. Every general register read as zero.
  Cause in the Vivado log: `gr_q` written twice in one process (W stage
  and FPU completion) -> "Trying to implement RAM 'gr_q_reg' in
  registers ... multiple writes via different ports in same process",
  then "Net p_0_out in module/entity sh5_core does not have driver".
  Verilator accepted the code. Fix e9d9aaa4: per-register write enable
  and value from both ports in combinational logic, flops written once.
  Lesson: grep every Vivado log for "does not have driver" and
  "Synth 8-4767" on our own files; `tests/exc` would have caught this in
  a gate-level simulation, which we do not have.
  With e9d9aaa4 (the register-file fix): tests/exc 438/0 in 0.1 s, ISA
  kit 458064/0 in 98 s (2.44 G cycles), SHcompact kit 172323/0 in 63 s,
  Linux (write-back kernel) to the shell in 25 s / 621 M cycles,
  `cat /proc/cpuinfo` and `ls /bin` typed through the hub. NetBSD then
  deposited after Linux printed nothing for 600 s: the PC histogram
  (300 samples of hub register 0x060 mapped with nm) was putchar/
  kprintf/cnputc plus the interrupt entry and printf: stray interrupts
  from the TMU/INTC state Linux left behind, because reset_hold reset
  only the core. Fixed in RTL (b458b6c6: peripherals and bridge share
  the core's reset) and in the tool (soft reset before a deposit; the
  hub's transmit FIFO is drained too, it is not reset by either).
  NetBSD then booted to `login:` in about 75 s but did not take the
  typed login: getty flushes input when it prints the prompt (type
  after 0.2 s of quiet), and NetBSD's scif driver (sys/arch/sh5/dev/
  scif.c) masks the FIFO count with 0x0f (16 bytes read as 0 and its
  handler spins without draining) and pops one byte more than the count
  it read (lost when a byte arrived during the handler). Typing in
  bursts below the 14-byte trigger with the FIFO drained in between
  avoids both; NetBSD logs in, `uname -a`, `ps`, `df` in 82 s. Final
  bitstream of the day b458b6c6, in the card's flash and in
  `/workspace/files/superh5re-fpga-b458b6c6/`; transcripts
  `logs/fpga-linux.txt`, `logs/fpga-netbsd.txt`.

- 2026-11-08: the three follow-ups after the first boots. (1) The gate:
  `build.tcl` turns Synth 8-11241 and Synth 8-3848 on our files into
  errors, `fpga/nitefury/checklog.py` reads a finished log for those and
  for Synth 8-4767 "multiple writes" (3 findings in the two bad logs of
  the week, none in the good ones), `host/check-card.sh` runs probe,
  memtest, exc, both kits, Linux and NetBSD on the card against their
  expected lines (7/7, 4.5 min; run it under sudo over a session without
  a terminal). (2) Speed. Post-route the 40 worst core paths all started
  at the IFU's queue pointer: fetch word -> SHcompact expander -> decoder
  -> issue -> fetch enable. Synth-only at 50 MHz (`-core_div 20
  -synth_only`): WNS -2.79 ns, 1037 failing endpoints. Decode split into
  D1/D2 (uop register): WNS -1.75, 567 endpoints, next path the TMU/INTC
  registers through the interrupt acceptance into issue; the interrupt
  inputs are now registered in the core. The split's first version lost
  1025 SHcompact checks: D1 decoded the instruction after FSCHG/FRCHG
  with the old SR.FR/SZ (the single-stage decoder decoded at issue time,
  after W); D1 now waits while a serialising uop issues or is in flight.
  Costs: +13 % cycles on tests/exc, +6 % on the Linux boot (one cycle per
  redirect). `rtl/soc/sh5_mem_cdc.sv` + `sh5_afifo.sv` replace mem_cdc in
  the board top; `rtl/tb/cdc` (fpgaslop's memchain harness shape, 4:1
  clocks, random traffic on both arbiter ports against a model): 4-beat
  write-back acked in 8 core cycles, 4-beat line fill in 15 at a 12-cycle
  controller latency. Two harness lessons: a_ack must be a registered
  one-cycle pulse (everything samples it after the edge), and the slave
  must not wait for req to fall after the last ack, because memarb holds
  m_req from its own registers until it has sampled that ack and a fast
  master never shows a low cycle through it.
  50 MHz: 0183b335 built with `-core_div 20` met timing after routing
  (WNS 0.27 ns, WHS 0.05 ns) and runs on the card at a measured
  49.999 MHz, check-card 7/7: Linux to the shell 12 s, NetBSD to login
  42 s, ISA kit 77 s (3.85 G cycles: the uncached kits are memory-latency
  bound and gain only a fifth). 50 MHz is build.tcl's default now. The
  longest core path at 50 MHz is the FPU's operand classification carry
  chain (`pass_r`).
  Toolchain groundwork (the user wants the SHmedia backend revived so a
  newer Linux can be built): gcc and binutils are cloned on the bench
  machine under `~/src/`. The removals to revert, in order: binutils
  211dc24b874 "Remove sh5 and sh64 support" (2018-04-16, binutils 2.31),
  gdb 8a3de5e1a3f (same day), fad3d2c1b26 "Remove SH-5 remnants"
  (2020-04-21), f8cab0b9958 "sim: sh64: delete port" (2021-01-09); GCC's
  was a 2016 series by Oleg Endo on gcc/config/sh (34d5fe774e8 "Remove
  SH5 target regs", e1fab8ba233 "sh-common.c: Remove SH5 support",
  9129c8cfcd8 crt1.S, bc6d901463c config.guess, af95276348b longlong.h,
  99dec205a12 divtab, and the main sh.c/sh.md cleanup before them in
  GCC 7). Plan: binutils first (revert on a branch at the removal commit,
  build, assemble tests/isa, then walk forward release by release), then
  GCC the same way, starting from the last GCC 6 tree we already build
  with. Needed on the bench machine: flex bison texinfo gawk libgmp-dev
  libmpfr-dev libmpc-dev libisl-dev zlib1g-dev libzstd-dev autoconf
  automake libtool gettext rsync tmux.
  The sandbox has 7 GB of memory: eight parallel Verilator core runs plus
  two board runs and a Verilator build got the container killed. One
  board-model Linux boot at a time (about 40 minutes), and the core
  groups in batches of three or four.
  virtio-blk (task 3): fpgaslop's slop_virtio_slots in sh5_top at
  0x0b00_0000 (guest) / register window +0x2_0000 (host), interrupt on
  INTC source 63; `host/sh5blk.c` serves a file over fpgaslop's
  slop_virtq/slop_vmmio; `--disk IMG` in the board testbench and sh5ctl.
  Kernel: CONFIG_VIRTIO_MMIO, VIRTIO_BLK, VIRTIO_MMIO_CMDLINE_DEVICES
  (`vmlinux-vio`), command line `virtio_mmio.device=0x200@0x0b000000:63`.
  First simulation: the transport registers, but the device read as
  DeviceID 0 because the transport sat in the reset_hold group and the
  host presents the identity while the core is held -> the transport is
  reset by the soft reset only. Second: `virtio_blk virtio0: [vda] 16384
  512-byte logical blocks`, driver status 0xf, queue 0 ready (desc
  0x812aa000 avail 0x812aa100 used 0x812ab000), then nothing: no request
  ever appears in the ring as the host reads it (SH5BLK_DEBUG=1 traces).
  The ext2 image is `mke2fs -d` on the bench machine (there is no mke2fs
  in the sandbox).
  Found with a trace of every guest access to the transport (`+viotrace`
  in the board testbench): the guest kicked (QueueNotify) at cycle 297 M,
  but the host saw avail idx 1 only at cycle 428 M, and after the host
  served the request and raised the interrupt the guest acknowledged it
  (InterruptStatus read 1, ACK written) and went idle for good. The ring
  was in cached memory: the device did not offer VIRTIO_F_ACCESS_PLATFORM
  (bit 33), and without it Linux assumes a cache-coherent device and does
  not use the DMA API (vring_use_dma_api). sh5blk now sets bit 33 after
  slop_vmmio_present; the driver accepts 0x3_00000200, the first request
  is served at once and the kernel reaches the shell in 347 M cycles.
  Then two test-script facts: smolsh's mkdir has no `-p` and the shell
  stops at the first failing command of a line; the getty shell is an
  unprivileged user (getty.c users_changeuser), so `su` first, otherwise
  mount fails with EPERM.
  Housekeeping: the container was OOM-killed (the sim and the vc.py
  client died; the Vivado worker went offline at 12:05 UTC in the middle
  of the virtio build, job j1794049124832, its retained status still
  says running). The work disk was full: a `+viotrace` run that also
  printed the host's polling reads wrote 180 MB in ten minutes; old
  out/vivado-* trees, core TB traces and the NetBSD object tree deleted
  (2 GB free). The trace prints host writes only now.
- 2026-11-07, toolchain (subagent on the bench machine, journal in
  `~/src/TOOLCHAIN-NOTES.md` there): binutils branch
  `intern-sh64-revive-20261107` (sh64 restored; gas GOT relocation
  renumbering fixed, output identical to 2.30 on libgcc's crt). GCC branch
  `intern-sh64-gcc-base-20261107` is the pre-removal 2016 tree plus the
  `sh_legitimate_constant_p` fix: a working sh64-linux compiler. GCC branch
  `intern-sh64-gcc-revive-20261107` is master with the removal reverted
  and the backend adapted: cc1 and libgcc build (C, no multilib), exc kit
  438/0 and ISA kit 458064/0 under qemu, SHcompact kit compiles (the sh4
  build's 37 rotl/rotr failures match the GCC 6.5 build), sh4-linux output
  identical to master on 3922 testsuite files. The sh64 kernel
  (48449896407a, write-back config) built with it boots to the smolutils
  shell in qemu. Kernel fixes for newer GCC (access_ok casts in
  traps_64.c, __kernel_ssize_t/__kernel_ptrdiff_t in posix_types_64.h,
  a fallthrough, four prototypes) are linux branch
  `intern-sh5-newgcc-20261107` (da73afb87709, 7 commits on 48449896407a);
  the kernel then builds with 0 errors and 28 warnings (19 missing
  prototypes that need header work, the clone3 #warning, two generic
  -Wconstant-logical-operand) and boots in qemu. The bench key cannot
  read linux.git on gitolite, so that branch was pushed from the sandbox.
  Heads: binutils base 4db9937a274 / revive 3871bac4d2d, gcc base
  ce91dc85be5 / revive d360b9bafc8. Build scripts on the bench:
  `~/build/build-revive.sh` (binutils), `~/build/build-gcc-revive.sh
  configure libgcc` (into `~/toolchain/gcc-sh64-revive`),
  `~/kernel/build-kernel.sh`, `~/build/final-tests.sh`. The bench still
  needs `bc` (a stand-in answers only HZ=250).
  MEXTR: Vol. 2 pp. 200-206 give (Rm >> 8k) | (Rn << 8(8-k)), which is
  what the kit, `rtl/sh5_mm.sv` and GCC implement; qemu-sh5 and the
  binutils cgen description (`cpu/sh64-media.cpu`) have k and 8-k
  swapped. The kit's `ref_mextr` compiles to mextr itself, so the kit
  cannot see that bug; build the reference at -O0 to make it a test.
  Manuals: the SH-5 Common Assembly Language Syntax (05-ASM-10001) from
  the user, the ABI and System Architecture volumes from
  larsbrinkhoff/awesome-cpus, all under `refs/manuals/`.
  Host MSI: the virtio kick goes to sh5_hostif and slop_card's mailbox
  path (IRQEN at window +0xB8, clear at reset), the board top has
  fpgaslop's msi_req into the endpoint's INTX_MSI_Request/Grant, CAPS has
  CAP_MSI. Board testbench with the disk: 9 requests, 9 interrupt pulses
  on sh5_top.msi, mount/cat/ls unchanged. On the card it needs the
  fpgaslop kernel module with msi=1 (not on the bench machine); sh5ctl
  polls. The PCIe IP keeps MSI_DECODE_ENABLED false (dmaslop sets it with
  the bus-mastering settings; untested here whether the endpoint needs it
  for INTX_MSI_Request).
- 2026-11-08: the Vivado worker came back at 23:07 UTC. The build of
  cb8f4b2 failed the Synth 8-11241 gate (vio_kick used in the hostif
  instance before its declaration; Verilator accepts that) -> 0af65334,
  declaration hoisted, checkdecl clean. 0af65334: 0 gate findings, but
  timing NOT met by 0.30 ns (20 endpoints, dcache tag RAM -> wb_data_q,
  FPU term_r -> al_r, 16 ns of routing in a 20 ns path). Flashed anyway
  (`flash.sh image`, `flash.sh reboot`, PCI remove + rescan): probe shows
  caps DRAM MSI CPU RESET, check-card 8/8 including the new disk step
  (Linux mounts the virtio disk, 13.4 s). Hand-over in
  files/superh5re-fpga-0af65334-50mhz-virtio. A `-effort high` build of
  the same sources (build id ...00000001) is running for the timing.
  MEXTR: the kit's ref_mextr now has an empty asm on one half so GCC
  cannot fold it into mextr (the toolchain subagent's patch); under qemu
  18230 checks failed (mextr1/2/3/5/6/7), on the card 458064/0, so the
  RTL agrees with the manual. qemu fixed (target/sh5/op_helper.c, shift
  counts n and 8-n swapped), kit 458064/0 under qemu; pushed on qemu's
  intern-sh5-20261102 (532517057a).
  Toolchain final round (subagent): kernel branch intern-sh5-newgcc-20261107
  at ca91592ba424 builds with only the clone3 #warning and two generic
  warnings; gcc revive at 24b7088701b (leaf r18 save, one stack
  adjustment); binutils revive at 9dc736aec34 (sh64elf.em %F crash fixed,
  testsuite exceptions: gas 521/0, ld 862/2 (pr20995, fails for all SH),
  binutils 250/0). bc installed on the bench.
  The `-effort high` build of 0af65334 (id ...00000001) met timing (worst
  core slack 0.134 ns, 0 gate findings), flashed; check-card 8/8 again
  (exc 1.65 M cycles, ISA 77 s, compact 51 s, Linux 12.3 s, disk 13.4 s,
  NetBSD 41.6 s). It is the bitstream in flash and in the hand-over dir.
  MSI on the card: not exercised, and not just for lack of time. The
  bench machine has no kernel headers (no /lib/modules/<rel>/build), so
  fpgaslop.ko cannot be built there; the module's kick ioctl and poll()
  need CAP_MAILBOX, which sh5_hostif does not set (the kick reaches
  h_msi through the mailbox block but the mailbox data path is not wired
  to the core); and fpgaslop's kmod README records three hard lockups
  (HyperTransport sync flood) of an AMD host from interrupts the driver
  could not clear. Enabling IRQEN with no driver bound would raise an
  unclaimed interrupt on the user's server. Decision for the user:
  install linux-headers, add CAP_MAILBOX (or a kick-count ioctl without
  it) and accept the risk, or leave the MSI masked and polled.
  User decision 2026-11-08: leave the host MSI advertised and masked, the
  host polls; task 3 closed with virtio-blk verified on the card.
  2026-11-08: the bench key can read and push linux.git on gitolite now.
  The bench kernel tree (~/kernel/linux-sh5, previously a git-archive
  import with no shared history) is on intern-sh5-newgcc-20261107
  tracking gitolite (ca91592ba424, identical tree); kernel work can be
  pushed from the bench machine directly.
- 2026-11-08, goal: SH-4 static busybox, then a Debian sh4 userspace, on
  the SH-5 system. Findings: the core is not the obstacle (SHcompact is
  the SH-4 user ISA; compact state = R0-R15, GBR R16, MAC R17, PR R18, T
  R19 of the SHmedia file, ISA by PC bit 0); the sh64 kernel is: it forces
  SHmedia in start_thread, accepts only the sh64 trapa encoding
  (TRA 0x1yzzzz), builds SH-5 signal frames, and traps_64.c says user
  SHcompact is unsupported. A subagent adds the sh32 user ABI on linux
  branch intern-sh5-shcompact-20261108 (ELF-flag detection, r3/r4-r7,r0,r1
  trapa #0x10 convention, sh32 sigframes with stack trampoline, gUSA
  restart, uapi audit), tested with hand-built -m5-compact programs on
  the card (qemu-sh5 has no SHcompact mode). Target binary downloaded with
  permission: Debian unstable busybox-static 1:1.38.0-3 sh4
  (pool-sh4/main/b/busybox/busybox-static_1.38.0-3_sh4.deb, sha256
  5ece2e489cd2d9f9b7fc29987c549fda1c8d319b0ce0203635d565df19ac45f5):
  static glibc, ELF32 EM_SH e_flags 0x17 (sh2a-or-sh4), PT_TLS (GBR thread
  pointer, 1439 stc gbr), syscalls `mov.l const,r3; trapa #16..#21`, about
  520 gUSA sequences (mov #-8,r15 ...), 914 mac.l, no FTRV/FIPR/movli.
  The user debootstraps Debian sh4 into a directory on the bench machine;
  the plan is mke2fs -d into an image served by sh5ctl --disk, with the
  second debootstrap stage run on the card.
  Debian sh4 stage 1 on the bench machine (one sudo, granted by the user
  after their own attempt failed; /usr/sbin is not in the user's PATH,
  which may have been why): `debootstrap --foreign --arch=sh4
  --variant=minbase --keyring=debian-ports-archive-keyring.gpg
  --include=debian-ports-archive-keyring,busybox-static unstable
  ~/debian-sh4 http://deb.debian.org/debian-ports`, 81 packages, then
  `mke2fs -t ext2 -L debsh4 -d ~/debian-sh4 ~/sh5/disk/debian-sh4.ext2 1G`
  (236 MB used; /debootstrap/debootstrap for the second stage, 69 .debs in
  /var/cache/apt/archives). Log: ~/debootstrap-sh4.log on the bench.
  Milestone 1 reached by the kernel subagent: Debian's sh4 busybox-static
  runs as init with a shell on the card (linux branch
  intern-sh5-shcompact-20261108, head 321af6d52864: sh32 user ABI keyed on
  the ELF machine flags, separate sh32 syscall table, sh32 signal frames
  with stack trampoline, gUSA restart, plus fixes to old sh64 bugs: a TLB
  flush that never matched kernel addresses (COW corruption, also for
  SHmedia), an icache flush with an end address as length, icache
  invalidate skipping the first line, FPU state around signals). Two RTL
  bugs it found, fixed here: RTE dropped SPC bit 1 (sh5_ctrl.sv), TEA of a
  fetch fault in an SHcompact delay slot was the branch's address
  (sh5_core.sv, uop.slot). The compact kit's exception entry had never
  been exercised: SR.BL left set (panic to RESVEC 0) and CMVEQ with the
  wrong sense; fixed, and `sys` gained TRAPA-return tests (the 0 mod 4
  TRAPA hangs the unfixed RTL). exc kit 438/0 and compact sys 634/0 on
  the core TB. The kernel keeps its two workarounds
  (CONFIG_SH64_COMPACT_RTE_STUB, CONFIG_SH64_COMPACT_SLOT_ITLB) until the
  bitstream with the fixes is on the card.
  f0c9c857 built with -effort high in 45 min (worker idle): timing met
  (0.116 ns), 0 gate findings, flashed; check-card 8/8 (compact kit now
  172328 checks; check-card.sh updated). sh5blk bug found by the Debian
  stage: Linux (no SIZE_MAX/SEG_MAX offered) sent reads up to 1280 KB,
  sh5blk rejected > 64 KB with IOERR and pushed the 1-byte status from the
  start of the writable area, so the status descriptor stayed 0 (OK) and
  the guest took unfilled memory for data (190 of 388 blocks of libc.so.6
  wrong). Fixed: reply = whole writable area (zeros on error) with the
  status last, buffer grown per request, size_max 64 KB and seg_max 14 in
  the config space with the feature bits. The card's disk step passes with
  it; the kernel subagent's max_sectors_kb=32 workaround is obsolete.
  Debian stage status from the subagent: dynamic binaries (dash, ls, dpkg,
  perl, bash) run; a pte_special() fix was needed (kernel b708e1cc4931);
  the second debootstrap stage hung after "Installing core packages" once
  (under investigation with a watchdog, and now with the fixed device).
  Proof of the RTL fixes on the card (subagent, bitstream f0c9c857, kernel
  with CONFIG_SH64_COMPACT_RTE_STUB and CONFIG_SH64_COMPACT_SLOT_ITLB off):
  ctest/ctest-nx ALL PASSED (store fault resumes at the faulting
  instruction 24/24, gUSA 600000/600000, COW/fork stress, signals, TLS),
  busybox signal scripts all OK including the pattern that spun forever
  through the delay-slot TEA bug, no [compact_stub] mapping. The kernel
  options default to n from here (kept for older bitstreams).
  Debian second stage (subagent, card): dynamic binaries run (dash, ls,
  bash, perl, dpkg, dpkg-deb, dpkg -i); more old sh64 kernel bugs found
  by it and pushed on the branch: pte_special() returned a non-boolean
  (b708e1cc4931); non-present PTEs (glibc's MADV_GUARD_INSTALL markers)
  were loaded as valid no-access DTLB entries (9fa61ba0d07a);
  flush_cache_range never invalidated the user icache (8e5dc650daa7);
  local_flush_tlb_page used the running ASID instead of the vma mm's, so
  kcompactd page migration corrupted other processes (b3c4c5678f3a);
  local_flush_tlb_one stopped at the first matching slot (961d7549c16e).
  Open: a second-stage run hangs in `rm` in an endless minor-fault loop
  (90 M faults, disk untouched for hours) after base-files, base-passwd,
  dpkg, libc6 and perl-base are configured; under investigation with a
  fault-loop debug patch. The passive monitor replaced a watchdog that
  killed dash's legitimately CPU-bound read loops.
  Debian second stage, round 3: the instrumented run reached 31 packages
  ("Unpacking the base system") before the subagent's own 7800 s timeout;
  the rm fault loop did not recur (intermittent). Random SIGSEGVs in
  dpkg-deb, dpkg and dash (PC 0, PR 0, sane positive SPs: not a missed
  gUSA restart) point at data corruption. Hardware fact relevant to it:
  the operand cache is indexed by EA[12:5] and the PA alias check covers
  only the set the EA selects, so two mappings of one physical page that
  differ in virtual bit 12 hold two independent copies (SH-5 nsynbits = 1,
  Vol. 4 §8.4); the kernel must copy/clear user pages through coloured
  mappings and purge after kernel-alias writes (cache-sh5.c). Suspect:
  page migration (folio_copy through the kernel alias, PG_dcache_clean
  carried to the new folio, so no purge). Experiment handed to the
  subagent: CONFIG_COMPACTION=n / CONFIG_MIGRATION=n.
  Second stage completed by hand (subagent, 2026-11-09 08:27 bench time):
  `dpkg --unpack` of the remaining base .debs then `dpkg --configure -a`
  returned 0; `dpkg -l` lists 78 installed packages. One failure:
  util-linux_2.41.3-4 (dpkg-deb's xz child died with SIGSEGV, the
  intermittent corruption) is not installed. The subagent's wrapper
  for the card runs is ~/bin/card-sh5ctl.sh in the sandbox; its first
  version re-parsed the arguments in a second shell (`sudo bash -c`),
  which turned "\n" into "n"; it now runs sudo ./sh5ctl directly.
  Milestone 2 evidence on the card (bitstream f0c9c857, kernel
  961d7549c16e, no workarounds): chroot from the rescue initrd into the
  Debian root: /etc/debian_version forky/sid, dpkg -l 78 ii, apt 3.3.7
  (sh4), ldd /bin/ls through /lib/ld-linux.so.2, bash; transcript
  logs/fpga-debian-sh4.txt (40 s, 2.0 G cycles). Open: util-linux, the
  intermittent corruption (compaction/migration experiment), a direct
  root=/dev/vda boot without the rescue initrd.
  Root-cause candidate for the intermittent corruption (2026-11-09): the
  subagent's instrumentation shows it correlates with ASID wraps (8-bit
  ASIDs, hundreds of wraps per stress round). At a wrap get_mmu_context()
  calls flush_cache_all(); sh64's sh64_dcache_purge_sets() purges by one
  ALLOCO per way per set on dummy_alloco_area and leaves the dummy lines
  resident. The RTL (and Vol. 2: ALLOCO is a hint) allocates only when
  the block is neither an EA nor a PA hit, so later purges evict nothing
  in sets whose dummy lines are still present; stale EA+ASID-tagged user
  lines (an EA hit needs no PA check) survive and a process with the
  recycled ASID reads them at the same EA (ld.so at 0x2aaa0000). Fix
  proposed to the subagent: OCBI/OCBP the dummy lines after the sweep.
  Stress numbers: baseline kernel 1 bad decompression in 12 (dst3),
  a modified kernel 0 in 8 (dst4).
  The subagent confirms the fit: dst3 (clean head) had one burst at
  kernel time 4115 s where sha256sum (SIGILL), memstress and cmp died at
  once, then nothing; dst4 (head + a printk per ASID wrap) 0 bad in 10
  with 500 wraps so far. The no-op purge also hits flush_cache_mm at
  exit/munmap, so dead dirty lines are written back later into pages
  reallocated to other processes (code pages included): that is the
  burst. Fix in progress: OCBI the dummy lines after the ALLOCO sweep in
  sh64_dcache_purge_sets(); the icache path uses ICCR0.ICI and is fine.
  Fix committed on the kernel branch: 5e89d4b54a0a "sh: sh64: invalidate
  the dummy lines after the D-cache purge sweep" (OCBI after the ALLOCO
  sweep; passes cowm and ctest-nx). The Debian image used for the stress
  runs is corrupt (ext2, about 950 fsck findings: runs killed mid-write
  plus the purge bug), so the full second stage is being rerun from the
  pristine stage-1 copy on the fixed kernel as the validation; then a
  fork/exec storm and dstress against tmpfs, then the direct root boot.
  Console garbling and the "ring unusable" of 2026-11-09 explained: two
  sh5ctl processes on the card at once (the subagent started ul1/ds7
  while its dst4 stress was still running; my checks used `tail -1` and
  saw one). Each drained every other console byte ("Spr HSIF rvriiilzd"
  = even positions only), both served the virtqueue and wrote the ext2
  image (hence the 950 fsck findings). The OCBI kernel is exonerated: an
  A/B boot of 961d754 and the OCBI build with the same initrd prints the
  same clean console. sh5ctl now takes an exclusive flock on
  /tmp/sh5ctl-<bdf>.lock, and card-sh5ctl.sh refuses to start while an
  sh5ctl runs on the bench.
  Validation run of the second stage on 5e89d4b (2026-11-09 18:00 bench
  time, one sh5ctl, clean image): one dpkg-deb SIGSEGV (TEA f0037008) at
  "Unpacking passwd", then at "Unpacking tzdata" the disk stopped changing
  for 45 min while the core ran 24 M instructions/s in the kernel; 26 PC
  samples through `sh5ctl dbg` (which no longer takes the lock: only run,
  boot and console do) resolve to handle_mm_fault, mt_find,
  lock_mm_and_find_vma, do_page_fault, ptep_set_access_flags,
  restore_user: the same fault loop as the earlier rm case, so the purge
  fix is not the whole story. RTL facts for it: the TLB lookup takes the
  lowest-index matching slot when two match; the protection check uses
  the TLB's bits, not the cache tag copies. Next: the subagent's stashed
  fault-loop report (fault.c, tlbex_64.c fast-fail counters) built into
  the vio kernel and the second stage rerun to catch the loop's PTE, vma,
  ASID and DTLB contents.
- 2026-11-11: the kernel subagent's run ended at the usage limit; its final
  report is in its transcript and ~/src/TOOLCHAIN-NOTES.md on the bench
  (17 commits on intern-sh5-shcompact-20261108 up to 5e89d4b54a0a, test
  matrix, open items). Its last finding, confirmed by my PC samples: a
  protection exception is raised while a TLB entry matches, so the entry
  stays loaded; when the PTE already allows the access handle_mm_fault()
  changes nothing and loads nothing, and the access faults forever (the
  rm/dpkg-deb/tzdata loops). Two kernel commits from here, pushed:
  fbae1660dc2c (__update_tlb flushes the page's older entries before
  loading, the TLB takes the lowest matching slot) and 806f95f2b6a0
  (do_page_fault drops the page's entries for the ASID before handling a
  user fault). The instrumented second stage on 5e89d4b crashed
  debootstrap itself (rc 139) after 5 fatal signals in dpkg/dash with
  recurring TEA f0037008 and kernel-looking register values; the rerun on
  806f95f2 has a user-fault MMU dump (PTE, vma, matching DTLB/ITLB slots)
  as an uncommitted debug patch.
