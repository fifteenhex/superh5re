# Plan: boot NetBSD/evbsh5 in QEMU

Goal: run the NetBSD 3.x CAYMAN kernel and userland under a QEMU system
emulator with an SH-5 CPU model, as a software reference for the FPGA core.

## Approach

Add a 64-bit `sh64` target variant sharing `target/sh4` (as mips64 shares
`target/mips`): `TARGET_BASE_ARCH=sh4`, `TARGET_LONG_BITS=64`. Add a `cayman`
machine in `hw/sh4`. Reuse the existing SH-4 SCIF, TMU and RTC models, whose
register layouts match (see `cayman-platform.md`).

The NetBSD kernel is SHmedia-only, so SHcompact can be deferred until
userland needs it.

## Stages

1. Toolchain and disassembler.
   Build binutils 2.30 for `sh64-elf` (last release with SH-5). Gives an
   assembler for test programs and `objdump` to disassemble the release
   kernels. Port `opcodes/sh64-dis.c` into QEMU `disas/` for `-d in_asm`.
   Optional: NetBSD netbsd-3 `build.sh -m evbsh5 tools` (gcc 3.3.3,
   binutils 2.15) to rebuild the SIMULATOR and CAYMAN kernels with `-g`.
   Expect build fixes on a modern host; a period Linux chroot may be easier.

2. CPU state and SHmedia translator.
   64 x 64-bit GPRs (R63 reads zero), 8 target registers, PC, SR, SSR, SPC,
   PSSR, PSPC, EXPEVT, INTEVT, TRA, TEA, RESVEC, VBR, KCR0/1, DCR, CTC, USR.
   Decode the 209 SHmedia instructions with decodetree from Volume 2.
   Integer, load/store, branch (PT*/BLINK, mode bit), control register
   access, SWAP.Q, SYNCO/SYNCI, cache ops as no-ops, TRAPA, RTE, SLEEP.
   FPU and SIMD stubs raising reserved-instruction until needed.
   Reference for semantics: Volume 2 pseudo-code and binutils 2.30
   `cpu/sh64-media.cpu`.

3. MMU, configuration registers and exceptions.
   getcfg/putcfg to ITLB/DTLB slots, ICCR, OCCR per Volume 4 and the STB1
   addresses in `cayman-platform.md`. Software-filled TLBs, page sizes 4 KB
   to 512 MB, ASID, protection, SH bit. Exception launch per Volume 1
   chapter 16: handler = VBR + offset (RESVEC for reset/panic/debug), SPC/SSR
   save, SR.BL/MD/MMU updates, EXPEVT/INTEVT codes. ITLB/DTLB miss codes as
   expected by `stb1_locore.S`.

4. Cayman machine.
   128 MB RAM at `0x80000000`; SuperHyway VCR stubs; peripheral bridge with
   INTC (new model, 64 sources, INTEVT mapping), CPRC (clock registers
   reporting the Cayman dividers), TMU, SCIF, RTC; system FPGA with
   interrupt groups, SuperIO 16550 at 0x3f8 and SMC91C111 (both exist in
   QEMU); DTF mailbox console device at `0x0c100018`; CTC counting.
   Loader: `-kernel` ELF to `0x80000000`, entry `start`, r1 magic and r2-r4
   set, optional `boot_params` at `end` for RAM size and console choice.

5. Bring-up order.
   a. Hand-written SHmedia test programs via DTF or SCIF output.
   b. SIMULATOR kernel (own build) to the DDB prompt over dtfcons.
   c. Release `netbsd-CAYMAN` (3.1) to the console over scif/com.
   d. Userland: NFS root via SMC91C111 as the kernel defaults expect, or an
      MFS/md root image built from `base.tgz` in a rebuilt kernel.
   e. CAYMAN64 kernel, then SHcompact if any userland needs it.

6. Verification.
   gdbstub with 64-bit registers; trace and compare against the binutils
   2.30 `sim/sh64` for instruction-level differences; use the 2002 Cayman
   dmesg as the reference boot log.

## Inputs still needed

- NetBSD 3.1 evbsh5 binary and source sets (archive.netbsd.org).
- binutils 2.30 source tarball.
- SH-5 System Architecture Volume 1 (SuperHyway, address map) for
  cross-checking; Volume 2 (Peripherals) is not available.

## Risks

- Exception offsets, TLB miss semantics and cache-op behaviour are
  implementation details of the STB1 chip; Volume 4 covers them but gaps
  must be filled from NetBSD and Linux sh64 behaviour.
- Period toolchain builds on modern hosts.
- Release kernels were never documented as booted on hardware; a hang may
  be a kernel bug rather than an emulator bug.
