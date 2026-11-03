# RTL

SystemVerilog for the SH-5 core described in `docs/core-design.md`.

| File | Contents |
|---|---|
| `sh5_pkg.sv` | architectural constants: control register numbers, SR and FPSCR fields, event codes and vector offsets, PTE layout, configuration-space map, cache geometry and tag views, instruction fields, opcode map (Vol. 2 Tables 36-66) |
| `shwy_pkg.sv` | bus packet opcodes, header types, byte-mask and burst-order helpers (`docs/bus-interface.md`) |
| `sh5_core.sv` | top-level port contract; target port (VCR) implemented, the rest tied off |
| `Makefile` | `make lint` runs Verilator in lint mode |

Planned modules: `sh5_ifu`, `sh5_icache`, `sh5_itlb`, `sh5_decode`,
`sh5_imu`, `sh5_lsu`, `sh5_dcache`, `sh5_dtlb`, `sh5_fpu`,
`sh5_regfile_gr`, `sh5_regfile_fr`, `sh5_ctrl`, `sh5_biu`.
