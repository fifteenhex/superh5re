VERILATOR ?= verilator
RTL  = ../../..
VEC  = ../../../../tests/isa/groups
SRCS = $(RTL)/sh5_pkg.sv $(wildcard $(RTL)/sh5_fpu*.sv)

test: obj_dir/Vsh5_fpu
	./obj_dir/Vsh5_fpu

obj_dir/Vsh5_fpu: $(SRCS) tb_fpu.cpp
	$(VERILATOR) --cc --exe --build -Wall -Wno-UNUSEDPARAM --top-module sh5_fpu \
		-CFLAGS "-std=c++17 -O2 -frounding-math -I$(abspath $(VEC))" \
		$(SRCS) tb_fpu.cpp -o Vsh5_fpu

clean:
	rm -rf obj_dir

.PHONY: test clean
