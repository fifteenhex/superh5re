#!/usr/bin/env python3
"""Compare register writes of the RTL commit trace with QEMU CPU state dumps.

usage: regcmp.py RTL_TRACE QEMU_CPU_LOG FIRST

RTL_TRACE: commit trace of rtl/tb/core ("pc insn [rN=value]" per line).
QEMU_CPU_LOG: output of qemu-system-sh5 -d exec,nochain,cpu with
-accel tcg,one-insn-per-tb=on, restricted to a window of instructions; FIRST
is the 1-based instruction number of the first "Trace" line in it. Each dump
shows the state before its instruction, so the write recorded by RTL line L
is checked against the dump of instruction L+1. Prints every mismatch.
"""
import re
import sys


def main(argv):
    if len(argv) < 4:
        sys.exit(__doc__)
    first = int(argv[3])
    # QEMU dumps: list of (pc, {reg: value}) in instruction order
    dumps = []
    cur = None
    with open(argv[2]) as f:
        for line in f:
            if line.startswith('Trace'):
                lb = line.find('[')
                pc = int(line[lb + 1:].split('/')[1], 16) & 0xffffffff
                cur = (pc, {})
                dumps.append(cur)
            elif cur is not None:
                for m in re.finditer(r'\b(r\d\d|tr\d)=([0-9a-f]{16})', line):
                    name = m.group(1)
                    if name.startswith('r'):
                        name = 'r%d' % int(name[1:])
                    cur[1][name] = int(m.group(2), 16)
    rtl = []
    with open(argv[1]) as f:
        for line in f:
            parts = line.split()
            if not parts or parts[0] in ('bus', 'fpu'):
                continue
            rtl.append(parts)
    bad = 0
    for k in range(len(dumps) - 1):
        n = first + k            # instruction number of dumps[k]
        if n - 1 >= len(rtl) or n < 1:
            continue
        line = rtl[n - 1]        # RTL line of instruction n
        pc = int(line[0], 16)
        if pc != dumps[k][0]:
            print('pc mismatch at instruction %d: rtl %08x qemu %08x' % (n, pc, dumps[k][0]))
            bad += 1
            break
        for tok in line[2:]:
            if '=' not in tok:
                continue
            reg, val = tok.split('=')
            val = int(val, 16)
            q = dumps[k + 1][1].get(reg)
            if q is not None and q != val:
                print('instruction %d pc %08x insn %s: %s rtl %016x qemu %016x' %
                      (n, pc, line[1], reg, val, q))
                bad += 1
    print('%d dumps compared, %d mismatches' % (len(dumps), bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
