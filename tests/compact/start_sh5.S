/* SHmedia entry: MMU off, physical 0x80000000, FPU on, VBR at exc_vectors.
 * Exceptions are counted (cop_exc_count/cop_exc_last) and skipped: RTE to
 * SPC + 2 for an SHcompact instruction, SPC + 4 for SHmedia. */

	.section .vectors, "ax"
	.globl exc_vectors
exc_vectors:
	.org 0x100
	pta/l exc_common, tr0
	blink tr0, r63
	.org 0x400
	pta/l exc_common, tr0
	blink tr0, r63
	.org 0x600
	pta/l exc_common, tr0
	blink tr0, r63

	.section .text.start, "ax"
	.globl _start
_start:
	getcon	sr, r0
	movi	1, r1
	shlli	r1, 15, r1		/* SR.FD */
	andc	r0, r1, r0
	movi	1, r1
	shlli	r1, 28, r1		/* SR.BL: set at reset; an exception with it set is a panic to RESVEC */
	andc	r0, r1, r0
	putcon	r0, sr
	movi	datalabel exc_vectors, r0
	putcon	r0, vbr
	movi	0x8010, r15
	shori	0x0000, r15		/* stack top 0x80100000 */
	add.l	r15, r63, r15
	movi	main, r0
	ori	r0, 1, r0
	ptabs	r0, tr0
	blink	tr0, r18
1:	pta/l	1b, tr0
	blink	tr0, r63

exc_common:
	movi	datalabel cop_exc_count, r20
	ld.q	r20, 0, r21
	addi	r21, 1, r21
	st.q	r20, 0, r21
	getcon	expevt, r21
	movi	datalabel cop_exc_last, r20
	st.q	r20, 0, r21
	getcon	spc, r21
	andi	r21, 1, r22
	addi	r21, 4, r23
	addi	r21, 2, r21
	cmvne	r22, r23, r21		/* ISA bit set: SHmedia, +4; clear: SHcompact, +2 (CMVNE: Rd = Rn when Rm != 0) */
	putcon	r21, spc
	rte
	nop

/*
 * void cop_call(const void *fn, const u64 in[4], struct cres *res)
 *   r2 = routine (ISA bit clear: SHcompact), r3 = in, r4 = res.
 * Passes in[0..3] in R4-R7, calls the routine with BLINK so that it returns
 * through PR = R18 (ISA bit set) into SHmedia, stores R0-R3 into res.
 */
	.text
	.globl cop_call
cop_call:
	addi	r15, -16, r15
	st.q	r15, 0, r18
	st.q	r15, 8, r4
	ptabs	r2, tr4
	ld.q	r3, 24, r7
	ld.q	r3, 16, r6
	ld.q	r3, 8, r5
	ld.q	r3, 0, r4
	blink	tr4, r18
	ld.q	r15, 8, r7
	st.q	r7, 0, r0
	st.q	r7, 8, r1
	st.q	r7, 16, r2
	st.q	r7, 24, r3
	ld.q	r15, 0, r18
	addi	r15, 16, r15
	ptabs	r18, tr0
	blink	tr0, r63
