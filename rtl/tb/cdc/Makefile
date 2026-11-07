# The memory path with sh5_mem_cdc: memarb, the crossing, req_to_axi4 and an
# AXI slave, two clocks at 4:1 (rtl/tb/cdc/tb_cdc.cpp).
#   make check            random traffic against a model, then the cost per access
VERILATOR ?= verilator
RTL  = ../..
SLOP = ../../../fpgaslop/rtl
SRCS = $(RTL)/soc/sh5_afifo.sv $(RTL)/soc/sh5_mem_cdc.sv $(SLOP)/memarb.sv $(SLOP)/req_to_axi4.sv tb_cdc_top.sv
VFLAGS = --cc --exe --build -O2 -Wno-fatal -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
         -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN \
         --top-module tb_cdc_top -Mdir obj --x-assign fast --x-initial fast

obj/Vtb_cdc_top: $(SRCS) tb_cdc.cpp
	$(VERILATOR) $(VFLAGS) $(SRCS) tb_cdc.cpp -o Vtb_cdc_top

build: obj/Vtb_cdc_top

check: obj/Vtb_cdc_top
	./obj/Vtb_cdc_top 12
	./obj/Vtb_cdc_top 1

clean:
	rm -rf obj

.PHONY: build check clean
