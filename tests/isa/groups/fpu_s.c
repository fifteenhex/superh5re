/*
 * Single-precision FPU (Vol. 2 ch. 2, Vol. 1 ch. 8): FADD.S, FSUB.S, FMUL.S,
 * FDIV.S, FABS.S, FNEG.S, FCMPEQ.S, FCMPGT.S, FCMPGE.S, FCMPUN.S, FMOV.S,
 * FMOV.LS, FMOV.SL, FLD.S, FST.S, FLDX.S, FSTX.S, FLOAT.LS, FLOAT.QS,
 * FTRC.SL, FTRC.SQ, FMAC.S, FIPR.S, FTRV.S, FSQRT.S, FSRRA.S, FSINA.S,
 * FCOSA.S, FGETSCR, FPUTSCR.
 *
 * The program is compiled with -m5-32media, so C float arithmetic here would
 * use the instructions under test.  All expected values therefore come from
 * groups/fpu_s_vectors.h, generated on the host by tools/gen_fpu_s.py with
 * exact rational arithmetic, IEEE754 single rounding and the manual's special
 * case tables.  Every vector carries the FPSCR written before the instruction
 * and the FPSCR expected after it (CAUSE replaced, FLAG accumulated, RM and
 * DN unchanged), so the exception flags are checked along with the result.
 *
 * Each vector produces two checks: "<insn>" compares the result bits and
 * "<insn> fpscr" compares FPSCR (reserved bits masked).  The operands are
 * printed on failure; for FIPR.S/FTRV.S, which have 8 or 20 inputs, 'a' is
 * the index of the vector in the generated table (for FTRV.S the result
 * element number is in bits 32..35).
 *
 * The vectors whose expected result is a NaN run last (pass 1), after every
 * other check of the group: an emulator that cannot generate the canonical
 * quiet NaN is then still exercised on everything else first, and the
 * "isa: fpu_s: N checks before the NaN-result vectors" line records how far
 * it got.  Every vector is checked.
 *
 * Binutils 2.30 does not know FSINA.S, FCOSA.S and FSRRA.S; those are
 * emitted as .long with the encodings of Vol. 2 (000110 g ext g f 0000,
 * ext = 1000, 1100, 1010).
 */
#include "harness.h"
#include "fpu_s_vectors.h"

#define N(t) (sizeof(t) / sizeof((t)[0]))
#define FPS(x) ((u32)(x) & FPU_S_FPSCR_MASK)

/*
 * Inline asm building blocks.  Floating-point registers are allocated by
 * the compiler through the "f" constraint on dummy float/double variables;
 * every block starts with FPUTSCR of the vector's FPSCR and ends with
 * FGETSCR so that CAUSE and FLAG are observed for exactly one instruction.
 */
#define FPS_IN	"fmov.ls %[fi], %[fs]\n\tfputscr %[fs]\n\t"
#define FPS_OUT	"fgetscr %[fs]\n\tfmov.sl %[fs], %[f]"

/* FRg, FRh -> FRf */
#define DEF_FOP2(name, insn)						\
static u32 name(u32 a, u32 b, u32 fps_in, u32 *fps_out)			\
{									\
	u64 r, f; float fa, fb, fr, fs;					\
	__asm__ volatile(FPS_IN						\
		"fmov.ls %[a], %[fa]\n\tfmov.ls %[b], %[fb]\n\t"	\
		insn " %[fa], %[fb], %[fr]\n\t"				\
		"fmov.sl %[fr], %[r]\n\t" FPS_OUT			\
		: [r]"=&r"(r), [f]"=&r"(f), [fa]"=&f"(fa), [fb]"=&f"(fb), \
		  [fr]"=&f"(fr), [fs]"=&f"(fs)				\
		: [a]"r"(a), [b]"r"(b), [fi]"r"(fps_in));		\
	*fps_out = (u32)f;						\
	return (u32)r;							\
}

/* FRg, FRh -> Rd (compares) */
#define DEF_FCMP(name, insn)						\
static u64 name(u32 a, u32 b, u32 fps_in, u32 *fps_out)			\
{									\
	u64 r, f; float fa, fb, fs;					\
	__asm__ volatile(FPS_IN						\
		"fmov.ls %[a], %[fa]\n\tfmov.ls %[b], %[fb]\n\t"	\
		insn " %[fa], %[fb], %[r]\n\t" FPS_OUT			\
		: [r]"=&r"(r), [f]"=&r"(f), [fa]"=&f"(fa), [fb]"=&f"(fb), \
		  [fs]"=&f"(fs)						\
		: [a]"r"(a), [b]"r"(b), [fi]"r"(fps_in));		\
	*fps_out = (u32)f;						\
	return r;							\
}

/* FRg -> FRf */
#define DEF_FOP1(name, insn)						\
static u32 name(u32 a, u32 fps_in, u32 *fps_out)			\
{									\
	u64 r, f; float fa, fr, fs;					\
	__asm__ volatile(FPS_IN						\
		"fmov.ls %[a], %[fa]\n\t"				\
		insn " %[fa], %[fr]\n\t"				\
		"fmov.sl %[fr], %[r]\n\t" FPS_OUT			\
		: [r]"=&r"(r), [f]"=&r"(f), [fa]"=&f"(fa), [fr]"=&f"(fr), \
		  [fs]"=&f"(fs)						\
		: [a]"r"(a), [fi]"r"(fps_in));				\
	*fps_out = (u32)f;						\
	return (u32)r;							\
}

/* FRg -> FRf through a .long encoding (fr32 source, fr33 destination) */
#define DEF_FOP1_RAW(name, ext)						\
static u32 name(u32 a, u32 fps_in, u32 *fps_out)			\
{									\
	u64 r, f; float fs;						\
	__asm__ volatile(FPS_IN						\
		"fmov.ls %[a], fr32\n\t"				\
		".long 0x18000000 | (32 << 20) | (" #ext " << 16) | (32 << 10) | (33 << 4)\n\t" \
		"fmov.sl fr33, %[r]\n\t" FPS_OUT			\
		: [r]"=&r"(r), [f]"=&r"(f), [fs]"=&f"(fs)		\
		: [a]"r"(a), [fi]"r"(fps_in)				\
		: "fr32", "fr33");					\
	*fps_out = (u32)f;						\
	return (u32)r;							\
}

DEF_FOP2(fadd_s, "fadd.s")
DEF_FOP2(fsub_s, "fsub.s")
DEF_FOP2(fmul_s, "fmul.s")
DEF_FOP2(fdiv_s, "fdiv.s")
DEF_FCMP(fcmpeq_s, "fcmpeq.s")
DEF_FCMP(fcmpgt_s, "fcmpgt.s")
DEF_FCMP(fcmpge_s, "fcmpge.s")
DEF_FCMP(fcmpun_s, "fcmpun.s")
DEF_FOP1(fsqrt_s, "fsqrt.s")
DEF_FOP1(fabs_s, "fabs.s")
DEF_FOP1(fneg_s, "fneg.s")
DEF_FOP1(fmov_s, "fmov.s")
DEF_FOP1(ftrc_sl, "ftrc.sl")
DEF_FOP1(float_ls, "float.ls")
DEF_FOP1_RAW(fsina_s, 8)
DEF_FOP1_RAW(fsrra_s, 10)
DEF_FOP1_RAW(fcosa_s, 12)

/* FMAC.S FRg, FRh, FRq: FRq is source and destination */
static u32 fmac_s(u32 a, u32 b, u32 c, u32 fps_in, u32 *fps_out)
{
	u64 r, f; float fa, fb, fc, fs;
	__asm__ volatile(FPS_IN
		"fmov.ls %[a], %[fa]\n\tfmov.ls %[b], %[fb]\n\tfmov.ls %[c], %[fc]\n\t"
		"fmac.s %[fa], %[fb], %[fc]\n\t"
		"fmov.sl %[fc], %[r]\n\t" FPS_OUT
		: [r]"=&r"(r), [f]"=&r"(f), [fa]"=&f"(fa), [fb]"=&f"(fb),
		  [fc]"=&f"(fc), [fs]"=&f"(fs)
		: [a]"r"(a), [b]"r"(b), [c]"r"(c), [fi]"r"(fps_in));
	*fps_out = (u32)f;
	return (u32)r;
}

/* FLOAT.QS DRg, FRf: 64-bit integer source */
static u32 float_qs(u64 a, u32 fps_in, u32 *fps_out)
{
	u64 r, f; double da; float fr, fs;
	__asm__ volatile(FPS_IN
		"fmov.qd %[a], %[da]\n\tfloat.qs %[da], %[fr]\n\t"
		"fmov.sl %[fr], %[r]\n\t" FPS_OUT
		: [r]"=&r"(r), [f]"=&r"(f), [da]"=&f"(da), [fr]"=&f"(fr), [fs]"=&f"(fs)
		: [a]"r"(a), [fi]"r"(fps_in));
	*fps_out = (u32)f;
	return (u32)r;
}

/* FTRC.SQ FRg, DRf: 64-bit integer result */
static u64 ftrc_sq(u32 a, u32 fps_in, u32 *fps_out)
{
	u64 r, f; double dr; float fa, fs;
	__asm__ volatile(FPS_IN
		"fmov.ls %[a], %[fa]\n\tftrc.sq %[fa], %[dr]\n\t"
		"fmov.dq %[dr], %[r]\n\t" FPS_OUT
		: [r]"=&r"(r), [f]"=&r"(f), [dr]"=&f"(dr), [fa]"=&f"(fa), [fs]"=&f"(fs)
		: [a]"r"(a), [fi]"r"(fps_in));
	*fps_out = (u32)f;
	return r;
}

/* FIPR.S FV32, FV36, FR40: v[0..3] = FVg, v[4..7] = FVh */
static u32 fipr_s(const u32 *v, u32 fps_in, u32 *fps_out)
{
	u64 r, f; float fs;
	__asm__ volatile(FPS_IN
		"fld.s %[p], 0, fr32\n\tfld.s %[p], 4, fr33\n\t"
		"fld.s %[p], 8, fr34\n\tfld.s %[p], 12, fr35\n\t"
		"fld.s %[p], 16, fr36\n\tfld.s %[p], 20, fr37\n\t"
		"fld.s %[p], 24, fr38\n\tfld.s %[p], 28, fr39\n\t"
		"fipr.s fv32, fv36, fr40\n\t"
		"fmov.sl fr40, %[r]\n\t" FPS_OUT
		: [r]"=&r"(r), [f]"=&r"(f), [fs]"=&f"(fs)
		: [p]"r"(v), [fi]"r"(fps_in)
		: "fr32", "fr33", "fr34", "fr35", "fr36", "fr37", "fr38", "fr39",
		  "fr40", "memory");
	*fps_out = (u32)f;
	return (u32)r;
}

/* FTRV.S MTRX16, FV32, FV36: m[16] column-major, v[4]; results to out[4] */
static void ftrv_s(const u32 *m, const u32 *v, u32 *out, u32 fps_in, u32 *fps_out)
{
	u64 f; float fs;
	__asm__ volatile(FPS_IN
		"fld.s %[m], 0, fr16\n\tfld.s %[m], 4, fr17\n\tfld.s %[m], 8, fr18\n\tfld.s %[m], 12, fr19\n\t"
		"fld.s %[m], 16, fr20\n\tfld.s %[m], 20, fr21\n\tfld.s %[m], 24, fr22\n\tfld.s %[m], 28, fr23\n\t"
		"fld.s %[m], 32, fr24\n\tfld.s %[m], 36, fr25\n\tfld.s %[m], 40, fr26\n\tfld.s %[m], 44, fr27\n\t"
		"fld.s %[m], 48, fr28\n\tfld.s %[m], 52, fr29\n\tfld.s %[m], 56, fr30\n\tfld.s %[m], 60, fr31\n\t"
		"fld.s %[v], 0, fr32\n\tfld.s %[v], 4, fr33\n\tfld.s %[v], 8, fr34\n\tfld.s %[v], 12, fr35\n\t"
		"ftrv.s mtrx16, fv32, fv36\n\t"
		"fst.s %[o], 0, fr36\n\tfst.s %[o], 4, fr37\n\tfst.s %[o], 8, fr38\n\tfst.s %[o], 12, fr39\n\t"
		FPS_OUT
		: [f]"=&r"(f), [fs]"=&f"(fs)
		: [m]"r"(m), [v]"r"(v), [o]"r"(out), [fi]"r"(fps_in)
		: "fr16", "fr17", "fr18", "fr19", "fr20", "fr21", "fr22", "fr23",
		  "fr24", "fr25", "fr26", "fr27", "fr28", "fr29", "fr30", "fr31",
		  "fr32", "fr33", "fr34", "fr35", "fr36", "fr37", "fr38", "fr39",
		  "memory");
	*fps_out = (u32)f;
}

/* FTRV.S MTRX0, FV16, FV20: the other register group encodings */
static void ftrv_s_mtrx0(const u32 *m, const u32 *v, u32 *out, u32 fps_in, u32 *fps_out)
{
	u64 f; float fs;
	__asm__ volatile(FPS_IN
		"fld.s %[m], 0, fr0\n\tfld.s %[m], 4, fr1\n\tfld.s %[m], 8, fr2\n\tfld.s %[m], 12, fr3\n\t"
		"fld.s %[m], 16, fr4\n\tfld.s %[m], 20, fr5\n\tfld.s %[m], 24, fr6\n\tfld.s %[m], 28, fr7\n\t"
		"fld.s %[m], 32, fr8\n\tfld.s %[m], 36, fr9\n\tfld.s %[m], 40, fr10\n\tfld.s %[m], 44, fr11\n\t"
		"fld.s %[m], 48, fr12\n\tfld.s %[m], 52, fr13\n\tfld.s %[m], 56, fr14\n\tfld.s %[m], 60, fr15\n\t"
		"fld.s %[v], 0, fr16\n\tfld.s %[v], 4, fr17\n\tfld.s %[v], 8, fr18\n\tfld.s %[v], 12, fr19\n\t"
		"ftrv.s mtrx0, fv16, fv20\n\t"
		"fst.s %[o], 0, fr20\n\tfst.s %[o], 4, fr21\n\tfst.s %[o], 8, fr22\n\tfst.s %[o], 12, fr23\n\t"
		FPS_OUT
		: [f]"=&r"(f), [fs]"=&f"(fs)
		: [m]"r"(m), [v]"r"(v), [o]"r"(out), [fi]"r"(fps_in)
		: "fr0", "fr1", "fr2", "fr3", "fr4", "fr5", "fr6", "fr7",
		  "fr8", "fr9", "fr10", "fr11", "fr12", "fr13", "fr14", "fr15",
		  "fr16", "fr17", "fr18", "fr19", "fr20", "fr21", "fr22", "fr23",
		  "memory");
	*fps_out = (u32)f;
}

static u32 fgetscr(void)
{
	u64 r; float fs;
	__asm__ volatile("fgetscr %[fs]\n\tfmov.sl %[fs], %[r]"
			 : [r]"=&r"(r), [fs]"=&f"(fs));
	return (u32)r;
}

static void fputscr(u32 v)
{
	float fs;
	__asm__ volatile("fmov.ls %[v], %[fs]\n\tfputscr %[fs]"
			 : [fs]"=&f"(fs) : [v]"r"(v));
}

/* FMOV.LS Rm, FRf then FMOV.SL FRf, Rd: 64-bit register in and out */
static u64 fmov_ls_sl(u64 a)
{
	u64 r; float fa;
	__asm__ volatile("fmov.ls %[a], %[fa]\n\tfmov.sl %[fa], %[r]"
			 : [r]"=&r"(r), [fa]"=&f"(fa) : [a]"r"(a));
	return r;
}

/*
 * Approximate results (FSINA.S, FCOSA.S, FSRRA.S, FIPR.S, FTRV.S): the
 * vector gives the lowest and highest acceptable single in value order
 * (Vol. 1 8.7: |result - ideal| < spec_error).  lo == hi means an exact
 * special case compared bitwise.  Reported as a=operand/index, b=lo, c=hi;
 * want shows lo on failure.
 */
static s32 fkey(u32 b)
{
	s32 m = b & 0x7fffffff;
	return (b & 0x80000000) ? -m : m;
}

static int check_range(const char *file, int line, const char *insn,
		       u32 got, u32 lo, u32 hi, u64 a)
{
	int ok = (lo == hi) ? got == lo
			    : fkey(got) >= fkey(lo) && fkey(got) <= fkey(hi);
	return isa_check(file, line, insn, got, ok ? got : lo, 3, a, lo, hi);
}
#define CHECKR(insn, got, lo, hi, a) \
	check_range(__FILE__, __LINE__, insn, (got), (lo), (hi), (a))

static int nan_result(u32 w)
{
	return (w & 0x7f800000) == 0x7f800000 && (w & 0x7fffff);
}

/* loop over a table, taking only the vectors of the given NaN pass */
#define FOR_PASS(i, tab, pass, field) \
	for ((i) = 0; (i) < N(tab); (i)++) if (nan_result((tab)[i].field) == (pass))

static u32 ldst_buf[1024] __attribute__((aligned(16)));

static void test_fpscr_access(void)
{
	/* FPUTSCR / FGETSCR: defined bits round-trip (RM, FLAG, ENABLE, CAUSE, DN) */
	static const u32 pat[] = {
		0x00000000, 0x00000001, 0x00040000, 0x00040001, 0x0000007c,
		0x0003f000, 0x00000f80, 0x0007fffd, 0x00020000, 0x00011004,
		0xffffffff, 0x80000002, 0x00055554, 0x0002aaa9,
	};
	unsigned i;

	for (i = 0; i < N(pat); i++) {
		fputscr(pat[i]);
		CHECK1("fputscr/fgetscr", FPS(fgetscr()), FPS(pat[i]), pat[i]);
	}
	fputscr(0);
}

static void test_moves(void)
{
	unsigned i;
	u32 fps;

	/* FMOV.LS / FMOV.SL: bit copy, low 32 bits, sign extended on the way back */
	for (i = 0; i < N(fpu_s_bits); i++) {
		u64 a = fpu_s_bits[i];

		CHECK1("fmov.ls/fmov.sl", fmov_ls_sl(a), (u64)SignExtend32(a), a);
		a |= (u64)fpu_s_bits[(i * 7 + 3) % N(fpu_s_bits)] << 32;
		CHECK1("fmov.ls/fmov.sl", fmov_ls_sl(a), (u64)SignExtend32(a), a);
	}

	/* FABS.S, FNEG.S, FMOV.S: not arithmetic, FPSCR untouched (also for NaNs) */
	for (i = 0; i < N(fpu_s_bits); i++) {
		u32 a = fpu_s_bits[i];
		u32 in = (i & 1) ? 0x0007fffd : 0x00040000;

		CHECK1("fabs.s", fabs_s(a, in, &fps), a & 0x7fffffff, a);
		CHECK1("fabs.s fpscr", FPS(fps), FPS(in), a);
		CHECK1("fneg.s", fneg_s(a, in, &fps), a ^ 0x80000000, a);
		CHECK1("fneg.s fpscr", FPS(fps), FPS(in), a);
		CHECK1("fmov.s", fmov_s(a, in, &fps), a, a);
		CHECK1("fmov.s fpscr", FPS(fps), FPS(in), a);
	}
	fputscr(0);
}

static void test_loadstore(void)
{
	/* FLD.S / FST.S (displacement = s*4, s in [-512, 511]) and FLDX.S / FSTX.S */
	u32 *base = &ldst_buf[512];
	unsigned i;
	u64 w, f;

	for (i = 0; i < N(ldst_buf); i++)
		ldst_buf[i] = fpu_s_bits[(i * 13) % N(fpu_s_bits)] ^ (i << 24);

#define CHK_FLD(disp)							\
	do {								\
		float fr;						\
		__asm__ volatile("fld.s %[b], " #disp ", %[fr]\n\tfmov.sl %[fr], %[w]" \
			: [w]"=&r"(w), [fr]"=&f"(fr) : [b]"r"(base) : "memory"); \
		CHECK2("fld.s " #disp, w, (u64)SignExtend32(base[(disp) / 4]), \
		       (u64)(disp), base[(disp) / 4]);			\
	} while (0)
	CHK_FLD(0); CHK_FLD(4); CHK_FLD(-4); CHK_FLD(8); CHK_FLD(2044);
	CHK_FLD(-2048); CHK_FLD(1024); CHK_FLD(-1028); CHK_FLD(508); CHK_FLD(-512);
#undef CHK_FLD

#define CHK_FST(disp, val)						\
	do {								\
		float fr;						\
		u32 v = (val), save_lo = base[(disp) / 4 - 1], save_hi = base[(disp) / 4 + 1]; \
		__asm__ volatile("fmov.ls %[v], %[fr]\n\tfst.s %[b], " #disp ", %[fr]" \
			: [fr]"=&f"(fr) : [b]"r"(base), [v]"r"(v) : "memory"); \
		CHECK2("fst.s " #disp, base[(disp) / 4], v, (u64)(disp), v); \
		CHECK2("fst.s " #disp " neighbours",			\
		       ((u64)base[(disp) / 4 - 1] << 32) | base[(disp) / 4 + 1], \
		       ((u64)save_lo << 32) | save_hi, (u64)(disp), v);	\
	} while (0)
	CHK_FST(0, 0x3f800000); CHK_FST(4, 0x7fbfffff); CHK_FST(-4, 0x80000000);
	CHK_FST(2040, 0xdeadbeef); CHK_FST(-2044, 0x00000001); CHK_FST(1020, 0xffffffff);
	CHK_FST(-1024, 0x7f800000); CHK_FST(512, 0x00800000);
#undef CHK_FST

	for (i = 0; i < 64; i++) {
		s64 idx = ((s64)(isa_rand() % 1000) - 500) * 4;	/* [-2000, 1996] */
		u32 *p = (u32 *)((char *)base + idx);
		u32 v = fpu_s_bits[i % N(fpu_s_bits)] ^ (u32)isa_rand();
		float fr;

		__asm__ volatile("fldx.s %[b], %[x], %[fr]\n\tfmov.sl %[fr], %[w]"
			: [w]"=&r"(w), [fr]"=&f"(fr) : [b]"r"(base), [x]"r"((u64)idx) : "memory");
		CHECK2("fldx.s", w, (u64)SignExtend32(*p), (u64)idx, *p);
		__asm__ volatile("fmov.ls %[v], %[fr]\n\tfstx.s %[b], %[x], %[fr]"
			: [fr]"=&f"(fr) : [b]"r"(base), [x]"r"((u64)idx), [v]"r"(v) : "memory");
		CHECK2("fstx.s", *p, v, (u64)idx, v);
	}
	/* loads and stores are not arithmetic: FPSCR unchanged */
	fputscr(0x0007fffd);
	__asm__ volatile("fld.s %[b], 0, fr32\n\tfst.s %[b], 4, fr32\n\t"
			 "fldx.s %[b], r63, fr33\n\tfstx.s %[b], r63, fr33\n\t"
			 "fgetscr fr32\n\tfmov.sl fr32, %[f]"
			 : [f]"=&r"(f) : [b]"r"(base) : "fr32", "fr33", "memory");
	CHECK0("fld.s/fst.s fpscr", FPS(f), 0x0007fffd);
	fputscr(0);
}

static void test_compares(void)
{
	/* comparisons: Rd is 0 or 1; NaN handling and V per Vol. 2 pp. 75-84 */
	unsigned i;
	u32 fps;

	for (i = 0; i < N(fpu_s_fcmpeq); i++) {
		const struct fpu_s_v2 *v;

		v = &fpu_s_fcmpeq[i];
		CHECK3("fcmpeq.s", fcmpeq_s(v->a, v->b, v->fps_in, &fps), v->want, v->a, v->b, v->fps_in);
		CHECK3("fcmpeq.s fpscr", FPS(fps), v->fps_want, v->a, v->b, v->fps_in);
		v = &fpu_s_fcmpgt[i];
		CHECK3("fcmpgt.s", fcmpgt_s(v->a, v->b, v->fps_in, &fps), v->want, v->a, v->b, v->fps_in);
		CHECK3("fcmpgt.s fpscr", FPS(fps), v->fps_want, v->a, v->b, v->fps_in);
		v = &fpu_s_fcmpge[i];
		CHECK3("fcmpge.s", fcmpge_s(v->a, v->b, v->fps_in, &fps), v->want, v->a, v->b, v->fps_in);
		CHECK3("fcmpge.s fpscr", FPS(fps), v->fps_want, v->a, v->b, v->fps_in);
		v = &fpu_s_fcmpun[i];
		CHECK3("fcmpun.s", fcmpun_s(v->a, v->b, v->fps_in, &fps), v->want, v->a, v->b, v->fps_in);
		CHECK3("fcmpun.s fpscr", FPS(fps), v->fps_want, v->a, v->b, v->fps_in);
	}
}

static void test_conversions(void)
{
	unsigned i;
	u32 fps;

	for (i = 0; i < N(fpu_s_ftrcsl); i++) {
		const struct fpu_s_vq *v = &fpu_s_ftrcsl[i];

		CHECK2("ftrc.sl", ftrc_sl((u32)v->a, v->fps_in, &fps), (u32)v->want, v->a, v->fps_in);
		CHECK2("ftrc.sl fpscr", FPS(fps), v->fps_want, v->a, v->fps_in);
	}
	for (i = 0; i < N(fpu_s_ftrcsq); i++) {
		const struct fpu_s_vq *v = &fpu_s_ftrcsq[i];

		CHECK2("ftrc.sq", ftrc_sq((u32)v->a, v->fps_in, &fps), v->want, v->a, v->fps_in);
		CHECK2("ftrc.sq fpscr", FPS(fps), v->fps_want, v->a, v->fps_in);
	}
	for (i = 0; i < N(fpu_s_floatls); i++) {
		const struct fpu_s_vq *v = &fpu_s_floatls[i];

		CHECK2("float.ls", float_ls((u32)v->a, v->fps_in, &fps), (u32)v->want, v->a, v->fps_in);
		CHECK2("float.ls fpscr", FPS(fps), v->fps_want, v->a, v->fps_in);
	}
	for (i = 0; i < N(fpu_s_floatqs); i++) {
		const struct fpu_s_vq *v = &fpu_s_floatqs[i];

		CHECK2("float.qs", float_qs(v->a, v->fps_in, &fps), (u32)v->want, v->a, v->fps_in);
		CHECK2("float.qs fpscr", FPS(fps), v->fps_want, v->a, v->fps_in);
	}
}

static void test_sina_cosa(void)
{
	/* approximate: result within 2^-21 of the ideal, inexact always signaled */
	unsigned i;
	u32 fps;

	for (i = 0; i < N(fpu_s_fsina); i++) {
		const struct fpu_s_vr *v = &fpu_s_fsina[i];

		CHECKR("fsina.s", fsina_s(v->a, v->fps_in, &fps), v->lo, v->hi, v->a);
		CHECK2("fsina.s fpscr", FPS(fps), v->fps_want, v->a, v->fps_in);
	}
	for (i = 0; i < N(fpu_s_fcosa); i++) {
		const struct fpu_s_vr *v = &fpu_s_fcosa[i];

		CHECKR("fcosa.s", fcosa_s(v->a, v->fps_in, &fps), v->lo, v->hi, v->a);
		CHECK2("fcosa.s fpscr", FPS(fps), v->fps_want, v->a, v->fps_in);
	}
}

/* everything that can produce a NaN result: pass 0 non-NaN, pass 1 NaN */
static void test_arith(unsigned pass)
{
	unsigned i, j;
	u32 fps;

	FOR_PASS(i, fpu_s_fadd, pass, want) {
		const struct fpu_s_v2 *v = &fpu_s_fadd[i];

		CHECK3("fadd.s", fadd_s(v->a, v->b, v->fps_in, &fps), v->want, v->a, v->b, v->fps_in);
		CHECK3("fadd.s fpscr", FPS(fps), v->fps_want, v->a, v->b, v->fps_in);
	}
	FOR_PASS(i, fpu_s_fsub, pass, want) {
		const struct fpu_s_v2 *v = &fpu_s_fsub[i];

		CHECK3("fsub.s", fsub_s(v->a, v->b, v->fps_in, &fps), v->want, v->a, v->b, v->fps_in);
		CHECK3("fsub.s fpscr", FPS(fps), v->fps_want, v->a, v->b, v->fps_in);
	}
	FOR_PASS(i, fpu_s_fmul, pass, want) {
		const struct fpu_s_v2 *v = &fpu_s_fmul[i];

		CHECK3("fmul.s", fmul_s(v->a, v->b, v->fps_in, &fps), v->want, v->a, v->b, v->fps_in);
		CHECK3("fmul.s fpscr", FPS(fps), v->fps_want, v->a, v->b, v->fps_in);
	}
	FOR_PASS(i, fpu_s_fdiv, pass, want) {
		const struct fpu_s_v2 *v = &fpu_s_fdiv[i];

		CHECK3("fdiv.s", fdiv_s(v->a, v->b, v->fps_in, &fps), v->want, v->a, v->b, v->fps_in);
		CHECK3("fdiv.s fpscr", FPS(fps), v->fps_want, v->a, v->b, v->fps_in);
	}
	FOR_PASS(i, fpu_s_fsqrt, pass, want) {
		const struct fpu_s_v2 *v = &fpu_s_fsqrt[i];

		CHECK2("fsqrt.s", fsqrt_s(v->a, v->fps_in, &fps), v->want, v->a, v->fps_in);
		CHECK2("fsqrt.s fpscr", FPS(fps), v->fps_want, v->a, v->fps_in);
	}
	FOR_PASS(i, fpu_s_fmac, pass, want) {
		const struct fpu_s_v3 *v = &fpu_s_fmac[i];

		CHECK3("fmac.s", fmac_s(v->a, v->b, v->c, v->fps_in, &fps), v->want, v->a, v->b, v->c);
		CHECK3("fmac.s fpscr", FPS(fps), v->fps_want, v->a, v->b, v->c);
	}
	FOR_PASS(i, fpu_s_fsrra, pass, lo) {
		const struct fpu_s_vr *v = &fpu_s_fsrra[i];

		CHECKR("fsrra.s", fsrra_s(v->a, v->fps_in, &fps), v->lo, v->hi, v->a);
		CHECK2("fsrra.s fpscr", FPS(fps), v->fps_want, v->a, v->fps_in);
	}
	FOR_PASS(i, fpu_s_fipr, pass, lo) {
		const struct fpu_s_vipr *v = &fpu_s_fipr[i];

		CHECKR("fipr.s", fipr_s(v->v, v->fps_in, &fps), v->lo, v->hi, i);
		CHECK2("fipr.s fpscr", FPS(fps), v->fps_want, i, v->fps_in);
	}
	for (i = 0; i < N(fpu_s_ftrv); i++) {
		const struct fpu_s_vtrv *v = &fpu_s_ftrv[i];
		u32 out[4];
		unsigned nan = 0;

		for (j = 0; j < 4; j++)
			nan |= nan_result(v->lo[j]);
		if (nan != pass)
			continue;
		ftrv_s(v->m, v->v, out, v->fps_in, &fps);
		for (j = 0; j < 4; j++)
			CHECKR("ftrv.s", out[j], v->lo[j], v->hi[j], ((u64)j << 32) | i);
		CHECK2("ftrv.s fpscr", FPS(fps), v->fps_want, i, v->fps_in);
		if (i < 8) {
			ftrv_s_mtrx0(v->m, v->v, out, v->fps_in, &fps);
			for (j = 0; j < 4; j++)
				CHECKR("ftrv.s mtrx0", out[j], v->lo[j], v->hi[j], ((u64)j << 32) | i);
			CHECK2("ftrv.s mtrx0 fpscr", FPS(fps), v->fps_want, i, v->fps_in);
		}
	}
}

static void test_sticky_flags(void)
{
	/* FLAG accumulates across a sequence, CAUSE is per instruction (Vol. 1 8.3.6) */
	u32 fps;

	fputscr(0);
	fadd_s(0x3f800000, 0x33800000, 0, &fps);		/* 1 + 2^-24: I */
	fdiv_s(0x3f800000, 0x00000000, fgetscr() & 0x7c, &fps);	/* 1/0: Z */
	fmul_s(0x7f7fffff, 0x7f7fffff, fgetscr() & 0x7c, &fps);	/* overflow: O, I */
	/* (2^-126 + 2^-149) / 2 = 2^-127 + 2^-150: tiny and inexact, so U and I
	 * (an exact denormal result such as 2^-127 signals nothing, Vol. 1 8.4.1) */
	fmul_s(0x00800001, 0x3f000000, fgetscr() & 0x7c, &fps);
	CHECK0("flag accumulation", FPS(fgetscr()), (0x0f << 2) | (0x3 << 12));
	fsub_s(0x7f800000, 0x7f800000, fgetscr() & 0x7c, &fps);	/* INF-INF: V (NaN result) */
	CHECK0("flag accumulation nan", FPS(fgetscr()), (0x1f << 2) | (0x10 << 12));
	fputscr(0);
}

ISA_GROUP(fpu_s)
{
	test_fpscr_access();
	test_moves();
	test_loadstore();
	test_compares();
	test_conversions();
	test_sina_cosa();
	test_arith(0);
	isa_puts("isa: fpu_s: ");
	isa_putdec(isa_tests);
	isa_puts(" checks before the NaN-result vectors, ");
	isa_putdec(isa_group_failures);
	isa_puts(" failures\n");
	test_arith(1);
	test_sticky_flags();
}
