# Freestanding RV32I Sieve of Eratosthenes: print every prime <= N, one per line.
# Base ISA only (no M extension: marking multiples is repeated addition, decimal
# printing divides by 10 with a subtract loop). Entry 0, write(64)/exit(93) ecalls,
# fits the 32 KiB guest RAM. Runs under `../../muxleq -r primes.elf`. The sieve array
# lives in .bss, which the loader zero-fills, so no explicit clear is needed.
.equ SYS_WRITE, 64
.equ SYS_EXIT,  93
.equ N,         100

.text
.global _start
_start:
    la   s0, sieve             # s0 = &sieve[0]
    li   s1, 2                 # s1 = i
loop_i:
    li   t3, N
    blt  t3, s1, done          # i > N -> done
    add  t2, s0, s1
    lbu  t4, 0(t2)             # sieve[i]  (0 = prime, 1 = composite)
    bnez t4, next_i
    mv   a0, s1                # i is prime: print it
    jal  ra, print_dec
    add  s2, s1, s1            # j = 2*i
mark:
    li   t3, N
    blt  t3, s2, next_i        # j > N -> stop marking
    add  t2, s0, s2
    li   t5, 1
    sb   t5, 0(t2)             # sieve[j] = 1
    add  s2, s2, s1            # j += i
    j    mark
next_i:
    addi s1, s1, 1
    j    loop_i
done:
    li   a7, SYS_EXIT
    li   a0, 0
    ecall

.include "print_dec.S"        # shared decimal printer (defines print_dec + buf)

.section .bss
sieve: .space N + 1
