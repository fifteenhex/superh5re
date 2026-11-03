/*
 * Control flow: PTA, PTABS, PTREL, GETTR, BLINK, BEQ, BNE, BGE, BGT, BGEU,
 * BGTU, BEQI, BNEI, NOP (Vol. 2 ch. 2).  PTB is not tested: it prepares an
 * SHcompact target and the emulator does not implement SHcompact.
 *
 * Addresses: the SH-5 implements neff = 32 effective address bits, so PC
 * and the target registers hold the sign extension of a 32-bit address
 * (Vol. 1, "Effective address representation"; GETTR returns the sign
 * extension of the highest implemented bit).  The reference label
 * addresses below are loaded with movi/shori, which produce exactly that
 * sign-extended form; "datalabel" asks gas for the raw address without
 * the ISA bit it otherwise sets on SHmedia code labels.
 */
#include "harness.h"

#define STR_(x) #x
#define STR(x) STR_(x)

/* Values written on the two paths of a conditional branch. */
#define TAKEN		0x11
#define NOT_TAKEN	0x22
#define WANT(cond)	((cond) ? (u64)TAKEN : (u64)NOT_TAKEN)

/*
 * Forward conditional branch with the target just past the asm block:
 *	pta 1f, tr0
 *	pta 2f, tr1
 *	<cmp> ..., tr0		the branch under test
 *	movi NOT_TAKEN, rd	fall-through path
 *	blink tr1, r63		skip the taken block
 * 1:	movi TAKEN, rd		taken path
 * 2:
 */
#define BRANCH_ASM(cmp, out, ...)					\
	__asm__ volatile (						\
		"pta 1f, tr0\n\t"					\
		"pta 2f, tr1\n\t"					\
		cmp "\n\t"						\
		"movi " STR(NOT_TAKEN) ", %0\n\t"			\
		"blink tr1, r63\n"					\
		"1:\tmovi " STR(TAKEN) ", %0\n"				\
		"2:"							\
		: "=&r"(out) : __VA_ARGS__ : "tr0", "tr1")

/* insn Rm, Rn, TRc */
#define BRANCH_RR(insn, a, b) ({					\
	u64 _r, _a = (a), _b = (b);					\
	BRANCH_ASM(insn " %1, %2, tr0", _r, "r"(_a), "r"(_b));		\
	_r; })

/* insn Rm, r63, TRc */
#define BRANCH_R63(insn, a) ({						\
	u64 _r, _a = (a);						\
	BRANCH_ASM(insn " %1, r63, tr0", _r, "r"(_a));			\
	_r; })

/* insn Rm, #imm, TRc with a literal immediate */
#define BRANCH_RI(insn, a, imm) ({					\
	u64 _r, _a = (a);						\
	BRANCH_ASM(insn " %1, " #imm ", tr0", _r, "r"(_a));		\
	_r; })

/* Both hint forms of one register-register branch. */
#define CHECK_BRANCH(name, cond, a, b) do {				\
	CHECK2(name "/l", BRANCH_RR(name "/l", a, b), WANT(cond), a, b); \
	CHECK2(name "/u", BRANCH_RR(name "/u", a, b), WANT(cond), a, b); \
} while (0)

/* Both hint forms of BEQI/BNEI with one literal immediate (-32..31). */
#define CHECK_BRANCH_I(name, op, a, imm) do {				\
	u64 _ia = (a);							\
	CHECK2(name " " #imm "/l", BRANCH_RI(name "/l", _ia, imm),	\
	       WANT((s64)_ia op (s64)(imm)), _ia, (u64)(s64)(imm));	\
	CHECK2(name " " #imm "/u", BRANCH_RI(name "/u", _ia, imm),	\
	       WANT((s64)_ia op (s64)(imm)), _ia, (u64)(s64)(imm));	\
} while (0)

/* The 64-bit comparisons from the manual's pseudocode (SignExtend64 or
 * ZeroExtend64 of both operands, then compare). */
static void test_cond_pair(u64 a, u64 b)
{
	CHECK_BRANCH("beq", a == b, a, b);
	CHECK_BRANCH("bne", a != b, a, b);
	CHECK_BRANCH("bge", (s64)a >= (s64)b, a, b);
	CHECK_BRANCH("bgt", (s64)a > (s64)b, a, b);
	CHECK_BRANCH("bgeu", a >= b, a, b);
	CHECK_BRANCH("bgtu", a > b, a, b);
}

/* Several immediates, including negative ones, for one operand. */
static void test_cond_imm(u64 a)
{
	CHECK_BRANCH_I("beqi", ==, a, 0);
	CHECK_BRANCH_I("beqi", ==, a, 1);
	CHECK_BRANCH_I("beqi", ==, a, 2);
	CHECK_BRANCH_I("beqi", ==, a, 31);
	CHECK_BRANCH_I("beqi", ==, a, -1);
	CHECK_BRANCH_I("beqi", ==, a, -2);
	CHECK_BRANCH_I("beqi", ==, a, -17);
	CHECK_BRANCH_I("beqi", ==, a, -32);
	CHECK_BRANCH_I("bnei", !=, a, 0);
	CHECK_BRANCH_I("bnei", !=, a, 1);
	CHECK_BRANCH_I("bnei", !=, a, 2);
	CHECK_BRANCH_I("bnei", !=, a, 31);
	CHECK_BRANCH_I("bnei", !=, a, -1);
	CHECK_BRANCH_I("bnei", !=, a, -2);
	CHECK_BRANCH_I("bnei", !=, a, -17);
	CHECK_BRANCH_I("bnei", !=, a, -32);
}

/*
 * Backward branches: count up from 0 while "insn x, y, tr0" branches back
 * to the loop head.  x and y are "%0" (the counter), "%1" (n) or a
 * literal immediate.
 *	pta 1f, tr0
 *	movi 0, rd
 * 1:	addi rd, 1, rd
 *	insn x, y, tr0
 */
#define BRANCH_LOOP(insn, x, y, n) ({					\
	u64 _r, _n = (n);						\
	__asm__ volatile (						\
		"pta 1f, tr0\n\t"					\
		"movi 0, %0\n"						\
		"1:\taddi %0, 1, %0\n\t"				\
		insn " " x ", " y ", tr0"				\
		: "=&r"(_r) : "r"(_n) : "tr0");				\
	_r; })

/* Reference for BRANCH_LOOP: @cond uses c (counter) and n. */
#define LOOP_REF(cond) ({						\
	u64 c = 0;							\
	do c++; while ((cond) && c < 100000);				\
	c; })

static void test_backward(void)
{
	static const u64 pos[] = { 1, 2, 3, 10, 100, 1000 };
	static const u64 small[] = { 0, 1, 5, 100 };
	static const u64 neg[] = { (u64)-1, (u64)-100 };
	unsigned i;
	u64 n;

	for (i = 0; i < sizeof(pos) / sizeof(pos[0]); i++) {
		n = pos[i];
		CHECK1("bne count,n loop", BRANCH_LOOP("bne", "%0", "%1", n),
		       LOOP_REF(c != n), n);
		CHECK1("bne/u n,count loop", BRANCH_LOOP("bne/u", "%1", "%0", n),
		       LOOP_REF(n != c), n);
	}
	for (i = 0; i < sizeof(small) / sizeof(small[0]); i++) {
		n = small[i];
		CHECK1("bgt n,count loop", BRANCH_LOOP("bgt", "%1", "%0", n),
		       LOOP_REF((s64)n > (s64)c), n);
		CHECK1("bgt/u n,count loop", BRANCH_LOOP("bgt/u", "%1", "%0", n),
		       LOOP_REF((s64)n > (s64)c), n);
		CHECK1("bge n,count loop", BRANCH_LOOP("bge", "%1", "%0", n),
		       LOOP_REF((s64)n >= (s64)c), n);
		CHECK1("bge/u n,count loop", BRANCH_LOOP("bge/u", "%1", "%0", n),
		       LOOP_REF((s64)n >= (s64)c), n);
		CHECK1("bgtu n,count loop", BRANCH_LOOP("bgtu", "%1", "%0", n),
		       LOOP_REF(n > c), n);
		CHECK1("bgtu/u n,count loop", BRANCH_LOOP("bgtu/u", "%1", "%0", n),
		       LOOP_REF(n > c), n);
		CHECK1("bgeu n,count loop", BRANCH_LOOP("bgeu", "%1", "%0", n),
		       LOOP_REF(n >= c), n);
		CHECK1("bgeu/u n,count loop", BRANCH_LOOP("bgeu/u", "%1", "%0", n),
		       LOOP_REF(n >= c), n);
		CHECK1("beq count,n loop", BRANCH_LOOP("beq", "%0", "%1", n),
		       LOOP_REF(c == n), n);
		CHECK1("beq/u count,n loop", BRANCH_LOOP("beq/u", "%0", "%1", n),
		       LOOP_REF(c == n), n);
	}
	/* Negative n: the signed forms stop at once, the unsigned ones
	 * would never stop and are not run. */
	for (i = 0; i < sizeof(neg) / sizeof(neg[0]); i++) {
		n = neg[i];
		CHECK1("bgt n,count loop", BRANCH_LOOP("bgt", "%1", "%0", n),
		       LOOP_REF((s64)n > (s64)c), n);
		CHECK1("bge n,count loop", BRANCH_LOOP("bge", "%1", "%0", n),
		       LOOP_REF((s64)n >= (s64)c), n);
	}
	/* Immediate forms: the counter only ever takes positive values. */
	CHECK1("beqi count,0 loop", BRANCH_LOOP("beqi", "%0", "0", 0),
	       LOOP_REF(c == 0), 0);
	CHECK1("beqi count,1 loop", BRANCH_LOOP("beqi", "%0", "1", 1),
	       LOOP_REF(c == 1), 1);
	CHECK1("beqi/u count,1 loop", BRANCH_LOOP("beqi/u", "%0", "1", 1),
	       LOOP_REF(c == 1), 1);
	CHECK1("bnei count,1 loop", BRANCH_LOOP("bnei", "%0", "1", 1),
	       LOOP_REF(c != 1), 1);
	CHECK1("bnei count,3 loop", BRANCH_LOOP("bnei", "%0", "3", 3),
	       LOOP_REF(c != 3), 3);
	CHECK1("bnei/u count,31 loop", BRANCH_LOOP("bnei/u", "%0", "31", 31),
	       LOOP_REF(c != 31), 31);
}

/*
 * A far target for PTA and for a BLINK call: entered with the return
 * address in r18, writes 0x5a to r0 and returns.  Top-level asm so that
 * the register usage is known (PTA reaches +-128 KB, the kit is smaller).
 */
__asm__(
	"\t.text\n"
	"\t.align 2\n"
	"isa_branch_far_target:\n"
	"\tmovi 0x5a, r0\n"
	"\tptabs r18, tr1\n"
	"\tblink tr1, r63\n");

static void test_pt(void)
{
	u64 got, lbl, x, d;
	unsigned i;

	/* PTA label, TRa: TRa = PC + (SignExtend16(s) << 2) + 1 = label | 1.
	 * Forward and backward labels, both hints and the plain "pt". */
	__asm__ volatile (
		"pta/l 1f, tr0\n\t"
		"gettr tr0, %0\n\t"
		"movi datalabel 1f, %1\n"
		"1:" : "=&r"(got), "=&r"(lbl) : : "tr0");
	CHECK1("pta/l fwd gettr", got, lbl + 1, lbl);
	__asm__ volatile (
		"pta/u 1f, tr1\n\t"
		"gettr tr1, %0\n\t"
		"movi datalabel 1f, %1\n"
		"1:" : "=&r"(got), "=&r"(lbl) : : "tr1");
	CHECK1("pta/u fwd gettr", got, lbl + 1, lbl);
	__asm__ volatile (
		"1:\tnop\n\t"
		"pta 1b, tr2\n\t"
		"gettr tr2, %0\n\t"
		"movi datalabel 1b, %1\n"
		: "=&r"(got), "=&r"(lbl) : : "tr2");
	CHECK1("pta bwd gettr", got, lbl + 1, lbl);
	__asm__ volatile (
		"1:\tpt 1b, tr3\n\t"
		"gettr tr3, %0\n\t"
		"movi datalabel 1b, %1\n"
		: "=&r"(got), "=&r"(lbl) : : "tr3");
	CHECK1("pt self gettr", got, lbl + 1, lbl);
	__asm__ volatile (
		"pta isa_branch_far_target, tr0\n\t"
		"gettr tr0, %0\n\t"
		"movi datalabel isa_branch_far_target, %1\n"
		: "=&r"(got), "=&r"(lbl) : : "tr0");
	CHECK1("pta far gettr", got, lbl + 1, lbl);

	/* PTABS Rn, TRa: TRa = Rn.  Only valid targets: sign-extended 32-bit
	 * addresses whose low two bits are not both set (else IADDERR). */
	for (i = 0; i < isa_num_operands + 32; i++) {
		x = i < isa_num_operands ? isa_operands[i] : isa_rand();
		x = (u64)SignExtend32(x);
		if ((x & 3) == 3)
			x &= ~2ULL;
		__asm__ volatile ("ptabs/l %1, tr0\n\tgettr tr0, %0"
				  : "=r"(got) : "r"(x) : "tr0");
		CHECK1("ptabs/l gettr", got, x, x);
		__asm__ volatile ("ptabs/u %1, tr1\n\tgettr tr1, %0"
				  : "=r"(got) : "r"(x) : "tr1");
		CHECK1("ptabs/u gettr", got, x, x);
	}
	/* r63 as the source reads as zero. */
	__asm__ volatile ("ptabs r63, tr0\n\tgettr tr0, %0" : "=r"(got) : : "tr0");
	CHECK0("ptabs r63 gettr", got, 0);
	/* GETTR from each of the eight target registers. */
	x = 0x12345674;
	__asm__ volatile ("ptabs %1, tr0\n\tgettr tr0, %0" : "=r"(got) : "r"(x) : "tr0");
	CHECK1("ptabs/gettr tr0", got, x, x);
	__asm__ volatile ("ptabs %1, tr1\n\tgettr tr1, %0" : "=r"(got) : "r"(x) : "tr1");
	CHECK1("ptabs/gettr tr1", got, x, x);
	__asm__ volatile ("ptabs %1, tr2\n\tgettr tr2, %0" : "=r"(got) : "r"(x) : "tr2");
	CHECK1("ptabs/gettr tr2", got, x, x);
	__asm__ volatile ("ptabs %1, tr3\n\tgettr tr3, %0" : "=r"(got) : "r"(x) : "tr3");
	CHECK1("ptabs/gettr tr3", got, x, x);
	__asm__ volatile ("ptabs %1, tr4\n\tgettr tr4, %0" : "=r"(got) : "r"(x) : "tr4");
	CHECK1("ptabs/gettr tr4", got, x, x);
	__asm__ volatile ("ptabs %1, tr5\n\tgettr tr5, %0" : "=r"(got) : "r"(x) : "tr5");
	CHECK1("ptabs/gettr tr5", got, x, x);
	__asm__ volatile ("ptabs %1, tr6\n\tgettr tr6, %0" : "=r"(got) : "r"(x) : "tr6");
	CHECK1("ptabs/gettr tr6", got, x, x);
	__asm__ volatile ("ptabs %1, tr7\n\tgettr tr7, %0" : "=r"(got) : "r"(x) : "tr7");
	CHECK1("ptabs/gettr tr7", got, x, x);
	/* Two target registers hold independent values. */
	__asm__ volatile (
		"ptabs %2, tr0\n\t"
		"ptabs %3, tr7\n\t"
		"gettr tr0, %0\n\t"
		"gettr tr7, %1"
		: "=&r"(got), "=&r"(lbl) : "r"(x), "r"(x + 0x1000) : "tr0", "tr7");
	CHECK2("ptabs tr0 then tr7: tr0", got, x, x, x + 0x1000);
	CHECK2("ptabs tr0 then tr7: tr7", lbl, x + 0x1000, x, x + 0x1000);

	/* PTREL Rn, TRa: TRa = PC of the PTREL itself + SignExtend64(Rn).
	 * Displacements keep the target inside the implemented address
	 * space and off the (target & 3) == 3 misalignment case. */
	{
		static const s64 disp[] = {
			0, 1, 2, 4, 5, 8, 16, -4, -8, -3, -6, 0x100, -0x100,
			0x7fc, -0x7fc, 0x10000, 0x100001, 0x10000000,
		};
		for (i = 0; i < sizeof(disp) / sizeof(disp[0]); i++) {
			d = (u64)disp[i];
			__asm__ volatile (
				"1:\tptrel/l %2, tr0\n\t"
				"gettr tr0, %0\n\t"
				"movi datalabel 1b, %1\n"
				: "=&r"(got), "=&r"(lbl) : "r"(d) : "tr0");
			CHECK2("ptrel/l gettr", got, lbl + d, lbl, d);
			__asm__ volatile (
				"nop\n"
				"1:\tptrel/u %2, tr1\n\t"
				"gettr tr1, %0\n\t"
				"movi datalabel 1b, %1\n"
				: "=&r"(got), "=&r"(lbl) : "r"(d) : "tr1");
			CHECK2("ptrel/u gettr", got, lbl + d, lbl, d);
		}
	}
}

static void test_blink(void)
{
	u64 link, lbl, flag, tgt, got, cnt;

	/* BLINK TRb, Rd forward: Rd = PC + 4 + ISA = address of the next
	 * instruction | 1, and that instruction is skipped. */
	__asm__ volatile (
		"pta 1f, tr0\n\t"
		"movi datalabel 2f, %1\n\t"
		"movi 0x22, %2\n\t"
		"blink tr0, %0\n"
		"2:\tmovi 0x33, %2\n"
		"1:" : "=&r"(link), "=&r"(lbl), "=&r"(flag) : : "tr0");
	CHECK1("blink link", link, lbl + 1, lbl);
	CHECK1("blink jump", flag, 0x22, lbl);

	/* Same through PTABS of an address with the ISA bit set; the
	 * target register reads back as written. */
	__asm__ volatile (
		"movi datalabel 1f, %3\n\t"
		"ori %3, 1, %3\n\t"
		"ptabs %3, tr2\n\t"
		"gettr tr2, %4\n\t"
		"movi datalabel 2f, %1\n\t"
		"movi 0x22, %2\n\t"
		"blink tr2, %0\n"
		"2:\tmovi 0x33, %2\n"
		"1:" : "=&r"(link), "=&r"(lbl), "=&r"(flag), "=&r"(tgt), "=&r"(got)
		: : "tr2");
	CHECK1("ptabs gettr label|1", got, tgt, tgt);
	CHECK1("blink via ptabs link", link, lbl + 1, lbl);
	CHECK1("blink via ptabs jump", flag, 0x22, tgt);

	/* Rd = r63: the branch happens, r63 still reads as zero (writes to
	 * r63 are discarded, Vol. 1 2.5.4) and nothing else is written. */
	__asm__ volatile (
		"pta 1f, tr0\n\t"
		"movi 0x22, %0\n\t"
		"movi 0x44, %1\n\t"
		"blink tr0, r63\n\t"
		"movi 0x33, %0\n"
		"1:\tor r63, r63, %2"
		: "=&r"(flag), "=&r"(cnt), "=&r"(got) : : "tr0");
	CHECK0("blink r63 jump", flag, 0x22);
	CHECK0("blink r63 other reg kept", cnt, 0x44);
	CHECK0("blink r63 reads zero", got, 0);

	/* Backward BLINK: forward to 2, back to 1, forward out to 3. */
	__asm__ volatile (
		"movi 0, %0\n\t"
		"pta 1f, tr0\n\t"
		"pta 2f, tr1\n\t"
		"pta 3f, tr2\n\t"
		"blink tr1, r63\n"
		"1:\taddi %0, 1, %0\n\t"
		"blink tr2, r63\n"
		"2:\taddi %0, 16, %0\n\t"
		"blink tr0, r63\n\t"
		"addi %0, 256, %0\n"
		"3:" : "=&r"(cnt) : : "tr0", "tr1", "tr2");
	CHECK0("blink backward", cnt, 17);

	/* Call: BLINK with r18 as link register into the far target, which
	 * writes r0 and returns through PTABS r18 / BLINK. */
	__asm__ volatile (
		"movi datalabel isa_branch_far_target, %2\n\t"
		"ori %2, 1, %2\n\t"
		"ptabs %2, tr0\n\t"
		"movi datalabel 2f, %1\n\t"
		"movi 0, r0\n\t"
		"blink tr0, r18\n"
		"2:\tor r0, r63, %0\n\t"
		"or r18, r63, %3"
		: "=&r"(got), "=&r"(lbl), "=&r"(tgt), "=&r"(link)
		: : "r0", "r18", "tr0", "tr1");
	CHECK1("blink call far: callee ran", got, 0x5a, tgt);
	CHECK1("blink call far: link", link, lbl + 1, lbl);
}

ISA_GROUP(branch)
{
	u64 a, b;
	unsigned i;

	/* Conditional branches over the operand corpus and random pairs. */
	ISA_FOREACH_OPERAND(a) ISA_FOREACH_OPERAND(b)
		test_cond_pair(a, b);
	for (i = 0; i < 64; i++)
		test_cond_pair(isa_rand(), isa_rand());
	/* r63 as Rn reads as zero. */
	ISA_FOREACH_OPERAND(a) {
		CHECK1("beq a,r63", BRANCH_R63("beq", a), WANT(a == 0), a);
		CHECK1("bne a,r63", BRANCH_R63("bne", a), WANT(a != 0), a);
		CHECK1("bge a,r63", BRANCH_R63("bge", a), WANT((s64)a >= 0), a);
		CHECK1("bgt a,r63", BRANCH_R63("bgt", a), WANT((s64)a > 0), a);
		CHECK1("bgeu a,r63", BRANCH_R63("bgeu", a), WANT(1), a);
		CHECK1("bgtu a,r63", BRANCH_R63("bgtu", a), WANT(a > 0), a);
	}
	/* BEQI/BNEI: corpus plus values around each immediate (equal,
	 * equal in the low 32 bits only, sign bit flipped, off by one). */
	ISA_FOREACH_OPERAND(a)
		test_cond_imm(a);
	{
		static const s64 imms[] = { 0, 1, 2, 31, -1, -2, -17, -32 };
		for (i = 0; i < sizeof(imms) / sizeof(imms[0]); i++) {
			u64 v = (u64)imms[i];

			test_cond_imm(v);
			test_cond_imm(ZeroExtend32(v));
			test_cond_imm(v ^ (1ULL << 63));
			test_cond_imm(v | (1ULL << 32));
			test_cond_imm(v + 1);
			test_cond_imm(v - 1);
		}
	}
	test_backward();
	test_pt();
	test_blink();
	/* NOP: no architectural effect; a register passes through unchanged. */
	ISA_FOREACH_OPERAND(a) {
		b = a;
		__asm__ volatile ("nop\n\tnop" : "+r"(b));
		CHECK1("nop", b, a, a);
	}
}
