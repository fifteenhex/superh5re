/*
 * Unit test for sh5_mm (SH-5 multimedia unit and MULU.L/MULS.L).
 *
 * Every instruction is driven through the 3-stage pipeline and result_o is
 * compared with the host-compiled references of tests/isa/groups/mmedia1.c
 * and mmedia2.c (ref_mm.h); MULU.L / MULS.L use the Vol. 2 pseudocode
 * directly.  Operands: the tests/isa corpus (every pair), all 64 shift
 * amounts, all 256 MPERM.W controls, and NRANDOM pseudo-random triples
 * (plain random words or words built from lane boundary values).
 *
 * Pipeline model: the result of the operands presented at clock edge k
 * appears after edge k+2, so a 3-deep queue of expected values is kept.
 * en_i = 0 cycles with changing inputs are inserted at random and also
 * explicitly; result_o must not change and the queued results must still
 * come out in order afterwards.
 */
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>

#include "Vsh5_mm.h"
#include "verilated.h"
#include "ref_mm.h"

extern "C" {
extern const unsigned long long isa_operands[];
extern const unsigned isa_num_operands;
}

typedef unsigned long long u64;

static u64 ref_mulu_l(u64 a, u64 b, u64) { return (u64)(uint32_t)a * (u64)(uint32_t)b; }
static u64 ref_muls_l(u64 a, u64 b, u64) { return (u64)((long long)(int32_t)a * (long long)(int32_t)b); }

struct Insn {
	const char *name;
	unsigned op, ext;
	bool shift;		/* Rn is a shift amount */
	u64 (*ref)(u64, u64, u64);
};

static const Insn insns[] = {
	/* opcode 000010 */
	{ "madd.w",     0x02,  1, false, ref_mm_madd_w },
	{ "madd.l",     0x02,  2, false, ref_mm_madd_l },
	{ "madds.ub",   0x02,  4, false, ref_mm_madds_ub },
	{ "madds.w",    0x02,  5, false, ref_mm_madds_w },
	{ "madds.l",    0x02,  6, false, ref_mm_madds_l },
	{ "msub.w",     0x02,  9, false, ref_mm_msub_w },
	{ "msub.l",     0x02, 10, false, ref_mm_msub_l },
	{ "msubs.ub",   0x02, 12, false, ref_mm_msubs_ub },
	{ "msubs.w",    0x02, 13, false, ref_mm_msubs_w },
	{ "msubs.l",    0x02, 14, false, ref_mm_msubs_l },
	/* opcode 000011 */
	{ "mshlld.w",   0x03,  1, true,  ref_mm_mshlld_w },
	{ "mshlld.l",   0x03,  2, true,  ref_mm_mshlld_l },
	{ "mshalds.w",  0x03,  5, true,  ref_mm_mshalds_w },
	{ "mshalds.l",  0x03,  6, true,  ref_mm_mshalds_l },
	{ "mshard.w",   0x03,  9, true,  ref_mm_mshard_w },
	{ "mshard.l",   0x03, 10, true,  ref_mm_mshard_l },
	{ "mshards.q",  0x03, 11, true,  ref_mm_mshards_q },
	{ "mshlrd.w",   0x03, 13, true,  ref_mm_mshlrd_w },
	{ "mshlrd.l",   0x03, 14, true,  ref_mm_mshlrd_l },
	/* opcode 001010 */
	{ "mcmpeq.b",   0x0a,  0, false, ref_mm_mcmpeq_b },
	{ "mcmpeq.w",   0x0a,  1, false, ref_mm_mcmpeq_w },
	{ "mcmpeq.l",   0x0a,  2, false, ref_mm_mcmpeq_l },
	{ "mcmpgt.ub",  0x0a,  4, false, ref_mm_mcmpgt_ub },
	{ "mcmpgt.w",   0x0a,  5, false, ref_mm_mcmpgt_w },
	{ "mcmpgt.l",   0x0a,  6, false, ref_mm_mcmpgt_l },
	{ "mextr1",     0x0a,  7, false, ref_mm_mextr1 },
	{ "mabs.w",     0x0a,  9, false, ref_mm_mabs_w },
	{ "mabs.l",     0x0a, 10, false, ref_mm_mabs_l },
	{ "mextr2",     0x0a, 11, false, ref_mm_mextr2 },
	{ "mperm.w",    0x0a, 13, false, ref_mm_mperm_w },
	{ "mextr3",     0x0a, 15, false, ref_mm_mextr3 },
	/* opcode 001011 */
	{ "mshflo.b",   0x0b,  0, false, ref_mm_mshflo_b },
	{ "mshflo.w",   0x0b,  1, false, ref_mm_mshflo_w },
	{ "mshflo.l",   0x0b,  2, false, ref_mm_mshflo_l },
	{ "mextr4",     0x0b,  3, false, ref_mm_mextr4 },
	{ "mshfhi.b",   0x0b,  4, false, ref_mm_mshfhi_b },
	{ "mshfhi.w",   0x0b,  5, false, ref_mm_mshfhi_w },
	{ "mshfhi.l",   0x0b,  6, false, ref_mm_mshfhi_l },
	{ "mextr5",     0x0b,  7, false, ref_mm_mextr5 },
	{ "mextr6",     0x0b, 11, false, ref_mm_mextr6 },
	{ "mextr7",     0x0b, 15, false, ref_mm_mextr7 },
	/* opcode 010010 */
	{ "msad.ubq",   0x12,  0, false, ref_mm_msad_ubq },
	{ "mmacfx.wl",  0x12,  1, false, ref_mm_mmacfx_wl },
	{ "mcmv",       0x12,  3, false, ref_mm_mcmv },
	{ "mmacnfx.wl", 0x12,  5, false, ref_mm_mmacnfx_wl },
	{ "mmulsum.wq", 0x12,  9, false, ref_mm_mmulsum_wq },
	/* opcode 010011 */
	{ "mmul.w",     0x13,  1, false, ref_mm_mmul_w },
	{ "mmul.l",     0x13,  2, false, ref_mm_mmul_l },
	{ "mmulfx.w",   0x13,  5, false, ref_mm_mmulfx_w },
	{ "mmulfx.l",   0x13,  6, false, ref_mm_mmulfx_l },
	{ "mcnvs.wb",   0x13,  8, false, ref_mm_mcnvs_wb },
	{ "mmulfxrp.w", 0x13,  9, false, ref_mm_mmulfxrp_w },
	{ "mmullo.wl",  0x13, 10, false, ref_mm_mmullo_wl },
	{ "mcnvs.wub",  0x13, 12, false, ref_mm_mcnvs_wub },
	{ "mcnvs.lw",   0x13, 13, false, ref_mm_mcnvs_lw },
	{ "mmulhi.wl",  0x13, 14, false, ref_mm_mmulhi_wl },
	/* opcodes 000000 / 000001, extension 1110 */
	{ "mulu.l",     0x00, 14, false, ref_mulu_l },
	{ "muls.l",     0x01, 14, false, ref_muls_l },
};
static const int NINSN = sizeof(insns) / sizeof(insns[0]);

#ifndef NRANDOM
#define NRANDOM 100000
#endif
#define MAX_REPORT 20

/* ---- pseudo-random operands ---- */

static u64 rng = 0x243f6a8885a308d3ULL;
static u64 rnd(void)
{
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return rng;
}

static const uint16_t bound16[16] = {
	0x0000, 0x0001, 0x007f, 0x0080, 0x00ff, 0x0100, 0x4000, 0x7fff,
	0x8000, 0x8001, 0xc000, 0xff00, 0xff7f, 0xff80, 0xfffe, 0xffff,
};
static const uint32_t bound32[16] = {
	0x00000000, 0x00000001, 0x7fffffff, 0x80000000, 0x80000001, 0xffffffff,
	0x40000000, 0xc0000000, 0x0000ffff, 0xffff0000, 0x00008000, 0x00007fff,
	0x7ffe0000, 0x80010000, 0xfffe0000, 0x0000007f,
};
static const uint8_t bound8[8] = { 0x00, 0x01, 0x7f, 0x80, 0x81, 0xfe, 0xff, 0x40 };

/* A word whose lanes of the given width are boundary values or random. */
static u64 lanes(int width)
{
	u64 r = rnd(), v = 0;
	int n = 64 / width;

	for (int i = 0; i < n; i++) {
		unsigned sel = (r >> (4 * i)) & 15;
		u64 lane;

		if (width == 8)
			lane = sel < 8 ? bound8[sel] : (rnd() & 0xff);
		else if (width == 16)
			lane = sel < 12 ? bound16[sel] : (rnd() & 0xffff);
		else
			lane = sel < 12 ? bound32[sel] : (rnd() & 0xffffffff);
		v |= lane << (width * i);
	}
	return v;
}

static void random_triple(u64 &a, u64 &b, u64 &c)
{
	switch (rnd() % 10) {
	case 0: case 1:
		a = rnd(); b = rnd(); c = rnd();
		break;
	case 2: case 3:
		a = lanes(16); b = lanes(16); c = lanes(32);
		break;
	case 4: case 5:
		a = lanes(32); b = lanes(32); c = rnd();
		break;
	case 6:
		a = lanes(8); b = lanes(8); c = lanes(8);
		break;
	case 7:	/* nearly equal lanes */
		a = lanes(16); b = a ^ (1ULL << (rnd() & 63)); c = rnd();
		break;
	case 8:	/* shift-amount-like Rn with garbage above */
		a = lanes(32); b = (rnd() << 6) | (rnd() & 63); c = lanes(32);
		break;
	default: /* saturated accumulators */
		a = lanes(16); b = lanes(16);
		c = (rnd() & 1) ? 0x7fffffff7fffffffULL : 0x8000000080000000ULL;
		c ^= (rnd() & 1) ? 0 : 0x00000000ffffffffULL;
		break;
	}
}

/* ---- pipeline driver ---- */

struct Pending {
	int insn;
	u64 a, b, c, want;
};

static Vsh5_mm *top;
static std::deque<Pending> queue;
static unsigned long checks[NINSN], fails[NINSN];
static unsigned long total_checks, total_fails, hold_cycles, hold_fails;

static void tick(void)
{
	top->clk = 0;
	top->eval();
	top->clk = 1;
	top->eval();
}

static void compare(const Pending &p)
{
	u64 got = top->result_o;

	checks[p.insn]++;
	total_checks++;
	if (got != p.want) {
		fails[p.insn]++;
		total_fails++;
		if (total_fails <= MAX_REPORT)
			printf("FAIL %-10s a=%016llx b=%016llx c=%016llx got=%016llx want=%016llx\n",
			       insns[p.insn].name, p.a, p.b, p.c, got, p.want);
	}
}

/* Present one instruction, advance one enabled cycle, check the result
 * that completes (if any). */
static void issue(int ii, u64 a, u64 b, u64 c)
{
	const Insn &in = insns[ii];
	Pending p = { ii, a, b, c, in.ref(a, b, c) };

	top->en_i = 1;
	top->op_i = in.op;
	top->ext_i = in.ext;
	top->a_i = a;
	top->b_i = b;
	top->c_i = c;
	tick();
	queue.push_back(p);
	if (queue.size() == 3) {
		compare(queue.front());
		queue.pop_front();
	}
}

/* n cycles with en_i = 0 and changing inputs: result_o must hold. */
static void hold(int n)
{
	u64 before = top->result_o;

	for (int i = 0; i < n; i++) {
		top->en_i = 0;
		top->op_i = rnd() & 63;
		top->ext_i = rnd() & 15;
		top->a_i = rnd();
		top->b_i = rnd();
		top->c_i = rnd();
		tick();
		hold_cycles++;
		if (top->result_o != before) {
			hold_fails++;
			if (hold_fails <= MAX_REPORT)
				printf("FAIL hold: result_o changed %016llx -> %016llx with en_i=0\n",
				       before, (u64)top->result_o);
		}
	}
}

/* Run the pending results out with madd.w of zeros so that every issued
 * check is scored. */
static void drain(void)
{
	while (!queue.empty()) {
		top->en_i = 1;
		top->op_i = insns[0].op;
		top->ext_i = insns[0].ext;
		top->a_i = top->b_i = top->c_i = 0;
		tick();
		compare(queue.front());
		queue.pop_front();
	}
}

static void all_insns(u64 a, u64 b, u64 c)
{
	for (int ii = 0; ii < NINSN; ii++)
		issue(ii, a, b, c);
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	top = new Vsh5_mm;
	top->clk = 0;
	top->en_i = 0;
	top->eval();

	unsigned long n_corpus, n_shift, n_perm, n_random;

	/* 1. Explicit hold test: fill the pipeline, freeze it, resume. */
	issue(0, 0x0001000200030004ULL, 0x0010002000300040ULL, 0);
	issue(1, 0x0000000100000002ULL, 0x0000001000000020ULL, 0);
	issue(2, 0x80ff7f0180ff7f01ULL, 0x80ff7f0180ff7f01ULL, 0);
	hold(16);
	issue(3, 0x7fff80007fff8000ULL, 0x0001ffff0001ffffULL, 0);
	hold(5);
	issue(4, 0x7fffffff80000000ULL, 0x0000000100000001ULL, 0);
	drain();

	/* 2. Corpus pairs on every instruction; Rw mixes both operands. */
	for (unsigned i = 0; i < isa_num_operands; i++)
		for (unsigned j = 0; j < isa_num_operands; j++) {
			u64 a = isa_operands[i], b = isa_operands[j];
			u64 c = a ^ ((b << 32) | (b >> 32));

			all_insns(a, b, c);
		}
	drain();
	n_corpus = total_checks;

	/* 3. Shifts: corpus data against every amount 0..63 with garbage
	 * above bit 5. */
	for (unsigned i = 0; i < isa_num_operands; i++)
		for (unsigned amt = 0; amt < 64; amt++) {
			u64 b = (rnd() << 6) | amt;

			for (int ii = 0; ii < NINSN; ii++)
				if (insns[ii].shift)
					issue(ii, isa_operands[i], b, 0);
		}
	drain();
	n_shift = total_checks - n_corpus;

	/* 4. MPERM.W: every control value, garbage in Rn bits 8..63. */
	for (unsigned ctrl = 0; ctrl < 256; ctrl++)
		for (unsigned i = 0; i < isa_num_operands; i++) {
			int ii = 0;

			while (strcmp(insns[ii].name, "mperm.w"))
				ii++;
			issue(ii, isa_operands[i], ctrl | (rnd() << 8), 0);
		}
	drain();
	n_perm = total_checks - n_corpus - n_shift;

	/* 5. Pseudo-random triples on every instruction with random stalls. */
	for (unsigned long t = 0; t < NRANDOM; t++) {
		u64 a, b, c;

		random_triple(a, b, c);
		for (int ii = 0; ii < NINSN; ii++) {
			issue(ii, a, b, c);
			if ((rnd() & 255) == 0)
				hold(1 + (rnd() & 3));
		}
	}
	drain();
	n_random = total_checks - n_corpus - n_shift - n_perm;

	top->final();

	printf("sh5_mm unit test: %d instructions\n", NINSN);
	printf("  %-11s %10s %6s\n", "instruction", "checks", "fails");
	for (int ii = 0; ii < NINSN; ii++)
		printf("  %-11s %10lu %6lu\n", insns[ii].name, checks[ii], fails[ii]);
	printf("corpus pairs: %lu checks; shift amounts: %lu; mperm.w controls: %lu; "
	       "%lu random triples: %lu checks\n",
	       n_corpus, n_shift, n_perm, (unsigned long)NRANDOM, n_random);
	printf("hold cycles (en_i=0): %lu, result changed: %lu\n", hold_cycles, hold_fails);
	printf("TOTAL %lu checks, %lu failures: %s\n", total_checks, total_fails + hold_fails,
	       (total_fails + hold_fails) ? "FAIL" : "PASS");

	delete top;
	return (total_fails + hold_fails) ? 1 : 0;
}
