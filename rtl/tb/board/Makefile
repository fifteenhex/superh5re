VERILATOR ?= verilator
RTL = ../..
SLOP = ../../../fpgaslop/rtl
HOST = ../../../host
FPU_SRC ?= $(if $(wildcard $(RTL)/sh5_fpu.sv),$(wildcard $(RTL)/sh5_fpu*.sv),$(RTL)/tb/stubs/sh5_fpu_stub.sv)
CORE_SRCS = $(RTL)/shwy_pkg.sv $(RTL)/sh5_pkg.sv $(RTL)/sh5_uop_pkg.sv $(RTL)/sh5_decode.sv \
       $(RTL)/sh5_alu.sv $(RTL)/sh5_cexpand.sv $(RTL)/sh5_ctrl.sv $(RTL)/sh5_tlb.sv $(RTL)/sh5_icache.sv \
       $(RTL)/sh5_dcache.sv $(RTL)/sh5_biu.sv $(RTL)/sh5_ifu.sv $(RTL)/sh5_mm.sv $(FPU_SRC) $(RTL)/sh5_core.sv
SOC_SRCS = $(RTL)/soc/sh5_shwy_req.sv $(RTL)/soc/sh5_periph.sv $(RTL)/soc/sh5_hub.sv \
       $(RTL)/soc/sh5_hostif.sv $(RTL)/soc/sh5_top.sv
SLOP_SRCS = $(SLOP)/slop_id.sv $(SLOP)/slop_reset.sv $(SLOP)/slop_mailbox.sv $(SLOP)/slop_flashreg.sv \
       $(SLOP)/slop_spiflash.sv $(SLOP)/slop_dma.sv $(SLOP)/slop_dmadesc.sv $(SLOP)/slop_dmablk.sv \
       $(SLOP)/slop_card.sv $(SLOP)/memarb.sv
VFLAGS = --cc --exe --build -O3 -Wno-fatal -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
         -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY -Wno-GENUNNAMED -Wno-SYNCASYNCNET \
         --top-module sh5_top -Mdir obj --x-assign fast --x-initial fast \
         -CFLAGS "-I$(abspath $(HOST))" -GAUTOSTART=0 -GCLK_HZ=25000000

obj/Vsh5_top: $(CORE_SRCS) $(SOC_SRCS) $(SLOP_SRCS) tb_board.cpp $(HOST)/sh5boot.c $(HOST)/sh5boot.h
	$(VERILATOR) $(VFLAGS) $(CORE_SRCS) $(SOC_SRCS) $(SLOP_SRCS) tb_board.cpp $(HOST)/sh5boot.c -o Vsh5_top

build: obj/Vsh5_top

# the bare suites through the host path
check: obj/Vsh5_top
	./obj/Vsh5_top --elf ../../../tests/exc/exc.elf --quiet
	./obj/Vsh5_top --elf ../../../tests/isa/isatest-bare-arith.elf --quiet

clean:
	rm -rf obj logs

.PHONY: build check clean
