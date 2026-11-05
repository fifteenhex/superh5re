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
| SHcompact kit branch, sys groups | 822 checks, 0 failures |
| Linux 6.15 | the first 1.5 M instructions after release match the core testbench's stream exactly |

The uncached boot path costs about 14 cycles per instruction through the
bridge (one request at a time, memory latency 6), so a kernel boot that
takes 207 M cycles on the core testbench takes several times that here;
the 5.5 MB deposit over the BAR costs 18.5 M cycles.

`make -C rtl lint-soc` lints `sh5_top` with the fpgaslop blocks;
`make -C rtl lint-board` elaborates the board top with fpgaslop's
Xilinx-primitive stubs and the build script's own file list (34 files,
0 warnings). What remains needs Vivado: `vivado -mode batch -source
fpga/nitefury/build.tcl` (or `-tclargs -synth_only` for the first area
and timing numbers), then fpgaslop's flashing procedure.

## Not done

- No interrupt to the host (CAP_MSI clear); the host polls, as smol68k's board does.
- The DMA engine of `slop_card` is instantiated but its masters are tied
  off (CAP_DMA clear).
- Write bursts, a wider DRAM window, and the core's bus timing (one
  request at a time through the bridge) are the performance items.
- `host/sh5ctl` has never seen hardware.
