# context switch. a0 = old tcb, a1 = new tcb (each: sp at offset 0).
#
# Saves the full callee-saved set (ra + s0..s11) to the old task's stack,
# records the old sp, loads the new sp, restores the set, and rets. On a task's
# first activation the new frame was synthesized by task_init so ra = the task
# entry. This is the corrected switch: the external context_switch.S saved only
# ra+a0.

.text
.global ctx_switch
ctx_switch:
    addi sp, sp, -64
    sw   ra,  0(sp)
    sw   s0,  4(sp)
    sw   s1,  8(sp)
    sw   s2,  12(sp)
    sw   s3,  16(sp)
    sw   s4,  20(sp)
    sw   s5,  24(sp)
    sw   s6,  28(sp)
    sw   s7,  32(sp)
    sw   s8,  36(sp)
    sw   s9,  40(sp)
    sw   s10, 44(sp)
    sw   s11, 48(sp)

    sw   sp, 0(a0)        # old->sp = sp
    lw   sp, 0(a1)        # sp = new->sp

    lw   ra,  0(sp)
    lw   s0,  4(sp)
    lw   s1,  8(sp)
    lw   s2,  12(sp)
    lw   s3,  16(sp)
    lw   s4,  20(sp)
    lw   s5,  24(sp)
    lw   s6,  28(sp)
    lw   s7,  32(sp)
    lw   s8,  36(sp)
    lw   s9,  40(sp)
    lw   s10, 44(sp)
    lw   s11, 48(sp)
    addi sp, sp, 64
    ret
