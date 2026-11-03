# SH-5 core design for FPGA

Microarchitecture of the FPGA implementation, up to the bus interface.
Every parameter is marked **D** (documented for the SH-5, with source) or
**C** (our choice where the documents are silent). Sources: Vol. 1
(Architecture), Vol. 2 (SHmedia), Vol. 4 (Implementation), SA Vol. 3
(Debug, DBUS mirrors SuperHyway packets), HC13 (Arakawa, Hot Chips 13
slides, see `refs/sources.md`).

The bus interface itself is specified in `bus-interface.md`. The RTL
skeleton (packages with every constant below, top-level port list) is in
`rtl/`.

## 1. Scope

| Item | Phase 1 | Later |
|---|---|---|
| SHmedia instruction set, all 209 instructions | yes | |
| SHcompact | decoder hook only (§13) | translation to SHmedia micro-ops |
| FPU (single, double, FIPR/FTRV, FSINA/FCOSA/FSRRA) | yes, parameter `FPU_PRESENT` | |
| MMU with translation, 64+64 entry split TLBs | yes | |
| Split 32 KB + 32 KB caches, locking, config-space views | yes | |
| Events: resets, NMI, EXTINT, exceptions, panic, TRAPA, RTE, SLEEP | yes | DEBUGINT, watchpoints (§11.4) |
| Bus: SuperHyway-style initiator port, target port for VCR | yes | Flush/Purge target requests |
| Outside the core: INTC, CPRC, memory, peripherals, debug module | not here | system integration |

## 2. Documented parameters

| Parameter | Value | Source |
|---|---|---|
| Pipeline | 7 stages F1 F2 D E1 E2 E3 W, single issue, in order | HC13 slide 7, 14 |
| Load latency (ALU + D-cache) | 3 cycles | HC13 slide 7 |
| Branch latency (I-cache + decode) | 3 cycles, hidden by split branch and target preload | HC13 slides 7, 10 |
| Static branch prediction | likely bit, compare and correct | HC13 slide 9 |
| Units | IFU, IMU, LSU, FPU (optional), BIU, I-cache + ITLB, D-cache + DTLB | HC13 slides 5, 6 |
| Register files | GR 64 x 64, FR 64 x 32, TR 8 x 64, 17 defined CRs (HC13: 18 implemented, 46 not) | HC13 slides 6, 8; Vol. 4 §6.2 |
| neff, nphys | 32, 32 | Vol. 4 Tables 2, 30 |
| TLB | split, 64 + 64 entries, fully associative, 4 page sizes (4 KB, 64 KB, 1 MB, 512 MB), 256 ASIDs, software refill | Vol. 4 §8.1, Table 31; Vol. 1 §17.7.6 |
| Caches | 32 KB each, 4-way, 32-byte block, 256 sets, EA indexed and EA tagged, operand cache also PA tagged, 6-bit LRU per set, way locking | Vol. 4 Table 41, §9.1.3, §9.1.4 |
| Synonym bits | nsynbits = 1 (bit 12) | Vol. 4 §8.4 |
| SIMD | 4 x 16-bit multiplies + 4 adds per cycle (MMULSUM.WQ issued every cycle) | HC13 slide 12 |
| Bus | SuperHyway, 64-bit, split transaction, half the CPU clock | HC13 slide 4 |
| Bus packets | Load8/16/32, Store8/16/32, Swap8, Flush, Purge; Success/Failure; critical-word-first bursts | SA Vol. 3 §3.6 |
| Clock tick counter | CTC decrements every CPU clock | Vol. 4 §6.2.13 |
| SHcompact scratch state | R20-R23, TR0-TR3, FR33 are clobbered by any SHcompact instruction | Vol. 4 Table 1 |

The documents do not give: execution latencies of multiply and FPU
instructions, FPU pipeline depth, fetch width, register file port counts,
store buffer depth, bus signal-level protocol. These are **C** below.

## 3. Block structure

```
            +-----------+   insn pair    +-----------+
 ITLB <---> |  I-cache  | -------------> |    IFU    |---- interrupts, debug
            +-----------+                | F1 F2 D   |
                  ^                      +-----------+
                  |                        |  3 x 64 (GR read), 3 x 32..128 (FR read)
                  |                 +------+------+--------+
                  |                 v             v        v
                  |            +---------+   +---------+  +---------+
                  |            |   IMU   |   |   LSU   |  |   FPU   |
                  |            | E1 E2 E3|   | E1 E2 E3|  | pipeline|
                  |            +---------+   +---------+  +---------+
                  |                 |             |  ^        |
                  |                 +------+------+  |        |
                  |                        v (W)     |        v
                  |                +------------+    |   +---------+
                  |                |  GR / TR / |    |   |   FR    |
                  |                |  CR files  |    |   +---------+
                  |                +------------+    v
                  |                              +-----------+
                  |                      DTLB <->|  D-cache  |
                  |                              +-----------+
                  |                                   |
                  v                                   v
            +----------------------------------------------+
            |                 BIU                          |
            |  refill / write-back / uncached / swap FIFOs |
            +----------------------------------------------+
                      |  initiator port        ^ target port (VCR)
                      v                        |
                 SuperHyway-style request / response channels
```

Module names in `rtl/`: `sh5_core` (top), `sh5_ifu`, `sh5_icache`,
`sh5_itlb`, `sh5_decode`, `sh5_imu`, `sh5_lsu`, `sh5_dcache`,
`sh5_dtlb`, `sh5_fpu`, `sh5_regfile_gr`, `sh5_regfile_fr`, `sh5_ctrl`
(control registers, event launch), `sh5_biu`.

## 4. Pipeline

### 4.1 Stage assignment

| Stage | IFU / control | IMU | LSU | FPU |
|---|---|---|---|---|
| F1 | select next PC; read I-cache tag and data arrays of the indexed set; ITLB CAM lookup in parallel | | | |
| F2 | tag compare (EA[31:13], ASID or SH, V), way select, PRU check; 8-byte fetch block into the fetch queue; on miss: ITLB result decides refill or ITLBMISS/EXECPROT | | | |
| D | decode (§4.3); register read (3 GR ports, FR ports); hazard check against the scoreboard; static prediction from the l-bit; privilege, FD and reserved-bit checks | | | |
| E1 | branch condition, PT target address and checks | 64-bit ALU, shifter, compare; multiply step 1; SIMD step 1 | address generation, misalignment and neff check | operand classification (NaN, denormal, zero, inf): all FPU exceptions are decided here (§9.3); issue to FP pipe |
| E2 | PT writes TR, starts target preload | multiply step 2; SIMD step 2 | D-cache set read (EA index), EA tag compare, DTLB CAM lookup, store buffer check | FP stage 1 |
| E3 | | multiply step 3 (result); SIMD step 3 | hit/miss, PA tag compare, protection, data align/extend, LDLO/LDHI byte select | FP stage 2 |
| W | commit: exception launch or state update; interrupt sampling; USR dirty bits; CTC | write GR | store enters store buffer; load writes GR | FP stages continue, write FR at the end of the FP pipe (§9) |

Simple ALU results are complete after E1 and are forwarded to the next
instruction's E1 (**C**: E1->E1, E2->E1, E3->E1 and W->E1 bypass paths).
Load and multiply results are complete after E3; a consumer in the next
two issue slots stalls in D for 2 or 1 cycles. This gives the documented
load-use distance of 3 cycles (**D**, HC13 slide 7).

Stage E1 to E3 exist for every instruction (**D**, slides 7 and 10 show
every instruction passing E1 E2 E3 W), so the pipeline is never shorter
for ALU operations; their results are simply forwarded early.

### 4.2 Fetch

- Fetch block: 8 bytes = 2 SHmedia instructions per I-cache access
  (**C**, so that the sequential stream needs the I-cache port only every
  second cycle and the other slots are free for target preload; consistent
  with the block diagram's 64-bit I-cache to IFU path, HC13 slide 6).
- Fetch queue: 4 entries of 8 bytes (**C**).
- PC is 32 bits (neff = 32), 4-byte aligned in SHmedia (2-byte with
  SHcompact later); the ISA bit is separate state. Bits 63:32 of PC, SPC, TR are the sign extension of bit 31 (Vol. 4
  §6.2.7 EXP fields, Vol. 1 §3.8).
- MMU disabled: I-cache bypassed and frozen (Vol. 1 §17.8.1), each fetch
  block is a Load8 bus request, no target preload (§4.4) and no fetch past
  the next sequential block (Vol. 1 §18.11.2).
- Fetch addresses are checked at F2: user mode and tag PRU = 0 gives
  EXECPROT; ITLB miss gives ITLBMISS; tag PRX is checked when the line is
  allocated (an ITLB entry without PRX is not allocated and gives
  EXECPROT).

### 4.3 Decode

Fields per Vol. 1 Table 17: `op[31:26]`, `m[25:20]`, `ext[19:16]`,
`n[15:10]`, `d[9:4]`, `r[3:0]`. Decode order (Vol. 2 §A.3, §A.6):

1. `r[3:0] != 0` -> RESINST.
2. `op` in the 14 FPU opcode groups and SR.FD = 1 (or no FPU) -> FPUDIS,
   even for reserved extensions of those groups.
3. Reserved opcode or extension -> RESINST (table in `rtl/sh5_pkg.sv`,
   from Vol. 2 Tables 37 to 66).
4. Privileged instruction in user mode -> RESINST: GETCON/PUTCON of CR0-31,
   GETCFG, PUTCFG, RTE, SLEEP.

Major formats (Vol. 1 Table 18, Vol. 2 Table 36) select the operand
fields: MND0 (`op[5:3]` = 000, 001, 010, 011 columns 0-3), MSD6
(`op` = 110000, 110001, 111000, 111001), MSD10 (`op[5:3]` = 100, 101 and
110100-110111), XSD16 (`op` = 110010, 110011, 111010, 111011).

Register read ports (**C**): GR 3 read (m, n, and d/w/y for RMW and store
data), 1 write; TR 1 read (b or c) + 1 write; FR 3 read ports of 32 bits,
widened to 64 for `.D`, `.P` and to 128 for FV operands (FIPR/FTRV), 1
write of up to 128 bits (FTRV column). FR is organised as 4 interleaved
banks of 16 x 32 (**C**) so that a vector read is one access.

### 4.4 Branches and target registers

Documented mechanism (Vol. 1 §5.3, HC13 slides 9, 10):

- PTA/PTB/PTABS/PTREL compute the target in E1, check bits 1:0 = 11
  (misaligned SHmedia) and the neff range -> IADDERR, and write TR in E2.
- BLINK reads TR (bit 0 = ISA, bit 1 = SHcompact alignment); conditional
  branches ignore bits 1:0 and never switch ISA.
- The l-bit on PT controls preload; the l-bit on branches controls
  prediction.

Implementation:

- Target buffer per TR (**C**): `{valid, addr[31:3], insn[63:0]}`, one
  fetch block (2 instructions). PT with l = 1 issues a preload fetch of the
  block at the new TR value through the normal I-cache path in a free F1
  slot (E2 of the PT at the earliest). PT with l = 0 only invalidates the
  buffer.
- Branch predicted taken (l = 1) in D: the next two instructions come from
  the target buffer if valid, the sequential fetch is redirected to
  target + 8. Predicted not taken (l = 0): nothing happens in D.
- Resolution in E1 (64-bit compare). Misprediction: squash the one or two
  younger instructions and restart at the correct path (penalty 2 cycles
  with a valid target buffer, 3 + I-cache latency without, **C**).
- With PT at least 3 instructions before the branch and a valid preload
  the taken branch costs 0 cycles (**D**, slide 10: PT E1 computes, E2
  transfers the fetch address, two fetch cycles, selected when the branch
  is in D):

  ```
  cycle        0   1   2   3   4   5   6   7   8
  PTA          F1  F2  D   E1  E2  E3  W
  i1               F1  F2  D   E1  E2  E3  W
  i2                   F1  F2  D   E1  E2  E3  W
  i3                       F1  F2  D   E1  E2  E3
  BLINK                        F1  F2  D   E1  E2
  target block                     F1  F2          (preload, free I-cache slot)
  target insn                              D   E1  (from the target buffer)
  ```
- Target buffers are invalidated by: writes to the TR, SYNCI, RTE, every
  event launch, ICBI, ICCR0 writes, any PUTCFG to the I-cache or ITLB
  region, and whenever SR.MMU = 0 (Vol. 1 §18.11.2 forbids speculative
  fetch from TR pages before a branch has executed with the MMU off;
  disabling preload entirely with the MMU off satisfies it).
- GETTR reads TR in E1 and returns bits 63:32 as the sign extension of
  bit 31.

### 4.5 Hazards and stalls

| Case | Action |
|---|---|
| RAW on ALU result | forward, no stall |
| RAW on load / multiply / SIMD-multiply result | stall in D, 2 then 1 cycle |
| RAW on FP result | scoreboard per FR (64 bits), stall in D until written |
| RAW on TR being written by PT in E2 | stall 1 cycle (branch in D needs TR at D for preload selection, E1 for resolution) |
| GETCON after PUTCON, FGETSCR after any FP op | drain: wait until the pipeline is empty |
| PUTCON SR, PUTCFG, RTE, SYNCI | complete in W, then flush F1-E3 and refetch (precise side effects, Vol. 1 §9.3.2) |
| SYNCO | hold issue until the store buffer is empty and all bus responses are in |
| Uncached or device load | hold the pipeline at E3 until the response arrives (in-order completion, **C**) |
| D-cache miss | hold at E3 until the critical word is returned, line fill continues in the background; the following accesses to the filling line wait |
| I-cache miss | fetch queue empties; D stalls |

## 5. Register files and control registers

- GR: 64 x 64, R63 reads 0 and ignores writes; writes set
  USR.GPRS[d/8] except R63 (Vol. 4 §6.2.14). FR: 64 x 32; writes set
  USR.FPRS[f/8].
- TR: 8 x 32 implemented bits + ISA bit; GETTR sign-extends.
- Implemented control registers and reset values (Vol. 4 §6.2, Vol. 1
  Table 153):

| CR | Name | Reset | Notes |
|---|---|---|---|
| 0x00 | SR | MD=1 BL=1 FD=1 MMU=0 WATCH=0 STEP=0 CD=PR=SZ=FR=0 | PUTCON writes S, IMASK, Q, M, CD, PR, SZ, FR, FD (RO without FPU); ASID, WATCH, STEP, MD, MMU change only by launch and RTE |
| 0x01 | SSR | undefined | |
| 0x02 | PSSR | undefined | |
| 0x04 | INTEVT | undefined | 32 bits |
| 0x05 | EXPEVT | 0 | 32 bits |
| 0x06 | PEXPEVT | undefined | 32 bits |
| 0x07 | TRA | undefined | low 32 bits of the TRAPA operand |
| 0x08 | SPC | undefined | bit 0 = ISA, bits 31:1 address, 63:32 sign extension |
| 0x09 | PSPC | undefined | as SPC |
| 0x0A | RESVEC | 0 | bit 0 = MMUOFF, bits 31:2 address |
| 0x0B | VBR | 0 | bits 31:2 |
| 0x0D | TEA | undefined | 32 bits, sign-extended |
| 0x10-0x12 | DCR, KCR0, KCR1 | undefined | 64-bit scratch |
| 0x3E | CTC | undefined | 32-bit down counter; user read returns 0 when SR.CD = 1; user write ignored |
| 0x3F | USR | undefined | GPRS[7:0], FPRS[15:8] |
| 0x20-0x3D | RESERVED | 0 | read 0, write ignored |
| 0x03, 0x0C, 0x0E, 0x0F, 0x13-0x1F | UNDEFINED | | **C**: read 0, write ignored |

User-mode access to CR0-31 raises RESINST (Vol. 1 Table 92).

## 6. Events

Implements Vol. 1 Chapter 16 in full for the non-debug events, plus BREAK,
DEBUGSS and PANIC. Event codes, vector offsets and ordering are the
constants in `rtl/sh5_pkg.sv` (Vol. 1 Tables 156, 157).

- Detection points: F2 (ITLBMISS, EXECPROT), D (RESINST, FPUDIS, TRAP,
  BREAK), E1 (IADDERR from PT, FPUEXC, RADDERR/WADDERR), E3 (RTLBMISS,
  WTLBMISS, READPROT, WRITEPROT). An instruction carries at most the
  highest-priority pending event to W; W launches it. Instructions behind it
  are squashed.
- Interrupts (NMI, DEBUGINT, EXTINT) are sampled at W when no launch is in
  progress and the instruction in W is not an RTE whose successor must be
  single-stepped (Vol. 1 §16.16.2 requires that interrupts can be accepted
  between the RTE and the following instruction, so they are sampled after
  the RTE commits, before the next instruction reaches W). The interrupt
  is launched on the next instruction to reach W, as a pre-execution event
  of that instruction. SLEEP wakes on any asserted asynchronous source.
- Launch sequence (Vol. 1 §16.6.2): panic saves SSR/SPC/EXPEVT to
  PSSR/PSPC/PEXPEVT; SPC = PC | ISA, SSR = SR; SR.MD = 1, ISA = 1,
  SR.BL = 1; debug events clear STEP and WATCH; CPURESET sets CD, FD, FR,
  SZ, PR to reset values; EXTINT sets IMASK to the level; SR.MMU cleared
  for CPURESET and PANIC, cleared for debug events when the vector base's
  MMUOFF bit is set; INTEVT/EXPEVT/TRA/TEA written per Table 160; PC =
  base + offset with base[1:0] forced to 0. Fetch and target buffers are
  flushed (Vol. 1 §16.8).
- RTE: PC/ISA from SPC, SR from SSR, SPC from PSPC, SSR from PSSR
  (Vol. 1 §16.7). Single step: STEP sampled after RTE applies, DEBUGSS
  (or PANIC when BL = 1) launched post-execution after the next
  instruction (Vol. 1 §16.16).
- POWERON: PC = 0, ISA = 1, SR per §5, EXPEVT = 0, RESVEC = VBR = 0,
  caches and TLBs not initialised (software invalidates: Vol. 4 §9.3.1).
- CPURESET: launch through RESVEC or DBRVEC, EXPEVT = 0x20, SPC/SSR
  saved, registers unchanged (Vol. 1 Table 154).

## 7. MMU

- ITLB and DTLB: 64 entries each, registers plus comparators (CAM),
  PTEH/PTEL layouts exactly as Vol. 4 Tables 36, 37, 39, 40 (ITLB
  implements CB1, SZ, PRX, PRU, PPN; DTLB implements CB0, CB1, SZ, PRR,
  PRW, PRU, PPN). Reserved bits read 0.
- Match: V and (SH or ASID = SR.ASID) and EPN match under the page mask
  (Vol. 1 §17.7.6). Multiple matches are software errors (Vol. 4 §8.3);
  the hardware uses the lowest matching index (**C**).
- Address check before translation (Vol. 1 §17.4.4): EA[63:31] must be
  all 0 or all 1, otherwise IADDERR/RADDERR/WADDERR with TEA = EA[31:0].
  Misaligned loads and stores give RADDERR/WADDERR (Vol. 2 §1 pseudocode
  order: address error, TLB miss, protection).
- MMU off: PA = EA[31:0] (identity, Vol. 1 §17.6), no protection, every
  data access is a device access, caches bypassed and frozen.
- Config space (Vol. 4 Table 28): address bits [31:24] region (0 MMU,
  1 cache), [23:21] bank, [20:16] way, [15:4] index, [3:0] register.
  GETCFG/PUTCFG decode: MMUIR `0x00000000 + 16 n + {0,1}`, MMUDR
  `0x00800000 + 16 n + {0,1}`. A PUTCFG to an enabled PTE's PTEL, or to
  PTEH without clearing V, is undefined (Vol. 4 §8.5.2); the hardware
  performs the write anyway (**C**).
- Cache behaviour resolution per Vol. 1 Tables 170, 171 from PTEL.CB and
  ICCR0.ICE / OCCR0.OCE / OCCR0.OWT.

## 8. Caches

### 8.1 Arrays

| Array | Geometry | Contents |
|---|---|---|
| I-cache data | 4 ways x 256 sets x 32 B | 8-byte words |
| I-cache tag | 4 x 256 | V, SH, ASID[7:0], EADDR[31:13], PRU (Vol. 4 Table 49) |
| I-cache LRU | 256 x 6 | Vol. 4 Table 42 encoding |
| D-cache data | 4 x 256 x 32 B | 8-byte words with byte write enables |
| D-cache tag0 | 4 x 256 | V, SH, ASID, EADDR[31:13], PRR, PRW, PRU, WT, U (Table 53) |
| D-cache tag1 | 4 x 256 | V, PADDR[31:12] (Table 54) |
| D-cache LRU | 256 x 6 | |

Index = EA[12:5] for both caches, always from the effective address
(Vol. 4 §9.1.6). The EA tag is 19 bits, the PA tag 20 bits; PA bit 12 is
in the tag, not the index (Table 54 note).

### 8.2 Lookup policy (Vol. 4 Tables 44, 45)

| Access | Lookup |
|---|---|
| load, store, data prefetch, ALLOCO, PREF | EA tag + ASID/SH; on miss, translate and compare PA tags (alias check) |
| SWAP.Q, OCBI, OCBP, OCBWB | translate first, PA tag only |
| instruction fetch, PREFI, ICBI | EA tag + ASID/SH only (no PA tags) |

Alias resolution (**C**, allowed by Vol. 1 §18.10): an EA miss with a PA
hit in another way re-tags that way with the new EA/ASID/SH/PR/WT bits
instead of allocating a second copy. Protection on a hit is checked from
the tag copies (PRR/PRW/PRU, PRU in the I-cache), so a hit never needs the
TLB (Vol. 4 §9.1.1). A protection violation detected from the tag copy is
re-checked against the TLB before launching (Vol. 1 §17.8.3 item 5
requires this so that permission upgrades need no cache coherence).

### 8.3 Replacement and locking

Exactly Vol. 4 §9.1.3: hit -> most recently used; miss -> lowest-numbered
invalid unlocked way, else LRU unlocked way, else no allocation (access
goes to memory uncached). Locks from ICCR1.IW_LOCK / OCCR1.OW_LOCK;
IW_LE/IW_LOAD and OW_LE/OW_LOAD force the way for prefetches. The LRU
field uses the 6 pairwise bits of Table 42 so that the configuration view
matches the real part.

### 8.4 Write policy

- Write-back line (tag WT = 0, from PTEL.CB0 = 0 and OWT = 0): write
  allocate (fill then merge, **C**), dirty bit U, eviction as Store32.
- Write-through line: hit updates the cache and sends Store8 with byte
  mask; miss does not allocate (**C**, permitted by Vol. 1 §18.8.2).
- Uncached and device data: Load8/Store8/Swap8 with exact byte mask; the
  core does not merge or widen uncached accesses (**C**, stricter than
  required).
- Refill: Load32, critical word first, word order per SA Vol. 3 Table 80;
  the critical word is forwarded to the stalled load.
- ALLOCO: per Vol. 4 §9.1.5 (write-back lines only, zero fill, mark
  dirty, write back the victim).
- OCBI/OCBP/OCBWB/ICBI/PREFI/data prefetch: Vol. 1 §6.6 and Vol. 4
  §9.1.5; ICBI never raises ITLBMISS and does nothing with the MMU off;
  prefetches never raise exceptions and are performed whenever
  translation permits (Vol. 4 "guarantees to prefetch").
- SWAP.Q: PA lookup, invalidate (WT) or purge (WB) the line, then Swap8
  on the bus; the pipeline waits for the response (Vol. 1 §6.5.1).

### 8.5 Configuration view (Vol. 4 §9.2)

GETCFG returns ICACHETAG0, ICACHEDATA[0..3], OCACHETAG0/1,
OCACHEDATA[0..3], ICCR0/1, OCCR0/1 with the exact bit positions of
Tables 47 to 55. PUTCFG to ICCR0.ICI / OCCR0.OCI clears every V bit of
the array (one cycle with a valid-bit flop array, **C**). PUTCFG to tag
or data registers is undefined; the hardware writes them (**C**, useful
for tests). A PUTCFG to ICCR/OCCR must be followed by SYNCI/SYNCO by
software; the hardware also flushes the fetch queue and target buffers.

## 9. Execution units

### 9.1 IMU

- 64-bit adder/subtractor, logic, 64-bit shifter (SHLLD/SHLRD/SHARD use
  6 bits of count; the `.L` forms use 5 bits and sign-extend), NSB,
  BYTEREV, compares (CMPEQ/CMPGT/CMPGTU, CMVEQ/CMVNE), MOVI/SHORI, ADDZ.L.
- Multiplier (**C**): 4 x (16 x 16) signed/unsigned array shared by
  MULS.L/MULU.L (32 x 32 -> 64 built from the four products over E1-E3)
  and the SIMD multiplies (MMUL.W, MMULFX.W, MMULFXRP.W, MMULLO/HI.WL,
  MMACFX.WL, MMACNFX.WL, MMULSUM.WQ, 4 products per cycle: **D**, HC13
  slide 12). The `.L` SIMD multiplies (MMUL.L, MMULFX.L: 2 x 32 x 32)
  take two passes (**C**).
- SIMD adders: 8 x 8, 4 x 16, 2 x 32 lanes with saturation; MSAD.UBQ,
  MCMP*, MABS, MSHF*, MCMV, MPERM.W, MEXTR1-7, MCNVS, MSH* shifts.
  Semantics per the Vol. 2 pseudocode as validated by `tests/isa`.
- Results after E1 (ALU) or E3 (multiplier and 3-stage SIMD ops).

### 9.2 LSU

Address generation in E1 (base + sign-extended scaled displacement or
base + index), alignment check, store data read from GR port 3, LDLO/LDHI
and STLO/STHI byte selection per Vol. 2 (byte offsets from EA[2:0], the
endianness input selects the mapping), sign/zero extension.

Store buffer (**C**): 4 entries `{PA, mask, data, type}` in order. Loads
compare PA[31:3] with every entry and stall until the match drains. Stores
to cacheable write-back lines update the data array from the buffer when
the line is present; otherwise a fill is requested. SYNCO drains the
buffer and waits for every outstanding response.

### 9.3 FPU

- FR file, FPSCR (RM, FLAG, ENABLE, CAUSE, DN; Vol. 4 Table 5), SR.FD
  gate, FGETSCR/FPUTSCR.
- Whether an instruction raises FPUEXC is decided in E1 (**D** makes this
  possible: Vol. 1 §8.3.8 raises O, U, I "early" whenever enabled and the
  instruction can produce them; V, Z and E depend only on operand classes,
  including the FTRC range check). So no FP result is ever needed to decide
  a launch and the FP pipe can be arbitrarily deep. The launch itself
  waits at W until the FP pipe has produced the instruction's actual
  CAUSE bits, which Vol. 1 §8.3.8 requires to be accurate at launch; the
  result is not written (Vol. 1 §8.3.6). CAUSE and FLAG bits of
  non-trapping operations are written when the operation completes;
  FGETSCR and FPUTSCR drain the FP pipe.
- Rounding: nearest even and toward zero only; FTRC truncates; tininess
  after rounding; denormal inputs raise E (CAUSE.E) unless DN = 1, in
  which case inputs and results flush to zero and a flushed result signals
  U and I (Vol. 1 §8.3.7, §8.4.1). Quiet NaN output 0x7FBFFFFF /
  0x7FF7FFFF_FFFFFFFF (Table 75). FCMPEQ/FCMPUN do not signal V for quiet
  NaNs. Behaviour of every instruction is the reference in `tests/isa`.
- Latencies (**C**, FPGA targets): FADD/FSUB/FMUL.S/FMAC.S/FCMP/FCNV/
  FLOAT/FTRC/FMOV/FABS/FNEG 4 cycles; FMUL.D 6; FIPR.S 6 (4 products,
  3-level adder tree, one rounding of the exact sum: this meets the
  accuracy bound of Vol. 1 §8.7.3 and matches the emulator); FTRV.S =
  4 FIPR issues over 4 cycles; FDIV.S/FSQRT.S 16, FDIV.D/FSQRT.D 32
  (iterative, one unit, blocks only dependants and the next
  divide); FSINA/FCOSA/FSRRA by table plus polynomial, 8 cycles, results
  within the Vol. 1 §8.7.4 bounds.
- Without the FPU (`FPU_PRESENT = 0`): SR.FD reads 1 and is read-only, all
  FPU opcodes raise FPUDIS, USR.FPRS stays writable (Vol. 4 §1.4, §6.2.14).

## 10. Synchronisation

- SYNCI: wait until the pipeline has drained, flush the fetch queue and
  the target buffers, refetch at the next PC (Vol. 1 §6.5.2). Does not
  touch cache contents.
- SYNCO: drain the store buffer, wait for all outstanding bus responses
  (loads, stores, write-backs, cache operations), then continue
  (Vol. 1 §6.5.3).
- Launch and RTE imply SYNCI (Vol. 1 §16.8).
- SLEEP: drain, assert `sleep_o`, stop issuing until nmi_i, debugint_i,
  extint_valid_i or cpu_reset_i is asserted (Vol. 1 §16.15), then continue
  with the launch or with the next instruction.
- Memory ordering towards other bus initiators: the core issues requests
  in program order per class but may have several outstanding; only SYNCO
  and the device rule (one outstanding device access at a time, **C**)
  order them.

## 11. External interface

Signal-level definitions are in `rtl/sh5_core.sv`; the bus channels in
`bus-interface.md`.

### 11.1 Clock and reset

`clk` (core clock), `rst_n` (power-on reset, asynchronous assert,
synchronous release). The bus channels run at the core clock; a clock
domain crossing to a slower SuperHyway clock, if used, belongs to the
system side (the real part runs the bus at half the CPU clock, HC13).

### 11.2 Static configuration

`big_endian_i`: data and instruction byte order (Vol. 1 §4.1, §3.7).
Parameters: `FPU_PRESENT`, `MODULE_ID`/`MODULE_VERSION` for the VCR,
`BUS_SRC_ID` (SuperHyway source identifier of the CPU; 0x0D on the
evaluation chip, `docs/cayman-platform.md`).

### 11.3 Events

| Signal | Direction | Meaning |
|---|---|---|
| `cpu_reset_i` | in | CPURESET event (level, Vol. 1 §16.9) |
| `nmi_i` | in | NMI, level; INTEVT = 0x1C0 |
| `debugint_i` | in | DEBUGINT, level |
| `extint_valid_i`, `extint_level_i[3:0]`, `extint_code_i[31:0]` | in | highest-priority pending external interrupt from the INTC and its INTEVT code (Vol. 1 §16.10.3) |
| `extint_ack_o`, `extint_ack_level_o[3:0]` | out | one-cycle pulse when an EXTINT is accepted (for the INTC's bookkeeping; the inputs stay level-sensitive) |
| `dbrvec_i[31:0]`, `dbrmode_i` | in | debug vector and mode, memory-mapped in the system (Vol. 1 §16.6.4) |
| `sleep_o` | out | CPU in sleep mode |

### 11.4 Debug (later)

Watchpoint hits for DEBUGIA/DEBUGIV/DEBUGOA come from a watchpoint
controller outside the core (Vol. 4 §7.2.2). Reserved ports:
`dbg_ia_hit_i`, `dbg_iv_hit_i`, `dbg_oa_hit_i`, and the exported
`dbg_fetch_addr_o`, `dbg_insn_o`, `dbg_op_addr_o`, `dbg_op_valid_o`
buses they compare against. Phase 1 ties them off.

## 12. FPGA mapping

| Structure | Implementation | Size |
|---|---|---|
| I-cache + D-cache data | block RAM, 64-bit wide with byte enables | 64 KB |
| Tags + LRU | block RAM or distributed RAM | about 5 KB |
| Valid bits | flops (bulk invalidate in one cycle) | 2 x 1024 |
| ITLB + DTLB | flop arrays with 64 comparators each | 2 x 64 x 52 bits |
| GR | distributed RAM, 3 copies for 3 read ports | 64 x 64 x 3 |
| FR | 4 banks x 16 x 32, replicated for 3 read ports | |
| Target buffers | flops | 8 x 100 bits |
| Multiplier | 4 DSP blocks (16 x 16) + adders | |
| FPU | DSP blocks for mantissa multiply; iterative divide/sqrt | |

Cache geometry is parameterised (`ICACHE_WAYS/SETS`, `DCACHE_WAYS/SETS`),
default the documented 4 x 256 x 32 B; smaller settings change the
configuration-space view and software that walks the tags (NetBSD) must
be rebuilt, so the default should be kept where the FPGA allows.

Target clock is not fixed; the latency choices above assume a 50-100 MHz
class device.

## 13. SHcompact (later)

Vol. 4 Table 1 lists R20-R23, TR0-TR3 and FR33 as scratch state that
becomes undefined when any SHcompact instruction executes, which shows the
SH-5 implemented SHcompact by expanding each instruction into SHmedia
operations using those registers. The same approach fits this pipeline: a
predecoder in D consumes 16-bit instructions (fetch block = 4 of them),
emits 1 to n SHmedia-format micro-ops, keeps the delayed-branch pair
indivisible for events (Vol. 1 §16.6.3), maps T to R19 bit 0, PR to R18,
GBR to R16, MACH/MACL to R17, and applies SR.S/Q/M and FPSCR.PR/SZ/FR
qualification. Mode switches happen only through BLINK (TR bit 0 = 0) and
RTE (SPC bit 0 = 0).

## 14. Verification

1. Verilator model of `sh5_core` with a testbench memory on the bus port
   and a minimal SCIF model at the Cayman address; run `tests/isa`
   `MODE=bare` (458064 checks) unchanged.
2. Instruction-level trace comparison against the QEMU `sh5` target
   (`-d exec,cpu`) on the same images.
3. Exception and trap tests (TRAPA, address errors, TLB miss and refill,
   protection, FPU enable path, RTE, single step, panic): to be added to
   `tests/isa` as a bare-metal group with its own vector table.
4. Boot the NetBSD 3.1 and Linux 6.15 kernels under simulation once the
   Cayman-like memory map exists on the bus.

## 15. Open questions

- SuperHyway signal-level protocol: not held; the port in
  `bus-interface.md` carries the documented packet fields and will need a
  bridge to whatever the system uses (AXI, Wishbone, a reconstructed
  SuperHyway).
- Failure responses: the CPU architecture has no bus error exception. The
  core records failures in the VCR error flags and raises `bus_error_o`;
  the system decides whether that becomes an interrupt.
- Multiply and FPU latencies, fetch width and buffer depths are not
  documented; the values above are starting points to tune against the
  FPGA.
- Target FPGA board and clock.
- Whether to implement the debug module's watchpoint comparators inside
  the core.

## 16. Implementation status

`rtl/` implements the core as follows (see `rtl/README.md` for files and
the test commands).

| Area | State |
|---|---|
| Pipeline | D E1 E2 E3 W in order, lockstep hold; loads wait for the bus response in E3; stores enter a 4-entry queue in E3; loads are ordered behind all older stores (no forwarding from the store queue). Branches resolve in E1 and redirect fetch; no prediction, no target preload yet. |
| Fetch | 8-byte blocks through the bus, 4-entry queue; no I-cache. |
| ALU, SIMD, FPU | complete; FPU latencies 2 to 63 cycles, one operation in flight. |
| MMU | ITLB and DTLB lookup and exceptions, configuration registers; all accesses are uncached regardless of PTEL.CB (no caches); ICCR/OCCR stored. Cache instructions perform their address, translation and protection checks only. |
| Events | all non-debug exceptions, BREAK, PANIC, NMI/DEBUGINT/EXTINT acceptance and INTEVT/IMASK, RTE, SLEEP. Not implemented: single step (DEBUGSS), watchpoints, SHcompact (RESINST on entry). |
| Bus | Load8/Store8/Swap8 only; VCR target port. |

Verification done: the 458064-check SHmedia ISA kit (`tests/isa`, bare
mode) and the 398-check exception suite (`tests/exc`) pass on the model; the
instruction stream of the first six million instructions of the Linux 6.15
boot matches QEMU (`tools/tracecmp.py`), register writes match in the
windows compared with `tools/regcmp.py`, and the kernel boots to the
smolutils shell prompt on the model (191 M cycles, bus latency 1).
