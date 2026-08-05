# Fibonacci for the muxleq runner.
# Prints fib(0)..fib(11), one decimal value per line, then exits. Uses only the
# base ISA -- no M extension -- so the decimal conversion divides by 10 with a
# subtract loop (values are small). Lowered by 'rvopt mux' and run on
# '../../build/muxleq'.
.equ SYS_WRITE, 64
.equ SYS_EXIT,  93
.equ COUNT,     12

.text
.global _start
_start:
    li   s0, 0             # fib(i-1)
    li   s1, 1             # fib(i)
    li   s2, 0             # i
    li   s3, COUNT
1:
    beq  s2, s3, 2f
    mv   a0, s0
    jal  ra, print_dec
    add  s4, s0, s1       # next = fib(i-1) + fib(i)
    mv   s0, s1
    mv   s1, s4
    addi s2, s2, 1
    j    1b
2:
    li   a7, SYS_EXIT
    li   a0, 0
    ecall

.include "print-dec.S"        # shared decimal printer (defines print_dec + buf)
