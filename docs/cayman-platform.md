# SH-5 evaluation chip and Cayman board, as seen by NetBSD

Facts taken from the NetBSD netbsd-3 sources (`sys/arch/sh5`, `sys/arch/evbsh5`)
and the 2002 Cayman dmesg. To be cross-checked against SH-5 System
Architecture Volume 1 when available.

## CPU

- Evaluation core name in software: STB1. CPU id 0x51e2. SuperHyway p-port 0x0d.
- Clock on Cayman: 256 MHz CPU (PLL 512 MHz), SuperHyway 128 MHz, peripheral
  bus 21 MHz, external memory 64 MHz.
- Caches: 32 KB instruction and 32 KB operand, 4-way, 256 sets, 32-byte lines.
  Instruction cache VIVT, operand cache VIPT write-back.
- TLBs: 64 ITLB and 64 DTLB slots, software loaded. No hardware TLB lookup by
  address.
- Configuration register space (getcfg/putcfg), addresses:
  ITLB slot n at `0x00000000 + n*step`, DTLB slot n at `0x00800000 + n*step`,
  ICCR `0x01600000`, OCCR `0x01e00000`, OCACHETAG `0x01800000 + way*65536 +
  set*16`. Each TLB slot has PTEH at index 0 and PTEL at index 1.
- PTEH: bit0 V, bit1 SH, bits 2.. ASID, bits 12.. EPN.
  PTEL: bits 1:0 CB (0 nocache, 1 device, 2 write-back, 3 write-through),
  bits 4:3 SZ (4 KB, 64 KB, 1 MB, 512 MB), PR bits R=0x40 X=0x80 W=0x100
  U=0x200, bits 12.. PPN. Software uses 0x400 and 0x800 as R and M bits.
- SR bits: IMASK 7:4, Q 8, M 9, CD 11, PR 12, SZ 13, FR 14, FD 15, ASID 23:16,
  WATCH 26, STEP 27, BL 28, MD 30, MMU 31.
- SR bits MD, MMU, WATCH, STEP and ASID are read-only to PUTCON on the
  STB1; only an event launch or RTE changes them (Volume 4, Table 9).
  NetBSD relies on this: `pmap_bootstrap` writes SR = 0xf0 just to clear
  BL, `sh5_setasid` switches the ASID with RTE, and `cpu_switch` restores a
  saved SR with PUTCON expecting the ASID to be unaffected.
- USR register: bits 7:0 GPRS, bits 15:8 FPRS. Bit i is set by hardware when
  any of R8i..R8i+7 (FR8i..FR8i+7) is written; software clears bits with
  PUTCON (Volume 1, 15.2.11). NetBSD saves and restores an FP register
  group on context switch and signal delivery only when its FPRS bit is set
  (`cpu_switch.S` FPSV/FPRS macros, `sh5_fpsave`), and the exception entry
  code preserves USR across handlers. gcc 3.3 uses FP registers as integer
  scratch (`fmov.ls`/`fmov.sl`), so an emulator that does not set the dirty
  bits leaks FP state between processes and corrupts pointers at random.
- FPSCR: RM bit 0, FLAG bits 6:2, ENABLE 11:7, CAUSE 17:12 (I,U,O,Z,V,E),
  DN bit 18. DR2i is FR2i (high half) : FR2i+1 (low half). The kernel
  enables the FPU (clears SR.FD) at boot and writes FPSCR = 0x20000.
- CTC control register: cycle counter, used for delay calibration.

## Physical memory map (Cayman)

| Physical address | Device |
|---|---|
| `0x80000000`, 128 MB | SDRAM. Kernel loaded here. |
| `0x04000000` | System FPGA (board glue), 16 KB window; SuperIO, SMC91C111 ethernet (`sm`), alpha LED, interrupt groups driving CPU IRL0-3 |
| `0x08000000` | FEMI (flash/external memory interface), p-port 0x08, base 0, length 0x8000000 |
| `0x09000000` | Peripheral bridge VCR, p-port 0x09, module id 0x448f |
| `0x0a000000` | INTC |
| `0x0a010000` | CPRC (clock, power, reset). FRQ +0, PLL +8, WTCNT +0x10, WTCS +0x18, MSTP +0x20, MSTPACK +0x28, STBCR +0x30, RST +0x38 |
| `0x0a020000` | TMU, SH-4 layout: TOCR 0, TSTR 4, TCOR/TCNT/TCR per timer at 8+12n, 0xc+12n, 0x10+12n |
| `0x0a030000` | SCIF, SH-4 layout: SMR 0, BRR 4, SCR 8, FTDR 0xc, FSR 0x10, FRDR 0x14, FCR 0x18, FDR 0x1c, SPTR 0x20, LSR 0x24 |
| `0x0a040000` | RTC, SH-4 layout: R64CNT 0, RSECCNT 4 ... RCR1 0x38, RCR2 0x3c |
| `0x0c100018` | Debug module FPF register, used by the DTF host console |
| `0x40000000` | PCI bridge, p-port 0x40 |

SuperHyway p-port n is at physical `n << 24`; each module has a 64-bit VCR
at offset 0 (module id in bits 47:32, version in 31:16).

INTC registers: ICR_SET 0, ICR_CLEAR 8, INTPRI 0x10.., INTSRC 0x50.., INTREQ
0x60.., INTENB 0x70.., INTDISB 0x80.., 64 sources. INTEVT codes: IRL0-3
0x240/0x2a0/0x300/0x360, TMU 0x400, SCIF 0x700, PCI INTA-D 0x800..0x860.

## Kernel entry contract

- ELF, little-endian, linked for KSEG0 `0xffffffff80000000` (64-bit ABI) or
  `0x80000000` (32-bit ABI) mapping physical `0x80000000` with one 512 MB
  TLB entry set up by the kernel itself.
- Entered at `start` in SHmedia mode, privileged, MMU may be off. If r1 ==
  `0xdeadbeefdeadbeef` then r2 = physical load address, r3 = symbol table,
  r4 = end of kernel; otherwise defaults: load address `0x80000000`, no
  symbols. A `struct boot_params` (magic 0xcafebabe) at `end` overrides the
  built-in Cayman defaults (128 MB at 0x80000000, CPU 256 MHz, console scif
  38400 baud, NFS root via sm0).
- Kernel code is SHmedia only (`-m5-32media-nofpu`). SHcompact is not used by
  the kernel.

## Console options

- `com0`: 16550 on the SuperIO behind the system FPGA (ISA 0x3f8), 38400 baud.
  Default on real Cayman.
- `scif0`: on-chip serial. Also in the CAYMAN config; used if com probe fails.
- `dtfcons0`: console over the debug link. Kernel writes `0xf7 << 56 |
  trapbuf_phys` to the FPF register at `0x0c100018` with the MMU off; the
  host reads a `dtf_trap`/`dtf_params`/packet triple from RAM and acks. The
  SIMULATOR kernel config uses only this console.

## Kernel configs in the tree

- CAYMAN / CAYMAN64: full board, 32-bit or 64-bit ABI. Shipped in releases.
- SIMULATOR: option SH5_SIM, CPU speed 10 MHz, devices cpu, pbridge, cprc,
  intc, tmu, rtc, clock, dtfcons. MFS and FFS, no network drivers.

## NetBSD 3.x sh5 kernel bugs found by emulation

- `sys/arch/sh5/sh5/in_cksum.S`, `in4_cksum`: the pseudo-header sum
  (`src | dst << 32` plus `(proto + len) << 8`) is kept unfolded in r2 and the
  folded per-mbuf sums are later added with a plain `add`, so for a
  destination of 255.255.255.255 the 64-bit sum overflows and the carry is
  lost. Every broadcast UDP packet fails checksum verification (udps_badsum),
  which breaks DHCP with servers that broadcast their replies. Workaround used
  here: fold `r20` (dst) to 32 bits with `mshfhi.l` before adding, so r2 can
  no longer overflow.
- `sys/arch/sh5/sh5/trap.c`: after a copyin/copyout fault the resume
  address is `(register_t)(uintptr_t)pcb_onfault`, which zero-extends a
  kernel address. Effective addresses outside the sign-extended 32-bit range
  raise IADDERR (Volume 1, address validity), so a faulting copyinstr in a
  32-bit kernel ends in "Instruction Address Error in kernel mode" at
  `Lcopystrerr`. Fix: cast through `intptr_t`.
- `sys/arch/sh5/include/param.h`: MSIZE 256 is too small for LP64;
  `sizeof(struct _m_ext) > MHLEN` and the 64-bit kernel panics in mbinit.
- `sys/arch/sh5/include/vmparam.h`: USRSTACK32 = 0xbffff000 puts the stack
  of a 32-bit process above 2 GB; the kernel sees the sign-extended address
  in TEA, outside the process map, and execve fails with EFAULT. Keeping
  32-bit processes below 0x80000000 works.
- Boot parameters: `bp_kseg0_phys` and `bp_mem[].physstart` must be unsigned
  physical addresses. The kernel's built-in defaults are sign-extended; with
  those the 64-bit pmap's page frame numbers no longer match the PTEL PPN
  and `PHYS_TO_VM_PAGE` fails for every page.
