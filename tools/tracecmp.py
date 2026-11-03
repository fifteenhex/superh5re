#!/usr/bin/env python3
"""Compare the instruction stream of the RTL model with QEMU.

usage: tracecmp.py RTL_TRACE QEMU_EXEC_LOG [--max N] [--ignore LO-HI]...

--ignore drops instructions whose PC lies in [LO, HI] (hex) from both
streams, for polling loops whose trip count depends on device timing.

RTL_TRACE is the commit trace of rtl/tb/core (one line per committed
instruction: "pc insn [rN=value]"); QEMU_EXEC_LOG is the output of
qemu-system-sh5 -d exec,nochain with -accel tcg,one-insn-per-tb=on
("Trace 0: 0x... [flags/pc/...]" per instruction). Prints the first
divergence of the program counter sequence with context, or the number of
matching instructions.
"""
import sys


def rtl_pcs(path):
    out = []
    with open(path) as f:
        for line in f:
            parts = line.split()
            if not parts or parts[0] in ('bus', 'fpu'):
                continue
            # optional leading cycle number
            pc = parts[1] if len(parts) > 2 and len(parts[0]) < 8 else parts[0]
            try:
                out.append(int(pc, 16) & 0xffffffff)
            except ValueError:
                continue
    return out


def qemu_pcs(path):
    out = []
    with open(path) as f:
        for line in f:
            if not line.startswith('Trace '):
                continue
            lb = line.find('[')
            if lb < 0:
                continue
            fields = line[lb + 1:].split('/')
            if len(fields) < 2:
                continue
            out.append(int(fields[1], 16) & 0xffffffff)
    return out


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    maxn = None
    if '--max' in argv:
        maxn = int(argv[argv.index('--max') + 1])
    ranges = []
    for i, x in enumerate(argv):
        if x == '--ignore':
            lo, hi = argv[i + 1].split('-')
            ranges.append((int(lo, 16), int(hi, 16)))

    def keep(pc):
        return not any(lo <= pc <= hi for lo, hi in ranges)

    a = [pc for pc in rtl_pcs(argv[1]) if keep(pc)]
    b = [pc for pc in qemu_pcs(argv[2]) if keep(pc)]
    # QEMU logs a translation block when it is entered; a block abandoned
    # before execution (pending interrupt, I/O) appears twice in a row.
    i = j = dup = 0
    hist = []
    while i < len(a) and j < len(b) and (maxn is None or i < maxn):
        if a[i] == b[j]:
            hist.append((a[i], b[j]))
            i += 1
            j += 1
            continue
        if j > 0 and b[j] == b[j - 1]:
            j += 1
            dup += 1
            continue
        print('divergence at instruction %d: rtl %08x qemu %08x' % (i, a[i], b[j]))
        for k, (x, y) in enumerate(hist[-8:]):
            print('  %7d rtl %08x qemu %08x' % (i - len(hist[-8:]) + k, x, y))
        for k in range(4):
            if i + k < len(a) and j + k < len(b):
                print('  %7d rtl %08x qemu %08x%s' % (i + k, a[i + k], b[j + k], ' <--' if k == 0 else ''))
        return 1
    print('%d instructions match (rtl %d, qemu %d, %d repeated qemu entries skipped)' % (i, len(a), len(b), dup))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
