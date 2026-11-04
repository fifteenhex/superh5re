/* MODE=sh4: SHcompact (SH-4) program for qemu-system-sh4 -M r2d, loaded at
 * physical 0x0c800000 and started at 0xac800000 (P2); output on the SH7751
 * SCIF (serial 1), polled. */
#include "harness.h"

#define SCIF_BASE	0xffe80000UL
#define SCIF_SCR	(*(volatile u16 *)(SCIF_BASE + 0x08))
#define SCIF_FTDR	(*(volatile u8 *)(SCIF_BASE + 0x0c))
#define SCIF_FSR	(*(volatile u16 *)(SCIF_BASE + 0x10))
#define SCIF_FSR_TDFE	0x20

int isa_main(const char *const *only);

static void putc(char c)
{
	while (!(SCIF_FSR & SCIF_FSR_TDFE))
		;
	SCIF_FTDR = c;
	SCIF_FSR = (u16)(SCIF_FSR & ~SCIF_FSR_TDFE);
}

void isa_puts(const char *s)
{
	while (*s) {
		if (*s == '\n')
			putc('\r');
		putc(*s++);
	}
}

void isa_exit(int failures)
{
	isa_puts("isa: DONE\n");
	for (;;)
		;
}

int main(void)
{
	SCIF_SCR = 0x30;	/* TE | RE */
	return isa_main(0);
}
