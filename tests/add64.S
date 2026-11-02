	.text
	.globl _start
_start:
	movi	0x0fb9, r0
	shori	0x1b82, r0		/* r0 = 0x0fb91b82 */
	movi	0, r7
	shori	0xc28b, r7
	shori	0x0bca, r7		/* r7 = 0xc28b0bca */
	add	r0, r7, r1		/* expect 0x1d244274c */
	add.l	r0, r7, r2		/* expect 0xffffffffd244274c */
	addz.l	r0, r7, r3		/* expect 0x00000000d244274c */
	movi	1, r9
	shori	0xd244, r9
	shori	0x274c, r9		/* r9 = 0x1d244274c */
	mshflo.l r9, r63, r10		/* expect 0xd244274c */
	mshfhi.l r9, r63, r11		/* expect 1 */
	add	r10, r11, r12		/* expect 0xd244274d */
	trapa	r63
1:	pta/l	1b, tr0
	blink	tr0, r63
