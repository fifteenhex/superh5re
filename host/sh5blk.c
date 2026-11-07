/* sh5blk.c - a virtio-blk device served from a file, see sh5blk.h. The
 * ring handling and the transport registers are fpgaslop's host library
 * (fpgaslop/host/slop_virtq.c, slop_vmmio.c); this file knows what a block
 * request is. Plain C, also compiled as C++ by the testbench. */
#include "sh5blk.h"
#include "slop_virtq.h"
#include "slop_vmmio.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#define VIRTIO_ID_BLOCK      2
#define VIRTIO_BLK_T_IN      0
#define VIRTIO_BLK_T_OUT     1
#define VIRTIO_BLK_T_FLUSH   4
#define VIRTIO_BLK_T_GET_ID  8
#define VIRTIO_BLK_S_OK      0
#define VIRTIO_BLK_S_IOERR   1
#define VIRTIO_BLK_S_UNSUPP  2
#define VIRTIO_BLK_F_RO      (1u << 5)
#define VIRTIO_BLK_F_FLUSH   (1u << 9)

#define QUEUE_MAX  16          /* descriptors the driver may use */
#define MAX_IO     (QUEUE_MAX * 4096 + 64)

struct sh5blk {
	const struct sh5_bar *bar;
	int fd, readonly, debug, said_status, said_istatus;
	uint64_t sectors;
	slop_vmmio t;
	slop_virtq q;
	int q_ready;
	unsigned long n_read, n_write, n_bytes, polls;
	uint8_t *buf;
};

/* ---- guest memory through the DRAM window, any alignment ---- */
static int gmem_read(void *user, uint64_t gpa, void *dst, size_t len)
{
	const struct sh5_bar *b = (const struct sh5_bar *)user;
	uint8_t *p = (uint8_t *)dst;

	if (gpa < SH5_RAM_PHYS || gpa + len > (uint64_t)SH5_RAM_PHYS + SH5_RAM_BYTES)
		return -1;
	while (len) {
		uint64_t w = sh5_read_mem64(b, (uint32_t)gpa);
		unsigned lane = gpa & 7, n = 8 - lane;
		if (n > len) n = len;
		for (unsigned i = 0; i < n; i++)
			p[i] = (uint8_t)(w >> (8 * (lane + i)));
		gpa += n; p += n; len -= n;
	}
	return 0;
}

static int gmem_write(void *user, uint64_t gpa, const void *src, size_t len)
{
	const struct sh5_bar *b = (const struct sh5_bar *)user;

	if (gpa < SH5_RAM_PHYS || gpa + len > (uint64_t)SH5_RAM_PHYS + SH5_RAM_BYTES)
		return -1;
	sh5_write_mem(b, (uint32_t)gpa, src, len);
	return 0;
}

/* ---- the transport's host page ---- */
static uint64_t vio_rd(void *user, uint32_t off)
{
	const struct sh5_bar *b = (const struct sh5_bar *)user;
	return b->read64(b->ctx, SH5_BAR_VIO + off);
}

static void vio_wr(void *user, uint32_t off, uint64_t v)
{
	const struct sh5_bar *b = (const struct sh5_bar *)user;
	b->write64(b->ctx, SH5_BAR_VIO + off, v, 0xff);
}

static void put_le64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static uint32_t get_le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t get_le64(const uint8_t *p) { return get_le32(p) | (uint64_t)get_le32(p + 4) << 32; }

struct sh5blk *sh5blk_open(const struct sh5_bar *b, unsigned slot, const char *image,
			   int readonly, char *msg, size_t msglen)
{
	struct sh5blk *d = (struct sh5blk *)calloc(1, sizeof(*d));
	struct stat st;
	slop_vmmio_io io;
	uint8_t cfg[8];

	if (!d) return NULL;
	d->bar = b;
	d->readonly = readonly;
	d->fd = open(image, readonly ? O_RDONLY : O_RDWR);
	if (d->fd < 0 || fstat(d->fd, &st)) {
		if (msg) snprintf(msg, msglen, "cannot open %s", image);
		free(d);
		return NULL;
	}
	d->sectors = (uint64_t)st.st_size / 512;
	d->buf = (uint8_t *)malloc(MAX_IO);
	d->debug = getenv("SH5BLK_DEBUG") != NULL;     /* trace the driver's steps and every request */

	io.rd = vio_rd; io.wr = vio_wr; io.user = (void *)b;
	slop_vmmio_init(&d->t, &io, slot);
	put_le64(cfg, d->sectors);
	slop_vmmio_config(&d->t, 0, cfg, 8);              /* capacity, in 512-byte sectors */
	slop_vmmio_present(&d->t, VIRTIO_ID_BLOCK, 0x53483500 /* "SH5" */,
			   (readonly ? VIRTIO_BLK_F_RO : 0) | VIRTIO_BLK_F_FLUSH, QUEUE_MAX);
	/* VIRTIO_F_ACCESS_PLATFORM (bit 33): the device is not coherent with the
	 * CPU's write-back cache. With it Linux puts the ring in an uncached
	 * mapping and flushes/invalidates every buffer around a request (the
	 * DMA API); without it the guest uses plain cached memory and the host
	 * sees an avail index only when its line happens to leave the cache,
	 * and the guest misses the used index the same way. The library's
	 * present() sets bit 32 (VERSION_1) in the same bank. */
	vio_wr((void *)b, SLOP_VMMIO_R_DEVFEAT, vio_rd((void *)b, SLOP_VMMIO_R_DEVFEAT) | (2ull << 32));
	if (msg) snprintf(msg, msglen, "virtio-blk slot %u: %s, %llu sectors%s", slot, image,
			  (unsigned long long)d->sectors, readonly ? ", read-only" : "");
	return d;
}

static int serve(struct sh5blk *d, slop_virtq_chain *c)
{
	uint8_t status = VIRTIO_BLK_S_OK;
	size_t out = 0;                /* bytes of reply before the status byte */

	if (c->in_len < 16 || c->out_len < 1) {
		status = VIRTIO_BLK_S_IOERR;
	} else {
		uint32_t type = get_le32(c->in);
		uint64_t sector = get_le64(c->in + 8);
		if (type == VIRTIO_BLK_T_IN) {
			size_t len = c->out_len - 1;
			if (len > MAX_IO - 1 || sector * 512 + len > d->sectors * 512) {
				status = VIRTIO_BLK_S_IOERR;
			} else if (pread(d->fd, d->buf, len, (off_t)(sector * 512)) != (ssize_t)len) {
				status = VIRTIO_BLK_S_IOERR;
			} else {
				out = len; d->n_read++; d->n_bytes += len;
			}
		} else if (type == VIRTIO_BLK_T_OUT) {
			size_t len = c->in_len - 16;
			if (d->readonly || sector * 512 + len > d->sectors * 512) {
				status = VIRTIO_BLK_S_IOERR;
			} else if (pwrite(d->fd, c->in + 16, len, (off_t)(sector * 512)) != (ssize_t)len) {
				status = VIRTIO_BLK_S_IOERR;
			} else {
				d->n_write++; d->n_bytes += len;
			}
		} else if (type == VIRTIO_BLK_T_FLUSH) {
			if (!d->readonly && fsync(d->fd)) status = VIRTIO_BLK_S_IOERR;
		} else if (type == VIRTIO_BLK_T_GET_ID) {
			memset(d->buf, 0, 20);
			memcpy(d->buf, "sh5blk0", 7);
			out = c->out_len - 1 < 20 ? c->out_len - 1 : 20;
		} else {
			status = VIRTIO_BLK_S_UNSUPP;
		}
	}
	d->buf[out] = status;
	return slop_virtq_push(&d->q, c, d->buf, out + 1);
}

int sh5blk_poll(struct sh5blk *d)
{
	int done = 0;

	if (!d->q_ready) {
		slop_virtq_mem mem;
		int r;
		uint32_t st = slop_vmmio_status(&d->t);
		if (d->debug && st != (uint32_t)d->said_status) {
			fprintf(stderr, "sh5blk: driver status %x\n", st);
			d->said_status = (int)st;
		}
		if (!(st & SLOP_VMMIO_S_DRIVER_OK))
			return 0;
		memset(&mem, 0, sizeof mem);
		mem.read = gmem_read; mem.write = gmem_write; mem.user = (void *)d->bar;
		r = slop_vmmio_queue(&d->t, 0, &mem, &d->q);
		if (r <= 0) {
			if (d->debug && r < 0) fprintf(stderr, "sh5blk: queue 0 unusable as programmed\n");
			return r;
		}
		d->q_ready = 1;
		if (d->debug)
			fprintf(stderr, "sh5blk: queue 0 ready: %u entries, desc %llx avail %llx used %llx, driver features %016llx\n", d->q.num,
				(unsigned long long)d->q.desc, (unsigned long long)d->q.avail, (unsigned long long)d->q.used,
				(unsigned long long)vio_rd((void *)d->bar, SLOP_VMMIO_R_DRVFEAT));
	}
	d->polls++;
	if (d->debug && (d->polls % 500000) == 0) {
		/* a periodic look at the ring while nothing seems to happen */
		uint8_t idx[4];
		gmem_read((void *)d->bar, d->q.avail, idx, 4);
		fprintf(stderr, "sh5blk: poll %lu: avail flags %04x idx %04x, kick latch %llx, istatus %llx, driver status %x\n",
			d->polls, idx[0] | idx[1] << 8, idx[2] | idx[3] << 8,
			(unsigned long long)d->bar->read64(d->bar->ctx, SH5_BAR_VIO + 0xf8),
			(unsigned long long)d->bar->read64(d->bar->ctx, SH5_BAR_VIO + 0x60),
			slop_vmmio_status(&d->t));
	}
	(void)slop_vmmio_kicks(&d->t);                 /* clear the latch; the ring is the truth */
	while (slop_virtq_pending(&d->q)) {
		slop_virtq_chain c;
		int r = slop_virtq_pop(&d->q, &c);
		if (r < 0) { if (d->debug) fprintf(stderr, "sh5blk: malformed chain\n"); return -1; }
		if (r == 0) break;
		if (d->debug)
			fprintf(stderr, "sh5blk: request type %u sector %llu in %zu out %zu\n", c.in_len >= 16 ? get_le32(c.in) : 99,
				c.in_len >= 16 ? (unsigned long long)get_le64(c.in + 8) : 0ull, c.in_len, c.out_len);
		if (serve(d, &c) < 0) { slop_virtq_chain_free(&c); return -1; }
		slop_virtq_chain_free(&c);
		done++;
	}
	if (done) {
		slop_vmmio_interrupt(&d->t, SLOP_VMMIO_INT_USED);
		if (d->debug) {
			uint8_t u[8];
			gmem_read((void *)d->bar, d->q.used, u, 8);
			fprintf(stderr, "sh5blk: %d served at poll %lu: used flags %04x idx %04x, elem0 id %u, istatus now %llx\n", done,
				d->polls, u[0] | u[1] << 8, u[2] | u[3] << 8, get_le32(u + 4),
				(unsigned long long)d->bar->read64(d->bar->ctx, SH5_BAR_VIO + 0x60));
			d->said_istatus = 1;
		}
	}
	if (d->debug && d->said_istatus) {
		/* report the driver's acknowledgement */
		uint64_t is = d->bar->read64(d->bar->ctx, SH5_BAR_VIO + 0x60);
		if (!(is & 1)) { fprintf(stderr, "sh5blk: interrupt acknowledged by poll %lu\n", d->polls); d->said_istatus = 0; }
	}
	return done;
}

void sh5blk_stats(const struct sh5blk *d, unsigned long *reads, unsigned long *writes,
		  unsigned long *bytes)
{
	*reads = d->n_read; *writes = d->n_write; *bytes = d->n_bytes;
}

void sh5blk_close(struct sh5blk *d)
{
	if (!d) return;
	if (d->fd >= 0) close(d->fd);
	free(d->buf);
	free(d);
}
