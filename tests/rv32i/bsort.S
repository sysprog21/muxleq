# Bubble sort for the muxleq runner.
# Sorts a small word array in place, then prints it ascending. This is the first
# demo to exercise computed-address word access (slli index + add base, then
# lw/sw a 32-bit element) and a signed compare (ble/bge) driving in-place swaps
# across nested loops -- ground the sieve (byte flags) and the arithmetic demos
# do not cover. Prints the sorted array 0..9, one per line, then exits.
# Lowered by 'rvopt mux' and run on '../../build/muxleq'.
.equ SYS_WRITE, 64
.equ SYS_EXIT,  93
.equ N,         10

.text
.global _start
_start:
    la   s0, arr          # base of the array
    li   s1, N
    li   s2, 0            # i = outer pass index
outer:
    addi t6, s1, -1       # N-1
    bge  s2, t6, print_start   # i >= N-1 -> fully sorted
    sub  t2, t6, s2       # inner bound = N-1-i (tail is already in place)
    li   t1, 0           # j = 0
inner:
    bge  t1, t2, next_i
    slli t3, t1, 2        # byte offset = j*4
    add  t4, s0, t3       # &arr[j]
    lw   t5, 0(t4)        # arr[j]
    lw   t0, 4(t4)        # arr[j+1]
    ble  t5, t0, no_swap  # arr[j] <= arr[j+1] (signed) -> keep order
    sw   t0, 0(t4)        # else swap the pair
    sw   t5, 4(t4)
no_swap:
    addi t1, t1, 1        # j++
    j    inner
next_i:
    addi s2, s2, 1        # i++
    j    outer

print_start:
    li   s2, 0           # reuse s2 as the print index
print_loop:
    bge  s2, s1, done
    slli t0, s2, 2
    add  t0, s0, t0
    lw   a0, 0(t0)       # arr[i]
    jal  ra, print_dec   # print_dec preserves s0..s2
    addi s2, s2, 1
    j    print_loop
done:
    li   a7, SYS_EXIT
    li   a0, 0
    ecall

.data
arr:
    .word 5, 2, 8, 1, 9, 3, 7, 4, 6, 0   # arbitrary shuffle of 0..9

.text                         # back to code: print_dec's instructions belong in .text
.include "print-dec.S"        # shared decimal printer (defines print_dec + buf)
