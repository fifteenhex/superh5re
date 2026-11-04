/* SHcompact system instructions: CLRS, SETS (observed through MAC.W
 * saturation), NOP, LDS/STS FPSCR and FPUL (register forms), FRCHG, FSCHG
 * (Vol. 3 chapter 2; FPSCR layout Vol. 1 section 13.4). */
#include "harness.h"
#include "cops.h"

/* SHcompact FPSCR (Vol. 1 Figure 53, Table 76): RM bit 0, FLAG 2-6, ENABLE
 * 7-11, CAUSE 12-17, DN 18, PR 19, SZ 20, FR 21; bit 1 and bits 22-31 are
 * reserved (written as zero, read value ignored). */
#define FPSCR_DEF	0x003ffffdu
#define FPSCR_PR	(1u << 19)
#define FPSCR_SZ	(1u << 20)
#define FPSCR_FR	(1u << 21)

static u16 wbuf[4] __attribute__((aligned(8)));

/* MAC.W: S = 0 64-bit accumulate, S = 1 32-bit saturating accumulate,
 * MACH = 1 on overflow, unchanged otherwise (Vol. 3 MAC.W) */
static void macw(u32 macl, u32 mach, s32 mul, int s, u32 *rl, u32 *rh)
{
	if (!s) {
		u64 acc = ((u64)mach << 32 | macl) + (u64)(s64)mul;

		*rl = (u32)acc; *rh = (u32)(acc >> 32);
		return;
	}
	s64 sum = (s64)(s32)macl + mul;

	if (sum > 0x7fffffffLL) { *rl = 0x7fffffffu; *rh = 1; }
	else if (sum < -0x80000000LL) { *rl = 0x80000000u; *rh = 1; }
	else { *rl = (u32)sum; *rh = mach; }
}

static u32 fpscr_val(unsigned i)
{
	/* single defined bits, then pseudo-random combinations; PR = SZ = 1 is a
	 * reserved mode (Vol. 1 Table 136) and is not written */
	static const u32 bits[] = { 0, 1u << 0, 1u << 2, 1u << 6, 1u << 7, 1u << 11, 1u << 12,
				    1u << 17, 1u << 18, FPSCR_PR, FPSCR_SZ, FPSCR_FR, 0x00040001u };
	u32 v;

	if (i < sizeof(bits) / sizeof(bits[0]))
		return bits[i];
	v = isa_rand() & FPSCR_DEF;
	if ((v & FPSCR_PR) && (v & FPSCR_SZ))
		v &= ~FPSCR_SZ;
	return v;
}

ISA_GROUP(sys)
{
	struct cres r;
	u32 a, b, v, fpscr0;

	r = cop(cop_sys_fpscr_get, 0, 0, 0, 0);
	fpscr0 = (u32)r.r0;

	/* CLRS / SETS */
	{
		static const u32 accs[][2] = { {0x7fffffff, 0}, {0x80000000, 0xffffffff}, {0, 0},
					       {0x7ffffffe, 0x12345678}, {0x80000001, 0}, {0xffffffff, 0xffffffff},
					       {0x40000000, 0x00000005} };
		static const s16 ops[][2] = { {1, 1}, {-1, 1}, {0x7fff, 0x7fff}, {-0x8000, 0x7fff},
					      {-0x8000, -0x8000}, {3, -5}, {0, 0x1234} };

		for (unsigned i = 0; i < sizeof(accs) / sizeof(accs[0]); i++)
			for (unsigned j = 0; j < sizeof(ops) / sizeof(ops[0]); j++) {
				u32 l, h, c = accs[i][0], d = accs[i][1];
				s32 mul = (s32)ops[j][0] * ops[j][1];

				wbuf[0] = (u16)ops[j][0]; wbuf[1] = (u16)ops[j][1];
				a = ADDR(&wbuf[0]); b = ADDR(&wbuf[1]);
				r = cop(cop_sys_clrs_macw, a, b, c, d);
				macw(c, d, mul, 0, &l, &h);
				CHECK3("clrs mac.w macl", r.r0, RES32(l), c, d, (u32)mul);
				CHECK3("clrs mac.w mach", r.r2, RES32(h), c, d, (u32)mul);
				r = cop(cop_sys_sets_macw, a, b, c, d);
				macw(c, d, mul, 1, &l, &h);
				CHECK3("sets mac.w macl", r.r0, RES32(l), c, d, (u32)mul);
				CHECK3("sets mac.w mach", r.r2, RES32(h), c, d, (u32)mul);
			}
	}

	/* NOP: registers and T unchanged */
	for (u32 t = 0; t < 2; t++) {
		r = cop(cop_sys_nop, 0x12345678, 0x9abcdef0, 0x0badcafe, t);
		CHECK1("nop", r.r0, RES32(0x12345678), t); CHECK1("nop T", r.r1, t, t);
		CHECK1("nop", r.r2, RES32(0x9abcdef0), t); CHECK1("nop", r.r3, RES32(0x0badcafe), t);
	}

	/* FPUL */
	COP_FOREACH(v) {
		r = cop(cop_sys_lds_fpul, v, 0, 0, 0); CHECK1("lds/sts fpul", r.r0, RES32(v), v);
	}

	/* FPSCR: write, read back the defined bits */
	for (unsigned i = 0; i < 64; i++) {
		v = fpscr_val(i);
		r = cop(cop_sys_lds_fpscr, v, 0, 0, 0);
		CHECK1("lds/sts fpscr", r.r0 & FPSCR_DEF, v, v);
		CHECK1("fpscr restored", r.r3, RES32(fpscr0), v);
		/* FRCHG, FSCHG: available only with PR = 0 */
		v &= ~FPSCR_PR;
		r = cop(cop_sys_frchg, v, 0, 0, 0);
		CHECK1("frchg", r.r0 & FPSCR_DEF, v ^ FPSCR_FR, v); CHECK1("frchg x2", r.r1 & FPSCR_DEF, v, v);
		r = cop(cop_sys_fschg, v, 0, 0, 0);
		CHECK1("fschg", r.r0 & FPSCR_DEF, v ^ FPSCR_SZ, v); CHECK1("fschg x2", r.r1 & FPSCR_DEF, v, v);
	}

	r = cop(cop_sys_fpscr_get, 0, 0, 0, 0);
	CHECK0("fpscr at group end", r.r0, RES32(fpscr0));
}
