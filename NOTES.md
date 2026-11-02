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
