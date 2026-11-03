/* Integer arithmetic: ADD, ADD.L, ADDZ.L, SUB, SUB.L, ADDI, ADDI.L (Vol. 2 ch. 2). */
#include "harness.h"

ISA_GROUP(arith)
{
	u64 a, b;

	ISA_FOREACH_OPERAND(a) ISA_FOREACH_OPERAND(b) {
		CHECK2("add", ASM_RRR("add", a, b), a + b, a, b);
		CHECK2("sub", ASM_RRR("sub", a, b), a - b, a, b);
		CHECK2("add.l", ASM_RRR("add.l", a, b),
		       (u64)SignExtend32((u32)a + (u32)b), a, b);
		CHECK2("sub.l", ASM_RRR("sub.l", a, b),
		       (u64)SignExtend32((u32)a - (u32)b), a, b);
		CHECK2("addz.l", ASM_RRR("addz.l", a, b),
		       ZeroExtend32((u32)a + (u32)b), a, b);
	}
	ISA_FOREACH_OPERAND(a) {
		CHECK1("addi 1", ASM_RIR("addi", a, 1), a + 1, a);
		CHECK1("addi -1", ASM_RIR("addi", a, -1), a - 1, a);
		CHECK1("addi 511", ASM_RIR("addi", a, 511), a + 511, a);
		CHECK1("addi -512", ASM_RIR("addi", a, -512), a - 512, a);
		CHECK1("addi.l 1", ASM_RIR("addi.l", a, 1),
		       (u64)SignExtend32((u32)a + 1), a);
		CHECK1("addi.l -512", ASM_RIR("addi.l", a, -512),
		       (u64)SignExtend32((u32)a - 512), a);
	}
}
