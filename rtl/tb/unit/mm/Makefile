# Unit test for rtl/sh5_mm.sv: Verilator model driven by a C++ testbench
# against the host-compiled references of tests/isa/groups/mmedia1.c and
# mmedia2.c.  `make test` builds and runs it.

VERILATOR ?= verilator
CC        ?= gcc
RTL        = ../../..
ISA        = ../../../../tests/isa
OBJ        = obj_dir
NRANDOM   ?= 100000

RTL_SRCS = $(RTL)/sh5_pkg.sv $(RTL)/sh5_mm.sv
REF_OBJS = $(OBJ)/ref_mm1.o $(OBJ)/ref_mm2.o $(OBJ)/isa_harness.o $(OBJ)/isa_stubs.o

VFLAGS = --cc --exe --build -Wall -Wno-UNUSEDPARAM --top-module sh5_mm \
         -Mdir $(OBJ) -o tb_mm \
         -CFLAGS "-O2 -I$(abspath .) -DNRANDOM=$(NRANDOM)"

.PHONY: test build lint clean

test: build
	$(OBJ)/tb_mm

build: $(OBJ)/tb_mm

$(OBJ)/tb_mm: $(RTL_SRCS) tb_mm.cpp ref_mm.h $(REF_OBJS)
	$(VERILATOR) $(VFLAGS) $(RTL_SRCS) tb_mm.cpp $(abspath $(REF_OBJS))

# The group files see the stand-in harness.h in this directory first.
$(OBJ)/ref_mm1.o: ref_mm1.c ref_mm.h harness.h $(ISA)/groups/mmedia1.c
	@mkdir -p $(OBJ)
	$(CC) -O2 -Wall -I. -I$(ISA) -c $< -o $@

$(OBJ)/ref_mm2.o: ref_mm2.c ref_mm.h harness.h $(ISA)/groups/mmedia2.c
	@mkdir -p $(OBJ)
	$(CC) -O2 -Wall -I. -I$(ISA) -c $< -o $@

# Operand corpus and isa_rand, built with the real tests/isa/harness.h.
$(OBJ)/isa_harness.o: $(ISA)/harness.c $(ISA)/harness.h
	@mkdir -p $(OBJ)
	$(CC) -O2 -Wall -c $< -o $@

$(OBJ)/isa_stubs.o: isa_stubs.c
	@mkdir -p $(OBJ)
	$(CC) -O2 -Wall -c $< -o $@

lint:
	cd $(RTL) && $(VERILATOR) --lint-only -Wall -Wno-UNUSEDPARAM sh5_pkg.sv sh5_mm.sv --top-module sh5_mm

clean:
	rm -rf $(OBJ)
