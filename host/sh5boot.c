/* sh5boot.c - the deposit protocol, see sh5boot.h. Plain C, no dependencies
 * beyond the standard library, so the same file links into the Verilator
 * testbench and into a host tool. */
#include "sh5boot.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KSEG0 0xc0000000u

static uint64_t hub_rd(const struct sh5_bar *b, unsigned reg)
{
	return b->read64(b->ctx, SH5_BAR_HUB + reg);
}

static void hub_wr(const struct sh5_bar *b, unsigned reg, uint64_t v)
{
	b->write64(b->ctx, SH5_BAR_HUB + reg, v, 0xff);
}

static int say(char *msg, size_t len, const char *s)
{
	if (msg && len)
		snprintf(msg, len, "%s", s);
	return -1;
}

void sh5_identify(const struct sh5_bar *b, struct sh5_info *i)
{
	i->magic     = b->read64(b->ctx, SH5_BAR_REGS + 0x00);   /* slop_id, fpgaslop/host/slop_id.h */
	i->design    = b->read64(b->ctx, SH5_BAR_REGS + 0x08);
	i->abi       = b->read64(b->ctx, SH5_BAR_REGS + 0x10);
	i->caps      = b->read64(b->ctx, SH5_BAR_REGS + 0x18);
	i->build_id  = b->read64(b->ctx, SH5_BAR_REGS + 0x20);
	i->build_cfg = b->read64(b->ctx, SH5_BAR_REGS + 0x28);
	i->dram_stat = b->read64(b->ctx, SH5_BAR_REGS + 0x30);
	i->wr_count  = b->read64(b->ctx, SH5_BAR_REGS + 0x38);
	i->hub_id      = hub_rd(b, SH5_HUB_ID);
	i->hub_version = hub_rd(b, SH5_HUB_VERSION);
	i->ram_size    = hub_rd(b, SH5_HUB_RAM_SIZE);
	i->status      = hub_rd(b, SH5_HUB_STATUS);
}

int sh5_probe(const struct sh5_bar *b, char *msg, size_t msglen)
{
	struct sh5_info i;

	sh5_identify(b, &i);
	if (i.magic != SH5_SLOP_MAGIC)
		return say(msg, msglen, "no fpgaslop identity block at the register window");
	if (i.design != SH5_HUB_ID_VALUE)
		return say(msg, msglen, "the card page is another design");
	if (i.hub_id != SH5_HUB_ID_VALUE)
		return say(msg, msglen, "no SH-5 hub at the hub window");
	if (msg && msglen)
		snprintf(msg, msglen, "superh5 hub version %llx, %llu MB RAM, status %llx",
			 (unsigned long long)i.hub_version,
			 (unsigned long long)(i.ram_size >> 20),
			 (unsigned long long)i.status);
	return 0;
}

void sh5_soft_reset(const struct sh5_bar *b)
{
	b->write64(b->ctx, SH5_BAR_REGS + 0xC0, 0x5245534554504C53ull, 0xff);   /* SLOP_R_RESET, "RESETPLS" */
}

void sh5_hold(const struct sh5_bar *b)
{
	hub_wr(b, SH5_HUB_RESET_HOLD, 1);
}

void sh5_release(const struct sh5_bar *b, uint32_t boot_pc)
{
	hub_wr(b, SH5_HUB_BOOT_PC, boot_pc);
	hub_wr(b, SH5_HUB_STATUS, 4);		/* clear a bus error seen by an earlier run */
	hub_wr(b, SH5_HUB_RESET_HOLD, 0);
}

static int in_ram(uint32_t paddr, size_t len)
{
	return paddr >= SH5_RAM_PHYS && (uint64_t)paddr + len <= (uint64_t)SH5_RAM_PHYS + SH5_RAM_BYTES;
}

void sh5_write_mem(const struct sh5_bar *b, uint32_t paddr, const void *data, size_t len)
{
	const uint8_t *p = (const uint8_t *)data;   /* also compiled as C++ by the testbench */
	uint64_t off = paddr - SH5_RAM_PHYS;

	if (!in_ram(paddr, len))
		return;
	while (len) {
		unsigned lane = off & 7, n = 8 - lane;
		uint64_t v = 0;
		uint8_t strb = 0;

		if (n > len)
			n = len;
		for (unsigned i = 0; i < n; i++) {
			v |= (uint64_t)p[i] << (8 * (lane + i));
			strb |= 1u << (lane + i);
		}
		b->write64(b->ctx, off & ~7ull, v, strb);
		off += n; p += n; len -= n;
	}
}

void sh5_fill_mem(const struct sh5_bar *b, uint32_t paddr, uint8_t byte, size_t len)
{
	uint8_t buf[256];

	memset(buf, byte, sizeof(buf));
	while (len) {
		size_t n = len > sizeof(buf) ? sizeof(buf) : len;
		sh5_write_mem(b, paddr, buf, n);
		paddr += n; len -= n;
	}
}

uint64_t sh5_read_mem64(const struct sh5_bar *b, uint32_t paddr)
{
	return b->read64(b->ctx, (paddr - SH5_RAM_PHYS) & ~7u);
}

static void w32(const struct sh5_bar *b, uint32_t paddr, uint32_t v)
{
	uint8_t d[4] = { v, v >> 8, v >> 16, v >> 24 };
	sh5_write_mem(b, paddr, d, 4);
}

static void w64(const struct sh5_bar *b, uint32_t paddr, uint64_t v)
{
	w32(b, paddr, (uint32_t)v);
	w32(b, paddr + 4, (uint32_t)(v >> 32));
}

static void wstr(const struct sh5_bar *b, uint32_t paddr, const char *s)
{
	sh5_write_mem(b, paddr, s, strlen(s) + 1);
}

static uint8_t *slurp(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	uint8_t *buf;
	long n;

	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	n = ftell(f);
	fseek(f, 0, SEEK_SET);
	buf = (uint8_t *)malloc(n > 0 ? n : 1);
	if (!buf || fread(buf, 1, n, f) != (size_t)n) {
		fclose(f);
		free(buf);
		return NULL;
	}
	fclose(f);
	*len = n;
	return buf;
}

static uint32_t r32(const uint8_t *p, size_t o) { return p[o] | p[o+1] << 8 | p[o+2] << 16 | (uint32_t)p[o+3] << 24; }
static uint16_t r16(const uint8_t *p, size_t o) { return p[o] | p[o+1] << 8; }
static uint32_t xlat(uint32_t a) { return a >= KSEG0 ? a - KSEG0 + SH5_RAM_PHYS : a; }

/* NetBSD wants its symbol table in memory as an ELF image whose section
 * headers point at .symtab and .strtab; returns the image size written at pa */
static uint32_t deposit_symbols(const struct sh5_bar *b, const uint8_t *img, size_t len, uint32_t pa)
{
	uint32_t shoff = r32(img, 32);
	uint16_t shentsize = r16(img, 46), shnum = r16(img, 48);
	size_t sym = 0, str = 0;
	uint32_t symsz, strsz, hdr = 52 + 3 * 40;
	uint8_t *out;
	uint32_t total;

	(void)len;
	for (unsigned i = 1; i < shnum; i++) {
		size_t sh = shoff + (size_t)i * shentsize;
		if (r32(img, sh + 4) == 2) { sym = sh; str = shoff + (size_t)r32(img, sh + 24) * shentsize; break; }
	}
	if (!sym)
		return 0;
	symsz = r32(img, sym + 20);
	strsz = r32(img, str + 20);
	total = hdr + symsz + strsz;
	out = (uint8_t *)calloc(total, 1);
	memcpy(out, img, 52);
	memset(out + 28, 0, 4);               /* no program headers */
	out[44] = out[45] = 0;
	out[32] = 52; out[33] = out[34] = out[35] = 0;   /* e_shoff */
	out[48] = 3; out[49] = 0;             /* e_shnum */
	out[50] = out[51] = 0;                /* e_shstrndx */
	memcpy(out + 52 + 40, img + sym, 40);
	memcpy(out + 52 + 80, img + str, 40);
	*(uint32_t *)(out + 52 + 40 + 16) = hdr;        /* .symtab offset (little-endian host assumed) */
	*(uint32_t *)(out + 52 + 40 + 24) = 2;          /* link to .strtab */
	*(uint32_t *)(out + 52 + 80 + 16) = hdr + symsz;
	memcpy(out + hdr, img + r32(img, sym + 16), symsz);
	memcpy(out + hdr + symsz, img + r32(img, str + 16), strsz);
	sh5_write_mem(b, pa, out, total);
	free(out);
	return total;
}

uint32_t sh5_deposit(const struct sh5_bar *b, const char *elf_path,
		     const char *cmdline, const char *initrd_path,
		     char *msg, size_t msglen)
{
	size_t len;
	uint8_t *img = slurp(elf_path, &len);
	uint32_t entry, highaddr = 0, phoff;
	uint16_t phentsize, phnum;

	if (!img) {
		say(msg, msglen, "cannot read the ELF file");
		return 0;
	}
	if (len < 52 || memcmp(img, "\x7f" "ELF", 4) || img[4] != 1 || img[5] != 1) {
		free(img);
		say(msg, msglen, "not a little-endian ELF32 file");
		return 0;
	}
	entry = r32(img, 24);
	phoff = r32(img, 28);
	phentsize = r16(img, 42);
	phnum = r16(img, 44);
	for (unsigned i = 0; i < phnum; i++) {
		size_t p = phoff + (size_t)i * phentsize;
		uint32_t type = r32(img, p), offset = r32(img, p + 4), paddr = xlat(r32(img, p + 12));
		uint32_t filesz = r32(img, p + 16), memsz = r32(img, p + 20);

		if (type != 1)
			continue;
		if (!in_ram(paddr, memsz)) {
			free(img);
			say(msg, msglen, "a segment lies outside the DRAM window");
			return 0;
		}
		sh5_write_mem(b, paddr, img + offset, filesz);
		if (memsz > filesz)
			sh5_fill_mem(b, paddr + filesz, 0, memsz - filesz);
		if (paddr + memsz > highaddr)
			highaddr = paddr + memsz;
	}

	if (entry < KSEG0) {
		/* Linux: command line at empty_zero_page + 0x100 (the page before
		 * _stext), initrd location at +0x10/+0x14 as an offset from the
		 * RAM base; the initrd goes 1 MB aligned after the image */
		uint32_t zp = (entry & ~1u) - 0x1000;

		if (cmdline)
			wstr(b, zp + 0x100, cmdline);
		if (initrd_path) {
			size_t ilen;
			uint8_t *ini = slurp(initrd_path, &ilen);
			uint32_t base = (highaddr + (1u << 20) - 1) & ~((1u << 20) - 1);

			if (!ini) {
				free(img);
				say(msg, msglen, "cannot read the initrd");
				return 0;
			}
			sh5_write_mem(b, base, ini, ilen);
			w32(b, zp + 0x10, base - SH5_RAM_PHYS);
			w32(b, zp + 0x14, (uint32_t)ilen);
			free(ini);
			if (msg && msglen)
				snprintf(msg, msglen, "Linux image, initrd %zu bytes at %08x", ilen, base);
		} else if (msg && msglen) {
			snprintf(msg, msglen, "image loaded, entry %08x", entry & ~1u);
		}
		free(img);
		return entry & ~1u;
	} else {
		/* NetBSD/evbsh5: symbol table image, struct boot_params (600
		 * bytes, sys/arch/evbsh5/include/bootparams.h) at the kernel end,
		 * then a stub that sets r2 = load address, r3 = symbol table,
		 * r4 = kernel end and jumps to the entry */
		uint32_t symtab = (highaddr + 7) & ~7u;
		uint32_t symlen = deposit_symbols(b, img, len, symtab);
		uint32_t bp = (symtab + symlen + 7) & ~7u;
		uint32_t stub = (bp + 600 + 15) & ~15u;
		uint32_t pc = stub;

		sh5_fill_mem(b, bp, 0, 600);
		w32(b, bp + 0, 0xcafebabe);
		w32(b, bp + 4, 1);
		w32(b, bp + 8, 0);
		w64(b, bp + 16, SH5_RAM_PHYS);
		wstr(b, bp + 24, "Cayman (fpgaslop)");
		w32(b, bp + 88, 0x51e2); w32(b, bp + 92, 0); w32(b, bp + 96, 0x0d);
		w64(b, bp + 104, 25000000);           /* cpu speed: informational */
		w32(b, bp + 112, 1); w32(b, bp + 116, 0xff);
		w64(b, bp + 120, SH5_RAM_PHYS); w64(b, bp + 128, SH5_RAM_BYTES);
		wstr(b, bp + 208, "/mainbus0/superhyway0,0x8/femi0,0x4000000/sysfpga0,0x1000/sm0");
		wstr(b, bp + 336, "netbsd"); w32(b, bp + 464, 0);
		wstr(b, bp + 468, "/mainbus0/superhyway0,0x9/pbridge0,0x1030000/scif0");
		w32(b, bp + 596, 38400);

		/* MOVI imm16, Rd = 0xcc000000 | imm << 10 | d << 4; SHORI =
		 * 0xc8000000 | ...; both sign-extend, ADDZ.L Rd, R63, Rd zero-extends */
#define EMIT(x) do { w32(b, pc, (x)); pc += 4; } while (0)
#define MOVI32(rd, v) do { EMIT(0xcc000000u | (((v) >> 16) & 0xffff) << 10 | (rd) << 4); \
			   EMIT(0xc8000000u | ((v) & 0xffff) << 10 | (rd) << 4); } while (0)
		MOVI32(2, SH5_RAM_PHYS); EMIT(0x002cfc20);
		if (symlen) MOVI32(3, symtab - SH5_RAM_PHYS + KSEG0); else EMIT(0xcc000030);
		MOVI32(4, bp - SH5_RAM_PHYS + KSEG0);
		MOVI32(5, xlat(entry) | 1);
		EMIT(0x6bf11600);                      /* ptabs r5, tr0 */
		EMIT(0x4401fff0);                      /* blink tr0, r63 */
#undef MOVI32
#undef EMIT
		if (msg && msglen)
			snprintf(msg, msglen, "NetBSD image, params at %08x, stub at %08x", bp, stub);
		free(img);
		return stub;
	}
}

unsigned sh5_con_waiting(const struct sh5_bar *b)
{
	return (unsigned)(hub_rd(b, SH5_HUB_CON_STATUS) >> 16) & 0xffff;
}

int sh5_con_pop(const struct sh5_bar *b)
{
	uint64_t v = hub_rd(b, SH5_HUB_CON_POP);
	return (v & 0x100) ? (int)(v & 0xff) : -1;
}

int sh5_con_push(const struct sh5_bar *b, uint8_t c)
{
	unsigned free_slots = (unsigned)(hub_rd(b, SH5_HUB_CON_STATUS) >> 8) & 0x1f;
	if (!free_slots)
		return 0;
	hub_wr(b, SH5_HUB_CON_PUSH, c);
	return 1;
}
