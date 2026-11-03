/*
 * Loads and stores (Vol. 2 ch. 2): LD.{B,W,L,Q,UB,UW}, LDX.{B,W,L,Q,UB,UW},
 * ST.{B,W,L,Q}, STX.{B,W,L,Q}, LDLO/LDHI/STLO/STHI.{L,Q}, SWAP.Q and the
 * cache hints PREFI, ALLOCO, OCBI, OCBP, OCBWB, ICBI.
 *
 * Everything works on one aligned static buffer whose byte i holds pat(i),
 * a pure function of i, so the expected value of a load is computed from
 * the pattern and the manual's pseudocode without reading memory.  Stores
 * are checked by reading back the three quadwords around the access with a
 * different access size and comparing them against the pattern with the
 * bytes the pseudocode says were written patched in; this also shows that
 * no neighbouring byte was disturbed.  All SH-5 memory tests here assume
 * little endian mode.
 */
#include "harness.h"

#define BUF_SIZE	16384
#define MID		(BUF_SIZE / 2)
/* Highest address used as a base: leaves room for the window after it. */
#define END		(BUF_SIZE - 16)

static u8 buf[BUF_SIZE] __attribute__((aligned(64)));

/* Known contents: byte i of the buffer is pat(i). */
static u8 pat(unsigned i)
{
	u32 h = (i + 1) * 0x9e3779b1u;

	h ^= h >> 15;
	h *= 0x85ebca6bu;
	return (u8)(h ^ (h >> 13) ^ (h >> 24));
}

/* The n bytes at buffer offset @off as a little endian value (MEM[a FOR n]). */
static u64 pat_le(unsigned off, int n)
{
	u64 v = 0;
	int k;

	for (k = 0; k < n; k++)
		v |= (u64)pat(off + k) << (8 * k);
	return v;
}

static void fill(void)
{
	unsigned i;

	for (i = 0; i < BUF_SIZE; i++)
		((volatile u8 *)buf)[i] = pat(i);
}

/* Addresses in registers are sign-extended 32-bit values on SH-5. */
static u64 addr_of(const void *p)
{
	return (u64)(s64)(s32)(unsigned long)p;
}

static unsigned off_of(u64 ea)
{
	return (unsigned)(ea - addr_of(buf));
}

/* ---- inline asm forms; displacements are literals in the string ---- */

#define LDD(insn, base, disp) ({					\
	u64 _r;								\
	__asm__ volatile (insn " %1, " #disp ", %0"			\
			  : "=r"(_r) : "r"((u64)(base)) : "memory");	\
	_r; })

#define STD(insn, base, disp, val)					\
	__asm__ volatile (insn " %0, " #disp ", %1"			\
			  : : "r"((u64)(base)), "r"((u64)(val)) : "memory")

#define LDXR(insn, base, idx) ({					\
	u64 _r;								\
	__asm__ volatile (insn " %1, %2, %0"				\
			  : "=r"(_r) : "r"((u64)(base)), "r"((u64)(idx)) \
			  : "memory");					\
	_r; })

#define STXR(insn, base, idx, val)					\
	__asm__ volatile (insn " %0, %1, %2"				\
			  : : "r"((u64)(base)), "r"((u64)(idx)),	\
			      "r"((u64)(val)) : "memory")

#define CACHEOP(insn, base, disp)					\
	__asm__ volatile (insn " %0, " #disp				\
			  : : "r"((u64)(base)) : "memory")

/*
 * Displacement sets, in bytes (what the assembler takes: immediate after
 * sign extension and scaling).  Each list spans the whole encodable range
 * of its form, including both extremes.
 */
#define DISP_B(X, i) X(i, -512) X(i, -511) X(i, -256) X(i, -17) X(i, -1) \
	X(i, 0) X(i, 1) X(i, 17) X(i, 255) X(i, 256) X(i, 510) X(i, 511)
#define DISP_W(X, i) X(i, -1024) X(i, -1022) X(i, -512) X(i, -34) X(i, -2) \
	X(i, 0) X(i, 2) X(i, 34) X(i, 512) X(i, 1020) X(i, 1022)
#define DISP_L(X, i) X(i, -2048) X(i, -2044) X(i, -1024) X(i, -68) X(i, -4) \
	X(i, 0) X(i, 4) X(i, 68) X(i, 1024) X(i, 2040) X(i, 2044)
#define DISP_Q(X, i) X(i, -4096) X(i, -4088) X(i, -2048) X(i, -136) X(i, -8) \
	X(i, 0) X(i, 8) X(i, 136) X(i, 2048) X(i, 4080) X(i, 4088)
#define DISP_6(X, i) X(i, -32) X(i, -31) X(i, -17) X(i, -9) X(i, -8) X(i, -7) \
	X(i, -3) X(i, -1) X(i, 0) X(i, 1) X(i, 3) X(i, 5) X(i, 7) X(i, 8) \
	X(i, 15) X(i, 16) X(i, 23) X(i, 31)
#define DISP_C(X, i) X(i, -1024) X(i, -992) X(i, -32) X(i, 0) X(i, 32) \
	X(i, 480) X(i, 992)

#define LD_CASE(insn, d)	case d: return LDD(insn, base, d);
#define ST_CASE(insn, d)	case d: STD(insn, base, d, val); return;
#define CO_CASE(insn, d)	case d: CACHEOP(insn, base, d); return;
#define DISP_VAL(insn, d)	d,

#define DEF_LD(fn, insn, LIST)						\
static u64 fn(u64 base, int disp)					\
{									\
	switch (disp) { LIST(LD_CASE, insn) }				\
	return 0xbad0bad0bad0bad0ULL;					\
}
#define DEF_ST(fn, insn, LIST)						\
static void fn(u64 base, int disp, u64 val)				\
{									\
	switch (disp) { LIST(ST_CASE, insn) }				\
}
#define DEF_CO(fn, insn, LIST)						\
static void fn(u64 base, int disp)					\
{									\
	switch (disp) { LIST(CO_CASE, insn) }				\
}

DEF_LD(ld_b,   "ld.b",   DISP_B)
DEF_LD(ld_ub,  "ld.ub",  DISP_B)
DEF_LD(ld_w,   "ld.w",   DISP_W)
DEF_LD(ld_uw,  "ld.uw",  DISP_W)
DEF_LD(ld_l,   "ld.l",   DISP_L)
DEF_LD(ld_q,   "ld.q",   DISP_Q)
DEF_LD(ldlo_l, "ldlo.l", DISP_6)
DEF_LD(ldhi_l, "ldhi.l", DISP_6)
DEF_LD(ldlo_q, "ldlo.q", DISP_6)
DEF_LD(ldhi_q, "ldhi.q", DISP_6)

DEF_ST(st_b,   "st.b",   DISP_B)
DEF_ST(st_w,   "st.w",   DISP_W)
DEF_ST(st_l,   "st.l",   DISP_L)
DEF_ST(st_q,   "st.q",   DISP_Q)
DEF_ST(stlo_l, "stlo.l", DISP_6)
DEF_ST(sthi_l, "sthi.l", DISP_6)
DEF_ST(stlo_q, "stlo.q", DISP_6)
DEF_ST(sthi_q, "sthi.q", DISP_6)

DEF_CO(prefi,  "prefi",  DISP_C)
DEF_CO(alloco, "alloco", DISP_C)
DEF_CO(ocbi,   "ocbi",   DISP_C)
DEF_CO(ocbp,   "ocbp",   DISP_C)
DEF_CO(ocbwb,  "ocbwb",  DISP_C)
DEF_CO(icbi,   "icbi",   DISP_C)

static const int disp_b[] = { DISP_B(DISP_VAL, 0) };
static const int disp_w[] = { DISP_W(DISP_VAL, 0) };
static const int disp_l[] = { DISP_L(DISP_VAL, 0) };
static const int disp_q[] = { DISP_Q(DISP_VAL, 0) };
static const int disp_6[] = { DISP_6(DISP_VAL, 0) };
static const int disp_c[] = { DISP_C(DISP_VAL, 0) };
#define NELEM(a) ((int)(sizeof(a) / sizeof((a)[0])))

/* ---- reference semantics, from the pseudocode, little endian ---- */

/* Loaded value of LD/LDX of @size bytes at buffer offset @off. */
static u64 ref_ld(unsigned off, int size, int sign)
{
	u64 mem = pat_le(off, size);

	switch (size) {
	case 1: return sign ? (u64)SignExtend8(mem) : ZeroExtend8(mem);
	case 2: return sign ? (u64)SignExtend16(mem) : ZeroExtend16(mem);
	case 4: return sign ? (u64)SignExtend32(mem) : ZeroExtend32(mem);
	default: return mem;
	}
}

/* LDLO.L: bytecount = 4 - (addr & 3); mem = ReadMemoryLow; ZeroExtend32. */
static u64 ref_ldlo_l(unsigned off)
{
	int bytecount = 4 - (off & 3);

	return ZeroExtend32(pat_le(off, bytecount));
}

/* LDHI.L: bytecount = (addr & 3) + 1; shift = ZeroExtend5(~(addr & 3) * 8);
 * mem = ReadMemoryHigh (addr is the highest byte); SignExtend32(mem << shift). */
static u64 ref_ldhi_l(unsigned off)
{
	int bytecount = (off & 3) + 1;
	unsigned shift = ((~(off & 3)) * 8) & 31;
	u64 mem = pat_le(off - bytecount + 1, bytecount);

	return (u64)SignExtend32(mem << shift);
}

/* LDLO.Q: bytecount = 8 - (addr & 7); ZeroExtend64(mem). */
static u64 ref_ldlo_q(unsigned off)
{
	int bytecount = 8 - (off & 7);

	return pat_le(off, bytecount);
}

/* LDHI.Q: bytecount = (addr & 7) + 1; shift = ZeroExtend6(~(addr & 7) * 8);
 * ZeroExtend64(mem << shift). */
static u64 ref_ldhi_q(unsigned off)
{
	int bytecount = (off & 7) + 1;
	unsigned shift = ((~(off & 7)) * 8) & 63;
	u64 mem = pat_le(off - bytecount + 1, bytecount);

	return mem << shift;
}

/*
 * Store windows: the quadword containing buffer offset @off and its two
 * neighbours (24 bytes from win_base(off)).  @want is built from the
 * pattern and patched by the ref_st_* functions.
 */
#define WIN 24

static unsigned win_base(unsigned off)
{
	return (off & ~7u) - 8;
}

static void win_restore(unsigned off, u8 *want)
{
	unsigned w = win_base(off);
	int i;

	for (i = 0; i < WIN; i++) {
		((volatile u8 *)buf)[w + i] = pat(w + i);
		want[i] = pat(w + i);
	}
}

/* MEM[off FOR n] <- value<0 FOR 8n> */
static void put_bytes(u8 *want, unsigned woff, unsigned off, int n, u64 value)
{
	int k;

	for (k = 0; k < n; k++)
		want[off - woff + k] = (u8)(value >> (8 * k));
}

/* ST/STX of @size bytes: the lowest 8*size bits of Ry go to addr. */
static void ref_st(u8 *want, unsigned off, int size, u64 v)
{
	put_bytes(want, win_base(off), off, size, v);
}

/* STLO.L: bytecount = 4 - (addr & 3); start = 0 (LE);
 * WriteMemoryLow(addr, ZeroExtend(ZeroExtend32(Ry) >> start)). */
static void ref_stlo_l(u8 *want, unsigned off, u64 v)
{
	int bytecount = 4 - (off & 3);

	put_bytes(want, win_base(off), off, bytecount, ZeroExtend32(v) >> 0);
}

/* STHI.L: bytecount = (addr & 3) + 1; start = 32 - bitcount (LE);
 * WriteMemoryHigh(addr, ...): addr is the highest byte written. */
static void ref_sthi_l(u8 *want, unsigned off, u64 v)
{
	int bytecount = (off & 3) + 1;
	int start = 32 - bytecount * 8;

	put_bytes(want, win_base(off), off - bytecount + 1, bytecount,
		  ZeroExtend32(v) >> start);
}

/* STLO.Q: bytecount = 8 - (addr & 7); start = 0 (LE). */
static void ref_stlo_q(u8 *want, unsigned off, u64 v)
{
	int bytecount = 8 - (off & 7);

	put_bytes(want, win_base(off), off, bytecount, v >> 0);
}

/* STHI.Q: bytecount = (addr & 7) + 1; start = 64 - bitcount (LE). */
static void ref_sthi_q(u8 *want, unsigned off, u64 v)
{
	int bytecount = (off & 7) + 1;
	int start = 64 - bytecount * 8;

	put_bytes(want, win_base(off), off - bytecount + 1, bytecount,
		  v >> start);
}

/* Read quadword @q (0..2) of the window at @w with accesses of @rsize bytes. */
static u64 win_read(unsigned w, int q, int rsize)
{
	u64 v = 0;
	int k;

	switch (rsize) {
	case 8:
		return *(volatile u64 *)(buf + w + 8 * q);
	case 4:
		v = *(volatile u32 *)(buf + w + 8 * q);
		v |= (u64)*(volatile u32 *)(buf + w + 8 * q + 4) << 32;
		return v;
	default:
		for (k = 0; k < 8; k++)
			v |= (u64)((volatile u8 *)buf)[w + 8 * q + k] << (8 * k);
		return v;
	}
}

static u64 le64(const u8 *p)
{
	u64 v = 0;
	int k;

	for (k = 0; k < 8; k++)
		v |= (u64)p[k] << (8 * k);
	return v;
}

/* Three checks "<insn>[q-1]", "<insn>[q0]", "<insn>[q+1]" with a=offset
 * of the access, b=value stored, c=displacement or index.  The window is
 * then put back to the pattern. */
static void win_check(const char *insn, unsigned off, u8 *want,
		      int rsize, u64 value, u64 dispidx)
{
	static const char *const suffix[3] = { "[q-1]", "[q0]", "[q+1]" };
	char name[48];
	unsigned w = win_base(off);
	int q, i, j;

	for (q = 0; q < 3; q++) {
		for (i = 0; insn[i] && i < 40; i++)
			name[i] = insn[i];
		for (j = 0; suffix[q][j]; j++)
			name[i++] = suffix[q][j];
		name[i] = 0;
		isa_check(__FILE__, __LINE__, name, win_read(w, q, rsize),
			  le64(want + 8 * q), 3, off, value, dispidx);
	}
	win_restore(off, want);
}

/* Whole-buffer checksum (read with LD.Q) and the same over the pattern. */
static u64 checksum_mem(void)
{
	u64 s = 0;
	unsigned i;

	for (i = 0; i < BUF_SIZE; i += 8)
		s = s * 0x100000001b3ULL + *(volatile u64 *)(buf + i);
	return s;
}

static u64 checksum_pat(void)
{
	u64 s = 0;
	unsigned i;

	for (i = 0; i < BUF_SIZE; i += 8)
		s = s * 0x100000001b3ULL + pat_le(i, 8);
	return s;
}

/* ---- the tests ---- */

struct ldform {
	const char *name;
	u64 (*fn)(u64 base, int disp);
	const int *disps;
	int ndisps, size, sign;
};

static const struct ldform ldforms[] = {
	{ "ld.b",  ld_b,  disp_b, NELEM(disp_b), 1, 1 },
	{ "ld.ub", ld_ub, disp_b, NELEM(disp_b), 1, 0 },
	{ "ld.w",  ld_w,  disp_w, NELEM(disp_w), 2, 1 },
	{ "ld.uw", ld_uw, disp_w, NELEM(disp_w), 2, 0 },
	{ "ld.l",  ld_l,  disp_l, NELEM(disp_l), 4, 1 },
	{ "ld.q",  ld_q,  disp_q, NELEM(disp_q), 8, 0 },
};

/* Base register offsets from the middle of the buffer, in access units. */
static const int base_units[] = { 0, 1, 2, 3, 5, 8, 13, 21, -1, -2, -7, -100 };

static void test_ld_disp(void)
{
	const u64 mid = addr_of(buf + MID);
	int f, d, j;

	for (f = 0; f < NELEM(ldforms); f++) {
		const struct ldform *t = &ldforms[f];

		for (d = 0; d < t->ndisps; d++)
			for (j = 0; j < NELEM(base_units); j++) {
				u64 base = mid + (s64)base_units[j] * t->size;
				int disp = t->disps[d];
				unsigned off = off_of(base + disp);

				CHECK2(t->name, t->fn(base, disp),
				       ref_ld(off, t->size, t->sign),
				       off, (u64)(s64)disp);
			}
	}
}

/* Indexed loads: address = ZeroExtend64(Rm) + SignExtend64(Rn). */
struct ldxform {
	const char *name;
	int size, sign;
};

static const struct ldxform ldxforms[] = {
	{ "ldx.b", 1, 1 }, { "ldx.ub", 1, 0 }, { "ldx.w", 2, 1 },
	{ "ldx.uw", 2, 0 }, { "ldx.l", 4, 1 }, { "ldx.q", 8, 0 },
};

static u64 do_ldx(const char *name, u64 base, u64 idx)
{
	switch (name[4]) {
	case 'b': return LDXR("ldx.b", base, idx);
	case 'w': return LDXR("ldx.w", base, idx);
	case 'l': return LDXR("ldx.l", base, idx);
	case 'q': return LDXR("ldx.q", base, idx);
	default:
		if (name[5] == 'b')
			return LDXR("ldx.ub", base, idx);
		return LDXR("ldx.uw", base, idx);
	}
}

static void do_stx(const char *name, u64 base, u64 idx, u64 val)
{
	switch (name[4]) {
	case 'b': STXR("stx.b", base, idx, val); break;
	case 'w': STXR("stx.w", base, idx, val); break;
	case 'l': STXR("stx.l", base, idx, val); break;
	default:  STXR("stx.q", base, idx, val); break;
	}
}

/* Index values in access units, both signs, up to the buffer extremes. */
static const int idx_units[] = { 0, 1, -1, 2, -2, 3, -3, 13, -13, 100, -100,
				 511, -512, 1000, -1000 };

static void test_ldx(void)
{
	const u64 mid = addr_of(buf + MID);
	const u64 end = addr_of(buf + END);
	const u64 start = addr_of(buf);
	int f, j;

	for (f = 0; f < NELEM(ldxforms); f++) {
		const struct ldxform *t = &ldxforms[f];

		for (j = 0; j < NELEM(idx_units); j++) {
			u64 idx = (u64)((s64)idx_units[j] * t->size);
			unsigned off = off_of(mid + idx);

			CHECK2(t->name, do_ldx(t->name, mid, idx),
			       ref_ld(off, t->size, t->sign), off, idx);
			/* Rm and Rn swapped: the sum is the same. */
			CHECK2(t->name, do_ldx(t->name, idx, mid),
			       ref_ld(off, t->size, t->sign), off, mid);
		}
		/* From the end of the buffer with a negative index. */
		for (j = 1; j <= 8; j++) {
			u64 idx = (u64)(-(s64)j * t->size);
			unsigned off = off_of(end + idx);

			CHECK2(t->name, do_ldx(t->name, end, idx),
			       ref_ld(off, t->size, t->sign), off, idx);
		}
		/* From the start with a positive index, index in Rm. */
		for (j = 0; j < 8; j++) {
			u64 idx = (u64)j * t->size * 7;
			unsigned off = off_of(start + idx);

			CHECK2(t->name, do_ldx(t->name, idx, start),
			       ref_ld(off, t->size, t->sign), off, idx);
		}
	}
}

/* Store a corpus value and read it back with every narrow load. */
static void test_extension(void)
{
	const u64 base = addr_of(buf + MID + 64);
	u8 want[WIN];
	u64 v;

	ISA_FOREACH_OPERAND(v) {
		win_restore(MID + 64, want);
		STD("st.q", base, 0, v);
		CHECK1("ld.b",   LDD("ld.b", base, 0),  (u64)SignExtend8(v),  v);
		CHECK1("ld.ub",  LDD("ld.ub", base, 0), ZeroExtend8(v),       v);
		CHECK1("ld.w",   LDD("ld.w", base, 0),  (u64)SignExtend16(v), v);
		CHECK1("ld.uw",  LDD("ld.uw", base, 0), ZeroExtend16(v),      v);
		CHECK1("ld.l",   LDD("ld.l", base, 0),  (u64)SignExtend32(v), v);
		CHECK1("ld.q",   LDD("ld.q", base, 0),  v,                    v);
		/* Same through the indexed forms with a negative index. */
		CHECK1("ldx.b",  LDXR("ldx.b", base + 8, -8),  (u64)SignExtend8(v),  v);
		CHECK1("ldx.ub", LDXR("ldx.ub", base + 8, -8), ZeroExtend8(v),       v);
		CHECK1("ldx.w",  LDXR("ldx.w", base + 8, -8),  (u64)SignExtend16(v), v);
		CHECK1("ldx.uw", LDXR("ldx.uw", base + 8, -8), ZeroExtend16(v),      v);
		CHECK1("ldx.l",  LDXR("ldx.l", base + 8, -8),  (u64)SignExtend32(v), v);
		CHECK1("ldx.q",  LDXR("ldx.q", base + 8, -8),  v,                    v);
		/* The upper bytes of the register are ignored by narrow stores. */
		win_restore(MID + 64, want);
		STD("st.b", base, 0, v);
		CHECK1("st.b/ld.q", LDD("ld.q", base, 0),
		       (le64(want + 8) & ~0xffULL) | ZeroExtend8(v), v);
		STD("st.w", base, 0, v);
		CHECK1("st.w/ld.q", LDD("ld.q", base, 0),
		       (le64(want + 8) & ~0xffffULL) | ZeroExtend16(v), v);
		STD("st.l", base, 0, v);
		CHECK1("st.l/ld.q", LDD("ld.q", base, 0),
		       (le64(want + 8) & ~0xffffffffULL) | ZeroExtend32(v), v);
	}
	win_restore(MID + 64, want);
}

struct stform {
	const char *name;
	void (*fn)(u64 base, int disp, u64 val);
	const int *disps;
	int ndisps, size;
};

static const struct stform stforms[] = {
	{ "st.b", st_b, disp_b, NELEM(disp_b), 1 },
	{ "st.w", st_w, disp_w, NELEM(disp_w), 2 },
	{ "st.l", st_l, disp_l, NELEM(disp_l), 4 },
	{ "st.q", st_q, disp_q, NELEM(disp_q), 8 },
};

static const int st_base_units[] = { 0, 1, -3 };

static u64 st_value(int k)
{
	switch (k) {
	case 0: return 0x0123456789abcdefULL;
	case 1: return 0xfedcba9876543210ULL;
	default: return isa_rand();
	}
}

static void test_st_disp(void)
{
	const u64 mid = addr_of(buf + MID);
	u8 want[WIN];
	int f, d, j, k;

	for (f = 0; f < NELEM(stforms); f++) {
		const struct stform *t = &stforms[f];
		int rsize = t->size == 8 ? 4 : 8;

		for (d = 0; d < t->ndisps; d++)
			for (j = 0; j < NELEM(st_base_units); j++)
				for (k = 0; k < 3; k++) {
					u64 base = mid + (s64)st_base_units[j] * t->size;
					int disp = t->disps[d];
					unsigned off = off_of(base + disp);
					u64 v = st_value(k);

					win_restore(off, want);
					t->fn(base, disp, v);
					ref_st(want, off, t->size, v);
					win_check(t->name, off, want, rsize, v,
						  (u64)(s64)disp);
				}
	}
}

static const char *const stxnames[] = { "stx.b", "stx.w", "stx.l", "stx.q" };
static const int stxsizes[] = { 1, 2, 4, 8 };

static void test_stx(void)
{
	const u64 mid = addr_of(buf + MID);
	const u64 end = addr_of(buf + END);
	u8 want[WIN];
	int f, j, k;

	for (f = 0; f < 4; f++) {
		int size = stxsizes[f], rsize = size == 8 ? 4 : 8;

		for (j = 0; j < NELEM(idx_units); j++)
			for (k = 0; k < 3; k++) {
				u64 idx = (u64)((s64)idx_units[j] * size);
				unsigned off = off_of(mid + idx);
				u64 v = st_value(k);

				win_restore(off, want);
				if (k == 1)	/* operands swapped */
					do_stx(stxnames[f], idx, mid, v);
				else
					do_stx(stxnames[f], mid, idx, v);
				ref_st(want, off, size, v);
				win_check(stxnames[f], off, want, rsize, v, idx);
			}
		for (j = 1; j <= 4; j++) {
			u64 idx = (u64)(-(s64)j * size);
			unsigned off = off_of(end + idx);
			u64 v = isa_rand();

			win_restore(off, want);
			do_stx(stxnames[f], end, idx, v);
			ref_st(want, off, size, v);
			win_check(stxnames[f], off, want, rsize, v, idx);
		}
	}
}

/*
 * LDLO/LDHI: every displacement in the 6-bit range combined with base
 * offsets 0..7 (and a few more), so every low-3-bit alignment is reached
 * through several displacements, positive and negative.
 */
static const int mis_base[] = { 0, 1, 2, 3, 4, 5, 6, 7, 9, 14, 100, -1, -5, -200 };

static void test_ldlohi(void)
{
	const u64 mid = addr_of(buf + MID);
	int d, j;

	for (d = 0; d < NELEM(disp_6); d++)
		for (j = 0; j < NELEM(mis_base); j++) {
			u64 base = mid + (s64)mis_base[j];
			int disp = disp_6[d];
			unsigned off = off_of(base + disp);
			u64 ud = (u64)(s64)disp;

			CHECK2("ldlo.l", ldlo_l(base, disp), ref_ldlo_l(off), off, ud);
			CHECK2("ldhi.l", ldhi_l(base, disp), ref_ldhi_l(off), off, ud);
			CHECK2("ldlo.q", ldlo_q(base, disp), ref_ldlo_q(off), off, ud);
			CHECK2("ldhi.q", ldhi_q(base, disp), ref_ldhi_q(off), off, ud);
		}

	/* The documented idiom: LDLO at A, LDHI at A+3 / A+7, OR gives the
	 * misaligned long/quad word at A (sign-extended for .L). */
	for (j = 0; j < 64; j++) {
		unsigned off = MID + 1000 + j;
		u64 base = mid + 1000 + j;
		u64 l = ldlo_l(base, 0) | ldhi_l(base, 3);
		u64 q = ldlo_q(base, 0) | ldhi_q(base, 7);

		CHECK1("ldlo.l|ldhi.l", l, (u64)SignExtend32(pat_le(off, 4)), off);
		CHECK1("ldlo.q|ldhi.q", q, pat_le(off, 8), off);
	}
}

static void test_stlohi(void)
{
	const u64 mid = addr_of(buf + MID);
	u8 want[WIN];
	int d, j, k;

	for (d = 0; d < NELEM(disp_6); d++)
		for (j = 0; j < NELEM(mis_base); j++)
			for (k = 0; k < 3; k++) {
				u64 base = mid + (s64)mis_base[j];
				int disp = disp_6[d];
				unsigned off = off_of(base + disp);
				u64 ud = (u64)(s64)disp;
				u64 v = st_value(k);

				win_restore(off, want);
				stlo_l(base, disp, v);
				ref_stlo_l(want, off, v);
				win_check("stlo.l", off, want, 8, v, ud);

				win_restore(off, want);
				sthi_l(base, disp, v);
				ref_sthi_l(want, off, v);
				win_check("sthi.l", off, want, 8, v, ud);

				win_restore(off, want);
				stlo_q(base, disp, v);
				ref_stlo_q(want, off, v);
				win_check("stlo.q", off, want, 4, v, ud);

				win_restore(off, want);
				sthi_q(base, disp, v);
				ref_sthi_q(want, off, v);
				win_check("sthi.q", off, want, 4, v, ud);
			}

	/* The documented idiom: STLO at A, STHI at A+3 / A+7 stores the
	 * misaligned long/quad word at A. */
	for (j = 0; j < 64; j++) {
		unsigned off = MID + 2000 + j;
		u64 base = mid + 2000 + j;
		u64 v = isa_rand();

		win_restore(off, want);
		stlo_l(base, 0, v);
		sthi_l(base, 3, v);
		ref_st(want, off, 4, v);
		win_check("stlo.l+sthi.l", off, want, 1, v, 0);

		win_restore(off, want);
		stlo_q(base, 0, v);
		sthi_q(base, 7, v);
		ref_st(want, off, 8, v);
		win_check("stlo.q+sthi.q", off, want, 1, v, 0);
	}
}

/* SWAP.Q: Rw <- MEM[Rm + Rn]; MEM[Rm + Rn] <- old Rw, atomically. */
static void test_swap(void)
{
	const u64 mid = addr_of(buf + MID);
	static const int swap_idx[] = { 0, 8, -8, 2048, -4096, 4088 };
	u8 want[WIN];
	u64 v;
	int j;

	ISA_FOREACH_OPERAND(v) {
		for (j = 0; j < NELEM(swap_idx); j++) {
			u64 idx = (u64)(s64)swap_idx[j];
			unsigned off = off_of(mid + idx);
			u64 w = v;

			win_restore(off, want);
			__asm__ volatile ("swap.q %1, %2, %0"
					  : "+r"(w) : "r"(mid), "r"(idx) : "memory");
			CHECK2("swap.q", w, pat_le(off, 8), off, v);
			ref_st(want, off, 8, v);
			win_check("swap.q", off, want, 4, v, idx);
			/* Rm/Rn exchanged: put v in, then take it out again;
			 * the second swap must return exactly what the first
			 * one wrote and leave the pattern in memory. */
			w = v;
			__asm__ volatile ("swap.q %1, %2, %0"
					  : "+r"(w) : "r"(idx), "r"(mid) : "memory");
			CHECK2("swap.q swapped-operands", w, pat_le(off, 8), off, v);
			w = pat_le(off, 8);
			__asm__ volatile ("swap.q %1, %2, %0"
					  : "+r"(w) : "r"(idx), "r"(mid) : "memory");
			CHECK2("swap.q back", w, v, off, v);
			CHECK2("swap.q back mem", win_read(win_base(off), 1, 1),
			       pat_le(off, 8), off, v);
		}
	}
}

/*
 * Cache instructions have no architecturally visible result.  Each is run
 * on a (misaligned, allowed) address in the buffer with every displacement
 * and the whole buffer is then checksummed against the pattern.  The target
 * block is written first so it is dirty in a real cache; before OCBI it is
 * written back, because OCBI discards dirty data.  ALLOCO leaves the block
 * architecturally undefined, so the block is rewritten before the check.
 */
struct coform {
	const char *name;
	void (*fn)(u64 base, int disp);
};

static const struct coform coforms[] = {
	{ "prefi", prefi }, { "alloco", alloco }, { "ocbi", ocbi },
	{ "ocbp", ocbp }, { "ocbwb", ocbwb }, { "icbi", icbi },
};

static void write_block(unsigned off)
{
	unsigned b = off & ~31u, i;

	for (i = 0; i < 32; i++)
		((volatile u8 *)buf)[b + i] = pat(b + i);
}

static void test_cache(u64 want_sum)
{
	const u64 base = addr_of(buf + MID + 5);
	int f, d;

	for (f = 0; f < NELEM(coforms); f++)
		for (d = 0; d < NELEM(disp_c); d++) {
			int disp = disp_c[d];
			unsigned off = off_of(base + disp);

			write_block(off);
			if (coforms[f].fn == ocbi) {
				ocbwb(base, disp);
				__asm__ volatile ("synco" ::: "memory");
			}
			coforms[f].fn(base, disp);
			__asm__ volatile ("synco" ::: "memory");
			if (coforms[f].fn == alloco)
				write_block(off);
			CHECK2(coforms[f].name, checksum_mem(), want_sum, off,
			       (u64)(s64)disp);
		}
}

ISA_GROUP(loadstore)
{
	u64 want_sum;

	fill();
	want_sum = checksum_pat();
	CHECK0("buffer pattern", checksum_mem(), want_sum);

	test_ld_disp();
	test_ldx();
	test_extension();
	test_st_disp();
	test_stx();
	test_ldlohi();
	test_stlohi();
	test_swap();
	/* Everything above restored what it wrote. */
	CHECK0("buffer intact after stores", checksum_mem(), want_sum);
	test_cache(want_sum);
}
