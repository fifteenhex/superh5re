# SH-5 exception, trap and privileged-state test

Bare-metal program for the event handling of the SH-5 core (Vol. 1 ch. 15-16,
Vol. 4 ch. 6-9).  It runs with the MMU off from physical 0x80000000, like
`tests/isa` with `MODE=bare`, on `qemu-system-sh5 -M cayman` and on the
Verilator model of `rtl/`.  Expected values come from the manuals, never
from an implementation.

```
make                       # exc.elf
make run                   # qemu-system-sh5, prints the exc:/isa: lines
make rtl                   # ../../rtl/tb/core/obj/Vsh5_core
```

Variables: `CROSS` (default `sh64-linux-`), `QEMU`, `RTL_TB`.

Output: `exc: <test> ok` or one `exc: FAIL <test> <check> got=0x... want=0x...`
line per failing check, then `isa: SUMMARY N tests, M failures` and
`isa: DONE`, which both runners detect.

## Layout

| File | Contents |
|---|---|
| `start.S` | vector code at VBR (+0x100, +0x400, +0x600) and RESVEC (+0, +0x100), the common handler, `_start` |
| `exc.c` | the tests |
| `exc.h` | record layout shared by `start.S` and `exc.c`, SR fields, event codes |
| `console.c` | SCIF output (polled), copied from `tests/isa/bare.c` and `harness.c` |
| `exc.ld` | `.vectors` at 0x80000000 (VBR = 0x80000000, RESVEC = 0x80000800), text from 0x80001000 |

`_start` clears SR.FD and SR.BL with RTE (the power-on SR has BL = 1,
Vol. 1 Table 153) and sets VBR and RESVEC.  Every vector entry saves r0 in
DCR (Vol. 1 15.2.9), r1 and tr0 in the control block, and jumps to the
common handler, which stores the vector number, EXPEVT, INTEVT, TEA, TRA,
SPC, SSR, SR, PSPC, PSSR, PEXPEVT and the saved registers into
`exc_area.rec[count % 8]`, increments `count`, and returns with RTE to
SPC + 4.  Two controls change the return: a TRAPA whose operand equals
`ctl.exit_tra` returns to `ctl.next` with SSR = `ctl.next_ssr` (used to
leave user mode), and `ctl.nest` makes the handler clear SR.BL with PUTCON
and execute one TRAPA itself before restoring SPC/SSR from its record and
returning (nested launch).  The tests read the records and the control
registers after return.

## Tests

| Test | Checks | Manual |
|---|---|---|
| `trapa` | EXPEVT 0x160, TRA = low 32 bits of the operand, SPC = address of TRAPA with ISA bit, SSR = SR, handler SR has MD = BL = 1, TEA/PSPC/PSSR/PEXPEVT untouched, RTE restores SR and SPC/SSR from PSPC/PSSR | 16.6.2, 16.7, Tables 157, 160, Vol. 4 Table 15 |
| `resinst` | 0x6ff4fff0, NOP with bit 0 set, reserved extension of opcode 001001, reserved opcode 010100: EXPEVT 0x180 | Vol. 2 A.3, A.4 |
| `user` | RTE with SSR.MD = 0; GETCON SR, PUTCON SR, GETCFG, PUTCFG, RTE, SLEEP, GETCON EXPEVT raise RESINST and are skipped; PUTCON/GETCON USR work; GETCON CTC returns 0 with SR.CD = 1 and the counter with SR.CD = 0; a TRAPA returns to privileged mode through the handler | 16.11.2, Vol. 2 GETCON, Vol. 1 Table 145 |
| `fpudis` | SR.FD = 1: FADD.S, FLD.S, FGETSCR raise 0x800; FPUTSCR with bit 0 set raises RESINST (not FPUDIS); with FD = 0 they execute | 16.11.4, Vol. 2 A.6 |
| `iadderr` | PTABS and PTREL with target bits [1:0] = 11 and with a target outside the sign-extended 32-bit space: EXPEVT 0xae0, TEA = low 32 bits of the target; PTABS/BLINK to a valid target does not fault | 16.11.1, Vol. 2 PTABS/PTREL, Vol. 4 Table 20 |
| `adderr` | misaligned LD.L, LD.Q, ST.W, ST.Q, FLD.D, SWAP.Q and a load/store outside the address space: 0x0e0/0x100 with TEA; LDLO/LDHI/STLO/STHI at odd addresses and LD.Q/LD.L/LDX.Q to R63 at bad addresses do not fault | 16.11.3, Vol. 2 SWAP.Q, LD.Q, LDLO/LDHI byte mappings |
| `panic` | TRAPA and a misaligned load with SR.BL = 1 set by PUTCON: RESVEC + 0, PSPC/PSSR/PEXPEVT saved, TRA and TEA preserved, SR.MMU = 0, RTE restores SPC/SSR from PSPC/PSSR; with SR.WATCH = 1 (set by RTE) the panic launch clears WATCH | 16.6.2 steps 2, 4.4, 5; 16.12; Table 160 |
| `brk` | BRK with BL = 0 and WATCH = 1: RESVEC + 0x100 (DBRMODE = 0), EXPEVT 0x940, SR.WATCH and SR.STEP cleared; BRK with BL = 1: panic | 16.11.5, Table 151 |
| `nested` | handler clears SR.BL with PUTCON and executes TRAPA: inner record has SPC in the handler, SSR with BL = 0; outer handler restores SPC/SSR and returns | 16.6.2 step 4.3 |
| `cr` | KCR0, KCR1, DCR (64 bits); VBR bits [1:0] and RESVEC bit 1 read 0, RESVEC.MMUOFF writable; TEA, SPC, PSPC read the sign extension of bit 31; TRA, INTEVT, EXPEVT, PEXPEVT are 32 bits; SSR/PSSR mask 0xdcfffbf2; PUTCON SR changes S, IMASK, Q, M, CD, PR, SZ, FR, FD, BL and not MD, MMU, ASID, WATCH, STEP or reserved bits; CR 0x20-0x3d read 0; CTC is 32 bits, writable, decrements; USR dirty bits for R9 (bit 1), R63 (none), FR17 (bit 10), GETCON destination marked after the read | Vol. 4 6.2 (Tables 9-26), Vol. 1 15.2.11 |
| `cfg` | MMUDR[5] and MMUIR[7] PTEH/PTEL written with V = 0 and read back: reserved bits (PTEH [10,11], [32,63]; PTEL 2, 5, [10,11], [32,63]; CB0/PRR/PRW in the ITLB, PRX in the DTLB) read 0; ICCR0/OCCR0 bit 1 reads 0; ICCR1/OCCR1 fields [0,1], 7, [8,11] | Vol. 4 Tables 36-40, 47, 48, 51, 52 |
| `fpuexc` | ENABLE.V with a signalling NaN source: 0x120, CAUSE.V and FLAG.V, destination unchanged; disabled: qNaN 0x7fbfffff and FLAG.V; ENABLE.Z with FDIV.S 1/0; ENABLE.I with an exact FADD.S raises early with CAUSE = 0; denormalized source with DN = 0 raises with CAUSE.E only; with DN = 1 it is flushed | 8.3.6-8.3.8, 8.4.1, 8.5 |
| `sync` | SYNCI, SYNCO, NOP execute without a launch | 6.5 |

SH-5 NaN encodings (Vol. 1 2.5.4): a signalling NaN has the fraction MSB set
(0x7fc00000-0x7fffffff); 0x7f800001 is a quiet NaN.  The test uses
0x7fc00001.

Not tested: SLEEP and interrupts (no interrupt source on the bare core),
SR.STEP and single step (not implemented by the RTL core), DBRMODE = 1,
TLB misses and protection (MMU off), the SHcompact ISA.

## Results

QEMU `sh5` target (Cayman): 398 checks, 43 failures.  RTL core
(`rtl/tb/core`, uncommitted working tree of `rtl/` at the time of the run): 398 checks, 23 failures,
202,838 cycles.  `tools/tracecmp.py` on the two instruction streams with
the console loop ignored (`--ignore 80001074-800010c7`): 683 instructions
match, then the streams diverge at the first check whose outcome differs
(`trapa tra`, which fails on QEMU only).

| Test | QEMU | RTL |
|---|---|---|
| trapa | FAIL (TRA 64 bits, SPC/PSPC upper bits) | ok |
| resinst | ok | ok |
| user | ok | ok |
| fpudis | ok | ok |
| iadderr | FAIL (TEA upper bits) | ok |
| adderr | FAIL (SWAP.Q code) | ok |
| panic | FAIL (TRA/TEA updated, WATCH kept, SPC/PSPC upper bits) | FAIL (PUTCON cannot set BL) |
| brk | FAIL (WATCH kept) | FAIL (PUTCON cannot set BL) |
| nested | ok | FAIL (PUTCON cannot clear BL) |
| cr | FAIL (VBR/RESVEC/TEA/SPC/PSPC bits, USR order) | FAIL (PUTCON BL, USR dirty bits late) |
| cfg | FAIL (reserved bits, ICCR1/OCCR1) | ok |
| fpuexc | FAIL (early inexact, FPU error) | ok |
| sync | ok | ok |

### QEMU

| Check | QEMU | Expected | Reference | Verdict |
|---|---|---|---|---|
| `trapa tra` | TRA holds all 64 bits of Rm | low 32 bits, upper half reads 0 | Vol. 1 15.2.4, Vol. 4 Table 15 | QEMU: `helper_trapa` stores the full operand |
| `cr tea`, `iadderr * malformed tea` | TEA returns the value written / the 64-bit target | ADDR [0,31], EXP reads as the sign extension of bit 31 | Vol. 4 Table 20, 16.11.1 (upper bits of a malformed address are lost) | QEMU: `env->tea = target` in `helper_ptabs_check` and `putcon` |
| `cr spc`, `cr pspc`, `trapa pspc kept`, `panic pspc`, `* spc after rte` | SPC/PSPC return the value written | EXP [32,63] reads as the sign extension of bit 31 | Vol. 4 Tables 16, 17 | QEMU keeps 64 bits |
| `cr vbr` | bits [1:0] read back as written | read 0 | Vol. 4 Table 19 | QEMU; the launch address is also computed without masking them (Vol. 1 16.6.4), so a VBR with bit 0 or 1 set vectors to a misaligned handler |
| `cr resvec` | bit 1 reads back as written | reads 0 | Vol. 4 Table 18 | QEMU |
| `panic tra preserved`, `panic tea preserved` | TRA/TEA updated by the trap/address error that caused the panic | preserved on a panic launch | Vol. 1 16.6.2 step 5 | QEMU: the helpers write TRA/TEA before the launch decides on panic |
| `panic watch panic sr`, `brk sr` | SR.WATCH kept | debug and panic launches clear SR.STEP and SR.WATCH | Vol. 1 16.6.2 step 4.4, Table 160 | QEMU |
| `adderr swap.q +1` | RADDERR (0x0e0) | WADDERR (0x100) | Vol. 2 SWAP.Q: possible exceptions WADDERR, WTLBMISS, READPROT, WRITEPROT | QEMU (alignment check of the atomic exchange reports a read) |
| `cr usr *` | GETCON from USR marks its destination before reading | after the read | Vol. 4 6.2.14; Vol. 1 15.2.11 allows either | implementation-specific; SH-5 behaviour is the documented one |
| `cfg mmu*` | PTEH/PTEL reserved bits read back as written | read 0 | Vol. 4 Tables 36-40 | QEMU stores the low 32 bits unmasked |
| `cfg iccr0`, `cfg occr0` | all bits stored | ICE/OCE, OWT only; ICI/OCI read 0 | Vol. 4 Tables 47, 51 | QEMU |
| `cfg iccr1`, `cfg occr1` | read 0 | W_LOAD, W_LE, W_LOCK fields | Vol. 4 Tables 48, 52 | QEMU: not implemented |
| `fpuexc early inexact` | no exception, result written | FPUEXC raised when ENABLE.I is set and the instruction can be inexact, CAUSE = 0 | Vol. 1 8.3.8 | QEMU raises only on a detected condition |
| `fpuexc denorm` | inexact (CAUSE.I, FLAG.I), result 1.0 | FPU error: FPUEXC with CAUSE.E, no flag | Vol. 1 8.3.7 | QEMU has no FPU error |

### RTL

| Check | RTL | Expected | Reference | Verdict |
|---|---|---|---|---|
| `cr sr writable fields`, `panic sr.bl set by putcon`, all panic/brk-panic/nested checks | PUTCON to SR does not change BL (`SR_PUTCON_MASK` = 0x0000fbf2 in `sh5_pkg.sv`) | BL is RW; PUTCON changes every field except ASID, WATCH, STEP, MD, MMU | Vol. 1 15.2.1, Vol. 4 Table 9 | RTL bug; because of it the panic tests see ordinary exceptions and the nested test sees a panic.  The panic path itself (entered with BL set by RTE) passes |
| `cr usr r9 written`, `cr usr r9 r2 written`, `cr usr fr17 written` | a GETCON from USR does not see the dirty bit of a register written by the preceding one or two instructions | GETCON observes all registers made dirty by previous instructions | Vol. 4 6.2.14 | RTL bug (USR read in E1, dirty bits set at write-back, no interlock) |
| deadlock | an instruction that raises an exception in the execute stage (PTABS/PTREL with IADDERR, LD.L with RADDERR) followed within two instructions by a load stops the core: no further commits or bus requests.  `gettr tr1, r6; ptabs r2, tr1; addi ...; ld.q ...` and `ld.l (misaligned); nop; ld.q ...` reproduce it; three NOPs after the faulting instruction avoid it | | | RTL bug; the test keeps three NOPs after every such instruction (`NOPS` in `exc.c`) so the run completes |
| deadlock (earlier build) | with an earlier build of the model, `movi; shori; movi r1; st.q r0,0,r1; ld.q r0,0,r2` stopped after the shori; not reproducible with the later build | | | RTL, superseded |

Checks that pass on the RTL and fail on QEMU confirm the manual reading
above (TRA width, TEA/SPC sign extension, VBR/RESVEC reserved bits, panic
preservation of TRA/TEA, WATCH clearing, SWAP.Q code, PTE reserved bits,
cache control fields, early inexact, FPU error), and vice versa (PUTCON of
BL, USR precision).
