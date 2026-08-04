# Minimal crt0 for the RV32I RTOS demos.
# rvopt zero-fills the guest regfile at entry, so a stack-using C program must
# set sp itself (docs/rvopt-native-muxleq.md). Set sp to the reserved stack top,
# call main, and fall back to exit(93) if main ever returns.

.section .text.init
    .global _start
_start:
    la   sp, __stack_top
    call main
    li   a7, 93
    li   a0, 0
    ecall
