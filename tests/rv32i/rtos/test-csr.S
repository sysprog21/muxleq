# CSR test: exercise the CSR forms the RTOS kernel uses plus the tricky cases
# (rd == rs1 aliasing, immediate write, and the zero-mask no-op that must NOT
# write the CSR). Uses mtvec as a scratch machine CSR (a plain data cell in the
# lowered image). Prints 'C' iff every check holds, else 'X'.
# csrsi/csrci mstatus,8 are also exercised (the kernel's MIE toggles).

.equ SYS_WRITE, 64
.equ SYS_EXIT,  93

.section .rodata
okmsg:   .ascii "C"
failmsg: .ascii "X"

.text
.global _start
_start:
    # 1. csrw / csrr round-trip.
    li    t0, 0x1234
    csrw  mtvec, t0
    csrr  t1, mtvec
    bne   t0, t1, fail

    # 2. csrwi (immediate write): mtvec = 5.
    csrwi mtvec, 5
    csrr  t1, mtvec
    li    t2, 5
    bne   t1, t2, fail

    # 3. csrrs with rd == rs1: mtvec=8, a0=1 -> a0=old(8), mtvec=8|1=9.
    li    t0, 8
    csrw  mtvec, t0
    li    a0, 1
    csrrs a0, mtvec, a0
    li    t2, 8
    bne   a0, t2, fail          # a0 got the OLD mtvec
    csrr  t1, mtvec
    li    t2, 9
    bne   t1, t2, fail          # mtvec |= 1

    # 4. csrrc with rd == rs1: mtvec=9, a0=1 -> a0=old(9), mtvec=9&~1=8.
    li    a0, 1
    csrrc a0, mtvec, a0
    li    t2, 9
    bne   a0, t2, fail
    csrr  t1, mtvec
    li    t2, 8
    bne   t1, t2, fail

    # 5. zero-mask set is a pure read (must NOT write): mtvec stays 8.
    csrsi mtvec, 0
    csrr  t1, mtvec
    li    t2, 8
    bne   t1, t2, fail

    # 6. the kernel's mstatus.MIE toggles must lower and run (no observable
    #    effect without the timer).
    csrsi mstatus, 8
    csrci mstatus, 8

    li    a7, SYS_WRITE
    li    a0, 1
    la    a1, okmsg
    li    a2, 1
    ecall
    j     done
fail:
    li    a7, SYS_WRITE
    li    a0, 1
    la    a1, failmsg
    li    a2, 1
    ecall
done:
    li    a7, SYS_EXIT
    li    a0, 0
    ecall
