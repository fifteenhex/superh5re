"""SHcompact routines of the arith group (see gen_cops.py for the
convention: a, b, c, d in R4-R7; results R0 (destination), R1 (T), R2, R3)."""


def define(add):
    # ---- integer: Rm,Rn forms (Rn = a in r4, Rm = b in r5)
    def rn_rm(insn, t_in=False):
        pre = 'shlr r7\n' if t_in else ''
        return pre + f'{insn} r5, r4\nmov r4, r0\nmovt r1\nmov r5, r2'

    for i in ['add', 'addv', 'sub', 'subv', 'and', 'or', 'xor', 'tst', 'cmp/eq', 'cmp/hs', 'cmp/ge',
              'cmp/hi', 'cmp/gt', 'cmp/str', 'xtrct', 'shad', 'shld', 'mul.l', 'muls.w', 'mulu.w',
              'dmuls.l', 'dmulu.l']:
        name = i.replace('/', '_').replace('.', '_')
        body = rn_rm(i)
        if i.startswith('mul') or i.startswith('dmul'):
            body += '\nsts macl, r0\nsts mach, r2'
        add(name, body)
    for i in ['addc', 'subc']:
        add(i, rn_rm(i, t_in=True))
    # Rm,Rn with Rn written from Rm (neg, not, exts, extu, swap, mov, negc)
    for i in ['neg', 'not', 'exts.b', 'exts.w', 'extu.b', 'extu.w', 'swap.b', 'swap.w', 'mov']:
        add(i.replace('.', '_'), f'{i} r5, r4\nmov r4, r0\nmovt r1\nmov r5, r2')
    add('negc', 'shlr r7\nnegc r5, r4\nmov r4, r0\nmovt r1')
    # Rn only
    for i in ['dt', 'shal', 'shar', 'shll', 'shlr', 'rotl', 'rotr', 'shll2', 'shll8', 'shll16',
              'shlr2', 'shlr8', 'shlr16', 'cmp/pl', 'cmp/pz']:
        add(i.replace('/', '_'), f'{i} r4\nmov r4, r0\nmovt r1')
    for i in ['rotcl', 'rotcr']:
        add(i, f'shlr r7\n{i} r4\nmov r4, r0\nmovt r1')
    # #imm,R0 forms (R0 = a)
    for i in ['and', 'or', 'xor', 'tst', 'cmp/eq']:
        for imm in [0, 1, 0x7f, 0x80, 0xff, 0x55]:
            add(f"{i.replace('/', '_')}_i{imm:02x}", f'mov r4, r0\n{i} #{imm}, r0\nmovt r1')
    for imm in [0, 1, -1, 127, -128, 0x55]:
        add(f'add_i{imm & 0xff:02x}', f'mov r4, r0\nadd #{imm}, r0\nmovt r1')
        add(f'mov_i{imm & 0xff:02x}', f'mov #{imm}, r0\nmovt r1')
    add('movt', 'shlr r7\nmovt r0\nmovt r1')
    add('clrt', 'shlr r7\nclrt\nmovt r1\nmov #0, r0')
    add('sett', 'shlr r7\nsett\nmovt r1\nmov #0, r0')
    # divide steps: Q/M from DIV0S or DIV0U, then k DIV1 steps on Rn = a, Rm = b
    for k in [1, 2, 3, 32]:
        add(f'div1s_{k}', 'div0s r5, r4\nmovt r3\n' + 'div1 r5, r4\n' * k + 'mov r4, r0\nmovt r1')
        add(f'div1u_{k}', 'div0u\n' + 'div1 r5, r4\n' * k + 'mov r4, r0\nmovt r1')
    # unsigned 32/32 division sequence (SH-4 programming manual): a / b
    add('divu32', 'mov #0, r2\ndiv0u\n' + 'rotcl r4\ndiv1 r5, r2\n' * 32 + 'rotcl r4\nmov r4, r0\nmov r2, r2\nmovt r1')
    # multiply-accumulate: a = pointer to m, b = pointer to n, c = MACL, d = MACH
    for i in ['mac.l', 'mac.w']:
        n = i.replace('.', '_')
        add(n, f'lds r6, macl\nlds r7, mach\nclrs\n{i} @r5+, @r4+\nsts macl, r0\nsts mach, r2\nmov r4, r1\nmov r5, r3')
        add(n + '_s', f'lds r6, macl\nlds r7, mach\nsets\n{i} @r5+, @r4+\nsts macl, r0\nsts mach, r2\nmov r4, r1\nmov r5, r3\nclrs')
    add('clrmac', 'lds r4, macl\nlds r5, mach\nclrmac\nsts macl, r0\nsts mach, r2')
    add('lds_sts_mac', 'lds r4, macl\nlds r5, mach\nsts macl, r0\nsts mach, r2')
