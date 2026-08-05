# print_dec: write the unsigned value in a0 as decimal digits followed by '\n'.
# Shared by the freestanding RV32I demos (fibonacci, primes) via
# '.include "print-dec.S"'.
# The includer must define SYS_WRITE (= 64) before the include. Base ISA only:
# the digits are built backward into buf by a divide-by-10 subtract loop (no M
# extension), then written as one substring. Touches only a0..a2/t0..t6 and no
# stack, so the caller keeps its state in s-registers. Internal labels are
# '.L'-local so an includer can reuse the names digit/mod/emit without clashing.
print_dec:
    la   t0, buf
    addi t1, t0, 15            # t1 -> last byte of buf
    li   t2, 10
    sb   t2, 0(t1)             # trailing newline (10 == '\n')
.Ldigit:
    li   t5, 0                 # quotient  = a0 / 10
    mv   t3, a0                # remainder = a0 % 10 (built by subtraction)
.Lmod:
    li   t6, 10
    blt  t3, t6, .Lemit
    addi t3, t3, -10
    addi t5, t5, 1
    j    .Lmod
.Lemit:
    addi t3, t3, 48            # '0' + digit
    addi t1, t1, -1
    sb   t3, 0(t1)
    mv   a0, t5
    bnez a0, .Ldigit
    la   a1, buf
    addi a1, a1, 16
    sub  a2, a1, t1            # length = end - first_digit
    mv   a1, t1               # buffer start
    li   a7, SYS_WRITE
    li   a0, 1
    ecall
    ret

.section .bss
buf: .space 16
