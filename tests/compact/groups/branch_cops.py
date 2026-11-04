"""SHcompact routines of the branch group. All carry their own RTS.
Results: R0 path marker, R1 delay slot count (ADD #1,R1 in the slot),
R2 PR - L (L = address after the delay slot, loaded with MOVA) or the slot
count seen at the target, R3 slot count seen at the target or the caller's
PR (saved there around BSR/BSRF/JSR/LDS PR). Fillers are ADD #1,R2 or ADD #1,R1: landing in
one changes a result."""

FILL2 = 'add #1, r2\n'
FILL1 = 'add #1, r1\n'
# JMP/JSR/BRAF/BSRF/RTS target blocks (offset -> marker in branch.c)
BLOCKS_POS = 4          # blocks at L + 6k, marker k
BLOCKS_NEG = 4          # blocks at L - 14 - 6j, marker -2 - j


def define(add):
    # ---- BT/BF near: taken r0 = 4 r1 = 0, not taken r0 = 6 r1 = 1 (d bit 0 = T)
    for b in ['bt', 'bf']:
        add(f'{b}_near', f'shlr r7\nmov #0, r0\nmov #0, r1\n{b} 1f\nadd #1, r1\nadd #2, r0\n1: add #4, r0\nrts\nnop',
            own_rts=True)
    # ---- BT/S, BF/S near: slot counted in r1, r3 = r1 at the target
    for b in ['bt/s', 'bf/s']:
        n = b.replace('/', '')
        add(f'{n}_near', f'shlr r7\nmov #0, r0\nmov #0, r1\nmov #0, r3\n{b} 1f\nadd #1, r1\nadd #2, r0\n'
            '1: mov r1, r3\nadd #4, r0\nrts\nnop', own_rts=True)
        # the slot changes T: the condition is the T before the slot
        slot = 'clrt' if b == 'bt/s' else 'sett'
        add(f'{n}_tslot', f'shlr r7\nmov #0, r0\n{b} 1f\n{slot}\nadd #2, r0\n1: add #4, r0\nmovt r1\nrts\nnop',
            own_rts=True)
    # ---- conditional, maximum forward displacement (+127): branch at offset 8,
    # target at 8 + 4 + 254 = 266
    for b in ['bt', 'bf', 'bt/s', 'bf/s']:
        n = b.replace('/', '')
        d = b.endswith('/s')
        body = 'shlr r7\nmov #0, r0\nmov #0, r1\nmov #0, r2\n'   # 0..6
        body += f'{b} 1f\n'                                          # 8
        body += 'add #1, r1\n' if d else ''                          # 10 slot
        body += 'bra 2f\nadd #2, r0\n'                               # not taken
        used = 8 + 2 + (2 if d else 0) + 4
        body += FILL2 * ((266 - used) // 2)
        body += '1: add #4, r0\n2: rts\nnop'
        add(f'{n}_fwd', body, own_rts=True)
    # ---- conditional, maximum backward displacement (-128): target T = 12,
    # branch at T + 252 = 264
    for b in ['bt', 'bf', 'bt/s', 'bf/s']:
        n = b.replace('/', '')
        d = b.endswith('/s')
        body = 'shlr r7\nmov #0, r0\nmov #0, r1\nmov #0, r2\nbra 2f\nnop\n'   # 0..10
        body += '1: add #4, r0\nbra 3f\nnop\n'                                # 12 (T), 14, 16
        body += FILL2 * ((264 - 4 - 18) // 2)                                 # 18 .. 259
        body += 'bra 3f\nnop\n'                                               # 260, 262
        body += f'2: {b} 1b\n'                                                # 264
        body += 'add #1, r1\n' if d else ''
        body += 'add #2, r0\n3: rts\nnop'
        add(f'{n}_back', body, own_rts=True)
    # ---- BRA near, maximum forward (+2047) and backward (-2048): r0 = 4,
    # r1 = 1 (slot), r3 = 1 (slot done before the target), r2 = 0 (no filler)
    add('bra_near', 'mov #0, r0\nmov #0, r1\nmov #0, r2\nmov #0, r3\nbra 1f\nadd #1, r1\nadd #2, r0\n'
        '1: mov r1, r3\nadd #4, r0\nrts\nnop', own_rts=True)
    # bra at 8, target 8 + 4 + 4094 = 4106
    add('bra_fwd', 'mov #0, r0\nmov #0, r1\nmov #0, r2\nmov #0, r3\nbra 1f\nadd #1, r1\n'
        + FILL2 * ((4106 - 12) // 2) + '1: mov r1, r3\nadd #4, r0\nrts\nnop', own_rts=True)
    # target T = 12, bra at T + 4092 = 4104
    add('bra_back', 'mov #0, r0\nmov #0, r1\nmov #0, r2\nmov #0, r3\nbra 2f\nnop\n'
        '1: mov r1, r3\nadd #4, r0\nrts\nnop\n'
        + FILL2 * ((4104 - 4 - 20) // 2) + 'rts\nnop\n2: bra 1b\nadd #1, r1\nadd #2, r0\nrts\nnop',
        own_rts=True)
    # ---- BSR: r6 = L (MOVA) before the call; the subroutine records r1 in r0
    # (slot done before entry), PR in r2, returns with RTS whose slot adds 8;
    # at L: r2 -= L, r0 += 16. Expected r0 = 25, r1 = 1, r2 = 0.
    tail = '2: sub r6, r2\nadd #16, r0\nlds r3, pr\nrts\nnop\n'
    sub = '1: mov r1, r0\nsts pr, r2\nrts\nadd #8, r0\n'
    # bsr at 8: L = 12
    add('bsr_near', 'sts pr, r3\nmov #0, r1\nmova 2f, r0\nmov r0, r6\nbsr 1f\nadd #1, r1\n' + tail + sub,
        own_rts=True)
    # bsr at 8, sub at 8 + 4 + 4094 = 4106; tail ends at 22
    add('bsr_fwd', 'sts pr, r3\nmov #0, r1\nmova 2f, r0\nmov r0, r6\nbsr 1f\nadd #1, r1\n' + tail
        + FILL1 * ((4106 - 22) // 2) + sub, own_rts=True)
    # sub at 8, bsr at 8 + 4092 = 4100 (L = 4104)
    add('bsr_back', 'sts pr, r3\nmov #0, r1\nbra 3f\nnop\n' + sub
        + FILL1 * ((4092 - 16) // 2) + 'bra 1b\nnop\n'
        + '3: mova 2f, r0\nmov r0, r6\nbsr 1b\nadd #1, r1\n' + tail, own_rts=True)

    # ---- BRAF/BSRF/JMP/JSR/RTS: 6-byte target blocks <first>; BRA 3f;
    # MOV #marker, R0 at L + 6k (marker k) and, for BRAF/BSRF, at L - 14 - 6j
    # (marker -2 - j); L = address after the delay slot, 4-aligned.
    def blocks(first, neg):
        if neg:
            return ''.join(f'{first}\nbra 3f\nmov #{-2 - j}, r0\n' for j in reversed(range(BLOCKS_NEG)))
        return ''.join(f'{first}\nbra 3f\nmov #{k}, r0\n' for k in range(BLOCKS_POS))

    # BRAF/BSRF r5 (r5 = b): 0..10 entry, 12..35 negative blocks, 36 MOVA L,
    # 38, 40 branch (B), 42 slot, 44 L
    def far_table(name, insn, first, slot, pr):
        body = ('sts pr, r3\n' if pr else 'nop\n') + 'mov #0, r1\nmov #0, r2\nbra 4f\nnop\nnop\n'
        body += blocks(first, True)
        body += '4: mova 2f, r0\nmov r0, r6\n'
        body += f'{insn} r5\n{slot}\n'
        body += '2:\n' + blocks(first, False)
        body += ('3: sub r6, r2\nlds r3, pr\n' if pr else '3:\n') + 'rts\nnop'
        add(name, body, own_rts=True)

    far_table('braf', 'braf', 'mov r1, r2', 'add #1, r1', False)
    far_table('braf_rslot', 'braf', 'mov r1, r2', 'add #8, r5', False)   # slot changes Rn
    far_table('bsrf', 'bsrf', 'sts pr, r2', 'add #1, r1', True)

    # JMP/JSR @r0 with r0 = L + b, RTS with PR = L + b
    def abs_table(name, pre, br, slot, first, pr_sub):
        body = 'sts pr, r3\nmov #0, r1\nmov #0, r2\n'
        body += 'mova 2f, r0\nmov r0, r6\nadd r5, r0\n' + pre + f'{br}\n{slot}\n'
        body += '.balign 4\n2:\n' + blocks(first, False)
        body += '3: ' + ('sub r6, r2\n' if pr_sub else '') + 'lds r3, pr\nrts\nnop'
        add(name, body, own_rts=True)

    abs_table('jmp', '', 'jmp @r0', 'add #1, r1', 'mov r1, r2', False)
    abs_table('jmp_rslot', '', 'jmp @r0', 'add #8, r0', 'mov r1, r2', False)   # slot changes Rn
    abs_table('jsr', '', 'jsr @r0', 'add #1, r1', 'sts pr, r2', True)
    abs_table('rts', 'lds r0, pr\n', 'rts', 'add #1, r1', 'mov r1, r2', False)
