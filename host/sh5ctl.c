/*
 * sh5ctl.c - drive the SH-5 card over its BAR from userspace.
 *
 *   sh5ctl <bdf> probe
 *   sh5ctl <bdf> boot <elf> [--cmdline "..."] [--initrd FILE]   deposit, start, serve the console
 *   sh5ctl <bdf> console                                         attach to a running system
 *   sh5ctl <bdf> hold | release [pc]
 *
 * BAR0 is mapped through sysfs as fpgaslop's slopctl does (its comments
 * on EINVAL and bound drivers apply). The sequence itself is sh5boot.c,
 * the same code the board testbench runs, so a bug in it cannot be in one
 * and not the other.
 *
 * UNTESTED ON HARDWARE: no bitstream of this design has been built yet.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <termios.h>
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

int main(int argc, char **argv)
{
	struct sh5_bar b = { NULL, rd64, wr64 };
	char msg[160];

	if (argc < 3) {
		fprintf(stderr, "usage: sh5ctl <bdf> probe|boot <elf> [--cmdline S] [--initrd F]|console|hold|release [pc]\n");
		return 2;
	}
	if (map_bar(argv[1]))
		return 1;
	if (sh5_probe(&b, msg, sizeof msg)) {
		fprintf(stderr, "sh5ctl: %s\n", msg);
		return 1;
	}
	if (!strcmp(argv[2], "probe")) {
		printf("%s\n", msg);
		return 0;
	}
	if (!strcmp(argv[2], "hold")) { sh5_hold(&b); return 0; }
	if (!strcmp(argv[2], "release")) {
		sh5_release(&b, argc > 3 ? (uint32_t)strtoul(argv[3], NULL, 0) : SH5_RAM_PHYS);
		return 0;
	}
	if (!strcmp(argv[2], "console")) { serve_console(&b); return 0; }
	if (!strcmp(argv[2], "boot") && argc > 3) {
		const char *cmdline = NULL, *initrd = NULL;
		uint32_t pc;

		for (int i = 4; i < argc; i++) {
			if (!strcmp(argv[i], "--cmdline") && i + 1 < argc) cmdline = argv[++i];
			else if (!strcmp(argv[i], "--initrd") && i + 1 < argc) initrd = argv[++i];
		}
		sh5_hold(&b);
		pc = sh5_deposit(&b, argv[3], cmdline, initrd, msg, sizeof msg);
		if (!pc) { fprintf(stderr, "sh5ctl: %s\n", msg); return 1; }
		fprintf(stderr, "sh5ctl: %s, starting at %08x\n", msg, pc);
		sh5_release(&b, pc);
		serve_console(&b);
		return 0;
	}
	fprintf(stderr, "sh5ctl: unknown command %s\n", argv[2]);
	return 2;
}
