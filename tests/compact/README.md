# SH-5 SHcompact ISA test kit

Self-checking tests for the SHcompact instruction set (SH-5 CPU Core
Volume 3). Every test calls a short SHcompact routine and compares the
registers it returns with a C reference written from the manual's
pseudocode. The expected values never come from an implementation.

Two builds from the same sources:

| MODE | Code | Runs on | Purpose |
|---|---|---|---|
| `sh5` (default) | SHmedia harness, SHcompact routines, MMU off at 0x80000000 | Verilator model of `rtl/`, `qemu-system-sh5 -M cayman` (no SHcompact there) | the test of the core |
| `sh4` | all SHcompact, raw image at 0x0c800000 started at 0xac800000 | `qemu-system-sh4 -M r2d` (SCIF on serial 1) | validates the kit's references against a mature SH-4 |

```
make                  # compact-sh5.elf
make MODE=sh4         # compact-sh4.elf and compact-sh4.bin
make run-sh4          # run the sh4 build on qemu-system-sh4, isa: lines
make rtl              # run the sh5 build on the Verilator model
make GROUPS="arith mem"   # a selection of groups
```

`CROSS` (default `sh64-linux-`) builds both: `-m5-32media` for SHmedia,
`-m5-compact` for SHcompact. Output format as in `tests/isa` (`isa: FAIL
...`, `isa: SUMMARY N tests, M failures`, `isa: DONE`).

## Layout

| File | Contents |
|---|---|
| `harness.h`, `harness.c` | types, CHECK macros, operand corpus (`cop_operands[]`, 32-bit), group table, `cop()` / `cop_call()` |
| `gen_cops.py` | writes `cops.S` and `cops.h` from the routine tables `groups/*_cops.py` |
| `groups/<g>_cops.py` | SHcompact routines of group g (Python table, assembled text) |
| `groups/<g>.c` | the tests of group g: operands, calls, C references |
| `start_sh5.S`, `bare_sh5.c`, `sh5.ld` | SHmedia entry, vectors (exceptions counted and skipped), SCIF output, `cop_call` (BLINK into SHcompact, RTS back) |
| `start_sh4.S`, `bare_sh4.c`, `sh4.ld`, `elf2bin.py` | SH-4 entry, `cop_call` (JSR), SH7751 SCIF output, raw image |

## Routine convention

`cop(fn, a, b, c, d)` calls routine `fn` with a, b, c, d in R4-R7 (32-bit
values, sign-extended into the 64-bit registers on the SH-5) and returns
R0-R3 in a `struct cres`. The templates in `groups/*_cops.py` put the
instruction's destination register in R0, the T-bit (MOVT) in R1 and other
state in R2/R3; routines needing a T-bit input take bit 0 of d (`shlr r7`).
Routines may use R0-R7, GBR, MACH/MACL, the T-bit and FPU state, must keep
R8-R15 and PR (save PR around BSR/JSR), and end with RTS (added by the
generator unless the body has its own). On the SH-5 they also clobber the
scratch registers R20-R23 and TR0-TR3 (Vol. 1 Table 4); the SHmedia caller
expects that.

Expected values: `RES32(x)` is the register value for a 32-bit result,
sign-extended on the SH-5 (Vol. 3 Table 2), the low word on the SH-4.
Addresses passed to routines go through `ADDR(p)`.

## Constraints of the SH-4 build

The SHcompact code generator of gcc calls libgcc trampolines
(`__GCC_shcompact_call_trampoline` and friends, SHmedia code) for calls
that pass or return 64-bit scalars, and the SHcompact libgcc itself is
SHmedia code. The SH-4 build therefore links without libgcc and no
function of the kit takes or returns a 64-bit scalar: `isa_check` takes a
struct pointer, `isa_puthex` a pointer, `isa_rand` returns 32 bits, and the
groups use `isa_udiv32()` instead of `/` and only constant 64-bit shifts.
gcc 6.5 for sh64 also crashes on a 64-bit XOR with a constant that does not
fit XORI; immediates in the group code go through a register (`__asm__("" :
"+r"(im))`).

## Groups

| File | Instructions |
|---|---|
| `arith.c` | ADD, ADDC, ADDV, SUB, SUBC, SUBV, NEG, NEGC, DT, CMP/*, DIV0S, DIV0U, DIV1 (steps and a 32/32 division), MUL.L, MULS.W, MULU.W, DMULS.L, DMULU.L, MAC.L, MAC.W (S = 0/1), CLRMAC, LDS/STS MACH/MACL, EXTS/EXTU, SWAP, XTRCT, AND/OR/XOR/TST/NOT (register and #imm), shifts and rotates, SHAD, SHLD, MOVT, CLRT, SETT, MOV, MOV #imm, ADD #imm |
| `mem.c` | MOV.B/W/L @Rn, @-Rn (also Rm = Rn), @Rm+ (also Rm = Rn), @(R0,Rn), @(disp,Rn), @(disp,GBR) (loads with sign extension, stores with the neighbouring bytes checked), MOV.L/MOV.W @(disp,PC) (both PC alignments, maximum displacement), MOVA, MOVCA.L, LDC/STC GBR, LDC.L @Rm+,GBR, STC.L GBR,@-Rn, LDS.L/STS.L PR, MACH, MACL, AND.B/OR.B/XOR.B/TST.B #imm,@(R0,GBR), TAS.B, PREF, OCBP, OCBWB, OCBI |
| `branch.c` | BT, BF, BT/S, BF/S (taken and not taken, T changed in the slot, displacement +127/-128), BRA, BSR (near, +2047/-2048), BRAF, BSRF (positive and negative Rn, Rn changed in the slot), JMP, JSR (Rn changed in the slot), RTS; delay slot executed once and before the target, PR = address after the slot |
| `sys.c` | CLRS, SETS (through MAC.W), NOP, LDS/STS FPSCR (defined bits) and FPUL (register forms), FRCHG, FSCHG |
| `fpu.c` | FADD, FSUB, FMUL, FDIV, FSQRT (single and double), FABS, FNEG (single and double), FCMP/EQ, FCMP/GT (single and double, T and FPSCR), FLDI0, FLDI1, FLDS, FSTS, FLOAT, FTRC (FRm and DRm), FCNVDS, FCNVSD, FMAC, FIPR, FTRV, FSRRA, FSCA, FMOV FRm,FRn (PR = 0 and 1), FMOV DR/XD register forms, FMOV.S @Rm, @Rm+, @(R0,Rm), @Rn, @-Rn, @(R0,Rn) (SZ = 0), FMOV DR/XD with the same memory forms (SZ = 1), FRCHG (bank swap), FSCHG, LDS/STS and LDS.L/STS.L FPSCR and FPUL; FADD also with FPSCR.FR = 1. Vectors in `groups/fpu_vectors.h` from `groups/gen_fpu.py` |

## Results

RTL core (`rtl/`, SHcompact expansion of `docs/core-design.md` 13): all
groups, 172323 checks, 0 failures, 207 M cycles. Core bugs found by the
kit: DIV1 kept bit 31 of the shifted dividend in its 33-bit step,
FSUB/FDIV operand order, FCNVDS/FCNVSD encodings swapped, BT/BF targets
aligned to 4 bytes.

`arith` on qemu-system-sh4 (QEMU from the `sh5` tree): 115644 checks,
0 failures after one emulator fix: ROTL/ROTR set T to 0 (`andi ... 0`
instead of `1` in `target/sh4/translate.c`). QEMU's SH-4 also computes
the DIV1 borrow as the carry of a two's complement addition, which is
wrong for Rm = 0; those cases are skipped in the sh4 build (`ISA_SH4`),
the SH-5 build checks them against Vol. 3.

`mem` 18816 checks, `branch` 193, `sys` 629 on qemu-system-sh4, 0
failures, no deviation from Vol. 3. Notes on the references:
- MOVCA.L leaves the rest of the cache block architecturally undefined;
  only the written long-word is checked.
- OCBI is checked after OCBWB of the same block, so the memory content is
  defined with and without an operand cache.
- FPSCR bit 1 and bits 22-31 are reserved in the SHcompact view (Vol. 1
  Figure 53, Table 76; QEMU's SH-4 keeps bits 0-21 writable): the tests
  write them as zero and compare only the defined bits (0x003ffffd). PR =
  SZ = 1 (reserved mode) is not written; FRCHG/FSCHG run with PR = 0.
- Vol. 1 Table 142 leaves FPSCR undefined at power-on reset (SR.PR, SZ, FR
  are 0); the `sys` routines save FPSCR on entry and restore it, and the
  group checks it is unchanged at its end (0x00040001 on qemu-system-sh4).
- `make run-sh4` waits for its 600 s timeout: the image idles after
  `isa: DONE`.

`fpu`: expected values from `groups/gen_fpu.py`, which reuses the exact
IEEE754 models of `tests/isa/tools/gen_fpu_s.py` and `gen_fpu_d.py`
(SHcompact FPU = SHmedia numerics, Vol. 1 13.6). All arithmetic runs with
FPSCR.DN = 1, ENABLE = 0, RM = nearest or zero, FLAG/CAUSE sometimes
preset; each vector checks the result and FPSCR (CAUSE replaced, FLAG
sticky). FSRRA, FSCA, FIPR, FTRV are checked against the error bounds of
Vol. 1 8.7.3/8.7.4. On qemu-system-sh4: 29695 checks, 0 failures; the SH-5
build has 36241 checks (5861 skipped in the sh4 build, 3372 of which fail
on QEMU; 685 FSRRA/FSCA checks are SH-5 only). Deviations of QEMU's SH-4
from the manual, skipped in the sh4 build (`ISA_SH4`, operand properties
X_* in the vectors):
- FPSCR.DN = 1 does not flush denormalized sources (QEMU sets only
  flush-to-zero of results); Vol. 1 8.4.1 treats them as signed zeros.
- Denormalized results are flushed when tiny before rounding and signal
  neither underflow nor inexact; Vol. 1 8.3.6/8.4.1: tininess after
  rounding, flush signals U and I.
- FTRC of a NaN gives 0x7FFFFFFF (Vol. 3: -2^31); FTRC of a non-integral
  value signals inexact (Vol. 3: only invalid).
- FCMP/EQ signals invalid for a quiet NaN (Vol. 3: signaling NaN only).
- FIPR/FTRV round every product and partial sum to single precision, which
  exceeds the Vol. 1 8.7.3 bound, and signal inexact only when a rounding
  occurred (Vol. 3: always in the FIPRADD case).
- FMOV pair transfers with SZ = 1 (DR/XD @Rm, @Rm+, @(R0,Rm), @Rn, @-Rn,
  @(R0,Rn)) are 64-bit little-endian accesses (FRn at address + 4); Vol. 1
  3.7 places the lower-numbered register at the lower address in both
  endiannesses. Data words not checked in the sh4 build; addresses, guard
  words and FPSCR are.
- FSRRA raises an illegal instruction exception after executing (case
  0xf07d of `target/sh4/translate.c` ends with `break`), FSCA is not
  decoded; with SR.BL = 1 either restarts the sh4 image. Not run in the
  sh4 build.

Notes on the `fpu` references:
- The FCMP/GT tables of Vol. 2 and Vol. 3 give +0 > -0 = true, contrary to
  their IEEE754 reference and to the FCMP/EQ table (+0 = -0); FCMP/GT T is
  not checked for zeros of different sign (also after the DN flush).
- The Vol. 3 pseudocode of FLOAT FPUL,DRn does not write FPSCR (Vol. 2
  FLOAT.LD does); its vectors have CAUSE = 0 so both readings agree.
- FSCA: FRn = sine, FRn+1 = cosine (Vol. 3 pseudocode, Vol. 1 13.6.8).
- DN = 0 is not tested (a denormalized source raises an FPU error on the
  SH-5, Vol. 1 8.3.7).
- The routines do not use FR12-FR15 of the front bank: callee-saved in the
  gcc ABI, and the SHcompact code of the sh4 build keeps integer values
  there.
