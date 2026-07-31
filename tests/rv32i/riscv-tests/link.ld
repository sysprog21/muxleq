/* Link the vendored riscv-tests at guest address 0 for the muxleq RV32I ABI
 * (entry _start). Same low layout as ../rv32i.ld; .data is writable because the
 * runner maps the whole guest image into its RAM window. */
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
