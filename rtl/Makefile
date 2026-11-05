VERILATOR ?= verilator
TOP ?= sh5_core
# Core sources in dependency order. FPU: the real unit when present, else the placeholder.
FPU_SRC ?= $(if $(wildcard sh5_fpu.sv),$(wildcard sh5_fpu*.sv),tb/stubs/sh5_fpu_stub.sv)
SRCS = shwy_pkg.sv sh5_pkg.sv sh5_uop_pkg.sv sh5_decode.sv sh5_alu.sv sh5_ctrl.sv sh5_tlb.sv sh5_icache.sv sh5_dcache.sv sh5_biu.sv sh5_cexpand.sv \
       sh5_ifu.sv sh5_mm.sv $(FPU_SRC) sh5_core.sv
LINTFLAGS = -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-SYNCASYNCNET

# the system around the core (rtl/soc) with fpgaslop's blocks
SLOP = ../fpgaslop/rtl
SOC_SRCS = soc/sh5_shwy_req.sv soc/sh5_periph.sv soc/sh5_hub.sv soc/sh5_hostif.sv soc/sh5_top.sv
SLOP_SRCS = $(SLOP)/slop_id.sv $(SLOP)/slop_reset.sv $(SLOP)/slop_mailbox.sv $(SLOP)/slop_flashreg.sv \
            $(SLOP)/slop_spiflash.sv $(SLOP)/slop_dma.sv $(SLOP)/slop_dmadesc.sv $(SLOP)/slop_dmablk.sv \
            $(SLOP)/slop_card.sv $(SLOP)/memarb.sv
SOC_LINTFLAGS = $(LINTFLAGS) -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY -Wno-GENUNNAMED

lint:
	$(VERILATOR) --lint-only $(LINTFLAGS) --top-module $(TOP) $(SRCS)

lint-soc:
	$(VERILATOR) --lint-only $(SOC_LINTFLAGS) --top-module sh5_top $(SRCS) $(SOC_SRCS) $(SLOP_SRCS)

# the board top with fpgaslop's primitive stubs; the Vivado IP are black boxes
lint-board:
	cd .. && fpgaslop/boards/nitefury/lint-top.sh --tcl fpga/nitefury/build.tcl --top sh5_board_top \
	  --var root=fpgaslop --var sh5dir=. --var here=fpga/nitefury \
	  --blackbox 'IBUFDS_GTE2|sh5_pcie_ep|sh5_pcie_cdc|sh5_ddr3'

.PHONY: lint lint-soc lint-board
