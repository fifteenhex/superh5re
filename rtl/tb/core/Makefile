VERILATOR ?= verilator
RTL = ../..
FPU_SRC ?= $(if $(wildcard $(RTL)/sh5_fpu.sv),$(wildcard $(RTL)/sh5_fpu*.sv),$(RTL)/tb/stubs/sh5_fpu_stub.sv)
SRCS = $(RTL)/shwy_pkg.sv $(RTL)/sh5_pkg.sv $(RTL)/sh5_uop_pkg.sv $(RTL)/sh5_decode.sv \
       $(RTL)/sh5_alu.sv $(RTL)/sh5_cexpand.sv $(RTL)/sh5_ctrl.sv $(RTL)/sh5_tlb.sv $(RTL)/sh5_icache.sv $(RTL)/sh5_dcache.sv $(RTL)/sh5_biu.sv $(RTL)/sh5_ifu.sv \
       $(RTL)/sh5_mm.sv $(FPU_SRC) $(RTL)/sh5_core.sv
VFLAGS = --cc --exe --build -O3 -Wno-fatal -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
         --top-module sh5_core -Mdir obj --x-assign fast --x-initial fast
ISA = ../../../tests/isa

obj/Vsh5_core: $(SRCS) tb_core.cpp
	$(VERILATOR) $(VFLAGS) $(SRCS) tb_core.cpp -o Vsh5_core

build: obj/Vsh5_core

# Run the bare-metal ISA test kit (built in tests/isa with MODE=bare)
run-%: obj/Vsh5_core
	./obj/Vsh5_core --elf $(ISA)/isatest-bare-$*.elf --quiet --trace run-$*.trace 2>&1 | tail -3

clean:
	rm -rf obj *.trace

.PHONY: build clean
