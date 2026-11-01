# SH-5 source material

## SuperH, Inc. document catalogue

From the SuperH, Inc. website documentation pages as archived by the Wayback
Machine (`web.archive.org`, superh.com/documentation/documents.php, snapshots
2004-02-14, 2004-08-26, 2006-03-21). Downloads required registration and were
not archived. Sizes in bytes as listed there.

| Title | Original file | Ver | Size | Held |
|---|---|---|---|---|
| SH-5 Common Assembly Language Syntax (05-ASM-10001) | sh5_asm.pdf | 1.0 | 117,520 | no (Yumpu 37195248, 9 pp) |
| SH-5 CPU Core, Volume 1: Architecture (05-CC-10001) | cpush5v1.pdf | 1.0 | 4,165,615 | yes, identical size |
| SH-5 CPU Core, Volume 2: SHmedia (05-CC-10002) | cpush5v2.pdf | 1.0 | 4,445,599 | yes, identical size |
| SH-5 CPU Core, Volume 3: SHcompact (05-CC-10003) | cpush5v3.pdf | 1.0 | 2,560,241 | yes, identical size |
| SH-5 CPU Core, Volume 4: Implementation (05-CC-10004) | cpush5v4.pdf | 1.0 | 1,255,758 | yes, identical size |
| SH-5 Evaluation Device Datasheet, a.k.a. SH5-103 Evaluation Device Datasheet (05-DS-10003) | 05-DS-10003.pdf | 1.0 | 1,704,865 | no |
| SH-5 General and C Specific ABI | sh5_abi.pdf | 1.0 | 318,179 | no |
| SH-5 System Architecture Volume 1: System (05-SA-10001) | sysv1.pdf | 1.0 | 4,311,511 | no (Yumpu 47837579, 344 pp) |
| SH-5 System Architecture Volume 2: Peripherals (05-SA-10002) | sysv2.pdf | 1.0 | 2,766,204 | no |
| SH-5 System Architecture Volume 3: Debug (05-SA-10003) | sysv3.pdf | 1.0 | 3,553,353 | yes, different rendering (9,810,393 bytes, PDF 1.7) |
| SH5-100 Series Core Datasheet (05-DS-10001) | 05-DS-10001.pdf | 1.2 | 201,874 | no |
| SH-5 Product Brief | sh_5_prod_brief.pdf | 2.0 | 988,328 | no |
| SH-5 DivX MPEG4 Demonstration | SH5-000-TOP-PRD-00001.pdf | 2.2 | 298,893 | no |
| SuperHyway Type 1 Transaction and Interface Definition | SH4-202-SHY-DEO-00026.pdf | 1.2 | 481,538 | no |
| SuperHyway Type 2 Transaction and Interface Definition | SH4-202-SHY-DEO-00027.pdf | 1.3 | 709,825 | no |
| SuperHyway Type 3 Transaction and Interface Definition | SH4-202-SHY-DEO-00028.pdf | 1.1 | 818,654 | no |

Technical papers/presentations listed on the same site (none held): debug_sh5.pdf
"Debug support on SH-5 CPU cores", mpeg4.pdf "MPEG4 codec on SH-5", fpu.pdf
"1.9 GFLOPS: screaming FPU", epf_superh_final.pdf "Compiler support for 8-way
SIMD instructions in the SH-5 CPU" (EPF 2003), SIMD_MPEG4.pdf, SH-5_benchmark.pdf
"SH-5 high performance media processing", gcc_vector_extensions.pdf.

Yumpu (user lars.nocrew.org, uploaded 2015-02-25) has flipbook copies of CPU
Core volumes 1, 2, 4, System Architecture volumes 1 and 3, and the assembly
syntax document. No PDF download; page images are served from img.yumpu.com.

## Published papers

| Item | Location | Held locally |
|---|---|---|
| "Hitachi, ST Extend SuperH to 64 Bits", Microprocessor Report, 1999-10-06, 13 pp | https://www.cecs.uci.edu/~papers/mpr/MPR/19991006/131304.pdf | sha256 dd28ddfa680efc00340e8d6617dabfd63bbf3977bd58cba32498fbd54ba1f677 |
| F. Arakawa, "SH-5: A First 64-bit SuperH Core with Multimedia Extension", Hot Chips 13, 2001, 24 pp | https://old.hotchips.org/wp-content/uploads/hc_archives/hc13/2_Mon/05hitachi.pdf | sha256 fa1869a6c1362d7d136bdfb196986e2e133d76a8faa3db99b6ec9aab9acb733a |
| Biswas, Hasegawa, Mandaville, Debbage, Sturges, Arakawa, Saito, Uchiyama, "SH-5: The 64-bit SuperH architecture", IEEE Micro 20(4):28-39, 2000 | https://ieeexplore.ieee.org/document/865864/ (paywalled) | no |

Hot Chips 13 facts: 1.5 V, 400 MHz, 7-stage pipeline, 32 KB + 32 KB 4-way
caches, 64-entry I/D TLBs, SuperHyway 64-bit 200 MHz split-transaction bus.
MPR 1999: 209 SHmedia instructions, 208 SHcompact instructions; Hitachi
internal name SH8000, ST name ST50.

## Software with SH-5 support (all since removed upstream)

| Project | Last version with SH-5 | Relevant paths |
|---|---|---|
| binutils/gdb | binutils 2.30, gdb 8.1 (removed 2018, GDB 8.2 / binutils 2.31) | `cpu/sh.cpu`, `cpu/sh.opc`, `cpu/sh64-media.cpu`, `cpu/sh64-compact.cpu` (CGEN ISA description); `opcodes/sh64-opc.c`, `opcodes/sh64-dis.c`; `sim/sh64/` (CGEN simulator); `gdb/sh64-tdep.c`; `bfd/elf32-sh64*.c`, `bfd/elf64-sh64.c`; `gas/config/tc-sh64.c`; `gas/testsuite/gas/sh/sh64/`, `sim/testsuite/sim/sh64/` |
| gcc | 6.x (obsolete in 6, removed in 7) | `gcc/config/sh/shmedia.md`, `shmedia.h`, `sshmedia.h`, `ushmedia.h`, `sh64.h`, `t-sh64`; SH5 code paths in `sh.c`, `sh.h`, `sh.md` |
| newlib | sh64-elf port, 2002 (A. Oliva) | `newlib/libc/machine/sh/` |
| Linux | `arch/sh64` in 2.6.8 to 2.6.24; merged into `arch/sh` from 2.6.25; core removed in 5.8 (commit 37744feebc08), Cayman board in 5.9 | 5.7: `arch/sh/kernel/cpu/sh5/`, `arch/sh/kernel/head_64.S`, `arch/sh/lib64/`, `arch/sh/mm/*64*`, `arch/sh/boards/mach-cayman/`, `arch/sh/include/asm/*_64.h` |
| NetBSD | netbsd-3 branch (port added 2002-07, removed 2007-04) | `sys/arch/sh5/`, `sys/arch/evbsh5/` |
| QEMU | never supported SH-5 | |

## Hardware

- Evaluation silicon: SH5-101, SH5-103 (SuperH part names); Cayman development
  board (Hitachi), PCI, bi-endian, little-endian by default.
- Hot Chips 13 block diagram of the evaluation chip: EMI (DDR SDRAM), FEMI
  (SRAM/Flash), PCI, debug, serial.
