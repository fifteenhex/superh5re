/*
 * Reference functions of tests/isa/groups/mmedia1.c compiled for the host.
 * The group file is included so that its static ref_* functions are
 * visible; harness.h resolves to the stand-in in this directory.
 */
#include "groups/mmedia1.c"
#include "ref_mm.h"

#define W2(name, expr) \
	u64 ref_mm_##name(u64 a, u64 b, u64 c) { (void)c; return expr; }
#define W3(name, expr) \
	u64 ref_mm_##name(u64 a, u64 b, u64 c) { return expr; }

W2(madd_w,    ref_madd(a, b, 16, 0))
W2(madd_l,    ref_madd(a, b, 32, 0))
W2(msub_w,    ref_madd(a, b, 16, 1))
W2(msub_l,    ref_madd(a, b, 32, 1))
W2(madds_w,   ref_madds(a, b, 16, 0))
W2(madds_l,   ref_madds(a, b, 32, 0))
W2(msubs_w,   ref_madds(a, b, 16, 1))
W2(msubs_l,   ref_madds(a, b, 32, 1))
W2(madds_ub,  ref_madds_ub(a, b, 0))
W2(msubs_ub,  ref_madds_ub(a, b, 1))
W2(mcmpeq_b,  ref_mcmpeq(a, b, 8))
W2(mcmpeq_w,  ref_mcmpeq(a, b, 16))
W2(mcmpeq_l,  ref_mcmpeq(a, b, 32))
W2(mcmpgt_w,  ref_mcmpgt(a, b, 16))
W2(mcmpgt_l,  ref_mcmpgt(a, b, 32))
W2(mcmpgt_ub, ref_mcmpgt_ub(a, b))
W3(mcmv,      ref_mcmv(a, b, c))
W3(msad_ubq,  ref_msad_ubq(a, b, c))
W2(mcnvs_lw,  ref_mcnvs(a, b, 32, SignedSaturate))
W2(mcnvs_wb,  ref_mcnvs(a, b, 16, SignedSaturate))
W2(mcnvs_wub, ref_mcnvs(a, b, 16, UnsignedSaturate))
W2(mshfhi_b,  ref_mshf(a, b, 8, 1))
W2(mshfhi_w,  ref_mshf(a, b, 16, 1))
W2(mshfhi_l,  ref_mshf(a, b, 32, 1))
W2(mshflo_b,  ref_mshf(a, b, 8, 0))
W2(mshflo_w,  ref_mshf(a, b, 16, 0))
W2(mshflo_l,  ref_mshf(a, b, 32, 0))
W2(mextr1,    ref_mextr(a, b, 1))
W2(mextr2,    ref_mextr(a, b, 2))
W2(mextr3,    ref_mextr(a, b, 3))
W2(mextr4,    ref_mextr(a, b, 4))
W2(mextr5,    ref_mextr(a, b, 5))
W2(mextr6,    ref_mextr(a, b, 6))
W2(mextr7,    ref_mextr(a, b, 7))
W2(mabs_w,    ((void)b, ref_mabs(a, 16)))
W2(mabs_l,    ((void)b, ref_mabs(a, 32)))
W2(mperm_w,   ref_mperm_w(a, b))
