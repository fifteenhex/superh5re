/*
 * Output layer and group table expected by tests/isa/harness.c when it is
 * linked into the host testbench.  Only isa_operands and isa_rand are used.
 */
#include <stdio.h>
#include <stdlib.h>

void isa_puts(const char *s) { fputs(s, stdout); }
void isa_exit(int failures) { exit(failures != 0); }

struct isa_group { const char *name; void (*run)(void); };
const struct isa_group __start_isa_groups[1] = { { 0, 0 } };
const struct isa_group __stop_isa_groups[1]  = { { 0, 0 } };
