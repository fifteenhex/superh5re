// Unit test of sh5_fpu: applies every table of tests/isa/groups/fpu_s_vectors.h
// and fpu_d_vectors.h through the issue/done interface, checks result_o and
// cause_o (as the FPSCR the core would write), checks trap_o against the
// exception launch rule of Vol. 1 8.3.8 for every ENABLE combination, adds
// directed FPU error cases, and cross-checks FADD/FSUB/FMUL/FDIV/FSQRT .S/.D of
// random normal operands against the host's IEEE754 arithmetic.
#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>

#include "Vsh5_fpu.h"
#include "verilated.h"

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int32_t s32;
typedef int64_t s64;

#include "fpu_s_vectors.h"
#include "fpu_d_vectors.h"

// opcode [31:26], extension [19:16] (Vol. 2 Tables 36-66)
struct Op { int op, ext; const char *name; };
static const Op FADDS{13, 0, "fadd.s"}, FADDD{13, 1, "fadd.d"}, FSUBS{13, 2, "fsub.s"},
    FSUBD{13, 3, "fsub.d"}, FDIVS{13, 4, "fdiv.s"}, FDIVD{13, 5, "fdiv.d"}, FMULS{13, 6, "fmul.s"},
    FMULD{13, 7, "fmul.d"}, FMACS{13, 14, "fmac.s"}, FSQRTS{14, 4, "fsqrt.s"}, FSQRTD{14, 5, "fsqrt.d"},
    FCNVSD{14, 6, "fcnv.sd"}, FCNVDS{14, 7, "fcnv.ds"}, FTRCSL{14, 8, "ftrc.sl"}, FTRCDQ{14, 9, "ftrc.dq"},
    FTRCSQ{14, 10, "ftrc.sq"}, FTRCDL{14, 11, "ftrc.dl"}, FLOATLS{14, 12, "float.ls"},
    FLOATQD{14, 13, "float.qd"}, FLOATLD{14, 14, "float.ld"}, FLOATQS{14, 15, "float.qs"},
    FCMPEQS{12, 8, "fcmpeq.s"}, FCMPEQD{12, 9, "fcmpeq.d"}, FCMPUNS{12, 10, "fcmpun.s"},
    FCMPUND{12, 11, "fcmpun.d"}, FCMPGTS{12, 12, "fcmpgt.s"}, FCMPGTD{12, 13, "fcmpgt.d"},
    FCMPGES{12, 14, "fcmpge.s"}, FCMPGED{12, 15, "fcmpge.d"}, FIPRS{5, 6, "fipr.s"}, FTRVS{5, 14, "ftrv.s"},
    FSINAS{6, 8, "fsina.s"}, FSRRAS{6, 10, "fsrra.s"}, FCOSAS{6, 12, "fcosa.s"};

enum { C_I = 1, C_U = 2, C_O = 4, C_Z = 8, C_V = 16, C_E = 32 };
enum { EN_I = 1, EN_U = 2, EN_O = 4, EN_Z = 8, EN_V = 16 };
static const u32 FPSCR_MASK = 0x7fffd;

struct Res {
  u32 r[4];
  u64 r64;
  u32 cause;
  bool trap;
  u32 tag;
  int cycles;
};

static Vsh5_fpu *dut;
static u64 total_cycles;

// latency (clocks from the accepting edge to done_o) per operation
struct Lat { const char *name; int lo, hi; };
static Lat lat[64];
static int n_lat;
static void note_latency(const char *name, int cycles) {
  for (int i = 0; i < n_lat; i++)
    if (lat[i].name == name) {
      if (cycles < lat[i].lo) lat[i].lo = cycles;
      if (cycles > lat[i].hi) lat[i].hi = cycles;
      return;
    }
  if (n_lat < 64) lat[n_lat++] = Lat{name, cycles, cycles};
}
static long n_checks, n_fail;
static u32 next_tag;

static void tick() {
  dut->clk = 0;
  dut->eval();
  dut->clk = 1;
  dut->eval();
  total_cycles++;
}

static Res run(const Op &o, u64 a, u64 b, u64 c, const u32 *va, const u32 *vb, const u32 *mtrx, u32 fpscr) {
  Res r{};
  dut->op_i = o.op;
  dut->ext_i = o.ext;
  dut->a_i = a;
  dut->b_i = b;
  dut->c_i = c;
  for (int i = 0; i < 4; i++) {
    dut->va_i[i] = va ? va[i] : 0;
    dut->vb_i[i] = vb ? vb[i] : 0;
  }
  for (int i = 0; i < 16; i++) dut->mtrx_i[i] = mtrx ? mtrx[i] : 0;
  dut->fpscr_i = fpscr;
  dut->tag_i = next_tag;
  dut->issue_i = 1;
  dut->clk = 0;
  dut->eval();
  int wait = 0;
  while (!dut->ready_o) {
    tick();
    dut->clk = 0;
    dut->eval();
    if (++wait > 1000) { printf("FATAL: ready_o stuck\n"); exit(1); }
  }
  r.trap = dut->trap_o;
  tick();
  dut->issue_i = 0;
  r.cycles = 1;
  while (!dut->done_o) {
    tick();
    if (++r.cycles > 1000) { printf("FATAL: done_o never asserted\n"); exit(1); }
  }
  for (int i = 0; i < 4; i++) r.r[i] = dut->result_o[i];
  r.r64 = ((u64)r.r[1] << 32) | r.r[0];
  r.cause = dut->cause_o;
  r.tag = dut->tag_o;
  note_latency(o.name, r.cycles);
  if (r.tag != (next_tag & 0xff)) { printf("FATAL: tag mismatch\n"); exit(1); }
  next_tag++;
  return r;
}

// FPSCR after the operation, as the core forms it: CAUSE replaced, FLAG accumulated
static u32 fps_new(u32 in, u32 cause) {
  return ((in & ~0x3f000u) | (cause << 12) | ((cause & 0x1f) << 2)) & FPSCR_MASK;
}

static s32 fkey(u32 b) {
  s32 m = b & 0x7fffffff;
  return (b & 0x80000000) ? -m : m;
}

static bool in_range(u32 got, u32 lo, u32 hi) {
  if (lo == hi) return got == lo;
  return fkey(got) >= fkey(lo) && fkey(got) <= fkey(hi);
}

static void check(bool ok, const char *what, const char *insn, u64 a, u64 b, u64 c, u64 got, u64 want, u32 fps) {
  n_checks++;
  if (!ok) {
    n_fail++;
    if (n_fail <= 60)
      printf("FAIL %-9s %-7s a=%016llx b=%016llx c=%016llx fpscr=%05x got=%016llx want=%016llx\n", insn, what,
             (unsigned long long)a, (unsigned long long)b, (unsigned long long)c, fps, (unsigned long long)got,
             (unsigned long long)want);
  }
}

// Exception launch rule (Vol. 1 8.3.8 and the Vol. 2 instruction pseudocode),
// from the operation's CAUSE bits and FPSCR.ENABLE.
static bool trap_rule(const Op &o, u32 cause, u32 en) {
  bool v = (en & EN_V) && (cause & C_V);
  bool z = (en & EN_Z) && (cause & C_Z);
  bool e = cause & C_E;
  bool iou = en & (EN_I | EN_O | EN_U);
  bool i = en & EN_I;
  switch (o.op) {
  case 13:
    if (o.ext == 4 || o.ext == 5) return v | z | e | iou;      // FDIV
    return v | e | iou;                                        // FADD FSUB FMUL FMAC
  case 14:
    switch (o.ext) {
    case 4: case 5: return v | e | i;                          // FSQRT
    case 6: return v | e;                                      // FCNV.SD
    case 7: return v | e | iou;                                // FCNV.DS
    case 8: case 9: case 10: case 11: return v;                // FTRC
    case 14: return false;                                     // FLOAT.LD
    default: return i;                                         // FLOAT.LS/QS/QD
    }
  case 12: return v;                                           // compares
  case 5:
    if (o.ext == 6) return v | iou;                            // FIPR
    return (en & EN_V) || iou;                                 // FTRV
  case 6:
    if (o.ext == 10) return v | z | e | i;                     // FSRRA
    return i;                                                  // FSINA FCOSA
  }
  return false;
}

static long n_trap_checks, n_trap_fail;

// Run a vector with ENABLE = 0 (returning the result) and with the ENABLE
// pattern derived from its index; trap_o must follow trap_rule on the
// operation's actual CAUSE bits and result/cause must not change.
static Res run_checked(const Op &o, u64 a, u64 b, u64 c, const u32 *va, const u32 *vb, const u32 *mtrx, u32 fps,
                       long idx) {
  Res r = run(o, a, b, c, va, vb, mtrx, fps);
  n_trap_checks++;
  bool want0 = trap_rule(o, r.cause, 0);
  if (r.trap != want0) {
    n_trap_fail++;
    if (n_trap_fail <= 40)
      printf("FAIL %-9s trap    a=%016llx b=%016llx fpscr=%05x cause=%02x got=%d want=%d\n", o.name,
             (unsigned long long)a, (unsigned long long)b, fps, r.cause, r.trap, want0);
  }
  u32 en = (u32)((idx * 7 + 1) & 31);
  if (en == 0) en = 31;
  u32 fps2 = fps | (en << 7);
  Res r2 = run(o, a, b, c, va, vb, mtrx, fps2);
  bool want = trap_rule(o, r.cause, en);
  n_trap_checks++;
  bool same = r2.cause == r.cause && memcmp(r2.r, r.r, sizeof r.r) == 0;
  if (r2.trap != want || !same) {
    n_trap_fail++;
    if (n_trap_fail <= 40)
      printf("FAIL %-9s trap    a=%016llx b=%016llx fpscr=%05x cause=%02x/%02x got=%d want=%d same=%d\n", o.name,
             (unsigned long long)a, (unsigned long long)b, fps2, r.cause, r2.cause, r2.trap, want, same);
  }
  return r;
}

#define N(t) (sizeof(t) / sizeof((t)[0]))

static void table_v2(const Op &o, const struct fpu_s_v2 *t, size_t n, bool dyadic, bool cmp) {
  long before = n_checks, fails = n_fail;
  for (size_t i = 0; i < n; i++) {
    Res r = run_checked(o, t[i].a, dyadic ? t[i].b : 0, 0, nullptr, nullptr, nullptr, t[i].fps_in, (long)i);
    u32 got = cmp ? (r.r[0] & 1) : r.r[0];
    check(got == t[i].want, "result", o.name, t[i].a, t[i].b, 0, got, t[i].want, t[i].fps_in);
    check(fps_new(t[i].fps_in, r.cause) == (t[i].fps_want & FPSCR_MASK), "fpscr", o.name, t[i].a, t[i].b, 0,
          fps_new(t[i].fps_in, r.cause), t[i].fps_want & FPSCR_MASK, t[i].fps_in);
  }
  printf("  %-9s %6zu vectors %6ld checks %4ld failures\n", o.name, n, n_checks - before, n_fail - fails);
}

static void table_vq(const Op &o, const struct fpu_s_vq *t, size_t n, bool res64) {
  long before = n_checks, fails = n_fail;
  for (size_t i = 0; i < n; i++) {
    Res r = run_checked(o, t[i].a, 0, 0, nullptr, nullptr, nullptr, t[i].fps_in, (long)i);
    u64 got = res64 ? r.r64 : r.r[0];
    u64 want = res64 ? t[i].want : (u32)t[i].want;
    check(got == want, "result", o.name, t[i].a, 0, 0, got, want, t[i].fps_in);
    check(fps_new(t[i].fps_in, r.cause) == (t[i].fps_want & FPSCR_MASK), "fpscr", o.name, t[i].a, 0, 0,
          fps_new(t[i].fps_in, r.cause), t[i].fps_want & FPSCR_MASK, t[i].fps_in);
  }
  printf("  %-9s %6zu vectors %6ld checks %4ld failures\n", o.name, n, n_checks - before, n_fail - fails);
}

static void table_vr(const Op &o, const struct fpu_s_vr *t, size_t n) {
  long before = n_checks, fails = n_fail;
  for (size_t i = 0; i < n; i++) {
    Res r = run_checked(o, t[i].a, 0, 0, nullptr, nullptr, nullptr, t[i].fps_in, (long)i);
    check(in_range(r.r[0], t[i].lo, t[i].hi), "range", o.name, t[i].a, t[i].lo, t[i].hi, r.r[0], t[i].lo,
          t[i].fps_in);
    check(fps_new(t[i].fps_in, r.cause) == (t[i].fps_want & FPSCR_MASK), "fpscr", o.name, t[i].a, 0, 0,
          fps_new(t[i].fps_in, r.cause), t[i].fps_want & FPSCR_MASK, t[i].fps_in);
  }
  printf("  %-9s %6zu vectors %6ld checks %4ld failures\n", o.name, n, n_checks - before, n_fail - fails);
}

static void table_fmac() {
  long before = n_checks, fails = n_fail;
  size_t n = N(fpu_s_fmac);
  for (size_t i = 0; i < n; i++) {
    const struct fpu_s_v3 &v = fpu_s_fmac[i];
    Res r = run_checked(FMACS, v.a, v.b, v.c, nullptr, nullptr, nullptr, v.fps_in, (long)i);
    check(r.r[0] == v.want, "result", "fmac.s", v.a, v.b, v.c, r.r[0], v.want, v.fps_in);
    check(fps_new(v.fps_in, r.cause) == (v.fps_want & FPSCR_MASK), "fpscr", "fmac.s", v.a, v.b, v.c,
          fps_new(v.fps_in, r.cause), v.fps_want & FPSCR_MASK, v.fps_in);
  }
  printf("  %-9s %6zu vectors %6ld checks %4ld failures\n", "fmac.s", n, n_checks - before, n_fail - fails);
}

static void table_fipr() {
  long before = n_checks, fails = n_fail;
  size_t n = N(fpu_s_fipr);
  for (size_t i = 0; i < n; i++) {
    const struct fpu_s_vipr &v = fpu_s_fipr[i];
    Res r = run_checked(FIPRS, 0, 0, 0, v.v, v.v + 4, nullptr, v.fps_in, (long)i);
    check(in_range(r.r[0], v.lo, v.hi), "range", "fipr.s", i, v.lo, v.hi, r.r[0], v.lo, v.fps_in);
    check(fps_new(v.fps_in, r.cause) == (v.fps_want & FPSCR_MASK), "fpscr", "fipr.s", i, 0, 0,
          fps_new(v.fps_in, r.cause), v.fps_want & FPSCR_MASK, v.fps_in);
  }
  printf("  %-9s %6zu vectors %6ld checks %4ld failures\n", "fipr.s", n, n_checks - before, n_fail - fails);
}

static void table_ftrv() {
  long before = n_checks, fails = n_fail;
  size_t n = N(fpu_s_ftrv);
  for (size_t i = 0; i < n; i++) {
    const struct fpu_s_vtrv &v = fpu_s_ftrv[i];
    Res r = run_checked(FTRVS, 0, 0, 0, v.v, nullptr, v.m, v.fps_in, (long)i);
    for (int j = 0; j < 4; j++)
      check(in_range(r.r[j], v.lo[j], v.hi[j]), "range", "ftrv.s", ((u64)j << 32) | i, v.lo[j], v.hi[j], r.r[j],
            v.lo[j], v.fps_in);
    check(fps_new(v.fps_in, r.cause) == (v.fps_want & FPSCR_MASK), "fpscr", "ftrv.s", i, 0, 0,
          fps_new(v.fps_in, r.cause), v.fps_want & FPSCR_MASK, v.fps_in);
  }
  printf("  %-9s %6zu vectors %6ld checks %4ld failures\n", "ftrv.s", n, n_checks - before, n_fail - fails);
}

static void table_d_dyadic(const Op &o, const struct fpd_dyadic *t, size_t n, const char *label) {
  long before = n_checks, fails = n_fail;
  for (size_t i = 0; i < n; i++) {
    u64 a = fpd_vals[t[i].a], b = fpd_vals[t[i].b];
    u32 mode = fpd_modes[t[i].m];
    Res r = run_checked(o, a, b, 0, nullptr, nullptr, nullptr, mode, (long)i);
    check(r.r64 == t[i].r, "result", o.name, a, b, 0, r.r64, t[i].r, mode);
    check(fps_new(mode, r.cause) == (t[i].fpscr & FPSCR_MASK), "fpscr", o.name, a, b, 0, fps_new(mode, r.cause),
          t[i].fpscr & FPSCR_MASK, mode);
  }
  printf("  %-9s %-4s %6zu vectors %6ld checks %4ld failures\n", o.name, label, n, n_checks - before,
         n_fail - fails);
}

static void table_d_cmp() {
  long before = n_checks, fails = n_fail;
  size_t n = N(fpd_cmp_vec);
  const Op *ops[4] = {&FCMPEQD, &FCMPGTD, &FCMPGED, &FCMPUND};
  for (size_t i = 0; i < n; i++) {
    const struct fpd_cmp &v = fpd_cmp_vec[i];
    u64 a = fpd_vals[v.a], b = fpd_vals[v.b];
    u32 mode = fpd_modes[v.m];
    for (int k = 0; k < 4; k++) {
      Res r = run_checked(*ops[k], a, b, 0, nullptr, nullptr, nullptr, mode, (long)(i * 4 + k));
      u32 want_scr = (mode | (((v.inv >> k) & 1) ? 0x10040u : 0)) & FPSCR_MASK;
      check((r.r[0] & 1) == ((v.res >> k) & 1), "result", ops[k]->name, a, b, 0, r.r[0] & 1, (v.res >> k) & 1,
            mode);
      check(fps_new(mode, r.cause) == want_scr, "fpscr", ops[k]->name, a, b, 0, fps_new(mode, r.cause), want_scr,
            mode);
    }
  }
  printf("  %-9s      %6zu vectors %6ld checks %4ld failures\n", "fcmp*.d", n * 4, n_checks - before,
         n_fail - fails);
}

// kind: 0 64->64, 1 64->32, 2 32->64
static void table_d_monadic(const Op &o, const struct fpd_monadic *t, size_t n, int kind, const char *label) {
  long before = n_checks, fails = n_fail;
  for (size_t i = 0; i < n; i++) {
    Res r = run_checked(o, t[i].a, 0, 0, nullptr, nullptr, nullptr, t[i].fpscr_in, (long)i);
    u64 got = (kind == 1) ? r.r[0] : r.r64;
    check(got == t[i].r, "result", o.name, t[i].a, 0, 0, got, t[i].r, t[i].fpscr_in);
    check(fps_new(t[i].fpscr_in, r.cause) == (t[i].fpscr & FPSCR_MASK), "fpscr", o.name, t[i].a, 0, 0,
          fps_new(t[i].fpscr_in, r.cause), t[i].fpscr & FPSCR_MASK, t[i].fpscr_in);
  }
  printf("  %-9s %-4s %6zu vectors %6ld checks %4ld failures\n", o.name, label, n, n_checks - before,
         n_fail - fails);
}

// Directed cases: FPU error (denormalized source, DN = 0) and the always-early
// traps, checked for every ENABLE pattern.
struct Directed { const Op *o; u64 a, b, c; u32 cause; };
static void directed_traps() {
  long before = n_trap_checks, fails = n_trap_fail;
  static const Directed cases[] = {
      {&FADDS, 0x00000001, 0x3f800000, 0, C_E},
      {&FSUBD, 0x3ff0000000000000ull, 0x0000000000000001ull, 0, C_E},
      {&FMULS, 0x3f800000, 0x80000001, 0, C_E},
      {&FMULD, 0x0008000000000000ull, 0x7ff0000000000000ull, 0, C_E},   // denormal * inf: error, not invalid
      {&FDIVS, 0x3f800000, 0x00000001, 0, C_E},
      {&FDIVS, 0x00000001, 0x3f800000, 0, C_E},
      {&FDIVS, 0x00000001, 0x00000000, 0, C_Z},                          // denormal / 0: divide by zero
      {&FDIVD, 0x3ff0000000000000ull, 0x0000000000000000ull, 0, C_Z},
      {&FDIVD, 0x0000000000000000ull, 0x0000000000000000ull, 0, C_V},
      {&FSQRTS, 0x00000001, 0, 0, C_E},
      {&FSQRTS, 0x80000001, 0, 0, C_V},                                  // negative denormal: invalid
      {&FSQRTD, 0x0000000000000001ull, 0, 0, C_E},
      {&FSRRAS, 0x00000001, 0, 0, C_E},
      {&FSRRAS, 0x00000000, 0, 0, C_Z},
      {&FSRRAS, 0xbf800000, 0, 0, C_V},
      {&FMACS, 0x3f800000, 0x3f800000, 0x00000001, C_E},
      {&FMACS, 0x00000000, 0x7f800000, 0x00000001, C_V},                 // 0 * inf before the error check
      {&FMACS, 0x7fc00000, 0x00000001, 0x3f800000, C_V},
      {&FCNVDS, 0x0000000000000001ull, 0, 0, C_E},
      {&FCNVSD, 0x00000001, 0, 0, C_E},
      {&FCNVSD, 0x7fc00000, 0, 0, C_V},
      {&FADDS, 0x00000001, 0x7fbfffff, 0, 0},                            // denormal with qNaN: no error
      {&FADDS, 0x7f800000, 0xff800000, 0, C_V},
      {&FMULS, 0x00000000, 0x7f800000, 0, C_V},
      {&FTRCSL, 0x00000001, 0, 0, 0},                                    // FTRC accepts denormals
      {&FTRCSL, 0x4f000000, 0, 0, C_V},
      {&FTRCDQ, 0x7ff8000000000000ull, 0, 0, C_V},
      {&FCMPEQS, 0x00000001, 0x00000001, 0, 0},
      {&FCMPGTS, 0x7fbfffff, 0x00000001, 0, C_V},
      {&FCMPUNS, 0x7fc00000, 0x00000001, 0, C_V},
  };
  u32 vec_den[4] = {0x00000001, 0x3f800000, 0x3f800000, 0x3f800000};
  u32 vec_one[4] = {0x3f800000, 0x3f800000, 0x3f800000, 0x3f800000};
  u32 vec_inv[4] = {0x7f800000, 0x3f800000, 0x3f800000, 0x3f800000};
  u32 vec_zero[4] = {0, 0x3f800000, 0x3f800000, 0x3f800000};
  u32 mtrx[16];
  for (int i = 0; i < 16; i++) mtrx[i] = (i % 5 == 0) ? 0x3f800000 : 0;
  for (u32 en = 0; en < 32; en++) {
    u32 fps = en << 7;
    for (const Directed &d : cases) {
      Res r = run(*d.o, d.a, d.b, d.c, nullptr, nullptr, nullptr, fps);
      bool want = trap_rule(*d.o, d.cause, en);
      n_trap_checks += 2;
      if (r.cause != d.cause || r.trap != want) {
        n_trap_fail++;
        if (n_trap_fail <= 40)
          printf("FAIL %-9s dtrap   a=%016llx b=%016llx en=%02x cause=%02x/%02x trap=%d/%d\n", d.o->name,
                 (unsigned long long)d.a, (unsigned long long)d.b, en, r.cause, d.cause, r.trap, want);
      }
    }
    // FIPR.S with a denormal: no FPU error; FIPR.S inf*0: invalid
    Res r = run(FIPRS, 0, 0, 0, vec_den, vec_one, nullptr, fps);
    n_trap_checks++;
    if (r.cause != C_I || r.trap != trap_rule(FIPRS, C_I, en)) { n_trap_fail++; printf("FAIL fipr.s dtrap den en=%02x\n", en); }
    r = run(FIPRS, 0, 0, 0, vec_inv, vec_zero, nullptr, fps);
    n_trap_checks++;
    if (r.cause != C_V || r.trap != trap_rule(FIPRS, C_V, en)) { n_trap_fail++; printf("FAIL fipr.s dtrap inv en=%02x\n", en); }
    // FTRV.S with normal operands: trap whenever V, I, O or U is enabled
    r = run(FTRVS, 0, 0, 0, vec_one, nullptr, mtrx, fps);
    n_trap_checks++;
    if (r.cause != C_I || r.trap != trap_rule(FTRVS, C_I, en)) { n_trap_fail++; printf("FAIL ftrv.s dtrap en=%02x\n", en); }
    // FLOAT.LD never traps, FLOAT.LS traps on ENABLE.I even when exact
    r = run(FLOATLD, 3, 0, 0, nullptr, nullptr, nullptr, fps);
    n_trap_checks++;
    if (r.trap || r.cause) { n_trap_fail++; printf("FAIL float.ld dtrap en=%02x\n", en); }
    r = run(FLOATLS, 3, 0, 0, nullptr, nullptr, nullptr, fps);
    n_trap_checks++;
    if (r.trap != ((en & EN_I) != 0) || r.cause) { n_trap_fail++; printf("FAIL float.ls dtrap en=%02x\n", en); }
    // FADD.S exact with I enabled: early trap, CAUSE = 0
    r = run(FADDS, 0x3f800000, 0x3f800000, 0, nullptr, nullptr, nullptr, fps);
    n_trap_checks++;
    if (r.trap != ((en & (EN_I | EN_O | EN_U)) != 0) || r.cause || r.r[0] != 0x40000000) {
      n_trap_fail++;
      printf("FAIL fadd.s dtrap exact en=%02x\n", en);
    }
    // DN = 1: the denormal is flushed, no error
    r = run(FADDS, 0x00000001, 0x3f800000, 0, nullptr, nullptr, nullptr, fps | 0x40000);
    n_trap_checks++;
    if (r.cause || r.r[0] != 0x3f800000 || r.trap != ((en & (EN_I | EN_O | EN_U)) != 0)) {
      n_trap_fail++;
      printf("FAIL fadd.s dtrap dn en=%02x\n", en);
    }
  }
  printf("  directed trap cases: %ld checks %ld failures\n", n_trap_checks - before, n_trap_fail - fails);
}

// ---------------------------------------------------------------- random --
static std::mt19937_64 rng(0x5a5a1234abcdull);

static u32 rnd_f32(int emin, int emax) {
  u32 s = (u32)(rng() & 1) << 31;
  u32 e = (u32)(emin + (int)(rng() % (u64)(emax - emin + 1)));
  u32 f = (u32)(rng() & 0x7fffff);
  return s | (e << 23) | f;
}

static u64 rnd_f64(int emin, int emax) {
  u64 s = (rng() & 1) << 63;
  u64 e = (u64)(emin + (int)(rng() % (u64)(emax - emin + 1)));
  u64 f = rng() & 0xfffffffffffffull;
  return s | (e << 52) | f;
}

static u32 host_flags() {
  int f = fetestexcept(FE_ALL_EXCEPT);
  u32 c = 0;
  if (f & FE_INEXACT) c |= C_I;
  if (f & FE_UNDERFLOW) c |= C_U;
  if (f & FE_OVERFLOW) c |= C_O;
  if (f & FE_DIVBYZERO) c |= C_Z;
  if (f & FE_INVALID) c |= C_V;
  return c;
}

static void random_single(int n) {
  long before = n_checks, fails = n_fail;
  const Op *ops[5] = {&FADDS, &FSUBS, &FMULS, &FDIVS, &FSQRTS};
  for (int k = 0; k < n; k++) {
    int rm = k & 1;
    fesetround(rm ? FE_TOWARDZERO : FE_TONEAREST);
    int op = k % 5;
    // exponent ranges: wide (overflow/underflow), near each other (cancellation), full
    u32 a, b;
    switch ((k / 5) % 3) {
    case 0: a = rnd_f32(1, 254); b = rnd_f32(1, 254); break;
    case 1: a = rnd_f32(100, 154); b = rnd_f32(100, 154); break;
    default: a = rnd_f32(1, 254); b = (a & 0x7f800000) | (u32)(rng() & 0x807fffff); break;
    }
    if (op == 4) a &= 0x7fffffff;
    volatile float fa, fb, fr;
    memcpy((void *)&fa, &a, 4);
    memcpy((void *)&fb, &b, 4);
    feclearexcept(FE_ALL_EXCEPT);
    switch (op) {
    case 0: fr = fa + fb; break;
    case 1: fr = fa - fb; break;
    case 2: fr = fa * fb; break;
    case 3: fr = fa / fb; break;
    default: fr = sqrtf(fa); break;
    }
    u32 hflags = host_flags();
    u32 want;
    float tmp = fr;
    memcpy(&want, &tmp, 4);
    Res r = run(*ops[op], a, op == 4 ? 0 : b, 0, nullptr, nullptr, nullptr, (u32)rm);
    check(r.r[0] == want, "result", ops[op]->name, a, b, 0, r.r[0], want, rm);
    check(r.cause == hflags, "flags", ops[op]->name, a, b, 0, r.cause, hflags, rm);
  }
  fesetround(FE_TONEAREST);
  printf("  random single %d cases %ld checks %ld failures\n", n, n_checks - before, n_fail - fails);
}

static void random_double(int n) {
  long before = n_checks, fails = n_fail;
  const Op *ops[5] = {&FADDD, &FSUBD, &FMULD, &FDIVD, &FSQRTD};
  for (int k = 0; k < n; k++) {
    int rm = k & 1;
    fesetround(rm ? FE_TOWARDZERO : FE_TONEAREST);
    int op = k % 5;
    u64 a, b;
    switch ((k / 5) % 3) {
    case 0: a = rnd_f64(1, 2046); b = rnd_f64(1, 2046); break;
    case 1: a = rnd_f64(900, 1150); b = rnd_f64(900, 1150); break;
    default: a = rnd_f64(1, 2046); b = (a & 0x7ff0000000000000ull) | (rng() & 0x800fffffffffffffull); break;
    }
    if (op == 4) a &= 0x7fffffffffffffffull;
    volatile double fa, fb, fr;
    memcpy((void *)&fa, &a, 8);
    memcpy((void *)&fb, &b, 8);
    feclearexcept(FE_ALL_EXCEPT);
    switch (op) {
    case 0: fr = fa + fb; break;
    case 1: fr = fa - fb; break;
    case 2: fr = fa * fb; break;
    case 3: fr = fa / fb; break;
    default: fr = sqrt(fa); break;
    }
    u32 hflags = host_flags();
    u64 want;
    double tmp = fr;
    memcpy(&want, &tmp, 8);
    Res r = run(*ops[op], a, op == 4 ? 0 : b, 0, nullptr, nullptr, nullptr, (u32)rm);
    check(r.r64 == want, "result", ops[op]->name, a, b, 0, r.r64, want, rm);
    check(r.cause == hflags, "flags", ops[op]->name, a, b, 0, r.cause, hflags, rm);
  }
  fesetround(FE_TONEAREST);
  printf("  random double %d cases %ld checks %ld failures\n", n, n_checks - before, n_fail - fails);
}

// Back-to-back issue: results must come back in issue order with their tags.
static void ordering_test() {
  long before = n_checks, fails = n_fail;
  // issue a division then an addition without waiting for the first result
  dut->issue_i = 0;
  dut->clk = 0;
  dut->eval();
  while (!dut->ready_o) tick();
  dut->op_i = FDIVS.op; dut->ext_i = FDIVS.ext; dut->a_i = 0x3f800000; dut->b_i = 0x40400000; dut->fpscr_i = 0;
  dut->tag_i = 0x11; dut->issue_i = 1;
  dut->eval();
  tick();
  dut->op_i = FADDS.op; dut->ext_i = FADDS.ext; dut->a_i = 0x3f800000; dut->b_i = 0x3f800000; dut->tag_i = 0x22;
  int seen = 0, cyc = 0;
  while (seen < 2 && cyc < 400) {
    dut->clk = 0;
    dut->eval();
    bool accepted = dut->issue_i && dut->ready_o;
    tick();
    cyc++;
    if (accepted) dut->issue_i = 0;
    if (dut->done_o) {
      if (seen == 0) {
        check(dut->tag_o == 0x11 && dut->result_o[0] == 0x3eaaaaab && dut->cause_o == C_I, "order", "fdiv.s", 0, 0, 0,
              dut->result_o[0], 0x3eaaaaab, dut->tag_o);
      } else {
        check(dut->tag_o == 0x22 && dut->result_o[0] == 0x40000000 && dut->cause_o == 0, "order", "fadd.s", 0, 0, 0,
              dut->result_o[0], 0x40000000, dut->tag_o);
      }
      seen++;
    }
  }
  check(seen == 2, "order", "count", 0, 0, 0, seen, 2, 0);
  printf("  ordering: %ld checks %ld failures\n", n_checks - before, n_fail - fails);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vsh5_fpu;
  dut->clk = 0;
  dut->rst_n = 0;
  dut->issue_i = 0;
  dut->eval();
  tick();
  tick();
  dut->rst_n = 1;
  tick();

  printf("fpu_s_vectors.h\n");
  table_v2(FADDS, fpu_s_fadd, N(fpu_s_fadd), true, false);
  table_v2(FSUBS, fpu_s_fsub, N(fpu_s_fsub), true, false);
  table_v2(FMULS, fpu_s_fmul, N(fpu_s_fmul), true, false);
  table_v2(FDIVS, fpu_s_fdiv, N(fpu_s_fdiv), true, false);
  table_v2(FSQRTS, fpu_s_fsqrt, N(fpu_s_fsqrt), false, false);
  table_v2(FCMPEQS, fpu_s_fcmpeq, N(fpu_s_fcmpeq), true, true);
  table_v2(FCMPGTS, fpu_s_fcmpgt, N(fpu_s_fcmpgt), true, true);
  table_v2(FCMPGES, fpu_s_fcmpge, N(fpu_s_fcmpge), true, true);
  table_v2(FCMPUNS, fpu_s_fcmpun, N(fpu_s_fcmpun), true, true);
  table_vq(FTRCSL, fpu_s_ftrcsl, N(fpu_s_ftrcsl), false);
  table_vq(FTRCSQ, fpu_s_ftrcsq, N(fpu_s_ftrcsq), true);
  table_vq(FLOATLS, fpu_s_floatls, N(fpu_s_floatls), false);
  table_vq(FLOATQS, fpu_s_floatqs, N(fpu_s_floatqs), false);
  table_fmac();
  table_vr(FSINAS, fpu_s_fsina, N(fpu_s_fsina));
  table_vr(FCOSAS, fpu_s_fcosa, N(fpu_s_fcosa));
  table_vr(FSRRAS, fpu_s_fsrra, N(fpu_s_fsrra));
  table_fipr();
  table_ftrv();

  printf("fpu_d_vectors.h\n");
  table_d_dyadic(FADDD, fpd_fadd_vec, N(fpd_fadd_vec), "");
  table_d_dyadic(FADDD, fpd_fadd_nan_vec, N(fpd_fadd_nan_vec), "nan");
  table_d_dyadic(FSUBD, fpd_fsub_vec, N(fpd_fsub_vec), "");
  table_d_dyadic(FSUBD, fpd_fsub_nan_vec, N(fpd_fsub_nan_vec), "nan");
  table_d_dyadic(FMULD, fpd_fmul_vec, N(fpd_fmul_vec), "");
  table_d_dyadic(FMULD, fpd_fmul_nan_vec, N(fpd_fmul_nan_vec), "nan");
  table_d_dyadic(FDIVD, fpd_fdiv_vec, N(fpd_fdiv_vec), "");
  table_d_dyadic(FDIVD, fpd_fdiv_nan_vec, N(fpd_fdiv_nan_vec), "nan");
  table_d_cmp();
  table_d_monadic(FSQRTD, fpd_fsqrt_vec, N(fpd_fsqrt_vec), 0, "");
  table_d_monadic(FSQRTD, fpd_fsqrt_nan_vec, N(fpd_fsqrt_nan_vec), 0, "nan");
  table_d_monadic(FCNVDS, fpd_fcnv_ds_vec, N(fpd_fcnv_ds_vec), 1, "");
  table_d_monadic(FCNVDS, fpd_fcnv_ds_nan_vec, N(fpd_fcnv_ds_nan_vec), 1, "nan");
  table_d_monadic(FCNVSD, fpd_fcnv_sd_vec, N(fpd_fcnv_sd_vec), 2, "");
  table_d_monadic(FCNVSD, fpd_fcnv_sd_nan_vec, N(fpd_fcnv_sd_nan_vec), 2, "nan");
  table_d_monadic(FTRCDL, fpd_ftrc_dl_vec, N(fpd_ftrc_dl_vec), 1, "");
  table_d_monadic(FTRCDQ, fpd_ftrc_dq_vec, N(fpd_ftrc_dq_vec), 0, "");
  table_d_monadic(FLOATLD, fpd_float_ld_vec, N(fpd_float_ld_vec), 2, "");
  table_d_monadic(FLOATQD, fpd_float_qd_vec, N(fpd_float_qd_vec), 0, "");

  printf("trap_o\n");
  printf("  vector-derived trap checks so far: %ld checks %ld failures\n", n_trap_checks, n_trap_fail);
  directed_traps();

  printf("random cross-check against host arithmetic\n");
  random_single(20000);
  random_double(20000);
  ordering_test();

  printf("latency (clocks, min..max)\n");
  for (int i = 0; i < n_lat; i++) printf("  %-9s %3d..%3d\n", lat[i].name, lat[i].lo, lat[i].hi);
  printf("total: %ld checks, %ld failures; trap: %ld checks, %ld failures; %llu clocks\n", n_checks, n_fail,
         n_trap_checks, n_trap_fail, (unsigned long long)total_cycles);
  bool ok = n_fail == 0 && n_trap_fail == 0;
  printf(ok ? "PASS\n" : "FAIL\n");
  dut->final();
  delete dut;
  return ok ? 0 : 1;
}
