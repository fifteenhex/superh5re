# Bare-metal test of the Linux sh64 string routines on qemu-system-sh5.
#   make LINUX=/path/to/linux CROSS=sh64-linux-
LINUX ?= ../../linux
CROSS ?= sh64-linux-
CC = $(CROSS)gcc
CFLAGS = -m5-32media-nofpu -ml -O2 -ffreestanding -nostdlib -fno-builtin \
	 -Wa,-isa=shmedia
AFLAGS = -m5-32media-nofpu -ml -Wa,-isa=shmedia -D__ASSEMBLY__ -D__KERNEL__ \
	 -I$(LINUX)/include -I$(LINUX)/arch/sh/include
LIBSRC = $(LINUX)/arch/sh/lib64

lib64test.elf: start.o test.o cstring.o memcpy.o memset.o strlen.o strcpy.o link.ld
	$(CROSS)ld -m shlelf32_linux -T link.ld -o $@ start.o test.o cstring.o memcpy.o memset.o strlen.o strcpy.o

start.o: start.S
	$(CC) $(AFLAGS) -c -o $@ $<
%.o: $(LIBSRC)/%.S
	$(CC) $(AFLAGS) -c -o $@ $<
test.o: test.c
	$(CC) $(CFLAGS) -c -o $@ $<

run: lib64test.elf
	qemu-system-sh5 -M cayman -kernel $< -nographic

clean:
	rm -f *.o lib64test.elf
cstring.o: cstring.c
	$(CC) $(CFLAGS) -c -o $@ $<
