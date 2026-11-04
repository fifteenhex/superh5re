"""SHcompact routines of the mem group: loads, stores, GBR/PR/MAC memory
forms, read-modify-write, cache hints (convention in gen_cops.py: a, b, c, d
in R4-R7; results R0, R1 (T), R2, R3)."""

# disp operands: (byte, word, long)
DISP_R = {'b': [0, 1, 5, 15], 'w': [0, 2, 14, 30], 'l': [0, 4, 28, 60]}
DISP_G = {'b': [0, 1, 0x7f, 0xff], 'w': [0, 2, 0xfe, 0x1fe], 'l': [0, 4, 0x1fc, 0x3fc]}
RMW_IMM = [0x00, 0x01, 0x5a, 0x80, 0xff]
# PC-relative literals: (prefix nops, filler entries before the literal, value)
PCREL_L = [(0, 0, 0x89abcdef), (1, 0, 0x12345678), (0, 254, 0xfedcba98), (1, 253, 0x7f00ff01)]
PCREL_W = [(0, 0, 0x8001), (1, 0, 0x7ffe), (0, 253, 0xff80), (1, 254, 0x1234)]
MOVA = [(0, 0), (1, 0), (0, 254), (1, 253)]


def define(add):
    for s in 'bwl':
        add(f'ld{s}_r', f'mov.{s} @r4, r0')
        add(f'ld{s}_p', f'mov.{s} @r4+, r0\nmov r4, r2')
        add(f'ld{s}_pn', f'mov.{s} @r4+, r4\nmov r4, r0')
        add(f'ld{s}_x', f'mov r5, r0\nmov.{s} @(r0, r4), r0')
        for d in DISP_R[s]:
            add(f'ld{s}_d{d}', f'mov.{s} @({d}, r4), r0')
        for d in DISP_G[s]:
            add(f'ld{s}_g{d}', f'ldc r4, gbr\nmov.{s} @({d}, gbr), r0')
        add(f'st{s}_r', f'mov.{s} r5, @r4')
        add(f'st{s}_m', f'mov.{s} r5, @-r4\nmov r4, r2')
        add(f'st{s}_mn', f'mov.{s} r4, @-r4\nmov r4, r2')
        add(f'st{s}_x', f'mov r6, r0\nmov.{s} r5, @(r0, r4)')
        for d in DISP_R[s]:
            if s == 'l':
                add(f'stl_d{d}', f'mov.l r5, @({d}, r4)')
            else:
                add(f'st{s}_d{d}', f'mov r5, r0\nmov.{s} r0, @({d}, r4)')
        for d in DISP_G[s]:
            add(f'st{s}_g{d}', f'ldc r4, gbr\nmov r5, r0\nmov.{s} r0, @({d}, gbr)')

    # PC-relative loads and MOVA: literal inside the routine, after RTS
    def fill(n, size):
        d = '.long' if size == 4 else '.word'
        return ''.join(f'{d} 0x{(0x5a5a0000 + i) & (0xffffffff if size == 4 else 0xffff):x}\n' for i in range(n))
    for k, (nops, n, v) in enumerate(PCREL_L):
        add(f'ldl_pc{k}', 'nop\n' * nops + 'mov.l 1f, r0\nrts\nnop\n.balign 4\n' + fill(n, 4)
            + f'1: .long 0x{v:08x}', own_rts=True)
    for k, (nops, n, v) in enumerate(PCREL_W):
        add(f'ldw_pc{k}', 'nop\n' * nops + 'mov.w 1f, r0\nrts\nnop\n' + fill(n, 2)
            + f'1: .word 0x{v:04x}', own_rts=True)
    for k, (nops, n) in enumerate(MOVA):
        add(f'mova{k}', 'nop\n' * nops + 'mova 1f, r0\nmov.l @r0, r1\nrts\nnop\n.balign 4\n' + fill(n, 4)
            + f'.globl cop_mova_lit{k}\ncop_mova_lit{k}:\n1: .long 0x{0xa5000000 + k:08x}', own_rts=True)

    add('movca', 'mov r5, r0\nmovca.l r0, @r4')
    # GBR, PR, MACH, MACL: register and memory forms. PR is saved in R3.
    add('ldc_gbr', 'ldc r4, gbr\nstc gbr, r0')
    add('ldcl_gbr', 'ldc.l @r4+, gbr\nstc gbr, r0\nmov r4, r2')
    add('stcl_gbr', 'ldc r5, gbr\nstc.l gbr, @-r4\nmov r4, r2')
    add('ldsl_pr', 'sts pr, r3\nlds.l @r4+, pr\nsts pr, r0\nmov r4, r2\nlds r3, pr')
    add('stsl_pr', 'sts pr, r3\nlds r5, pr\nsts.l pr, @-r4\nmov r4, r2\nlds r3, pr')
    for m in ['mach', 'macl']:
        add(f'ldsl_{m}', f'lds.l @r4+, {m}\nsts {m}, r0\nmov r4, r2')
        add(f'stsl_{m}', f'lds r5, {m}\nsts.l {m}, @-r4\nmov r4, r2')
    # #imm, @(R0, GBR): GBR = a, R0 = b
    for i in ['and', 'or', 'xor', 'tst']:
        for imm in RMW_IMM:
            add(f'{i}b_{imm:02x}', f'ldc r4, gbr\nmov r5, r0\n{i}.b #{imm}, @(r0, gbr)\nmovt r1')
    add('tas', 'tas.b @r4\nmovt r1')
    # cache hints: a = any byte address in the block, b = aligned word in it, c = value
    add('pref', 'pref @r4\nmov.l @r5, r0')
    add('ocbp', 'mov.l r6, @r5\nocbp @r4\nmov.l @r5, r0')
    add('ocbwb', 'mov.l r6, @r5\nocbwb @r4\nmov.l @r5, r0')
    add('ocbi', 'mov.l r6, @r5\nocbwb @r4\nocbi @r4\nmov.l @r5, r0')
