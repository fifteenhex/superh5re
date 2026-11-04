# SH-5 SHcompact ISA test kit.
#   make [MODE=sh5|sh4] [GROUPS="arith mem"]   build compact-$(MODE).elf (sh4: also .bin)
#   make run-sh4        run the SH-4 build on qemu-system-sh4 -M r2d (reference check of the kit)
#   make rtl            run the SH-5 build on the Verilator model of ../../rtl
MODE ?= sh5
CROSS ?= sh64-linux-
CC = $(CROSS)gcc
QEMU_SH4 ?= qemu-system-sh4
RTL_TB ?= ../../rtl/tb/core/obj/Vsh5_core

GROUP_SRCS = $(if $(GROUPS),$(addsuffix .c,$(addprefix groups/,$(GROUPS))),$(wildcard groups/*.c))
SEL = $(if $(GROUPS),-$(subst $(eval) ,_,$(strip $(GROUPS))),)
ELF = compact-$(MODE)$(SEL).elf
BIN = compact-$(MODE)$(SEL).bin

CFLAGS_COMMON = -O1 -g -Wall -Wno-unused-function -ffreestanding -fno-stack-protector -fno-builtin -I.
LDFLAGS = -nostdlib -static

ifeq ($(MODE),sh5)
CFLAGS = -m5-32media -mdiv=call -Wa,-isa=shmedia $(CFLAGS_COMMON)
SRCS = bare_sh5.c harness.c $(GROUP_SRCS)
OBJS = start_sh5.o cops.o $(SRCS:.c=.sh5.o)
LDSCRIPT = sh5.ld
else
CFLAGS = -m5-compact -Wa,-isa=shcompact $(CFLAGS_COMMON) -DISA_SH4
SRCS = bare_sh4.c harness.c $(GROUP_SRCS)
OBJS = start_sh4.o cops.o $(SRCS:.c=.sh4.o)
LDSCRIPT = sh4.ld
endif

all: $(ELF) $(if $(filter sh4,$(MODE)),$(BIN))

$(ELF): $(OBJS) $(LDSCRIPT)
	$(CC) $(CFLAGS) $(LDFLAGS) -T $(LDSCRIPT) -o $@ $(OBJS) $(if $(filter sh5,$(MODE)),-lgcc)

$(BIN): $(ELF)
	python3 elf2bin.py $< $@

cops.S cops.h: gen_cops.py $(wildcard groups/*_cops.py)
	python3 gen_cops.py

%.sh5.o: %.c harness.h cops.h
	$(CC) $(CFLAGS) -c -o $@ $<
%.sh4.o: %.c harness.h cops.h
	$(CC) $(CFLAGS) -c -o $@ $<
cops.o: cops.S
	$(CC) -m5-compact -Wa,-isa=shcompact -c -o $@ $<
start_sh5.o: start_sh5.S
	$(CC) -m5-32media -Wa,-isa=shmedia -c -o $@ $<
start_sh4.o: start_sh4.S
	$(CC) -m5-compact -Wa,-isa=shcompact -c -o $@ $<

run-sh4:
	$(MAKE) MODE=sh4 GROUPS="$(GROUPS)" compact-sh4$(SEL).bin
	timeout 600 $(QEMU_SH4) -M r2d -display none -monitor none -serial null -serial stdio -kernel compact-sh4$(SEL).bin \
		| tee compact-sh4$(SEL).log | grep -a '^isa:' ; true

rtl:
	$(MAKE) MODE=sh5 GROUPS="$(GROUPS)" compact-sh5$(SEL).elf
	$(RTL_TB) --elf compact-sh5$(SEL).elf --done "isa: DONE" --max-cycles 400000000

clean:
	rm -f *.o groups/*.o *.elf *.bin *.log cops.S cops.h

.PHONY: all run-sh4 rtl clean
