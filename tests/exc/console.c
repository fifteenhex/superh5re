/* Output on the Cayman SCIF transmit register, polled (as tests/isa/bare.c). */
#include "exc.h"

#define SCIF_BASE	0x0a030000UL
#define SCIF_FTDR	(*(volatile u8 *)(SCIF_BASE + 0x0c))
#define SCIF_FSR	(*(volatile u16 *)(SCIF_BASE + 0x10))
#define SCIF_FSR_TDFE	0x20

__attribute__((noinline)) void exc_putc(char c)
{
	while (!(SCIF_FSR & SCIF_FSR_TDFE))
		;
	SCIF_FTDR = c;
	SCIF_FSR = (u16)(SCIF_FSR & ~SCIF_FSR_TDFE);
}

void exc_puts(const char *s)
{
	while (*s) {
		if (*s == '\n')
			exc_putc('\r');
		exc_putc(*s++);
	}
}

void exc_puthex(u64 v)
{
	static const char d[] = "0123456789abcdef";
	char buf[19];
	int i;

	buf[0] = '0'; buf[1] = 'x';
	for (i = 0; i < 16; i++)
		buf[2 + i] = d[(v >> (60 - 4 * i)) & 15];
	buf[18] = 0;
	exc_puts(buf);
}

void exc_putdec(u64 v)
{
	char buf[21];
	int i = 20;

	buf[i] = 0;
	do {
		buf[--i] = '0' + v % 10;
		v /= 10;
	} while (v);
	exc_puts(buf + i);
}
