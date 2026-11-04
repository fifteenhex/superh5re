"""SHcompact routines of the fpu group (gen_cops.py convention: a, b, c, d in
R4-R7; results in R0-R3). Every routine saves FPSCR on the stack, loads the
FPSCR of the test (SHcompact view: PR 19, SZ 20, FR 21), runs the
instruction and returns FPSCR in R1; caller's FPSCR restored before RTS.
Single operands go through FPUL (LDS/FSTS, FLDS/STS). FR12-FR15 of the
front bank are not used: callee-saved in the gcc ABI, where the SH-4 build
keeps integer values."""

SAVE = 'sts.l fpscr, @-r15'
REST = 'lds.l @r15+, fpscr'


def to_fr(reg, fr):
    return f'lds {reg}, fpul\nfsts fpul, fr{fr}'


def from_fr(fr, reg):
    return f'flds fr{fr}, fpul\nsts fpul, {reg}'


def define(add):
    def r(name, body):
        add(name, f'{SAVE}\n{body}\n{REST}')

    # ---- single precision: a = FRn (fr2), b = FRm (fr3), c = FPSCR
    for i in ['fadd', 'fsub', 'fmul', 'fdiv']:
        r(i + '_s', f'lds r6, fpscr\n{to_fr("r4", 2)}\n{to_fr("r5", 3)}\n{i} fr3, fr2\n'
                    f'sts fpscr, r1\n{from_fr(2, "r0")}')
    # different register numbers: FRn = fr11, FRm = fr8
    r('fadd_s2', f'lds r6, fpscr\n{to_fr("r4", 11)}\n{to_fr("r5", 8)}\nfadd fr8, fr11\n'
                 f'sts fpscr, r1\n{from_fr(11, "r0")}')
    # FCMP: R0 = T(eq), R2 = FPSCR after EQ, R3 = T(gt), R1 = FPSCR after GT
    r('fcmp_s', f'lds r6, fpscr\n{to_fr("r4", 2)}\n{to_fr("r5", 3)}\nfcmp/eq fr3, fr2\nmovt r0\n'
                f'sts fpscr, r2\nlds r6, fpscr\nfcmp/gt fr3, fr2\nmovt r3\nsts fpscr, r1')
    for i in ['fsqrt', 'fabs', 'fneg', 'fsrra']:
        r(i + '_s', f'lds r6, fpscr\n{to_fr("r4", 5)}\n{i} fr5\nsts fpscr, r1\n{from_fr(5, "r0")}')
    r('ftrc_s', f'lds r6, fpscr\n{to_fr("r4", 9)}\nftrc fr9, fpul\nsts fpscr, r1\nsts fpul, r0')
    r('float_s', f'lds r6, fpscr\nlds r4, fpul\nfloat fpul, fr9\nsts fpscr, r1\n{from_fr(9, "r0")}')
    # FMAC FR0, FRm, FRn: a = FR0, b = FRm (fr3), c = FRn (fr2), d = FPSCR
    r('fmac_s', f'lds r7, fpscr\n{to_fr("r4", 0)}\n{to_fr("r5", 3)}\n{to_fr("r6", 2)}\n'
                f'fmac fr0, fr3, fr2\nsts fpscr, r1\n{from_fr(2, "r0")}')
    # FLDI0/FLDI1 over a = FRn; FLDS/FSTS round trip
    for i in ['fldi0', 'fldi1']:
        r(i, f'lds r6, fpscr\n{to_fr("r4", 11)}\n{i} fr11\nsts fpscr, r1\n{from_fr(11, "r0")}')
    r('flds_fsts', f'lds r6, fpscr\n{to_fr("r4", 9)}\nlds r5, fpul\nflds fr9, fpul\nsts fpul, r0\nsts fpscr, r1')
    # FSCA FPUL, DR6: R0 = FR6 (sin), R2 = FR7 (cos)
    r('fsca', f'lds r6, fpscr\nlds r4, fpul\nfsca fpul, dr6\nsts fpscr, r1\n{from_fr(6, "r0")}\n{from_fr(7, "r2")}')
    # FIPR: a = pointer to FVm (FV0) then FVn (FV4), b = FPSCR; R0 = FR7
    r('fipr', 'mov #0, r0\nlds r0, fpscr\n' + '\n'.join(f'fmov.s @r4+, fr{i}' for i in range(8)) +
      f'\nlds r5, fpscr\nfipr fv0, fv4\nsts fpscr, r1\n{from_fr(7, "r0")}\n{from_fr(4, "r2")}')
    # FIPR FV8, FV0: FVm = FV8, FVn = FV0; R0 = FR3
    r('fipr2', 'mov #0, r0\nlds r0, fpscr\n' + '\n'.join(f'fmov.s @r4+, fr{i}' for i in list(range(8, 12)) + list(range(0, 4))) +
      f'\nlds r5, fpscr\nfipr fv8, fv0\nsts fpscr, r1\n{from_fr(3, "r0")}\n{from_fr(0, "r2")}')
    # FTRV XMTRX, FV4: a = pointer to XF0..XF15 then FV4, b = result buffer, c = FPSCR
    r('ftrv', 'mov #0, r0\nlds r0, fpscr\nfrchg\n' + '\n'.join(f'fmov.s @r4+, fr{i}' for i in range(16)) +
      '\nfrchg\n' + '\n'.join(f'fmov.s @r4+, fr{i}' for i in range(4, 8)) +
      '\nlds r6, fpscr\nftrv xmtrx, fv4\nsts fpscr, r1\nadd #16, r5\n' +
      '\n'.join(f'fmov.s fr{i}, @-r5' for i in range(7, 3, -1)))

    # ---- double precision: a = pointer to {fps, DRn hi, lo, DRm hi, lo};
    # DRn = DR2 (fr2/fr3), DRm = DR4 (fr4/fr5); R0/R2 = FR2/FR3, R3 = T
    dload = ('mov.l @r4+, r0\nlds r0, fpscr\n' +
             '\n'.join(f'mov.l @r4+, r0\n{to_fr("r0", i)}' for i in (2, 3, 4, 5)))
    dres = f'sts fpscr, r1\n{from_fr(2, "r0")}\n{from_fr(3, "r2")}'
    for i in ['fadd', 'fsub', 'fmul', 'fdiv']:
        r(i + '_d', f'{dload}\n{i} dr4, dr2\n{dres}')
    r('fcmp_d', f'{dload}\nfcmp/eq dr4, dr2\nmovt r0\nsts fpscr, r2\nadd #-20, r4\nmov.l @r4, r1\nlds r1, fpscr\n'
                f'fcmp/gt dr4, dr2\nmovt r3\nsts fpscr, r1')
    for i in ['fsqrt', 'fabs', 'fneg']:
        r(i + '_d', f'{dload}\n{i} dr2\n{dres}')
    r('fcnvds_d', f'{dload}\nfcnvds dr4, fpul\nsts fpscr, r1\nsts fpul, r0')
    r('ftrc_d', f'{dload}\nftrc dr4, fpul\nsts fpscr, r1\nsts fpul, r0')
    r('fcnvsd_d', f'{dload}\nflds fr4, fpul\nfcnvsd fpul, dr2\n{dres}')
    r('float_d', f'{dload}\nflds fr4, fpul\nfloat fpul, dr2\n{dres}')

    # ---- FMOV register forms. c = FPSCR.
    r('fmov_s', f'lds r6, fpscr\n{to_fr("r4", 3)}\nfmov fr3, fr10\nsts fpscr, r1\n{from_fr(10, "r0")}')
    # SZ = 1: a, b = DR2 (fr2, fr3); d = marker in front fr10, fr11
    pair_in = f'{to_fr("r4", 2)}\n{to_fr("r5", 3)}'
    mark = f'{to_fr("r7", 10)}\n{to_fr("r7", 11)}'
    pair_out = f'{from_fr(10, "r0")}\n{from_fr(11, "r2")}'
    r('fmov_dd', f'lds r6, fpscr\n{pair_in}\nfmov dr2, dr10\nsts fpscr, r1\n{pair_out}')
    # DRm -> XDn: R3 = front fr10 (unchanged), R0/R2 = back fr10/fr11, R1 = FPSCR after FRCHG
    r('fmov_dx', f'lds r6, fpscr\n{mark}\n{pair_in}\nfmov dr2, xd10\n{from_fr(10, "r3")}\nfrchg\n'
                 f'sts fpscr, r1\n{pair_out}')
    r('fmov_xd', f'lds r6, fpscr\n{mark}\nfrchg\n{pair_in}\nfrchg\nfmov xd2, dr10\nsts fpscr, r1\n{pair_out}')
    r('fmov_xx', f'lds r6, fpscr\n{mark}\nfrchg\n{pair_in}\nfrchg\nfmov xd2, xd10\nsts fpscr, r1\n'
                 f'{from_fr(10, "r3")}\nfrchg\n{pair_out}')
    # FRCHG, FSCHG: R0 = FPSCR after FRCHG, R2 = after FSCHG
    r('frchg_fschg', 'lds r4, fpscr\nfrchg\nsts fpscr, r0\nfschg\nsts fpscr, r2\nsts fpscr, r1')

    # ---- FMOV memory forms, SZ = 0. a = address, b = index (R0) or value, c = FPSCR
    r('fmovs_ld', f'lds r6, fpscr\nfmov.s @r4, fr5\nsts fpscr, r1\n{from_fr(5, "r0")}')
    r('fmovs_ldp', f'lds r6, fpscr\nfmov.s @r4+, fr5\nsts fpscr, r1\n{from_fr(5, "r0")}\nmov r4, r2')
    r('fmovs_ldx', f'lds r6, fpscr\nmov r5, r0\nfmov.s @(r0, r4), fr5\nsts fpscr, r1\n{from_fr(5, "r0")}')
    r('fmovs_st', f'lds r6, fpscr\n{to_fr("r5", 5)}\nfmov.s fr5, @r4\nsts fpscr, r1')
    r('fmovs_stm', f'lds r6, fpscr\n{to_fr("r5", 5)}\nfmov.s fr5, @-r4\nsts fpscr, r1\nmov r4, r2')
    # @(R0, Rn): d = index
    r('fmovs_stx', f'lds r6, fpscr\n{to_fr("r5", 5)}\nmov r7, r0\nfmov.s fr5, @(r0, r4)\nsts fpscr, r1')
    # ---- SZ = 1, DR and XD. Loads: a = address, b = index; R0/R2 = pair, R3 = Rm after
    for k, reg in (('d', 'dr6'), ('x', 'xd6')):
        sw = 'frchg\n' if k == 'x' else ''
        out = f'{sw}{from_fr(6, "r0")}\n{from_fr(7, "r2")}\n{sw}'
        r(f'fmov{k}_ld', f'lds r6, fpscr\nfmov @r4, {reg}\nsts fpscr, r1\n{out}')
        r(f'fmov{k}_ldp', f'lds r6, fpscr\nfmov @r4+, {reg}\nsts fpscr, r1\n{out}mov r4, r3')
        r(f'fmov{k}_ldx', f'lds r6, fpscr\nmov r5, r0\nfmov @(r0, r4), {reg}\nsts fpscr, r1\n{out}')
        # stores: a = address, b = FR6 value, d = FR7 value, c = FPSCR
        inp = f'{sw}{to_fr("r5", 6)}\n{to_fr("r7", 7)}\n{sw}'
        r(f'fmov{k}_st', f'lds r6, fpscr\n{inp}fmov {reg}, @r4\nsts fpscr, r1')
        r(f'fmov{k}_stm', f'lds r6, fpscr\n{inp}fmov {reg}, @-r4\nsts fpscr, r1\nmov r4, r2')
        # @(R0, Rn): a = base, b = index, d = pointer to the two values
        inp = f'{sw}mov.l @r7+, r0\n{to_fr("r0", 6)}\nmov.l @r7, r0\n{to_fr("r0", 7)}\n{sw}'
        r(f'fmov{k}_stx', f'lds r6, fpscr\n{inp}mov r5, r0\nfmov {reg}, @(r0, r4)\nsts fpscr, r1')

    # ---- FPSCR / FPUL special registers
    r('lds_sts_fpscr', 'lds r4, fpscr\nsts fpscr, r0\nsts fpscr, r1')
    r('ldsl_fpscr', 'lds.l @r4+, fpscr\nsts fpscr, r0\nmov r4, r2\nsts fpscr, r1')
    r('stsl_fpscr', 'lds r5, fpscr\nsts.l fpscr, @-r4\nmov r4, r2\nsts fpscr, r1')
    r('lds_sts_fpul', 'lds r6, fpscr\nlds r4, fpul\nsts fpul, r0\nsts fpscr, r1')
    r('ldsl_fpul', 'lds r6, fpscr\nlds.l @r4+, fpul\nsts fpul, r0\nmov r4, r2\nsts fpscr, r1')
    r('stsl_fpul', 'lds r6, fpscr\nlds r5, fpul\nsts.l fpul, @-r4\nmov r4, r2\nsts fpscr, r1')
