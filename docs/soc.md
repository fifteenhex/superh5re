# The SH-5 system on the NiteFury II

How the core becomes a card: the pieces around `sh5_core` that let the PCIe
host deposit a kernel into DDR3, start the core and talk to it. Built on
fpgaslop (the shared board layer, a submodule at `fpgaslop/`), following
the boundary its documentation sets: fpgaslop owns everything from the
req/ack bus outwards to the board, the CPU project everything inwards.

```
PCIe BAR0 -> axi_pcie -> axi clock converter -> axi4_to_req ---- h_* -----+
                                                                           |
  +------------------------------------------------------------------------+
  | sh5_top (rtl/soc)                                                 h_*  |
  |   sh5_hostif ---+-- BAR bit 28 set, +0x0000..0xFFF: slop_card          |
  |                 |     identity, soft reset, mailbox/flash/DMA regs     |
  |                 +-- +0x1_0000..0x1_FFF: sh5_hub                        |
  |                 |     reset hold, boot PC, console FIFOs, doorbell      |
  |                 `-- BAR bit 28 clear: DRAM window -> memarb port B      |
  |                                                                        |
  |   sh5_core --packets--> sh5_shwy_req --+-- 0x8000_0000 + 256 MB: memarb port A
  |                                        `-- everything else: sh5_periph |
  |   sh5_periph: INTC, CPRC, TMU, SCIF, RTC, system FPGA regs, VCRs      |
  |   memarb -> mem_* ----------------------------------------------------+
  +------------------------------------------------------------------------+
                                                                           |
                                        mem_cdc -> req_to_axi4 -> MIG -> DDR3
```

`fpga/nitefury/sh5_board_top.sv` holds the outer part (copied from
smol68k's board top, which has built and run) and `build.tcl` the Vivado
flow; `rtl/tb/board` simulates `sh5_top` with the host and the memory as
C++ models.

## Address maps

The core sees the Cayman map the kernels were built for
(`cayman-platform.md`): DRAM at physical 0x8000_0000, 256 MB (the MIG has
1 GB; the window is the decode), peripherals at 0x0a00_0000 (INTC, CPRC,
TMU, SCIF, RTC at the Cayman offsets), the system FPGA registers at
0x0400_2000, module VCRs at 0x0d/0x09/0x08 << 24. Anything else gets a
bus Failure (the core's VCR flags it; the hub's STATUS bit 2 records it).

The host sees fpgaslop's BAR layout: bit 28 clear is the DRAM window
(offset o = DDR3 byte o = physical 0x8000_0000 + o), bit 28 set the
register window with the card page at +0 (`fpgaslop/host/slop_id.h`:
DESIGN `"superh5 "`, CAPS DRAM | CPU | RESET) and the hub at +0x1_0000.

## The hub (`rtl/soc/sh5_hub.sv`)

64-bit registers, one-cycle acknowledge:

| offset | name | meaning |
|---|---|---|
| 0x000 | ID | `"superh5 "` |
| 0x008 | VERSION | major.minor |
| 0x010 | RAM_SIZE | 256 MB |
| 0x018 | STATUS | bit 0 core held in reset, bit 1 asleep, bit 2 bus error seen (write clears) |
| 0x020 | RESET_HOLD | bit 0 holds the core in reset; reset value 1 on a board |
| 0x028 | BOOT_PC | the address the core starts at when released |
| 0x030 | CYCLES | core clock counter |
| 0x038 | IRQ | write: bit 0 NMI pulse, bit 1 set / bit 2 clear the doorbell (INTC source 63) |
| 0x100 | CON_STATUS | [31:16] bytes waiting in the transmit FIFO, [12:8] free slots in the receive FIFO, bit 3 overflow (write clears) |
| 0x108 | CON_POP | read pops a transmit byte: bit 8 valid, [7:0] byte |
| 0x110 | CON_PUSH | write a byte into the SCIF receive FIFO |

The SCIF's transmit register feeds a 4 KB FIFO the host drains with
CON_POP; CON_PUSH fills the SCIF's 16-byte receive FIFO (RDF, RXI as on
the chip). The kernels' console therefore works unchanged: `ttySC0` on
Linux, `scif0` on NetBSD.

## The deposit protocol (`host/sh5boot.c`)

One implementation, used by the board testbench and by `host/sh5ctl`:

1. probe: fpgaslop MAGIC and DESIGN at the card page, ID at the hub
2. RESET_HOLD = 1
3. write the ELF's PT_LOAD segments into the DRAM window (KSEG0
   addresses of a NetBSD kernel translated to physical), zero-fill
4. Linux: command line at `_stext - 0x1000 + 0x100`, initrd 1 MB aligned
   after the image with its location at +0x10/+0x14 of that page.
   NetBSD: symbol-table image, the 600-byte `struct boot_params` at the
   kernel end, and a stub that sets r2/r3/r4 and jumps to the entry
   (what the QEMU Cayman board does)
5. BOOT_PC = entry (or the stub), RESET_HOLD = 0
6. poll CON_STATUS/CON_POP, push input with CON_PUSH

Releasing the core resets it, so the caches start invalid and see the
deposited image.

## The bridge (`rtl/soc/sh5_shwy_req.sv`)

The core's packet port (`bus-interface.md`) becomes fpgaslop's req/ack:
one packet at a time; Load32 as a 4-beat burst read (`mem_len` = 3)
answered critical word first; Store32 as four single-beat writes (write
bursts through `mem_cdc` need `wr_ready` pacing that smol68k also leaves
for later); Swap8 as a read and a write. The core keeps several
requests outstanding and accepts responses in any order, so the
serialisation is legal.

## Results

Through the board testbench (`rtl/tb/board`, memory latency 6 cycles,
every host access a 64-bit BAR transaction):

| program | result |
|---|---|
| tests/exc (MMU, caches, preload in its `mmu` test) | 430 checks, 0 failures, 0.43 M cycles |
| ISA kit arith, branch groups | 5312 and 16093 checks, 0 failures |
| SHcompact kit (all groups) | 172323 checks, 0 failures, 1.05 G cycles |
| Linux 6.15 with the smolutils initrd | boots to the getty on ttySC0, 3.13 G cycles after release |

The uncached boot path costs about 14 cycles per instruction through the
bridge (one request at a time, memory latency 6), so a kernel boot that
takes 207 M cycles on the core testbench takes several times that here;
the 5.5 MB deposit over the BAR costs 18.5 M cycles.

`make -C rtl lint-soc` lints `sh5_top` with the fpgaslop blocks;
`make -C rtl lint-board` elaborates the board top with fpgaslop's
Xilinx-primitive stubs and the build script's own file list (35 files,
0 warnings).

## Synthesis

`vivado -mode batch -source fpga/nitefury/build.tcl -tclargs -synth_only`
(Vivado 2026.1, xc7a200tfbg484-2, core clock 25 MHz). The first run, with
the cache arrays and the hub FIFO as flops, needed 715 k LUTs and 690 k
flops, five times the part; the arrays went into block RAM
(`core-design.md` §8.1) and the second run fits:

| block | LUTs | flops | RAMB36 | RAMB18 | DSP |
|---|---|---|---|---|---|
| whole design | 88499 | 48970 | 54 | 6 | 56 |
| xc7a200t | 134600 | 269200 | 365 | 730 | 740 |
| sh5_core | 67936 | 30509 | 36 | 4 | 56 |
| of which sh5_mm | 17284 | 950 | | | 28 |
| sh5_fpu | 11706 | 2427 | | | 28 |
| sh5_ifu | 10626 | 431 | | | |
| sh5_dcache | 9761 | 4148 | 20 | | |
| sh5_icache | 6509 | 2879 | 16 | 4 | |
| ITLB + DTLB | 7938 | 7168 | | | |
| sh5_shwy_req | 1259 | 598 | | | |
| sh5_periph + sh5_hostif | 1122 | 2031 | 3 | | |
| MIG | 6033 | 5194 | | | |

The build also showed two implicit nets (`d_redirect`, `e1_redirect`
used before their declarations in `sh5_core.sv`, fixed); fpgaslop's
`tools/checkdecl.py` finds those before Vivado does.

## Implementation

The full flow (`build.tcl` without `-synth_only`, commit 8a0aba28, with
the 33 x 33 lane multipliers) placed and routed in about 15 minutes and
met every constraint:

| | |
|---|---|
| LUTs | 85774 (64 %), 855 of them as memory |
| flops | 47399 (18 %) |
| block RAM tiles | 53 (15 %) |
| DSPs | 44 |
| setup slack | 0.725 ns (MIG, 200 MHz); 2.5 ns on the 40 ns core clock |
| hold slack | 0.036 ns |

The worst core-clock path runs from the IFU's queue read pointer to the
fetch PC's clock enable: 37 ns, 84 % of it routing, one logic level.
The design makes 25 MHz with little to spare; a faster core clock needs
the high-fanout control nets (`hold`, the queue pointers) looked at
first.

`out/sh5.bit` (JTAG) and `out/sh5.bin` (SPI flash) are the products.
Loading follows `fpgaslop/docs/flashing.md`: `flash.sh detect`, then
`sram` with the `.bit` to see the LEDs (`led_fpga[0]`, a heartbeat from
retired instructions, DDR3 calibration done, PCIe link up), then `app`
with the `.bin` and a cold power cycle, since on this card a JTAG-loaded
design does not enumerate on PCIe. Then `host/sh5ctl <bdf> probe`.
Nothing has been loaded on a card yet.

## Not done

- No interrupt to the host (CAP_MSI clear); the host polls, as smol68k's board does.
- The DMA engine of `slop_card` is instantiated but its masters are tied
  off (CAP_DMA clear).
- Write bursts, a wider DRAM window, and the core's bus timing (one
  request at a time through the bridge) are the performance items.
- `host/sh5ctl` has never seen hardware; no bitstream has been loaded on a card.
