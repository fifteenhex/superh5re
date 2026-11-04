/* SHcompact branches (Vol. 3 chapter 2 and section 1.6): BT, BF, BT/S, BF/S,
 * BRA, BRAF, BSR, BSRF, JMP, JSR, RTS. Layouts are in branch_cops.py: the
 * routines return the path marker in R0, the number of delay slot executions
 * in R1 and PR minus L (L = address after the delay slot, loaded with MOVA),
 * so the results do not depend on where the routines are linked. */
#include "harness.h"
#include "cops.h"

#define CHK(name, reg, want, x)	CHECK1(name, reg, RES32(want), x)

/* BRAF/BSRF/JMP/JSR/RTS target blocks: marker of the block at L + off
 * (6-byte blocks at L + 6k, marker k; at L - 14 - 6j, marker -2 - j) */
static const s32 tgt_off[] = { 0, 6, 12, 18, -14, -20, -26, -32 };
static s32 marker(s32 off)
{
	if (off >= 0)
		return isa_udiv32((u32)off, 6);
	return -2 - (s32)isa_udiv32((u32)(-14 - off), 6);
}

ISA_GROUP(branch)
{
	struct cres r;

	for (u32 t = 0; t < 2; t++) {
		static const struct {
			const char *name;
			const u16 *near, *fwd, *back;
			u32 on_t, delayed;
		} cb[] = {
			{ "bt", cop_bt_near, cop_bt_fwd, cop_bt_back, 1, 0 },
			{ "bf", cop_bf_near, cop_bf_fwd, cop_bf_back, 0, 0 },
			{ "bt/s", cop_bts_near, cop_bts_fwd, cop_bts_back, 1, 1 },
			{ "bf/s", cop_bfs_near, cop_bfs_fwd, cop_bfs_back, 0, 1 },
		};

		for (unsigned i = 0; i < 4; i++) {
			u32 taken = t == cb[i].on_t, d = cb[i].delayed;

			/* near: fall-through adds 2 (and 1 to r1 for BT/BF); target adds 4 */
			r = cop(cb[i].near, 0, 0, 0, t);
			CHK(cb[i].name, r.r0, taken ? 4 : 6, t);
			if (d) {
				CHK(cb[i].name, r.r1, 1, t);	/* slot executed once */
				CHK(cb[i].name, r.r3, 1, t);	/* before the target */
			} else {
				CHK(cb[i].name, r.r1, !taken, t);
			}
			/* displacement +127 and -128 (target PC + 4 + disp * 2) */
			r = cop(cb[i].fwd, 0, 0, 0, t);
			CHK(cb[i].name, r.r0, taken ? 4 : 2, t);
			CHK(cb[i].name, r.r1, d, t);
			CHK(cb[i].name, r.r2, 0, t);
			r = cop(cb[i].back, 0, 0, 0, t);
			CHK(cb[i].name, r.r0, taken ? 4 : 2, t);
			CHK(cb[i].name, r.r1, d, t);
			CHK(cb[i].name, r.r2, 0, t);
		}
		/* the condition is T before the delay slot (slot CLRT / SETT) */
		r = cop(cop_bts_tslot, 0, 0, 0, t);
		CHK("bt/s T slot", r.r0, t ? 4 : 6, t); CHK("bt/s T slot", r.r1, 0, t);
		r = cop(cop_bfs_tslot, 0, 0, 0, t);
		CHK("bf/s T slot", r.r0, t ? 6 : 4, t); CHK("bf/s T slot", r.r1, 1, t);
	}

	{
		static const struct { const char *name; const u16 *fn; } b[] = {
			{ "bra", cop_bra_near }, { "bra +2047", cop_bra_fwd }, { "bra -2048", cop_bra_back } };

		for (unsigned i = 0; i < 3; i++) {
			r = cop(b[i].fn, 0, 0, 0, 0);
			CHK(b[i].name, r.r0, 4, 0); CHK(b[i].name, r.r1, 1, 0);
			CHK(b[i].name, r.r2, 0, 0); CHK(b[i].name, r.r3, 1, 0);
		}
	}
	{
		/* BSR: subroutine sees the slot done (r0 = 1), RTS slot adds 8,
		 * return path adds 16; PR = L */
		static const struct { const char *name; const u16 *fn; } b[] = {
			{ "bsr", cop_bsr_near }, { "bsr +2047", cop_bsr_fwd }, { "bsr -2048", cop_bsr_back } };

		for (unsigned i = 0; i < 3; i++) {
			r = cop(b[i].fn, 0, 0, 0, 0);
			CHK(b[i].name, r.r0, 1 + 8 + 16, 0); CHK(b[i].name, r.r1, 1, 0);
			CHK(b[i].name, r.r2, 0, 0);
		}
	}

	for (unsigned i = 0; i < sizeof(tgt_off) / sizeof(tgt_off[0]); i++) {
		u32 off = (u32)tgt_off[i], m = (u32)marker(tgt_off[i]);

		/* BRAF/BSRF Rn: target PC + 4 + Rn = L + Rn */
		r = cop(cop_braf, 0, off, 0, 0);
		CHK("braf", r.r0, m, off); CHK("braf", r.r1, 1, off); CHK("braf slot first", r.r2, 1, off);
		r = cop(cop_braf_rslot, 0, off, 0, 0);
		CHK("braf Rn in slot", r.r0, m, off);
		r = cop(cop_bsrf, 0, off, 0, 0);
		CHK("bsrf", r.r0, m, off); CHK("bsrf", r.r1, 1, off); CHK("bsrf pr", r.r2, 0, off);
		if (tgt_off[i] < 0)
			continue;
		/* JMP/JSR @Rn, RTS: target Rn / PR = L + off */
		r = cop(cop_jmp, 0, off, 0, 0);
		CHK("jmp", r.r0, m, off); CHK("jmp", r.r1, 1, off); CHK("jmp slot first", r.r2, 1, off);
		r = cop(cop_jmp_rslot, 0, off, 0, 0);
		CHK("jmp Rn in slot", r.r0, m, off);
		r = cop(cop_jsr, 0, off, 0, 0);
		CHK("jsr", r.r0, m, off); CHK("jsr", r.r1, 1, off); CHK("jsr pr", r.r2, 0, off);
		r = cop(cop_rts, 0, off, 0, 0);
		CHK("rts", r.r0, m, off); CHK("rts", r.r1, 1, off); CHK("rts slot first", r.r2, 1, off);
	}
}
