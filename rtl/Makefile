VERILATOR ?= verilator
TOP ?= sh5_core
# Core sources in dependency order. FPU: the real unit when present, else the placeholder.
FPU_SRC ?= $(if $(wildcard sh5_fpu.sv),$(wildcard sh5_fpu*.sv),tb/stubs/sh5_fpu_stub.sv)
SRCS = shwy_pkg.sv sh5_pkg.sv sh5_uop_pkg.sv sh5_decode.sv sh5_alu.sv sh5_ctrl.sv sh5_tlb.sv sh5_icache.sv sh5_dcache.sv sh5_biu.sv \
       sh5_ifu.sv sh5_mm.sv $(FPU_SRC) sh5_core.sv
LINTFLAGS = -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-SYNCASYNCNET

lint:
	$(VERILATOR) --lint-only $(LINTFLAGS) --top-module $(TOP) $(SRCS)

.PHONY: lint
