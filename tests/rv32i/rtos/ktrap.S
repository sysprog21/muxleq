# Trap entry and context switch for the preemptive RTOS.
#
# A task's register save area (its "frame") is the first member of its TCB, so a
# TCB pointer is also a frame pointer. mscratch holds the running task's frame
# pointer; on a timer trap we swap it with sp (the standard technique), spill all
# registers, run the C scheduler on a private kernel stack, then restore the
# newly-current task and mret. _start shares the restore tail to launch the first
# task. The C side never touches the frame layout; only these offsets do.
.equ F_SP,   8     # frame[2]  = saved sp (x2)
.equ F_MEPC, 128   # frame[32] = saved mepc

# Save/restore every general-purpose register except x0 (hardwired 0) and x2 (sp,
# handled via the mscratch swap). Register xN lives at frame offset N*4. The set
# is listed ONCE; `\op` is sw to spill or lw to reload.
.macro GPREGS op
    .irp n, 1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
        \op x\n, (\n * 4)(sp)
    .endr
.endm

.section .bss
.align 4
kstack: .skip 2048
kstack_top:

.section .text
.global _start
.global trap_handler
_start:
    la    sp, kstack_top
    call  kmain                # create tasks, set current_tcb, mtvec, timer
    la    t0, current_tcb      # launch the first task: restore its frame + mret
    lw    sp, 0(t0)
    j     .Lrestore

trap_handler:
    csrrw sp, 0x340, sp        # sp = current frame, mscratch = interrupted sp
    GPREGS sw                  # spill x1, x3..x31 to the frame
    csrr  t0, 0x340            # interrupted sp, parked in mscratch by the swap
    sw    t0, F_SP(sp)
    csrr  t0, mepc
    sw    t0, F_MEPC(sp)

    la    sp, kstack_top       # private stack for the C scheduler
    call  scheduler_tick       # updates current_tcb, rearms the timer

    la    t0, current_tcb
    lw    sp, 0(t0)            # sp = new current task's frame
.Lrestore:
    lw    t0, F_MEPC(sp)
    csrw  mepc, t0
    GPREGS lw                  # reload x1, x3..x31 from the frame
    csrw  0x340, sp            # mscratch = current frame for the next trap
    lw    x2, F_SP(sp)         # sp = task sp (last: clobbers the frame pointer)
    mret
