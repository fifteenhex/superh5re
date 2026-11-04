# RTL

SystemVerilog for the SH-5 core described in `docs/core-design.md`.
Implementation status is in that document's last section.

| File | Contents |
|---|---|
| `sh5_pkg.sv` | architectural constants: control register numbers, SR and FPSCR fields, event codes and vector offsets, PTE layout, configuration-space map, cache geometry and tag views, instruction fields, opcode map (Vol. 2 Tables 36-66) |
| `shwy_pkg.sv` | bus packet opcodes, header types, byte-mask and burst-order helpers (`docs/bus-interface.md`) |
| `sh5_uop_pkg.sv` | decoded instruction (micro-op) record |
| `sh5_decode.sv` | SHmedia decoder, exception precedence at decode |
| `sh5_alu.sv` | 64-bit integer ALU (E1) |
| `sh5_mm.sv` | SIMD unit and MULS.L/MULU.L, 3 stages |
| `sh5_fpu.sv` | floating-point unit, all 36 arithmetic operations, early trap decision |
| `sh5_tlb.sv` | 64-entry PTE array with configuration access and lookup (one instance each for MMUIR and MMUDR) |
| `sh5_icache.sv` | instruction cache: 4 ways x 256 sets x 32 B, EA indexed and tagged (ASID/SH, PRU copy), LRU, locking, ICBI, configuration view |
| `sh5_dcache.sv` | operand cache: EA and PA tags, write-back/write-through per block, alias resolution by re-tagging, OCBI/OCBP/OCBWB/ALLOCO, SWAP purge, LRU, locking, configuration view |
| `sh5_ctrl.sv` | control registers, FPSCR, ICCR/OCCR, event launch and RTE |
| `sh5_ifu.sv` | fetch queue, 8-byte blocks, redirect |
| `sh5_biu.sv` | bus packets: Load8/Load32 fetch and data, Swap8, Store8/Store32 queue |
| `sh5_core.sv` | pipeline D E1 E2 E3 W, register files, forwarding, hazards, memory ordering, target register buffers and branch prediction, VCR target port |
| `tb/core/` | Verilator testbench: ELF loader, memory, Cayman SCIF/INTC/TMU/CPRC/RTC/VCR models, commit and bus trace |
| `tb/unit/mm/`, `tb/unit/fpu/` | unit tests of the SIMD unit and the FPU against the test-kit references and vectors |
| `tb/stubs/` | FPU placeholder for builds without the FPU |
| `Makefile` | `make lint` runs Verilator in lint mode |

```
make lint                      # Verilator lint of the core
make -C tb/core build          # build the model
cd tb/core && ./obj/Vsh5_core --elf ../../../tests/isa/isatest-bare.elf --quiet
./obj/Vsh5_core --elf ../../../tests/exc/exc.elf --quiet
./obj/Vsh5_core --elf vmlinux --cmdline "console=ttySC0 ..." --initrd rootfs.cpio.gz \
    --console-log console.txt --trace trace.txt --trace-max 1000000
make -C tb/unit/mm test        # SIMD unit against the C references
make -C tb/unit/fpu test       # FPU against the generated vectors
```

Testbench options: `--max-cycles N`, `--latency N` (bus response delay),
`--trace FILE [--trace-max N] [--bus]` (one line per committed instruction:
pc, encoding, register write; `launch` lines for events; `bus` lines for
packets), `--done STRING` (stop when the console printed it), `--quiet`.
The final line reports cycles, committed instructions, branches predicted
taken and fetch redirects by resolved branches.
`tools/tracecmp.py` compares the trace with a QEMU `-d exec,nochain`
log (`--irq VEC` skips interrupt handlers entered at different points),
`tools/regcmp.py` compares register writes with QEMU `-d cpu` dumps.
