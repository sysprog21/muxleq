/* Link the RV32I RTOS demos at guest address 0 but reserve a stack the C code
 * needs. The NOLOAD .stack section extends the PT_LOAD memsz so rvopt's
 * guest-RAM window covers the stack; __stack_top is the initial sp set by
 * crt0.S.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
    . = 0x0;
    .text   : { *(.text.init) *(.text*) }
    .rodata : { *(.rodata*) }
    .data   : { *(.data*) }
    .bss    : { *(.bss*) *(COMMON) }
    . = ALIGN(16);
    __bss_end = .;
    .stack (NOLOAD) : {
        . = . + 0x1000;   /* 4 KiB stack */
        . = ALIGN(16);
        __stack_top = .;
    }
}
