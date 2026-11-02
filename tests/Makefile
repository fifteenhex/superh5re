# Bare-metal SHmedia tests. Needs a sh64-elf binutils (2.30 is the last
# release with SH-5 support, configure with --target=sh64-elf --enable-obsolete).
CROSS ?= sh64-elf-
AS = $(CROSS)as
LD = $(CROSS)ld
TESTS = add64.elf

all: $(TESTS)

%.o: %.S
	$(AS) -isa=shmedia -abi=32 -little $< -o $@

%.elf: %.o
	$(LD) -m shlelf32 -Ttext 0xc0000000 -e _start $< -o $@

clean:
	rm -f *.o *.elf
