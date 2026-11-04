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
| `docs/` | Platform notes (`cayman-platform.md`), core microarchitecture (`core-design.md`), bus port (`bus-interface.md`). |
| `refs/` | Source material (manuals) and pointers to external sources. |
| `tools/` | Scripts. |
| `tests/isa/` | SHmedia ISA test kit (nolibc and bare-metal builds). |
| `tests/exc/` | Exception, trap and privileged-state suite (bare metal). |
| `tests/compact/` | SHcompact ISA test kit (SH-5 build for the core, SH-4 build for qemu-system-sh4). |
| `rtl/` | FPGA design: the SH-5 core (SHmedia and SHcompact, caches, MMU, FPU), Verilator testbench with Cayman devices, unit tests. |
