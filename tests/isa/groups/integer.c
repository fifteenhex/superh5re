/*
 * Integer instructions: MULS.L, MULU.L, NSB, BYTEREV, CMPEQ, CMPGT, CMPGTU,
 * CMVEQ, CMVNE, MOVI, SHORI (Vol. 2 ch. 2).
 *
 * The reference values follow the manual's pseudocode.  The 64-bit product
 * is formed by shift-and-add so that it does not depend on the multiplier
 * under test, and NSB is the manual's SignExtend-n loop written literally.
 */
#include "harness.h"

/* insn Rm, Rn, Rw with Rw read and written ("+r"): CMVEQ, CMVNE. */
#define ASM_RRW(insn, m, n, w) ({					\
	u64 _w = (w), _m = (m), _n = (n);				\
	__asm__ volatile (insn " %1, %2, %0" : "+r"(_w) : "r"(_m), "r"(_n)); \
	_w; })

/* insn Rm, Rn, Rw with Rw the same register as Rm. */
#define ASM_RRW_W_IS_M(insn, m, n) ({					\
	u64 _r, _m = (m), _n = (n);					\
	__asm__ volatile (insn " %1, %2, %0" : "=r"(_r) : "0"(_m), "r"(_n)); \
	_r; })

/* insn Rm, Rn, Rw with Rw the same register as Rn. */
#define ASM_RRW_W_IS_N(insn, m, n) ({					\
	u64 _r, _m = (m), _n = (n);					\
	__asm__ volatile (insn " %1, %2, %0" : "=r"(_r) : "r"(_m), "0"(_n)); \
	_r; })

/* movi #imm, Rd; the literal must fit the 16-bit signed field, otherwise
 * gas silently expands it into a movi/shori sequence. */
#define ASM_MOVI(imm) ({						\
	u64 _r;								\
	__asm__ volatile ("movi " #imm ", %0" : "=r"(_r));		\
	_r; })

/* shori #imm, Rw */
#define ASM_SHORI(imm, w) ({						\
	u64 _w = (w);							\
	__asm__ volatile ("shori " #imm ", %0" : "+r"(_w));		\
	_w; })

/* movi/shori chains building 32-, 48- and 64-bit constants */
#define ASM_CHAIN2(i0, i1) ({						\
	u64 _r;								\
	__asm__ volatile ("movi " #i0 ", %0\n\t"			\
			  "shori " #i1 ", %0" : "=r"(_r));		\
	_r; })
#define ASM_CHAIN3(i0, i1, i2) ({					\
	u64 _r;								\
	__asm__ volatile ("movi " #i0 ", %0\n\t"			\
			  "shori " #i1 ", %0\n\t"			\
			  "shori " #i2 ", %0" : "=r"(_r));		\
	_r; })
#define ASM_CHAIN4(i0, i1, i2, i3) ({					\
	u64 _r;								\
	__asm__ volatile ("movi " #i0 ", %0\n\t"			\
			  "shori " #i1 ", %0\n\t"			\
			  "shori " #i2 ", %0\n\t"			\
			  "shori " #i3 ", %0" : "=r"(_r));		\
	_r; })

/* MOVI: imm <- SignExtend16(s) */
static u64 ref_movi(u64 s)
{
	return (u64)SignExtend16(s & 0xffff);
}

/* SHORI: imm <- ZeroExtend16(SignExtend16(s)); Rw <- (Rw << 16) | imm */
static u64 ref_shori(u64 w, u64 s)
{
	u64 imm = ZeroExtend16((u64)SignExtend16(s & 0xffff));

	return (w << 16) | imm;
}

/* Unsigned 32x32 -> 64 product by shift-and-add (no multiply instruction). */
static u64 ref_mul32(u32 a, u32 b)
{
	u64 r = 0;
	int i;

	for (i = 0; i < 32; i++)
		if ((b >> i) & 1)
			r += (u64)a << i;
	return r;
}

/* MULU.L: ZeroExtend32(Rm) * ZeroExtend32(Rn), 64-bit result */
static u64 ref_mulu_l(u64 a, u64 b)
{
	return ref_mul32((u32)ZeroExtend32(a), (u32)ZeroExtend32(b));
}

/* MULS.L: SignExtend32(Rm) * SignExtend32(Rn), 64-bit result (mod 2^64) */
static u64 ref_muls_l(u64 a, u64 b)
{
	s64 sa = SignExtend32(a), sb = SignExtend32(b);
	int neg = (sa < 0) != (sb < 0);
	u32 ua = sa < 0 ? (u32)(0 - (u64)sa) : (u32)sa;	/* |-2^31| fits */
	u32 ub = sb < 0 ? (u32)(0 - (u64)sb) : (u32)sb;
	u64 p = ref_mul32(ua, ub);

	return neg ? 0 - p : p;
}

/* SignExtend-n of a 64-bit value, 1 <= n <= 64 */
static s64 sign_extend_n(s64 v, int n)
{
	int sh = 64 - n;

	return sh ? (s64)((u64)v << sh) >> sh : v;
}

/* NSB: the manual's loop; result is the largest i with SignExtend(64-i)
 * leaving the value unchanged, i.e. consecutive sign bits minus one. */
static u64 ref_nsb(u64 v)
{
	s64 source = (s64)v;
	u64 result = 0;
	int i;

	for (i = 0; i < 64; i++) {
		int n = 64 - i;

		if (sign_extend_n(source, n) == source)
			result = i;
	}
	return result;
}

/* BYTEREV */
static u64 ref_byterev(u64 v)
{
	u64 source = v, result = 0;
	int i;

	for (i = 0; i < 8; i++) {
		result = (result << 8) | (source & 0xff);
		source >>= 8;
	}
	return result;
}

#define CHECK_MOVI(imm) \
	CHECK1("movi " #imm, ASM_MOVI(imm), ref_movi((u64)(s64)(imm)), (u64)(s64)(imm))

#define CHECK_SHORI(imm, w) \
	CHECK2("shori " #imm, ASM_SHORI(imm, w), ref_shori((w), (imm)), (imm), (w))

#define CHECK_CHAIN2(i0, i1)						\
	CHECK0("movi " #i0 "; shori " #i1, ASM_CHAIN2(i0, i1),		\
	       ref_shori(ref_movi((u64)(s64)(i0)), (i1)))
#define CHECK_CHAIN3(i0, i1, i2)					\
	CHECK0("movi " #i0 "; shori " #i1 "; shori " #i2,		\
	       ASM_CHAIN3(i0, i1, i2),					\
	       ref_shori(ref_shori(ref_movi((u64)(s64)(i0)), (i1)), (i2)))
#define CHECK_CHAIN4(i0, i1, i2, i3)					\
	CHECK0("movi " #i0 "; shori " #i1 "; shori " #i2 "; shori " #i3, \
	       ASM_CHAIN4(i0, i1, i2, i3),				\
	       ref_shori(ref_shori(ref_shori(ref_movi((u64)(s64)(i0)),	\
					     (i1)), (i2)), (i3)))

#define CHECK_SHORI_ALL(w) do {						\
	CHECK_SHORI(0, w);						\
	CHECK_SHORI(1, w);						\
	CHECK_SHORI(0x00ff, w);						\
	CHECK_SHORI(0x0100, w);						\
	CHECK_SHORI(0x1234, w);						\
	CHECK_SHORI(0x7fff, w);						\
	CHECK_SHORI(0x8000, w);						\
	CHECK_SHORI(0xabcd, w);						\
	CHECK_SHORI(0xff00, w);						\
	CHECK_SHORI(0xffff, w);						\
	CHECK_SHORI(65535, w);						\
} while (0)

static void test_mul(u64 a, u64 b)
{
	CHECK2("muls.l", ASM_RRR("muls.l", a, b), ref_muls_l(a, b), a, b);
	CHECK2("mulu.l", ASM_RRR("mulu.l", a, b), ref_mulu_l(a, b), a, b);
}

static void test_cmp(u64 a, u64 b)
{
	CHECK2("cmpeq", ASM_RRR("cmpeq", a, b), (u64)(a == b), a, b);
	CHECK2("cmpgt", ASM_RRR("cmpgt", a, b), (u64)((s64)a > (s64)b), a, b);
	CHECK2("cmpgtu", ASM_RRR("cmpgtu", a, b), (u64)(a > b), a, b);
}

/* CMVEQ/CMVNE Rm, Rn, Rw with Rw preset to @w (always different from n). */
static void test_cmv(u64 m, u64 n, u64 w)
{
	CHECK3("cmveq", ASM_RRW("cmveq", m, n, w), m == 0 ? n : w, m, n, w);
	CHECK3("cmvne", ASM_RRW("cmvne", m, n, w), m != 0 ? n : w, m, n, w);
}

static void test_unary(u64 a)
{
	CHECK1("nsb", ASM_RR("nsb", a), ref_nsb(a), a);
	CHECK1("byterev", ASM_RR("byterev", a), ref_byterev(a), a);
}

ISA_GROUP(integer)
{
	u64 a, b, w;
	int i, k;

	/* MULS.L, MULU.L, CMPEQ, CMPGT, CMPGTU over the corpus and random pairs */
	ISA_FOREACH_OPERAND(a) ISA_FOREACH_OPERAND(b) {
		test_mul(a, b);
		test_cmp(a, b);
	}
	for (i = 0; i < 64; i++) {
		a = isa_rand();
		b = isa_rand();
		test_mul(a, b);
		test_cmp(a, b);
		/* products of small and 32-bit-boundary values */
		test_mul(a & 0xffff, b);
		test_mul(a | 0x80000000, b | 0x80000000);
		/* close neighbours, including the equal case */
		test_cmp(a, a);
		test_cmp(a, a + 1);
		test_cmp(a, a - 1);
		test_cmp(a, a ^ 0x8000000000000000ULL);
	}

	/* CMVEQ, CMVNE: taken and not taken, Rw preset */
	ISA_FOREACH_OPERAND(a) ISA_FOREACH_OPERAND(b) {
		test_cmv(a, b, ~b);
		test_cmv(a, b, b ^ 0x00000000c0ffee00ULL);
	}
	for (i = 0; i < 64; i++) {
		w = isa_rand();
		b = isa_rand();
		test_cmv(0, b, w);
		test_cmv(isa_rand() | 1, b, w);
		test_cmv(isa_rand() << 32, b, w);	/* only high bits set */
		test_cmv(1ULL << (i & 63), b, w);	/* single bit set */
	}
	/* Rw aliased with Rm or Rn */
	ISA_FOREACH_OPERAND(a) ISA_FOREACH_OPERAND(b) {
		CHECK2("cmveq w=m", ASM_RRW_W_IS_M("cmveq", a, b),
		       a == 0 ? b : a, a, b);
		CHECK2("cmvne w=m", ASM_RRW_W_IS_M("cmvne", a, b),
		       a != 0 ? b : a, a, b);
		CHECK2("cmveq w=n", ASM_RRW_W_IS_N("cmveq", a, b), b, a, b);
		CHECK2("cmvne w=n", ASM_RRW_W_IS_N("cmvne", a, b), b, a, b);
	}

	/* NSB, BYTEREV over the corpus */
	ISA_FOREACH_OPERAND(a)
		test_unary(a);
	/* NSB: every result 0..63 for positive and negative values */
	for (k = 0; k < 63; k++) {
		a = 1ULL << (62 - k);			/* k+1 leading zeros */
		test_unary(a);
		test_unary(~a);				/* k+1 leading ones */
		test_unary((1ULL << (63 - k)) - 1);	/* 000..0111..1 */
		test_unary(~((1ULL << (63 - k)) - 1));	/* 111..1000..0 */
		test_unary(a | (isa_rand() & (a - 1)));	/* random low bits */
		test_unary(~a & ~(isa_rand() & (a - 1)));
	}
	test_unary(0);					/* nsb = 63 */
	test_unary(~0ULL);				/* nsb = 63 */
	test_unary(0x8000000000000000ULL);		/* nsb = 0 */
	test_unary(0x7fffffffffffffffULL);		/* nsb = 0 */
	for (i = 0; i < 64; i++)
		test_unary(isa_rand());

	/* MOVI: the 16-bit signed range */
	CHECK_MOVI(0);
	CHECK_MOVI(1);
	CHECK_MOVI(-1);
	CHECK_MOVI(2);
	CHECK_MOVI(-2);
	CHECK_MOVI(127);
	CHECK_MOVI(128);
	CHECK_MOVI(-128);
	CHECK_MOVI(-129);
	CHECK_MOVI(255);
	CHECK_MOVI(256);
	CHECK_MOVI(-256);
	CHECK_MOVI(0x1234);
	CHECK_MOVI(-0x1234);
	CHECK_MOVI(0x5555);
	CHECK_MOVI(-0x5556);		/* field 0xaaaa */
	CHECK_MOVI(0x7ffe);
	CHECK_MOVI(0x7fff);
	CHECK_MOVI(32767);
	CHECK_MOVI(-32767);
	CHECK_MOVI(-32768);		/* field 0x8000 */
	CHECK_MOVI(-0x8000);

	/* SHORI: unsigned 16-bit immediates over the corpus as Rw */
	ISA_FOREACH_OPERAND(w)
		CHECK_SHORI_ALL(w);
	for (i = 0; i < 16; i++) {
		w = isa_rand();		/* the macro evaluates w several times */
		CHECK_SHORI_ALL(w);
	}

	/* movi/shori chains: 32-bit constants (sign-extended) */
	CHECK_CHAIN2(0x1234, 0x5678);		/* 0x0000000012345678 */
	CHECK_CHAIN2(0x7fff, 0xffff);		/* 0x000000007fffffff */
	CHECK_CHAIN2(-32768, 0);		/* 0xffffffff80000000 */
	CHECK_CHAIN2(-32768, 1);		/* 0xffffffff80000001 */
	CHECK_CHAIN2(-8531, 0xbeef);		/* 0xffffffffdeadbeef */
	CHECK_CHAIN2(-1, 0xffff);		/* 0xffffffffffffffff */
	CHECK_CHAIN2(-1, 0);			/* 0xffffffffffff0000 */
	CHECK_CHAIN2(0, 0xffff);		/* 0x000000000000ffff */
	CHECK_CHAIN2(0, 0x8000);		/* 0x0000000000008000 */
	CHECK_CHAIN2(1, 0);			/* 0x0000000000010000 */
	CHECK_CHAIN2(-0x5556, 0xaaaa);		/* 0xffffffffaaaaaaaa */
	CHECK_CHAIN2(0x5555, 0x5555);		/* 0x0000000055555555 */
	/* 48-bit chains: zero-extended 32-bit constants and more */
	CHECK_CHAIN3(0, 0xdead, 0xbeef);	/* 0x00000000deadbeef */
	CHECK_CHAIN3(0, 0x8000, 0);		/* 0x0000000080000000 */
	CHECK_CHAIN3(0, 0xffff, 0xffff);	/* 0x00000000ffffffff */
	CHECK_CHAIN3(1, 0, 0);			/* 0x0000000100000000 */
	CHECK_CHAIN3(-1, 0x8000, 0);		/* 0xffffffff80000000 */
	CHECK_CHAIN3(0x1234, 0x5678, 0x9abc);	/* 0x0000123456789abc */
	CHECK_CHAIN3(-32768, 0xffff, 0xffff);	/* 0xffff8000ffffffff */
	/* 64-bit chains */
	CHECK_CHAIN4(0x0123, 0x4567, 0x89ab, 0xcdef);	/* 0x0123456789abcdef */
	CHECK_CHAIN4(-292, 0xba98, 0x7654, 0x3210);	/* 0xfedcba9876543210 */
	CHECK_CHAIN4(-32768, 0, 0, 0);			/* 0x8000000000000000 */
	CHECK_CHAIN4(0x7fff, 0xffff, 0xffff, 0xffff);	/* 0x7fffffffffffffff */
	CHECK_CHAIN4(-1, 0xffff, 0xffff, 0xffff);	/* 0xffffffffffffffff */
	CHECK_CHAIN4(-1, 0xffff, 0xffff, 0xfffe);	/* 0xfffffffffffffffe */
	CHECK_CHAIN4(0, 0, 0, 0);			/* 0 */
	CHECK_CHAIN4(0, 0, 0, 1);			/* 1 */
	CHECK_CHAIN4(-8531, 0xbeef, 0, 0);		/* 0xdeadbeef00000000 */
	CHECK_CHAIN4(0, 0, 0xdead, 0xbeef);		/* 0x00000000deadbeef */
	CHECK_CHAIN4(0x5555, 0x5555, 0x5555, 0x5555);	/* 0x5555555555555555 */
	CHECK_CHAIN4(-0x5556, 0xaaaa, 0xaaaa, 0xaaaa);	/* 0xaaaaaaaaaaaaaaaa */
}
