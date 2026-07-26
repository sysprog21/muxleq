/* Link DureMark at guest address 0 for the muxleq runner. crt0's .text.init
 * (with _start) must come first so the ELF entry is 0. All sections pack low;
 * the stack grows down from 0x8000 (set in crt0). No gp -- built -mno-relax.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
    . = 0x0;
    .text   : { *(.text.init) *(.text*) }
    .rodata : { *(.rodata*) *(.srodata*) }
    .data   : { *(.data*) *(.sdata*) }
    .bss    : { *(.sbss*) *(.bss*) *(COMMON) }
}
