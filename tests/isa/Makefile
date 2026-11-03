# SH-5 SHmedia ISA test kit.
#   make [MODE=nolibc|bare] [GROUPS="arith logic"]   build isatest-$(MODE).elf
#   make run [MODE=...]                              run it on qemu-system-sh5
# MODE=nolibc needs NOLIBCDIR (tools/include/nolibc with the SH-5 patch) and
# UAPIDIR (make headers_install of the sh64 kernel), and for `make run` the
# sh64 kernel in KERNEL.  MODE=bare needs nothing but the toolchain.
MODE ?= nolibc
CROSS ?= sh64-linux-
CC = $(CROSS)gcc
QEMU ?= qemu-system-sh5
KERNEL ?= ../../../linux-sh5/vmlinux
NOLIBCDIR ?= $(HOME)/sh5work/nolibc-src/tools/include/nolibc
UAPIDIR ?= $(HOME)/sh5work/uapi-sh64/include

GROUP_SRCS = $(if $(GROUPS),$(addsuffix .c,$(addprefix groups/,$(GROUPS))),$(wildcard groups/*.c))

CFLAGS = -m5-32media -mdiv=call -O1 -g -Wall -Wno-unused-function \
	 -fno-stack-protector -fno-builtin -Wa,-isa=shmedia -I.
LDFLAGS = -nostdlib -static

ifeq ($(MODE),nolibc)
CFLAGS += -include $(NOLIBCDIR)/nolibc.h -I$(NOLIBCDIR) -I$(UAPIDIR)
SRCS = nolibc.c harness.c $(GROUP_SRCS)
OBJS = $(SRCS:.c=.nolibc.o)
else
CFLAGS += -ffreestanding -DISA_BARE
SRCS = bare.c harness.c $(GROUP_SRCS)
OBJS = start.o $(SRCS:.c=.bare.o)
LDFLAGS += -T bare.ld
endif

# Per-selection output names so that parallel runs of different groups do not
# overwrite each other's image, cpio and log.
SEL = $(if $(GROUPS),-$(subst $(eval) ,_,$(strip $(GROUPS))),)
ELF = isatest-$(MODE)$(SEL).elf
CPIO = isatest$(SEL).cpio
LOG = isatest-$(MODE)$(SEL).log

all: $(ELF)

$(ELF): $(OBJS) $(if $(filter bare,$(MODE)),bare.ld)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS) -lgcc

# groups include generated vector headers; rebuild when they change
%.nolibc.o: %.c harness.h $(wildcard groups/*.h)
	$(CC) $(CFLAGS) -c -o $@ $<
%.bare.o: %.c harness.h $(wildcard groups/*.h)
	$(CC) $(CFLAGS) -c -o $@ $<
start.o: start.S
	$(CC) -m5-32media -Wa,-isa=shmedia -c -o $@ $<

$(CPIO): $(ELF)
	rm -rf initrd$(SEL) && mkdir initrd$(SEL) && cp $< initrd$(SEL)/init && \
	(cd initrd$(SEL) && echo init | cpio -o -H newc 2>/dev/null) > $@

ifeq ($(MODE),nolibc)
run: $(CPIO)
	QEMU=$(QEMU) python3 ../../tools/qrun.py --kernel $(KERNEL) --timeout 600 \
		--qemu-args '-initrd $(CPIO) -append "console=ttySC0 -- $(ARGS)" -no-reboot' \
		--log $(LOG) 'expect:isa: DONE' | grep '^isa:'
else
run: $(ELF)
	QEMU=$(QEMU) python3 ../../tools/qrun.py --kernel $(ELF) --timeout 600 \
		--log $(LOG) 'expect:isa: DONE' | grep '^isa:'
endif

clean:
	rm -rf *.o groups/*.o *.elf *.cpio initrd* *.log

.PHONY: all run clean
