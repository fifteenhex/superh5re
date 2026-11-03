/*
 * SH-5 exception test: layout of the record area shared by the vector code
 * (start.S) and the tests (exc.c).  All fields are 64-bit.
 */
#ifndef EXC_H
#define EXC_H

/* Vector identifiers written by the entry stubs (Vol. 1 Table 151). */
#define VEC_EXC		1	/* VBR + 0x100: non-debug exception */
#define VEC_TLB		2	/* VBR + 0x400: TLB miss */
#define VEC_INT		3	/* VBR + 0x600: interrupt */
#define VEC_PANIC	4	/* RESVEC + 0x000: CPU reset, panic */
#define VEC_DEBUG	5	/* RESVEC + 0x100: debug exception */

/* struct exc_ctl: handler control block at the start of exc_area */
#define CTL_NEXT	0x00	/* SPC to return to when the exit trap is taken */
#define CTL_NEXT_SSR	0x08	/* SSR to return with on the exit trap */
#define CTL_EXIT_TRA	0x10	/* TRA value of the exit trap; >= 2^32 disables */
#define CTL_NEST	0x18	/* nonzero: the handler raises one nested TRAPA */
#define CTL_NEST_TRA	0x20	/* operand of the nested TRAPA */
#define CTL_COUNT	0x28	/* number of launches so far */
#define CTL_SAVE_R1	0x30	/* entry stub temporaries */
#define CTL_SAVE_TR0	0x38
#define CTL_VEC		0x40
#define CTL_SIZE	0x80

/* struct exc_rec: one per launch, EXC_NREC entries after the control block */
#define REC_BASE	CTL_SIZE
#define REC_SHIFT	8	/* sizeof(struct exc_rec) == 0x100 */
#define EXC_NREC	8
#define REC_VEC		0x00
#define REC_EXPEVT	0x08
#define REC_INTEVT	0x10
#define REC_TEA		0x18
#define REC_TRA		0x20
#define REC_SPC		0x28
#define REC_SSR		0x30
#define REC_SR		0x38
#define REC_PSPC	0x40
#define REC_PSSR	0x48
#define REC_PEXPEVT	0x50
#define REC_R0		0x58
#define REC_R1		0x60
#define REC_R2		0x68
#define REC_R3		0x70
#define REC_TR0		0x78
#define REC_RET_SPC	0x80	/* SPC/SSR the handler returns with */
#define REC_RET_SSR	0x88

/* SR fields (Vol. 1 Figure 54) */
#define SR_S		(1u << 1)
#define SR_IMASK	(0xfu << 4)
#define SR_Q		(1u << 8)
#define SR_M		(1u << 9)
#define SR_CD		(1u << 11)
#define SR_PR		(1u << 12)
#define SR_SZ		(1u << 13)
#define SR_FR		(1u << 14)
#define SR_FD		(1u << 15)
#define SR_ASID		(0xffu << 16)
#define SR_WATCH	(1u << 26)
#define SR_STEP		(1u << 27)
#define SR_BL		(1u << 28)
#define SR_MD		(1u << 30)
#define SR_MMU		(1u << 31)

/* Event codes (Vol. 1 Table 157) */
#define EVT_RADDERR	0x0e0
#define EVT_WADDERR	0x100
#define EVT_FPUEXC	0x120
#define EVT_TRAP	0x160
#define EVT_RESINST	0x180
#define EVT_FPUDIS	0x800
#define EVT_BREAK	0x940
#define EVT_IADDERR	0xae0

#ifndef __ASSEMBLER__
typedef unsigned long long u64;
typedef long long s64;
typedef unsigned int u32;
typedef int s32;
typedef unsigned short u16;
typedef unsigned char u8;

struct exc_ctl {
	u64 next, next_ssr, exit_tra, nest, nest_tra, count;
	u64 save_r1, save_tr0, vec;
	u64 pad[7];
};

struct exc_rec {
	u64 vec, expevt, intevt, tea, tra, spc, ssr, sr, pspc, pssr, pexpevt;
	u64 r0, r1, r2, r3, tr0;
	u64 ret_spc, ret_ssr;
	u64 pad[14];
};

struct exc_area {
	struct exc_ctl ctl;
	struct exc_rec rec[EXC_NREC];
};

extern struct exc_area exc_area;
extern char exc_nest_trapa[];	/* the nested TRAPA inside the handler */

/* Console (console.c): Cayman SCIF, polled. */
void exc_puts(const char *s);
void exc_puthex(u64 v);
void exc_putdec(u64 v);
#endif

#endif /* EXC_H */
