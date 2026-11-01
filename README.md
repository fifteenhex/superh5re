# superh5re

Reverse engineering of the SuperH SH-5 architecture towards an FPGA
implementation.

SH-5 is the 64-bit SuperH architecture (Hitachi / SuperH Inc. /
STMicroelectronics, 2000-2002). It has two instruction sets: SHmedia (32-bit
encodings, 64-bit registers) and SHcompact (SH-4 compatible 16-bit encodings),
selected by the low bit of branch targets. It only reached evaluation silicon
and never shipped in a product.

## Layout

| Path | Contents |
|---|---|
| `NOTES.md` | Journal: findings, decisions, open questions, reproduction steps. |
| `docs/` | ISA tables, encodings, memory map, pipeline notes. |
| `refs/` | Source material (manuals) and pointers to external sources. |
| `tools/` | Scripts. |
| `rtl/` | FPGA design and testbenches. |
