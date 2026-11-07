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
                                    sh5_mem_cdc -> req_to_axi4 -> MIG -> DDR3
```

`fpga/nitefury/sh5_board_top.sv` holds the outer part (copied from
smol68k's board top, which has built and run, with `sh5_mem_cdc` in place
of `mem_cdc`) and `build.tcl` the Vivado flow; `rtl/tb/board` simulates `sh5_top` with the host and the memory as
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
cycles and 10 % off the transactions of tests/exc through the testbench,
and 5.5 % and 15 % off a Linux boot with the caches on (332.6 M cycles
and 11.3 M transactions without them, 314.3 M and 9.6 M with).

## The memory clock crossing (`rtl/soc/sh5_mem_cdc.sv`)

The SoC runs at the core clock, the DDR3 controller's user interface at
100 MHz, and the two are unrelated (fpgaslop's `mem_cdc.sv` explains).
fpgaslop's crossing is a four-phase handshake that pays about seven core
cycles for every beat; `sh5_mem_cdc` has the same ports and reset contract
(assert both resets together) and three asynchronous FIFOs instead
(`sh5_afifo.sv`, Gray-code pointers): a command FIFO, a write-data FIFO
the master fills one beat per acknowledge, and a read-data FIFO the
controller side fills one beat per cycle. Writes are posted (acknowledged
when in the FIFO; the command FIFO keeps the order, `req_to_axi4` finishes
each transaction before the next, so a later read sees them). `rd_ready`
and `wr_ready` of `req_to_axi4` come from the FIFOs. `rtl/tb/cdc` (`make
-C rtl check-cdc`) drives the real `memarb` and `req_to_axi4` with two
clocks at 4:1 and random traffic on both ports against a model, then
measures: with a 12-cycle controller latency a single write is
acknowledged in 2 core cycles, a 4-beat write-back in 8, a single read
takes 11 and a 4-beat line fill 15.

## Storage: virtio-blk (`host/sh5blk.c`)

fpgaslop's `slop_virtio_slots` sits in `sh5_top`: a stock virtio-mmio v2
register block the core sees at 0x0b00_0000 (slot n at +n*0x200), its
host side at register window +0x2_0000 (slot n at +n*0x400), the
interrupt on INTC source 63 together with the hub doorbell (INTEVT 0x560,
Linux irq 63, priority set by the Cayman platform). The virtqueue is in
DRAM, which both sides reach, so nothing else crosses. Linux binds the
transport from its command line, no driver code added:

    virtio_mmio.device=0x200@0x0b000000:63

`host/sh5blk.c` is the device, served from a file over fpgaslop's host
virtqueue library (`slop_virtq.c`, `slop_vmmio.c`): it presents device id
2 with the capacity in the config space, waits for DRIVER_OK, then takes
IN/OUT/FLUSH/GET_ID requests from queue 0 and raises the used-buffer
interrupt. `sh5ctl run|boot ... --disk IMG` and the board testbench's
`--disk IMG` both serve it between console polls; the device is presented
before the core is released, as the transport requires. `mke2fs -d DIR
img 8M` on the bench machine makes an image with files in it.

The device offers VIRTIO_F_ACCESS_PLATFORM (feature bit 33) besides
VERSION_1. Without it Linux assumes a device that is coherent with the
CPU's caches and uses plain kernel memory for the ring and the buffers:
with the write-back data cache the host saw the avail index only when
its line happened to be evicted (131 M cycles after the kick in one
run) and the guest never saw the used index the host wrote. With the
bit the driver goes through the DMA API: the ring in an uncached mapping
(sh64's `pgprot_noncached` is CB=device), every buffer written back or
invalidated around the request by `arch_sync_dma_for_device`. The
testbench's `+viotrace` plusarg prints every guest access to the
transport and every host write, with the cycle number.

## Results

Through the board testbench (`rtl/tb/board`, memory latency 6 cycles,
every host access a 64-bit BAR transaction):

| program | result |
|---|---|
| tests/exc (MMU, caches, preload, write-back cache stress) | 438 checks, 0 failures, 1.08 M cycles |
| ISA kit arith, branch groups | 5312 and 16093 checks, 0 failures |
| SHcompact kit (all groups) | 172323 checks, 0 failures, 1.05 G cycles |
| Linux 6.15 with the smolutils initrd, kernel built with CONFIG_CACHE_OFF | boots to the getty on ttySC0, 3.13 G cycles after release, 262 M memory transactions |
| the same kernel built with CONFIG_CACHE_WRITEBACK | shell prompt after 314 M cycles, 9.6 M memory transactions (12.6 s at 25 MHz) |
| NetBSD 3.1 (CAYMAN_QEMU, memory-disk root) | root login, `uname -a`, 1.77 G cycles |
| the write-back kernel with VIRTIO_MMIO + VIRTIO_BLK and `--disk` (8 MB ext2) | `mount -t ext2 /dev/vda /mnt`, `cat`, `ls` of the image: 8 reads, 1 write, 352 M cycles to FIN |

With the caches off every instruction fetch and data access is a
serialised bridge transaction, about 14 cycles per instruction (memory
latency 6); with the caches on the same boot takes a tenth of the cycles
and 4 % of the transactions. The 5.5 MB deposit over the BAR costs
18.5 M cycles.

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

The worst core-clock path (`timing.rpt`, 2.5 ns slack) runs from the
IFU's queue read pointer through the instruction mux, the SHcompact
expander (`d_cinsn`), decode and the issue decision back to the fetch
PC's clock enable: 39 logic levels, 37 ns, 31 of them routing between
slices spread across the die. The design makes 25 MHz with little to
spare, and the path is a decode depth, not a fanout: a faster core clock
needs a register between the fetch queue and decode (one more cycle on a
redirect, hidden by the target buffers for predicted branches) and, for
SHcompact, between the expander and decode.

`out/sh5.bit` (JTAG) and `out/sh5.bin` (SPI flash) are the products.
`timing_core.rpt` lists the core-clock paths on their own (the overall
list is headed by the MIG's 200 MHz paths).

## On the card

Results on the NiteFury II through `host/sh5ctl` over PCIe. First the
bitstreams of 2026-11-07 (e9d9aaa4 and b458b6c6, 25 MHz core clock):

| program | result | time |
|---|---|---|
| probe, status, memtest | identity, 25.000 MHz measured, 1 MB write/read/compare passed | 1 s |
| tests/exc | 438 checks, 0 failures, 1.35 M cycles | 0.1 s |
| SHmedia ISA kit | 458064 checks, 0 failures, 2.44 G cycles | 98 s |
| SHcompact kit | 172323 checks, 0 failures, 1.57 G cycles | 63 s |
| Linux 6.15, write-back caches, smolutils initramfs | boots to the shell; `cat /proc/cpuinfo` says SH5-101 with 32 KiB split caches; `ls /bin` | 25 s, 621 M cycles |
| NetBSD 3.1 (CAYMAN_QEMU, memory-disk root) | multi-user, root login, `uname -a`, `ps`, `df` | about 75 s to `login:` |

Transcripts: `logs/fpga-linux.txt`, `logs/fpga-netbsd.txt`.

Then 0183b335 (2026-11-08: decode in two stages, interrupts registered,
the FIFO memory crossing), built with `-core_div 20` and met after routing
with 0.27 ns to spare; the card measures 49.999 MHz:

| program | 25 MHz | 50 MHz |
|---|---|---|
| tests/exc | 0.1 s, 1.35 M cycles | 0.1 s, 1.65 M cycles |
| SHmedia ISA kit (uncached) | 98 s, 2.44 G cycles | 77 s, 3.85 G cycles |
| SHcompact kit (uncached) | 63 s, 1.57 G cycles | 51 s, 2.55 G cycles |
| Linux to its shell | 25 s, 621 M cycles | 12 s, 613 M cycles |
| NetBSD to root login | 82 s, 2.04 G cycles | 42 s, 2.08 G cycles |

The cached kernels take the same cycles at twice the rate; the uncached
kits pay the memory latency, now twice as many cycles per access, and
gain a fifth. The longest core path at 50 MHz is a carry chain in the FPU
(`pass_r`, the operand classification); the decode path is no longer
near the top.

The uncached kits run about eight times slower per instruction than in
the board testbench (memory latency 6 there, about 30 core cycles here
through `mem_cdc` and the controller); the cached kernel boot is twice
the simulated cycle count.

Two things the simulations could not show. The first bitstream
(8a0aba28) fetched and executed but every general register read as zero: Vivado had refused to make a memory of `gr_q`,
written from two ports in one process, and left a net in `sh5_core`
without a driver (`Synth 8-3848`); Verilator ran the same code
correctly. The hub's debug registers (0x040..0x070, `sh5ctl dbg`: last
bus request, first failing request, counts, last response, retired
PC/instruction) were added to find it and stay in the design. Second,
NetBSD deposited after Linux spun in `kprintf` from the interrupt path
before its console existed: the peripherals kept Linux's TMU and INTC
state across the host's hold and release, since only the core was in
`reset_hold`'s reset. The peripherals and the bridge now reset with the
core, and `sh5ctl` issues fpgaslop's soft reset before every deposit for
the bitstreams that predate that.

## Bring-up

Nothing below has been done on a card yet; this is the order and what
each step proves. Loading follows `fpgaslop/docs/flashing.md`.
`host/bringup.sh <bdf>` runs steps 2 to 5 in order, stopping at the
first failure, with each step's output kept in a log directory;
`host/check-card.sh <bdf>` is the full regression once the card is known
to work (both scripts call sudo themselves; over a session without a
terminal, run them under `sudo` instead). On this
card no cold power cycle was needed after flashing: `flash.sh reboot`
(the FPGA reconfigures from flash) and then a PCI remove and rescan of
the device re-enumerated it with the new subsystem id.

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
   the console is interactive (Ctrl-] detaches, `console` reattaches);
   the prompt is `smolsh / >`. `run` types its `--expect/--send` steps
   only after the console has been quiet for 0.2 s (a getty flushes its
   input as it prints the prompt) and in bursts of at most 13 bytes with
   the receive FIFO drained in between (two quirks of NetBSD's SCIF
   driver, `host/sh5ctl.c`, `type_byte`); typing by hand is far slower
   than either. Use a kernel built with
   `CONFIG_CACHE_WRITEBACK=y`: the image booted on the testbenches until
   2026-11-06 had `CONFIG_CACHE_OFF=y`, never touched the caches, and
   needed 3.1 G cycles to the getty through the board testbench (two
   minutes at 25 MHz). NetBSD: `boot netbsd-qemu` (the kernel with the
   memory-disk root); root login and `uname -a` after 1.77 G cycles
   through the board testbench.

What a failure at each step means is in `fpgaslop/docs/flashing.md`
(PCIe, DDR3, the write-loss history of this board) and above
(`sh5_hostif`: card page, hub, DRAM forwarding; `sh5_hub`: STATUS,
console FIFOs). `sh5ctl reset` is fpgaslop's soft reset of the design
without the host path.

## Not done

- No interrupt to the host (CAP_MSI clear); the host polls, as smol68k's
  board does, and the virtio kick is polled too (the kick latch at host
  offset 0x0f8 is what an MSI would carry).
- virtio-blk has run in the board testbench only; the bitstream with the
  transport is not built yet (the 50 MHz bitstream in flash, 0183b335,
  predates it).
- The DMA engine of `slop_card` is instantiated but its masters are tied
  off (CAP_DMA clear).
- A wider DRAM window and the core's bus timing (one request at a time
  through the bridge) are the performance items.
