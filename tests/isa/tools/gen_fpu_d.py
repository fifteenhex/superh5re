#!/usr/bin/env python3
"""Generate groups/fpu_d_vectors.h: reference vectors for the SH-5 SHmedia
double-precision FPU group (groups/fpu_d.c).

The test program is compiled with -m5-32media, so any C double arithmetic in
the test would run on the FPU under test.  The expected results are therefore
computed here, on the host, from the IEEE754 definitions and the special-case
tables of SH-5 CPU Core Volume 2 (SHmedia) and the FPU chapter of Volume 1:

  - results are computed exactly with fractions.Fraction (or integer square
    roots) and rounded by round_pack() below for both SH-5 rounding modes
    (FPSCR.RM: 0 = round to nearest even, 1 = round toward zero);
  - the FPSCR flag/cause bits follow Vol. 1 section 8.3.6: inexact, overflow
    (always with inexact), underflow = tininess after rounding AND loss of
    accuracy, divide-by-zero, invalid;
  - FPSCR.DN = 1 flushes denormalized sources to signed zero before anything
    else and flushes denormalized results to signed zero signaling inexact
    and underflow (Vol. 1 section 8.4.1);
  - a denormalized source to an arithmetic operation with FPSCR.DN = 0 raises
    the FPU error exception (no result), so those cases are not emitted;
  - NaN results always use the quiet NaN of Vol. 1 Table 75
    (0x7FF7FFFF_FFFFFFFF double, 0x7FBFFFFF single); a NaN is signaling when
    the most significant fraction bit is 1 (Vol. 1 section 3.4);
  - FTRC truncates and saturates: NaN -> most negative integer, +big -> max,
    -big -> min, denormal -> 0 regardless of DN, invalid signaled on
    out-of-range, infinity and NaN (Vol. 2 FTRC.DL/FTRC.DQ special cases).

For round-to-nearest results the generator cross-checks itself against the
host's IEEE double arithmetic (Python floats).  Standard library only.

usage: gen_fpu_d.py [output-file]      (default groups/fpu_d_vectors.h
                                        relative to this script's parent)
"""
import math
import os
import random
import struct
import sys
from fractions import Fraction

# FPSCR layout (Vol. 1 Table 76)
RM_RZ = 1
FLAG_SHIFT = 2
CAUSE_SHIFT = 12
DN = 1 << 18
# exception bits within the FLAG and CAUSE fields
I, U, O, Z, V = 1, 2, 4, 8, 16
E = 32  # CAUSE only

MODES = [0, DN, RM_RZ, DN | RM_RZ]  # FPSCR input values indexed by 'm'

QNAN64 = 0x7FF7FFFFFFFFFFFF
QNAN32 = 0x7FBFFFFF
MASK64 = (1 << 64) - 1

DOUBLE = dict(w=64, p=53, emin=-1022, emax=1023, bias=1023, qnan=QNAN64)
SINGLE = dict(w=32, p=24, emin=-126, emax=127, bias=127, qnan=QNAN32)


class Trap(Exception):
    """FPU error (denormalized source with DN = 0): no result, not emitted."""


# ---------------------------------------------------------------- formats --

def classify(bits, fmt=DOUBLE):
    w, p = fmt['w'], fmt['p']
    ebits = w - p
    sign = bits >> (w - 1)
    exp = (bits >> (p - 1)) & ((1 << ebits) - 1)
    frac = bits & ((1 << (p - 1)) - 1)
    if exp == (1 << ebits) - 1:
        if frac == 0:
            return 'inf', sign
        return ('snan' if frac >> (p - 2) else 'qnan'), sign
    if exp == 0:
        return ('zero' if frac == 0 else 'denorm'), sign
    return 'norm', sign


def to_frac(bits, fmt=DOUBLE):
    """Exact value of a finite number."""
    w, p = fmt['w'], fmt['p']
    ebits = w - p
    sign = bits >> (w - 1)
    exp = (bits >> (p - 1)) & ((1 << ebits) - 1)
    frac = bits & ((1 << (p - 1)) - 1)
    if exp == 0:
        m, e = frac, fmt['emin'] - (p - 1)
    else:
        m, e = frac | (1 << (p - 1)), exp - fmt['bias'] - (p - 1)
    v = Fraction(m) * (Fraction(2) ** e)
    return -v if sign else v


def inf(sign, fmt=DOUBLE):
    w, p = fmt['w'], fmt['p']
    return (sign << (w - 1)) | (((1 << (w - p)) - 1) << (p - 1))


def zero(sign, fmt=DOUBLE):
    return sign << (fmt['w'] - 1)


def maxfinite(sign, fmt=DOUBLE):
    return inf(sign, fmt) - 1


def flush(bits, fpscr, fmt=DOUBLE):
    """FPSCR.DN = 1: denormalized sources become signed zeros."""
    kind, sign = classify(bits, fmt)
    if kind == 'denorm' and (fpscr & DN):
        return zero(sign, fmt), 'zero', sign
    return bits, kind, sign


# --------------------------------------------------------------- rounding --

def frac_to_sig(fr):
    """fr > 0  ->  (sig, exp, sticky) with 2^63 <= sig < 2^64 and
    fr = (sig + eps) * 2^exp, eps in [0,1) nonzero iff sticky."""
    n, d = fr.numerator, fr.denominator
    shift = 63 - (n.bit_length() - d.bit_length())
    while True:
        if shift >= 0:
            q, r = divmod(n << shift, d)
        else:
            q, r = divmod(n, d << -shift)
        if q >= 1 << 64:
            shift -= 1
        elif q < 1 << 63:
            shift += 1
        else:
            return q, -shift, r != 0


def norm_sig(sig, exp, sticky):
    """Renormalize an arbitrary positive (sig, exp, sticky) to 64 bits."""
    bl = sig.bit_length()
    if bl > 64:
        sh = bl - 64
        sticky = sticky or (sig & ((1 << sh) - 1)) != 0
        return sig >> sh, exp + sh, sticky
    sh = 64 - bl
    return sig << sh, exp - sh, sticky


def round_sig(sig, shift, sticky, rm):
    """Drop 'shift' low bits of sig (plus the sticky tail) in rounding mode rm.
    Returns (rounded integer, inexact)."""
    if shift <= 0:
        return sig, sticky
    m = sig >> shift
    rem = sig & ((1 << shift) - 1)
    half = 1 << (shift - 1)
    inexact = rem != 0 or sticky
    if rm == 0:  # round to nearest, ties to even
        if rem > half or (rem == half and sticky):
            m += 1
        elif rem == half and not sticky and (m & 1):
            m += 1
    # rm == RM_RZ: truncate
    return m, inexact


def round_pack(sign, sig, exp, sticky, fpscr, fmt=DOUBLE):
    """Round the positive value (sig + eps) * 2^exp (sig normalized to 64 bits)
    into the format and return (bits, flags).  Vol. 1 sections 8.3.6, 8.4.1."""
    p, emin, emax, w = fmt['p'], fmt['emin'], fmt['emax'], fmt['w']
    rm = fpscr & RM_RZ
    lead = exp + 63  # unbiased exponent of the leading bit
    # rounding as if the exponent range were unbounded (tininess detection)
    m, inexact = round_sig(sig, 64 - p, sticky, rm)
    e = lead
    if m == 1 << p:
        m >>= 1
        e += 1
    if e > emax:
        flags = O | I
        if rm == 0:
            return inf(sign, fmt), flags
        return maxfinite(sign, fmt), flags
    if e >= emin:
        bits = (sign << (w - 1)) | ((e + fmt['bias']) << (p - 1)) | (m - (1 << (p - 1)))
        return bits, (I if inexact else 0)
    # tiny: round in the denormalized grid
    m, inexact = round_sig(sig, 64 - p + (emin - lead), sticky, rm)
    flags = (I | U) if inexact else 0
    if m < 1 << (p - 1) and (fpscr & DN):
        # denormalized result flushed to zero: inexact and underflow signaled
        return zero(sign, fmt), I | U
    # m == 2^(p-1) is the minimum normalized number (exponent field 1)
    return (sign << (w - 1)) | m, flags


def pack_frac(sign, fr, fpscr, fmt=DOUBLE):
    """Round the positive rational fr."""
    sig, exp, sticky = frac_to_sig(fr)
    return round_pack(sign, sig, exp, sticky, fpscr, fmt)


def pack_value(fr, fpscr, fmt=DOUBLE, zero_sign=0):
    """Round a nonzero-or-zero rational with sign; exact zero gets zero_sign."""
    if fr == 0:
        return zero(zero_sign, fmt), 0
    return pack_frac(1 if fr < 0 else 0, abs(fr), fpscr, fmt)


# -------------------------------------------------------------- operations --

def result(bits, flags, fpscr):
    """New FPSCR: cause = this operation, flags sticky-ORed."""
    return bits, fpscr | (flags << CAUSE_SHIFT) | (flags << FLAG_SHIFT)


def fadd(a, b, fpscr):
    a, ka, sa = flush(a, fpscr)
    b, kb, sb = flush(b, fpscr)
    if ka == 'snan' or kb == 'snan':
        return result(QNAN64, V, fpscr)
    if ka == 'qnan' or kb == 'qnan':
        return result(QNAN64, 0, fpscr)
    if ka == 'inf' and kb == 'inf':
        if sa != sb:
            return result(QNAN64, V, fpscr)
        return result(a, 0, fpscr)
    if ka == 'denorm' or kb == 'denorm':
        raise Trap()
    if ka == 'inf':
        return result(a, 0, fpscr)
    if kb == 'inf':
        return result(b, 0, fpscr)
    fr = to_frac(a) + to_frac(b)
    # exact zero: -0 only from (-0) + (-0); cancellation gives +0 in RN and RZ
    zs = sa & sb if (ka == 'zero' and kb == 'zero') else 0
    bits, flags = pack_value(fr, fpscr, zero_sign=zs)
    return result(bits, flags, fpscr)


def fsub(a, b, fpscr):
    # a - b == a + (-b), including the special cases (Vol. 2 FSUB table)
    return fadd(a, b ^ (1 << 63), fpscr)


def fmul(a, b, fpscr):
    a, ka, sa = flush(a, fpscr)
    b, kb, sb = flush(b, fpscr)
    if ka == 'snan' or kb == 'snan':
        return result(QNAN64, V, fpscr)
    if ka == 'qnan' or kb == 'qnan':
        return result(QNAN64, 0, fpscr)
    s = sa ^ sb
    if (ka == 'zero' and kb == 'inf') or (ka == 'inf' and kb == 'zero'):
        return result(QNAN64, V, fpscr)
    if ka == 'denorm' or kb == 'denorm':
        raise Trap()
    if ka == 'inf' or kb == 'inf':
        return result(inf(s), 0, fpscr)
    if ka == 'zero' or kb == 'zero':
        return result(zero(s), 0, fpscr)
    bits, flags = pack_frac(s, abs(to_frac(a) * to_frac(b)), fpscr)
    return result(bits, flags, fpscr)


def fdiv(a, b, fpscr):
    a, ka, sa = flush(a, fpscr)
    b, kb, sb = flush(b, fpscr)
    if ka == 'snan' or kb == 'snan':
        return result(QNAN64, V, fpscr)
    if ka == 'qnan' or kb == 'qnan':
        return result(QNAN64, 0, fpscr)
    s = sa ^ sb
    if (ka == 'zero' and kb == 'zero') or (ka == 'inf' and kb == 'inf'):
        return result(QNAN64, V, fpscr)
    if kb == 'zero' and ka in ('norm', 'denorm'):
        # divide by zero is checked before FPU error: DNRM / 0 -> INF, Z
        return result(inf(s), Z, fpscr)
    if kb == 'denorm' or ka == 'denorm':
        raise Trap()
    if ka == 'inf':
        return result(inf(s), 0, fpscr)  # includes INF / 0
    if kb == 'inf' or ka == 'zero':
        return result(zero(s), 0, fpscr)
    bits, flags = pack_frac(s, abs(to_frac(a) / to_frac(b)), fpscr)
    return result(bits, flags, fpscr)


def fsqrt(a, fpscr):
    a, ka, sa = flush(a, fpscr)
    if ka == 'snan':
        return result(QNAN64, V, fpscr)
    if ka == 'qnan':
        return result(QNAN64, 0, fpscr)
    if ka == 'zero':
        return result(a, 0, fpscr)
    if sa:  # negative infinity, normalized or denormalized: invalid
        return result(QNAN64, V, fpscr)
    if ka == 'inf':
        return result(a, 0, fpscr)
    if ka == 'denorm':
        raise Trap()
    fr = to_frac(a)
    # fr = m * 2^e exactly; make e even, then sqrt(m * 2^(2k)) by isqrt
    m, e = fr.numerator, 0
    d = fr.denominator
    while d > 1:
        d >>= 1
        e -= 1
    if e & 1:
        m <<= 1
        e -= 1
    k = 64
    s = math.isqrt(m << (2 * k))
    sticky = s * s != (m << (2 * k))
    sig, exp, sticky = norm_sig(s, e // 2 - k, sticky)
    bits, flags = round_pack(0, sig, exp, sticky, fpscr)
    return result(bits, flags, fpscr)


def fcnv_ds(a, fpscr):
    a, ka, sa = flush(a, fpscr)
    if ka == 'snan':
        return result(QNAN32, V, fpscr)
    if ka == 'qnan':
        return result(QNAN32, 0, fpscr)
    if ka == 'inf':
        return result(inf(sa, SINGLE), 0, fpscr)
    if ka == 'zero':
        return result(zero(sa, SINGLE), 0, fpscr)
    if ka == 'denorm':
        raise Trap()
    bits, flags = pack_frac(sa, abs(to_frac(a)), fpscr, SINGLE)
    return result(bits, flags, fpscr)


def fcnv_sd(a, fpscr):
    a, ka, sa = flush(a, fpscr, SINGLE)
    if ka == 'snan':
        return result(QNAN64, V, fpscr)
    if ka == 'qnan':
        return result(QNAN64, 0, fpscr)
    if ka == 'inf':
        return result(inf(sa), 0, fpscr)
    if ka == 'zero':
        return result(zero(sa), 0, fpscr)
    if ka == 'denorm':
        raise Trap()
    bits, flags = pack_frac(sa, abs(to_frac(a, SINGLE)), fpscr)
    assert flags == 0  # the conversion is exact
    return result(bits, flags, fpscr)


def ftrc(a, fpscr, nbits):
    """FTRC.DL (nbits 32) / FTRC.DQ (nbits 64): truncate with saturation."""
    ka, sa = classify(a)
    imin, imax = -(1 << (nbits - 1)), (1 << (nbits - 1)) - 1
    mask = (1 << nbits) - 1
    if ka in ('snan', 'qnan'):
        return result(imin & mask, V, fpscr)
    if ka == 'inf':
        return result((imin if sa else imax) & mask, V, fpscr)
    if ka in ('zero', 'denorm'):
        return result(0, 0, fpscr)  # denormalized numbers are 0 regardless of DN
    fr = to_frac(a)
    t = int(fr)  # Python int() truncates toward zero
    if t > imax:
        return result(imax & mask, V, fpscr)
    if t < imin:
        return result(imin & mask, V, fpscr)
    return result(t & mask, 0, fpscr)


def float_ld(a, fpscr):
    v = a - (1 << 32) if a & (1 << 31) else a
    bits, flags = pack_value(Fraction(v), fpscr)
    assert flags == 0
    return result(bits, flags, fpscr)


def float_qd(a, fpscr):
    v = a - (1 << 64) if a & (1 << 63) else a
    bits, flags = pack_value(Fraction(v), fpscr)
    return result(bits, flags, fpscr)


def fcmp(a, b, fpscr):
    """Returns (eq, gt, ge, un) booleans and the invalid bits per op."""
    a, ka, sa = flush(a, fpscr)
    b, kb, sb = flush(b, fpscr)
    nan = ka in ('snan', 'qnan') or kb in ('snan', 'qnan')
    snan = ka == 'snan' or kb == 'snan'
    if nan:
        eq = gt = ge = False
        un = True
    else:
        fa = struct.unpack('<d', struct.pack('<Q', a))[0]
        fb = struct.unpack('<d', struct.pack('<Q', b))[0]
        eq, gt, ge, un = fa == fb, fa > fb, fa >= fb, False
    # invalid: EQ and UN only for signaling NaNs, GT and GE for any NaN
    inv = (snan, nan, nan, snan)
    return (eq, gt, ge, un), inv


# ------------------------------------------------------------- host check --

def host_double(a):
    return struct.unpack('<d', struct.pack('<Q', a))[0]


def host_bits(f):
    return struct.unpack('<Q', struct.pack('<d', f))[0]


def crosscheck(op, a, b, fpscr, got):
    """For RN with finite normal operands, Python's double arithmetic must
    agree bit for bit (x86-64 SSE2 is IEEE754 round-to-nearest, no FTZ)."""
    if fpscr & RM_RZ:
        return
    ka = classify(a)[0]
    kb = classify(b)[0] if b is not None else 'norm'
    if ka not in ('norm', 'zero') or kb not in ('norm', 'zero'):
        return
    fa = host_double(a)
    fb = host_double(b) if b is not None else None
    try:
        if op == 'fadd':
            want = fa + fb
        elif op == 'fsub':
            want = fa - fb
        elif op == 'fmul':
            want = fa * fb
        elif op == 'fdiv':
            want = fa / fb
        elif op == 'fsqrt':
            want = math.sqrt(fa)
        else:
            return
    except (ZeroDivisionError, OverflowError, ValueError):
        return
    if fpscr & DN and classify(host_bits(want))[0] == 'denorm':
        return
    assert host_bits(want) == got, (op, hex(a), hex(b or 0), hex(got), hex(host_bits(want)))


# -------------------------------------------------------------- operands --

def d(x):
    return host_bits(float(x))


# Main corpus for the dyadic cross products (indexed by the u16 fields).
VALS = [
    0x0000000000000000,  # +0
    0x8000000000000000,  # -0
    d(1.0), d(-1.0), d(2.0), d(0.5), d(-3.0), d(1.5),
    0x3FB999999999999A,  # 0.1
    0x3FD5555555555555,  # 1/3
    0x400921FB54442D18,  # pi
    0xC005BF0A8B145769,  # -e
    0x419D6F3454000000,  # 123456789.0
    0x4330000000000001,  # 2^52 + 1
    0x7E37E43C8800759C,  # 1e300
    0x7FEFFFFFFFFFFFFF,  # max finite
    0xFFEFFFFFFFFFFFFF,  # -max finite
    0x7FE0000000000000,  # 2^1023
    0x0010000000000000,  # min normal 2^-1022
    0x8010000000000000,  # -min normal
    0x0020000000000000,  # 2^-1021
    0x0000000000000001,  # min denormal
    0x8000000000000001,  # -min denormal
    0x000FFFFFFFFFFFFF,  # max denormal
    0x8008000000000000,  # -2^-1023
    0x7FF0000000000000,  # +inf
    0xFFF0000000000000,  # -inf
    0x7FF7FFFFFFFFFFFF,  # default qNaN
    0xFFF0000000000001,  # another qNaN
    0x7FF8000000000000,  # sNaN
    0xFFFFFFFFFFFFFFFF,  # sNaN (all ones)
]

# operands for which FPSCR.DN can change the outcome of a dyadic operation
DN_SENSITIVE = {
    0x0000000000000000, 0x8000000000000000, 0x0010000000000000, 0x8010000000000000,
    0x0020000000000000, 0x0000000000000001, 0x8000000000000001, 0x000FFFFFFFFFFFFF,
    0x8008000000000000, 0x7FEFFFFFFFFFFFFF, 0xFFEFFFFFFFFFFFFF, 0x7FE0000000000000,
    0x7E37E43C8800759C, d(0.5), 0x7FF0000000000000, 0xFFF0000000000000,
}

# subset for the round-toward-zero cross products
RZ_VALS = [
    d(1.0), d(-1.0), 0x3FB999999999999A, 0xC005BF0A8B145769, 0x7E37E43C8800759C,
    0x7FEFFFFFFFFFFFFF, 0xFFEFFFFFFFFFFFFF, 0x0010000000000000, 0x0000000000000001,
    0x000FFFFFFFFFFFFF, 0x7FF0000000000000, 0x7FF7FFFFFFFFFFFF, 0x7FF8000000000000,
]

# targeted pairs (a, b): exact / inexact / tie / overflow / underflow cases
TARGETED = [
    (d(1.0), 0x3CA0000000000000),            # 1 + 2^-53: tie, rounds to 1
    (d(1.0), 0x3CA0000000000001),            # 1 + (2^-53 + ulp): rounds up
    (d(1.0), 0x3C90000000000000),            # 1 + 2^-54: rounds to 1
    (0x3FF0000000000001, 0x3CA0000000000000),  # (1+ulp) + 2^-53: tie to even -> 1+2ulp
    (d(1.0), 0x3CB0000000000000),            # 1 + 2^-52: exact
    (0x7FEFFFFFFFFFFFFF, 0x7FEFFFFFFFFFFFFF),  # max + max: overflow
    (0x7FEFFFFFFFFFFFFF, 0x7C90000000000000),  # max + 2^970 (half ulp): tie -> overflow
    (0x7FEFFFFFFFFFFFFF, 0x7C8FFFFFFFFFFFFF),  # max + just under half ulp: max, inexact
    (0x7FEFFFFFFFFFFFFF, 0x7CA0000000000000),  # max + 1 ulp: exact overflow? no: 2^1024 -> inf
    (0x0010000000000000, 0x8000000000000001),  # min normal - min denormal: denormal result
    (0x0010000000000000, 0x0010000000000000),  # 2 * min normal
    (0x0000000000000001, 0x0000000000000001),  # denormal + denormal
    (0x0008000000000000, 0x0008000000000000),  # 2^-1023 + 2^-1023 = min normal
    (0x0010000000000001, 0x8010000000000000),  # (minnorm+ulp) - minnorm = min denormal
    (0x3FF0000000000000, 0xBFF0000000000000),  # 1 - 1 = +0
    (0x0010000000000000, 0x0000000000000001),  # min normal + min denormal
    (0x4340000000000000, 0x3FF0000000000000),  # 2^53 + 1: tie -> 2^53
    (0x4340000000000000, 0x3FF8000000000000),  # 2^53 + 1.5: rounds to 2^53 + 2
    (0x4340000000000001, 0x3FF0000000000000),  # (2^53+2) + 1: tie to even -> 2^53+4
    (0x7FE0000000000000, 0x4000000000000000),  # 2^1023 * 2: overflow
    (0x7FE0000000000000, 0x3FF8000000000000),  # 2^1023 * 1.5 exact
    (0x0010000000000000, 0x3FE0000000000000),  # min normal * 0.5 = 2^-1023 denormal exact
    (0x0010000000000000, 0x3FD0000000000000),  # min normal * 0.25
    (0x3FD5555555555555, 0x4008000000000000),  # (1/3) * 3: inexact, rounds to 1
    (0x0010000000000001, 0x3FE0000000000000),  # (minnorm + ulp) * 0.5: tie, inexact tiny
    (0x0010000000000003, 0x3FE0000000000000),  # (minnorm + 3ulp) * 0.5: rounds up
    (0x0010000000000000, 0x3FDFFFFFFFFFFFFF),  # minnorm * (0.5 - tiny): tiny, inexact
    (0x001FFFFFFFFFFFFF, 0x3FE0000000000000),  # just below 2*minnorm * 0.5: tie up -> min normal
    (0x0160000000000000, 0x0160000000000000),  # 2^-1001 * 2^-1001: underflow to 0
    (0x0170000000000000, 0x0190000000000000),  # 2^-1000 * 2^-998 = 2^-1998 -> 0 (no DN)
    (0x0170000000000000, 0x3C30000000000000),  # 2^-1000 * 2^-60 = 2^-1060 exact denormal
    (d(6.0), d(3.0)),                          # exact division
    (d(1.0), d(3.0)),                          # inexact division
    (d(1.0), 0x0010000000000000),              # 1 / min normal = 2^1022
    (d(1.0), 0x000FFFFFFFFFFFFF),              # 1 / max denormal (trap with DN=0)
    (0x0010000000000000, d(2.0)),              # min normal / 2: exact denormal
    (0x0010000000000001, d(2.0)),              # (min normal + ulp) / 2: tie
    (0x7FEFFFFFFFFFFFFF, 0x3FE0000000000000),  # max / 0.5: overflow
    (0x7FEFFFFFFFFFFFFF, 0x3FEFFFFFFFFFFFFF),  # max / (1 - ulp): overflow in RN, max in RZ
    (0x0000000000000001, d(2.0)),              # min denormal / 2: tie to even -> 0
    (0x0000000000000003, d(2.0)),              # 3 * min denormal / 2 -> 2 min denormals
    (0x0000000000000001, 0x0000000000000000),  # min denormal / +0: divide by zero
    (0x8000000000000001, 0x0000000000000000),  # -min denormal / +0
    (0x0000000000000001, 0x7FF0000000000000),  # denormal / inf (trap with DN=0)
    (0x7FF0000000000000, 0x0000000000000001),  # inf / denormal (trap with DN=0)
    (0x0000000000000001, 0x7FF8000000000000),  # denormal with sNaN: invalid, no error
    (0x0000000000000001, 0x7FF7FFFFFFFFFFFF),  # denormal with qNaN: qNaN, no error
    (0x7FF7FFFFFFFFFFFF, 0x7FF8000000000000),  # qNaN with sNaN: invalid
    (0xFFF8000000000000, 0xFFF8000000000000),  # negative sNaNs
    (0x7FF0000000000001, 0x3FF0000000000000),  # qNaN with small payload
    (0x7FF7FFFFFFFFFFFF, 0x3FF0000000000000),  # default qNaN + 1
]


def random_normals(rng, n, lo=-60, hi=60):
    out = []
    for _ in range(n):
        s = rng.getrandbits(1)
        e = rng.randint(lo, hi) + 1023
        f = rng.getrandbits(52)
        out.append((s << 63) | (e << 52) | f)
    return out


# ------------------------------------------------------------------ emit --

def main():
    out_path = (sys.argv[1] if len(sys.argv) > 1 else
                os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                             'groups', 'fpu_d_vectors.h'))
    rng = random.Random(0x5a5a1234)

    vals = list(VALS)
    # all operands used by the dyadic tables must be in the value table
    val_index = {}

    def vi(x):
        if x not in val_index:
            val_index[x] = len(vals)
            vals.append(x)
        return val_index[x]

    for i, v in enumerate(vals):
        val_index[v] = i

    rand_pairs = {}
    for op in ('fadd', 'fsub', 'fmul', 'fdiv'):
        lo, hi = (-60, 60) if op != 'fmul' else (-540, 540)
        pairs = []
        for _ in range(40):
            a, = random_normals(rng, 1, lo, hi)
            b, = random_normals(rng, 1, lo, hi)
            pairs.append((a, b))
        rand_pairs[op] = pairs
    # a few random pairs with equal-magnitude exponents for cancellation
    cancel = []
    for _ in range(16):
        a, = random_normals(rng, 1, -5, 5)
        b = (a ^ (1 << 63)) ^ rng.getrandbits(3)
        cancel.append((a, b))

    ops = {'fadd': fadd, 'fsub': fsub, 'fmul': fmul, 'fdiv': fdiv}
    dyadic = {op: [] for op in ops}
    skipped = 0
    for op, fn in ops.items():
        pairlist = []
        for m, fpscr in enumerate(MODES):
            cross = VALS if not (fpscr & RM_RZ) else RZ_VALS
            for a in cross:
                for b in cross:
                    # DN = 1 behaves as DN = 0 unless a source is denormalized
                    # or the result can be: keep only those pairs
                    if fpscr == DN and not (a in DN_SENSITIVE or b in DN_SENSITIVE):
                        continue
                    pairlist.append((m, a, b))
            for a, b in TARGETED + rand_pairs[op] + cancel:
                pairlist.append((m, a, b))
                if op in ('fsub', 'fdiv'):
                    pairlist.append((m, b, a))
        seen = set()
        for m, a, b in pairlist:
            if (m, a, b) in seen:
                continue
            seen.add((m, a, b))
            fpscr = MODES[m]
            try:
                r, fps = fn(a, b, fpscr)
            except Trap:
                skipped += 1
                continue
            crosscheck(op, a, b, fpscr, r)
            dyadic[op].append((vi(a), vi(b), m, r, fps))

    # compares: full cross product with DN = 0 and DN = 1 (denormals allowed);
    # NaN operands are paired with one representative of each value class only
    # (the manual's tables have one row per class), to keep the output short
    cmp_entries = []
    cmp_vals = VALS + [0x3FF0000000000001, 0x8000000000000002, 0x000FFFFFFFFFFFFE]
    nan_partners = {
        d(1.0), d(-1.0), 0x0000000000000000, 0x8000000000000000,
        0x7FF0000000000000, 0xFFF0000000000000, 0x0000000000000001, 0x8008000000000000,
        0x7FF7FFFFFFFFFFFF, 0xFFF0000000000001, 0x7FF8000000000000, 0xFFFFFFFFFFFFFFFF,
    }
    for m in (0, 1):
        fpscr = MODES[m]
        for a in cmp_vals:
            for b in cmp_vals:
                if (classify(a)[0] in ('qnan', 'snan') and b not in nan_partners) or \
                   (classify(b)[0] in ('qnan', 'snan') and a not in nan_partners):
                    continue
                res, inv = fcmp(a, b, fpscr)
                rbits = sum(int(x) << i for i, x in enumerate(res))
                ibits = sum(int(x) << i for i, x in enumerate(inv))
                cmp_entries.append((vi(a), vi(b), m, rbits, ibits))

    assert len(vals) <= 65536

    # monadic tables: (input, result, fpscr_in, fpscr_out)
    sqrt_in = VALS + [
        d(4.0), d(9.0), d(2.0), d(0.25), 0x4000000000000001, d(1e-300),
        0x0010000000000001, 0x7FEFFFFFFFFFFFFE, 0x0008000000000000,
    ] + random_normals(rng, 24, -1000, 1000)
    sqrt_vec = []
    for fpscr in MODES:
        for a in sqrt_in:
            try:
                r, fps = fsqrt(a, fpscr)
            except Trap:
                skipped += 1
                continue
            crosscheck('fsqrt', a, None, fpscr, r)
            sqrt_vec.append((a, r, fpscr, fps))

    cnvds_in = VALS + [
        0x47F0000000000000,  # 2^128: overflow
        0x47EFFFFFE0000000,  # max single, exact
        0x47EFFFFFF0000000,  # max single + half ulp: tie -> overflow (RN)
        0x47EFFFFFE8000000,  # max single + quarter ulp: max single, inexact
        0x47EFFFFFF8000000,  # above half ulp: overflow
        0x3810000000000000,  # 2^-126: min normal single
        0x3800000000000000,  # 2^-127: single denormal, exact
        0x36A0000000000000,  # 2^-149: min denormal single, exact
        0x3690000000000000,  # 2^-150: tie -> +0, inexact underflow
        0x3698000000000000,  # 1.5 * 2^-150: rounds to min denormal
        0x3680000000000000,  # 2^-151: rounds to 0
        0x380FFFFFFFFFFFFF,  # just below 2^-126: ties up to min normal, not tiny after rounding
        0x380FFFFFE0000000,  # 2^-126 * (1 - 2^-24): rounds in denormal grid
        0x3FF0000010000000,  # 1 + 2^-24: tie -> 1.0f
        0x3FF0000020000000,  # 1 + 2^-23: exact
        0x3FF0000010000001,  # 1 + 2^-24 + tiny: rounds up
        0x3FF0000030000000,  # 1 + 3 * 2^-24: tie to even -> 1 + 2^-22
        0xC1DFFFFFFFC00000,  # -2147483647.0
        0x7FF0DEADBEEF0000,  # qNaN with payload
        0xFFF8DEADBEEF0000,  # negative sNaN
    ] + random_normals(rng, 16, -140, 140)
    cnvds_vec = []
    for fpscr in MODES:
        for a in cnvds_in:
            try:
                r, fps = fcnv_ds(a, fpscr)
            except Trap:
                skipped += 1
                continue
            if not (fpscr & RM_RZ) and classify(a)[0] == 'norm':
                hs = struct.unpack('<I', struct.pack('<f', host_double(a)))[0] \
                    if abs(host_double(a)) < 3.4028235677973366e38 else None
                if hs is not None and not (fpscr & DN and classify(hs, SINGLE)[0] == 'denorm'):
                    assert hs == r, (hex(a), hex(r), hex(hs))
            cnvds_vec.append((a, r, fpscr, fps))

    cnvsd_in = [
        0x00000000, 0x80000000, 0x3F800000, 0xBF800000, 0x40490FDB, 0x3EAAAAAB,
        0x7F7FFFFF, 0xFF7FFFFF, 0x00800000, 0x80800000, 0x00000001, 0x80000001,
        0x007FFFFF, 0x00400000, 0x7F800000, 0xFF800000, 0x7FBFFFFF, 0x7F800001,
        0xFFBFFFFF, 0x7FC00000, 0x7FFFFFFF, 0xFFC00001, 0x4B800000, 0x33800000,
        0x3F7FFFFF, 0x4F000000, 0xCF000000, 0x5F000000,
    ]
    for _ in range(12):
        cnvsd_in.append((rng.getrandbits(1) << 31) | (rng.randint(1, 254) << 23) | rng.getrandbits(23))
    cnvsd_vec = []
    for fpscr in MODES[:2]:
        for a in cnvsd_in:
            try:
                r, fps = fcnv_sd(a, fpscr)
            except Trap:
                skipped += 1
                continue
            if classify(a, SINGLE)[0] == 'norm':
                hf = struct.unpack('<f', struct.pack('<I', a))[0]
                assert host_bits(hf) == r
            cnvsd_vec.append((a, r, fpscr, fps))

    ftrc_in = VALS + [
        d(2147483647.0), d(-2147483648.0), 0x41E0000000000000,  # 2^31
        0x41DFFFFFFFE00000,   # 2147483647.5
        0xC1E0000000100000,   # -2147483648.5 (truncates into range)
        0xC1E0000000200000,   # -2147483649
        0x41DFFFFFFFFFFFFF,   # just below 2^31
        0x43E0000000000000,   # 2^63
        0xC3E0000000000000,   # -2^63 (in range for DQ)
        0x43DFFFFFFFFFFFFF,   # 2^63 - 1024
        0xC3E0000000000001,   # just below -2^63
        0x43F0000000000000,   # 2^64
        0x4330000000000001,   # 2^52 + 1
        0x3FEFFFFFFFFFFFFF,   # 0.99999...
        0xBFEFFFFFFFFFFFFF,   # -0.99999...
        0x3FE0000000000000,   # 0.5
        0xBFF8000000000000,   # -1.5
        0x40FFFFFFFFFFFFFF,   # 131071.99999
        0xC0FFFFFFFFFFFFFF,
        0x7FF0DEADBEEF0000, 0xFFF8DEADBEEF0000,
    ] + random_normals(rng, 8, -2, 70)
    ftrc_dl_vec, ftrc_dq_vec = [], []
    for fpscr in MODES[:2]:
        for a in ftrc_in:
            r, fps = ftrc(a, fpscr, 32)
            ftrc_dl_vec.append((a, r, fpscr, fps))
            r, fps = ftrc(a, fpscr, 64)
            ftrc_dq_vec.append((a, r, fpscr, fps))

    ld_in = [0, 1, 0xFFFFFFFF, 2, 0xFFFFFFFE, 0x7FFFFFFF, 0x80000000, 0x80000001,
             0x00010000, 0xFFFF0000, 0x12345678, 0xDEADBEEF, 0x00FFFFFF, 0x01000000,
             0x7FFFFFFE, 0x40000000, 0xC0000000, 0x00000080, 0xFFFFFF80]
    ld_in += [rng.getrandbits(32) for _ in range(12)]
    float_ld_vec = []
    for fpscr in MODES[:2]:
        for a in ld_in:
            r, fps = float_ld(a, fpscr)
            assert host_bits(float(a - (1 << 32) if a >> 31 else a)) == r
            float_ld_vec.append((a, r, fpscr, fps))

    qd_in = [0, 1, MASK64, 2, 0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0x8000000000000001,
             0x0020000000000000,   # 2^53: exact
             0x0020000000000001,   # 2^53 + 1: tie -> 2^53
             0x0020000000000002,   # 2^53 + 2: exact
             0x0020000000000003,   # 2^53 + 3: tie to even -> 2^53 + 4
             0x0040000000000005,   # 2^54 + 5: rounds
             0xFFDFFFFFFFFFFFFF,   # -(2^53 + 1)
             0x7FFFFFFFFFFFFC00,   # 2^63 - 1024: exact
             0x7FFFFFFFFFFFFBFF,   # inexact
             0x0123456789ABCDEF, 0xFEDCBA9876543210, 0x00000000FFFFFFFF, 0xFFFFFFFF00000000,
             0x00000000DEADBEEF, 0xDEADBEEF00000000, 0x5555555555555555, 0xAAAAAAAAAAAAAAAA]
    qd_in += [rng.getrandbits(64) for _ in range(16)]
    float_qd_vec = []
    for fpscr in MODES:
        for a in qd_in:
            r, fps = float_qd(a, fpscr)
            if not (fpscr & RM_RZ):
                v = a - (1 << 64) if a >> 63 else a
                assert host_bits(float(v)) == r  # Python int->float is RNE
            float_qd_vec.append((a, r, fpscr, fps))

    # ------------------------------------------------------------ write --
    lines = []
    w = lines.append
    w('/* Generated by tools/gen_fpu_d.py from IEEE754 and the SH-5 manuals; do not edit. */')
    w('#ifndef FPD_VECTORS_H')
    w('#define FPD_VECTORS_H')
    w('')
    w('/* FPSCR input values indexed by the m field. */')
    w('static const u32 fpd_modes[%d] = { %s };' % (len(MODES), ', '.join('0x%08x' % x for x in MODES)))
    w('')
    w('/* Operand table indexed by the a and b fields. */')
    w('static const u64 fpd_vals[%d] = {' % len(vals))
    for i in range(0, len(vals), 3):
        w('\t' + ' '.join('0x%016x,' % x for x in vals[i:i + 3]))
    w('};')
    w('')
    w('/* a op b with FPSCR = fpd_modes[m]: result r, FPSCR afterwards fpscr.')
    w(' * The cases whose result is a NaN are in separate *_nan_vec tables so')
    w(' * that the group can run them last. */')
    w('struct fpd_dyadic { u16 a, b; u8 m; u64 r; u32 fpscr; };')
    for op in ops:
        for suffix, isnan in (('', False), ('_nan', True)):
            vec = [e for e in dyadic[op] if (e[3] == QNAN64) == isnan]
            w('static const struct fpd_dyadic fpd_%s%s_vec[%d] = {' % (op, suffix, len(vec)))
            for a, b, m, r, fps in vec:
                w('\t{%d,%d,%d,0x%016x,0x%x},' % (a, b, m, r, fps))
            w('};')
    w('')
    w('/* Comparisons: res bit0 EQ, bit1 GT, bit2 GE, bit3 UN; inv: invalid signaled, same order. */')
    w('struct fpd_cmp { u16 a, b; u8 m, res, inv; };')
    w('static const struct fpd_cmp fpd_cmp_vec[%d] = {' % len(cmp_entries))
    for a, b, m, r, inv in cmp_entries:
        w('\t{%d,%d,%d,%d,%d},' % (a, b, m, r, inv))
    w('};')
    w('')
    w('/* Monadic operations: input a, result r, FPSCR before and after. */')
    w('struct fpd_monadic { u64 a, r; u32 fpscr_in, fpscr; };')
    for name, allvec, nanval in (('fsqrt', sqrt_vec, QNAN64), ('fcnv_ds', cnvds_vec, QNAN32),
                                 ('fcnv_sd', cnvsd_vec, QNAN64), ('ftrc_dl', ftrc_dl_vec, None),
                                 ('ftrc_dq', ftrc_dq_vec, None), ('float_ld', float_ld_vec, None),
                                 ('float_qd', float_qd_vec, None)):
        for suffix, isnan in (('', False), ('_nan', True)):
            if nanval is None and isnan:
                continue
            vec = [e for e in allvec if (e[1] == nanval) == isnan]
            w('static const struct fpd_monadic fpd_%s%s_vec[%d] = {' % (name, suffix, len(vec)))
            for a, r, fi, fo in vec:
                w('\t{0x%016x,0x%016x,0x%x,0x%x},' % (a, r, fi, fo))
            w('};')
    w('')
    w('#endif /* FPD_VECTORS_H */')
    with open(out_path, 'w') as f:
        f.write('\n'.join(lines) + '\n')

    n_dyadic = sum(len(v) for v in dyadic.values())
    n_mono = sum(len(v) for v in (sqrt_vec, cnvds_vec, cnvsd_vec, ftrc_dl_vec,
                                  ftrc_dq_vec, float_ld_vec, float_qd_vec))
    sys.stderr.write('%s: %d operands, %d dyadic, %d compare, %d monadic vectors '
                     '(%d FPU-error cases skipped)\n'
                     % (os.path.relpath(out_path), len(vals), n_dyadic,
                        len(cmp_entries), n_mono, skipped))


if __name__ == '__main__':
    main()
