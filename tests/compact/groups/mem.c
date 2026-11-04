/* SHcompact loads and stores (all MOV addressing modes, MOVA, MOVCA.L),
 * GBR/PR/MACH/MACL memory forms, AND.B/OR.B/XOR.B/TST.B #imm,@(R0,GBR),
 * TAS.B, PREF, OCBI, OCBP, OCBWB (Vol. 3 chapter 2). Memory is little-endian;
 * the references read and write the byte array explicitly. */
#include "harness.h"
#include "cops.h"

#define BUFSZ	1536
static volatile u8 buf[BUFSZ] __attribute__((aligned(32)));
static u8 ref[BUFSZ];
static u32 fill_state;

#define A(off)	ADDR(&buf[off])

static u32 frand(void)
{
	u32 x = fill_state;

	x ^= x << 13; x ^= x >> 17; x ^= x << 5;
	fill_state = x;
	return x;
}

/* known bytes; every 7th byte 0 and every 11th 0x80 so that TAS.B and the
 * sign extensions see both cases */
static void fill(u32 seed)
{
	fill_state = seed * 0x9e3779b9u + 1;
	for (unsigned i = 0; i < BUFSZ; i++) {
		u8 v = (u8)(frand() >> 24);

		if (i % 7 == 0) v = 0;
		else if (i % 11 == 0) v = 0x80;
		else if (i % 13 == 0) v = 0x7f;
		buf[i] = ref[i] = v;
	}
}

static u32 rd(unsigned off, unsigned sz)
{
	u32 v = 0;

	for (unsigned i = 0; i < sz; i++)
		v |= (u32)ref[off + i] << (8 * i);
	return v;
}

static void wr(unsigned off, u32 v, unsigned sz)
{
	for (unsigned i = 0; i < sz; i++)
		ref[off + i] = (u8)(v >> (8 * i));
}

/* loaded value: sign extension of the byte/word/long */
static u32 sx(u32 v, unsigned sz)
{
	return sz == 1 ? (u32)(s32)(s8)v : sz == 2 ? (u32)(s32)(s16)v : v;
}

/* whole buffer equals ref: one check, the first differing word is reported */
static void chkbuf(const char *name, u32 a, u32 b)
{
	unsigned i;

	for (i = 0; i < BUFSZ; i += 4)
		if (buf[i] != ref[i] || buf[i + 1] != ref[i + 1] || buf[i + 2] != ref[i + 2] || buf[i + 3] != ref[i + 3])
			break;
	if (i == BUFSZ) {
		CHECK2(name, 0, 0, a, b);
		return;
	}
	CHECK2(name, (u64)(buf[i] | buf[i + 1] << 8 | buf[i + 2] << 16 | (u32)buf[i + 3] << 24),
	       (u64)rd(i, 4), a, b);
	for (i = 0; i < BUFSZ; i++)	/* resynchronise after a failure */
		ref[i] = buf[i];
}

static const u16 *const ld_r[3] = { cop_ldb_r, cop_ldw_r, cop_ldl_r };
static const u16 *const ld_p[3] = { cop_ldb_p, cop_ldw_p, cop_ldl_p };
static const u16 *const ld_pn[3] = { cop_ldb_pn, cop_ldw_pn, cop_ldl_pn };
static const u16 *const ld_x[3] = { cop_ldb_x, cop_ldw_x, cop_ldl_x };
static const u16 *const st_r[3] = { cop_stb_r, cop_stw_r, cop_stl_r };
static const u16 *const st_m[3] = { cop_stb_m, cop_stw_m, cop_stl_m };
static const u16 *const st_mn[3] = { cop_stb_mn, cop_stw_mn, cop_stl_mn };
static const u16 *const st_x[3] = { cop_stb_x, cop_stw_x, cop_stl_x };
/* displacements as in mem_cops.py */
static const u16 disp_r[3][4] = { {0, 1, 5, 15}, {0, 2, 14, 30}, {0, 4, 28, 60} };
static const u16 disp_g[3][4] = { {0, 1, 0x7f, 0xff}, {0, 2, 0xfe, 0x1fe}, {0, 4, 0x1fc, 0x3fc} };
static const u16 *const ld_d[3][4] = {
	{ cop_ldb_d0, cop_ldb_d1, cop_ldb_d5, cop_ldb_d15 },
	{ cop_ldw_d0, cop_ldw_d2, cop_ldw_d14, cop_ldw_d30 },
	{ cop_ldl_d0, cop_ldl_d4, cop_ldl_d28, cop_ldl_d60 } };
static const u16 *const ld_g[3][4] = {
	{ cop_ldb_g0, cop_ldb_g1, cop_ldb_g127, cop_ldb_g255 },
	{ cop_ldw_g0, cop_ldw_g2, cop_ldw_g254, cop_ldw_g510 },
	{ cop_ldl_g0, cop_ldl_g4, cop_ldl_g508, cop_ldl_g1020 } };
static const u16 *const st_d[3][4] = {
	{ cop_stb_d0, cop_stb_d1, cop_stb_d5, cop_stb_d15 },
	{ cop_stw_d0, cop_stw_d2, cop_stw_d14, cop_stw_d30 },
	{ cop_stl_d0, cop_stl_d4, cop_stl_d28, cop_stl_d60 } };
static const u16 *const st_g[3][4] = {
	{ cop_stb_g0, cop_stb_g1, cop_stb_g127, cop_stb_g255 },
	{ cop_stw_g0, cop_stw_g2, cop_stw_g254, cop_stw_g510 },
	{ cop_stl_g0, cop_stl_g4, cop_stl_g508, cop_stl_g1020 } };
static const char *const sname[3] = { "mov.b", "mov.w", "mov.l" };

/* PC-relative literals and MOVA targets as in mem_cops.py */
static const u16 *const ldl_pc[4] = { cop_ldl_pc0, cop_ldl_pc1, cop_ldl_pc2, cop_ldl_pc3 };
static const u32 ldl_pc_v[4] = { 0x89abcdef, 0x12345678, 0xfedcba98, 0x7f00ff01 };
static const u16 *const ldw_pc[4] = { cop_ldw_pc0, cop_ldw_pc1, cop_ldw_pc2, cop_ldw_pc3 };
static const u16 ldw_pc_v[4] = { 0x8001, 0x7ffe, 0xff80, 0x1234 };
static const u16 *const mova[4] = { cop_mova0, cop_mova1, cop_mova2, cop_mova3 };
extern const u32 cop_mova_lit0[], cop_mova_lit1[], cop_mova_lit2[], cop_mova_lit3[];
static const u32 *const mova_lit[4] = { cop_mova_lit0, cop_mova_lit1, cop_mova_lit2, cop_mova_lit3 };

static const u8 rmw_imm[5] = { 0x00, 0x01, 0x5a, 0x80, 0xff };
static const u16 *const andb[5] = { cop_andb_00, cop_andb_01, cop_andb_5a, cop_andb_80, cop_andb_ff };
static const u16 *const orb[5] = { cop_orb_00, cop_orb_01, cop_orb_5a, cop_orb_80, cop_orb_ff };
static const u16 *const xorb[5] = { cop_xorb_00, cop_xorb_01, cop_xorb_5a, cop_xorb_80, cop_xorb_ff };
static const u16 *const tstb[5] = { cop_tstb_00, cop_tstb_01, cop_tstb_5a, cop_tstb_80, cop_tstb_ff };

static void loads(void)
{
	struct cres r;
	u32 a, b;

	for (unsigned s = 0; s < 3; s++) {
		unsigned sz = 1u << s;
		const char *n = sname[s];

		for (unsigned off = 64; off < 128; off += sz) {
			u32 v = sx(rd(off, sz), sz);

			a = A(off); b = 0;
			r = cop(ld_r[s], a, 0, 0, 0);  CHECK1(n, r.r0, RES32(v), a);
			r = cop(ld_p[s], a, 0, 0, 0);  CHECK1(n, r.r0, RES32(v), a);
			CHECK1("mov @rm+ rm", r.r2, RES32(a + sz), a);
			r = cop(ld_pn[s], a, 0, 0, 0); CHECK1("mov @rm+,rm", r.r0, RES32(v), a);
			/* @(R0,Rm): Rm = buf + 640, R0 negative */
			a = A(640); b = off - 640;
			r = cop(ld_x[s], a, b, 0, 0);  CHECK2(n, r.r0, RES32(v), a, b);
			/* @(R0,Rm): Rm = buf + 32, R0 positive */
			a = A(32); b = off - 32;
			r = cop(ld_x[s], a, b, 0, 0);  CHECK2(n, r.r0, RES32(v), a, b);
			for (unsigned k = 0; k < 4; k++) {
				unsigned d = disp_r[s][k];

				a = A(off);
				r = cop(ld_d[s][k], a, 0, 0, 0);
				CHECK2(n, r.r0, RES32(sx(rd(off + d, sz), sz)), a, d);
				d = disp_g[s][k];
				r = cop(ld_g[s][k], a, 0, 0, 0);
				CHECK2(n, r.r0, RES32(sx(rd(off + d, sz), sz)), a, d);
			}
		}
	}
	for (unsigned k = 0; k < 4; k++) {
		r = cop(ldl_pc[k], 0, 0, 0, 0);
		CHECK1("mov.l @(disp,pc)", r.r0, RES32(ldl_pc_v[k]), k);
		r = cop(ldw_pc[k], 0, 0, 0, 0);
		CHECK1("mov.w @(disp,pc)", r.r0, RES32((s32)(s16)ldw_pc_v[k]), k);
		r = cop(mova[k], 0, 0, 0, 0);
		CHECK1("mova", r.r0, RES32(ADDR(mova_lit[k])), k);
		CHECK1("mova literal", r.r1, RES32(0xa5000000u + k), k);
	}
}

static void stores(u32 v)
{
	static const unsigned offs[] = { 256, 258, 260, 263 };
	struct cres r;
	u32 a, b, c;

	for (unsigned s = 0; s < 3; s++) {
		unsigned sz = 1u << s;
		const char *n = sname[s];

		for (unsigned i = 0; i < 4; i++) {
			unsigned off = offs[i] & ~(sz - 1);

			a = A(off); b = v;
			r = cop(st_r[s], a, b, 0, 0); wr(off, v, sz); chkbuf(n, a, b);
			/* @-Rn: Rn = address + size */
			a = A(off + sz);
			r = cop(st_m[s], a, b, 0, 0); wr(off, v, sz); chkbuf(n, a, b);
			CHECK2("mov @-rn rn", r.r2, RES32(a - sz), a, b);
			/* @(R0,Rn): R0 = c, both signs */
			a = A(640); c = off - 640;
			r = cop(st_x[s], a, b, c, 0); wr(off, v, sz); chkbuf(n, a, c);
			a = A(64); c = off - 64;
			r = cop(st_x[s], a, b, c, 0); wr(off, ~v, sz); wr(off, v, sz); chkbuf(n, a, c);
			for (unsigned k = 0; k < 4; k++) {
				unsigned d = disp_r[s][k];

				a = A(off);
				r = cop(st_d[s][k], a, b, 0, 0); wr(off + d, v, sz); chkbuf(n, a, d);
				d = disp_g[s][k];
				r = cop(st_g[s][k], a, b, 0, 0); wr(off + d, v, sz); chkbuf(n, a, d);
			}
		}
	}
}

ISA_GROUP(mem)
{
	struct cres r;
	u32 a, b, v;

	for (u32 seed = 1; seed <= 6; seed++) {
		fill(seed);
		loads();
	}
	fill(7);
	COP_FOREACH(v)
		stores(v);
	/* Rm = Rn for @-Rn: the stored value is Rn before the decrement */
	for (unsigned s = 0; s < 3; s++) {
		unsigned sz = 1u << s;

		for (unsigned off = 128; off < 160; off += sz) {
			a = A(off + sz);
			r = cop(st_mn[s], a, 0, 0, 0); wr(off, a, sz); chkbuf("mov rn,@-rn", a, 0);
			CHECK1("mov rn,@-rn rn", r.r2, RES32(a - sz), a);
		}
	}

	/* MOVCA.L: only the written long-word is defined afterwards */
	COP_FOREACH(v) {
		unsigned off = 384 + (v & 0x1c);

		a = A(off);
		cop(cop_movca, a, v, 0, 0);
		CHECK2("movca.l", (u64)(buf[off] | buf[off + 1] << 8 | buf[off + 2] << 16 | (u32)buf[off + 3] << 24),
		       (u64)v, a, v);
	}
	fill(8);

	/* GBR, PR, MACH, MACL */
	COP_FOREACH(v) {
		r = cop(cop_ldc_gbr, v, 0, 0, 0); CHECK1("ldc/stc gbr", r.r0, RES32(v), v);
	}
	for (unsigned off = 192; off < 256; off += 4) {
		u32 w = rd(off, 4);

		a = A(off);
		r = cop(cop_ldcl_gbr, a, 0, 0, 0);
		CHECK1("ldc.l gbr", r.r0, RES32(w), a); CHECK1("ldc.l rm", r.r2, RES32(a + 4), a);
		r = cop(cop_ldsl_pr, a, 0, 0, 0);
		CHECK1("lds.l pr", r.r0, RES32(w), a); CHECK1("lds.l pr rm", r.r2, RES32(a + 4), a);
		r = cop(cop_ldsl_mach, a, 0, 0, 0);
		CHECK1("lds.l mach", r.r0, RES32(w), a); CHECK1("lds.l mach rm", r.r2, RES32(a + 4), a);
		r = cop(cop_ldsl_macl, a, 0, 0, 0);
		CHECK1("lds.l macl", r.r0, RES32(w), a); CHECK1("lds.l macl rm", r.r2, RES32(a + 4), a);
	}
	COP_FOREACH(v) {
		static const struct { const u16 *fn; const char *n; } st[] = {
			{ cop_stcl_gbr, "stc.l gbr" }, { cop_stsl_pr, "sts.l pr" },
			{ cop_stsl_mach, "sts.l mach" }, { cop_stsl_macl, "sts.l macl" } };

		for (unsigned k = 0; k < 4; k++) {
			unsigned off = 192 + 4 * k + (v & 0x30);

			a = A(off + 4); b = v;
			r = cop(st[k].fn, a, b, 0, 0); wr(off, v, 4); chkbuf(st[k].n, a, b);
			CHECK2("sts.l/stc.l rn", r.r2, RES32(a - 4), a, b);
		}
	}

	/* #imm, @(R0,GBR) and TAS.B: GBR = a, R0 = b */
	for (unsigned i = 0; i < 64; i++) {
		unsigned off = 512 + i * 3;

		for (unsigned k = 0; k < 5; k++) {
			u8 im = rmw_imm[k], m;

			a = A(512); b = off - 512;
			m = ref[off];
			r = cop(tstb[k], a, b, 0, 0); chkbuf("tst.b", a, b);
			CHECK3("tst.b T", r.r1, (u64)((m & im) == 0), a, b, im);
			r = cop(andb[k], a, b, 0, 0); ref[off] &= im; chkbuf("and.b", a, b);
			r = cop(orb[k], a, b, 0, 0);  ref[off] |= im; chkbuf("or.b", a, b);
			r = cop(xorb[k], a, b, 0, 0); ref[off] ^= im; chkbuf("xor.b", a, b);
			/* GBR negative offset to the same byte */
			a = A(off + 300); b = (u32)-300;
			r = cop(xorb[k], a, b, 0, 0); ref[off] ^= im; chkbuf("xor.b", a, b);
		}
		a = A(off + 1);
		v = ref[off + 1];
		r = cop(cop_tas, a, 0, 0, 0); ref[off + 1] |= 0x80; chkbuf("tas.b", a, 0);
		CHECK1("tas.b T", r.r1, (u64)(v == 0), a);
		r = cop(cop_tas, a, 0, 0, 0); chkbuf("tas.b", a, 0);
		CHECK1("tas.b T", r.r1, 0, a);
	}

	/* PREF, OCBP, OCBWB, OCBI: no exception, memory as stored */
	for (unsigned k = 0; k < 32; k++) {
		unsigned blk = 768 + 32 * (k & 3), w = blk + (k & 0x1c);

		a = A(blk + k); b = A(w); v = 0x5a000000u | (k << 16) | (u32)(blk + k);
		r = cop(cop_pref, a, b, 0, 0); CHECK2("pref", r.r0, RES32(rd(w, 4)), a, b);
		chkbuf("pref", a, b);
		r = cop(cop_ocbp, a, b, v, 0); wr(w, v, 4);
		CHECK2("ocbp", r.r0, RES32(v), a, b); chkbuf("ocbp", a, b);
		v ^= 0xffff;
		r = cop(cop_ocbwb, a, b, v, 0); wr(w, v, 4);
		CHECK2("ocbwb", r.r0, RES32(v), a, b); chkbuf("ocbwb", a, b);
		v = ~v;
		r = cop(cop_ocbi, a, b, v, 0); wr(w, v, 4);
		CHECK2("ocbwb/ocbi", r.r0, RES32(v), a, b); chkbuf("ocbwb/ocbi", a, b);
	}
}
