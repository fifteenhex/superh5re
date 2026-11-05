CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -std=gnu99

all: sh5ctl

sh5ctl: sh5ctl.c sh5boot.c sh5boot.h
	$(CC) $(CFLAGS) -o $@ sh5ctl.c sh5boot.c

clean:
	rm -f sh5ctl

.PHONY: all clean
