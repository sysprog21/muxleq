.section .text.init
.global _start
_start:
    li   sp, 0x8000       # top of 32 KiB guest RAM
    jal  ra, du_main      # ONE `jal ra` call site so rvopt -mux resolves the ret
    li   a7, 93           # SYS_EXIT
    li   a0, 0
    ecall
1:  j 1b
