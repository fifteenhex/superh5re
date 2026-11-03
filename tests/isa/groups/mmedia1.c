/*
 * Packed SIMD "multimedia" instructions, part 1 (Vol. 2 ch. 2):
 * MADD.W/L, MADDS.W/L/UB, MSUB.W/L, MSUBS.W/L/UB, MABS.W/L,
 * MCMPEQ.B/W/L, MCMPGT.W/L/UB, MCMV, MCNVS.LW/WB/WUB, MSAD.UBQ,
 * MPERM.W, MSHFHI.B/W/L, MSHFLO.B/W/L, MEXTR1..MEXTR7.
 *
 * Lane numbering follows the manual (Vol. 2 section 1, "Expressions"):
 * MultiZeroExtend_n(A)[i] = ZeroExtend_n(A >> (i * n)), so element 0 is
 * the least significant n bits of the register, and MultiRegister_n packs
 * the low n bits of element i back at bit i * n.
 */
#include "harness.h"

/* insn Rm, Rn, Rw with Rw read and written (MCMV, MSAD.UBQ). */
#define ASM_RRW(insn, a, b, w) ({					\
	u64 _w = (w), _a = (a), _b = (b);				\
	__asm__ volatile (insn " %1, %2, %0" : "+r"(_w) : "r"(_a), "r"(_b)); \
	_w; })

/* ---- Vol. 2 helpers: Multi*Extend, MultiRegister, saturation, bytes ---- */

/* Number of n-bit elements in 64 bits, without a division (-mdiv=call). */
static inline int nlanes(int n)
{
	return n == 8 ? 8 : n == 16 ? 4 : 2;
}

static inline u64 MultiZeroExtend(u64 v, int n, int i)
{
	return (v >> (i * n)) & ((1ULL << n) - 1);
}

static inline s64 MultiSignExtend(u64 v, int n, int i)
{
	u64 x = MultiZeroExtend(v, n, i);

	return (s64)(x << (64 - n)) >> (64 - n);
}

/* MultiRegister_n: pack the low n bits of each of the 64/n elements. */
static inline u64 MultiRegister(const s64 *r, int n)
{
	u64 v = 0;
	int i;

	for (i = 0; i < nlanes(n); i++)
		v |= (((u64)r[i]) & ((1ULL << n) - 1)) << (i * n);
	return v;
}

static inline s64 SignedSaturate(s64 v, int n)
{
	s64 lo = -(1LL << (n - 1)), hi = (1LL << (n - 1)) - 1;

	return v < lo ? lo : v > hi ? hi : v;
}

static inline s64 UnsignedSaturate(s64 v, int n)
{
	s64 hi = (1LL << n) - 1;

	return v < 0 ? 0 : v > hi ? hi : v;
}

/* LowerBytes_n(i) = i AND (2^(n*8) - 1); UpperBytes_n(i) = i AND (2^64 - 2^(64-n*8)). */
static inline u64 LowerBytes(u64 v, int n)
{
	return n == 8 ? v : v & ((1ULL << (n * 8)) - 1);
}

static inline u64 UpperBytes(u64 v, int n)
{
	return n == 8 ? v : v & ~((1ULL << (64 - n * 8)) - 1);
}

/* ---- References, lane by lane from the manual's pseudocode ---- */

/* MADD.W / MADD.L / MSUB.W / MSUB.L: modulo, ZeroExtend_n(s1 +/- s2). */
static u64 ref_madd(u64 a, u64 b, int n, int sub)
{
	s64 r[8];
	int i;

	for (i = 0; i < nlanes(n); i++) {
		s64 s1 = MultiZeroExtend(a, n, i), s2 = MultiZeroExtend(b, n, i);

		r[i] = (sub ? s1 - s2 : s1 + s2) & ((1LL << n) - 1);
	}
	return MultiRegister(r, n);
}

/* MADDS.W / MADDS.L / MSUBS.W / MSUBS.L: SignedSaturate_n(s1 +/- s2). */
static u64 ref_madds(u64 a, u64 b, int n, int sub)
{
	s64 r[8];
	int i;

	for (i = 0; i < nlanes(n); i++) {
		s64 s1 = MultiSignExtend(a, n, i), s2 = MultiSignExtend(b, n, i);

		r[i] = SignedSaturate(sub ? s1 - s2 : s1 + s2, n);
	}
	return MultiRegister(r, n);
}

/* MADDS.UB / MSUBS.UB: UnsignedSaturate8(s1 +/- s2). */
static u64 ref_madds_ub(u64 a, u64 b, int sub)
{
	s64 r[8];
	int i;

	for (i = 0; i < 8; i++) {
		s64 s1 = MultiZeroExtend(a, 8, i), s2 = MultiZeroExtend(b, 8, i);

		r[i] = UnsignedSaturate(sub ? s1 - s2 : s1 + s2, 8);
	}
	return MultiRegister(r, 8);
}

/*
 * MABS.W / MABS.L: source >= 0 ? source : SignedSaturate_n(-source).
 * The saturation matters for the most negative element (0x8000 /
 * 0x80000000), which the manual maps to 0x7fff / 0x7fffffff.
 */
static u64 ref_mabs(u64 a, int n)
{
	s64 r[8];
	int i;

	for (i = 0; i < nlanes(n); i++) {
		s64 s = MultiSignExtend(a, n, i);

		r[i] = s >= 0 ? s : SignedSaturate(-s, n);
	}
	return MultiRegister(r, n);
}

/* MCMPEQ.B/W/L: all ones where equal. */
static u64 ref_mcmpeq(u64 a, u64 b, int n)
{
	s64 r[8];
	int i;

	for (i = 0; i < nlanes(n); i++)
		r[i] = MultiSignExtend(a, n, i) == MultiSignExtend(b, n, i) ? -1 : 0;
	return MultiRegister(r, n);
}

/* MCMPGT.W/L: signed greater-than, all ones where true. */
static u64 ref_mcmpgt(u64 a, u64 b, int n)
{
	s64 r[8];
	int i;

	for (i = 0; i < nlanes(n); i++)
		r[i] = MultiSignExtend(a, n, i) > MultiSignExtend(b, n, i) ? -1 : 0;
	return MultiRegister(r, n);
}

/* MCMPGT.UB: unsigned greater-than on bytes. */
static u64 ref_mcmpgt_ub(u64 a, u64 b)
{
	s64 r[8];
	int i;

	for (i = 0; i < 8; i++)
		r[i] = MultiZeroExtend(a, 8, i) > MultiZeroExtend(b, 8, i) ? -1 : 0;
	return MultiRegister(r, 8);
}

/* MCMV Rm, Rn, Rw: Rw = (Rm & Rn) | (Rw & ~Rn). */
static u64 ref_mcmv(u64 a, u64 b, u64 w)
{
	return (a & b) | (w & ~b);
}

/*
 * MCNVS.LW / MCNVS.WB / MCNVS.WUB: 64/n elements of n bits in each source
 * are saturated to n/2 bits; Rm's go to the low half of Rd, Rn's to the
 * high half.  @sat is SignedSaturate or UnsignedSaturate.
 */
static u64 ref_mcnvs(u64 a, u64 b, int n, s64 (*sat)(s64, int))
{
	s64 r[8];
	int i, k = nlanes(n);

	for (i = 0; i < k; i++)
		r[i] = sat(MultiSignExtend(a, n, i), n >> 1);
	for (i = 0; i < k; i++)
		r[i + k] = sat(MultiSignExtend(b, n, i), n >> 1);
	return MultiRegister(r, n >> 1);
}

/* MSAD.UBQ Rm, Rn, Rw: Rw += sum of |Rm.byte[i] - Rn.byte[i]|. */
static u64 ref_msad_ubq(u64 a, u64 b, u64 w)
{
	s64 acc = 0, temp;
	int i;

	for (i = 0; i < 8; i++) {
		temp = (s64)MultiZeroExtend(a, 8, i) - (s64)MultiZeroExtend(b, 8, i);
		if (temp < 0)
			temp = -temp;
		acc += temp;
	}
	return w + (u64)acc;
}

/* MPERM.W: result[i] = source[(control >> 2i) & 3], control = Rn bits 0..7. */
static u64 ref_mperm_w(u64 a, u64 b)
{
	s64 r[4];
	u64 control = ZeroExtend8(b);
	int i;

	for (i = 0; i < 4; i++) {
		unsigned index = (control >> (i * 2)) & 3;

		r[i] = MultiZeroExtend(a, 16, index);
	}
	return MultiRegister(r, 16);
}

/* MSHFHI.n / MSHFLO.n: interleave the upper (hi=1) or lower half of the
 * elements of Rm (even result lanes) and Rn (odd result lanes). */
static u64 ref_mshf(u64 a, u64 b, int n, int hi)
{
	s64 r[8];
	int i, k = nlanes(n) >> 1, base = hi ? k : 0;

	for (i = 0; i < k; i++) {
		r[i * 2] = MultiZeroExtend(a, n, i + base);
		r[i * 2 + 1] = MultiZeroExtend(b, n, i + base);
	}
	return MultiRegister(r, n);
}

/* MEXTRk: (UpperBytes_(8-k)(Rm) >> (k*8)) | (LowerBytes_k(Rn) << ((8-k)*8)). */
static u64 ref_mextr(u64 a, u64 b, int k)
{
	return (UpperBytes(a, 8 - k) >> (k * 8)) | (LowerBytes(b, k) << ((8 - k) * 8));
}

/* ---- Operand construction so that every lane sees boundary values ---- */

static const u16 bound16[16] = {
	0x0000, 0x0001, 0x007f, 0x0080, 0x0081, 0x00ff, 0x0100, 0x7ffe,
	0x7fff, 0x8000, 0x8001, 0xff00, 0xff7f, 0xff80, 0xfffe, 0xffff,
};
static const u32 bound32[16] = {
	0x00000000, 0x00000001, 0x7ffffffe, 0x7fffffff, 0x80000000, 0x80000001,
	0xfffffffe, 0xffffffff, 0x0000ffff, 0xffff0000, 0x00008000, 0x00007fff,
	0x00010000, 0x7f000000, 0x80ffffff, 0x0000007f,
};

/* A 64-bit value whose 16-bit (or 32-bit) lanes are independently drawn
 * from the boundary tables, with one lane in four being fully random. */
static u64 lane_mix(void)
{
	u64 r = isa_rand(), v = 0;
	int i;

	if (r & 1) {
		for (i = 0; i < 4; i++) {
			unsigned sel = (r >> (8 + i * 8)) & 0xff;
			u64 lane = sel < 0xc0 ? bound16[sel & 15]
					      : (isa_rand() & 0xffff);

			v |= lane << (i * 16);
		}
	} else {
		for (i = 0; i < 2; i++) {
			unsigned sel = (r >> (8 + i * 8)) & 0xff;
			u64 lane = sel < 0xc0 ? bound32[sel & 15]
					      : (isa_rand() & 0xffffffff);

			v |= lane << (i * 32);
		}
	}
	return v;
}

/* Every two-source instruction of the group on one operand pair; @c is
 * the initial Rw for MCMV and MSAD.UBQ. */
static void check_pair(u64 a, u64 b, u64 c)
{
	CHECK2("madd.w", ASM_RRR("madd.w", a, b), ref_madd(a, b, 16, 0), a, b);
	CHECK2("madd.l", ASM_RRR("madd.l", a, b), ref_madd(a, b, 32, 0), a, b);
	CHECK2("msub.w", ASM_RRR("msub.w", a, b), ref_madd(a, b, 16, 1), a, b);
	CHECK2("msub.l", ASM_RRR("msub.l", a, b), ref_madd(a, b, 32, 1), a, b);
	CHECK2("madds.w", ASM_RRR("madds.w", a, b), ref_madds(a, b, 16, 0), a, b);
	CHECK2("madds.l", ASM_RRR("madds.l", a, b), ref_madds(a, b, 32, 0), a, b);
	CHECK2("msubs.w", ASM_RRR("msubs.w", a, b), ref_madds(a, b, 16, 1), a, b);
	CHECK2("msubs.l", ASM_RRR("msubs.l", a, b), ref_madds(a, b, 32, 1), a, b);
	CHECK2("madds.ub", ASM_RRR("madds.ub", a, b), ref_madds_ub(a, b, 0), a, b);
	CHECK2("msubs.ub", ASM_RRR("msubs.ub", a, b), ref_madds_ub(a, b, 1), a, b);

	CHECK2("mcmpeq.b", ASM_RRR("mcmpeq.b", a, b), ref_mcmpeq(a, b, 8), a, b);
	CHECK2("mcmpeq.w", ASM_RRR("mcmpeq.w", a, b), ref_mcmpeq(a, b, 16), a, b);
	CHECK2("mcmpeq.l", ASM_RRR("mcmpeq.l", a, b), ref_mcmpeq(a, b, 32), a, b);
	CHECK2("mcmpgt.w", ASM_RRR("mcmpgt.w", a, b), ref_mcmpgt(a, b, 16), a, b);
	CHECK2("mcmpgt.l", ASM_RRR("mcmpgt.l", a, b), ref_mcmpgt(a, b, 32), a, b);
	CHECK2("mcmpgt.ub", ASM_RRR("mcmpgt.ub", a, b), ref_mcmpgt_ub(a, b), a, b);

	CHECK3("mcmv", ASM_RRW("mcmv", a, b, c), ref_mcmv(a, b, c), a, b, c);
	CHECK3("msad.ubq", ASM_RRW("msad.ubq", a, b, c), ref_msad_ubq(a, b, c), a, b, c);

	CHECK2("mcnvs.lw", ASM_RRR("mcnvs.lw", a, b),
	       ref_mcnvs(a, b, 32, SignedSaturate), a, b);
	CHECK2("mcnvs.wb", ASM_RRR("mcnvs.wb", a, b),
	       ref_mcnvs(a, b, 16, SignedSaturate), a, b);
	CHECK2("mcnvs.wub", ASM_RRR("mcnvs.wub", a, b),
	       ref_mcnvs(a, b, 16, UnsignedSaturate), a, b);

	CHECK2("mshfhi.b", ASM_RRR("mshfhi.b", a, b), ref_mshf(a, b, 8, 1), a, b);
	CHECK2("mshfhi.w", ASM_RRR("mshfhi.w", a, b), ref_mshf(a, b, 16, 1), a, b);
	CHECK2("mshfhi.l", ASM_RRR("mshfhi.l", a, b), ref_mshf(a, b, 32, 1), a, b);
	CHECK2("mshflo.b", ASM_RRR("mshflo.b", a, b), ref_mshf(a, b, 8, 0), a, b);
	CHECK2("mshflo.w", ASM_RRR("mshflo.w", a, b), ref_mshf(a, b, 16, 0), a, b);
	CHECK2("mshflo.l", ASM_RRR("mshflo.l", a, b), ref_mshf(a, b, 32, 0), a, b);

	CHECK2("mextr1", ASM_RRR("mextr1", a, b), ref_mextr(a, b, 1), a, b);
	CHECK2("mextr2", ASM_RRR("mextr2", a, b), ref_mextr(a, b, 2), a, b);
	CHECK2("mextr3", ASM_RRR("mextr3", a, b), ref_mextr(a, b, 3), a, b);
	CHECK2("mextr4", ASM_RRR("mextr4", a, b), ref_mextr(a, b, 4), a, b);
	CHECK2("mextr5", ASM_RRR("mextr5", a, b), ref_mextr(a, b, 5), a, b);
	CHECK2("mextr6", ASM_RRR("mextr6", a, b), ref_mextr(a, b, 6), a, b);
	CHECK2("mextr7", ASM_RRR("mextr7", a, b), ref_mextr(a, b, 7), a, b);
}

static void check_unary(u64 a)
{
	CHECK1("mabs.w", ASM_RR("mabs.w", a), ref_mabs(a, 16), a);
	CHECK1("mabs.l", ASM_RR("mabs.l", a), ref_mabs(a, 32), a);
}

ISA_GROUP(mmedia1)
{
	u64 a, b, c;
	unsigned i, ctrl;

	isa_rand_seed(0x6d6d65646961310aULL);

	/* Corpus pairs; Rw for MCMV/MSAD.UBQ is a mix of both. */
	ISA_FOREACH_OPERAND(a) ISA_FOREACH_OPERAND(b) {
		c = a ^ ((b << 32) | (b >> 32));
		check_pair(a, b, c);
	}

	/* Pairs with boundary values in every lane, and random Rw. */
	for (i = 0; i < 1024; i++) {
		a = lane_mix();
		b = (i & 1) ? lane_mix() : isa_rand();
		c = isa_rand();
		check_pair(a, b, c);
		/* Nearly-equal operands exercise MCMPEQ/MSAD per lane. */
		b = a ^ (1ULL << (isa_rand() & 63));
		check_pair(a, b, c);
	}

	/* MABS: corpus plus per-lane boundaries. */
	ISA_FOREACH_OPERAND(a)
		check_unary(a);
	for (i = 0; i < 1024; i++)
		check_unary(lane_mix());

	/* MPERM.W: every 8-bit control value, with garbage in Rn bits 8..63. */
	for (ctrl = 0; ctrl < 256; ctrl++) {
		ISA_FOREACH_OPERAND(a) {
			b = ctrl | (isa_rand() << 8);
			CHECK2("mperm.w", ASM_RRR("mperm.w", a, b), ref_mperm_w(a, b), a, b);
		}
		for (i = 0; i < 4; i++) {
			a = lane_mix();
			b = ctrl | (isa_rand() << 8);
			CHECK2("mperm.w", ASM_RRR("mperm.w", a, b), ref_mperm_w(a, b), a, b);
		}
	}
}
