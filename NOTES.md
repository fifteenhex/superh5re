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
