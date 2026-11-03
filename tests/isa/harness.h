/*
 * SH-5 SHmedia ISA test kit: common definitions.
 *
 * Each test executes an instruction through inline asm and compares the
 * result with a C reference written from the pseudocode in SH-5 CPU Core
 * Volume 2 (SHmedia).  The same sources build as a nolibc Linux program
 * (MODE=nolibc) and as a bare-metal image for the QEMU Cayman board or an
 * FPGA (MODE=bare).  Only the small output layer differs.
 */
#ifndef ISA_HARNESS_H
#define ISA_HARNESS_H

typedef unsigned long long u64;
typedef long long s64;
typedef unsigned int u32;
typedef int s32;
typedef unsigned short u16;
typedef short s16;
typedef unsigned char u8;
typedef signed char s8;

/* Output layer (harness.c / bare.c / nolibc.c). */
void isa_puts(const char *s);
void isa_puthex(u64 v);		/* 16 hex digits */
void isa_putdec(u64 v);
void isa_exit(int failures);	/* print DONE, then idle (bare) or exit */

/* Result accounting. */
extern unsigned isa_tests, isa_failures, isa_group_failures;
extern int isa_verbose;		/* also print PASS lines */

void isa_group_begin(const char *name);
void isa_group_end(void);

/*
 * Report one check.  @what names the instruction and operands, e.g.
 * "add.l a=0x... b=0x...".  Returns 1 on pass.
 */
int isa_check(const char *file, int line, const char *insn, u64 got, u64 want,
	      int nops, u64 a, u64 b, u64 c);

#define CHECK0(insn, got, want) \
	isa_check(__FILE__, __LINE__, insn, (got), (want), 0, 0, 0, 0)
#define CHECK1(insn, got, want, a) \
	isa_check(__FILE__, __LINE__, insn, (got), (want), 1, (a), 0, 0)
#define CHECK2(insn, got, want, a, b) \
	isa_check(__FILE__, __LINE__, insn, (got), (want), 2, (a), (b), 0)
#define CHECK3(insn, got, want, a, b, c) \
	isa_check(__FILE__, __LINE__, insn, (got), (want), 3, (a), (b), (c))

/*
 * Operand corpus: boundary values for 8/16/32/64-bit arithmetic plus
 * pseudo-random words.  Loop over it with ISA_FOREACH_OPERAND.
 */
extern const u64 isa_operands[];
extern const unsigned isa_num_operands;
#define ISA_FOREACH_OPERAND(v) \
	for (unsigned _i_##v = 0; _i_##v < isa_num_operands && (((v) = isa_operands[_i_##v]), 1); _i_##v++)

/* 64-bit xorshift for extra operands; never returns the same sequence twice. */
u64 isa_rand(void);
void isa_rand_seed(u64 seed);

/* Reference helpers from the manual's pseudocode. */
static inline s64 SignExtend8(u64 v)  { return (s64)(s8)v; }
static inline s64 SignExtend16(u64 v) { return (s64)(s16)v; }
static inline s64 SignExtend32(u64 v) { return (s64)(s32)v; }
static inline u64 ZeroExtend8(u64 v)  { return (u8)v; }
static inline u64 ZeroExtend16(u64 v) { return (u16)v; }
static inline u64 ZeroExtend32(u64 v) { return (u32)v; }

/*
 * Group registration: ISA_GROUP(name) { body } defines the group function
 * and puts it in the "isa_groups" table; main() runs every entry.
 */
struct isa_group {
	const char *name;
	void (*run)(void);
};

#define ISA_GROUP(gname)						\
	static void isa_group_fn_##gname(void);				\
	static const struct isa_group isa_group_desc_##gname		\
	__attribute__((section("isa_groups"), used, aligned(8))) =	\
		{ #gname, isa_group_fn_##gname };			\
	static void isa_group_fn_##gname(void)

/*
 * Inline asm shorthands.  Operands are 64-bit registers; "r" never gives
 * r63.  Instructions with immediates need the literal in the string.
 */
#define ASM_RRR(insn, a, b) ({						\
	u64 _r, _a = (a), _b = (b);					\
	__asm__ volatile (insn " %1, %2, %0" : "=r"(_r) : "r"(_a), "r"(_b)); \
	_r; })

#define ASM_RR(insn, a) ({						\
	u64 _r, _a = (a);						\
	__asm__ volatile (insn " %1, %0" : "=r"(_r) : "r"(_a));	\
	_r; })

/* insn Rm, #imm, Rd with a literal immediate */
#define ASM_RIR(insn, a, imm) ({					\
	u64 _r, _a = (a);						\
	__asm__ volatile (insn " %1, " #imm ", %0" : "=r"(_r) : "r"(_a)); \
	_r; })

#endif /* ISA_HARNESS_H */
