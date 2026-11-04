/* MODE=sh5: SHmedia harness, MMU off, physical 0x80000000, output on the
 * Cayman SCIF transmit register (polled). */
#include "harness.h"

#define SCIF_BASE	0x0a030000UL
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
	return isa_main(0);
}
