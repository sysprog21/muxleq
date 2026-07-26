# Freestanding RV32I "Hello World!" for the muxleq runner.
# Links at guest address 0 and uses only the write(64) and exit(93) ecalls, so it
# runs directly under `../../muxleq -r hello.elf`. Prints the greeting five times.
.equ SYS_WRITE, 64
.equ SYS_EXIT,  93

.section .rodata
msg: .ascii "Hello World!\n"
.equ msg_len, . - msg          # define length before _start references it

.text
.global _start
_start:
    li   t0, 0              # loop counter
    li   t1, 5              # repeat count
loop:
    beq  t0, t1, done
    li   a7, SYS_WRITE
    li   a0, 1              # fd 1 = stdout (the runner ignores the fd)
    la   a1, msg
    li   a2, msg_len
    ecall
    addi t0, t0, 1
    j    loop
done:
    li   a7, SYS_EXIT
    li   a0, 0
    ecall
