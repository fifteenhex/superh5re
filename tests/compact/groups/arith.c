/* SHcompact integer arithmetic, logic, shifts, compares, divide steps and
 * multiply-accumulate (Vol. 3 chapter 2). References follow the pseudocode:
 * 32-bit operations, results sign-extended into the register. */
#include "harness.h"
#include "cops.h"

#define CHK(name, r, want)       CHECK2(name, (r).r0, RES32(want), a, b)
#define CHKT(name, r, want)      CHECK2(name " T", (r).r1, (u64)(want), a, b)

static u32 shad(u32 n, u32 m)
{
	u32 sh = m & 31;

	if ((s32)m >= 0)
		return n << sh;
	if (sh != 0)
		return (u32)((s32)n >> (32 - sh));
	return (s32)n < 0 ? 0xffffffffu : 0;
}

static u32 shld(u32 n, u32 m)
{
	u32 sh = m & 31;

	if ((s32)m >= 0)
		return n << sh;
	if (sh != 0)
		return n >> (32 - sh);
	return 0;
}

/* DIV1 Rm, Rn with the Q, M, T state; returns the new Rn, updates *q, *t */
static u32 div1(u32 rn, u32 rm, u32 *q, u32 m, u32 *t)
{
	u32 oldq = *q;
	u64 op2;

	*q = rn >> 31;
	op2 = ((u64)(u32)(rn << 1)) | *t;
	op2 = (oldq == m) ? op2 - rm : op2 + rm;
	*q = (*q ^ m) ^ ((op2 >> 32) & 1);
	*t = 1 - (*q ^ m);
	return (u32)op2;
}

ISA_GROUP(arith)
{
	u32 a, b, im;
	struct cres r;

	COP_FOREACH(a) COP_FOREACH(b) {
		r = cop(cop_add, a, b, 0, 0);   CHK("add", r, a + b);
		r = cop(cop_sub, a, b, 0, 0);   CHK("sub", r, a - b);
		r = cop(cop_and, a, b, 0, 0);   CHK("and", r, a & b);
		r = cop(cop_or, a, b, 0, 0);    CHK("or", r, a | b);
		r = cop(cop_xor, a, b, 0, 0);   CHK("xor", r, a ^ b);
		r = cop(cop_tst, a, b, 0, 0);   CHK("tst", r, a); CHKT("tst", r, (a & b) == 0);
		r = cop(cop_addv, a, b, 0, 0);  CHK("addv", r, a + b);
		CHKT("addv", r, ((s64)(s32)a + (s64)(s32)b) != (s64)(s32)(a + b));
		r = cop(cop_subv, a, b, 0, 0);  CHK("subv", r, a - b);
		CHKT("subv", r, ((s64)(s32)a - (s64)(s32)b) != (s64)(s32)(a - b));
		for (u32 t = 0; t < 2; t++) {
			r = cop(cop_addc, a, b, 0, t);
			CHK("addc", r, a + b + t); CHKT("addc", r, ((u64)a + b + t) >> 32);
			r = cop(cop_subc, a, b, 0, t);
			CHK("subc", r, a - b - t); CHKT("subc", r, ((u64)a - b - t) >> 63);
		}
		r = cop(cop_cmp_eq, a, b, 0, 0); CHKT("cmp/eq", r, a == b);
		r = cop(cop_cmp_hs, a, b, 0, 0); CHKT("cmp/hs", r, a >= b);
		r = cop(cop_cmp_ge, a, b, 0, 0); CHKT("cmp/ge", r, (s32)a >= (s32)b);
		r = cop(cop_cmp_hi, a, b, 0, 0); CHKT("cmp/hi", r, a > b);
		r = cop(cop_cmp_gt, a, b, 0, 0); CHKT("cmp/gt", r, (s32)a > (s32)b);
		{
			u32 x = a ^ b;
			int str = !(x & 0xff) || !(x & 0xff00) || !(x & 0xff0000) || !(x & 0xff000000);
			r = cop(cop_cmp_str, a, b, 0, 0); CHKT("cmp/str", r, str);
		}
		r = cop(cop_xtrct, a, b, 0, 0); CHK("xtrct", r, (b << 16) | (a >> 16));
		r = cop(cop_shad, a, b, 0, 0);  CHK("shad", r, shad(a, b));
		r = cop(cop_shld, a, b, 0, 0);  CHK("shld", r, shld(a, b));
		r = cop(cop_mul_l, a, b, 0, 0); CHK("mul.l", r, a * b);
		r = cop(cop_muls_w, a, b, 0, 0); CHK("muls.w", r, (u32)((s32)(s16)a * (s32)(s16)b));
		r = cop(cop_mulu_w, a, b, 0, 0); CHK("mulu.w", r, (u32)(u16)a * (u32)(u16)b);
		{
			s64 p = (s64)(s32)a * (s64)(s32)b;
			u64 q = (u64)a * (u64)b;
			r = cop(cop_dmuls_l, a, b, 0, 0);
			CHK("dmuls.l macl", r, (u32)p); CHECK2("dmuls.l mach", r.r2, RES32(p >> 32), a, b);
			r = cop(cop_dmulu_l, a, b, 0, 0);
			CHK("dmulu.l macl", r, (u32)q); CHECK2("dmulu.l mach", r.r2, RES32(q >> 32), a, b);
		}
		/* Rm -> Rn forms: source b */
		r = cop(cop_neg, a, b, 0, 0);    CHK("neg", r, 0 - b);
		r = cop(cop_not, a, b, 0, 0);    CHK("not", r, ~b);
		r = cop(cop_exts_b, a, b, 0, 0); CHK("exts.b", r, (u32)(s32)(s8)b);
		r = cop(cop_exts_w, a, b, 0, 0); CHK("exts.w", r, (u32)(s32)(s16)b);
		r = cop(cop_extu_b, a, b, 0, 0); CHK("extu.b", r, b & 0xff);
		r = cop(cop_extu_w, a, b, 0, 0); CHK("extu.w", r, b & 0xffff);
		r = cop(cop_swap_b, a, b, 0, 0); CHK("swap.b", r, (b & 0xffff0000u) | ((b & 0xff) << 8) | ((b >> 8) & 0xff));
		r = cop(cop_swap_w, a, b, 0, 0); CHK("swap.w", r, (b << 16) | (b >> 16));
		r = cop(cop_mov, a, b, 0, 0);    CHK("mov", r, b);
		for (u32 t = 0; t < 2; t++) {
			r = cop(cop_negc, a, b, 0, t);
			CHK("negc", r, 0 - b - t); CHKT("negc", r, (b != 0) || t);
		}
		/* divide steps: Q, M from DIV0S / DIV0U, T */
		{
			static const u32 steps[] = {1, 2, 3, 32};
			static const u16 *const rs[] = {cop_div1s_1, cop_div1s_2, cop_div1s_3, cop_div1s_32};
			static const u16 *const ru[] = {cop_div1u_1, cop_div1u_2, cop_div1u_3, cop_div1u_32};

			for (unsigned k = 0; k < 4; k++) {
				u32 q = a >> 31, m = b >> 31, t = q ^ m, rn = a;

#ifdef ISA_SH4
				/* QEMU's SH-4 computes the DIV1 borrow of a 33-bit
				 * subtraction as the carry of a two's complement
				 * addition, which is wrong for Rm = 0 (Vol. 3 DIV1
				 * defines that case) */
				if (b == 0)
					break;
#endif

				r = cop(rs[k], a, b, 0, 0);
				CHECK2("div0s T", r.r3, (u64)t, a, b);
				for (u32 i = 0; i < steps[k]; i++) rn = div1(rn, b, &q, m, &t);
				CHK("div0s/div1", r, rn); CHKT("div0s/div1", r, t);
				q = 0; m = 0; t = 0; rn = a;
				r = cop(ru[k], a, b, 0, 0);
				for (u32 i = 0; i < steps[k]; i++) rn = div1(rn, b, &q, m, &t);
				CHK("div0u/div1", r, rn); CHKT("div0u/div1", r, t);
			}
			if (b != 0) {
				r = cop(cop_divu32, a, b, 0, 0);
				CHK("div 32/32 unsigned", r, isa_udiv32(a, b));
			}
		}
	}
	COP_FOREACH(a) {
		b = 0;
		r = cop(cop_dt, a, 0, 0, 0);     CHK("dt", r, a - 1); CHKT("dt", r, a - 1 == 0);
		r = cop(cop_shal, a, 0, 0, 0);   CHK("shal", r, a << 1); CHKT("shal", r, a >> 31);
		r = cop(cop_shll, a, 0, 0, 0);   CHK("shll", r, a << 1); CHKT("shll", r, a >> 31);
		r = cop(cop_shar, a, 0, 0, 0);   CHK("shar", r, (u32)((s32)a >> 1)); CHKT("shar", r, a & 1);
		r = cop(cop_shlr, a, 0, 0, 0);   CHK("shlr", r, a >> 1); CHKT("shlr", r, a & 1);
		r = cop(cop_rotl, a, 0, 0, 0);   CHK("rotl", r, (a << 1) | (a >> 31)); CHKT("rotl", r, a >> 31);
		r = cop(cop_rotr, a, 0, 0, 0);   CHK("rotr", r, (a >> 1) | (a << 31)); CHKT("rotr", r, a & 1);
		r = cop(cop_shll2, a, 0, 0, 0);  CHK("shll2", r, a << 2);
		r = cop(cop_shll8, a, 0, 0, 0);  CHK("shll8", r, a << 8);
		r = cop(cop_shll16, a, 0, 0, 0); CHK("shll16", r, a << 16);
		r = cop(cop_shlr2, a, 0, 0, 0);  CHK("shlr2", r, a >> 2);
		r = cop(cop_shlr8, a, 0, 0, 0);  CHK("shlr8", r, a >> 8);
		r = cop(cop_shlr16, a, 0, 0, 0); CHK("shlr16", r, a >> 16);
		r = cop(cop_cmp_pl, a, 0, 0, 0); CHKT("cmp/pl", r, (s32)a > 0);
		r = cop(cop_cmp_pz, a, 0, 0, 0); CHKT("cmp/pz", r, (s32)a >= 0);
		for (u32 t = 0; t < 2; t++) {
			r = cop(cop_rotcl, a, 0, 0, t); CHK("rotcl", r, (a << 1) | t); CHKT("rotcl", r, a >> 31);
			r = cop(cop_rotcr, a, 0, 0, t); CHK("rotcr", r, (a >> 1) | (t << 31)); CHKT("rotcr", r, a & 1);
			r = cop(cop_movt, a, 0, 0, t);  CHK("movt", r, t); CHKT("movt", r, t);
			r = cop(cop_clrt, a, 0, 0, t);  CHKT("clrt", r, 0);
			r = cop(cop_sett, a, 0, 0, t);  CHKT("sett", r, 1);
		}
		/* #imm, R0 */
#define IMM_CASES(X) X(00) X(01) X(7f) X(80) X(ff) X(55)
		/* the immediate goes through a register: gcc 6.5 for sh64 crashes on
		 * a 64-bit XOR with a constant that does not fit XORI */
#define IMMT(i) \
		im = 0x##i; __asm__("" : "+r"(im)); \
		r = cop(cop_and_i##i, a, 0, 0, 0); CHK("and #imm", r, a & im); \
		r = cop(cop_or_i##i, a, 0, 0, 0);  CHK("or #imm", r, a | im); \
		r = cop(cop_xor_i##i, a, 0, 0, 0); CHK("xor #imm", r, a ^ im); \
		r = cop(cop_tst_i##i, a, 0, 0, 0); CHKT("tst #imm", r, (a & im) == 0); \
		r = cop(cop_cmp_eq_i##i, a, 0, 0, 0); CHKT("cmp/eq #imm", r, a == (u32)(s32)(s8)im); \
		r = cop(cop_add_i##i, a, 0, 0, 0); CHK("add #imm", r, a + (u32)(s32)(s8)im); \
		r = cop(cop_mov_i##i, a, 0, 0, 0); CHK("mov #imm", r, (u32)(s32)(s8)im);
		IMM_CASES(IMMT)
	}
	/* multiply-accumulate from memory */
	{
		static u32 buf[8] __attribute__((aligned(16)));
		static const u64 accs[] = { 0, 1, 0x7fffffffffffffffULL, 0x8000000000000000ULL,
					    0x00007fffffffffffULL, 0xffff800000000000ULL, 0x0000800000000000ULL,
					    0xffff7fffffffffffULL, 0x000000007fffffffULL, 0xffffffff80000000ULL };

		for (unsigned i = 0; i < 24; i++) {
			u32 x = isa_rand(), y = isa_rand();
			static const u32 specials[] = {0x80000000u, 0x7fffffffu, 0xffffffffu, 1, 0x8000, 0x7fff, 0xffff8000u};

			if (i < 7) { x = specials[i]; y = specials[(i * 3 + 1) % 7]; }
			buf[0] = x; buf[1] = y; buf[2] = x ^ 0x5a5a; buf[3] = y;
			for (unsigned k = 0; k < sizeof(accs) / sizeof(accs[0]); k++) {
				u64 acc = accs[k], want;
				s64 p;

				/* MAC.L @R5+ (b), @R4+ (a): Rn = a, Rm = b */
				a = ADDR(&buf[0]); b = ADDR(&buf[1]);
				p = (s64)(s32)x * (s64)(s32)y;
				r = cop(cop_mac_l, a, b, (u32)acc, (u32)(acc >> 32));
				want = acc + (u64)p;
				CHECK3("mac.l macl", r.r0, RES32(want), x, y, acc);
				CHECK3("mac.l mach", r.r2, RES32(want >> 32), x, y, acc);
				CHECK3("mac.l rn+", r.r1, RES32(a + 4), x, y, acc);
				CHECK3("mac.l rm+", r.r3, RES32(b + 4), x, y, acc);
				r = cop(cop_mac_l_s, a, b, (u32)acc, (u32)(acc >> 32));
				{
					/* 48-bit saturation of the 65-bit sum: accumulator is a 64-bit two's complement */
					s64 lo = (s64)acc, sum;
					int ovf;

					sum = lo + p;
					ovf = ((lo ^ sum) & (p ^ sum)) < 0;	/* 64-bit overflow */
					if (ovf) want = (lo < 0) ? 0xffff800000000000ULL : 0x00007fffffffffffULL;
					else if (sum > (s64)0x00007fffffffffffLL) want = 0x00007fffffffffffULL;
					else if (sum < (s64)0xffff800000000000LL) want = 0xffff800000000000ULL;
					else want = (u64)sum;
				}
				CHECK3("mac.l/s macl", r.r0, RES32(want), x, y, acc);
				CHECK3("mac.l/s mach", r.r2, RES32(want >> 32), x, y, acc);
				/* MAC.W: 16-bit operands at the pointers */
				p = (s64)(s32)(s16)x * (s64)(s32)(s16)y;
				r = cop(cop_mac_w, a, b, (u32)acc, (u32)(acc >> 32));
				want = acc + (u64)p;
				CHECK3("mac.w macl", r.r0, RES32(want), x, y, acc);
				CHECK3("mac.w mach", r.r2, RES32(want >> 32), x, y, acc);
				CHECK3("mac.w rn+", r.r1, RES32(a + 2), x, y, acc);
				CHECK3("mac.w rm+", r.r3, RES32(b + 2), x, y, acc);
				r = cop(cop_mac_w_s, a, b, (u32)acc, (u32)(acc >> 32));
				{
					s64 sum = (s64)(s32)(u32)acc + p;
					u32 mach = (u32)(acc >> 32);

					if (sum > 0x7fffffffLL) { want = 0x7fffffffu; mach = 1; }
					else if (sum < -0x80000000LL) { want = 0x80000000u; mach = 1; }
					else want = (u32)sum;
					CHECK3("mac.w/s macl", r.r0, RES32(want), x, y, acc);
					CHECK3("mac.w/s mach", r.r2, RES32(mach), x, y, acc);
				}
			}
		}
		r = cop(cop_clrmac, 0x12345678, 0x9abcdef0, 0, 0);
		CHECK0("clrmac macl", r.r0, 0); CHECK0("clrmac mach", r.r2, 0);
		r = cop(cop_lds_sts_mac, 0x12345678, 0x9abcdef0, 0, 0);
		CHECK0("lds/sts macl", r.r0, RES32(0x12345678)); CHECK0("lds/sts mach", r.r2, RES32(0x9abcdef0));
	}
}
