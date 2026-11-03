#!/usr/bin/env python3
"""
Generate groups/fpu_s_vectors.h: reference vectors for the SH-5 SHmedia
single-precision FPU group (groups/fpu_s.c).

The test program is compiled with -m5-32media, so any C float arithmetic in
it would run on the FPU under test.  The expected results are therefore
computed here, on the host, with exact rational arithmetic (fractions) and
an explicit IEEE754 single-precision rounding step written from SH-5 CPU
Core Volume 1 chapter 8 (round to nearest even / round to zero, tininess
detected after rounding, flush-to-zero when FPSCR.DN=1) and the special
case tables of Volume 2 chapter 2.  Only the standard library is required;
numpy, when present, is used as an independent cross-check of the normal
(non-special) cases.

Conventions (Volume 1 section 3.4.2 and 8.3.5):
  NaN with fraction MSB (bit 22) set    -> signalling NaN
  NaN with fraction MSB clear           -> quiet NaN
  every NaN result is the canonical quiet NaN 0x7FBFFFFF

FPSCR (Volume 1 table 76): RM bit 0 (0 nearest, 1 zero); FLAG bits 2..6 and
CAUSE bits 12..16 in the order I, U, O, Z, V; CAUSE.E bit 17; DN bit 18.
The vectors carry the FPSCR written before the instruction (fps_in) and the
complete FPSCR expected after it (fps_want).

Usage: python3 tools/gen_fpu_s.py > groups/fpu_s_vectors.h
"""
import math
import random
import struct
import sys
from fractions import Fraction as Fr

# ---------------------------------------------------------------- formats --

QNAN = 0x7FBFFFFF
F_I, F_U, F_O, F_Z, F_V = 1, 2, 4, 8, 16          # flag bits, FPSCR order
RM_RN, RM_RZ = 0, 1
DN = 1 << 18
FPSCR_FLAG_SHIFT, FPSCR_CAUSE_SHIFT = 2, 12
FPSCR_MASK = 0x7FFFD                              # defined bits (0, 2..18)

ZERO, DNRM, NORM, INF, QN, SN = range(6)


def cls(b):
    e = (b >> 23) & 0xFF
    f = b & 0x7FFFFF
    if e == 0xFF:
        return INF if f == 0 else (SN if f & 0x400000 else QN)
    if e == 0:
        return ZERO if f == 0 else DNRM
    return NORM


def sgn(b):
    return (b >> 31) & 1


def is_nan(b):
    return cls(b) in (QN, SN)


def pow2(e):
    return Fr(1 << e) if e >= 0 else Fr(1, 1 << -e)


def val(b):
    """Exact value of a finite single (zero, denormal or normal)."""
    e = (b >> 23) & 0xFF
    f = b & 0x7FFFFF
    if e == 0:
        v = Fr(f, 1 << 149)
    else:
        v = Fr((1 << 23) | f) * pow2(e - 150)
    return -v if b >> 31 else v


def flush(b, dn):
    """FPSCR.DN=1: denormalized source operands become signed zeros."""
    if dn and cls(b) == DNRM:
        return b & 0x80000000
    return b


def floor_log2(x):
    assert x > 0
    n, d = x.numerator, x.denominator
    e = n.bit_length() - d.bit_length()
    # adjust so that 2^e <= x < 2^(e+1)
    while x < pow2(e):
        e -= 1
    while x >= pow2(e + 1):
        e += 1
    return e


def round_int(scaled, rm):
    """Round a non-negative fraction to an integer; returns (q, inexact)."""
    q = scaled.numerator // scaled.denominator
    rem = scaled - q
    inexact = rem != 0
    if rm == RM_RN and (rem > Fr(1, 2) or (rem == Fr(1, 2) and (q & 1))):
        q += 1
    return q, inexact


def round_pack(sign, x, rm, dn):
    """
    Round the exact non-zero magnitude x to single precision (Vol. 1 8.3.2,
    8.3.6, 8.4.1).  Returns (bits, flags).
    """
    assert x > 0
    e = floor_log2(x)
    q, inexact = round_int(x * pow2(23 - e), rm)
    if q == 1 << 24:
        q >>= 1
        e += 1
    if e > 127:                                   # overflow
        if rm == RM_RN:
            return (sign << 31) | 0x7F800000, F_O | F_I
        return (sign << 31) | 0x7F7FFFFF, F_O | F_I
    if e >= -126:                                 # normal
        return (sign << 31) | ((e + 127) << 23) | (q & 0x7FFFFF), (F_I if inexact else 0)
    # tiny after rounding: round on the denormal grid
    q, inexact = round_int(x * pow2(149), rm)
    flags = (F_U | F_I) if inexact else 0
    if dn and q < (1 << 23):
        # denormal (or zero) result flushed to zero: U and I are signaled
        return sign << 31, F_U | F_I
    return (sign << 31) | q, flags


def from_sticky(m, k, exact):
    """Value floor(v*2^k)=m of an irrational v, with a sticky half bit."""
    return Fr(m, 1 << k) if exact else Fr(2 * m + 1, 1 << (k + 1))


def isqrt_frac(x, k=200):
    """floor(sqrt(x) * 2^k) and whether it is exact."""
    n = x.numerator << (2 * k)
    d = x.denominator
    m = math.isqrt(n // d)
    return m, (m * m * d == n)


def fpscr(fps_in, flags):
    """FPSCR after an instruction that signalled @flags (CAUSE replaced,
    FLAG accumulated, everything else unchanged)."""
    out = fps_in & ~(0x3F << FPSCR_CAUSE_SHIFT)
    out |= flags << FPSCR_CAUSE_SHIFT
    out |= flags << FPSCR_FLAG_SHIFT
    return out & FPSCR_MASK


# ------------------------------------------------------------- operations --

def f_add(a, b, rm, dn):
    a, b = flush(a, dn), flush(b, dn)
    ca, cb = cls(a), cls(b)
    if SN in (ca, cb):
        return QNAN, F_V
    if QN in (ca, cb):
        return QNAN, 0
    assert DNRM not in (ca, cb), "denormal source with DN=0 raises FPU error"
    if ca == INF and cb == INF:
        return (a, 0) if sgn(a) == sgn(b) else (QNAN, F_V)
    if ca == INF:
        return a, 0
    if cb == INF:
        return b, 0
    va, vb = val(a), val(b)
    s = va + vb
    if s == 0:
        if va == 0 and vb == 0:
            return (sgn(a) & sgn(b)) << 31, 0
        return 0, 0
    return round_pack(1 if s < 0 else 0, abs(s), rm, dn)


def f_sub(a, b, rm, dn):
    return f_add(a, b ^ 0x80000000, rm, dn)


def f_mul(a, b, rm, dn):
    a, b = flush(a, dn), flush(b, dn)
    ca, cb = cls(a), cls(b)
    s = sgn(a) ^ sgn(b)
    if SN in (ca, cb):
        return QNAN, F_V
    if QN in (ca, cb):
        return QNAN, 0
    assert DNRM not in (ca, cb)
    if (ca == ZERO and cb == INF) or (ca == INF and cb == ZERO):
        return QNAN, F_V
    if INF in (ca, cb):
        return (s << 31) | 0x7F800000, 0
    if ZERO in (ca, cb):
        return s << 31, 0
    return round_pack(s, abs(val(a) * val(b)), rm, dn)


def f_div(a, b, rm, dn):
    a, b = flush(a, dn), flush(b, dn)
    ca, cb = cls(a), cls(b)
    s = sgn(a) ^ sgn(b)
    if SN in (ca, cb):
        return QNAN, F_V
    if QN in (ca, cb):
        return QNAN, 0
    if (ca == ZERO and cb == ZERO) or (ca == INF and cb == INF):
        return QNAN, F_V
    if cb == ZERO:
        if ca == INF:
            return (s << 31) | 0x7F800000, 0
        # finite non-zero (a denormal dividend is allowed here: Vol. 2 p. 92
        # "the dividend is a denormalized number and the divisor is not a zero")
        return (s << 31) | 0x7F800000, F_Z
    assert cb != DNRM and ca != DNRM
    if ca == INF:
        return (s << 31) | 0x7F800000, 0
    if cb == INF or ca == ZERO:
        return s << 31, 0
    return round_pack(s, abs(val(a) / val(b)), rm, dn)


def f_sqrt(a, rm, dn):
    a = flush(a, dn)
    c = cls(a)
    if c == SN:
        return QNAN, F_V
    if c == QN:
        return QNAN, 0
    if c == ZERO:
        return a, 0
    if sgn(a):                       # -INF, -NORM, -DNRM: invalid, no FPU error
        return QNAN, F_V
    if c == INF:
        return a, 0
    assert c != DNRM, "+DNRM source with DN=0 raises FPU error"
    m, exact = isqrt_frac(val(a))
    return round_pack(0, from_sticky(m, 200, exact), rm, dn)


def f_cmp(kind, a, b, dn):
    a, b = flush(a, dn), flush(b, dn)
    ca, cb = cls(a), cls(b)
    nan = ca in (QN, SN) or cb in (QN, SN)
    snan = SN in (ca, cb)
    if kind == "un":
        return (1 if nan else 0), (F_V if snan else 0)
    if nan:
        if kind == "eq":
            return 0, (F_V if snan else 0)
        return 0, F_V                # gt, ge: any NaN is invalid
    # ordered values: compare as extended reals
    def ext(x):
        if cls(x) == INF:
            return math.inf if not sgn(x) else -math.inf
        return val(x)
    va, vb = ext(a), ext(b)
    if kind == "eq":
        return (1 if va == vb else 0), 0
    if kind == "gt":
        return (1 if va > vb else 0), 0
    if kind == "ge":
        return (1 if va >= vb else 0), 0
    raise ValueError(kind)


def f_ftrc(a, bits):
    """FTRC.SL (bits=32) / FTRC.SQ (bits=64): truncate, saturate, V on overflow."""
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    c = cls(a)
    if c in (QN, SN):
        return lo & ((1 << bits) - 1), F_V
    if c == INF:
        return (hi if not sgn(a) else lo) & ((1 << bits) - 1), F_V
    if c in (ZERO, DNRM):
        return 0, 0
    v = val(a)
    t = int(v)                       # truncation toward zero
    if t > hi:
        return hi & ((1 << bits) - 1), F_V
    if t < lo:
        return lo & ((1 << bits) - 1), F_V
    return t & ((1 << bits) - 1), 0


def f_float(i, rm):
    """FLOAT.LS / FLOAT.QS: signed integer to single; only I can be signaled."""
    if i == 0:
        return 0, 0
    bits, flags = round_pack(1 if i < 0 else 0, Fr(abs(i)), rm, 0)
    assert not (flags & ~F_I)
    return bits, flags


def f_mac(a, b, c, rm, dn):
    """FMAC.S: fused (a*b)+c, special cases from Vol. 2 pp. 111-113."""
    a, b, c = flush(a, dn), flush(b, dn), flush(c, dn)
    ca, cb, cc = cls(a), cls(b), cls(c)
    if SN in (ca, cb, cc):
        return QNAN, F_V
    if (ca == ZERO and cb == INF) or (ca == INF and cb == ZERO):
        return QNAN, F_V
    if QN in (ca, cb, cc):
        return QNAN, 0
    assert DNRM not in (ca, cb, cc)
    sp = sgn(a) ^ sgn(b)
    if INF in (ca, cb):
        if cc == INF and sgn(c) != sp:
            return QNAN, F_V
        return (sp << 31) | 0x7F800000, 0
    if cc == INF:
        return c, 0
    p = val(a) * val(b)
    s = p + val(c)
    if s == 0:
        if p == 0 and val(c) == 0:
            return (sp & sgn(c)) << 31, 0
        return 0, 0
    return round_pack(1 if s < 0 else 0, abs(s), rm, dn)


# ------------------------------------------- approximate instruction ranges --

def fkey(b):
    """Order-preserving integer key of a single (+0 and -0 both map to 0)."""
    m = b & 0x7FFFFFFF
    return -m if b >> 31 else m


def from_key(k):
    return (k & 0x7FFFFFFF) if k >= 0 else (0x80000000 | (-k))


def f32_exact_or_none(x):
    """Bits of x if x is exactly a finite single, else None."""
    if x == 0:
        return 0
    bits, flags = round_pack(1 if x < 0 else 0, abs(x), RM_RZ, 0)
    return bits if flags == 0 else None


def largest_below(x):
    """Largest finite single strictly less than the fraction x."""
    b = f32_exact_or_none(x)
    if b is not None:
        return from_key(fkey(b) - 1)
    if x == 0:
        return 0x80000001
    # RZ rounding of |x| gives the single nearest to zero; adjust by sign
    bits, _ = round_pack(1 if x < 0 else 0, abs(x), RM_RZ, 0)
    if cls(bits) == INF:
        return 0x7F7FFFFF if x > 0 else 0xFF7FFFFF
    if x > 0:
        return bits                  # below x
    return from_key(fkey(bits) - 1)  # x<0: RZ went toward zero, step down


def smallest_above(x):
    return largest_below(-x) ^ 0x80000000


def unbiased_exp(b):
    e = (b >> 23) & 0xFF
    return (e - 127) if e else -126


def approx_range(ideal, bound_of_exp):
    """
    [lo, hi] (bits) of all finite singles f with |f - ideal| < bound(E(f)),
    where bound depends only on the unbiased exponent of f.  The set is
    contiguous in key order (the bound grows with |f|).
    """
    best_hi = None
    best_lo = None
    for E in range(-126, 128):
        B = bound_of_exp(E)
        if B <= 0:
            continue
        for sign in (0, 1):
            if E == -126:
                fmin_k, fmax_k = 0, fkey(0x00FFFFFF)        # zero, denormals, 2^-126 binade
            else:
                fmin_k = fkey(((E + 127) << 23))
                fmax_k = fkey(((E + 127) << 23) | 0x7FFFFF)
            if sign:
                fmin_k, fmax_k = -fmax_k, -fmin_k
            # f < ideal + B  (largest such f in this binade)
            cap = ideal + B
            cand = largest_below(cap)
            ck = fkey(cand)
            if ck > fmax_k:
                ck = fmax_k
            if ck >= fmin_k and (best_hi is None or ck > best_hi):
                best_hi = ck
            # f > ideal - B  (smallest such f in this binade)
            flo = ideal - B
            cand = smallest_above(flo)
            ck = fkey(cand)
            if ck < fmin_k:
                ck = fmin_k
            if ck <= fmax_k and (best_lo is None or ck < best_lo):
                best_lo = ck
    assert best_lo is not None and best_hi is not None and best_lo <= best_hi
    return from_key(best_lo), from_key(best_hi)


def sina_cosa_range(a, cos):
    """FSINA.S/FCOSA.S: angle a (int32), 1 = 360/2^16 degrees; error < 2^-21."""
    ang = (a & 0xFFFF)
    theta = 2.0 * math.pi * ang / 65536.0
    ideal = Fr(math.cos(theta) if cos else math.sin(theta))
    # exact special angles so the bound is centred on the true value
    quarter = ang % 16384
    if quarter == 0:
        q = (ang // 16384) % 4
        s_tab, c_tab = (0, 1, 0, -1), (1, 0, -1, 0)
        ideal = Fr(c_tab[q] if cos else s_tab[q])
    return approx_range(ideal, lambda E: pow2(-21))


def srra_range(a):
    """FSRRA.S of a positive normal: error < 2^(E-21), E exponent of result."""
    x = val(a)
    m, exact = isqrt_frac(1 / x)
    ideal = from_sticky(m, 200, exact)
    return approx_range(ideal, lambda E: pow2(E - 21))


EZ = -253


def fipr_one(g, h, rm, dn):
    """
    One inner product (FIPR.S, or one row of FTRV.S) of two 4-vectors of
    singles.  Returns (lo, hi, flags): lo == hi means an exact result.
    """
    g = [flush(x, dn) for x in g]
    h = [flush(x, dn) for x in h]
    invalid = False
    nan = False
    terms = []                       # Fraction, or +-inf as float
    eps = []
    for x, y in zip(g, h):
        cx, cy = cls(x), cls(y)
        if SN in (cx, cy):
            invalid = True
            nan = True
            continue
        if QN in (cx, cy):
            nan = True
            continue
        if (cx == ZERO and cy == INF) or (cx == INF and cy == ZERO):
            invalid = True
            nan = True
            continue
        s = sgn(x) ^ sgn(y)
        if INF in (cx, cy):
            terms.append(-math.inf if s else math.inf)
            continue
        terms.append(val(x) * val(y))
        if cx == ZERO or cy == ZERO:
            eps.append(EZ)
        else:
            ex, ey = (x >> 23) & 0xFF, (y >> 23) & 0xFF
            eps.append(max(ex, 1) + max(ey, 1) - 254)
    if nan:
        return QNAN, QNAN, (F_V if invalid else 0)
    infs = [t for t in terms if isinstance(t, float)]
    if infs:
        if math.inf in infs and -math.inf in infs:
            return QNAN, QNAN, F_V
        return (0x7F800000, 0x7F800000, 0) if infs[0] > 0 else (0xFF800000, 0xFF800000, 0)
    S = sum(terms, Fr(0))
    epm = max(eps)
    if epm == EZ:
        return 0x80000000, 0, F_I    # all products are zero: +0 or -0 (same key)
    if abs(S) >= pow2(128) or (S != 0 and abs(S) < pow2(-120)):
        return None                  # overflow/underflow handling is implementation dependent
    lo, hi = approx_range(S, lambda E: pow2(epm - 24) + pow2(E - 24 + rm))
    return lo, hi, F_I


# ------------------------------------------------------------------ corpus --

SPECIALS = [
    0x00000000, 0x80000000,                      # +0 -0
    0x00000001, 0x80000001, 0x007FFFFF, 0x807FFFFF, 0x00400000,  # denormals
    0x00800000, 0x80800000, 0x00800001,          # min normal
    0x3F800000, 0xBF800000, 0x3F000000, 0x40000000, 0xC0000000, 0x40400000,
    0x3EAAAAAB, 0x40490FDB, 0x3FFFFFFF, 0x3F7FFFFF, 0x3F800001,
    0x4B800000, 0x4B7FFFFF, 0x33800000, 0x34000000,  # 2^24, 2^24-1, 2^-24, 2^-23
    0x4F000000, 0x4EFFFFFF, 0xCF000000, 0xCF000001,  # around 2^31
    0x5F000000, 0x5EFFFFFF, 0xDF000000, 0xDF000001,  # around 2^63
    0x7F7FFFFF, 0xFF7FFFFF, 0x7F000000, 0x7E800000, 0x6F800000,
    0x0D800000, 0x01000000, 0x0A800000, 0x0B800000,
    0x7F800000, 0xFF800000,                      # +INF -INF
    QNAN, 0x7F800001, 0xFFBFFFFF, 0xFF800001,    # quiet NaNs (bit 22 clear)
    0x7FC00000, 0xFFC00000, 0x7FFFFFFF, 0xFFFFFFFF, 0x7FC00001,  # signalling NaNs
]
CORE = [
    0x00000000, 0x80000000, 0x00800000, 0x3F800000, 0xBF800000, 0x40000000,
    0x3F000000, 0x7F7FFFFF, 0xFF7FFFFF, 0x7F800000, 0xFF800000,
    QNAN, 0xFFBFFFFF, 0x7FC00000, 0xFFFFFFFF, 0x4B800000, 0x33800000,
]
rng = random.Random(0x5A5A5A5A)

# 18631 * 2^-80 and 1801 * 2^-71 (both normal): product 2^-126 - 2^-151
TINY_A = f32_exact_or_none(Fr(18631, 1 << 80))
TINY_B = f32_exact_or_none(Fr(1801, 1 << 71))
assert TINY_A is not None and TINY_B is not None
assert val(TINY_A) * val(TINY_B) == pow2(-126) - pow2(-151)


def rnd_normal(emin=1, emax=254):
    return (rng.getrandbits(1) << 31) | (rng.randint(emin, emax) << 23) | rng.getrandbits(23)


def rnd_denormal():
    return (rng.getrandbits(1) << 31) | rng.randint(1, 0x7FFFFF)


def rnd_any():
    r = rng.random()
    if r < 0.6:
        return rnd_normal()
    if r < 0.7:
        return rnd_normal(100, 154)
    if r < 0.8:
        return rnd_denormal()
    return rng.choice(SPECIALS)


def nondenormal(x):
    return cls(x) != DNRM


def near(x, k):
    """A single a few ulps away from x (same sign), for cancellation cases."""
    if cls(x) in (INF, QN, SN):
        return x
    return from_key(fkey(x) + rng.randint(-k, k))


# ------------------------------------------------------------------ output --

out = []


def emit(s=""):
    out.append(s)


def fps_variants():
    """
    Random (fps_in) choice: RN/RZ, DN=0/1, and occasionally pre-set FLAG and
    CAUSE bits to check that FLAG is sticky and CAUSE is replaced.
    """
    rm = RM_RZ if rng.random() < 0.3 else RM_RN
    dn = DN if rng.random() < 0.4 else 0
    fps = rm | dn
    if rng.random() < 0.15:
        fps |= (0x1F << FPSCR_FLAG_SHIFT) | (0x15 << FPSCR_CAUSE_SHIFT)
    return fps


def gen_dyadic(name, fn, n_rand, denormal_ok=False):
    """Vectors {a, b, want, fps_in, fps_want} for a two-operand arithmetic op."""
    vecs = []
    seen = set()

    def add(a, b, fps):
        rm, dn = fps & 1, (fps >> 18) & 1
        if not dn and not denormal_ok:
            # avoid FPU error (CAUSE.E) cases: denormal source with DN=0,
            # unless the result is a NaN anyway or (FDIV) the divisor is zero
            if DNRM in (cls(a), cls(b)):
                if is_nan(a) or is_nan(b):
                    pass
                elif name == "fdiv" and cls(a) == DNRM and cls(b) == ZERO:
                    pass
                else:
                    return
        key = (a, b, fps)
        if key in seen:
            return
        seen.add(key)
        want, flags = fn(a, b, rm, dn)
        vecs.append((a, b, want, fps, fpscr(fps, flags)))

    for a in CORE:
        for b in CORE:
            add(a, b, RM_RN)
    for a in SPECIALS:
        add(a, rng.choice(SPECIALS), fps_variants())
        add(rng.choice(SPECIALS), a, fps_variants())
        add(a, rng.choice(SPECIALS), DN)
        add(a, rng.choice(SPECIALS), RM_RZ | DN)
    for _ in range(n_rand):
        a = rnd_any()
        r = rng.random()
        if r < 0.3:
            b = near(a, 3)
            if rng.random() < 0.5:
                b ^= 0x80000000
        elif r < 0.5:
            b = rnd_normal(max(1, 127 - ((a >> 23) & 0xFF) + 60), min(254, 127 - ((a >> 23) & 0xFF) + 194)) \
                if cls(a) == NORM else rnd_any()
        else:
            b = rnd_any()
        add(a, b, fps_variants())
    # directed under/overflow and tininess cases
    for _ in range(40):
        add(rnd_normal(1, 30), rnd_normal(1, 60), fps_variants())      # products/quotients tiny
        add(rnd_normal(230, 254), rnd_normal(230, 254), fps_variants())  # overflow
        add(rnd_normal(1, 3), rnd_normal(1, 3), fps_variants())
    # tininess corners: exact results just below 2^-126.  18631*1801 =
    # 2^25-1, so TINY_A*TINY_B = 2^-126 - 2^-151 rounds up to 2^-126 with an
    # unbounded exponent range (not tiny after rounding: I only, Vol. 1 p. 141)
    # while 2^-126 * (1-2^-24) = 2^-126 - 2^-150 stays tiny (U and I).
    for fps in (RM_RN, RM_RZ, DN, DN | RM_RZ, RM_RN | (0x1F << FPSCR_FLAG_SHIFT)):
        add(0x00800000, 0x3F7FFFFF, fps)
        add(TINY_A, TINY_B, fps)
        add(TINY_B, TINY_A ^ 0x80000000, fps)
    for _ in range(20):
        add(0x00800000 | rng.getrandbits(23), 0x3F7FFFFE | rng.getrandbits(1), fps_variants())
    emit("static const struct fpu_s_v2 fpu_s_%s[] = {" % name)
    for v in vecs:
        emit("\t{ 0x%08x, 0x%08x, 0x%08x, 0x%05x, 0x%05x }," % v)
    emit("};")
    emit()
    return vecs


def gen_monadic(name, fn, inputs, n_rand):
    vecs = []
    seen = set()

    def add(a, fps):
        rm, dn = fps & 1, (fps >> 18) & 1
        if not dn and cls(a) == DNRM and not sgn(a):
            return                   # +DNRM with DN=0: FPU error
        key = (a, fps)
        if key in seen:
            return
        seen.add(key)
        want, flags = fn(a, rm, dn)
        vecs.append((a, 0, want, fps, fpscr(fps, flags)))

    for a in inputs:
        add(a, RM_RN)
        add(a, RM_RZ)
        add(a, DN)
        add(a, fps_variants())
    for _ in range(n_rand):
        add(rnd_any(), fps_variants())
    # perfect squares and values straddling rounding boundaries
    for _ in range(30):
        r = rnd_normal(100, 154) & 0x7FFFFFFF
        sq, fl = f_mul(r, r, RM_RN, 0)
        if fl == 0:
            add(sq, fps_variants())
    emit("static const struct fpu_s_v2 fpu_s_%s[] = {" % name)
    for v in vecs:
        emit("\t{ 0x%08x, 0x%08x, 0x%08x, 0x%05x, 0x%05x }," % v)
    emit("};")
    emit()
    return vecs


def gen_cmp(n_rand):
    pairs = []
    for a in CORE:
        for b in CORE:
            pairs.append((a, b, RM_RN))
    for a in SPECIALS:
        pairs.append((a, rng.choice(SPECIALS), fps_variants()))
        pairs.append((a, a, DN))
        pairs.append((a, a ^ 0x80000000, RM_RN))
        pairs.append((a, near(a, 1), RM_RN))
    for _ in range(n_rand):
        a = rnd_any()
        b = near(a, 2) if rng.random() < 0.4 else rnd_any()
        pairs.append((a, b, fps_variants()))
    for kind in ("eq", "gt", "ge", "un"):
        emit("static const struct fpu_s_v2 fpu_s_fcmp%s[] = {" % kind)
        for a, b, fps in pairs:
            want, flags = f_cmp(kind, a, b, (fps >> 18) & 1)
            emit("\t{ 0x%08x, 0x%08x, 0x%08x, 0x%05x, 0x%05x }," % (a, b, want, fps, fpscr(fps, flags)))
        emit("};")
        emit()
    return pairs


def gen_ftrc(n_rand):
    inputs = list(SPECIALS)
    inputs += [0x4EFFFFFF, 0x4F000000, 0xCF000000, 0xCF000001, 0x5EFFFFFF, 0x5F000000,
               0xDF000000, 0xDF000001, 0x3F7FFFFF, 0xBF7FFFFF, 0x3FFFFFFF, 0xBFFFFFFF,
               0x4B000000, 0x4AFFFFFF, 0x43000000, 0xC2FE0000, 0x3F800000, 0xBF800000]
    for _ in range(n_rand):
        inputs.append(rnd_normal(100, 200))
        inputs.append(rnd_any())
    for bits, name in ((32, "ftrcsl"), (64, "ftrcsq")):
        emit("static const struct fpu_s_vq fpu_s_%s[] = {" % name)
        for a in inputs:
            fps = fps_variants()
            want, flags = f_ftrc(a, bits)
            emit("\t{ 0x%016xULL, 0x%016xULL, 0x%05x, 0x%05x }," % (a, want, fps, fpscr(fps, flags)))
        emit("};")
        emit()


def gen_float(n_rand):
    ints32 = [0, 1, -1, 2, 3, 0x7FFFFFFF, -0x80000000, 0x7FFFFF80, 0x7FFFFFC0, 0x7FFFFFBF, 0x7FFFFFC1,
              0x01000001, 0x00FFFFFF, 0x01000000, -0x01000001, 0x12345678, -0x12345678, 0x00800000]
    ints64 = [0, 1, -1, 0x7FFFFFFFFFFFFFFF, -0x8000000000000000, 0x7FFFFF8000000000,
              0x7FFFFFC000000000, 0x0123456789ABCDEF, -0x0123456789ABCDEF, 0x0000000100000000,
              0x00000000FFFFFFFF, 0x01000001, 0x1000000000000001, 0x1000001000000000]
    for _ in range(n_rand):
        ints32.append(rng.getrandbits(32) - (1 << 31))
        ints32.append(rng.getrandbits(rng.randint(1, 31)))
        ints64.append(rng.getrandbits(64) - (1 << 63))
        ints64.append(rng.getrandbits(rng.randint(1, 63)))
    emit("static const struct fpu_s_vq fpu_s_floatls[] = {")
    for i in ints32:
        fps = fps_variants()
        want, flags = f_float(i, fps & 1)
        emit("\t{ 0x%016xULL, 0x%016xULL, 0x%05x, 0x%05x }," % (i & 0xFFFFFFFF, want, fps, fpscr(fps, flags)))
    emit("};")
    emit()
    emit("static const struct fpu_s_vq fpu_s_floatqs[] = {")
    for i in ints64:
        fps = fps_variants()
        want, flags = f_float(i, fps & 1)
        emit("\t{ 0x%016xULL, 0x%016xULL, 0x%05x, 0x%05x }," % (i & 0xFFFFFFFFFFFFFFFF, want, fps, fpscr(fps, flags)))
    emit("};")
    emit()


def gen_fmac(n_rand):
    vecs = []
    seen = set()

    def add(a, b, c, fps):
        rm, dn = fps & 1, (fps >> 18) & 1
        if not dn and DNRM in (cls(a), cls(b), cls(c)) and not any(map(is_nan, (a, b, c))):
            if not ((cls(a) == ZERO and cls(b) == INF) or (cls(a) == INF and cls(b) == ZERO)):
                return               # FPU error
        key = (a, b, c, fps)
        if key in seen:
            return
        seen.add(key)
        want, flags = f_mac(a, b, c, rm, dn)
        vecs.append((a, b, c, want, fps, fpscr(fps, flags)))

    for a in CORE:
        for b in CORE:
            add(a, b, rng.choice(CORE), RM_RN)
    for a in SPECIALS:
        add(a, rng.choice(SPECIALS), rng.choice(SPECIALS), fps_variants())
        add(rng.choice(SPECIALS), a, rng.choice(SPECIALS), DN)
        add(rng.choice(SPECIALS), rng.choice(SPECIALS), a, fps_variants())
    # fused cases: a*b exact product cancels against c (result needs the
    # unrounded product), and products that would overflow single precision
    for _ in range(n_rand):
        a, b = rnd_normal(100, 154), rnd_normal(100, 154)
        p, fl = f_mul(a, b, RM_RN, 0)
        if rng.random() < 0.5 and cls(p) == NORM:
            c = p ^ 0x80000000       # exact cancellation of the rounded product
            if rng.random() < 0.5:
                c = near(c, 2)
        else:
            c = rnd_any()
        add(a, b, c, fps_variants())
    for _ in range(n_rand // 2):
        add(rnd_any(), rnd_any(), rnd_any(), fps_variants())
    for fps in (RM_RN, RM_RZ, DN, DN | RM_RZ):
        add(TINY_A, TINY_B, 0x00000000, fps)
        add(TINY_A, TINY_B, 0x80000000, fps)
        add(0x00800000, 0x3F7FFFFF, 0x00000000, fps)
    for _ in range(20):
        add(rnd_normal(230, 254), rnd_normal(230, 254), 0xFF800000, fps_variants())  # huge*huge + -INF = -INF
        add(rnd_normal(230, 254), rnd_normal(230, 254), rnd_normal(), fps_variants())  # overflow
        add(rnd_normal(1, 40), rnd_normal(1, 40), rnd_normal(1, 10), fps_variants())  # tiny
    emit("static const struct fpu_s_v3 fpu_s_fmac[] = {")
    for v in vecs:
        emit("\t{ 0x%08x, 0x%08x, 0x%08x, 0x%08x, 0x%05x, 0x%05x }," % v)
    emit("};")
    emit()
    return vecs


def gen_sina_cosa(n_rand):
    angles = [0, 1, 0x4000, 0x8000, 0xC000, 0xFFFF, 0x2000, 0x6000, 0xA000, 0xE000,
              0x10000, 0x14000, 0xFFFF0000, 0xFFFFC000, 0xFFFF8000, 0x7FFFFFFF, 0x80000000,
              0x12345678, 0x80004000, 0x00003FFF, 0x00004001, 0x1555, 0x2AAB]
    for _ in range(n_rand):
        angles.append(rng.getrandbits(16))
        angles.append(rng.getrandbits(32))
    for cos, name in ((False, "fsina"), (True, "fcosa")):
        emit("static const struct fpu_s_vr fpu_s_%s[] = {" % name)
        for a in angles:
            fps = fps_variants()
            lo, hi = sina_cosa_range(a, cos)
            emit("\t{ 0x%08x, 0x%08x, 0x%08x, 0x%05x, 0x%05x }," % (a & 0xFFFFFFFF, lo, hi, fps, fpscr(fps, F_I)))
        emit("};")
        emit()


def gen_fsrra(n_rand):
    inputs = [x for x in SPECIALS]
    inputs += [0x3F800000, 0x40800000, 0x41800000, 0x3E800000, 0x40000000, 0x3F000000,
               0x7F7FFFFF, 0x00800000, 0x00800001, 0x7F000000, 0x3F7FFFFF, 0x3F800001]
    for _ in range(n_rand):
        inputs.append(rnd_normal())
    emit("static const struct fpu_s_vr fpu_s_fsrra[] = {")
    for a in inputs:
        fps = fps_variants()
        dn = (fps >> 18) & 1
        x = flush(a, dn)
        c = cls(x)
        if c == DNRM and not sgn(x):
            fps |= DN                # +DNRM with DN=0 would raise FPU error
            x = flush(a, 1)
            c = cls(x)
        if c == SN:
            lo, hi, fl = QNAN, QNAN, F_V
        elif c == QN:
            lo, hi, fl = QNAN, QNAN, 0
        elif c == ZERO:
            lo = hi = (x & 0x80000000) | 0x7F800000
            fl = F_Z
        elif sgn(x):                 # -NORM, -INF, -DNRM
            lo, hi, fl = QNAN, QNAN, F_V
        elif c == INF:
            lo, hi, fl = 0, 0, 0
        else:
            lo, hi = srra_range(x)
            fl = F_I
        emit("\t{ 0x%08x, 0x%08x, 0x%08x, 0x%05x, 0x%05x }," % (a, lo, hi, fps, fpscr(fps, fl)))
    emit("};")
    emit()


def rnd_vec4(kind):
    if kind == "moderate":
        return [rnd_normal(110, 144) for _ in range(4)]
    if kind == "mixed":
        return [rnd_normal(90, 164) for _ in range(4)]
    if kind == "wide":
        return [rnd_normal(70, 184) for _ in range(4)]
    return [rnd_any() for _ in range(4)]


def gen_fipr(n_rand):
    vecs = []

    def add(g, h, fps):
        rm, dn = fps & 1, (fps >> 18) & 1
        r = fipr_one(g, h, rm, dn)
        if r is None:
            return
        lo, hi, fl = r
        vecs.append((g, h, lo, hi, fps, fpscr(fps, fl)))

    one = 0x3F800000
    add([one] * 4, [one] * 4, RM_RN)                                  # 4
    add([one, one, one, one], [one, 0xBF800000, one, 0xBF800000], RM_RN)  # 0
    add([0] * 4, [0] * 4, RM_RN)                                      # exact zero
    add([0x80000000] * 4, [0] * 4, RM_RN)
    add([0x40000000, 0x40400000, 0x40800000, 0x40A00000], [one] * 4, RM_RN)  # 2+3+4+5
    add([0x7F800000, one, one, one], [one] * 4, RM_RN)               # +INF
    add([0x7F800000, 0xFF800000, one, one], [one] * 4, RM_RN)        # +INF + -INF: invalid
    add([0x7F800000, one, one, one], [0, one, one, one], RM_RN)      # INF*0: invalid
    add([QNAN, one, one, one], [one] * 4, RM_RN)                     # qNaN
    add([0x7FC00000, one, one, one], [one] * 4, RM_RN)               # sNaN
    add([0x00000001, one, one, one], [one] * 4, RM_RN)               # denormal, DN=0: no FPU error
    add([0x00000001, 0x00400000, one, one], [0x7F800000, one, one, one], RM_RN)
    add([0x00000001, one, one, one], [one] * 4, DN)
    add([0x7F7FFFFF, one, one, one], [one, 0xFF7FFFFF, one, one], RM_RN)  # max - max
    for _ in range(n_rand):
        kind = rng.choice(["moderate", "moderate", "mixed", "wide"])
        g, h = rnd_vec4(kind), rnd_vec4(kind)
        if rng.random() < 0.3 and kind != "wide":
            # cancellation: h[1] chosen so that g1*h1 nearly cancels g0*h0
            p = f_mul(g[0], h[0], RM_RN, 0)[0]
            if cls(p) == NORM:
                q = f_div(p, g[1], RM_RN, 0)[0]
                if cls(q) == NORM:
                    h[1] = near(q ^ 0x80000000, 4)
        add(g, h, fps_variants())
    emit("static const struct fpu_s_vipr fpu_s_fipr[] = {")
    for g, h, lo, hi, fps, fw in vecs:
        emit("\t{ { %s }, 0x%08x, 0x%08x, 0x%05x, 0x%05x }," % (
            ", ".join("0x%08x" % x for x in g + h), lo, hi, fps, fw))
    emit("};")
    emit()


def gen_ftrv(n_rand):
    vecs = []

    def add(m, v, fps):
        rm, dn = fps & 1, (fps >> 18) & 1
        los, his, fl = [], [], 0
        for i in range(4):
            row = [m[i + 4 * j] for j in range(4)]   # column-major: element i+4j
            r = fipr_one(row, v, rm, dn)
            if r is None:
                return
            lo, hi, f = r
            los.append(lo)
            his.append(hi)
            fl |= f
        vecs.append((m, v, los, his, fps, fpscr(fps, fl)))

    one = 0x3F800000
    ident = [one if i % 5 == 0 else 0 for i in range(16)]
    add(ident, [0x40000000, 0x40400000, 0x40800000, 0x40A00000], RM_RN)
    add([one] * 16, [one] * 4, RM_RN)
    add([0] * 16, [one] * 4, RM_RN)
    m = list(ident)
    m[0] = QNAN
    add(m, [one] * 4, RM_RN)                           # row 0 qNaN, others normal
    m = list(ident)
    m[5] = 0x7FC00000
    add(m, [one] * 4, RM_RN)                           # row 1 sNaN: V
    m = list(ident)
    m[2] = 0x7F800000
    add(m, [0] * 4, RM_RN)                             # INF*0 in row 2: V
    m = list(ident)
    m[3] = 0x00000001
    add(m, [one] * 4, RM_RN)                           # denormal in row 3, DN=0
    add(m, [one] * 4, DN)
    for _ in range(n_rand):
        kind = rng.choice(["moderate", "mixed", "wide"])
        add([rnd_normal(*{"moderate": (110, 144), "mixed": (90, 164), "wide": (70, 184)}[kind]) for _ in range(16)],
            rnd_vec4(kind), fps_variants())
    emit("static const struct fpu_s_vtrv fpu_s_ftrv[] = {")
    for m, v, los, his, fps, fw in vecs:
        emit("\t{ { %s }," % ", ".join("0x%08x" % x for x in m))
        emit("\t  { %s }," % ", ".join("0x%08x" % x for x in v))
        emit("\t  { %s }, { %s }, 0x%05x, 0x%05x }," % (
            ", ".join("0x%08x" % x for x in los), ", ".join("0x%08x" % x for x in his), fps, fw))
    emit("};")
    emit()


def gen_bits(n_rand):
    """FABS.S / FNEG.S / FMOV.S / FMOV.LS / FMOV.SL corpus (bit patterns)."""
    vals = list(SPECIALS)
    for _ in range(n_rand):
        vals.append(rng.getrandbits(32))
    emit("static const u32 fpu_s_bits[] = {")
    for i in range(0, len(vals), 6):
        emit("\t" + " ".join("0x%08x," % x for x in vals[i:i + 6]))
    emit("};")
    emit()


# --------------------------------------------------------------- self test --

def selftest():
    global rng
    try:
        import numpy as np
    except ImportError:
        return "numpy not available, cross-check skipped"
    np.seterr(all="ignore")
    saved = rng
    rng = random.Random(1)

    def f32(b):
        return np.frombuffer(struct.pack("<I", b), dtype=np.float32)[0]

    def bits(f):
        return struct.unpack("<I", np.float32(f).tobytes())[0]

    checked = 0
    for _ in range(4000):
        a, b = rnd_any(), rnd_any()
        if is_nan(a) or is_nan(b) or DNRM in (cls(a), cls(b)):
            continue
        for fn, op in ((f_add, np.add), (f_sub, np.subtract), (f_mul, np.multiply), (f_div, np.divide)):
            if fn is f_div and cls(b) == ZERO and cls(a) == ZERO:
                continue
            if fn is f_div and cls(a) == INF and cls(b) == INF:
                continue
            if fn is f_mul and (ZERO in (cls(a), cls(b))) and (INF in (cls(a), cls(b))):
                continue
            if fn in (f_add, f_sub) and cls(a) == INF and cls(b) == INF:
                continue
            want, _ = fn(a, b, RM_RN, 0)
            got = bits(op(f32(a), f32(b), dtype=np.float32))
            assert want == got, "%s a=%08x b=%08x ours=%08x numpy=%08x" % (fn.__name__, a, b, want, got)
            checked += 1
        if cls(a) in (NORM, ZERO, INF) and not sgn(a):
            want, _ = f_sqrt(a, RM_RN, 0)
            got = bits(np.sqrt(f32(a), dtype=np.float32))
            assert want == got, "sqrt a=%08x ours=%08x numpy=%08x" % (a, want, got)
            checked += 1
        i = rng.getrandbits(32) - (1 << 31)
        want, _ = f_float(i, RM_RN)
        assert want == bits(np.float32(i)), "float.ls %d" % i
        checked += 1
    # a few exact rounding corners against struct (host double -> float)
    for x in (Fr(1, 3), Fr(2, 3), Fr(1, 10), Fr(16777217), Fr(1, 1 << 150), Fr(3, 1 << 150)):
        want, _ = round_pack(0, x, RM_RN, 0)
        got = struct.unpack("<I", struct.pack("<f", float(x)))[0]
        assert want == got, "round_pack %s ours=%08x host=%08x" % (x, want, got)
    rng = saved
    return "numpy cross-check of %d normal cases passed" % checked


def main():
    note = selftest()
    emit("/*")
    emit(" * Reference vectors for groups/fpu_s.c, generated by tools/gen_fpu_s.py.")
    emit(" * Do not edit; regenerate with: python3 tools/gen_fpu_s.py > groups/fpu_s_vectors.h")
    emit(" * Expected values come from exact rational arithmetic with IEEE754")
    emit(" * single-precision rounding and the SH-5 special case tables (Vol. 2 ch. 2),")
    emit(" * never from an emulator.  Host self-test: %s." % note)
    emit(" */")
    emit("#ifndef FPU_S_VECTORS_H")
    emit("#define FPU_S_VECTORS_H")
    emit()
    emit("/* a, b (b unused for monadic ops), expected result, FPSCR before, FPSCR after */")
    emit("struct fpu_s_v2 { u32 a, b, want, fps_in, fps_want; };")
    emit("/* FMAC.S: a*b + c */")
    emit("struct fpu_s_v3 { u32 a, b, c, want, fps_in, fps_want; };")
    emit("/* conversions with a 64-bit side: FLOAT.LS/QS (a integer), FTRC.SL/SQ (want integer) */")
    emit("struct fpu_s_vq { u64 a, want; u32 fps_in, fps_want; };")
    emit("/* approximate monadic ops: result must satisfy lo <= got <= hi in value order")
    emit(" * (lo == hi: exact result, compared bitwise) */")
    emit("struct fpu_s_vr { u32 a, lo, hi, fps_in, fps_want; };")
    emit("/* FIPR.S: v[0..3] = FVg, v[4..7] = FVh */")
    emit("struct fpu_s_vipr { u32 v[8]; u32 lo, hi, fps_in, fps_want; };")
    emit("/* FTRV.S: m[16] = MTRXg (column-major, element i + 4*j), v[4] = FVh */")
    emit("struct fpu_s_vtrv { u32 m[16]; u32 v[4]; u32 lo[4], hi[4]; u32 fps_in, fps_want; };")
    emit()
    emit("#define FPU_S_QNAN 0x%08xu" % QNAN)
    emit("#define FPU_S_FPSCR_MASK 0x%05xu" % FPSCR_MASK)
    emit()
    gen_dyadic("fadd", f_add, 260)
    gen_dyadic("fsub", f_sub, 200)
    gen_dyadic("fmul", f_mul, 260)
    gen_dyadic("fdiv", f_div, 260)
    gen_monadic("fsqrt", f_sqrt, SPECIALS, 200)
    gen_cmp(160)
    gen_ftrc(80)
    gen_float(90)
    gen_fmac(220)
    gen_sina_cosa(90)
    gen_fsrra(200)
    gen_fipr(90)
    gen_ftrv(32)
    gen_bits(60)
    emit("#endif /* FPU_S_VECTORS_H */")
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
