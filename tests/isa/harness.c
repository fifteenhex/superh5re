/* Common code of the ISA test kit; the output primitives are in the
 * MODE-specific file (nolibc.c or bare.c). */
#include "harness.h"

unsigned isa_tests, isa_failures, isa_group_failures;
int isa_verbose;
static const char *isa_group_name;

const u64 isa_operands[] = {
	0x0000000000000000ULL, 0x0000000000000001ULL, 0x0000000000000002ULL,
	0x0000000000000003ULL, 0x000000000000007fULL, 0x0000000000000080ULL,
	0x00000000000000ffULL, 0x0000000000000100ULL, 0x0000000000007fffULL,
	0x0000000000008000ULL, 0x000000000000ffffULL, 0x0000000000010000ULL,
	0x000000007fffffffULL, 0x0000000080000000ULL, 0x00000000ffffffffULL,
	0x0000000100000000ULL, 0x00000001ffffffffULL, 0x7fffffffffffffffULL,
	0x8000000000000000ULL, 0xffffffffffffffffULL, 0xfffffffffffffffeULL,
	0xffffffff80000000ULL, 0xffffffff7fffffffULL, 0xffffffff00000000ULL,
	0x0123456789abcdefULL, 0xfedcba9876543210ULL, 0x5555555555555555ULL,
	0xaaaaaaaaaaaaaaaaULL, 0x00000000deadbeefULL, 0xdeadbeef00000000ULL,
	0x000000000000003fULL, 0x0000000000000040ULL,
};
const unsigned isa_num_operands = sizeof(isa_operands) / sizeof(isa_operands[0]);

static u64 rand_state = 0x9e3779b97f4a7c15ULL;

void isa_rand_seed(u64 seed)
{
	rand_state = seed ? seed : 0x9e3779b97f4a7c15ULL;
}

u64 isa_rand(void)
{
	u64 x = rand_state;

	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	rand_state = x;
	return x;
}

void isa_group_begin(const char *name)
{
	isa_group_name = name;
	isa_group_failures = 0;
	isa_puts("isa: group ");
	isa_puts(name);
	isa_puts("\n");
}

void isa_group_end(void)
{
	isa_puts("isa: group ");
	isa_puts(isa_group_name);
	isa_puts(isa_group_failures ? " FAILED " : " ok ");
	isa_putdec(isa_group_failures);
	isa_puts(" failures\n");
}

int isa_check(const char *file, int line, const char *insn, u64 got, u64 want,
	      int nops, u64 a, u64 b, u64 c)
{
	int pass = got == want;

	isa_tests++;
	if (pass && !isa_verbose)
		return 1;
	if (!pass) {
		isa_failures++;
		isa_group_failures++;
	}
	isa_puts(pass ? "isa: PASS " : "isa: FAIL ");
	isa_puts(insn);
	if (nops >= 1) { isa_puts(" a="); isa_puthex(a); }
	if (nops >= 2) { isa_puts(" b="); isa_puthex(b); }
	if (nops >= 3) { isa_puts(" c="); isa_puthex(c); }
	isa_puts(" got="); isa_puthex(got);
	isa_puts(" want="); isa_puthex(want);
	isa_puts(" ("); isa_puts(file); isa_puts(":"); isa_putdec(line);
	isa_puts(")\n");
	return pass;
}

void isa_puthex(u64 v)
{
	static const char d[] = "0123456789abcdef";
	char buf[19];
	int i;

	buf[0] = '0'; buf[1] = 'x';
	for (i = 0; i < 16; i++)
		buf[2 + i] = d[(v >> (60 - 4 * i)) & 15];
	buf[18] = 0;
	isa_puts(buf);
}

void isa_putdec(u64 v)
{
	char buf[21];
	int i = 20;

	buf[i] = 0;
	do {
		buf[--i] = '0' + v % 10;
		v /= 10;
	} while (v);
	isa_puts(buf + i);
}

extern const struct isa_group __start_isa_groups[];
extern const struct isa_group __stop_isa_groups[];

/* Run every registered group, or only those named in @only (NULL-terminated). */
int isa_main(const char *const *only)
{
	const struct isa_group *g;

	isa_puts("isa: SH-5 SHmedia ISA test kit\n");
	for (g = __start_isa_groups; g < __stop_isa_groups; g++) {
		if (only && *only) {
			const char *const *p;
			int match = 0;

			for (p = only; *p; p++) {
				const char *x = *p, *y = g->name;

				while (*x && *x == *y) { x++; y++; }
				if (!*x && !*y)
					match = 1;
			}
			if (!match)
				continue;
		}
		isa_group_begin(g->name);
		g->run();
		isa_group_end();
	}
	isa_puts("isa: SUMMARY ");
	isa_putdec(isa_tests);
	isa_puts(" tests, ");
	isa_putdec(isa_failures);
	isa_puts(" failures\n");
	isa_exit(isa_failures);
	return isa_failures != 0;
}
