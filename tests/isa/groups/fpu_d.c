/*
 * Double-precision FPU and conversions (Vol. 2 ch. 2, Vol. 1 ch. 8):
 * FADD.D, FSUB.D, FMUL.D, FDIV.D, FSQRT.D, FABS.D, FNEG.D, FCMPEQ.D,
 * FCMPGT.D, FCMPGE.D, FCMPUN.D, FMOV.D, FMOV.DQ, FMOV.QD, FCNV.SD, FCNV.DS,
 * FLOAT.LD, FLOAT.QD, FTRC.DL, FTRC.DQ, FLD.D, FST.D, FLDX.D, FSTX.D,
 * FLD.P, FST.P, FLDX.P, FSTX.P.
 *
 * The program is compiled with -m5-32media, so C double arithmetic would
 * run on the FPU under test.  The expected results and FPSCR values for the
 * arithmetic, comparison and conversion instructions are therefore computed
 * on the host by tools/gen_fpu_d.py from IEEE754 and the manual's
 * special-case tables (fpu_d_vectors.h).  Results are compared as bit
 * patterns.  Every test sets FPSCR first (FPUTSCR) and reads it back after
 * the instruction (FGETSCR); the exception enables are never set, and
 * denormalized sources are only given to arithmetic instructions with
 * FPSCR.DN = 1, since with DN = 0 they raise the FPU error exception.
 *
 * Register plumbing uses only FMOV.QD / FMOV.DQ: DR2i is the pair FR2i
 * (upper 32 bits) : FR2i+1 (lower 32 bits), Vol. 1 section 3.3.  Results of
 * instructions that write a single FR are read through the containing DR so
 * that the other half of the pair is checked to be untouched.
 */
#include "harness.h"
#include "fpu_d_vectors.h"

#define FPD_SIGN	0x8000000000000000ULL
#define FPD_FPSCR_RM	0x00000001u	/* 1: round toward zero */
#define FPD_FPSCR_FLAG	0x0000007cu	/* I U O Z V, bits 2..6 */
#define FPD_FPSCR_CAUSE	0x0003f000u	/* I U O Z V E, bits 12..17 */
#define FPD_FPSCR_DN	0x00040000u
#define FPD_FLAG_I	0x00000004u
#define FPD_FLAG_Z	0x00000020u
#define FPD_FLAG_V	0x00000040u
#define FPD_CAUSE_I	0x00001000u
#define FPD_CAUSE_Z	0x00008000u
#define FPD_CAUSE_V	0x00010000u
#define FPD_V		(FPD_FLAG_V | FPD_CAUSE_V)

#define fpd_swap32(x)	((((u64)(x)) << 32) | (((u64)(x)) >> 32))

/*
 * Effective addresses are 64-bit; in 32-bit mode they must be the sign
 * extension of the 32-bit address, otherwise RADDERR/WADDERR is raised.
 * (unsigned long)p would zero-extend.
 */
#define fpd_addr(p)	((u64)(s64)(long)(p))

/* FPSCR is a single-precision register operand: use fr62, upper half of dr62. */
static void fpd_putscr(u32 v)
{
	u64 t = (u64)v << 32;

	__asm__ volatile("fmov.qd %0, dr62\n\tfputscr fr62" : : "r"(t) : "fr62", "fr63");
}

static u32 fpd_getscr(void)
{
	u64 t;

	__asm__ volatile("fgetscr fr62\n\tfmov.dq dr62, %0" : "=r"(t) : : "fr62", "fr63");
	return (u32)(t >> 32);
}

/* insn DRg, DRh, DRf  (dr0, dr2 -> dr4), then FPSCR in the upper half of scr */
#define FPD_DYADIC(insn, a, b, res, scr)				\
	__asm__ volatile("fmov.qd %2, dr0\n\t"				\
			 "fmov.qd %3, dr2\n\t"				\
			 insn " dr0, dr2, dr4\n\t"			\
			 "fmov.dq dr4, %0\n\t"				\
			 "fgetscr fr62\n\t"				\
			 "fmov.dq dr62, %1"				\
			 : "=r"(res), "=r"(scr) : "r"(a), "r"(b)	\
			 : "fr0", "fr1", "fr2", "fr3", "fr4", "fr5", "fr62", "fr63")

/* insn DRg, DRh, Rd */
#define FPD_CMP(insn, a, b, res, scr)					\
	__asm__ volatile("fmov.qd %2, dr0\n\t"				\
			 "fmov.qd %3, dr2\n\t"				\
			 insn " dr0, dr2, %0\n\t"			\
			 "fgetscr fr62\n\t"				\
			 "fmov.dq dr62, %1"				\
			 : "=r"(res), "=r"(scr) : "r"(a), "r"(b)	\
			 : "fr0", "fr1", "fr2", "fr3", "fr62", "fr63")

/* dr0 = a, dr2 = pre, then insn (reading dr0/fr0, writing dr2/fr2/fr3), result dr2 */
#define FPD_MONADIC(insn, a, pre, res, scr)				\
	__asm__ volatile("fmov.qd %2, dr0\n\t"				\
			 "fmov.qd %3, dr2\n\t"				\
			 insn "\n\t"					\
			 "fmov.dq dr2, %0\n\t"				\
			 "fgetscr fr62\n\t"				\
			 "fmov.dq dr62, %1"				\
			 : "=r"(res), "=r"(scr) : "r"(a), "r"(pre)	\
			 : "fr0", "fr1", "fr2", "fr3", "fr62", "fr63")

/* Loads with a literal displacement; the result is read through dr0 / dr62. */
#define FPD_FLD_D(base, disp, res)					\
	__asm__ volatile("fld.d %1, " #disp ", dr0\n\tfmov.dq dr0, %0"	\
			 : "=r"(res) : "r"(base) : "fr0", "fr1", "memory")
#define FPD_FLD_P(base, disp, res)					\
	__asm__ volatile("fld.p %1, " #disp ", fp62\n\tfmov.dq dr62, %0" \
			 : "=r"(res) : "r"(base) : "fr62", "fr63", "memory")
#define FPD_FST_D(base, disp, val)					\
	__asm__ volatile("fmov.qd %1, dr62\n\tfst.d %0, " #disp ", dr62" \
			 : : "r"(base), "r"(val) : "fr62", "fr63", "memory")
#define FPD_FST_P(base, disp, val)					\
	__asm__ volatile("fmov.qd %1, dr0\n\tfst.p %0, " #disp ", fp0"	\
			 : : "r"(base), "r"(val) : "fr0", "fr1", "memory")

/* Register plus register forms. */
static u64 fpd_fldx_d(u64 base, u64 index)
{
	u64 r;

	__asm__ volatile("fldx.d %1, %2, dr4\n\tfmov.dq dr4, %0"
			 : "=r"(r) : "r"(base), "r"(index) : "fr4", "fr5", "memory");
	return r;
}

static u64 fpd_fldx_p(u64 base, u64 index)
{
	u64 r;

	__asm__ volatile("fldx.p %1, %2, fp60\n\tfmov.dq dr60, %0"
			 : "=r"(r) : "r"(base), "r"(index) : "fr60", "fr61", "memory");
	return r;
}

static void fpd_fstx_d(u64 base, u64 index, u64 val)
{
	__asm__ volatile("fmov.qd %2, dr60\n\tfstx.d %0, %1, dr60"
			 : : "r"(base), "r"(index), "r"(val) : "fr60", "fr61", "memory");
}

static void fpd_fstx_p(u64 base, u64 index, u64 val)
{
	__asm__ volatile("fmov.qd %2, dr4\n\tfstx.p %0, %1, fp4"
			 : : "r"(base), "r"(index), "r"(val) : "fr4", "fr5", "memory");
}

/* Memory for FLD/FST: displacements are s10 << 3, i.e. -4096..4088 bytes. */
#define FPD_MEM_WORDS	(1024 + 16)
#define FPD_MEM_BASE	(512 + 8)
static u64 fpd_mem[FPD_MEM_WORDS] __attribute__((aligned(16)));

static void fpd_fill_mem(void)
{
	unsigned i;

	for (i = 0; i < FPD_MEM_WORDS; i++)
		fpd_mem[i] = isa_rand();
}

static void fpd_test_dyadic(const char *insn, const char *insn_scr,
			    const struct fpd_dyadic *vec, unsigned n, int op)
{
	unsigned i;

	for (i = 0; i < n; i++) {
		u64 a = fpd_vals[vec[i].a], b = fpd_vals[vec[i].b];
		u32 mode = fpd_modes[vec[i].m];
		u64 r, scr;

		fpd_putscr(mode);
		switch (op) {
		case 0: FPD_DYADIC("fadd.d", a, b, r, scr); break;
		case 1: FPD_DYADIC("fsub.d", a, b, r, scr); break;
		case 2: FPD_DYADIC("fmul.d", a, b, r, scr); break;
		default: FPD_DYADIC("fdiv.d", a, b, r, scr); break;
		}
		CHECK3(insn, r, vec[i].r, a, b, mode);
		CHECK3(insn_scr, scr >> 32, vec[i].fpscr, a, b, mode);
	}
}

static void fpd_test_cmp(void)
{
	unsigned i, k;
	static const char *const names[4] = { "fcmpeq.d", "fcmpgt.d", "fcmpge.d", "fcmpun.d" };
	static const char *const names_scr[4] = {
		"fcmpeq.d fpscr", "fcmpgt.d fpscr", "fcmpge.d fpscr", "fcmpun.d fpscr" };

	for (i = 0; i < sizeof(fpd_cmp_vec) / sizeof(fpd_cmp_vec[0]); i++) {
		const struct fpd_cmp *v = &fpd_cmp_vec[i];
		u64 a = fpd_vals[v->a], b = fpd_vals[v->b];
		u32 mode = fpd_modes[v->m];

		for (k = 0; k < 4; k++) {
			u64 r, scr;
			u32 want_scr = mode | ((v->inv >> k) & 1 ? FPD_V : 0);

			fpd_putscr(mode);
			switch (k) {
			case 0: FPD_CMP("fcmpeq.d", a, b, r, scr); break;
			case 1: FPD_CMP("fcmpgt.d", a, b, r, scr); break;
			case 2: FPD_CMP("fcmpge.d", a, b, r, scr); break;
			default: FPD_CMP("fcmpun.d", a, b, r, scr); break;
			}
			CHECK3(names[k], r, (u64)((v->res >> k) & 1), a, b, mode);
			CHECK3(names_scr[k], scr >> 32, want_scr, a, b, mode);
		}
	}
}

/*
 * Monadic instructions.  @kind selects the operand plumbing:
 *  0: DRg -> DRf                        (FSQRT.D, FTRC.DQ, FLOAT.QD)
 *  1: DRg -> FRf (even), FRf+1 kept     (FCNV.DS)
 *  2: DRg -> FRf+1 (odd), FRf kept      (FTRC.DL written to fr3)
 *  3: FRg (32-bit input in fr0) -> DRf  (FCNV.SD, FLOAT.LD)
 */
static void fpd_test_monadic(const char *insn, const char *insn_scr,
			     const struct fpd_monadic *vec, unsigned n, int op, int kind)
{
	unsigned i;
	const u64 pre = 0x5a5aa5a5c3c33c3cULL;	/* previous contents of dr2 */

	for (i = 0; i < n; i++) {
		u64 a = vec[i].a, want = vec[i].r, in, r, scr;

		/* a 32-bit source sits in fr0; fr1 holds its complement */
		in = kind == 3 ? (a << 32) | (~a & 0xffffffffULL) : a;
		if (kind == 1)
			want = (want << 32) | (pre & 0xffffffffULL);
		else if (kind == 2)
			want = (pre & 0xffffffff00000000ULL) | want;

		fpd_putscr(vec[i].fpscr_in);
		switch (op) {
		case 0: FPD_MONADIC("fsqrt.d dr0, dr2", in, pre, r, scr); break;
		case 1: FPD_MONADIC("fcnv.ds dr0, fr2", in, pre, r, scr); break;
		case 2: FPD_MONADIC("fcnv.sd fr0, dr2", in, pre, r, scr); break;
		case 3: FPD_MONADIC("ftrc.dl dr0, fr3", in, pre, r, scr); break;
		case 4: FPD_MONADIC("ftrc.dq dr0, dr2", in, pre, r, scr); break;
		case 5: FPD_MONADIC("float.ld fr0, dr2", in, pre, r, scr); break;
		default: FPD_MONADIC("float.qd dr0, dr2", in, pre, r, scr); break;
		}
		CHECK2(insn, r, want, a, vec[i].fpscr_in);
		CHECK2(insn_scr, scr >> 32, vec[i].fpscr, a, vec[i].fpscr_in);
	}
}

/* FMOV.QD/FMOV.DQ round trips, FMOV.D, FABS.D, FNEG.D: bit copies, no FPSCR effect. */
static void fpd_test_moves(u64 a)
{
	u64 r, r2;
	const u32 scr_in = FPD_FPSCR_DN | FPD_FPSCR_CAUSE | FPD_FPSCR_FLAG | FPD_FPSCR_RM;

	fpd_putscr(scr_in);
	__asm__ volatile("fmov.qd %1, dr0\n\tfmov.dq dr0, %0"
			 : "=r"(r) : "r"(a) : "fr0", "fr1");
	CHECK1("fmov.qd/fmov.dq dr0", r, a, a);
	__asm__ volatile("fmov.qd %1, dr62\n\tfmov.dq dr62, %0"
			 : "=r"(r) : "r"(a) : "fr62", "fr63");
	CHECK1("fmov.qd/fmov.dq dr62", r, a, a);
	__asm__ volatile("fmov.qd %2, dr0\n\tfmov.qd %3, dr2\n\t"
			 "fmov.d dr0, dr60\n\tfmov.d dr60, dr2\n\t"
			 "fmov.dq dr2, %0\n\tfmov.dq dr60, %1"
			 : "=r"(r), "=r"(r2) : "r"(a), "r"(~a)
			 : "fr0", "fr1", "fr2", "fr3", "fr60", "fr61");
	CHECK1("fmov.d", r, a, a);
	CHECK1("fmov.d dr60", r2, a, a);
	__asm__ volatile("fmov.qd %1, dr0\n\tfabs.d dr0, dr2\n\tfmov.dq dr2, %0"
			 : "=r"(r) : "r"(a) : "fr0", "fr1", "fr2", "fr3");
	CHECK1("fabs.d", r, a & ~FPD_SIGN, a);
	__asm__ volatile("fmov.qd %1, dr0\n\tfneg.d dr0, dr2\n\tfmov.dq dr2, %0"
			 : "=r"(r) : "r"(a) : "fr0", "fr1", "fr2", "fr3");
	CHECK1("fneg.d", r, a ^ FPD_SIGN, a);
	__asm__ volatile("fmov.qd %1, dr0\n\tfneg.d dr0, dr0\n\tfabs.d dr0, dr0\n\tfmov.dq dr0, %0"
			 : "=r"(r) : "r"(a) : "fr0", "fr1");
	CHECK1("fneg.d/fabs.d in place", r, a & ~FPD_SIGN, a);
	/* none of the above is an arithmetic operation: FPSCR is untouched
	 * (Vol. 2 FABS.D, FNEG.D, FMOV.D, FMOV.DQ, FMOV.QD pseudocode) */
	CHECK1("fmov/fabs/fneg fpscr unchanged", fpd_getscr(), scr_in, a);
	fpd_putscr(0);
}

/* FLD.D / FLD.P with every displacement form, against C reads of the buffer. */
static void fpd_test_loads(void)
{
	u64 *base = &fpd_mem[FPD_MEM_BASE];
	u64 b = fpd_addr(base), r;

#define FPD_LD_CASE(disp)						\
	FPD_FLD_D(b, disp, r);						\
	CHECK2("fld.d", r, base[(disp) / 8], base[(disp) / 8], (u64)(s64)(disp)); \
	FPD_FLD_P(b, disp, r);						\
	CHECK2("fld.p", r, fpd_swap32(base[(disp) / 8]), base[(disp) / 8], (u64)(s64)(disp)); \
	r = fpd_fldx_d(b, (u64)(s64)(disp));				\
	CHECK2("fldx.d", r, base[(disp) / 8], base[(disp) / 8], (u64)(s64)(disp)); \
	r = fpd_fldx_p(b, (u64)(s64)(disp));				\
	CHECK2("fldx.p", r, fpd_swap32(base[(disp) / 8]), base[(disp) / 8], (u64)(s64)(disp));

	FPD_LD_CASE(0)
	FPD_LD_CASE(8)
	FPD_LD_CASE(-8)
	FPD_LD_CASE(16)
	FPD_LD_CASE(-16)
	FPD_LD_CASE(1024)
	FPD_LD_CASE(-1024)
	FPD_LD_CASE(2048)
	FPD_LD_CASE(-2048)
	FPD_LD_CASE(4088)
	FPD_LD_CASE(-4096)
#undef FPD_LD_CASE

	/* register + register: Rm is zero-extended, Rn sign-extended (Vol. 2 FLDX.D) */
	r = fpd_fldx_d(b + 4096, (u64)(s64)-4096);
	CHECK2("fldx.d", r, base[0], base[0], (u64)(s64)-4096);
	r = fpd_fldx_d(b - 8, 16);
	CHECK2("fldx.d", r, base[1], base[1], 16);
	r = fpd_fldx_p(b + 8, (u64)(s64)-16);
	CHECK2("fldx.p", r, fpd_swap32(base[-1]), base[-1], (u64)(s64)-16);
	r = fpd_fldx_d(0, b + 24);
	CHECK2("fldx.d base 0", r, base[3], base[3], 24);
}

/* FST.D / FST.P: the stored word and both neighbours, against C reads. */
static void fpd_test_stores(u64 v)
{
	u64 *base = &fpd_mem[FPD_MEM_BASE];
	u64 b = fpd_addr(base);
	u64 lo, hi;

#define FPD_ST_CASE(disp, STORE, name, want)				\
	lo = base[(disp) / 8 - 1]; hi = base[(disp) / 8 + 1];		\
	STORE;								\
	CHECK2(name, base[(disp) / 8], want, v, (u64)(s64)(disp));	\
	CHECK2(name " below", base[(disp) / 8 - 1], lo, v, (u64)(s64)(disp)); \
	CHECK2(name " above", base[(disp) / 8 + 1], hi, v, (u64)(s64)(disp));
#define FPD_ST_D(disp)	FPD_ST_CASE(disp, FPD_FST_D(b, disp, v), "fst.d", v)
#define FPD_ST_P(disp)	FPD_ST_CASE(disp, FPD_FST_P(b, disp, v), "fst.p", fpd_swap32(v))

	FPD_ST_D(0)   FPD_ST_P(8)    FPD_ST_D(-8)   FPD_ST_P(-16)
	FPD_ST_D(1024) FPD_ST_P(-1024) FPD_ST_D(4088) FPD_ST_P(-4096)
	FPD_ST_P(0)   FPD_ST_D(8)    FPD_ST_P(4088) FPD_ST_D(-4096)
	FPD_ST_CASE(16, fpd_fstx_d(b, 16, v), "fstx.d", v)
	FPD_ST_CASE(-24, fpd_fstx_d(b, (u64)(s64)-24, v), "fstx.d", v)
	FPD_ST_CASE(4088, fpd_fstx_d(b + 8, 4080, v), "fstx.d", v)
	FPD_ST_CASE(-4096, fpd_fstx_d(b + 4096, (u64)(s64)-8192, v), "fstx.d", v)
	FPD_ST_CASE(32, fpd_fstx_p(b, 32, v), "fstx.p", fpd_swap32(v))
	FPD_ST_CASE(-32, fpd_fstx_p(b, (u64)(s64)-32, v), "fstx.p", fpd_swap32(v))
	FPD_ST_CASE(40, fpd_fstx_p(0, b + 40, v), "fstx.p", fpd_swap32(v))
#undef FPD_ST_CASE
#undef FPD_ST_D
#undef FPD_ST_P
}

/* Sticky flags, cause bits and the FPSCR round trip (Vol. 1 8.3.6, 8.5). */
static void fpd_test_fpscr(void)
{
	static const u32 vals[] = {
		0, FPD_FPSCR_DN, FPD_FPSCR_RM, FPD_FPSCR_FLAG, FPD_FPSCR_CAUSE,
		FPD_FPSCR_DN | FPD_FPSCR_CAUSE | FPD_FPSCR_FLAG | FPD_FPSCR_RM,
	};
	const u64 one = 0x3ff0000000000000ULL, two = 0x4000000000000000ULL;
	const u64 tiny = 0x3c30000000000000ULL;		/* 2^-60 */
	unsigned i;
	u64 r, scr;

	for (i = 0; i < sizeof(vals) / sizeof(vals[0]); i++) {
		fpd_putscr(vals[i]);
		CHECK1("fputscr/fgetscr", fpd_getscr(), vals[i], vals[i]);
	}

	/* a sticky flag survives an exact operation; cause is for this op only */
	fpd_putscr(FPD_FLAG_Z);
	FPD_DYADIC("fadd.d", one, two, r, scr);
	CHECK2("fadd.d 1+2", r, 0x4008000000000000ULL, one, two);
	CHECK2("fadd.d fpscr sticky Z", scr >> 32, FPD_FLAG_Z, one, two);

	/* inexact sets cause and flag; the next exact op clears the cause only */
	fpd_putscr(FPD_FPSCR_DN);
	FPD_DYADIC("fadd.d", one, tiny, r, scr);
	CHECK2("fadd.d 1+2^-60", r, one, one, tiny);
	CHECK2("fadd.d fpscr inexact", scr >> 32, FPD_FPSCR_DN | FPD_CAUSE_I | FPD_FLAG_I, one, tiny);
	FPD_DYADIC("fadd.d", one, one, r, scr);
	CHECK2("fadd.d 1+1", r, two, one, one);
	CHECK2("fadd.d fpscr cause cleared", scr >> 32, FPD_FPSCR_DN | FPD_FLAG_I, one, one);

	/* comparisons and FTRC also clear the cause bits of a previous operation */
	fpd_putscr(0);
	FPD_DYADIC("fdiv.d", one, 0, r, scr);
	FPD_CMP("fcmpeq.d", one, one, r, scr);
	CHECK2("fcmpeq.d after Z", r, 1, one, one);
	CHECK2("fcmpeq.d fpscr after Z", scr >> 32, FPD_FLAG_Z, one, one);
	FPD_DYADIC("fdiv.d", one, 0, r, scr);
	FPD_MONADIC("ftrc.dq dr0, dr2", two, 0, r, scr);
	CHECK2("ftrc.dq after Z", r, 2, two, 0);
	CHECK2("ftrc.dq fpscr after Z", scr >> 32, FPD_FLAG_Z, two, 0);
	fpd_putscr(0);
}

/* Accumulate Z then V through a sequence without clearing (NaN results). */
static void fpd_test_fpscr_nan(void)
{
	const u64 one = 0x3ff0000000000000ULL;
	const u64 inf = 0x7ff0000000000000ULL, ninf = 0xfff0000000000000ULL;
	const u64 qnan = 0x7ff7ffffffffffffULL;
	u64 r, scr;

	fpd_putscr(0);
	FPD_DYADIC("fdiv.d", one, 0, r, scr);
	CHECK2("fdiv.d 1/0", r, inf, one, 0);
	CHECK2("fdiv.d fpscr Z", scr >> 32, FPD_CAUSE_Z | FPD_FLAG_Z, one, 0);
	FPD_DYADIC("fmul.d", 0, inf, r, scr);
	CHECK2("fmul.d 0*inf", r, qnan, 0, inf);
	CHECK2("fmul.d fpscr Z|V", scr >> 32, FPD_V | FPD_FLAG_Z, 0, inf);
	FPD_DYADIC("fadd.d", inf, ninf, r, scr);
	CHECK2("fadd.d inf-inf", r, qnan, inf, ninf);
	CHECK2("fadd.d fpscr Z|V", scr >> 32, FPD_V | FPD_FLAG_Z, inf, ninf);
	FPD_DYADIC("fsub.d", one, one, r, scr);
	CHECK2("fsub.d 1-1", r, 0, one, one);
	CHECK2("fsub.d fpscr flags only", scr >> 32, FPD_FLAG_V | FPD_FLAG_Z, one, one);
	fpd_putscr(0);
}

#define FPD_DYAD(name, vec, op) \
	fpd_test_dyadic(name, name " fpscr", vec, sizeof(vec) / sizeof(vec[0]), op)
#define FPD_MONO(name, vec, op, kind) \
	fpd_test_monadic(name, name " fpscr", vec, sizeof(vec) / sizeof(vec[0]), op, kind)

ISA_GROUP(fpu_d)
{
	u64 a;
	unsigned i, k;

	fpd_test_fpscr();

	FPD_DYAD("fadd.d", fpd_fadd_vec, 0);
	FPD_DYAD("fsub.d", fpd_fsub_vec, 1);
	FPD_DYAD("fmul.d", fpd_fmul_vec, 2);
	FPD_DYAD("fdiv.d", fpd_fdiv_vec, 3);

	fpd_test_cmp();

	FPD_MONO("fsqrt.d", fpd_fsqrt_vec, 0, 0);
	FPD_MONO("fcnv.ds", fpd_fcnv_ds_vec, 1, 1);
	FPD_MONO("fcnv.sd", fpd_fcnv_sd_vec, 2, 3);
	FPD_MONO("ftrc.dl", fpd_ftrc_dl_vec, 3, 2);
	FPD_MONO("ftrc.dq", fpd_ftrc_dq_vec, 4, 0);
	FPD_MONO("float.ld", fpd_float_ld_vec, 5, 3);
	FPD_MONO("float.qd", fpd_float_qd_vec, 6, 0);

	/* bit copies over the integer corpus and every FP operand of the vectors */
	ISA_FOREACH_OPERAND(a)
		fpd_test_moves(a);
	for (i = 0; i < sizeof(fpd_vals) / sizeof(fpd_vals[0]); i++)
		fpd_test_moves(fpd_vals[i]);

	/* loads and stores: three random fills, FP specials and random words */
	isa_rand_seed(0xf9d0f9d0f9d0f9d0ULL);
	for (k = 0; k < 3; k++) {
		fpd_fill_mem();
		fpd_test_loads();
		for (i = 0; i < 32; i++)
			fpd_test_stores(fpd_vals[i]);
		for (i = 0; i < 8; i++)
			fpd_test_stores(isa_rand());
	}

	/*
	 * The cases whose result is a NaN (NaN sources, invalid operations)
	 * come last: an emulator without the SH-5 default NaN pattern dies
	 * here, and this order gets every other check reported first.
	 */
	isa_puts("isa: fpu_d: NaN-producing checks follow\n");
	fpd_test_fpscr_nan();
	FPD_DYAD("fadd.d", fpd_fadd_nan_vec, 0);
	FPD_DYAD("fsub.d", fpd_fsub_nan_vec, 1);
	FPD_DYAD("fmul.d", fpd_fmul_nan_vec, 2);
	FPD_DYAD("fdiv.d", fpd_fdiv_nan_vec, 3);
	FPD_MONO("fsqrt.d", fpd_fsqrt_nan_vec, 0, 0);
	FPD_MONO("fcnv.ds", fpd_fcnv_ds_nan_vec, 1, 1);
	FPD_MONO("fcnv.sd", fpd_fcnv_sd_nan_vec, 2, 3);
}
