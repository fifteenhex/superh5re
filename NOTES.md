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
