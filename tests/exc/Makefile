# SH-5 exception, trap and privileged-state test (bare metal, MMU off).
#   make          build exc.elf
#   make run      run on qemu-system-sh5 (Cayman), print the exc:/isa: lines
#   make rtl      run on the Verilator model of ../../rtl
CROSS ?= sh64-linux-
CC = $(CROSS)gcc
QEMU ?= qemu-system-sh5
RTL_TB ?= ../../rtl/tb/core/obj/Vsh5_core

CFLAGS = -m5-32media -mdiv=call -O1 -g -Wall -ffreestanding \
	 -fno-stack-protector -fno-builtin -Wa,-isa=shmedia -I.
LDFLAGS = -nostdlib -static -T exc.ld
OBJS = start.o console.o exc.o

all: exc.elf

exc.elf: $(OBJS) exc.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS) -lgcc

%.o: %.c exc.h
	$(CC) $(CFLAGS) -c -o $@ $<
start.o: start.S exc.h
	$(CC) -m5-32media -Wa,-isa=shmedia -I. -c -o $@ $<

run: exc.elf
	QEMU=$(QEMU) python3 ../../tools/qrun.py --kernel exc.elf --timeout 120 \
		--log exc-qemu.log 'expect:isa: DONE' | grep '^\(exc\|isa\):'

rtl: exc.elf
	$(RTL_TB) --elf exc.elf --done "isa: DONE" --max-cycles 20000000

clean:
	rm -f *.o *.elf *.log qrun.out

.PHONY: all run rtl clean
