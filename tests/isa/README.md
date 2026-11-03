# SH-5 SHmedia ISA test kit

Self-checking tests for the SHmedia instruction set. Each test executes an
instruction with inline asm and compares the result with a C reference
written from the pseudocode in SH-5 CPU Core Volume 2, over a corpus of
boundary operands (`isa_operands[]` in `harness.c`) and pseudo-random words.
The expected values never come from the emulator: the kit is meant to
validate QEMU now and the FPGA core later.

Two builds from the same sources:

| MODE | Runs as | Output |
|---|---|---|
| `nolibc` (default) | static Linux program, usable as `/init` | stdout |
| `bare` | image for `qemu-system-sh5 -kernel`, MMU off, 0x80000000 | SCIF, polled |

```
make                 # isatest-nolibc.elf
make MODE=bare       # isatest-bare.elf
make run             # boots KERNEL with the program as init, prints the isa: lines
make MODE=bare run
make GROUPS="arith logic" run    # only these groups
make run ARGS=-v                 # also print PASS lines (nolibc mode)
```

Variables: `CROSS` (default `sh64-linux-`), `QEMU`, `KERNEL` (sh64 vmlinux),
`NOLIBCDIR` (nolibc with the SH-5 patch, see `../../userspace/`), `UAPIDIR`
(`make headers_install` of the sh64 kernel).

Output format, one line per failure and per group:

```
isa: group arith
isa: FAIL add.l a=0x... b=0x... got=0x... want=0x... (groups/arith.c:12)
isa: group arith ok 0 failures
isa: SUMMARY 5312 tests, 0 failures
isa: DONE
```

## Writing a group

One file per group in `groups/`, registered with `ISA_GROUP(name) { ... }`;
the table is a linker section, nothing else to edit. Use `CHECK1..3` with
the operands so a failure line is reproducible, `ISA_FOREACH_OPERAND` for
the corpus, `isa_rand()` for more. Reference semantics go next to the asm
in plain C, following the manual's `SignExtend`/`ZeroExtend` steps. Keep a
group under about a minute of emulated time.

## Groups

| File | Instructions |
|---|---|
| `arith.c` | ADD, ADD.L, ADDZ.L, SUB, SUB.L, ADDI, ADDI.L |
| `integer.c` | MULS.L, MULU.L, NSB, BYTEREV, CMPEQ, CMPGT, CMPGTU, CMVEQ, CMVNE, MOVI, SHORI |
| `logic.c` | AND, ANDC, OR, XOR, ANDI, ORI, XORI, SHLLD(.L), SHLRD(.L), SHARD(.L), SHLLI(.L), SHLRI(.L), SHARI(.L) |
| `loadstore.c` | LD/LDX/ST/STX .B .W .L .Q .UB .UW, LDLO/LDHI/STLO/STHI .L .Q, SWAP.Q, PREFI, ALLOCO, OCBI, OCBP, OCBWB, ICBI |
| `branch.c` | PTA, PTABS, PTREL, GETTR, BLINK, BEQ, BNE, BGE, BGT, BGEU, BGTU, BEQI, BNEI, NOP |
| `mmedia1.c` | MADD(S), MSUB(S), MABS, MCMPEQ, MCMPGT, MCMV, MCNVS, MSAD.UBQ, MPERM.W, MSHFHI, MSHFLO, MEXTR1-7 |
| `mmedia2.c` | MMUL, MMULFX, MMULFXRP, MMULHI/LO.WL, MMULSUM.WQ, MMACFX/MMACNFX.WL, MSHALDS, MSHARD(S), MSHLLD, MSHLRD |
| `fpu_s.c` | all single-precision FPU instructions incl. FIPR, FTRV, FSINA, FCOSA, FSRRA, FGETSCR, FPUTSCR; vectors from `tools/gen_fpu_s.py` |
| `fpu_d.c` | all double-precision FPU instructions, FCNV.SD/DS, FLOAT/FTRC .LD .QD .DL .DQ, FLD/FST .D .P; vectors from `tools/gen_fpu_d.py` |

FPU vectors are generated on the host (`tools/gen_fpu_*.py`, exact
rational arithmetic with IEEE rounding and the manual's special-case
tables) so the expectations do not depend on the target FPU. The
approximate instructions are checked against the error bounds of Vol. 1
8.7.3.

Emulator bugs the kit found and that are fixed on the QEMU branch: MABS.W/L
saturation; NaN conventions (default and signalling NaN), tininess after
rounding, flags of flushed denormal results, quiet FCMPEQ/FCMPUN, FTRC
flags and NaN result, FSRRA/FSINA/FCOSA/FIPR/FTRV flags and accuracy.
Kernel bugs found by running it under Linux: FPU state cache, lazy FPU
restore, FPU save on context switch and fork, caller-saved registers across
the fast TLB miss handler, fixmap faults.
