/* Bare-metal entry for SHmedia tests on the QEMU Cayman board: runs with the
 * MMU off at physical 0x80000000; sets a stack and calls main(). */
	.section .text.start, "ax"
	.globl _start
_start:
	movi	0x8010, r15
	shori	0x0000, r15		/* stack top 0x80100000 */
	add.l	r15, r63, r15
	movi	main, r0
	ori	r0, 1, r0
	ptabs	r0, tr0
	blink	tr0, r18
1:	pta/l	1b, tr0
	blink	tr0, r63
