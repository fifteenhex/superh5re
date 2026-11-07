CC ?= gcc
SLOP ?= ../fpgaslop/host
CFLAGS ?= -O2 -Wall -Wextra -std=gnu99 -I$(SLOP)

all: sh5ctl

# sh5blk serves a virtio-blk device over fpgaslop's host-side virtqueue
# and transport library
sh5ctl: sh5ctl.c sh5boot.c sh5boot.h sh5blk.c sh5blk.h $(SLOP)/slop_virtq.c $(SLOP)/slop_vmmio.c
	$(CC) $(CFLAGS) -o $@ sh5ctl.c sh5boot.c sh5blk.c $(SLOP)/slop_virtq.c $(SLOP)/slop_vmmio.c

clean:
	rm -f sh5ctl

.PHONY: all clean
