/*
 * Host-side stand-in for tests/isa/harness.h, seen by tests/isa/groups/
 * mmedia1.c and mmedia2.c when they are compiled for the host by
 * ref_mm1.c / ref_mm2.c.  It provides the declarations those files use and
 * turns the CHECKn macros into evaluations of the reference value only, so
 * the ASM_* operand (SH-5 inline assembly) is never expanded.  The operand
 * corpus and isa_rand come from tests/isa/harness.c itself.
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

extern const u64 isa_operands[];
extern const unsigned isa_num_operands;
#define ISA_FOREACH_OPERAND(v) \
	for (unsigned _i_##v = 0; _i_##v < isa_num_operands && (((v) = isa_operands[_i_##v]), 1); _i_##v++)

u64 isa_rand(void);
void isa_rand_seed(u64 seed);

static inline s64 SignExtend8(u64 v)  { return (s64)(s8)v; }
static inline s64 SignExtend16(u64 v) { return (s64)(s16)v; }
static inline s64 SignExtend32(u64 v) { return (s64)(s32)v; }
static inline u64 ZeroExtend8(u64 v)  { return (u8)v; }
static inline u64 ZeroExtend16(u64 v) { return (u16)v; }
static inline u64 ZeroExtend32(u64 v) { return (u32)v; }

/* The 'got' argument (inline asm) is dropped; 'want' keeps the references used. */
#define CHECK0(insn, got, want)             ((void)(want))
#define CHECK1(insn, got, want, a)          ((void)(want))
#define CHECK2(insn, got, want, a, b)       ((void)(want))
#define CHECK3(insn, got, want, a, b, c)    ((void)(want))

/* The group body is kept as an ordinary function; it is not run here. */
#define ISA_GROUP(gname) void isa_group_fn_##gname(void)

#endif /* ISA_HARNESS_H */
