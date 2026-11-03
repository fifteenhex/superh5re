VERILATOR ?= verilator
TOP ?= sh5_core
SRCS = shwy_pkg.sv sh5_pkg.sv sh5_core.sv

lint:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDPARAM --top-module $(TOP) $(SRCS)

.PHONY: lint
