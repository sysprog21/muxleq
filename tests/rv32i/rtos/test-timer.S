# Timer-trap test: set mtvec, enable the timer, program mtimecmp,
# wait (wfi), take a timer interrupt into the handler, print 'T', bump mtimecmp,
# mret back to the wait loop, take a SECOND interrupt (which must observe the
# updated interrupt count in memory and fresh CSR state), then print 'R' and
# exit. Expected stdout: "TTR".
#
# CSR numbers: mtvec=0x305, mie=0x304, mstatus=0x300, mip=0x344, mepc=0x341,
# mcause=0x342, mtimecmp=0x7c0 (custom), mtime=0xb00. mie.MTIE = bit 7 (0x80),
# mstatus.MIE = bit 3 (0x08).

.equ SYS_WRITE, 64
.equ SYS_EXIT,  93

.section .data
count: .word 0

.section .rodata
tmsg: .ascii "T"
rmsg: .ascii "R"

.text
.global _start
_start:
    la    t0, trap_handler
    csrw  mtvec, t0
    li    t0, 5
    csrw  0x7c0, t0            # mtimecmp = 5 (fires soon)
    li    t0, 0x80
    csrs  mie, t0             # enable machine timer interrupt (MTIE)
    csrsi mstatus, 8          # enable global interrupts (MIE)
wait:
    wfi
    j     wait                # spin until the timer redirects to mtvec

    .align 2
trap_handler:
    li    a7, SYS_WRITE
    li    a0, 1
    la    a1, tmsg
    li    a2, 1
    ecall                     # print 'T'

    csrr  t0, 0x7c0
    addi  t0, t0, 1000
    csrw  0x7c0, t0           # push mtimecmp out so the handler can finish

    la    t1, count
    lw    t2, 0(t1)
    addi  t2, t2, 1
    sw    t2, 0(t1)           # count this interrupt (memory, seen by 2nd trap)
    li    t3, 2
    bge   t2, t3, finish
    mret                      # return to the interrupted wait loop

finish:
    li    a7, SYS_WRITE
    li    a0, 1
    la    a1, rmsg
    li    a2, 1
    ecall                     # print 'R'
    li    a7, SYS_EXIT
    li    a0, 0
    ecall
