/* Link freestanding RV32I test programs for the muxleq runner: entry at guest
 * address 0, everything packed contiguously from 0 so it fits the 1 KiB guest RAM. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
    . = 0x0;
    .text   : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data   : { *(.data*) }
    .bss    : { *(.bss*) *(COMMON) }
}
