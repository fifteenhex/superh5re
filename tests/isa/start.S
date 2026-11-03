/* Bare-metal entry: MMU off, physical 0x80000000 (QEMU -kernel), FPU on. */
	.section .text.start, "ax"
	.globl _start
_start:
	getcon	sr, r0
	movi	1, r1
	shlli	r1, 15, r1		/* SR.FD */
	andc	r0, r1, r0
	putcon	r0, sr
	movi	0x8010, r15
	shori	0x0000, r15		/* stack top 0x80100000 */
	add.l	r15, r63, r15
	movi	main, r0
	ori	r0, 1, r0
	ptabs	r0, tr0
	blink	tr0, r18
1:	pta/l	1b, tr0
	blink	tr0, r63
