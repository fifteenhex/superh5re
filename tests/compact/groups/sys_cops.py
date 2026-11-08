"""SHcompact routines of the sys group: CLRS/SETS (through MAC.W), NOP,
LDS/STS FPSCR and FPUL (register forms; the .L forms are in the fpu
group), FRCHG, FSCHG. Routines that write FPSCR save it in R3
on entry and restore it before returning."""


def define(add):
    # MAC.W @R5+, @R4+ with MACL = c, MACH = d; S set by the pair (last one wins)
    add('sys_clrs_macw', 'lds r6, macl\nlds r7, mach\nsets\nclrs\nmac.w @r5+, @r4+\nsts macl, r0\nsts mach, r2')
    add('sys_sets_macw', 'lds r6, macl\nlds r7, mach\nclrs\nsets\nmac.w @r5+, @r4+\nsts macl, r0\nsts mach, r2\nclrs')
    add('sys_nop', 'shlr r7\nnop\nmov r4, r0\nnop\nmovt r1\nmov r5, r2\nnop\nmov r6, r3')
    add('sys_fpscr_get', 'sts fpscr, r0')
    # TRAPA and the return: the handler (start_sh5.S) counts the exception and
    # RTEs to SPC + 2. One TRAPA at 2 mod 4 and one at 0 mod 4: the return
    # must land on the instruction after the TRAPA in both cases (an RTE that
    # dropped bit 1 of SPC re-executed the instruction before a 2 mod 4 TRAPA).
    add('sys_trapa_half', 'mov #0, r0\n.balign 4\nadd #1, r0\ntrapa #0x20\nadd #16, r0')
    add('sys_trapa_word', 'mov #0, r0\n.balign 4\nnop\nadd #1, r0\ntrapa #0x20\nadd #16, r0')
    add('sys_lds_fpscr', 'sts fpscr, r3\nlds r4, fpscr\nsts fpscr, r0\nlds r3, fpscr')
    add('sys_lds_fpul', 'lds r4, fpul\nsts fpul, r0')
    # FPSCR = a, toggle once (r0) and twice (r1)
    for i in ['frchg', 'fschg']:
        add('sys_' + i, f'sts fpscr, r3\nlds r4, fpscr\n{i}\nsts fpscr, r0\n{i}\nsts fpscr, r1\nlds r3, fpscr')
