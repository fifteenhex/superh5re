/*
 * SH-5 exception, trap and privileged-state tests (Vol. 1 ch. 15-16,
 * Vol. 4 ch. 6-9).  Each test executes the instruction under test with
 * inline asm, lets the vector code in start.S record the launch into
 * exc_area and compares the record and the state after return with the
 * values the manual specifies.  Expected values never come from an
 * implementation.
 */
#include "exc.h"

struct exc_area exc_area __attribute__((aligned(16)));

_Static_assert(sizeof(struct exc_ctl) == CTL_SIZE, "exc_ctl");
_Static_assert(sizeof(struct exc_rec) == 1 << REC_SHIFT, "exc_rec");
_Static_assert(__builtin_offsetof(struct exc_ctl, count) == CTL_COUNT, "count");
_Static_assert(__builtin_offsetof(struct exc_ctl, vec) == CTL_VEC, "vec");
_Static_assert(__builtin_offsetof(struct exc_area, rec) == REC_BASE, "rec");
_Static_assert(__builtin_offsetof(struct exc_rec, pexpevt) == REC_PEXPEVT, "pexpevt");
_Static_assert(__builtin_offsetof(struct exc_rec, ret_ssr) == REC_RET_SSR, "ret_ssr");

#define STR_(x) #x
#define STR(x) STR_(x)

/* Appended to instructions that raise an exception in the execute stage:
 * the RTL core deadlocks when a load follows within two instructions
 * (README). */
#define NOPS	"\n\tnop\n\tnop\n\tnop"

/* Sign-extended 32-bit form of an address or 32-bit value (neff = 32). */
#define ADDR(p)	((u64)(s64)(s32)(unsigned long)(p))
#define SX32(x)	((u64)(s64)(s32)(u32)(x))

#define GETCON(cr) ({ u64 _v; __asm__ volatile("getcon " cr ", %0" : "=r"(_v)); _v; })
#define PUTCON(cr, v) do { u64 _v = (v); \
	__asm__ volatile("putcon %0, " cr : : "r"(_v) : "memory"); } while (0)

#define COUNT	(*(volatile u64 *)&exc_area.ctl.count)
#define REC(n)	(&exc_area.rec[(n) & (EXC_NREC - 1)])

/* ---- result accounting ---- */

static unsigned exc_tests, exc_failures, exc_test_failures;
static const char *exc_test_name;

static void check(const char *what, u64 got, u64 want)
{
	exc_tests++;
	if (got == want)
		return;
	exc_failures++;
	exc_test_failures++;
	exc_puts("exc: FAIL ");
	exc_puts(exc_test_name);
	exc_puts(" ");
	exc_puts(what);
	exc_puts(" got=");
	exc_puthex(got);
	exc_puts(" want=");
	exc_puthex(want);
	exc_puts("\n");
}
#define CHECK(what, got, want) check(what, (u64)(got), (u64)(want))

static void run(const char *name, void (*fn)(void))
{
	exc_test_name = name;
	exc_test_failures = 0;
	fn();
	if (!exc_test_failures) {
		exc_puts("exc: ");
		exc_puts(name);
		exc_puts(" ok\n");
	}
}

/* Record of launch number n with the fields common to every launch. */
static void check_launch(const char *what, u64 n, u64 vec, u64 expevt,
			 u64 spc, u64 ssr)
{
	const struct exc_rec *r = REC(n);

	CHECK(what, r->vec, vec);
	CHECK(what, r->expevt, expevt);
	CHECK(what, r->spc, spc);
	CHECK(what, r->ssr, ssr);
	/* 16.6.2 step 4: MD = BL = 1, other fields of the saved SR kept */
	CHECK(what, r->sr, (ssr | SR_MD | SR_BL) & ~(vec == VEC_PANIC ? SR_MMU : 0));
}

/* ---- 1. TRAPA ---- */

static void t_trapa(void)
{
	u64 sr0 = GETCON("sr"), c0 = COUNT, pc, sr1;
	u64 op = 0x123456789abcdef0ULL;
	const struct exc_rec *r = REC(c0);

	PUTCON("tea", 0x1234);
	PUTCON("pspc", 0x80000021);
	PUTCON("pssr", 0x40008000);
	PUTCON("pexpevt", 0x777);
	__asm__ volatile(
		"pta 1f, tr1\n\t"
		"gettr tr1, %[pc]\n"
		"1:\ttrapa %[op]\n\t"
		"getcon sr, %[sr1]"
		: [pc] "=&r"(pc), [sr1] "=&r"(sr1) : [op] "r"(op) : "tr1", "memory");
	CHECK("count", COUNT, c0 + 1);
	check_launch("trapa", c0, VEC_EXC, EVT_TRAP, pc, sr0);
	CHECK("tra", r->tra, 0x9abcdef0);		/* low 32 bits, Vol. 4 Table 15 */
	CHECK("tea kept", r->tea, 0x1234);		/* Table 160: TRAP sets no TEA */
	CHECK("pspc kept", r->pspc, 0xffffffff80000021ULL);
	CHECK("pssr kept", r->pssr, 0x40008000);
	CHECK("pexpevt kept", r->pexpevt, 0x777);
	CHECK("sr after rte", sr1, sr0);
	CHECK("tra after", GETCON("tra"), 0x9abcdef0);
	CHECK("expevt after", GETCON("expevt"), EVT_TRAP);
	/* RTE: SPC <- PSPC, SSR <- PSSR (16.7 step 3) */
	CHECK("spc after rte", GETCON("spc"), 0xffffffff80000021ULL);
	CHECK("ssr after rte", GETCON("ssr"), 0x40008000);
}

/* ---- 2. RESINST ---- */

#define RESINST_CASE(what, enc) do {					\
	u64 _c0 = COUNT, _pc;						\
	__asm__ volatile("pta 1f, tr1\n\tgettr tr1, %0\n"		\
			 "1:\t.long " enc : "=r"(_pc) : : "tr1", "memory"); \
	CHECK(what " count", COUNT, _c0 + 1);				\
	check_launch(what, _c0, VEC_EXC, EVT_RESINST, _pc, sr0);	\
} while (0)

static void t_resinst(void)
{
	u64 sr0 = GETCON("sr");

	RESINST_CASE("6ff4fff0", "0x6ff4fff0");	/* guaranteed reserved, Vol. 2 A.4 */
	RESINST_CASE("nop bit0", "0x6ff0fff1");	/* bits [3:0] != 0, A.3 */
	RESINST_CASE("misc9 ext0", "0x27f0fff0"); /* opcode 001001, extension 0 */
	RESINST_CASE("opcode 14", "0x53f0fff0"); /* reserved opcode 010100 */
}

/* ---- 3. user mode ---- */

/*
 * Enter user mode with RTE (SSR.MD = 0) and run a sequence of privileged
 * instructions, each of which raises RESINST and is skipped by the handler;
 * GETCON of user-accessible registers works; a TRAPA with CTL_EXIT_TRA
 * returns to privileged mode through the handler.  res[0] = USR read in
 * user mode, res[1] = CTC read in user mode, res[2] = address of the first
 * user instruction.
 */
static void user_enter(u64 sr_priv, u64 *res)
{
	u64 ssr_user = sr_priv & ~(SR_MD | SR_BL);
	u64 t;

	exc_area.ctl.exit_tra = 0xee;
	exc_area.ctl.next_ssr = sr_priv;
	__asm__ volatile(
		"pta 9f, tr1\n\t"
		"gettr tr1, %[t]\n\t"
		"st.q %[ctl], " STR(CTL_NEXT) ", %[t]\n\t"
		"pta 1f, tr1\n\t"
		"gettr tr1, %[t]\n\t"
		"st.q %[res], 16, %[t]\n\t"
		"putcon %[t], spc\n\t"
		"putcon %[ssr], ssr\n\t"
		"movi 0x0160, r2\n\t"
		"shori 0x0000, r2\n\t"		/* harmless GETCFG/PUTCFG index (ICCR0) */
		"movi 0, r3\n\t"
		"rte\n"
		"1:\tgetcon sr, r1\n\t"		/* +0  RESINST */
		"putcon r1, sr\n\t"		/* +4  RESINST */
		"getcfg r2, 0, r3\n\t"		/* +8  RESINST */
		"putcfg r2, 0, r3\n\t"		/* +12 RESINST */
		"rte\n\t"			/* +16 RESINST */
		"sleep\n\t"			/* +20 RESINST */
		"getcon expevt, r1\n\t"		/* +24 RESINST: privileged register */
		"movi 0x5a, r9\n\t"		/* +28 */
		"putcon r9, usr\n\t"		/* +32 user register */
		"getcon usr, r9\n\t"		/* +36 */
		"st.q %[res], 0, r9\n\t"	/* +40 */
		"getcon ctc, r9\n\t"		/* +44 */
		"st.q %[res], 8, r9\n\t"	/* +48 */
		"movi 0xee, r9\n\t"		/* +52 */
		"trapa r9\n"			/* +56 exit */
		"9:"
		: [t] "=&r"(t)
		: [ctl] "r"(&exc_area.ctl), [res] "r"(res), [ssr] "r"(ssr_user)
		: "r1", "r2", "r3", "r9", "tr1", "memory");
	exc_area.ctl.exit_tra = 1ULL << 32;
}

static void t_user(void)
{
	static const u64 expevt[8] = {
		EVT_RESINST, EVT_RESINST, EVT_RESINST, EVT_RESINST,
		EVT_RESINST, EVT_RESINST, EVT_RESINST, EVT_TRAP };
	u64 sr0 = GETCON("sr"), res[3], c0, base, i, sr_cd;

	/* SR.CD = 1: user reads of CTC return 0 (Vol. 1 Table 145) */
	sr_cd = sr0 | SR_CD;
	PUTCON("sr", sr_cd);
	c0 = COUNT;
	user_enter(sr_cd, res);
	base = res[2];
	CHECK("count", COUNT, c0 + 8);
	for (i = 0; i < 8; i++)
		check_launch("user insn", c0 + i, VEC_EXC, expevt[i],
			     base + (i < 7 ? 4 * i : 56), sr_cd & ~(SR_MD | SR_BL));
	CHECK("exit tra", REC(c0 + 7)->tra, 0xee);
	CHECK("sr after exit", GETCON("sr"), sr_cd);
	CHECK("usr in user mode", res[0], 0x5a);
	CHECK("ctc with cd=1", res[1], 0);

	/* SR.CD = 0: user reads return the counter */
	PUTCON("sr", sr0);
	c0 = COUNT;
	user_enter(sr0, res);
	CHECK("count", COUNT, c0 + 8);
	CHECK("sr after exit", GETCON("sr"), sr0);
	CHECK("ctc with cd=0 nonzero", res[1] != 0, 1);
	CHECK("ctc with cd=0 32-bit", res[1] >> 32, 0);
}

/* ---- 4. FPUDIS ---- */

static void t_fpudis(void)
{
	u64 sr0 = GETCON("sr"), sr_fd = sr0 | SR_FD, c0, pc, v;
	static const u32 word = 0x3fc00000;	/* 1.5f */

	PUTCON("sr", sr_fd);
	CHECK("sr.fd set", GETCON("sr"), sr_fd);

	c0 = COUNT;
	__asm__ volatile("pta 1f, tr1\n\tgettr tr1, %0\n"
			 "1:\tfadd.s fr33, fr34, fr35" : "=r"(pc) : : "tr1", "memory");
	CHECK("fadd count", COUNT, c0 + 1);
	check_launch("fadd.s", c0, VEC_EXC, EVT_FPUDIS, pc, sr_fd);

	c0 = COUNT;
	__asm__ volatile("pta 1f, tr1\n\tgettr tr1, %0\n"
			 "1:\tfld.s %1, 0, fr35" : "=&r"(pc) : "r"(ADDR(&word)) : "tr1", "memory");
	CHECK("fld count", COUNT, c0 + 1);
	check_launch("fld.s", c0, VEC_EXC, EVT_FPUDIS, pc, sr_fd);

	c0 = COUNT;
	__asm__ volatile("pta 1f, tr1\n\tgettr tr1, %0\n"
			 "1:\tfgetscr fr35" : "=r"(pc) : : "tr1", "memory");
	CHECK("fgetscr count", COUNT, c0 + 1);
	check_launch("fgetscr", c0, VEC_EXC, EVT_FPUDIS, pc, sr_fd);

	/* FPUTSCR fr0 with bit 0 set: not an FPU instruction, RESINST (A.6) */
	c0 = COUNT;
	__asm__ volatile("pta 1f, tr1\n\tgettr tr1, %0\n"
			 "1:\t.long 0x300203f1" : "=r"(pc) : : "tr1", "memory");
	CHECK("fputscr bit0 count", COUNT, c0 + 1);
	check_launch("fputscr bit0", c0, VEC_EXC, EVT_RESINST, pc, sr_fd);

	PUTCON("sr", sr0);
	c0 = COUNT;
	__asm__ volatile("fld.s %1, 0, fr35\n\t"
			 "fmov.ls r63, fr34\n\t"
			 "fadd.s fr35, fr34, fr33\n\t"
			 "fmov.sl fr33, %0" : "=&r"(v) : "r"(ADDR(&word)) : "memory");
	CHECK("fd=0 count", COUNT, c0);
	CHECK("fd=0 fld/fadd", (u32)v, 0x3fc00000);
}

/* ---- 5. IADDERR ---- */

static void t_iadderr(void)
{
	u64 sr0 = GETCON("sr"), c0, pc, t, v;

	/* PTABS: bits [1:0] = 11.  The NOPs after each faulting instruction
	 * keep loads out of its shadow: the RTL core deadlocks otherwise
	 * (README). */
	c0 = COUNT;
	__asm__ volatile("pta 1f, tr1\n\tgettr tr1, %0\n"
			 "1:\tptabs %1, tr1" NOPS : "=&r"(pc) : "r"(0xffffffff80000003ULL) : "tr1", "memory");
	CHECK("ptabs misaligned count", COUNT, c0 + 1);
	check_launch("ptabs misaligned", c0, VEC_EXC, EVT_IADDERR, pc, sr0);
	CHECK("ptabs misaligned tea", REC(c0)->tea, 0xffffffff80000003ULL);

	/* PTABS: not a sign-extended 32-bit address; TEA holds the low 32 bits */
	c0 = COUNT;
	__asm__ volatile("pta 1f, tr1\n\tgettr tr1, %0\n"
			 "1:\tptabs %1, tr1" NOPS : "=&r"(pc) : "r"(0x0000000100000001ULL) : "tr1", "memory");
	CHECK("ptabs malformed count", COUNT, c0 + 1);
	check_launch("ptabs malformed", c0, VEC_EXC, EVT_IADDERR, pc, sr0);
	CHECK("ptabs malformed tea", REC(c0)->tea, 0x0000000000000001ULL);

	/* PTREL Rn: target = PC + Rn */
	c0 = COUNT;
	__asm__ volatile("pta 1f, tr1\n\tgettr tr1, %0\n"
			 "1:\tptrel %1, tr1" NOPS : "=&r"(pc) : "r"(3ULL) : "tr1", "memory");
	CHECK("ptrel misaligned count", COUNT, c0 + 1);
	check_launch("ptrel misaligned", c0, VEC_EXC, EVT_IADDERR, pc, sr0);
	CHECK("ptrel misaligned tea", REC(c0)->tea, (pc & ~1ULL) + 3);

	c0 = COUNT;
	__asm__ volatile("pta 1f, tr1\n\t"
			 "gettr tr1, %[pc]\n\t"
			 "addi %[pc], -1, %[t]\n\t"
			 "sub %[want], %[t], %[t]\n"
			 "1:\tptrel %[t], tr1" NOPS
			 : [pc] "=&r"(pc), [t] "=&r"(t) : [want] "r"(0x0000000100000001ULL)
			 : "tr1", "memory");
	CHECK("ptrel malformed count", COUNT, c0 + 1);
	check_launch("ptrel malformed", c0, VEC_EXC, EVT_IADDERR, pc, sr0);
	CHECK("ptrel malformed tea", REC(c0)->tea, 0x0000000000000001ULL);

	/* a well-formed target: PTABS and BLINK succeed */
	c0 = COUNT;
	__asm__ volatile("pta 1f, tr1\n\t"
			 "gettr tr1, %[t]\n\t"
			 "ptabs %[t], tr1\n\t"
			 "movi 1, %[v]\n\t"
			 "blink tr1, r63\n\t"
			 "movi 2, %[v]\n"
			 "1:" : [t] "=&r"(t), [v] "=&r"(v) : : "tr1", "memory");
	CHECK("blink count", COUNT, c0);
	CHECK("blink taken", v, 1);
	CHECK("gettr isa bit", t & 1, 1);
}

/* ---- 6. RADDERR / WADDERR ---- */

static u64 buf[4] __attribute__((aligned(16)));

#define ADDRERR_CASE(what, insn, addr, evt) do {			\
	u64 _c0 = COUNT, _pc, _a = (addr);				\
	__asm__ volatile("pta 1f, tr1\n\tgettr tr1, %0\n"		\
			 "1:\t" insn NOPS : "=&r"(_pc) : "r"(_a)	\
			 : "r1", "fr32", "fr33", "tr1", "memory");	\
	CHECK(what " count", COUNT, _c0 + 1);				\
	check_launch(what, _c0, VEC_EXC, evt, _pc, sr0);		\
	CHECK(what " tea", REC(_c0)->tea, SX32(_a));			\
} while (0)

static void t_adderr(void)
{
	u64 sr0 = GETCON("sr"), b = ADDR(buf), c0, v;
	volatile u64 *m = buf;

	ADDRERR_CASE("ld.l +1", "ld.l %1, 0, r1", b + 1, EVT_RADDERR);
	ADDRERR_CASE("ld.q +4", "ld.q %1, 0, r1", b + 4, EVT_RADDERR);
	ADDRERR_CASE("st.w +1", "st.w %1, 0, r63", b + 1, EVT_WADDERR);
	ADDRERR_CASE("st.q +2", "st.q %1, 0, r63", b + 2, EVT_WADDERR);
	ADDRERR_CASE("fld.d +4", "fld.d %1, 0, dr32", b + 4, EVT_RADDERR);
	/* SWAP.Q: misaligned swaps raise WADDERR (Vol. 2, SWAP.Q) */
	ADDRERR_CASE("swap.q +1", "swap.q %1, r63, r1", b + 1, EVT_WADDERR);
	/* not in the implemented effective address space: TEA = low 32 bits */
	ADDRERR_CASE("ld.l malformed", "ld.l %1, 0, r1", 0x0000000100001000ULL, EVT_RADDERR);
	ADDRERR_CASE("st.q malformed", "st.q %1, 0, r63", 0x0000000100002000ULL, EVT_WADDERR);

	/* LDLO/LDHI/STLO/STHI accept any byte address (Vol. 2 byte mappings) */
	m[0] = 0x0706050403020100ULL;
	m[1] = 0;
	m[2] = 0;
	c0 = COUNT;
	__asm__ volatile("ldlo.q %1, 0, %0" : "=r"(v) : "r"(b + 3) : "memory");
	CHECK("ldlo.q +3", v, 0x0000000706050403ULL);
	__asm__ volatile("ldhi.q %1, 0, %0" : "=r"(v) : "r"(b + 3) : "memory");
	CHECK("ldhi.q +3", v, 0x0302010000000000ULL);
	__asm__ volatile("ldlo.l %1, 0, %0" : "=r"(v) : "r"(b + 5) : "memory");
	CHECK("ldlo.l +5", v, 0x0000000000070605ULL);
	__asm__ volatile("ldhi.l %1, 0, %0" : "=r"(v) : "r"(b + 5) : "memory");
	CHECK("ldhi.l +5", v, 0x0000000005040000ULL);
	__asm__ volatile("stlo.q %0, 0, %1" : : "r"(b + 8 + 3), "r"(0xf7f6f5f4f3f2f1f0ULL) : "memory");
	CHECK("stlo.q +3", m[1], 0xf4f3f2f1f0000000ULL);
	__asm__ volatile("sthi.q %0, 0, %1" : : "r"(b + 16 + 3), "r"(0xf7f6f5f4f3f2f1f0ULL) : "memory");
	CHECK("sthi.q +3", m[2], 0x00000000f7f6f5f4ULL);
	__asm__ volatile("stlo.l %0, 0, %1" : : "r"(b + 8 + 1), "r"(0xffffffffa3a2a1a0ULL) : "memory");
	CHECK("stlo.l +1", m[1], 0xf4f3f2f1a2a1a000ULL);
	__asm__ volatile("sthi.l %0, 0, %1" : : "r"(b + 16 + 1), "r"(0xffffffffa3a2a1a0ULL) : "memory");
	CHECK("sthi.l +1", m[2], 0x00000000f7f6a3a2ULL);
	CHECK("hi/lo count", COUNT, c0);

	/* LD.Q to R63 is a prefetch: no exception in exceptional cases */
	c0 = COUNT;
	__asm__ volatile("ld.q %0, 0, r63" : : "r"(0x0000000100001000ULL) : "memory");
	__asm__ volatile("ld.q %0, 0, r63" : : "r"(b + 1) : "memory");
	__asm__ volatile("ld.l %0, 0, r63" : : "r"(b + 1) : "memory");
	__asm__ volatile("ldx.q %0, r63, r63" : : "r"(0x0000000100001000ULL) : "memory");
	CHECK("prefetch count", COUNT, c0);
}

/* ---- 7. panic ---- */

static void t_panic(void)
{
	u64 sr0 = GETCON("sr"), c0, pc, sr1, t;
	const struct exc_rec *r;

	/* known pre-panic SPC, SSR, EXPEVT, TRA, TEA */
	PUTCON("spc", 0x80000041);
	PUTCON("ssr", 0x40008800);
	PUTCON("expevt", 0x5a0);
	PUTCON("tra", 0x5555);
	PUTCON("tea", 0x4242);
	PUTCON("sr", sr0 | SR_BL);
	CHECK("sr.bl set by putcon", GETCON("sr"), sr0 | SR_BL);
	PUTCON("sr", sr0);
	c0 = COUNT;
	r = REC(c0);
	__asm__ volatile(
		"putcon %[blsr], sr\n\t"
		"pta 1f, tr1\n\t"
		"gettr tr1, %[pc]\n"
		"1:\ttrapa %[op]\n\t"
		"getcon sr, %[sr1]\n\t"
		"putcon %[sr0], sr"
		: [pc] "=&r"(pc), [sr1] "=&r"(sr1)
		: [op] "r"(0x9999ULL), [blsr] "r"(sr0 | SR_BL), [sr0] "r"(sr0)
		: "tr1", "memory");
	CHECK("count", COUNT, c0 + 1);
	check_launch("trapa panic", c0, VEC_PANIC, EVT_TRAP, pc, sr0 | SR_BL);
	CHECK("pspc", r->pspc, 0xffffffff80000041ULL);	/* 16.6.2 step 2 */
	CHECK("pssr", r->pssr, 0x40008800);
	CHECK("pexpevt", r->pexpevt, 0x5a0);
	CHECK("tra preserved", r->tra, 0x5555);		/* 16.6.2 step 5 */
	CHECK("tea preserved", r->tea, 0x4242);
	CHECK("sr.mmu", r->sr & SR_MMU, 0);
	CHECK("sr after rte", sr1, sr0 | SR_BL);
	/* RTE restored SPC and SSR from PSPC and PSSR (16.7 step 3) */
	CHECK("spc after rte", GETCON("spc"), 0xffffffff80000041ULL);
	CHECK("ssr after rte", GETCON("ssr"), 0x40008800);
	CHECK("expevt after", GETCON("expevt"), EVT_TRAP);
	CHECK("pexpevt after", GETCON("pexpevt"), 0x5a0);

	/* a data address error under SR.BL = 1: panic, TEA preserved */
	PUTCON("tea", 0x4343);
	c0 = COUNT;
	r = REC(c0);
	__asm__ volatile(
		"putcon %[blsr], sr\n\t"
		"pta 1f, tr1\n\t"
		"gettr tr1, %[pc]\n"
		"1:\tld.l %[a], 0, r1" NOPS "\n\t"
		"putcon %[sr0], sr"
		: [pc] "=&r"(pc)
		: [a] "r"(ADDR(buf) + 1), [blsr] "r"(sr0 | SR_BL), [sr0] "r"(sr0)
		: "r1", "tr1", "memory");
	CHECK("count", COUNT, c0 + 1);
	check_launch("radderr panic", c0, VEC_PANIC, EVT_RADDERR, pc, sr0 | SR_BL);
	CHECK("tea preserved", r->tea, 0x4343);

	/* debug launches clear SR.WATCH (16.6.2 step 4.4, Table 160): enter
	 * with WATCH = 1 and BL = 1 by RTE, trap, leave the same way */
	c0 = COUNT;
	r = REC(c0);
	__asm__ volatile(
		"putcon %[ssr], ssr\n\t"
		"pta 1f, tr1\n\t"
		"gettr tr1, %[pc]\n\t"
		"putcon %[pc], spc\n\t"
		"rte\n"
		"1:\ttrapa %[op]\n\t"
		"getcon sr, %[sr1]\n\t"
		"putcon %[sr0], ssr\n\t"
		"pta 2f, tr1\n\t"
		"gettr tr1, %[t]\n\t"
		"putcon %[t], spc\n\t"
		"rte\n"
		"2:"
		: [pc] "=&r"(pc), [sr1] "=&r"(sr1), [t] "=&r"(t)
		: [op] "r"(0x9998ULL), [ssr] "r"(sr0 | SR_WATCH | SR_BL), [sr0] "r"(sr0)
		: "tr1", "memory");
	CHECK("count", COUNT, c0 + 1);
	CHECK("watch panic expevt", r->expevt, EVT_TRAP);
	CHECK("watch panic spc", r->spc, pc);
	CHECK("watch panic vec", r->vec, VEC_PANIC);
	CHECK("watch panic ssr", r->ssr, sr0 | SR_WATCH | SR_BL);
	CHECK("watch panic sr", r->sr, (sr0 | SR_BL) & ~SR_WATCH);
	CHECK("watch after rte", sr1, sr0 | SR_WATCH | SR_BL);
	CHECK("sr restored", GETCON("sr"), sr0);
}

/* ---- 8. BRK ---- */

static void t_brk(void)
{
	u64 sr0 = GETCON("sr"), c0, pc, sr1, t;
	const struct exc_rec *r;

	/* BL = 0, WATCH = 1: debug exception through RESVEC + 0x100 */
	c0 = COUNT;
	r = REC(c0);
	__asm__ volatile(
		"putcon %[ssr], ssr\n\t"
		"pta 1f, tr1\n\t"
		"gettr tr1, %[pc]\n\t"
		"putcon %[pc], spc\n\t"
		"rte\n"
		"1:\tbrk\n\t"
		"getcon sr, %[sr1]\n\t"
		"putcon %[sr0], ssr\n\t"
		"pta 2f, tr1\n\t"
		"gettr tr1, %[t]\n\t"
		"putcon %[t], spc\n\t"
		"rte\n"
		"2:"
		: [pc] "=&r"(pc), [sr1] "=&r"(sr1), [t] "=&r"(t)
		: [ssr] "r"(sr0 | SR_WATCH), [sr0] "r"(sr0)
		: "tr1", "memory");
	CHECK("count", COUNT, c0 + 1);
	CHECK("vec", r->vec, VEC_DEBUG);
	CHECK("expevt", r->expevt, EVT_BREAK);
	CHECK("spc", r->spc, pc);
	CHECK("ssr", r->ssr, sr0 | SR_WATCH);
	CHECK("sr", r->sr, (sr0 | SR_MD | SR_BL) & ~(SR_WATCH | SR_STEP));
	CHECK("sr after rte", sr1, sr0 | SR_WATCH);
	CHECK("sr restored", GETCON("sr"), sr0);

	/* BL = 1: panic with the BREAK code */
	c0 = COUNT;
	r = REC(c0);
	__asm__ volatile(
		"putcon %[blsr], sr\n\t"
		"pta 1f, tr1\n\t"
		"gettr tr1, %[pc]\n"
		"1:\tbrk\n\t"
		"putcon %[sr0], sr"
		: [pc] "=&r"(pc) : [blsr] "r"(sr0 | SR_BL), [sr0] "r"(sr0)
		: "tr1", "memory");
	CHECK("count", COUNT, c0 + 1);
	check_launch("brk panic", c0, VEC_PANIC, EVT_BREAK, pc, sr0 | SR_BL);
}

/* ---- 9. nested exception ---- */

static void t_nested(void)
{
	u64 sr0 = GETCON("sr"), c0, pc, sr1;
	const struct exc_rec *outer, *inner;

	exc_area.ctl.nest = 1;
	exc_area.ctl.nest_tra = 0x77;
	c0 = COUNT;
	outer = REC(c0);
	inner = REC(c0 + 1);
	__asm__ volatile(
		"pta 1f, tr1\n\t"
		"gettr tr1, %[pc]\n"
		"1:\ttrapa %[op]\n\t"
		"getcon sr, %[sr1]"
		: [pc] "=&r"(pc), [sr1] "=&r"(sr1) : [op] "r"(0x33ULL) : "tr1", "memory");
	CHECK("count", COUNT, c0 + 2);
	check_launch("outer", c0, VEC_EXC, EVT_TRAP, pc, sr0);
	CHECK("outer tra", outer->tra, 0x33);
	/* inner: launched from the handler with SR.BL cleared by PUTCON */
	CHECK("inner vec", inner->vec, VEC_EXC);
	CHECK("inner expevt", inner->expevt, EVT_TRAP);
	CHECK("inner tra", inner->tra, 0x77);
	CHECK("inner spc", inner->spc & ~1ULL, ADDR(exc_nest_trapa) & ~1ULL);
	CHECK("inner spc isa", inner->spc & 1, 1);
	CHECK("inner ssr", inner->ssr, (sr0 | SR_MD) & ~SR_BL);
	CHECK("inner sr", inner->sr, sr0 | SR_MD | SR_BL);
	CHECK("nest cleared", exc_area.ctl.nest, 0);
	CHECK("sr after rte", sr1, sr0);
}

/* ---- 10. control registers ---- */

#define RW_CASE(cr, w, want) do {					\
	PUTCON(cr, w);							\
	CHECK(cr, GETCON(cr), want);					\
} while (0)
#define SR_CASE(what, w, want) do {					\
	PUTCON("sr", w);						\
	CHECK(what, GETCON("sr"), want);				\
} while (0)

#define RESERVED_CR(n) do {						\
	u64 _o;								\
	__asm__ volatile("putcon %1, cr" #n "\n\tgetcon cr" #n ", %0"	\
			 : "=r"(_o) : "r"(~0ULL));			\
	CHECK("cr" #n, _o, 0);						\
} while (0)

static void t_cr(void)
{
	u64 sr0 = GETCON("sr"), vbr0 = GETCON("vbr"), resvec0 = GETCON("resvec");
	u64 a, b, d, u1, u2;
	volatile int i;

	RW_CASE("kcr0", 0x0123456789abcdefULL, 0x0123456789abcdefULL);
	RW_CASE("kcr1", 0xfedcba9876543210ULL, 0xfedcba9876543210ULL);
	RW_CASE("dcr", 0x5555aaaa5555aaaaULL, 0x5555aaaa5555aaaaULL);
	/* VBR bits [1:0] and RESVEC bit 1 are reserved and read 0 (Vol. 4
	 * Tables 18, 19); RESVEC bit 0 is MMUOFF */
	CHECK("vbr base", vbr0, 0xffffffff80000000ULL);
	RW_CASE("vbr", vbr0 | 3, vbr0);
	RW_CASE("vbr", vbr0, vbr0);
	CHECK("resvec base", resvec0, 0xffffffff80000800ULL);
	RW_CASE("resvec", resvec0 | 3, resvec0 | 1);
	RW_CASE("resvec", resvec0, resvec0);
	/* 32-bit registers: the upper half reads 0 (Tables 12-15) or as the
	 * sign extension of bit 31 (Tables 16, 17, 20) */
	RW_CASE("tea", 0x123456789abcdef0ULL, 0xffffffff9abcdef0ULL);
	RW_CASE("tra", 0x123456789abcdef0ULL, 0x9abcdef0);
	RW_CASE("intevt", 0x123456789abcdef0ULL, 0x9abcdef0);
	RW_CASE("expevt", 0x123456789abcdef0ULL, 0x9abcdef0);
	RW_CASE("pexpevt", 0x123456789abcdef0ULL, 0x9abcdef0);
	RW_CASE("spc", 0x123456789abcdef1ULL, 0xffffffff9abcdef1ULL);
	RW_CASE("pspc", 0x123456789abcdef1ULL, 0xffffffff9abcdef1ULL);
	/* SSR, PSSR: every defined field writable, reserved bits read 0 */
	RW_CASE("ssr", ~0ULL, 0xdcfffbf2);
	RW_CASE("pssr", ~0ULL, 0xdcfffbf2);
	RW_CASE("ssr", 0, 0);
	RW_CASE("pssr", 0, 0);

	/* SR through PUTCON (Vol. 1 15.2.1, Vol. 4 Table 9) */
	SR_CASE("sr writable fields", sr0 ^ (SR_S | SR_IMASK | SR_Q | SR_M | SR_CD |
		SR_PR | SR_SZ | SR_FR | SR_FD | SR_BL),
		sr0 ^ (SR_S | SR_IMASK | SR_Q | SR_M | SR_CD | SR_PR | SR_SZ | SR_FR | SR_FD | SR_BL));
	SR_CASE("sr restored", sr0, sr0);
	SR_CASE("sr read-only fields", sr0 ^ (SR_MD | SR_MMU | SR_ASID | SR_WATCH | SR_STEP), sr0);
	SR_CASE("sr reserved bits", sr0 | 0x2000000dULL | (0xffffffffULL << 32), sr0);

	RESERVED_CR(32); RESERVED_CR(33); RESERVED_CR(34); RESERVED_CR(35);
	RESERVED_CR(36); RESERVED_CR(37); RESERVED_CR(38); RESERVED_CR(39);
	RESERVED_CR(40); RESERVED_CR(41); RESERVED_CR(42); RESERVED_CR(43);
	RESERVED_CR(44); RESERVED_CR(45); RESERVED_CR(46); RESERVED_CR(47);
	RESERVED_CR(48); RESERVED_CR(49); RESERVED_CR(50); RESERVED_CR(51);
	RESERVED_CR(52); RESERVED_CR(53); RESERVED_CR(54); RESERVED_CR(55);
	RESERVED_CR(56); RESERVED_CR(57); RESERVED_CR(58); RESERVED_CR(59);
	RESERVED_CR(60); RESERVED_CR(61);

	/* CTC: 32 bits, decrements every cycle, privileged write (Vol. 4 6.2.13) */
	PUTCON("ctc", 0x80000000);
	a = GETCON("ctc");
	CHECK("ctc write", ((0x80000000ULL - a) & 0xffffffffULL) < 0x1000000, 1);
	CHECK("ctc 32-bit", a >> 32, 0);
	a = GETCON("ctc");
	for (i = 0; i < 200; i++)
		;
	b = GETCON("ctc");
	d = (a - b) & 0xffffffffULL;
	CHECK("ctc decrements", d != 0 && d < 0x1000000, 1);
	PUTCON("sr", sr0 | SR_CD);
	CHECK("ctc privileged cd=1 nonzero", GETCON("ctc") != 0, 1);
	PUTCON("sr", sr0);

	/* USR dirty bits (Vol. 1 15.2.11, Vol. 4 6.2.14): the register written
	 * by a GETCON from USR is marked after the read */
	__asm__ volatile("putcon r63, usr\n\t"
			 "add r63, r63, r9\n\t"
			 "getcon usr, r2\n\t"
			 "getcon usr, r3\n\t"
			 "or r2, r63, %0\n\t"
			 "or r3, r63, %1" : "=&r"(u1), "=&r"(u2) : : "r2", "r3", "r9");
	CHECK("usr r9 written", u1, 0x02);
	CHECK("usr r9 r2 written", u2, 0x03);
	__asm__ volatile("putcon r63, usr\n\t"
			 "add r63, r63, r63\n\t"
			 "getcon usr, r2\n\t"
			 "or r2, r63, %0" : "=&r"(u1) : : "r2");
	CHECK("usr r63 written", u1, 0);
	__asm__ volatile("putcon r63, usr\n\t"
			 "fmov.ls r63, fr17\n\t"
			 "getcon usr, r2\n\t"
			 "or r2, r63, %0" : "=&r"(u1) : : "r2", "fr17");
	CHECK("usr fr17 written", u1, 0x400);
	__asm__ volatile("movi 0x1234, r2\n\t"
			 "putcon r2, usr\n\t"
			 "getcon usr, r9\n\t"
			 "or r9, r63, %0" : "=&r"(u1) : : "r2", "r9");
	CHECK("usr write/read", u1, 0x1234);
	PUTCON("usr", 0);
}

/* ---- 11. configuration registers ---- */

#define GETCFG(idx) ({ u64 _v, _i = (idx);				\
	__asm__ volatile("getcfg %1, 0, %0" : "=r"(_v) : "r"(_i)); _v; })
#define PUTCFG(idx, v) do { u64 _v = (v), _i = (idx);			\
	__asm__ volatile("putcfg %0, 0, %1" : : "r"(_i), "r"(_v) : "memory"); } while (0)

static void t_cfg(void)
{
	const u64 dr5 = 0x00800000 + 16 * 5, ir7 = 0x00000000 + 16 * 7;
	const u64 iccr = 0x01600000, occr = 0x01e00000;

	/* MMUDR[5]: PTEH V=0 SH=1 ASID=0x5a EPN=0x12345, reserved bits [10,11]
	 * and [32,63] written 1 and read 0 (Vol. 4 Table 39); PTEL all ones:
	 * PRX and the reserved bits read 0 (Table 40) */
	PUTCFG(dr5, 0xffffffff12345d6aULL);
	CHECK("mmudr5.pteh", GETCFG(dr5), 0x1234516a);
	PUTCFG(dr5 + 1, ~0ULL);
	CHECK("mmudr5.ptel", GETCFG(dr5 + 1), 0xfffff35b);
	/* MMUIR[7]: in the ITLB CB0, PRR and PRW are reserved (Table 37) */
	PUTCFG(ir7, 0xffffffff12345d6aULL);
	CHECK("mmuir7.pteh", GETCFG(ir7), 0x1234516a);
	PUTCFG(ir7 + 1, ~0ULL);
	CHECK("mmuir7.ptel", GETCFG(ir7 + 1), 0xfffff29a);
	PUTCFG(dr5, 0);
	PUTCFG(dr5 + 1, 0);
	PUTCFG(ir7, 0);
	PUTCFG(ir7 + 1, 0);
	CHECK("mmudr5 cleared", GETCFG(dr5) | GETCFG(dr5 + 1), 0);
	CHECK("mmuir7 cleared", GETCFG(ir7) | GETCFG(ir7 + 1), 0);

	/* ICCR0/OCCR0: ICI/OCI (bit 1) read 0 (Tables 47, 51); the caches are
	 * off while SR.MMU = 0 so enabling them has no effect here */
	PUTCFG(iccr, ~0ULL);
	CHECK("iccr0", GETCFG(iccr), 0x1);
	PUTCFG(occr, ~0ULL);
	CHECK("occr0", GETCFG(occr), 0x5);
	PUTCFG(iccr, 0);
	PUTCFG(occr, 0);
	CHECK("iccr0 cleared", GETCFG(iccr), 0);
	CHECK("occr0 cleared", GETCFG(occr), 0);
	/* ICCR1/OCCR1: W_LOAD [0,1], W_LE 7, W_LOCK [8,11] (Tables 48, 52) */
	PUTCFG(iccr + 1, ~0ULL);
	CHECK("iccr1", GETCFG(iccr + 1), 0xf83);
	PUTCFG(occr + 1, ~0ULL);
	CHECK("occr1", GETCFG(occr + 1), 0xf83);
	PUTCFG(iccr + 1, 0);
	PUTCFG(occr + 1, 0);
}

/* ---- 12. FPUEXC ---- */

#define FPSCR_FLAG_I	(1u << 2)
#define FPSCR_FLAG_Z	(1u << 5)
#define FPSCR_FLAG_V	(1u << 6)
#define FPSCR_ENABLE_I	(1u << 7)
#define FPSCR_ENABLE_Z	(1u << 10)
#define FPSCR_ENABLE_V	(1u << 11)
#define FPSCR_CAUSE_I	(1u << 12)
#define FPSCR_CAUSE_Z	(1u << 15)
#define FPSCR_CAUSE_V	(1u << 16)
#define FPSCR_CAUSE_E	(1u << 17)
#define FPSCR_DN	(1u << 18)

#define SNAN_S		0x7fc00001u	/* fraction MSB set (Vol. 1 2.5.4) */
#define QNAN_S		0x7fbfffffu	/* the default quiet NaN */
#define ONE_S		0x3f800000u
#define TWO_S		0x40000000u
#define DENORM_S	0x00000001u
#define PRESET_S	0x12345678u

struct fpres { u64 pc; u32 d, fpscr; };

/* FPSCR = fpscr; fr35 = PRESET_S; insn fr33 (= a), fr34 (= b) -> fr35 */
#define FPU_CASE(out, scr, insn, x, y) do {				\
	u64 _pc, _d, _s;						\
	__asm__ volatile(						\
		"fmov.ls %[sc], fr32\n\t"				\
		"fputscr fr32\n\t"					\
		"fmov.ls %[ax], fr33\n\t"				\
		"fmov.ls %[bx], fr34\n\t"				\
		"fmov.ls %[p], fr35\n\t"				\
		"pta 1f, tr1\n\t"					\
		"gettr tr1, %[pc]\n"					\
		"1:\t" insn " fr33, fr34, fr35\n\t"			\
		"fmov.sl fr35, %[d]\n\t"				\
		"fgetscr fr32\n\t"					\
		"fmov.sl fr32, %[s]"					\
		: [pc] "=&r"(_pc), [d] "=&r"(_d), [s] "=&r"(_s)		\
		: [sc] "r"((u64)(scr)), [ax] "r"((u64)(x)), [bx] "r"((u64)(y)), \
		  [p] "r"((u64)PRESET_S)				\
		: "fr32", "fr33", "fr34", "fr35", "tr1", "memory");	\
	(out).pc = _pc; (out).d = (u32)_d; (out).fpscr = (u32)_s;	\
} while (0)

static void t_fpuexc(void)
{
	u64 sr0 = GETCON("sr"), c0;
	struct fpres r;

	/* invalid operation enabled: exception, CAUSE.V and FLAG.V, no result */
	c0 = COUNT;
	FPU_CASE(r, FPSCR_ENABLE_V, "fadd.s", SNAN_S, ONE_S);
	CHECK("snan enabled count", COUNT, c0 + 1);
	check_launch("snan enabled", c0, VEC_EXC, EVT_FPUEXC, r.pc, sr0);
	CHECK("snan enabled fpscr", r.fpscr, FPSCR_ENABLE_V | FPSCR_CAUSE_V | FPSCR_FLAG_V);
	CHECK("snan enabled dest", r.d, PRESET_S);

	/* invalid operation not enabled: quiet NaN, CAUSE.V and FLAG.V */
	c0 = COUNT;
	FPU_CASE(r, 0, "fadd.s", SNAN_S, ONE_S);
	CHECK("snan disabled count", COUNT, c0);
	CHECK("snan disabled fpscr", r.fpscr, FPSCR_CAUSE_V | FPSCR_FLAG_V);
	CHECK("snan disabled dest", r.d, QNAN_S);

	/* division by zero enabled */
	c0 = COUNT;
	FPU_CASE(r, FPSCR_ENABLE_Z, "fdiv.s", ONE_S, 0);
	CHECK("div0 enabled count", COUNT, c0 + 1);
	check_launch("div0 enabled", c0, VEC_EXC, EVT_FPUEXC, r.pc, sr0);
	CHECK("div0 enabled fpscr", r.fpscr, FPSCR_ENABLE_Z | FPSCR_CAUSE_Z | FPSCR_FLAG_Z);
	CHECK("div0 enabled dest", r.d, PRESET_S);

	/* division by zero not enabled: infinity */
	c0 = COUNT;
	FPU_CASE(r, 0, "fdiv.s", ONE_S, 0);
	CHECK("div0 disabled count", COUNT, c0);
	CHECK("div0 disabled fpscr", r.fpscr, FPSCR_CAUSE_Z | FPSCR_FLAG_Z);
	CHECK("div0 disabled dest", r.d, 0x7f800000);

	/* inexact enabled, exact operation: raised early (Vol. 1 8.3.8) with
	 * no cause and no flag */
	c0 = COUNT;
	FPU_CASE(r, FPSCR_ENABLE_I, "fadd.s", ONE_S, ONE_S);
	CHECK("early inexact count", COUNT, c0 + 1);
	check_launch("early inexact", c0, VEC_EXC, EVT_FPUEXC, r.pc, sr0);
	CHECK("early inexact fpscr", r.fpscr, FPSCR_ENABLE_I);
	CHECK("early inexact dest", r.d, PRESET_S);

	/* the same operation with inexact not enabled */
	c0 = COUNT;
	FPU_CASE(r, 0, "fadd.s", ONE_S, ONE_S);
	CHECK("exact count", COUNT, c0);
	CHECK("exact fpscr", r.fpscr, 0);
	CHECK("exact dest", r.d, TWO_S);

	/* denormalized source, DN = 0: FPU error, CAUSE.E only (8.3.7) */
	c0 = COUNT;
	FPU_CASE(r, 0, "fadd.s", DENORM_S, ONE_S);
	CHECK("denorm count", COUNT, c0 + 1);
	check_launch("denorm", c0, VEC_EXC, EVT_FPUEXC, r.pc, sr0);
	CHECK("denorm fpscr", r.fpscr, FPSCR_CAUSE_E);
	CHECK("denorm dest", r.d, PRESET_S);

	/* denormalized source, DN = 1: flushed to zero, exact result (8.4.1) */
	c0 = COUNT;
	FPU_CASE(r, FPSCR_DN, "fadd.s", DENORM_S, ONE_S);
	CHECK("denorm dn count", COUNT, c0);
	CHECK("denorm dn fpscr", r.fpscr, FPSCR_DN);
	CHECK("denorm dn dest", r.d, ONE_S);

	__asm__ volatile("fmov.ls r63, fr32\n\tfputscr fr32" : : : "fr32");
}

/* ---- 13. SYNCI, SYNCO, NOP ---- */

static void t_sync(void)
{
	u64 c0 = COUNT, v;

	__asm__ volatile("movi 0x55, %0\n\tsynci\n\tsynco\n\tnop\n\taddi %0, 1, %0"
			 : "=&r"(v) : : "memory");
	CHECK("count", COUNT, c0);
	CHECK("value", v, 0x56);
	CHECK("expevt kept", GETCON("expevt"), REC(c0 - 1)->expevt);
}

int main(void)
{
	exc_area.ctl.exit_tra = 1ULL << 32;	/* no exit trap */
	exc_puts("exc: SH-5 exception test\n");
	run("trapa", t_trapa);
	run("resinst", t_resinst);
	run("user", t_user);
	run("fpudis", t_fpudis);
	run("iadderr", t_iadderr);
	run("adderr", t_adderr);
	run("panic", t_panic);
	run("brk", t_brk);
	run("nested", t_nested);
	run("cr", t_cr);
	run("cfg", t_cfg);
	run("fpuexc", t_fpuexc);
	run("sync", t_sync);
	exc_puts("exc: sleep not tested (needs an interrupt source)\n");
	exc_puts("isa: SUMMARY ");
	exc_putdec(exc_tests);
	exc_puts(" tests, ");
	exc_putdec(exc_failures);
	exc_puts(" failures\n");
	exc_puts("isa: DONE\n");
	for (;;)
		;
	return 0;
}
