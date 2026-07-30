# Binary GCD (Stein's algorithm) for the muxleq runner.
# The binary GCD needs no division: it strips common factors of two with right
# shifts, orders the pair with an UNSIGNED compare, and subtracts. So this is the
# first demo to exercise an unsigned compare (bgeu, via the bleu pseudo) and a
# variable left shift (sll) alongside srli/andi. Prints gcd of a few pairs read
# from a .rodata table, one decimal result per line, then exits.
# Lowered by 'rvopt mux' and run on '../../build/muxleq'.
.equ SYS_WRITE, 64
.equ SYS_EXIT,  93

.text
.global _start
_start:
    la   s3, pairs        # -> current (u, v) pair
    la   s4, pairs_end
row_loop:
    beq  s3, s4, done
    lw   s0, 0(s3)        # u
    lw   s1, 4(s3)        # v
    addi s3, s3, 8        # advance to the next pair

    # a0 = gcd(s0, s1) by Stein's algorithm, working in t0..t3
    mv   t0, s0           # u
    mv   t1, s1           # v
    bnez t0, u_nonzero
    mv   a0, t1           # gcd(0, v) = v
    j    emit
u_nonzero:
    bnez t1, both_nonzero
    mv   a0, t0           # gcd(u, 0) = u
    j    emit
both_nonzero:
    li   t2, 0            # shift = count of common factors of two
common_twos:
    or   t3, t0, t1
    andi t3, t3, 1
    bnez t3, strip_u      # once either is odd, no more common twos
    srli t0, t0, 1
    srli t1, t1, 1
    addi t2, t2, 1
    j    common_twos
strip_u:
    andi t3, t0, 1        # make u odd
    bnez t3, strip_v
    srli t0, t0, 1
    j    strip_u
strip_v:
    andi t3, t1, 1        # make v odd
    bnez t3, ordered
    srli t1, t1, 1
    j    strip_v
ordered:
    bleu t0, t1, no_swap  # keep u <= v (unsigned) -> emits bgeu
    mv   t3, t0           # swap u and v
    mv   t0, t1
    mv   t1, t3
no_swap:
    sub  t1, t1, t0       # v -= u (both odd, so v stays even and nonneg)
    bnez t1, strip_v      # more to do while v != 0
    sll  a0, t0, t2       # gcd = u << shift  (restore the common factors of two)
emit:
    jal  ra, print_dec
    j    row_loop
done:
    li   a7, SYS_EXIT
    li   a0, 0
    ecall

.section .rodata
pairs:
    .word 48, 36          # 12
    .word 1071, 462       # 21
    .word 7, 7            # 7
    .word 17, 5           # 1
    .word 0, 9            # 9
pairs_end:

.text                         # back to code: print_dec's instructions belong in .text, not .rodata
.include "print_dec.S"        # shared decimal printer (defines print_dec + buf)
