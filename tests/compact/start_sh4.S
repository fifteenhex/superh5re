/* SH-4 entry (qemu-system-sh4 -M r2d -kernel): raw image at physical
 * 0x0c800000, started at 0xac800000. */
	.text
	.globl _start
_start:
	mov.l	.Lsp, r15
	mov.l	.Lmain, r0
	jsr	@r0
	nop
1:	bra	1b
	nop
	.balign 4
.Lsp:	.long	0xac900000
.Lmain:	.long	main

/*
 * void cop_call(const void *fn, const u64 in[4], struct cres *res)
 *   SH-5 ABI (also for SHcompact code): r2 = routine, r3 = in, r4 = res.
 *   Low words of in[] go to R4-R7, R0-R3 come back zero-extended in res.
 */
	.globl cop_call
cop_call:
	sts.l	pr, @-r15
	mov.l	r8, @-r15
	mov.l	r4, @-r15
	mov	r2, r8
	mov.l	@(24, r3), r7
	mov.l	@(16, r3), r6
	mov.l	@(8, r3), r5
	mov.l	@(0, r3), r4
	jsr	@r8
	nop
	mov.l	@r15+, r4
	mov.l	r0, @(0, r4)
	mov.l	r1, @(8, r4)
	mov.l	r2, @(16, r4)
	mov.l	r3, @(24, r4)
	mov	#0, r0
	mov.l	r0, @(4, r4)
	mov.l	r0, @(12, r4)
	mov.l	r0, @(20, r4)
	mov.l	r0, @(28, r4)
	mov.l	@r15+, r8
	lds.l	@r15+, pr
	rts
	nop
