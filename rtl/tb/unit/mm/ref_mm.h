/*
 * Host-compiled reference functions for the sh5_mm unit test.  The bodies
 * are those of tests/isa/groups/mmedia1.c and mmedia2.c (see ref_mm1.c,
 * ref_mm2.c); every wrapper takes (Rm, Rn, Rw) and ignores what the
 * instruction does not read.
 */
#ifndef REF_MM_H
#define REF_MM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned long long ref_mm_fn(unsigned long long a, unsigned long long b,
				     unsigned long long c);

/* mmedia1.c */
ref_mm_fn ref_mm_madd_w, ref_mm_madd_l, ref_mm_msub_w, ref_mm_msub_l;
ref_mm_fn ref_mm_madds_w, ref_mm_madds_l, ref_mm_msubs_w, ref_mm_msubs_l;
ref_mm_fn ref_mm_madds_ub, ref_mm_msubs_ub;
ref_mm_fn ref_mm_mcmpeq_b, ref_mm_mcmpeq_w, ref_mm_mcmpeq_l;
ref_mm_fn ref_mm_mcmpgt_w, ref_mm_mcmpgt_l, ref_mm_mcmpgt_ub;
ref_mm_fn ref_mm_mcmv, ref_mm_msad_ubq;
ref_mm_fn ref_mm_mcnvs_lw, ref_mm_mcnvs_wb, ref_mm_mcnvs_wub;
ref_mm_fn ref_mm_mshfhi_b, ref_mm_mshfhi_w, ref_mm_mshfhi_l;
ref_mm_fn ref_mm_mshflo_b, ref_mm_mshflo_w, ref_mm_mshflo_l;
ref_mm_fn ref_mm_mextr1, ref_mm_mextr2, ref_mm_mextr3, ref_mm_mextr4;
ref_mm_fn ref_mm_mextr5, ref_mm_mextr6, ref_mm_mextr7;
ref_mm_fn ref_mm_mabs_w, ref_mm_mabs_l, ref_mm_mperm_w;

/* mmedia2.c */
ref_mm_fn ref_mm_mmul_w, ref_mm_mmul_l, ref_mm_mmulfx_w, ref_mm_mmulfx_l;
ref_mm_fn ref_mm_mmulfxrp_w, ref_mm_mmulhi_wl, ref_mm_mmullo_wl;
ref_mm_fn ref_mm_mmulsum_wq, ref_mm_mmacfx_wl, ref_mm_mmacnfx_wl;
ref_mm_fn ref_mm_mshalds_w, ref_mm_mshalds_l, ref_mm_mshard_w, ref_mm_mshard_l;
ref_mm_fn ref_mm_mshards_q, ref_mm_mshlld_w, ref_mm_mshlld_l;
ref_mm_fn ref_mm_mshlrd_w, ref_mm_mshlrd_l;

#ifdef __cplusplus
}
#endif

#endif /* REF_MM_H */
