/*
 * Preemptive RTOS core: priority scheduling, blocking counting semaphores, and
 * a priority-inheritance mutex. See rtos.h for the scenario contract. Blocking
 * needs NO synchronous context switch: a blocked task parks itself (state =
 * BLOCKED) and spins at a wfi safepoint; the scheduler never picks a non-READY
 * task, so the timer switches away and the task is not run again until it is
 * made READY.
 */
#include "rtos.h"

#include "syscall.h"

tcb_t *current_tcb; /* read by ktrap.S */

/* Called from the trap handler on a private kernel stack: pick the highest
 * priority READY task (idle, last in tasks[], is always READY) and rearm the
 * timer.
 */
void scheduler_tick(void)
{
    if (current_tcb->state == RUNNING)
        current_tcb->state = READY;
    tcb_t *best = tasks[ntasks - 1]; /* idle: lowest priority, always READY */
    for (int k = 0; k < ntasks; k++)
        if (tasks[k]->state == READY && tasks[k]->prio > best->prio)
            best = tasks[k];
    current_tcb = best;
    current_tcb->state = RUNNING;

    /* Rearm LAST: mtime also ticks at the safepoints inside this function, so
     * an early rearm would already have elapsed and preempt the task
     * immediately.
     */
    wr_mtimecmp(rd_mtime() + QUANTUM);
}

/* Wait-queue helpers (called with interrupts off). */
static void wq_push(waitq_t *q, tcb_t *t)
{
    t->wq_next = 0;
    if (q->tail)
        q->tail->wq_next = t;
    else
        q->head = t;
    q->tail = t;
}
static tcb_t *wq_pop(waitq_t *q)
{
    tcb_t *t = q->head;
    if (t) {
        q->head = t->wq_next;
        if (!q->head)
            q->tail = 0;
    }
    return t;
}

/* Park the current task on a wait queue and spin until another task makes it
 * READY again. Called with interrupts off; returns with them off. The state is
 * volatile, so the spin reloads it every pass.
 */
static void block_current(waitq_t *q)
{
    current_tcb->state = BLOCKED; /* parked: the scheduler skips us */
    wq_push(q, current_tcb);
    irq_on();
    while (current_tcb->state == BLOCKED) /* resumed READY by a post/unlock */
        asm volatile("wfi");
    irq_off();
}

/* Counting semaphore, signal-and-continue: the token is the count itself, so
 * sem_post only marks the oldest waiter READY and the waiter re-checks count
 * when it runs. A task that calls sem_wait first can therefore take the token
 * instead (no strict FIFO handoff), but no token is ever lost.
 */
void sem_wait(sem_t *s)
{
    irq_off();
    while (s->count == 0)
        block_current(&s->wq);
    s->count--;
    irq_on();
}

void sem_post(sem_t *s)
{
    irq_off();
    s->count++;
    tcb_t *w = wq_pop(&s->wq); /* wake the oldest waiter, if any */
    if (w)
        w->state = READY;
    irq_on();
}

/* Priority-inheritance mutex. When a higher-priority task blocks on a mutex a
 * lower-priority task holds, the holder is lifted to the waiter's priority so a
 * medium-priority task cannot preempt the holder and leave the high-priority
 * waiter blocked indefinitely (bounded, single-level inversion). The boost is
 * dropped on unlock.
 *
 * Scope: this is a teaching mutex, deliberately narrower than a full RTOS one.
 * It assumes at most one held mutex per task (restore to base, not recompute
 * across held mutexes), wakes waiters FIFO rather than highest-priority-first,
 * does not propagate a boost transitively down a chain of mutexes, and releases
 * on unlock rather than handing off directly (so a third contender could win
 * the race). The single-holder / single-waiter scenario exercises none of those
 * gaps.
 */
void mutex_lock(mutex_t *m)
{
    irq_off();
    while (m->owner && m->owner != current_tcb) {
        if (current_tcb->prio > m->owner->prio)
            m->owner->prio = current_tcb->prio; /* inherit our priority */
        block_current(&m->wq);
    }
    m->owner = current_tcb;
    irq_on();
}

void mutex_unlock(mutex_t *m)
{
    irq_off();

    /* only the holder may unlock; ignore others, so a stray call cannot hand
     * off the mutex or reset an unrelated task's priority
     */
    if (m->owner != current_tcb) {
        irq_on();
        return;
    }

    /* Drop straight back to base priority. A full RTOS recomputes the effective
     * priority across every mutex the task still holds; this demo holds at most
     * one, so base is exact.
     */
    current_tcb->prio = current_tcb->base_prio;
    m->owner = 0;
    tcb_t *w = wq_pop(&m->wq); /* hand off to the next waiter */
    if (w)
        w->state = READY;
    irq_on();
}

void task_exit(void)
{
    irq_off();
    current_tcb->state = DEAD;
    if (--alive == 0)
        exit(0);
    irq_on();
    for (;;) /* DEAD: parked forever by the scheduler */
        asm volatile("wfi");
}
