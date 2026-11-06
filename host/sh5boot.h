/*
 * sh5boot.h - what a host does to boot a kernel on the SH-5 card: the BAR
 * map, the hub registers, and the deposit protocol (docs/soc.md). Used by
 * the board testbench (rtl/tb/board) and by a host tool alike, through
 * the two BAR accessors in struct sh5_bar; there is one implementation of
 * the sequence, not a tested one and a shipped one.
 *
 * Addresses are BAR offsets. DRAM is the half of the BAR with bit 28
 * clear: offset o is DDR3 byte o and SH-5 physical 0x8000_0000 + o. The
 * register window (bit 28 set) holds fpgaslop's card page at +0 and the
 * hub at +0x1_0000.
 */
#ifndef SH5BOOT_H
#define SH5BOOT_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SH5_RAM_PHYS      0x80000000u
#define SH5_RAM_BYTES     (256u << 20)
#define SH5_BAR_REGS      0x10000000ull       /* fpgaslop's register window (SLOP_REG_BASE) */
#define SH5_BAR_HUB       (SH5_BAR_REGS + 0x10000)

/* hub registers (rtl/soc/sh5_hub.sv) */
#define SH5_HUB_ID        0x000
#define SH5_HUB_VERSION   0x008
#define SH5_HUB_RAM_SIZE  0x010
#define SH5_HUB_STATUS    0x018
#define SH5_HUB_RESET_HOLD 0x020
#define SH5_HUB_BOOT_PC   0x028
#define SH5_HUB_CYCLES    0x030
#define SH5_HUB_IRQ       0x038
#define SH5_HUB_CON_STATUS 0x100
#define SH5_HUB_CON_POP   0x108
#define SH5_HUB_CON_PUSH  0x110
#define SH5_HUB_ID_VALUE  0x7375706572683520ull   /* "superh5 " */

struct sh5_bar {
	void *ctx;
	/* 64-bit transactions on the BAR; wstrb selects the bytes of a write */
	uint64_t (*read64)(void *ctx, uint64_t off);
	void     (*write64)(void *ctx, uint64_t off, uint64_t val, uint8_t wstrb);
};

/* the card page (fpgaslop/host/slop_id.h) and the hub's identity registers */
struct sh5_info {
	uint64_t magic, design, abi, caps, build_id, build_cfg, dram_stat, wr_count;
	uint64_t hub_id, hub_version, ram_size, status;
};
#define SH5_SLOP_MAGIC    0x46504741534C4F50ull   /* "FPGASLOP" */
#define SH5_CFG_CORE_DIV(cfg)  (((cfg) >> 8) & 0xff)   /* 1000 MHz / div = core clock */
#define SH5_CFG_DDR_TCK(cfg)   (((cfg) >> 16) & 0xffff) /* DDR3 clock period, ps */

void sh5_identify(const struct sh5_bar *b, struct sh5_info *i);

/* identity: 0 if the card page and the hub answer as expected */
int sh5_probe(const struct sh5_bar *b, char *msg, size_t msglen);

/* fpgaslop soft reset of the design (core and peripherals; not the host path) */
void sh5_soft_reset(const struct sh5_bar *b);

/* hold the core in reset / set its start address / release it */
void sh5_hold(const struct sh5_bar *b);
void sh5_release(const struct sh5_bar *b, uint32_t boot_pc);

/* raw memory writes into the DRAM window, SH-5 physical addresses */
void sh5_write_mem(const struct sh5_bar *b, uint32_t paddr, const void *data, size_t len);
void sh5_fill_mem(const struct sh5_bar *b, uint32_t paddr, uint8_t byte, size_t len);
uint64_t sh5_read_mem64(const struct sh5_bar *b, uint32_t paddr);

/*
 * Deposit a kernel image and whatever it needs:
 *   - a physical-address ELF (bare tests, Linux vmlinux): the segments;
 *     with cmdline/initrd the Linux zero page is filled in (docs/cayman-platform.md)
 *   - a KSEG0 (0xc000_0000) ELF: NetBSD/evbsh5; the boot parameters, the
 *     symbol table image and the register-setting stub are written
 * Returns the address to start the core at, or 0 on failure.
 */
uint32_t sh5_deposit(const struct sh5_bar *b, const char *elf_path,
		     const char *cmdline, const char *initrd_path,
		     char *msg, size_t msglen);

/* console: pop one transmit byte (-1 if none), push one receive byte (0 if full) */
int sh5_con_pop(const struct sh5_bar *b);
int sh5_con_push(const struct sh5_bar *b, uint8_t c);
unsigned sh5_con_waiting(const struct sh5_bar *b);

#ifdef __cplusplus
}
#endif
#endif
