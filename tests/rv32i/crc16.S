# CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection) over the standard
# check string "123456789"; prints the checksum in decimal (10673 = 0x29B1).
# Base ISA only: the bitwise CRC is XOR + shift + AND, no M extension, so it
# exercises the logical/shift microcode that the other demos don't. Entry 0,
# write(64)/exit(93) ecalls, fits the 32 KiB guest RAM.
# Lowered by 'rvopt mux' and run on '../../build/muxleq'.
.equ SYS_WRITE, 64
.equ SYS_EXIT,  93

.section .rodata
msg: .ascii "123456789"
.equ msg_len, . - msg

.text
.global _start
_start:
    li   s0, 0xFFFF            # crc = 0xFFFF
    la   s1, msg              # s1 = message pointer
    li   s2, msg_len          # s2 = bytes remaining
byte_loop:
    beqz s2, done
    lbu  t0, 0(s1)            # b
    slli t0, t0, 8            # b << 8
    xor  s0, s0, t0          # crc ^= (b << 8)
    li   t3, 8               # 8 bits per byte
bit_loop:
    li   t1, 0x8000
    and  t2, s0, t1          # t2 = crc & 0x8000 (top bit, tested before the shift)
    slli s0, s0, 1           # crc <<= 1
    beqz t2, no_xor
    li   t1, 0x1021
    xor  s0, s0, t1          # crc ^= 0x1021
no_xor:
    li   t1, 0xFFFF
    and  s0, s0, t1          # keep crc 16-bit
    addi t3, t3, -1
    bnez t3, bit_loop
    addi s1, s1, 1
    addi s2, s2, -1
    j    byte_loop
done:
    mv   a0, s0
    jal  ra, print_dec
    li   a7, SYS_EXIT
    li   a0, 0
    ecall

.include "print_dec.S"        # shared decimal printer (defines print_dec + buf)
