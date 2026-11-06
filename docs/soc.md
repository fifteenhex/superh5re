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
answered critical word first; Store32 to RAM as a 4-beat burst write,
ascending words, each beat's data and mask held until its ack (fpgaslop
`docs/porting-write-bursts.md`; the board top feeds `req_to_axi4`'s
`wr_ready` from the crossing's ready, as ddrslop does, because tied high
it deadlocks on the first write burst); Swap8 as a read and a write. The
core keeps several requests outstanding and accepts responses in any
order, so the serialisation is legal. Write bursts took 5 % off the
cycles and 10 % off the transactions of tests/exc through the testbench.

## Results

Through the board testbench (`rtl/tb/board`, memory latency 6 cycles,
every host access a 64-bit BAR transaction):

| program | result |
|---|---|
| tests/exc (MMU, caches, preload, write-back cache stress) | 438 checks, 0 failures, 1.08 M cycles |
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
| sh5_ifu (decode logic pulled in across the boundary by synthesis) | 10626 | 431 | | | |
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
`timing_core.rpt` lists the core-clock paths on their own (the overall
list is headed by the MIG's 200 MHz paths).

## Bring-up

Nothing below has been done on a card yet; this is the order and what
each step proves. Loading follows `fpgaslop/docs/flashing.md`.
`host/bringup.sh <bdf>` runs steps 2 to 5 in order, stopping at the
first failure, with each step's output kept in a log directory.

1. `flash.sh detect`, then `flash.sh sram out/sh5.bit`. LEDs, from the
   board top: 0 PCIe link up, 1 DDR3 calibrated, 2 heartbeat from
   retired instructions (dark while the core is held in reset, which is
   the state at power-up), 3 bit 0 of the system FPGA LEDCR register
   (the kernels drive it). A JTAG-loaded design does not enumerate on
   PCIe on this card, so after LEDs 0 and 1: `flash.sh app out/sh5.bin`
   and a cold power cycle.
2. `lspci -d 10ee:` (subsystem 0x5a05), `make -C host`, then
   `sh5ctl <bdf> probe`. Expected: magic `FPGASLOP`, design `superh5 `,
   caps DRAM CPU RESET, the build id's top 32 bits the git commit, core
   1000/40 = 25 MHz, DDR3 3000 ps, dram calibrated, hub id `superh5 `,
   status 1 (held). The card page is answered by `slop_card` in one cycle
   independent of everything else, so a good card page with a bad hub
   points at `sh5_hostif`/`sh5_hub`, and a bad card page at the PCIe
   path or the clocking. Reads of an undecoded register-window address
   return `baadf00d_baadf00d`; all-ones means the endpoint is not
   answering at all.
3. `sh5ctl <bdf> status`: the hub's cycle counter against the host's
   clock gives the core clock in MHz (25.00 expected); a counter that
   does not move means no MMCM output.
4. `sh5ctl <bdf> memtest` (1 MB at the RAM base, two patterns and a byte
   strobe; `memtest 0x10000000` for the whole 256 MB window): proves the
   host-to-DDR3 path, `memarb` port B, `mem_cdc`, `req_to_axi4` and the
   MIG, with the core held. Then `peek`/`poke` for anything by hand.
5. `sh5ctl <bdf> run tests/exc/exc.elf --done SUMMARY`: the first code
   on the core; `SUMMARY 438 tests, 0 failures` within a second (1.1 M
   cycles in simulation). Then the ISA kit, `run
   tests/isa/isatest-bare.elf --done DONE` (458064 checks, 309 M cycles
   in simulation, about 12 s at 25 MHz), and the SHcompact kit
   `tests/compact/compact-sh5.elf` (207 M cycles). A `run` stops on a
   bus error (hub STATUS bit 2), on the done string, or on its timeout.
6. `sh5ctl <bdf> boot vmlinux --initrd sh-sh5.cpio.gz --cmdline
   "console=ttySC0 -- smolinit.getty=/dev/ttySC0 smolinit.hostname=cayman"`:
   the board testbench needed 3.1 G cycles to the getty, about two
   minutes at 25 MHz; the console is interactive (Ctrl-] detaches,
   `console` reattaches). NetBSD: `boot netbsd-qemu` (the kernel with
   the memory-disk root), `login:` after 2.3 G cycles in the core
   testbench.

What a failure at each step means is in `fpgaslop/docs/flashing.md`
(PCIe, DDR3, the write-loss history of this board) and above
(`sh5_hostif`: card page, hub, DRAM forwarding; `sh5_hub`: STATUS,
console FIFOs). `sh5ctl reset` is fpgaslop's soft reset of the design
without the host path.

## Not done

- No interrupt to the host (CAP_MSI clear); the host polls, as smol68k's board does.
- The DMA engine of `slop_card` is instantiated but its masters are tied
  off (CAP_DMA clear).
- A wider DRAM window and the core's bus timing (one request at a time
  through the bridge) are the performance items.
- Nothing has run on a card yet.
