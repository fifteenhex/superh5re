/* SHcompact floating point (Vol. 3 chapter 2, Vol. 1 chapters 8 and 13):
 * FADD, FSUB, FMUL, FDIV, FSQRT, FABS, FNEG (single and double), FCMP/EQ,
 * FCMP/GT, FLDI0, FLDI1, FLDS, FSTS, FLOAT, FTRC, FCNVDS, FCNVSD, FMAC,
 * FIPR, FTRV, FSRRA, FSCA, FMOV (register, XD bank and memory forms, SZ = 0
 * and 1), FRCHG, FSCHG, LDS/STS (.L) FPSCR and FPUL.
 *
 * Expected values come from groups/fpu_vectors.h (groups/gen_fpu.py, exact
 * IEEE754 models of the SHmedia kit); no C floating point is used. All
 * arithmetic runs with FPSCR.DN = 1 and ENABLE = 0. Every arithmetic vector
 * checks the result and FPSCR (CAUSE replaced, FLAG sticky). FSRRA, FSCA,
 * FIPR and FTRV results are checked against the error bounds of Vol. 1
 * 8.7.3/8.7.4 (Vol. 3 FSRRA: 2^(E-21), FSCA: 2^-21). */
#include "harness.h"
#include "cops.h"
#include "fpu_vectors.h"

#define N(t)	(sizeof(t) / sizeof((t)[0]))
#define RZ	1u
#define FLAGS	(0x1fu << 2)
#define CAUSE	(0x3fu << 12)
#define DN	(1u << 18)
#define PR	(1u << 19)
#define SZ	(1u << 20)
#define FRB	(1u << 21)
#define FPSCR_DEF 0x003ffffdu	/* defined bits of the SHcompact view */
#define STICKY	(FLAGS | (0x15u << 12))	/* preset FLAG and CAUSE bits */

/*
 * Checks skipped in the SH-4 build, where QEMU's SH-4 FPU deviates from the
 * manual, selected by the X_* operand properties of the vectors:
 *  X_DNRM: with FPSCR.DN = 1 a denormalized source is treated as a signed
 *   zero (Vol. 1 8.4.1, Vol. 3 special cases); QEMU computes with it.
 *  X_TINY: a denormalized result is flushed to zero signaling U and I, and
 *   tininess is detected after rounding (Vol. 1 8.3.6, 8.4.1); QEMU flushes
 *   when tiny before rounding and signals neither.
 *  X_FRAC (FTRC fpscr): FTRC signals only invalid (Vol. 3 FTRC special
 *   cases); QEMU also signals inexact.
 *  X_NAN (FTRC result): a NaN converts to -2^31 (Vol. 3 FTRC table); QEMU
 *   returns 0x7FFFFFFF.
 *  X_QNAN (FCMP/EQ fpscr): invalid only for a signaling NaN (Vol. 3 FCMP/EQ);
 *   QEMU also signals it for a quiet NaN.
 *  FIPR, FTRV: QEMU rounds each product and partial sum to single precision,
 *   which exceeds the bound of Vol. 1 8.7.3 (X_APPROX without X_EXACT), and
 *   signals inexact only when a rounding occurred, while Vol. 3 signals it in
 *   every FIPRADD case (X_EXACT).
 *  SZ = 1 memory pairs: QEMU's little-endian SH-4 moves FRn to address + 4;
 *   Vol. 1 3.7 maps the lower-numbered register to the lower address in both
 *   endiannesses. Data checks skipped, register updates checked.
 *  FSRRA and FSCA trap on QEMU's SH-4 (see test_single).
 */
#ifdef ISA_SH4
#define SH4_SKIP(c)	(c)
#else
#define SH4_SKIP(c)	(0 && (c))
#endif
#define SKIP_ARITH	(X_DNRM | X_TINY)
#define PAIR_DATA	(!SH4_SKIP(1))

static u32 fps_after(u32 in, u32 fl)
{
	return (in & ~CAUSE) | (fl << 12) | (fl << 2);
}

static s32 fkey(u32 b)
{
	s32 m = (s32)(b & 0x7fffffffu);

	return (b >> 31) ? -m : m;
}

static int is_nan(u32 b)
{
	return (b & 0x7f800000u) == 0x7f800000u && (b & 0x7fffffu);
}

/* lo == hi: exact; else lo <= got <= hi in value order, got not a NaN */
static int in_range(u32 got, u32 lo, u32 hi)
{
	if (lo == hi)
		return got == lo;
	return !is_nan(got) && fkey(got) >= fkey(lo) && fkey(got) <= fkey(hi);
}

/* single-precision vectors: R0 = result, R1 = FPSCR; fr: FPSCR.FR = 1 */
static void run_fv(const char *name, const char *fname, const u16 *fn, const struct fv *v, unsigned n,
		   int fmac, u32 skip_val, u32 skip_fps, u32 fr)
{
	for (unsigned i = 0; i < n; i++, v++) {
		u32 f = v->fps_in | fr;
		struct cres r;

		if (fmac)
			r = cop(fn, v->a, v->b, v->c, f);
		else
			r = cop(fn, v->a, v->b, f, 0);
		if (!SH4_SKIP(v->x & skip_val))
			CHECK3(name, r.r0, RES32(v->want), v->a, v->b, fmac ? v->c : f);
		if (!SH4_SKIP(v->x & skip_fps))
			CHECK3(fname, r.r1, RES32(v->fps_want | fr), v->a, v->b, fmac ? v->c : f);
	}
}

static u64 dw(u32 hi, u32 lo)
{
	return ((u64)hi << 32) | lo;
}

/* double-precision vectors: R0/R2 = DR2 (or R0 = FPUL), R1 = FPSCR */
static void run_fd(const char *name, const char *fname, const u16 *fn, const struct fd *v, unsigned n,
		   int fpul, u32 skip_val, u32 skip_fps)
{
	for (unsigned i = 0; i < n; i++, v++) {
		struct cres r = cop(fn, ADDR(v), 0, 0, 0);
		u64 a = dw(v->n_hi, v->n_lo), b = dw(v->m_hi, v->m_lo);

		if (!SH4_SKIP(v->x & skip_val)) {
			if (fpul)
				CHECK3(name, r.r0, RES32(v->w_hi), a, b, v->fps_in);
			else
				CHECK3(name, dw((u32)r.r0, (u32)r.r2), dw(v->w_hi, v->w_lo), a, b, v->fps_in);
		}
		if (!SH4_SKIP(v->x & skip_fps))
			CHECK3(fname, r.r1, RES32(v->fps_want), a, b, v->fps_in);
	}
}

static void range_chk(const char *name, u32 got, u32 lo, u32 hi, u32 a)
{
	CHECK3(name, in_range(got, lo, hi) ? lo : got, lo, a, lo, hi);
}

static void test_single(void)
{
	struct cres r;

	run_fv("fadd", "fadd fpscr", cop_fadd_s, fadd_s, N(fadd_s), 0, SKIP_ARITH, SKIP_ARITH, 0);
	run_fv("fadd FR=1", "fadd FR=1 fpscr", cop_fadd_s, fadd_s, N(fadd_s), 0, SKIP_ARITH, SKIP_ARITH, FRB);
	run_fv("fadd fr8,fr11", "fadd fr8,fr11 fpscr", cop_fadd_s2, fadd_s, N(fadd_s), 0, SKIP_ARITH, SKIP_ARITH, 0);
	run_fv("fsub", "fsub fpscr", cop_fsub_s, fsub_s, N(fsub_s), 0, SKIP_ARITH, SKIP_ARITH, 0);
	run_fv("fmul", "fmul fpscr", cop_fmul_s, fmul_s, N(fmul_s), 0, SKIP_ARITH, SKIP_ARITH, 0);
	run_fv("fdiv", "fdiv fpscr", cop_fdiv_s, fdiv_s, N(fdiv_s), 0, SKIP_ARITH, SKIP_ARITH, 0);
	run_fv("fsqrt", "fsqrt fpscr", cop_fsqrt_s, fsqrt_s, N(fsqrt_s), 0, SKIP_ARITH, SKIP_ARITH, 0);
	run_fv("ftrc", "ftrc fpscr", cop_ftrc_s, ftrc_s, N(ftrc_s), 0, X_NAN, X_FRAC, 0);
	run_fv("float", "float fpscr", cop_float_s, float_s, N(float_s), 0, 0, 0, 0);
	run_fv("fmac", "fmac fpscr", cop_fmac_s, fmac_s, N(fmac_s), 1, SKIP_ARITH, SKIP_ARITH, 0);

	for (unsigned i = 0; i < N(fcmp_s); i++) {
		const struct fcmp *v = &fcmp_s[i];

		r = cop(cop_fcmp_s, v->a, v->b, v->fps_in, 0);
		if (!SH4_SKIP(v->x & X_DNRM)) {
			CHECK3("fcmp/eq T", r.r0, v->t_eq, v->a, v->b, v->fps_in);
			CHECK3("fcmp/gt fpscr", r.r1, RES32(v->fps_gt), v->a, v->b, v->fps_in);
		}
		if (!SH4_SKIP(v->x & (X_DNRM | X_QNAN)))
			CHECK3("fcmp/eq fpscr", r.r2, RES32(v->fps_eq), v->a, v->b, v->fps_in);
		/* +0 vs -0: the FCMP/GT tables of Vol. 2 and Vol. 3 give
		 * "+0 > -0" = true, contrary to IEEE754 and to the FCMP/EQ
		 * table (+0 == -0); not checked */
		if (!(v->x & X_ZERO) && !SH4_SKIP(v->x & X_DNRM))
			CHECK3("fcmp/gt T", r.r3, v->t_gt, v->a, v->b, v->fps_in);
	}

	/* FABS, FNEG, FMOV, FLDI0/1, FLDS/FSTS, LDS/STS FPUL: bit copies,
	 * FPSCR unchanged (preset FLAG and CAUSE bits stay) */
	for (unsigned i = 0; i < N(fbits); i++) {
		u32 a = fbits[i], f = DN | STICKY;

		r = cop(cop_fabs_s, a, 0, f, 0);
		CHECK1("fabs", r.r0, RES32(a & 0x7fffffffu), a); CHECK1("fabs fpscr", r.r1, RES32(f), a);
		r = cop(cop_fneg_s, a, 0, f, 0);
		CHECK1("fneg", r.r0, RES32(a ^ 0x80000000u), a); CHECK1("fneg fpscr", r.r1, RES32(f), a);
		r = cop(cop_fldi0, a, 0, f, 0);
		CHECK1("fldi0", r.r0, 0, a); CHECK1("fldi0 fpscr", r.r1, RES32(f), a);
		r = cop(cop_fldi1, a, 0, f, 0);
		CHECK1("fldi1", r.r0, RES32(0x3f800000u), a); CHECK1("fldi1 fpscr", r.r1, RES32(f), a);
		for (u32 pr = 0; pr <= PR; pr += PR) {
			r = cop(cop_fmov_s, a, 0, f | pr, 0);
			CHECK2("fmov frm,frn", r.r0, RES32(a), a, pr); CHECK2("fmov frm,frn fpscr", r.r1, RES32(f | pr), a, pr);
			r = cop(cop_flds_fsts, a, ~a, f | pr, 0);
			CHECK2("flds/fsts", r.r0, RES32(a), a, pr); CHECK2("flds/fsts fpscr", r.r1, RES32(f | pr), a, pr);
			r = cop(cop_lds_sts_fpul, a, 0, f | pr, 0);
			CHECK2("lds/sts fpul", r.r0, RES32(a), a, pr); CHECK2("lds/sts fpul fpscr", r.r1, RES32(f | pr), a, pr);
		}
	}

#ifndef ISA_SH4
	/* QEMU's SH-4 raises an illegal instruction exception after FSRRA
	 * (target/sh4/translate.c: "break" instead of "return") and does not
	 * decode FSCA; both are SH-5 only here */
	for (unsigned i = 0; i < N(fsrra_s); i++) {
		const struct fr *v = &fsrra_s[i];

		r = cop(cop_fsrra_s, v->a, 0, v->fps_in, 0);
		range_chk("fsrra", (u32)r.r0, v->lo, v->hi, v->a);
		CHECK2("fsrra fpscr", r.r1, RES32(v->fps_want), v->a, v->fps_in);
	}
	for (unsigned i = 0; i < N(fsca_s); i++) {
		const struct fr *v = &fsca_s[i];

		r = cop(cop_fsca, v->a, 0, v->fps_in, 0);
		range_chk("fsca sin", (u32)r.r0, v->lo, v->hi, v->a);
		range_chk("fsca cos", (u32)r.r2, v->lo2, v->hi2, v->a);
		CHECK2("fsca fpscr", r.r1, RES32(v->fps_want), v->a, v->fps_in);
	}
#endif

	for (unsigned i = 0; i < N(fipr_s); i++) {
		const struct fipr *v = &fipr_s[i];

		int sv = SH4_SKIP((v->x & X_DNRM) || (v->x & (X_APPROX | X_EXACT)) == X_APPROX);
		int sf = SH4_SKIP(v->x & (X_DNRM | X_EXACT));

		r = cop(cop_fipr, ADDR(v->v), v->fps_in, 0, 0);
		if (!sv)
			range_chk("fipr fv0,fv4", (u32)r.r0, v->lo, v->hi, i);
		CHECK1("fipr fv0,fv4 fr4", r.r2, RES32(v->v[4]), i);
		if (!sf)
			CHECK2("fipr fv0,fv4 fpscr", r.r1, RES32(v->fps_want), i, v->fps_in);
		r = cop(cop_fipr2, ADDR(v->v), v->fps_in, 0, 0);
		if (!sv)
			range_chk("fipr fv8,fv0", (u32)r.r0, v->lo, v->hi, i);
		CHECK1("fipr fv8,fv0 fr0", r.r2, RES32(v->v[4]), i);
	}
	for (unsigned i = 0; i < N(ftrv_s); i++) {
		static u32 out[4] __attribute__((aligned(8)));
		const struct ftrv *v = &ftrv_s[i];
		int sf = 0, approx = 0;

		r = cop(cop_ftrv, ADDR(v->m), ADDR(out), v->fps_in, 0);
		for (unsigned k = 0; k < 4; k++) {
			u32 x = (v->x >> (8 * k)) & 0xff;

			if (x & X_DNRM)
				sf = 1;
			if ((x & (X_APPROX | X_EXACT)) == X_APPROX)
				approx = 1;
			if (!SH4_SKIP((x & X_DNRM) || (x & (X_APPROX | X_EXACT)) == X_APPROX))
				range_chk("ftrv", ((volatile u32 *)out)[k], v->lo[k], v->hi[k], (k << 16) | i);
		}
		/* inexact from QEMU only if some element needed a rounding */
		if (!SH4_SKIP(sf || ((v->x & 0x20202020u) && !approx)))
			CHECK2("ftrv fpscr", r.r1, RES32(v->fps_want), i, v->fps_in);
	}
}

static void test_double(void)
{
	run_fd("fadd dr", "fadd dr fpscr", cop_fadd_d, fadd_d, N(fadd_d), 0, SKIP_ARITH, SKIP_ARITH);
	run_fd("fsub dr", "fsub dr fpscr", cop_fsub_d, fsub_d, N(fsub_d), 0, SKIP_ARITH, SKIP_ARITH);
	run_fd("fmul dr", "fmul dr fpscr", cop_fmul_d, fmul_d, N(fmul_d), 0, SKIP_ARITH, SKIP_ARITH);
	run_fd("fdiv dr", "fdiv dr fpscr", cop_fdiv_d, fdiv_d, N(fdiv_d), 0, SKIP_ARITH, SKIP_ARITH);
	run_fd("fsqrt dr", "fsqrt dr fpscr", cop_fsqrt_d, fsqrt_d, N(fsqrt_d), 0, SKIP_ARITH, SKIP_ARITH);
	run_fd("fcnvds", "fcnvds fpscr", cop_fcnvds_d, fcnvds_d, N(fcnvds_d), 1, SKIP_ARITH, SKIP_ARITH);
	run_fd("fcnvsd", "fcnvsd fpscr", cop_fcnvsd_d, fcnvsd_d, N(fcnvsd_d), 0, SKIP_ARITH, SKIP_ARITH);
	run_fd("ftrc dr", "ftrc dr fpscr", cop_ftrc_d, ftrc_d, N(ftrc_d), 1, X_NAN, X_FRAC);
	run_fd("float dr", "float dr fpscr", cop_float_d, float_d, N(float_d), 0, 0, 0);

	for (unsigned i = 0; i < N(fcmp_d); i++) {
		const struct fd *v = &fcmp_d[i];
		struct cres r = cop(cop_fcmp_d, ADDR(v), 0, 0, 0);
		u64 a = dw(v->n_hi, v->n_lo), b = dw(v->m_hi, v->m_lo);

		if (SH4_SKIP(v->x & X_DNRM))
			continue;
		CHECK3("fcmp/eq dr T", r.r0, v->w_hi, a, b, v->fps_in);
		if (!SH4_SKIP(v->x & X_QNAN))
			CHECK3("fcmp/eq dr fpscr", r.r2, RES32(v->fps_want), a, b, v->fps_in);
		CHECK3("fcmp/gt dr fpscr", r.r1, RES32(fps_after(v->fps_in, (v->x & X_GTV) ? 16 : 0)), a, b, v->fps_in);
		if (!(v->x & X_ZERO))	/* +0 vs -0: see fcmp/gt above */
			CHECK3("fcmp/gt dr T", r.r3, v->w_lo, a, b, v->fps_in);
	}
	/* FADD DRm, DRn with FPSCR.FR = 1 */
	for (unsigned i = 0; i < N(fadd_d); i++) {
		static struct fd w __attribute__((aligned(8)));
		u64 a, b;
		struct cres r;

		w = fadd_d[i];
		w.fps_in |= FRB;
		a = dw(w.n_hi, w.n_lo); b = dw(w.m_hi, w.m_lo);
		r = cop(cop_fadd_d, ADDR(&w), 0, 0, 0);
		if (!SH4_SKIP(w.x & SKIP_ARITH)) {
			CHECK3("fadd dr FR=1", dw((u32)r.r0, (u32)r.r2), dw(w.w_hi, w.w_lo), a, b, w.fps_in);
			CHECK3("fadd dr FR=1 fpscr", r.r1, RES32(w.fps_want | FRB), a, b, w.fps_in);
		}
	}
	/* FABS DRn, FNEG DRn: sign bit only, FPSCR unchanged */
	for (unsigned i = 0; i < N(fadd_d); i++) {
		const struct fd *v = &fadd_d[i];
		u64 a = dw(v->n_hi, v->n_lo);
		struct cres r = cop(cop_fabs_d, ADDR(v), 0, 0, 0);

		CHECK2("fabs dr", dw((u32)r.r0, (u32)r.r2), dw(v->n_hi & 0x7fffffffu, v->n_lo), a, v->fps_in);
		CHECK2("fabs dr fpscr", r.r1, RES32(v->fps_in), a, v->fps_in);
		r = cop(cop_fneg_d, ADDR(v), 0, 0, 0);
		CHECK2("fneg dr", dw((u32)r.r0, (u32)r.r2), dw(v->n_hi ^ 0x80000000u, v->n_lo), a, v->fps_in);
		CHECK2("fneg dr fpscr", r.r1, RES32(v->fps_in), a, v->fps_in);
	}
}

static void test_fmov(void)
{
	static u32 buf[8] __attribute__((aligned(8)));
	static u32 val[2] __attribute__((aligned(8)));
	volatile u32 *vb = buf;
	const u32 mark = 0x5a5aa5a5u, guard = 0xdeadbeefu;
	struct cres r;

	for (unsigned i = 0; i < N(fbits); i++) {
		u32 a = fbits[i], b = fbits[(i * 7 + 3) % N(fbits)];
		u32 f0 = DN | (i & 1 ? STICKY : 0), f1 = f0 | SZ;
		u32 base = ADDR(&buf[4]);

		/* SZ = 1 register pairs: R0/R2 = DR10 or XD10, R3 = front FR10 */
		r = cop(cop_fmov_dd, a, b, f1, mark);
		CHECK2("fmov drm,drn", dw((u32)r.r0, (u32)r.r2), dw(a, b), a, b);
		CHECK2("fmov drm,drn fpscr", r.r1, RES32(f1), a, b);
		r = cop(cop_fmov_dx, a, b, f1, mark);
		CHECK2("fmov drm,xdn", dw((u32)r.r0, (u32)r.r2), dw(a, b), a, b);
		CHECK2("fmov drm,xdn front", r.r3, RES32(mark), a, b);
		CHECK2("frchg fpscr", r.r1, RES32(f1 ^ FRB), a, b);
		r = cop(cop_fmov_xd, a, b, f1, mark);
		CHECK2("fmov xdm,drn", dw((u32)r.r0, (u32)r.r2), dw(a, b), a, b);
		CHECK2("fmov xdm,drn fpscr", r.r1, RES32(f1), a, b);
		r = cop(cop_fmov_xx, a, b, f1, mark);
		CHECK2("fmov xdm,xdn", dw((u32)r.r0, (u32)r.r2), dw(a, b), a, b);
		CHECK2("fmov xdm,xdn front", r.r3, RES32(mark), a, b);
		CHECK2("fmov xdm,xdn fpscr", r.r1, RES32(f1), a, b);

		/* SZ = 0 memory forms (PR = 0 and 1) */
		for (u32 pr = 0; pr <= PR; pr += PR) {
			u32 f = f0 | pr;

			for (unsigned k = 0; k < 8; k++) vb[k] = guard + k;
			vb[2] = a;
			r = cop(cop_fmovs_ld, ADDR(&buf[2]), 0, f, 0);
			CHECK2("fmov.s @rm,frn", r.r0, RES32(a), a, pr);
			CHECK2("fmov.s @rm,frn fpscr", r.r1, RES32(f), a, pr);
			r = cop(cop_fmovs_ldp, ADDR(&buf[2]), 0, f, 0);
			CHECK2("fmov.s @rm+,frn", r.r0, RES32(a), a, pr);
			CHECK2("fmov.s @rm+,frn rm", r.r2, RES32(ADDR(&buf[2]) + 4), a, pr);
			for (s32 x = -8; x <= 8; x += 4) {
				vb[4 + x / 4] = a ^ (u32)x;
				r = cop(cop_fmovs_ldx, base, (u32)x, f, 0);
				CHECK3("fmov.s @(r0,rm),frn", r.r0, RES32(a ^ (u32)x), a, pr, (u32)x);
			}
			for (unsigned k = 0; k < 8; k++) vb[k] = guard + k;
			r = cop(cop_fmovs_st, ADDR(&buf[3]), a, f, 0);
			CHECK2("fmov.s frm,@rn", vb[3], a, a, pr);
			CHECK2("fmov.s frm,@rn guard", dw(vb[2], vb[4]), dw(guard + 2, guard + 4), a, pr);
			CHECK2("fmov.s frm,@rn fpscr", r.r1, RES32(f), a, pr);
			r = cop(cop_fmovs_stm, base, b, f, 0);
			CHECK2("fmov.s frm,@-rn", vb[3], b, b, pr);
			CHECK2("fmov.s frm,@-rn rn", r.r2, RES32(base - 4), b, pr);
			CHECK2("fmov.s frm,@-rn guard", vb[4], guard + 4, b, pr);
			for (s32 x = -8; x <= 8; x += 4) {
				r = cop(cop_fmovs_stx, base, a ^ (u32)x, f, (u32)x);
				CHECK3("fmov.s frm,@(r0,rn)", vb[4 + x / 4], a ^ (u32)x, a, pr, (u32)x);
			}
		}

		/* SZ = 1 memory forms, DR (cop_fmovd_*) and XD (cop_fmovx_*) */
		{
			static const u16 *const ld[2][3] = {
				{ cop_fmovd_ld, cop_fmovd_ldp, cop_fmovd_ldx },
				{ cop_fmovx_ld, cop_fmovx_ldp, cop_fmovx_ldx } };
			static const u16 *const st[2][3] = {
				{ cop_fmovd_st, cop_fmovd_stm, cop_fmovd_stx },
				{ cop_fmovx_st, cop_fmovx_stm, cop_fmovx_stx } };
			static const char *const nm[2][6] = {
				{ "fmov @rm,drn", "fmov @rm+,drn", "fmov @(r0,rm),drn",
				  "fmov drm,@rn", "fmov drm,@-rn", "fmov drm,@(r0,rn)" },
				{ "fmov @rm,xdn", "fmov @rm+,xdn", "fmov @(r0,rm),xdn",
				  "fmov xdm,@rn", "fmov xdm,@-rn", "fmov xdm,@(r0,rn)" } };

			for (unsigned k = 0; k < 2; k++) {
				for (unsigned j = 0; j < 8; j++) vb[j] = guard + j;
				vb[2] = a; vb[3] = b;
				r = cop(ld[k][0], ADDR(&buf[2]), 0, f1, 0);
				if (PAIR_DATA)
					CHECK2(nm[k][0], dw((u32)r.r0, (u32)r.r2), dw(a, b), a, b);
				CHECK2(nm[k][0], r.r1, RES32(f1), a, b);
				r = cop(ld[k][1], ADDR(&buf[2]), 0, f1, 0);
				if (PAIR_DATA)
					CHECK2(nm[k][1], dw((u32)r.r0, (u32)r.r2), dw(a, b), a, b);
				CHECK2(nm[k][1], r.r3, RES32(ADDR(&buf[2]) + 8), a, b);
				for (s32 x = -8; x <= 8; x += 8) {
					vb[4 + x / 4] = a ^ (u32)x; vb[5 + x / 4] = b;
					r = cop(ld[k][2], base, (u32)x, f1, 0);
					if (PAIR_DATA)
						CHECK3(nm[k][2], dw((u32)r.r0, (u32)r.r2), dw(a ^ (u32)x, b), a, b, (u32)x);
				}
				for (unsigned j = 0; j < 8; j++) vb[j] = guard + j;
				r = cop(st[k][0], ADDR(&buf[2]), a, f1, b);
				if (PAIR_DATA)
					CHECK2(nm[k][3], dw(vb[2], vb[3]), dw(a, b), a, b);
				CHECK2(nm[k][3], dw(vb[1], vb[4]), dw(guard + 1, guard + 4), a, b);
				CHECK2(nm[k][3], r.r1, RES32(f1), a, b);
				r = cop(st[k][1], base, b, f1, a);
				if (PAIR_DATA)
					CHECK2(nm[k][4], dw(vb[2], vb[3]), dw(b, a), a, b);
				CHECK2(nm[k][4], r.r2, RES32(base - 8), a, b);
				for (s32 x = -8; x <= 8; x += 8) {
					val[0] = a ^ (u32)x; val[1] = b;
					r = cop(st[k][2], base, (u32)x, f1, ADDR(val));
					if (PAIR_DATA)
						CHECK3(nm[k][5], dw(vb[4 + x / 4], vb[5 + x / 4]), dw(a ^ (u32)x, b), a, b, (u32)x);
				}
			}
		}
	}
}

static void test_fpscr(void)
{
	static u32 m[2] __attribute__((aligned(8)));
	volatile u32 *vm = m;
	static const u32 vals[] = {
		0, DN, DN | RZ, DN | FLAGS, DN | CAUSE, DN | (0x1fu << 7), DN | PR, DN | SZ, DN | FRB,
		DN | SZ | FRB, DN | PR | FRB, FPSCR_DEF & ~SZ, FPSCR_DEF & ~PR, 0x00055555u & FPSCR_DEF,
		0x002aaaa9u & FPSCR_DEF & ~SZ, 0x00000001u, 0x00001004u, 0x0002007cu,
	};
	struct cres r;

	for (unsigned i = 0; i < N(vals); i++) {
		u32 v = vals[i];

		r = cop(cop_lds_sts_fpscr, v, 0, 0, 0);
		CHECK1("lds/sts fpscr", r.r0 & FPSCR_DEF, v, v);
		vm[0] = v;
		r = cop(cop_ldsl_fpscr, ADDR(&m[0]), 0, 0, 0);
		CHECK1("lds.l @rm+,fpscr", r.r0 & FPSCR_DEF, v, v);
		CHECK1("lds.l @rm+,fpscr rm", r.r2, RES32(ADDR(&m[0]) + 4), v);
		vm[0] = 0;
		r = cop(cop_stsl_fpscr, ADDR(&m[1]), v, 0, 0);
		CHECK1("sts.l fpscr,@-rn", vm[0] & FPSCR_DEF, v, v);
		CHECK1("sts.l fpscr,@-rn rn", r.r2, RES32(ADDR(&m[0])), v);
		/* FRCHG, FSCHG (PR = 0) */
		if (!(v & PR)) {
			v &= ~(0x1fu << 7);	/* no enables with FP instructions */
			r = cop(cop_frchg_fschg, v, 0, 0, 0);
			CHECK1("frchg", r.r0 & FPSCR_DEF, v ^ FRB, v);
			CHECK1("fschg", r.r2 & FPSCR_DEF, v ^ FRB ^ SZ, v);
		}
	}
	for (unsigned i = 0; i < N(fbits); i++) {
		u32 a = fbits[i], f = DN | STICKY;

		vm[0] = a;
		r = cop(cop_ldsl_fpul, ADDR(&m[0]), 0, f, 0);
		CHECK1("lds.l @rm+,fpul", r.r0, RES32(a), a);
		CHECK1("lds.l @rm+,fpul rm", r.r2, RES32(ADDR(&m[0]) + 4), a);
		CHECK1("lds.l @rm+,fpul fpscr", r.r1, RES32(f), a);
		vm[0] = ~a;
		r = cop(cop_stsl_fpul, ADDR(&m[1]), a, f, 0);
		CHECK1("sts.l fpul,@-rn", vm[0], a, a);
		CHECK1("sts.l fpul,@-rn rn", r.r2, RES32(ADDR(&m[0])), a);
		CHECK1("sts.l fpul,@-rn fpscr", r.r1, RES32(f), a);
	}
}

ISA_GROUP(fpu)
{
	test_fpscr();
	test_fmov();
	test_single();
	test_double();
}
