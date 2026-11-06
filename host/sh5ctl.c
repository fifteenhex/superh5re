/*
 * sh5ctl.c - drive the SH-5 card over its BAR from userspace.
 *
 *   sh5ctl <bdf> probe                       identity: card page, build, clocks, DRAM, hub
 *   sh5ctl <bdf> status                      hub status and the measured core clock
 *   sh5ctl <bdf> peek <paddr> [n]            read n 64-bit words of DRAM
 *   sh5ctl <bdf> poke <paddr> <value>        write one 64-bit word
 *   sh5ctl <bdf> memtest [bytes] [paddr]     write/read/compare DRAM through the BAR (holds the core)
 *   sh5ctl <bdf> hold | release [pc] | reset
 *   sh5ctl <bdf> run <elf> [--cmdline S] [--initrd F] [--done STR] [--timeout SEC]
 *                                            deposit, start, print the console, stop at STR
 *   sh5ctl <bdf> boot <elf> [--cmdline S] [--initrd F]
 *                                            deposit, start, serve an interactive console
 *   sh5ctl <bdf> console                     attach to a running system
 *
 * BAR0 is mapped through sysfs as fpgaslop's slopctl does (its comments
 * on EINVAL and bound drivers apply). The deposit sequence is sh5boot.c,
 * the same code the board testbench runs, so a bug in it cannot be in one
 * and not the other. Bring-up order: probe, status, memtest, run with
 * tests/exc/exc.elf, then boot (docs/soc.md, "Bring-up").
 *
 * UNTESTED ON HARDWARE until the first card is programmed.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <termios.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/select.h>

#include "sh5boot.h"

static volatile uint64_t *bar;
static size_t bar_len;

static int map_bar(const char *bdf)
{
	char path[256];
	struct stat st;
	int fd;

	snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/enable", bdf);
	fd = open(path, O_WRONLY);
	if (fd >= 0) { if (write(fd, "1", 1) < 0) { /* already enabled */ } close(fd); }

	snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/resource0", bdf);
	fd = open(path, O_RDWR | O_SYNC);
	if (fd < 0) { perror(path); return -1; }
	if (fstat(fd, &st)) { perror("fstat"); close(fd); return -1; }
	bar_len = st.st_size;
	bar = mmap(NULL, bar_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	close(fd);
	if (bar == MAP_FAILED) {
		perror("mmap");
		fprintf(stderr, "  EINVAL usually means a driver has claimed BAR0; unbind it first\n");
		return -1;
	}
	if (bar_len < (1u << 29))
		fprintf(stderr, "sh5ctl: BAR0 is %zu bytes; the design expects 512 MB\n", bar_len);
	return 0;
}

static uint64_t rd64(void *ctx, uint64_t off)
{
	(void)ctx;
	return bar[off / 8];
}

/* The BAR is byte-addressable through the uncached mapping; a partial
 * strobe becomes byte stores so that neighbouring bytes are untouched. */
static void wr64(void *ctx, uint64_t off, uint64_t v, uint8_t strb)
{
	(void)ctx;
	if (strb == 0xff) {
		bar[off / 8] = v;
	} else {
		volatile uint8_t *b = (volatile uint8_t *)bar + off;
		for (int i = 0; i < 8; i++)
			if (strb & (1 << i))
				b[i] = (uint8_t)(v >> (8 * i));
	}
}

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint64_t hub_rd(const struct sh5_bar *b, unsigned reg)
{
	return b->read64(b->ctx, SH5_BAR_HUB + reg);
}

static void print_ascii8(uint64_t v)
{
	for (int i = 0; i < 8; i++) {
		int c = (v >> (56 - 8 * i)) & 0xff;
		putchar(c >= 0x20 && c < 0x7f ? c : '.');
	}
}

static void print_status(uint64_t st)
{
	printf("hub status      %llx:%s%s%s\n", (unsigned long long)st,
	       (st & 1) ? " core-held-in-reset" : " core-running",
	       (st & 2) ? " asleep" : "",
	       (st & 4) ? " BUS-ERROR-SEEN" : "");
}

/* ---- probe: everything the card says about itself ---- */
static int cmd_probe(const struct sh5_bar *b)
{
	struct sh5_info i;
	static const char *capname[] = { "DRAM", "MAILBOX", "MSI", "LOADER", "CPU", "RESET", "DMA" };

	sh5_identify(b, &i);
	printf("card page       magic %016llx ", (unsigned long long)i.magic);
	print_ascii8(i.magic);
	printf("%s\n", i.magic == SH5_SLOP_MAGIC ? "" : "  <-- not fpgaslop: wrong BAR, wrong card, or the design is not alive");
	printf("design          %016llx ", (unsigned long long)i.design);
	print_ascii8(i.design);
	printf("%s\n", i.design == SH5_HUB_ID_VALUE ? "" : "  <-- not superh5");
	printf("abi             %llx\n", (unsigned long long)i.abi);
	printf("caps            %llx:", (unsigned long long)i.caps);
	for (unsigned k = 0; k < 7; k++)
		if (i.caps & (1ull << k)) printf(" %s", capname[k]);
	printf("\n");
	printf("build id        %016llx (git commit %08llx)\n", (unsigned long long)i.build_id,
	       (unsigned long long)(i.build_id >> 32));
	printf("build cfg       %016llx: core 1000/%llu = %.2f MHz, DDR3 clock %llu ps\n",
	       (unsigned long long)i.build_cfg,
	       (unsigned long long)SH5_CFG_CORE_DIV(i.build_cfg),
	       SH5_CFG_CORE_DIV(i.build_cfg) ? 1000.0 / SH5_CFG_CORE_DIV(i.build_cfg) : 0.0,
	       (unsigned long long)SH5_CFG_DDR_TCK(i.build_cfg));
	printf("dram            %llx:%s%s%s\n", (unsigned long long)i.dram_stat,
	       (i.dram_stat & 1) ? " calibrated" : " NOT-CALIBRATED",
	       (i.dram_stat & 2) ? " ERROR" : "", (i.dram_stat & 4) ? " WEDGED" : "");
	printf("writes          in %llu, out %llu (host path through mem_cdc)\n",
	       (unsigned long long)(i.wr_count & 0xffffffff), (unsigned long long)(i.wr_count >> 32));
	printf("hub id          %016llx ", (unsigned long long)i.hub_id);
	print_ascii8(i.hub_id);
	printf("%s\n", i.hub_id == SH5_HUB_ID_VALUE ? "" : "  <-- no hub at +0x10000");
	printf("hub version     %llu.%llu, RAM %llu MB\n",
	       (unsigned long long)((i.hub_version >> 16) & 0xffff), (unsigned long long)(i.hub_version & 0xffff),
	       (unsigned long long)(i.ram_size >> 20));
	print_status(i.status);
	return (i.magic == SH5_SLOP_MAGIC && i.design == SH5_HUB_ID_VALUE && i.hub_id == SH5_HUB_ID_VALUE) ? 0 : 1;
}

/* ---- status: the hub, and the core clock measured against the host's ---- */
static int cmd_status(const struct sh5_bar *b)
{
	uint64_t c0, c1;
	double t0, t1;

	print_status(hub_rd(b, SH5_HUB_STATUS));
	printf("boot pc         %08llx\n", (unsigned long long)hub_rd(b, SH5_HUB_BOOT_PC));
	printf("console         %u bytes waiting from the core\n", sh5_con_waiting(b));
	t0 = now_s(); c0 = hub_rd(b, SH5_HUB_CYCLES);
	usleep(500000);
	c1 = hub_rd(b, SH5_HUB_CYCLES); t1 = now_s();
	printf("cycles          %llu, +%llu in %.3f s = %.3f MHz core clock\n",
	       (unsigned long long)c1, (unsigned long long)(c1 - c0), t1 - t0,
	       (double)(c1 - c0) / (t1 - t0) / 1e6);
	if (c1 == c0)
		printf("                the counter is not running: no core clock (MMCM) or the hub is not there\n");
	return 0;
}

/* ---- memory through the BAR ---- */
static int cmd_peek(const struct sh5_bar *b, uint32_t paddr, unsigned n)
{
	for (unsigned k = 0; k < n; k++, paddr += 8) {
		if ((k % 2) == 0) printf("%08x:", paddr);
		printf(" %016llx", (unsigned long long)sh5_read_mem64(b, paddr));
		if ((k % 2) == 1 || k + 1 == n) printf("\n");
	}
	return 0;
}

static uint64_t pattern(uint32_t paddr, unsigned pass)
{
	uint64_t v = (uint64_t)paddr * 0x9E3779B97F4A7C15ull + 0x5851F42D4C957F2Dull;
	v ^= v >> 29;
	return pass ? ~v : v;
}

static int cmd_memtest(const struct sh5_bar *b, size_t bytes, uint32_t paddr)
{
	size_t words = bytes / 8, bad = 0;
	double t0, t1;

	if (paddr < SH5_RAM_PHYS || (uint64_t)paddr + bytes > (uint64_t)SH5_RAM_PHYS + SH5_RAM_BYTES || (paddr & 7)) {
		fprintf(stderr, "memtest: range must be 8-byte aligned inside %08x..%08x\n",
			SH5_RAM_PHYS, SH5_RAM_PHYS + SH5_RAM_BYTES);
		return 2;
	}
	sh5_hold(b);
	for (unsigned pass = 0; pass < 2; pass++) {
		t0 = now_s();
		for (size_t k = 0; k < words; k++)
			b->write64(b->ctx, (paddr - SH5_RAM_PHYS) + 8 * k, pattern(paddr + 8 * k, pass), 0xff);
		t1 = now_s();
		printf("pass %u: wrote %zu bytes in %.3f s (%.1f MB/s)", pass, bytes, t1 - t0, bytes / (t1 - t0) / 1e6);
		t0 = now_s();
		for (size_t k = 0; k < words; k++) {
			uint64_t want = pattern(paddr + 8 * k, pass);
			uint64_t got = sh5_read_mem64(b, paddr + 8 * k);
			if (got != want) {
				if (bad < 8)
					printf("\n  %08x: got %016llx want %016llx", (unsigned)(paddr + 8 * k),
					       (unsigned long long)got, (unsigned long long)want);
				bad++;
			}
		}
		t1 = now_s();
		printf(", read back in %.3f s (%.1f MB/s), %zu mismatches\n", t1 - t0, bytes / (t1 - t0) / 1e6, bad);
	}
	/* byte strobes: a partial write must leave its neighbours alone */
	{
		uint8_t one = 0xa5;
		uint64_t before = pattern(paddr, 1), after;
		sh5_write_mem(b, paddr + 3, &one, 1);
		after = sh5_read_mem64(b, paddr);
		if (after != ((before & ~(0xffull << 24)) | ((uint64_t)one << 24))) {
			printf("byte strobe: got %016llx, want %016llx\n", (unsigned long long)after,
			       (unsigned long long)((before & ~(0xffull << 24)) | ((uint64_t)one << 24)));
			bad++;
		} else {
			printf("byte strobe ok\n");
		}
	}
	printf("memtest %s (the core is held in reset; release or boot to continue)\n", bad ? "FAILED" : "passed");
	return bad ? 1 : 0;
}

/* ---- console ---- */
static struct termios saved_tty;
static int tty_raw = 0;

static void tty_restore(void)
{
	if (tty_raw)
		tcsetattr(0, TCSANOW, &saved_tty);
}

static void serve_console(const struct sh5_bar *b)
{
	struct termios t;

	if (isatty(0) && !tcgetattr(0, &saved_tty)) {
		t = saved_tty;
		cfmakeraw(&t);
		tcsetattr(0, TCSANOW, &t);
		tty_raw = 1;
		atexit(tty_restore);
		fprintf(stderr, "sh5ctl: console attached, Ctrl-] detaches\r\n");
	}
	for (;;) {
		fd_set rf;
		struct timeval tv = { 0, 1000 };
		unsigned n = sh5_con_waiting(b);

		for (unsigned k = 0; k < n; k++) {
			int c = sh5_con_pop(b);
			if (c < 0) break;
			putchar(c);
		}
		fflush(stdout);
		FD_ZERO(&rf);
		FD_SET(0, &rf);
		if (select(1, &rf, NULL, NULL, &tv) > 0) {
			unsigned char c;
			if (read(0, &c, 1) != 1) return;
			if (c == 0x1d) return;          /* Ctrl-] */
			while (!sh5_con_push(b, c))
				usleep(100);
		}
	}
}

/* print the console until `done` appears or `timeout` seconds pass; no input */
static int run_console(const struct sh5_bar *b, const char *done, double timeout)
{
	char ring[256] = { 0 };
	size_t rl = done ? strlen(done) : 0, fill = 0;
	double t0 = now_s(), last = t0;
	uint64_t c0 = hub_rd(b, SH5_HUB_CYCLES);

	for (;;) {
		unsigned n = sh5_con_waiting(b);
		for (unsigned k = 0; k < n; k++) {
			int c = sh5_con_pop(b);
			if (c < 0) break;
			putchar(c);
			if (rl) {
				memmove(ring, ring + 1, sizeof ring - 1);
				ring[sizeof ring - 1] = (char)c;
				if (fill < sizeof ring) fill++;
				if (fill >= rl && !memcmp(ring + sizeof ring - rl, done, rl)) {
					fflush(stdout);
					fprintf(stderr, "\nsh5ctl: \"%s\" seen after %.1f s, %llu core cycles\n", done,
						now_s() - t0, (unsigned long long)(hub_rd(b, SH5_HUB_CYCLES) - c0));
					return 0;
				}
			}
			last = now_s();
		}
		fflush(stdout);
		if (n == 0) {
			if (hub_rd(b, SH5_HUB_STATUS) & 4) {
				fprintf(stderr, "\nsh5ctl: the core saw a bus error (hub STATUS bit 2)\n");
				return 1;
			}
			if (now_s() - t0 > timeout) {
				fprintf(stderr, "\nsh5ctl: timeout after %.0f s (%.1f s since the last console byte, %llu core cycles)\n",
					timeout, now_s() - last, (unsigned long long)(hub_rd(b, SH5_HUB_CYCLES) - c0));
				return 2;
			}
			usleep(1000);
		}
	}
}

int main(int argc, char **argv)
{
	struct sh5_bar b = { NULL, rd64, wr64 };
	char msg[160];

	if (argc < 3) {
		fprintf(stderr, "usage: sh5ctl <bdf> probe|status|peek A [N]|poke A V|memtest [BYTES] [A]|hold|release [pc]|reset|\n"
				"              run ELF [--cmdline S] [--initrd F] [--done STR] [--timeout SEC]|\n"
				"              boot ELF [--cmdline S] [--initrd F]|console\n");
		return 2;
	}
	if (map_bar(argv[1]))
		return 1;
	if (!strcmp(argv[2], "probe"))
		return cmd_probe(&b);
	if (sh5_probe(&b, msg, sizeof msg)) {
		fprintf(stderr, "sh5ctl: %s (run `probe` for the raw registers)\n", msg);
		return 1;
	}
	if (!strcmp(argv[2], "status")) return cmd_status(&b);
	if (!strcmp(argv[2], "hold")) { sh5_hold(&b); return 0; }
	if (!strcmp(argv[2], "reset")) { sh5_soft_reset(&b); return 0; }
	if (!strcmp(argv[2], "release")) {
		sh5_release(&b, argc > 3 ? (uint32_t)strtoul(argv[3], NULL, 0) : SH5_RAM_PHYS);
		return 0;
	}
	if (!strcmp(argv[2], "peek") && argc > 3)
		return cmd_peek(&b, (uint32_t)strtoul(argv[3], NULL, 0), argc > 4 ? (unsigned)strtoul(argv[4], NULL, 0) : 1);
	if (!strcmp(argv[2], "poke") && argc > 4) {
		uint64_t v = strtoull(argv[4], NULL, 0);
		uint32_t a = (uint32_t)strtoul(argv[3], NULL, 0);
		uint8_t d[8];
		for (int i = 0; i < 8; i++) d[i] = (uint8_t)(v >> (8 * i));
		sh5_write_mem(&b, a, d, 8);
		return 0;
	}
	if (!strcmp(argv[2], "memtest"))
		return cmd_memtest(&b, argc > 3 ? (size_t)strtoull(argv[3], NULL, 0) : (1u << 20),
				   argc > 4 ? (uint32_t)strtoul(argv[4], NULL, 0) : SH5_RAM_PHYS);
	if (!strcmp(argv[2], "console")) { serve_console(&b); return 0; }
	if ((!strcmp(argv[2], "boot") || !strcmp(argv[2], "run")) && argc > 3) {
		const char *cmdline = NULL, *initrd = NULL, *done = NULL;
		double timeout = 600;
		uint32_t pc;
		double t0;

		for (int i = 4; i < argc; i++) {
			if (!strcmp(argv[i], "--cmdline") && i + 1 < argc) cmdline = argv[++i];
			else if (!strcmp(argv[i], "--initrd") && i + 1 < argc) initrd = argv[++i];
			else if (!strcmp(argv[i], "--done") && i + 1 < argc) done = argv[++i];
			else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) timeout = atof(argv[++i]);
		}
		sh5_hold(&b);
		t0 = now_s();
		pc = sh5_deposit(&b, argv[3], cmdline, initrd, msg, sizeof msg);
		if (!pc) { fprintf(stderr, "sh5ctl: %s\n", msg); return 1; }
		fprintf(stderr, "sh5ctl: %s in %.1f s, starting at %08x\n", msg, now_s() - t0, pc);
		sh5_release(&b, pc);
		if (!strcmp(argv[2], "run"))
			return run_console(&b, done, timeout);
		serve_console(&b);
		return 0;
	}
	fprintf(stderr, "sh5ctl: unknown command %s\n", argv[2]);
	return 2;
}
