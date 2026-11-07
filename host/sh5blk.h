/*
 * sh5blk.h - a virtio-blk device for the SH-5 card, served by the host.
 *
 * The transport is fpgaslop's slop_virtio (rtl/soc/sh5_top.sv instantiates
 * it): the guest sees a stock virtio-mmio v2 register block at
 * 0x0b00_0000 and Linux binds it from `virtio_mmio.device=0x200@0x0b000000:63`
 * with nothing added. The virtqueue lives in the card's DRAM, which the
 * host reaches through the BAR; the host side of the register block is at
 * register window +0x2_0000. This file is the device: it presents the
 * identity, waits for the driver, and serves the queue from a file.
 *
 * Used by the board testbench (rtl/tb/board) and by sh5ctl alike through
 * struct sh5_bar, like the deposit protocol in sh5boot.h.
 */
#ifndef SH5BLK_H
#define SH5BLK_H

#include <stdint.h>
#include "sh5boot.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SH5_BAR_VIO       (SH5_BAR_REGS + 0x20000)   /* host pages of the virtio slots */
#define SH5_VIO_GUEST     0x0b000000u                /* guest page of slot 0 (SH-5 physical) */
#define SH5_VIO_IRQ       63                         /* INTC source 63, Linux irq 63 */

struct sh5blk;

/* Open the backing file (read-write unless `readonly`) and present the
 * device on slot `slot`; call while the core is held, before the kernel
 * probes. Returns NULL with a message in msg on failure. */
struct sh5blk *sh5blk_open(const struct sh5_bar *b, unsigned slot, const char *image,
			   int readonly, char *msg, size_t msglen);

/* Serve whatever the driver has queued. Call often (every few hundred
 * core cycles in simulation, every millisecond on hardware). Returns the
 * number of requests completed, or -1 if the ring is unusable. */
int sh5blk_poll(struct sh5blk *d);

/* Statistics for the summary line. */
void sh5blk_stats(const struct sh5blk *d, unsigned long *reads, unsigned long *writes,
		  unsigned long *bytes);

void sh5blk_close(struct sh5blk *d);

#ifdef __cplusplus
}
#endif
#endif
