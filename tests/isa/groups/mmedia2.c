/*
 * Packed SIMD multiply and shift (Vol. 2 ch. 2): MMUL.W, MMUL.L, MMULFX.W,
 * MMULFX.L, MMULFXRP.W, MMULHI.WL, MMULLO.WL, MMULSUM.WQ, MMACFX.WL,
 * MMACNFX.WL, MSHALDS.W, MSHALDS.L, MSHARD.W, MSHARD.L, MSHARDS.Q,
 * MSHLLD.W, MSHLLD.L, MSHLRD.W, MSHLRD.L.
 *
 * Every reference below is the manual's pseudocode written lane by lane:
 * MultiSignExtend/MultiZeroExtend split the register into lanes, the lane
 * arithmetic is done on s64 (wide enough for every intermediate: a 32x32
 * product or a 32-bit lane shifted left by 31 both fit), SignedSaturate
 * clamps to the n-bit signed range [-2^(n-1), 2^(n-1)-1] (Vol. 2 Table 11),
 * and MultiRegister packs the low n bits of each lane back.  Right shifts
 * of negative s64 values rely on gcc's arithmetic >>.
 */
#include "harness.h"

/* insn Rm, Rn, Rw: Rw is both accumulator input and result. */
#define ASM_RRW(insn, a, b, w) ({					\
	u64 _w = (w), _a = (a), _b = (b);				\
	__asm__ volatile (insn " %1, %2, %0" : "+r"(_w) : "r"(_a), "r"(_b)); \
	_w; })

/* Vol. 2 Table 11. */
static s64 SignedSaturate16(s64 i)
{
	if (i < -32768) return -32768;
	if (i > 32767) return 32767;
	return i;
}

static s64 SignedSaturate32(s64 i)
{
	if (i < -2147483648LL) return -2147483648LL;
	if (i > 2147483647LL) return 2147483647LL;
	return i;
}

/* MultiSignExtend / MultiZeroExtend, one element at a time. */
static s64 lane16s(u64 v, int i) { return SignExtend16(v >> (16 * i)); }
static u64 lane16u(u64 v, int i) { return ZeroExtend16(v >> (16 * i)); }
static s64 lane32s(u64 v, int i) { return SignExtend32(v >> (32 * i)); }
static u64 lane32u(u64 v, int i) { return ZeroExtend32(v >> (32 * i)); }

/* MultiRegister16 / MultiRegister32: low n bits of each element. */
static u64 pack16(const s64 r[4])
{
	return ZeroExtend16(r[0]) | ZeroExtend16(r[1]) << 16 |
	       ZeroExtend16(r[2]) << 32 | ZeroExtend16(r[3]) << 48;
}

static u64 pack32(const s64 r[2])
{
	return ZeroExtend32(r[0]) | ZeroExtend32(r[1]) << 32;
}

/* ---- multiplies ---- */

static u64 ref_mmul_w(u64 m, u64 n)
{
	s64 r[4];
	int i;

	for (i = 0; i < 4; i++)
		r[i] = ZeroExtend16(lane16u(m, i) * lane16u(n, i));
	return pack16(r);
}

static u64 ref_mmul_l(u64 m, u64 n)
{
	s64 r[2];
	int i;

	for (i = 0; i < 2; i++)
		r[i] = ZeroExtend32(lane32u(m, i) * lane32u(n, i));
	return pack32(r);
}

/* temp = s1*s2; result = SignedSaturate16(temp >> 15).  -1 * -1 -> 0x7fff. */
static u64 ref_mmulfx_w(u64 m, u64 n)
{
	s64 r[4];
	int i;

	for (i = 0; i < 4; i++) {
		s64 temp = lane16s(m, i) * lane16s(n, i);

		r[i] = SignedSaturate16(temp >> 15);
	}
	return pack16(r);
}

static u64 ref_mmulfx_l(u64 m, u64 n)
{
	s64 r[2];
	int i;

	for (i = 0; i < 2; i++) {
		s64 temp = lane32s(m, i) * lane32s(n, i);

		r[i] = SignedSaturate32(temp >> 31);
	}
	return pack32(r);
}

/* result = SignedSaturate16((temp + 2^14) >> 15): round to nearest, ties up. */
static u64 ref_mmulfxrp_w(u64 m, u64 n)
{
	s64 r[4];
	int i;

	for (i = 0; i < 4; i++) {
		s64 temp = lane16s(m, i) * lane16s(n, i);

		r[i] = SignedSaturate16((temp + (1 << 14)) >> 15);
	}
	return pack16(r);
}

/* result[i] = source1[i+2] * source2[i+2], packed as 2 x 32 bits. */
static u64 ref_mmulhi_wl(u64 m, u64 n)
{
	s64 r[2];
	int i;

	for (i = 0; i < 2; i++)
		r[i] = lane16s(m, i + 2) * lane16s(n, i + 2);
	return pack32(r);
}

static u64 ref_mmullo_wl(u64 m, u64 n)
{
	s64 r[2];
	int i;

	for (i = 0; i < 2; i++)
		r[i] = lane16s(m, i) * lane16s(n, i);
	return pack32(r);
}

/* Rw = Rw + sum of the four signed 16x16 products, 64-bit modulo. */
static u64 ref_mmulsum_wq(u64 m, u64 n, u64 w)
{
	s64 acc = 0;
	int i;

	for (i = 0; i < 4; i++)
		acc += lane16s(m, i) * lane16s(n, i);
	return (u64)((s64)w + acc);
}

/*
 * temp = SignedSaturate32((s1[i]*s2[i]) << 1)   (-1 * -1 -> 0x7fffffff)
 * rw[i] = SignedSaturate32(rw[i] + temp)        (MMACNFX: rw[i] - temp)
 *
 * Two plain functions rather than one with a negate flag: with the flag,
 * gcc 6.5 implemented a 32-bit sign extension through an FP register
 * (fmov.ls/fmov.sl), and this integer group must not touch the FPU.
 */
static u64 ref_mmacfx_wl(u64 m, u64 n, u64 w)
{
	s64 r[2];
	int i;

	for (i = 0; i < 2; i++) {
		s64 temp = lane16s(m, i) * lane16s(n, i);

		temp = SignedSaturate32(temp << 1);
		r[i] = SignedSaturate32(lane32s(w, i) + temp);
	}
	return pack32(r);
}

static u64 ref_mmacnfx_wl(u64 m, u64 n, u64 w)
{
	s64 r[2];
	int i;

	for (i = 0; i < 2; i++) {
		s64 temp = lane16s(m, i) * lane16s(n, i);

		temp = SignedSaturate32(temp << 1);
		r[i] = SignedSaturate32(lane32s(w, i) - temp);
	}
	return pack32(r);
}

/* ---- shifts: .W uses bits 0-3 of Rn, .L bits 0-4, .Q bits 0-5 ---- */

static u64 ref_mshalds_w(u64 m, u64 n)
{
	s64 r[4];
	unsigned amt = n & 15;
	int i;

	for (i = 0; i < 4; i++)
		r[i] = SignedSaturate16(lane16s(m, i) << amt);
	return pack16(r);
}

static u64 ref_mshalds_l(u64 m, u64 n)
{
	s64 r[2];
	unsigned amt = n & 31;
	int i;

	for (i = 0; i < 2; i++)
		r[i] = SignedSaturate32(lane32s(m, i) << amt);
	return pack32(r);
}

static u64 ref_mshard_w(u64 m, u64 n)
{
	s64 r[4];
	unsigned amt = n & 15;
	int i;

	for (i = 0; i < 4; i++)
		r[i] = SignExtend16(lane16s(m, i) >> amt);
	return pack16(r);
}

static u64 ref_mshard_l(u64 m, u64 n)
{
	s64 r[2];
	unsigned amt = n & 31;
	int i;

	for (i = 0; i < 2; i++)
		r[i] = SignExtend32(lane32s(m, i) >> amt);
	return pack32(r);
}

/* Scalar: Rd = Register(SignedSaturate16(SignExtend64(Rm) >> (Rn & 63))). */
static u64 ref_mshards_q(u64 m, u64 n)
{
	return (u64)SignedSaturate16((s64)m >> (n & 63));
}

static u64 ref_mshlld_w(u64 m, u64 n)
{
	s64 r[4];
	unsigned amt = n & 15;
	int i;

	for (i = 0; i < 4; i++)
		r[i] = ZeroExtend16(lane16u(m, i) << amt);
	return pack16(r);
}

static u64 ref_mshlld_l(u64 m, u64 n)
{
	s64 r[2];
	unsigned amt = n & 31;
	int i;

	for (i = 0; i < 2; i++)
		r[i] = ZeroExtend32(lane32u(m, i) << amt);
	return pack32(r);
}

static u64 ref_mshlrd_w(u64 m, u64 n)
{
	s64 r[4];
	unsigned amt = n & 15;
	int i;

	for (i = 0; i < 4; i++)
		r[i] = ZeroExtend16(lane16u(m, i) >> amt);
	return pack16(r);
}

static u64 ref_mshlrd_l(u64 m, u64 n)
{
	s64 r[2];
	unsigned amt = n & 31;
	int i;

	for (i = 0; i < 2; i++)
		r[i] = ZeroExtend32(lane32u(m, i) >> amt);
	return pack32(r);
}

/* ---- operand generation ---- */

/*
 * Lane boundary values: the corpus only has 0x8000/0x7fff/0xffff in a few
 * lane positions, so build extra words with every 16-bit lane drawn from
 * this table (or random), and likewise for 32-bit lanes.  Index 0..7 are
 * the fixed-point extremes; 8..15 take a random value.
 */
static const u16 lane16_vals[8] = {
	0x0000, 0x0001, 0x7fff, 0x8000, 0x8001, 0xffff, 0x4000, 0xc000,
};
static const u32 lane32_vals[8] = {
	0x00000000, 0x00000001, 0x7fffffff, 0x80000000,
	0x80000001, 0xffffffff, 0x40000000, 0xc0000000,
};

static u64 rand_lanes16(void)
{
	u64 r = isa_rand(), v = 0;
	int i;

	for (i = 0; i < 4; i++) {
		unsigned sel = (r >> (4 * i)) & 15;
		u64 lane = sel < 8 ? lane16_vals[sel] : (u16)(r >> (16 + 12 * i));

		v |= lane << (16 * i);
	}
	return v;
}

static u64 rand_lanes32(void)
{
	u64 r = isa_rand(), v = 0;
	int i;

	for (i = 0; i < 2; i++) {
		unsigned sel = (r >> (4 * i)) & 15;
		u64 lane = sel < 8 ? lane32_vals[sel] : (u32)(r >> (8 + 24 * i));

		v |= lane << (32 * i);
	}
	return v;
}

/* All two-operand instructions on one (a, b) pair; b is the shift amount. */
static void check_pair(u64 a, u64 b)
{
	CHECK2("mmul.w", ASM_RRR("mmul.w", a, b), ref_mmul_w(a, b), a, b);
	CHECK2("mmul.l", ASM_RRR("mmul.l", a, b), ref_mmul_l(a, b), a, b);
	CHECK2("mmulfx.w", ASM_RRR("mmulfx.w", a, b), ref_mmulfx_w(a, b), a, b);
	CHECK2("mmulfx.l", ASM_RRR("mmulfx.l", a, b), ref_mmulfx_l(a, b), a, b);
	CHECK2("mmulfxrp.w", ASM_RRR("mmulfxrp.w", a, b),
	       ref_mmulfxrp_w(a, b), a, b);
	CHECK2("mmulhi.wl", ASM_RRR("mmulhi.wl", a, b),
	       ref_mmulhi_wl(a, b), a, b);
	CHECK2("mmullo.wl", ASM_RRR("mmullo.wl", a, b),
	       ref_mmullo_wl(a, b), a, b);

	CHECK2("mshalds.w", ASM_RRR("mshalds.w", a, b),
	       ref_mshalds_w(a, b), a, b);
	CHECK2("mshalds.l", ASM_RRR("mshalds.l", a, b),
	       ref_mshalds_l(a, b), a, b);
	CHECK2("mshard.w", ASM_RRR("mshard.w", a, b), ref_mshard_w(a, b), a, b);
	CHECK2("mshard.l", ASM_RRR("mshard.l", a, b), ref_mshard_l(a, b), a, b);
	CHECK2("mshards.q", ASM_RRR("mshards.q", a, b),
	       ref_mshards_q(a, b), a, b);
	CHECK2("mshlld.w", ASM_RRR("mshlld.w", a, b), ref_mshlld_w(a, b), a, b);
	CHECK2("mshlld.l", ASM_RRR("mshlld.l", a, b), ref_mshlld_l(a, b), a, b);
	CHECK2("mshlrd.w", ASM_RRR("mshlrd.w", a, b), ref_mshlrd_w(a, b), a, b);
	CHECK2("mshlrd.l", ASM_RRR("mshlrd.l", a, b), ref_mshlrd_l(a, b), a, b);
}

/* The accumulating forms on (a, b, w). */
static void check_acc(u64 a, u64 b, u64 w)
{
	CHECK3("mmulsum.wq", ASM_RRW("mmulsum.wq", a, b, w),
	       ref_mmulsum_wq(a, b, w), a, b, w);
	CHECK3("mmacfx.wl", ASM_RRW("mmacfx.wl", a, b, w),
	       ref_mmacfx_wl(a, b, w), a, b, w);
	CHECK3("mmacnfx.wl", ASM_RRW("mmacnfx.wl", a, b, w),
	       ref_mmacnfx_wl(a, b, w), a, b, w);
}

ISA_GROUP(mmedia2)
{
	u64 a, b, w;
	unsigned i, amt;

	/* Corpus pairs: a is the data, b doubles as data and shift amount. */
	ISA_FOREACH_OPERAND(a) ISA_FOREACH_OPERAND(b) {
		check_pair(a, b);
		check_acc(a, b, a ^ (b << 7));
	}

	/* Corpus data against every shift amount 0..63 (bits above the
	 * used ones set at random, they must be ignored). */
	ISA_FOREACH_OPERAND(a) for (amt = 0; amt < 64; amt++) {
		b = (isa_rand() << 6) | amt;
		CHECK2("mshalds.w", ASM_RRR("mshalds.w", a, b),
		       ref_mshalds_w(a, b), a, b);
		CHECK2("mshalds.l", ASM_RRR("mshalds.l", a, b),
		       ref_mshalds_l(a, b), a, b);
		CHECK2("mshard.w", ASM_RRR("mshard.w", a, b),
		       ref_mshard_w(a, b), a, b);
		CHECK2("mshard.l", ASM_RRR("mshard.l", a, b),
		       ref_mshard_l(a, b), a, b);
		CHECK2("mshards.q", ASM_RRR("mshards.q", a, b),
		       ref_mshards_q(a, b), a, b);
		CHECK2("mshlld.w", ASM_RRR("mshlld.w", a, b),
		       ref_mshlld_w(a, b), a, b);
		CHECK2("mshlld.l", ASM_RRR("mshlld.l", a, b),
		       ref_mshlld_l(a, b), a, b);
		CHECK2("mshlrd.w", ASM_RRR("mshlrd.w", a, b),
		       ref_mshlrd_w(a, b), a, b);
		CHECK2("mshlrd.l", ASM_RRR("mshlrd.l", a, b),
		       ref_mshlrd_l(a, b), a, b);
	}

	/* Lane-boundary words: every 16-bit lane sees 0x8000, 0x7fff, ...
	 * against every other, so each lane of the FX forms saturates and
	 * the MMAC and MMULSUM forms accumulate from saturated accumulators. */
	isa_rand_seed(0x6d6d656469613200ULL);	/* fixed seed: reproducible */
	for (i = 0; i < 1500; i++) {
		a = rand_lanes16();
		b = rand_lanes16();
		w = (i & 1) ? rand_lanes32() : isa_rand();
		check_pair(a, b);
		check_acc(a, b, w);
	}
	for (i = 0; i < 1000; i++) {
		a = rand_lanes32();
		b = (i & 1) ? rand_lanes32() : isa_rand();
		check_pair(a, b);
		check_acc(a, b, rand_lanes32());
	}
	/* Fully random words. */
	for (i = 0; i < 500; i++) {
		a = isa_rand();
		b = isa_rand();
		check_pair(a, b);
		check_acc(a, b, isa_rand());
	}
}
