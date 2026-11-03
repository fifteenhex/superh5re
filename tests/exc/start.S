/*
 * Bare-metal entry and event vectors.  Runs with the MMU off from physical
 * 0x80000000 (QEMU -kernel, RTL testbench).  VBR = exc_vectors, RESVEC =
 * exc_resvec (Vol. 1 Table 151).  Every entry records the control registers
 * into exc_area (exc.h) and returns with RTE to SPC + 4, or to CTL_NEXT with
 * CTL_NEXT_SSR when the event is a TRAPA whose operand equals CTL_EXIT_TRA.
 * With CTL_NEST set the handler clears SR.BL and executes one TRAPA itself
 * before returning (nested launch); the inner launch overwrites SPC and SSR,
 * which the outer handler restores from its record.
 *
 * Register use in the handler: r0 is saved in DCR by the entry stub (the
 * save slot the architecture provides for this purpose, Vol. 1 15.2.9), r1
 * and tr0 go to the control block, r2 and r3 to the record.  Everything is
 * restored before RTE.
 */
#include "exc.h"

	.macro	STUB id
	putcon	r0, dcr
	movi	datalabel exc_area, r0
	st.q	r0, CTL_SAVE_R1, r1
	gettr	tr0, r1
	st.q	r0, CTL_SAVE_TR0, r1
	movi	\id, r1
	st.q	r0, CTL_VEC, r1
	pta	exc_common, tr0
	blink	tr0, r63
	.endm

	.section .vectors, "ax"
	.globl	exc_vectors
exc_vectors:
	.org	0x100
	STUB	VEC_EXC
	.org	0x400
	STUB	VEC_TLB
	.org	0x600
	STUB	VEC_INT
	.org	0x800
	.globl	exc_resvec
exc_resvec:
	STUB	VEC_PANIC
	.org	0x900
	STUB	VEC_DEBUG
	.org	0xa00

exc_common:
	/* r2 = &exc_area.rec[count % EXC_NREC] */
	ld.q	r0, CTL_COUNT, r1
	andi	r1, EXC_NREC - 1, r1
	shlli	r1, REC_SHIFT, r1
	addi	r1, REC_BASE, r1
	add	r0, r1, r1
	st.q	r1, REC_R2, r2
	st.q	r1, REC_R3, r3
	or	r1, r63, r2
	ld.q	r0, CTL_SAVE_R1, r1
	st.q	r2, REC_R1, r1
	ld.q	r0, CTL_SAVE_TR0, r1
	st.q	r2, REC_TR0, r1
	ld.q	r0, CTL_VEC, r1
	st.q	r2, REC_VEC, r1
	getcon	dcr, r1
	st.q	r2, REC_R0, r1
	getcon	expevt, r1
	st.q	r2, REC_EXPEVT, r1
	getcon	intevt, r1
	st.q	r2, REC_INTEVT, r1
	getcon	tea, r1
	st.q	r2, REC_TEA, r1
	getcon	tra, r1
	st.q	r2, REC_TRA, r1
	getcon	spc, r1
	st.q	r2, REC_SPC, r1
	getcon	ssr, r1
	st.q	r2, REC_SSR, r1
	getcon	sr, r1
	st.q	r2, REC_SR, r1
	getcon	pspc, r1
	st.q	r2, REC_PSPC, r1
	getcon	pssr, r1
	st.q	r2, REC_PSSR, r1
	getcon	pexpevt, r1
	st.q	r2, REC_PEXPEVT, r1

	/* default return: the instruction after the one that launched */
	ld.q	r2, REC_SPC, r3
	addi	r3, 4, r3
	st.q	r2, REC_RET_SPC, r3
	ld.q	r2, REC_SSR, r3
	st.q	r2, REC_RET_SSR, r3
	/* exit trap: TRAPA with TRA == CTL_EXIT_TRA returns to CTL_NEXT/CTL_NEXT_SSR */
	pta	1f, tr0
	ld.q	r2, REC_EXPEVT, r1
	movi	EVT_TRAP, r3
	bne	r1, r3, tr0
	ld.q	r2, REC_TRA, r1
	ld.q	r0, CTL_EXIT_TRA, r3
	bne	r1, r3, tr0
	ld.q	r0, CTL_NEXT, r1
	st.q	r2, REC_RET_SPC, r1
	ld.q	r0, CTL_NEXT_SSR, r1
	st.q	r2, REC_RET_SSR, r1
1:	ld.q	r0, CTL_COUNT, r1
	addi	r1, 1, r1
	st.q	r0, CTL_COUNT, r1

	/* nested launch on request: unblock and trap from inside the handler */
	pta	2f, tr0
	ld.q	r0, CTL_NEST, r1
	beq	r1, r63, tr0
	st.q	r0, CTL_NEST, r63
	getcon	sr, r1
	movi	1, r3
	shlli	r3, 28, r3
	andc	r1, r3, r1
	putcon	r1, sr
	ld.q	r0, CTL_NEST_TRA, r3
	.globl	exc_nest_trapa
exc_nest_trapa:
	trapa	r3

2:	ld.q	r2, REC_RET_SSR, r1
	putcon	r1, ssr
	ld.q	r2, REC_RET_SPC, r1
	putcon	r1, spc
	ld.q	r2, REC_TR0, r1
	ptabs	r1, tr0
	ld.q	r2, REC_R1, r1
	ld.q	r2, REC_R3, r3
	ld.q	r2, REC_R0, r0
	ld.q	r2, REC_R2, r2
	rte

	.section .text.start, "ax"
	.globl	_start
_start:
	getcon	sr, r0
	movi	1, r1
	shlli	r1, 15, r1
	andc	r0, r1, r0		/* SR.FD = 0 */
	movi	1, r1
	shlli	r1, 28, r1
	andc	r0, r1, r0		/* SR.BL = 0: exceptions are not panics */
	putcon	r0, ssr
	pta	1f, tr0
	gettr	tr0, r0
	putcon	r0, spc
	rte				/* RTE writes every SR field (Vol. 1 15.2.1) */
1:
	movi	datalabel exc_vectors, r0
	putcon	r0, vbr
	movi	datalabel exc_resvec, r0
	putcon	r0, resvec
	movi	0x8010, r15
	shori	0x0000, r15		/* stack top 0x80100000 */
	add.l	r15, r63, r15
	movi	main, r0
	ori	r0, 1, r0
	ptabs	r0, tr0
	blink	tr0, r18
1:	pta/l	1b, tr0
	blink	tr0, r63
