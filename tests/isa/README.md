# SH-5 SHmedia ISA test kit

Self-checking tests for the SHmedia instruction set. Each test executes an
instruction with inline asm and compares the result with a C reference
written from the pseudocode in SH-5 CPU Core Volume 2, over a corpus of
boundary operands (`isa_operands[]` in `harness.c`) and pseudo-random words.
The expected values never come from the emulator: the kit is meant to
validate QEMU now and the FPGA core later.

Two builds from the same sources:

| MODE | Runs as | Output |
|---|---|---|
| `nolibc` (default) | static Linux program, usable as `/init` | stdout |
| `bare` | image for `qemu-system-sh5 -kernel`, MMU off, 0x80000000 | SCIF, polled |

```
make                 # isatest-nolibc.elf
make MODE=bare       # isatest-bare.elf
make run             # boots KERNEL with the program as init, prints the isa: lines
make MODE=bare run
make GROUPS="arith logic" run    # only these groups
make run ARGS=-v                 # also print PASS lines (nolibc mode)
```

Variables: `CROSS` (default `sh64-linux-`), `QEMU`, `KERNEL` (sh64 vmlinux),
`NOLIBCDIR` (nolibc with the SH-5 patch, see `../../userspace/`), `UAPIDIR`
(`make headers_install` of the sh64 kernel).

Output format, one line per failure and per group:

```
isa: group arith
isa: FAIL add.l a=0x... b=0x... got=0x... want=0x... (groups/arith.c:12)
isa: group arith ok 0 failures
isa: SUMMARY 5312 tests, 0 failures
isa: DONE
```

## Writing a group

One file per group in `groups/`, registered with `ISA_GROUP(name) { ... }`;
the table is a linker section, nothing else to edit. Use `CHECK1..3` with
the operands so a failure line is reproducible, `ISA_FOREACH_OPERAND` for
the corpus, `isa_rand()` for more. Reference semantics go next to the asm
in plain C, following the manual's `SignExtend`/`ZeroExtend` steps. Keep a
group under about a minute of emulated time.

## Groups

| File | Instructions |
|---|---|
| `arith.c` | ADD, ADD.L, ADDZ.L, SUB, SUB.L, ADDI, ADDI.L |
