OUTPUT_FORMAT("elf32-sh64-linux")
ENTRY(_start)
SECTIONS
{
	. = 0x80000000;
	.text : { *(.text.start) *(.text..SHmedia32) *(.text .text.*) }
	.rodata : { *(.rodata .rodata.*) }
	isa_groups : { __start_isa_groups = .; KEEP(*(isa_groups)) __stop_isa_groups = .; }
	.data : { *(.data .data.*) }
	.bss : { *(.bss .bss.*) *(COMMON) }
}
