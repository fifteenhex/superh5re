/*
 * Reference functions of tests/isa/groups/mmedia2.c compiled for the host.
 * The group file is included so that its static ref_* functions are
 * visible; harness.h resolves to the stand-in in this directory.
 */
#include "groups/mmedia2.c"
#include "ref_mm.h"

#define W2(name, expr) \
	u64 ref_mm_##name(u64 a, u64 b, u64 c) { (void)c; return expr; }
#define W3(name, expr) \
	u64 ref_mm_##name(u64 a, u64 b, u64 c) { return expr; }

W2(mmul_w,     ref_mmul_w(a, b))
W2(mmul_l,     ref_mmul_l(a, b))
W2(mmulfx_w,   ref_mmulfx_w(a, b))
W2(mmulfx_l,   ref_mmulfx_l(a, b))
W2(mmulfxrp_w, ref_mmulfxrp_w(a, b))
W2(mmulhi_wl,  ref_mmulhi_wl(a, b))
W2(mmullo_wl,  ref_mmullo_wl(a, b))
W3(mmulsum_wq, ref_mmulsum_wq(a, b, c))
W3(mmacfx_wl,  ref_mmacfx_wl(a, b, c))
W3(mmacnfx_wl, ref_mmacnfx_wl(a, b, c))
W2(mshalds_w,  ref_mshalds_w(a, b))
W2(mshalds_l,  ref_mshalds_l(a, b))
W2(mshard_w,   ref_mshard_w(a, b))
W2(mshard_l,   ref_mshard_l(a, b))
W2(mshards_q,  ref_mshards_q(a, b))
W2(mshlld_w,   ref_mshlld_w(a, b))
W2(mshlld_l,   ref_mshlld_l(a, b))
W2(mshlrd_w,   ref_mshlrd_w(a, b))
W2(mshlrd_l,   ref_mshlrd_l(a, b))
