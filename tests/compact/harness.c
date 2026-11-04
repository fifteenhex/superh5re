/* Common code of the SHcompact test kit; the output primitives are in the
 * MODE-specific file (bare_sh5.c or bare_sh4.c). */
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

const u32 cop_operands[] = {
	0x00000000, 0x00000001, 0x00000002, 0x00000003, 0x00000007, 0x0000007f,
	0x00000080, 0x000000ff, 0x00000100, 0x00007fff, 0x00008000, 0x0000ffff,
	0x00010000, 0x0001ffff, 0x3fffffff, 0x40000000, 0x7ffffffe, 0x7fffffff,
	0x80000000, 0x80000001, 0xbfffffff, 0xc0000000, 0xfffeffff, 0xffff0000,
	0xffff7fff, 0xffff8000, 0xffffff00, 0xffffff7f, 0xffffff80, 0xfffffffe,
	0xffffffff, 0x0000001f, 0x00000020, 0x00000021, 0x12345678, 0x89abcdef,
	0x55555555, 0xaaaaaaaa, 0xdeadbeef, 0x0badcafe,
};
const unsigned cop_num_operands = sizeof(cop_operands) / sizeof(cop_operands[0]);
volatile u64 cop_exc_count, cop_exc_last;

static u32 rand_state = 0x9e3779b9u;

void isa_rand_seed(u32 seed)
{
	rand_state = seed ? seed : 0x9e3779b9u;
}

u32 isa_rand(void)
{
	u32 x = rand_state;

	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	rand_state = x;
	return x;
}

u32 isa_udiv32(u32 a, u32 b)
{
	u32 q = 0, r = 0;
	int i;

	if (!b)
		return 0xffffffffu;
	for (i = 31; i >= 0; i--) {
		r = (r << 1) | ((a >> i) & 1);
		if (r >= b) { r -= b; q |= 1u << i; }
	}
	return q;
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

int isa_check(const struct isa_chk *k)
{
	int pass = k->got == k->want;

	isa_tests++;
	if (pass && !isa_verbose)
		return 1;
	if (!pass) {
		isa_failures++;
		isa_group_failures++;
	}
	isa_puts(pass ? "isa: PASS " : "isa: FAIL ");
	isa_puts(k->insn);
	if (k->nops >= 1) { isa_puts(" a="); isa_puthex(&k->a); }
	if (k->nops >= 2) { isa_puts(" b="); isa_puthex(&k->b); }
	if (k->nops >= 3) { isa_puts(" c="); isa_puthex(&k->c); }
	isa_puts(" got="); isa_puthex(&k->got);
	isa_puts(" want="); isa_puthex(&k->want);
	isa_puts(" ("); isa_puts(k->file); isa_puts(":"); isa_putdec(k->line);
	isa_puts(")\n");
	return pass;
}

void isa_puthex(const u64 *v)
{
	static const char d[] = "0123456789abcdef";
	u32 hi = (u32)(*v >> 32), lo = (u32)*v;
	char buf[19];
	int i;

	buf[0] = '0'; buf[1] = 'x';
	for (i = 0; i < 8; i++) {
		buf[2 + i] = d[(hi >> (28 - 4 * i)) & 15];
		buf[10 + i] = d[(lo >> (28 - 4 * i)) & 15];
	}
	buf[18] = 0;
	isa_puts(buf);
}

void isa_putdec(u32 v)
{
	char buf[12];
	int i = 11;

	buf[i] = 0;
	do {
		u32 q = isa_udiv32(v, 10);

		buf[--i] = '0' + (v - q * 10);
		v = q;
	} while (v);
	isa_puts(buf + i);
}

extern const struct isa_group __start_isa_groups[];
extern const struct isa_group __stop_isa_groups[];

/* Run every registered group, or only those named in @only (NULL-terminated). */
int isa_main(const char *const *only)
{
	const struct isa_group *g;

	isa_puts("isa: SH-5 SHcompact ISA test kit\n");
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
		cop_exc_count = 0;
		g->run();
		if (cop_exc_count) {
			isa_puts("isa: FAIL unexpected exceptions ");
			isa_putdec(cop_exc_count);
			isa_puts(" last expevt=");
			isa_puthex(&cop_exc_last);
			isa_puts("\n");
			isa_failures++;
			isa_group_failures++;
		}
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
