/*
 * Context-switch test case: a minimal cooperative two-task kernel that drives
 * the ctx-switch.S routine end to end. This is the cooperative counterpart to
 * the preemptive kernel.c; it isolates the bare context-switch mechanism, with
 * no priorities, queues, mutexes, or timer.
 *
 * Two statically-allocated tasks round-robin via an explicit context switch
 * (ctx-switch.S saves the full callee-saved set ra + s0..s11). Each prints its
 * letter and yields; task0 exits first, so the exact transcript "ABABAB!" holds
 * only if every switch preserves and restores the register context correctly, a
 * clobbered callee-saved register would corrupt a task's loop counter and
 * derail the alternation. That makes the transcript a direct check of
 * ctx-switch.S.
 */

#include <stdint.h>

#include "syscall.h"

typedef struct {
    unsigned *sp; /* saved stack pointer (offset 0: ctx-switch.S depends on it) */
} tcb_t;

#define FRAME_WORDS 16 /* ra + s0..s11, padded to 16 (64-byte) alignment */
#define STACK_WORDS 256

static tcb_t maintcb;            /* main's throwaway context on the first switch */
static tcb_t tasks[2];
static unsigned stack0[STACK_WORDS];
static unsigned stack1[STACK_WORDS];
static int cur;

extern void ctx_switch(tcb_t *old, tcb_t *newt); /* ctx-switch.S */

static void yield(void)
{
    int prev = cur;
    cur ^= 1;
    ctx_switch(&tasks[prev], &tasks[cur]);
}

static void task0(void)
{
    for (int i = 0; i < 3; i++) {
        putchar('A');
        yield();
    }
    putchar('!');
    exit(0);
}

static void task1(void)
{
    for (int i = 0; i < 3; i++) {
        putchar('B');
        yield();
    }
    putchar('?'); /* not reached: task0 exits first */
}

int main(void)
{
    /* Build each fake initial frame inline (not via a helper) so the store of
     * the task entry is a compile-time constant rvopt can see as a code
     * pointer. The other frame slots (s0..s11) are already zero: the stacks are
     * static bss. ra sits at frame offset 0; ctx_switch rets to it on first
     * activation.
     */
    tasks[0].sp = &stack0[STACK_WORDS - FRAME_WORDS];
    tasks[0].sp[0] = (unsigned) (uintptr_t) task0;
    tasks[1].sp = &stack1[STACK_WORDS - FRAME_WORDS];
    tasks[1].sp[0] = (unsigned) (uintptr_t) task1;
    cur = 0;
    ctx_switch(&maintcb, &tasks[0]); /* enter task0; never returns here */
    return 0;
}
