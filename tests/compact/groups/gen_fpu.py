#!/usr/bin/env python3
"""Generate groups/fpu_vectors.h: reference vectors of the SHcompact fpu group.

The SHcompact FPU instructions have the numerical behaviour of the SHmedia
ones (Vol. 1 13.6, Vol. 3 special-case tables), so the IEEE754 models of the
SHmedia kit are reused: tests/isa/tools/gen_fpu_s.py (single precision) and
tests/isa/tools/gen_fpu_d.py (double precision), exact rational arithmetic,
RN/RZ rounding, tininess after rounding, DN = 1 flush of sources and results
(U and I signaled), canonical quiet NaNs 0x7FBFFFFF / 0x7FF7FFFF_FFFFFFFF.

All vectors use FPSCR.DN = 1 and ENABLE = 0 (a denormalized source with
DN = 0 raises an FPU error on the SH-5, Vol. 1 8.3.7). FPSCR is the SHcompact
view (Vol. 1 Figure 53): RM 0, FLAG 2-6, ENABLE 7-11, CAUSE 12-17, DN 18,
PR 19, SZ 20, FR 21. Expected FPSCR after an arithmetic instruction: CAUSE
replaced, FLAG accumulated, other bits unchanged.

The x field of each vector holds properties of the operands, used by the
SH-4 build to skip cases where QEMU's SH-4 deviates from the manual:
  X_DNRM  a source is denormalized
  X_TINY  the exact result is non-zero and below the smallest normal number
  X_FRAC  FTRC source is finite, non-zero and not an integer
  X_EXACT FIPR/FTRV: products and left-to-right partial sums exact in single
          precision (the manual still signals inexact)
  X_APPROX FIPR/FTRV: approximate case (finite result, not a special case)
  X_ZERO  FCMP/GT of two zeros of different sign after the DN flush
  X_NAN   FTRC source is a NaN
  X_QNAN  FCMP: a source is a quiet NaN, none is signaling
  X_GTV   (double compare vectors) FCMP/GT signals invalid

Usage: python3 groups/gen_fpu.py   (writes groups/fpu_vectors.h)
"""
import importlib.util
import os
import random
from fractions import Fraction as Fr

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, '..', '..', 'isa', 'tools')


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOLS, name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


S = load('gen_fpu_s')
D = load('gen_fpu_d')

RZ = 1
DN = 1 << 18
PR = 1 << 19
SZ = 1 << 20
FR = 1 << 21
FLAGS_ALL = 0x1F << 2
CAUSE_MASK = 0x3F << 12
I_, U_, O_, Z_, V_ = 1, 2, 4, 8, 16
X_DNRM, X_TINY, X_FRAC, X_EXACT, X_ZERO, X_APPROX, X_NAN, X_QNAN, X_GTV = 1, 2, 4, 8, 16, 32, 64, 128, 256
QNAN32 = 0x7FBFFFFF

rng = random.Random(0x5C0FF1)
out = []


def emit(s=''):
    out.append(s)


def fpscr(fps_in, flags):
    return (fps_in & ~CAUSE_MASK) | (flags << 12) | (flags << 2)


def fps_s(sz_ok=True):
    """single-precision FPSCR input: DN = 1, RN or RZ, sometimes SZ = 1 and
    preset FLAG/CAUSE bits (FLAG sticky, CAUSE replaced)"""
    f = DN | (RZ if rng.random() < 0.35 else 0)
    if sz_ok and rng.random() < 0.25:
        f |= SZ
    if rng.random() < 0.15:
        f |= FLAGS_ALL | (0x15 << 12)
    return f


def fps_d():
    f = DN | PR | (RZ if rng.random() < 0.35 else 0)
    if rng.random() < 0.15:
        f |= FLAGS_ALL | (0x15 << 12)
    return f


# ------------------------------------------------------------ single ops --

def dnrm32(b):
    return S.cls(b) == S.DNRM


def tiny32(fn, args, rm):
    """exact result non-zero and below 2^-126: from the DN = 0 model (no
    denormal sources here), denormal result, or 2^-126 reached by rounding"""
    r, fl = fn(*args, rm, 0)
    if S.cls(r) == S.DNRM or (fl & S.F_U):
        return True
    if (r & 0x7FFFFFFF) == 0x00800000 and (fl & S.F_I):
        return True
    return S.cls(r) == S.ZERO and (fl & S.F_I) != 0


def sx(fn, srcs, rm):
    x = X_DNRM if any(dnrm32(s) for s in srcs) else 0
    if not x and tiny32(fn, srcs, rm):
        x |= X_TINY
    return x


def rnd_normal(emin=1, emax=254):
    return (rng.getrandbits(1) << 31) | (rng.randint(emin, emax) << 23) | rng.getrandbits(23)


def rnd_any():
    r = rng.random()
    if r < 0.55:
        return rnd_normal()
    if r < 0.7:
        return rnd_normal(100, 154)
    if r < 0.8:
        return (rng.getrandbits(1) << 31) | rng.randint(1, 0x7FFFFF)
    return rng.choice(S.SPECIALS)


def near(x, k):
    if S.cls(x) in (S.INF, S.QN, S.SN):
        return x
    return S.from_key(S.fkey(x) + rng.randint(-k, k))


def pairs_s(n_rand):
    p = [(a, b) for a in S.CORE for b in S.CORE]
    for a in S.SPECIALS:
        p.append((a, rng.choice(S.SPECIALS)))
        p.append((rng.choice(S.SPECIALS), a))
    for _ in range(n_rand):
        a = rnd_any()
        b = near(a, 3) ^ (0x80000000 if rng.random() < 0.5 else 0) if rng.random() < 0.3 else rnd_any()
        p.append((a, b))
    for _ in range(25):
        p.append((rnd_normal(1, 30), rnd_normal(1, 60)))
        p.append((rnd_normal(230, 254), rnd_normal(230, 254)))
        p.append((rnd_normal(100, 154), rnd_normal(100, 154)))
    p += [(0x00800000, 0x3F7FFFFF), (S.TINY_A, S.TINY_B), (S.TINY_B, S.TINY_A ^ 0x80000000),
          (0x3F800000, 0x33800000), (0x3F800001, 0x33800000), (0x4B7FFFFF, 0x3F000000)]
    return p


def gen_dyadic_s(name, fn):
    """FADD/FSUB/FMUL/FDIV FRm, FRn: a = FRn, b = FRm, want = FRn op FRm"""
    emit('static const struct fv %s[] = {' % name)
    for a, b in pairs_s(160):
        f = fps_s()
        rm = f & RZ
        w, fl = fn(a, b, rm, 1)
        emit('\t{ 0x%08x, 0x%08x, 0, 0x%08x, 0x%06x, 0x%06x, %d },'
             % (a, b, w, f, fpscr(f, fl), sx(fn, (a, b), rm)))
    emit('};')


def gen_cmp_s():
    """FCMP/EQ and FCMP/GT FRm, FRn: a = FRn, b = FRm; T_eq = a == b, T_gt = a > b"""
    emit('static const struct fcmp fcmp_s[] = {')
    for a, b in pairs_s(80) + [(a, a) for a in S.SPECIALS] + [(a, a ^ 0x80000000) for a in S.SPECIALS]:
        f = fps_s()
        teq, feq = S.f_cmp('eq', a, b, 1)
        tgt, fgt = S.f_cmp('gt', a, b, 1)
        fa, fb = S.flush(a, 1), S.flush(b, 1)
        x = X_DNRM if dnrm32(a) or dnrm32(b) else 0
        if S.cls(fa) == S.ZERO and S.cls(fb) == S.ZERO and fa != fb:
            x |= X_ZERO
        if S.QN in (S.cls(a), S.cls(b)) and S.SN not in (S.cls(a), S.cls(b)):
            x |= X_QNAN
        emit('\t{ 0x%08x, 0x%08x, %d, %d, 0x%06x, 0x%06x, 0x%06x, %d },'
             % (a, b, teq, tgt, f, fpscr(f, feq), fpscr(f, fgt), x))
    emit('};')


def gen_mono_s():
    emit('static const struct fv fsqrt_s[] = {')
    ins = list(S.SPECIALS) + [rnd_any() for _ in range(150)]
    for _ in range(30):
        r = rnd_normal(100, 154) & 0x7FFFFFFF
        sq, fl = S.f_mul(r, r, 0, 0)
        if fl == 0:
            ins.append(sq)
    for a in ins:
        f = fps_s()
        w, fl = S.f_sqrt(a, f & RZ, 1)
        x = X_DNRM if dnrm32(a) else 0
        emit('\t{ 0x%08x, 0, 0, 0x%08x, 0x%06x, 0x%06x, %d },' % (a, w, f, fpscr(f, fl), x))
    emit('};')
    # FTRC FRm, FPUL
    emit('static const struct fv ftrc_s[] = {')
    ins = list(S.SPECIALS) + [0x4EFFFFFF, 0x4F000000, 0xCF000000, 0xCF000001, 0x3F7FFFFF, 0xBF7FFFFF,
                              0x3FFFFFFF, 0xBFFFFFFF, 0x4B000000, 0x4AFFFFFF, 0x43000000, 0xC2FE0000,
                              0x3FC00000, 0xBFC00000, 0x4EFFFFFE, 0xCEFFFFFF]
    ins += [rnd_normal(100, 200) for _ in range(60)] + [rnd_any() for _ in range(40)]
    for a in ins:
        f = fps_s()
        w, fl = S.f_ftrc(a, 32)
        x = X_DNRM if dnrm32(a) else 0
        if S.cls(a) in (S.NORM, S.DNRM) and S.val(a).denominator != 1 and not fl:
            x |= X_FRAC
        if S.is_nan(a):
            x |= X_NAN
        emit('\t{ 0x%08x, 0, 0, 0x%08x, 0x%06x, 0x%06x, %d },' % (a, w, f, fpscr(f, fl), x))
    emit('};')
    # FLOAT FPUL, FRn
    emit('static const struct fv float_s[] = {')
    ints = [0, 1, 0xFFFFFFFF, 2, 3, 0x7FFFFFFF, 0x80000000, 0x7FFFFF80, 0x7FFFFFC0, 0x7FFFFFBF,
            0x7FFFFFC1, 0x01000001, 0x00FFFFFF, 0x01000000, 0xFEFFFFFF, 0x12345678, 0xEDCBA988,
            0x00800000, 0x01000003, 0x80000001]
    ints += [rng.getrandbits(32) for _ in range(50)] + [rng.getrandbits(rng.randint(1, 31)) for _ in range(30)]
    for i in ints:
        f = fps_s()
        w, fl = S.f_float(i - (1 << 32) if i >> 31 else i, f & RZ)
        emit('\t{ 0x%08x, 0, 0, 0x%08x, 0x%06x, 0x%06x, 0 },' % (i, w, f, fpscr(f, fl)))
    emit('};')


def gen_fmac():
    """FMAC FR0, FRm, FRn: a = FR0, b = FRm, c = FRn; want = a * b + c"""
    v = []
    for a in S.CORE:
        for b in S.CORE:
            v.append((a, b, rng.choice(S.CORE)))
    for a in S.SPECIALS:
        v.append((a, rng.choice(S.SPECIALS), rng.choice(S.SPECIALS)))
        v.append((rng.choice(S.SPECIALS), a, rng.choice(S.SPECIALS)))
        v.append((rng.choice(S.SPECIALS), rng.choice(S.SPECIALS), a))
    for _ in range(160):
        a, b = rnd_normal(100, 154), rnd_normal(100, 154)
        p, _ = S.f_mul(a, b, 0, 0)
        if rng.random() < 0.5 and S.cls(p) == S.NORM:
            c = p ^ 0x80000000
            if rng.random() < 0.5:
                c = near(c, 2)
        else:
            c = rnd_any()
        v.append((a, b, c))
    for _ in range(60):
        v.append((rnd_any(), rnd_any(), rnd_any()))
    for _ in range(15):
        v.append((rnd_normal(230, 254), rnd_normal(230, 254), 0xFF800000))
        v.append((rnd_normal(230, 254), rnd_normal(230, 254), rnd_normal()))
        v.append((rnd_normal(1, 40), rnd_normal(1, 40), rnd_normal(1, 10)))
    v += [(S.TINY_A, S.TINY_B, 0), (S.TINY_A, S.TINY_B, 0x80000000), (0x00800000, 0x3F7FFFFF, 0)]
    emit('static const struct fv fmac_s[] = {')
    for a, b, c in v:
        f = fps_s()
        w, fl = S.f_mac(a, b, c, f & RZ, 1)
        x = sx(S.f_mac, (a, b, c), f & RZ)
        emit('\t{ 0x%08x, 0x%08x, 0x%08x, 0x%08x, 0x%06x, 0x%06x, %d },' % (a, b, c, w, f, fpscr(f, fl), x))
    emit('};')


def gen_fsrra():
    """FSRRA FRn: result range [lo, hi] (Vol. 3: error < 2^(E-21))"""
    ins = list(S.SPECIALS) + [0x3F800000, 0x40800000, 0x41800000, 0x3E800000, 0x40000000, 0x3F000000,
                              0x7F7FFFFF, 0x00800000, 0x00800001, 0x7F000000, 0x3F7FFFFF, 0x3F800001]
    ins += [rnd_normal() for _ in range(120)]
    emit('static const struct fr fsrra_s[] = {')
    for a in ins:
        f = fps_s()
        x = S.flush(a, 1)
        c = S.cls(x)
        if c == S.SN:
            lo, hi, fl = QNAN32, QNAN32, V_
        elif c == S.QN:
            lo, hi, fl = QNAN32, QNAN32, 0
        elif c == S.ZERO:
            lo = hi = (x & 0x80000000) | 0x7F800000
            fl = Z_
        elif S.sgn(x):
            lo, hi, fl = QNAN32, QNAN32, V_
        elif c == S.INF:
            lo, hi, fl = 0, 0, 0
        else:
            lo, hi = S.srra_range(x)
            fl = I_
        emit('\t{ 0x%08x, 0x%08x, 0x%08x, 0, 0, 0x%06x, 0x%06x, %d },'
             % (a, lo, hi, f, fpscr(f, fl), X_DNRM if dnrm32(a) else 0))
    emit('};')


def gen_fsca():
    """FSCA FPUL, DRn: FRn = sin, FRn+1 = cos; error < 2^-21; I always"""
    angles = [0, 1, 0x4000, 0x8000, 0xC000, 0xFFFF, 0x2000, 0x6000, 0xA000, 0xE000, 0x10000, 0x14000,
              0xFFFF0000, 0xFFFFC000, 0xFFFF8000, 0x7FFFFFFF, 0x80000000, 0x12345678, 0x80004000,
              0x3FFF, 0x4001, 0x1555, 0x2AAB, 0x0100, 0x0010]
    angles += [rng.getrandbits(16) for _ in range(40)] + [rng.getrandbits(32) for _ in range(40)]
    emit('static const struct fr fsca_s[] = {')
    for a in angles:
        f = fps_s()
        slo, shi = S.sina_cosa_range(a, False)
        clo, chi = S.sina_cosa_range(a, True)
        emit('\t{ 0x%08x, 0x%08x, 0x%08x, 0x%08x, 0x%08x, 0x%06x, 0x%06x, 0 },'
             % (a, slo, shi, clo, chi, f, fpscr(f, I_)))
    emit('};')


def fipr_x(g, h, rm):
    """X_APPROX: approximate (FIPRADD) case with a finite result;
    X_EXACT: every product and every left-to-right partial sum is exact in
    single precision (no rounding in a sequential evaluation)"""
    x = X_DNRM if any(dnrm32(t) for t in g + h) else 0
    if any(S.cls(t) in (S.INF, S.QN, S.SN) for t in g + h):
        return x
    x |= X_APPROX
    acc = Fr(0)
    for p, q in zip(g, h):
        t = S.val(S.flush(p, 1)) * S.val(S.flush(q, 1))
        acc += t
        if (t != 0 and S.f32_exact_or_none(t) is None) or (acc != 0 and S.f32_exact_or_none(acc) is None):
            return x
    return x | X_EXACT


def rnd_vec4(kind):
    lo, hi = {'moderate': (110, 144), 'mixed': (90, 164), 'wide': (70, 184)}[kind]
    return [rnd_normal(lo, hi) for _ in range(4)]


def gen_fipr():
    """FIPR FVm, FVn: v[0..3] = FVm, v[4..7] = FVn; FRn+3 in [lo, hi]
    (Vol. 1 8.7.3 bound, FVn <-> FVg, FVm <-> FVh of FIPR.S)"""
    one, m1 = 0x3F800000, 0xBF800000
    vs = [([one] * 4, [one] * 4), ([one, m1, one, m1], [one] * 4), ([0] * 4, [0] * 4),
          ([0] * 4, [0x80000000] * 4), ([one] * 4, [0x40000000, 0x40400000, 0x40800000, 0x40A00000]),
          ([one] * 4, [0x7F800000, one, one, one]), ([one] * 4, [0x7F800000, 0xFF800000, one, one]),
          ([0, one, one, one], [0x7F800000, one, one, one]), ([one] * 4, [QNAN32, one, one, one]),
          ([one] * 4, [0x7FC00000, one, one, one]), ([one] * 4, [0x00000001, one, one, one]),
          ([0x7F800000, one, one, one], [0x00000001, 0x00400000, one, one]),
          ([one, 0xFF7FFFFF, one, one], [0x7F7FFFFF, one, one, one]),
          ([one, one, 0xFF800000, one], [one, QNAN32, one, one])]
    for _ in range(90):
        kind = rng.choice(['moderate', 'moderate', 'mixed', 'wide'])
        g, h = rnd_vec4(kind), rnd_vec4(kind)
        if rng.random() < 0.3 and kind != 'wide':
            p = S.f_mul(g[0], h[0], 0, 0)[0]
            if S.cls(p) == S.NORM:
                q = S.f_div(p, g[1], 0, 0)[0]
                if S.cls(q) == S.NORM:
                    h[1] = near(q ^ 0x80000000, 4)
        vs.append((h, g))
    emit('static const struct fipr fipr_s[] = {')
    for m, n in vs:
        f = fps_s(sz_ok=False)
        r = S.fipr_one(n, m, f & RZ, 1)
        if r is None:
            continue
        lo, hi, fl = r
        emit('\t{ { %s }, 0x%08x, 0x%08x, 0x%06x, 0x%06x, %d },'
             % (', '.join('0x%08x' % t for t in m + n), lo, hi, f, fpscr(f, fl), fipr_x(n, m, f & RZ)))
    emit('};')


def gen_ftrv():
    """FTRV XMTRX, FVn: m[16] = XF0..XF15 (column-major, element i + 4j),
    v[4] = FVn; FRn+i = sum_j XF[i + 4j] * FR[n + j]"""
    one = 0x3F800000
    ident = [one if i % 5 == 0 else 0 for i in range(16)]
    vs = [(ident, [0x40000000, 0x40400000, 0x40800000, 0x40A00000]), ([one] * 16, [one] * 4),
          ([0] * 16, [one] * 4)]
    for pos, val, vec in ((0, QNAN32, [one] * 4), (5, 0x7FC00000, [one] * 4), (2, 0x7F800000, [0] * 4),
                          (3, 0x00000001, [one] * 4)):
        m = list(ident)
        m[pos] = val
        vs.append((m, vec))
    for _ in range(30):
        kind = rng.choice(['moderate', 'mixed', 'wide'])
        lo, hi = {'moderate': (110, 144), 'mixed': (90, 164), 'wide': (70, 184)}[kind]
        vs.append(([rnd_normal(lo, hi) for _ in range(16)], rnd_vec4(kind)))
    emit('static const struct ftrv ftrv_s[] = {')
    for m, v in vs:
        f = fps_s(sz_ok=False)
        los, his, fl, x = [], [], 0, 0
        for i in range(4):
            row = [m[i + 4 * j] for j in range(4)]
            r = S.fipr_one(row, v, f & RZ, 1)
            if r is None:
                break
            los.append(r[0])
            his.append(r[1])
            fl |= r[2]
            x |= fipr_x(row, v, f & RZ) << (8 * i)
        else:
            emit('\t{ { %s },\n\t  { %s }, { %s }, { %s }, 0x%06x, 0x%06x, 0x%08x },'
                 % (', '.join('0x%08x' % t for t in m), ', '.join('0x%08x' % t for t in v),
                    ', '.join('0x%08x' % t for t in los), ', '.join('0x%08x' % t for t in his),
                    f, fpscr(f, fl), x))
    emit('};')


# ------------------------------------------------------------ double ops --

def dnrm64(b):
    return D.classify(b)[0] == 'denorm'


def dflags(fn, args, f):
    """flags of a double operation from the SHmedia model (CAUSE field)"""
    r, fo = fn(*args, f)
    return r, (fo >> 12) & 0x1F


def tiny64(fn, args, rm):
    try:
        r, fl = dflags(fn, args, rm)
    except D.Trap:
        return False
    k = D.classify(r)[0]
    if k == 'denorm' or (fl & U_):
        return True
    if (r & ~(1 << 63)) == 0x0010000000000000 and (fl & I_):
        return True
    return k == 'zero' and (fl & I_) != 0


def gen_double():
    vals = D.VALS
    pairs = [(a, b) for a in vals for b in vals if rng.random() < 0.5]
    pairs += D.TARGETED + [(b, a) for a, b in D.TARGETED]
    pairs += list(zip(D.random_normals(rng, 60), D.random_normals(rng, 60)))
    pairs += list(zip(D.random_normals(rng, 30, -540, 540), D.random_normals(rng, 30, -540, 540)))
    for _ in range(16):
        a, = D.random_normals(rng, 1, -5, 5)
        pairs.append((a, (a ^ (1 << 63)) ^ rng.getrandbits(3)))

    def row(n, m, w, f, fo, x):
        return '\t{ 0x%06x, 0x%08x, 0x%08x, 0x%08x, 0x%08x, 0x%08x, 0x%08x, 0x%06x, %d },' % (
            f, n >> 32, n & 0xFFFFFFFF, m >> 32, m & 0xFFFFFFFF, w >> 32, w & 0xFFFFFFFF, fo, x)

    for name, fn in (('fadd_d', D.fadd), ('fsub_d', D.fsub), ('fmul_d', D.fmul), ('fdiv_d', D.fdiv)):
        emit('static const struct fd %s[] = {' % name)
        for n, m in pairs:
            f = fps_d()
            w, fl = dflags(fn, (n, m), DN | (f & RZ))
            x = X_DNRM if dnrm64(n) or dnrm64(m) else 0
            if not x and tiny64(fn, (n, m), f & RZ):
                x |= X_TINY
            emit(row(n, m, w, f, fpscr(f, fl), x))
        emit('};')
    # FCMP/EQ, FCMP/GT DRm, DRn: w_hi = T(eq), w_lo = T(gt), fps_want for EQ,
    # X_GTV: GT signals invalid
    emit('static const struct fd fcmp_d[] = {')
    for n, m in pairs[::2] + [(v, v) for v in vals] + [(v, v ^ (1 << 63)) for v in vals]:
        f = fps_d()
        (eq, gt, _, _), (ieq, igt, _, _) = D.fcmp(n, m, DN)
        fn_, kn, sn = D.flush(n, DN)
        fm_, km, sm = D.flush(m, DN)
        x = X_DNRM if dnrm64(n) or dnrm64(m) else 0
        if kn == 'zero' and km == 'zero' and sn != sm:
            x |= X_ZERO
        kinds = (D.classify(n)[0], D.classify(m)[0])
        if 'qnan' in kinds and 'snan' not in kinds:
            x |= X_QNAN
        if igt:
            x |= X_GTV
        emit(row(n, m, (int(eq) << 32) | int(gt), f, fpscr(f, V_ if ieq else 0), x))
    emit('};')
    # monadic: FSQRT DRn (n), FCNVDS DRm, FPUL (m -> w_hi), FTRC DRm, FPUL (m -> w_hi)
    sq_in = vals + [D.d(4.0), D.d(9.0), D.d(2.0), D.d(0.25), 0x4000000000000001, D.d(1e-300),
                    0x0010000000000001, 0x7FEFFFFFFFFFFFFE] + D.random_normals(rng, 30, -1000, 1000)
    emit('static const struct fd fsqrt_d[] = {')
    for n in sq_in:
        f = fps_d()
        w, fl = dflags(D.fsqrt, (n,), DN | (f & RZ))
        emit(row(n, 0, w, f, fpscr(f, fl), X_DNRM if dnrm64(n) else 0))
    emit('};')
    ds_in = vals + [0x47F0000000000000, 0x47EFFFFFE0000000, 0x47EFFFFFF0000000, 0x47EFFFFFE8000000,
                    0x47EFFFFFF8000000, 0x3810000000000000, 0x3800000000000000, 0x36A0000000000000,
                    0x3690000000000000, 0x3698000000000000, 0x3680000000000000, 0x380FFFFFFFFFFFFF,
                    0x380FFFFFE0000000, 0x3FF0000010000000, 0x3FF0000020000000, 0x3FF0000010000001,
                    0x3FF0000030000000, 0xC1DFFFFFFFC00000, 0x7FF0DEADBEEF0000, 0xFFF8DEADBEEF0000]
    ds_in += D.random_normals(rng, 30, -140, 140)
    emit('static const struct fd fcnvds_d[] = {')
    for m in ds_in:
        f = fps_d()
        w, fl = dflags(D.fcnv_ds, (m,), DN | (f & RZ))
        x = X_DNRM if dnrm64(m) else 0
        if not x and tiny64(D.fcnv_ds, (m,), f & RZ):
            x |= X_TINY
        emit(row(0, m, w << 32, f, fpscr(f, fl), x))
    emit('};')
    tr_in = vals + [0x41DFFFFFFFC00000, 0x41E0000000000000, 0xC1E0000000000000, 0xC1E0000000200000,
                    0x41DFFFFFFFFFFFFF, 0xC1E00000001FFFFF, 0x3FEFFFFFFFFFFFFF, 0xBFF8000000000000,
                    0x4330000000000000, 0x432FFFFFFFFFFFFF] + D.random_normals(rng, 30, -10, 40)
    emit('static const struct fd ftrc_d[] = {')
    for m in tr_in:
        f = fps_d()
        w, fl = dflags(lambda a, fp: D.ftrc(a, fp, 32), (m,), DN | (f & RZ))
        x = X_DNRM if dnrm64(m) else 0
        k = D.classify(m)[0]
        if k in ('norm', 'denorm') and D.to_frac(m).denominator != 1 and not fl:
            x |= X_FRAC
        if k in ('qnan', 'snan'):
            x |= X_NAN
        emit(row(0, m, w << 32, f, fpscr(f, fl), x))
    emit('};')
    # FCNVSD FPUL, DRn and FLOAT FPUL, DRn: m_hi = FPUL
    emit('static const struct fd fcnvsd_d[] = {')
    for s in list(S.SPECIALS) + [rnd_any() for _ in range(60)]:
        f = fps_d()
        w, fl = dflags(D.fcnv_sd, (s,), DN | (f & RZ))
        emit(row(0, s << 32, w, f, fpscr(f, fl), X_DNRM if dnrm32(s) else 0))
    emit('};')
    emit('static const struct fd float_d[] = {')
    ints = [0, 1, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0x12345678, 0x80000001, 0x01000001]
    ints += [rng.getrandbits(32) for _ in range(40)]
    for i in ints:
        # FLOAT FPUL, DRn: Vol. 3 pseudocode does not write FPSCR; the
        # vectors keep CAUSE = 0 so that both readings agree
        f = fps_d() & ~CAUSE_MASK
        w, fl = dflags(D.float_ld, (i,), DN | (f & RZ))
        assert fl == 0
        emit(row(0, i << 32, w, f, f, 0))
    emit('};')


def gen_bits():
    vals = list(S.SPECIALS) + [rng.getrandbits(32) for _ in range(40)]
    emit('static const u32 fbits[] = {')
    for i in range(0, len(vals), 6):
        emit('\t' + ' '.join('0x%08x,' % v for v in vals[i:i + 6]))
    emit('};')


def main():
    emit('/* Generated by groups/gen_fpu.py from the IEEE754 models of')
    emit(' * tests/isa/tools/gen_fpu_s.py and gen_fpu_d.py. Do not edit. */')
    emit('#ifndef FPU_VECTORS_H')
    emit('#define FPU_VECTORS_H')
    emit()
    for k, v in (('X_DNRM', X_DNRM), ('X_TINY', X_TINY), ('X_FRAC', X_FRAC), ('X_EXACT', X_EXACT),
                 ('X_ZERO', X_ZERO), ('X_APPROX', X_APPROX), ('X_NAN', X_NAN),
                 ('X_QNAN', X_QNAN), ('X_GTV', X_GTV)):
        emit('#define %s %d' % (k, v))
    emit()
    emit('/* single: a = FRn (FR0 for FMAC), b = FRm, c = FRn (FMAC) */')
    emit('struct fv { u32 a, b, c, want, fps_in, fps_want, x; };')
    emit('struct fcmp { u32 a, b, t_eq, t_gt, fps_in, fps_eq, fps_gt, x; };')
    emit('/* approximate: result r in [lo, hi] (key order), r2 in [lo2, hi2] */')
    emit('struct fr { u32 a, lo, hi, lo2, hi2, fps_in, fps_want, x; };')
    emit('struct fipr { u32 v[8]; u32 lo, hi, fps_in, fps_want, x; };')
    emit('/* x: one byte of X_* per result element */')
    emit('struct ftrv { u32 m[16]; u32 v[4]; u32 lo[4], hi[4]; u32 fps_in, fps_want, x; };')
    emit('/* double: first five words are the routine input block */')
    emit('struct fd { u32 fps_in, n_hi, n_lo, m_hi, m_lo, w_hi, w_lo, fps_want, x; };')
    emit()
    gen_dyadic_s('fadd_s', S.f_add)
    gen_dyadic_s('fsub_s', S.f_sub)
    gen_dyadic_s('fmul_s', S.f_mul)
    gen_dyadic_s('fdiv_s', S.f_div)
    gen_cmp_s()
    gen_mono_s()
    gen_fmac()
    gen_fsrra()
    gen_fsca()
    gen_fipr()
    gen_ftrv()
    gen_double()
    gen_bits()
    emit()
    emit('#endif')
    with open(os.path.join(HERE, 'fpu_vectors.h'), 'w') as f:
        f.write('\n'.join(out) + '\n')


if __name__ == '__main__':
    main()
