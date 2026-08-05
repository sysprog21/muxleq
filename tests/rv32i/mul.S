# shift-add software multiply for the muxleq runner.
# RV32I base has NO M extension, so a product is built in software: for each set
# bit of the multiplier, add the shifted multiplicand (the standard shift-add
# algorithm milliForth does with a hardware M* -- here in base ISA). This is the
# first demo to exercise a logical right shift (srli) + low-bit testing (andi).
# Prints the 7 times table 7*0..7*9, one decimal product per line, then exits.
# Lowered by 'rvopt mux' and run on '../../build/muxleq'.
.equ SYS_WRITE, 64
.equ SYS_EXIT,  93
.equ COUNT,     10

.text
.global _start
_start:
    li   s0, 7             # fixed multiplicand (the "7 times table")
    li   s1, 0             # i = current multiplier, 0..COUNT-1
    li   s2, COUNT
row_loop:
    beq  s1, s2, done
    mv   t0, s0           # multiplicand, shifted left each step
    mv   t1, s1           # multiplier, shifted right each step
    li   a0, 0            # accumulator = product
mul_loop:
    beqz t1, mul_done     # no multiplier bits left -> product complete
    andi t2, t1, 1        # test the low bit of the multiplier
    beqz t2, no_add
    add  a0, a0, t0       # bit set: add the current shifted multiplicand
no_add:
    slli t0, t0, 1        # multiplicand <<= 1
    srli t1, t1, 1        # multiplier  >>= 1
    j    mul_loop
mul_done:
    jal  ra, print_dec    # print the product (a0), print_dec preserves s0..s2
    addi s1, s1, 1
    j    row_loop
done:
    li   a7, SYS_EXIT
    li   a0, 0
    ecall

.include "print-dec.S"        # shared decimal printer (defines print_dec + buf)
