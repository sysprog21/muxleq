/*
 * RTOS scenario: priority inheritance under the classic priority-inversion
 * setup. Exercises the rtos.c core (scheduling, priority-inheritance mutex,
 * blocking semaphores, blocking/wakeup) end to end.
 *
 *   L (low)  takes the mutex, then wakes H and M.
 *   H (high) blocks on the mutex L holds.
 *   M (mid)  is ready and, being higher than L's BASE priority, would preempt L
 *            and starve H (unbounded inversion) if nothing intervened.
 * The mutex lifts L to H's priority while H waits, so M cannot preempt L; L
 * finishes its critical section and hands the mutex to H, which runs before M.
 * The transcript is therefore "LHM". Without priority inheritance it would be
 * "LMH" (H starved behind M). Ordering is decided by priorities, not the timer
 * rate, so the run is deterministic.
 */

#include "rtos.h"

#include "syscall.h"

static tcb_t tcb_low, tcb_mid, tcb_high, tcb_idle;
static uint32_t stk_low[256], stk_mid[256], stk_high[256], stk_idle[128];
tcb_t *const tasks[] = {&tcb_high, &tcb_mid, &tcb_low, &tcb_idle}; /* idle last */
const int ntasks = 4;
int alive = 3; /* non-idle tasks still running */

static sem_t go_high = {.count = 0}; /* releases H after L has the mutex */
static sem_t go_mid = {.count = 0};  /* releases M */
static mutex_t mtx = {.owner = 0};   /* the contended resource */

static void task_low(void)
{
    mutex_lock(&mtx);
    putchar('L');
    sem_post(&go_high); /* H wakes, preempts, and blocks on mtx (boosting us) */
    sem_post(&go_mid);  /* M wakes; without the boost it would preempt us here */

    /* Hold the mutex long enough that H actually preempts and blocks on it
     * while we own it: the loop must span more than one QUANTUM of mtime ticks
     * (400 iterations is ~30x QUANTUM here). If it were shorter than a quantum
     * we would unlock before H ever blocks, and no inversion would occur to
     * test.
     */
    for (volatile int i = 0; i < 400; i++)
        ;
    mutex_unlock(&mtx); /* boost drops; H (highest) takes mtx and runs before M */
    task_exit();
}

static void task_mid(void)
{
    sem_wait(&go_mid);
    putchar('M');
    task_exit();
}

static void task_high(void)
{
    sem_wait(&go_high);
    mutex_lock(&mtx);
    putchar('H');
    mutex_unlock(&mtx);
    task_exit();
}

static void idle(void)
{
    for (;;)
        asm volatile("wfi");
}

/* Frames are initialized INLINE so each "frame[32] = &task" stores a
 * compile-time constant rvopt can collect as an mret entry target.
 */
void kmain(void)
{
    /* base_prio == prio initially. */
    tcb_low.frame[2] = (uint32_t) (uintptr_t) &stk_low[256];
    tcb_low.frame[32] = (uint32_t) (uintptr_t) task_low;
    tcb_low.state = READY;
    tcb_low.prio = tcb_low.base_prio = 1;
    tcb_mid.frame[2] = (uint32_t) (uintptr_t) &stk_mid[256];
    tcb_mid.frame[32] = (uint32_t) (uintptr_t) task_mid;
    tcb_mid.state = READY;
    tcb_mid.prio = tcb_mid.base_prio = 2;
    tcb_high.frame[2] = (uint32_t) (uintptr_t) &stk_high[256];
    tcb_high.frame[32] = (uint32_t) (uintptr_t) task_high;
    tcb_high.state = READY;
    tcb_high.prio = tcb_high.base_prio = 3;
    tcb_idle.frame[2] = (uint32_t) (uintptr_t) &stk_idle[128];
    tcb_idle.frame[32] = (uint32_t) (uintptr_t) idle;
    tcb_idle.state = READY;
    tcb_idle.prio = tcb_idle.base_prio = 0;

    /* L runs first and takes the mutex. H and M are READY too, but each blocks
     * at once on its still-zero release semaphore when scheduled, so L owns the
     * critical section before either of them can act.
     */
    current_tcb = &tcb_low;
    current_tcb->state = RUNNING;
    asm volatile("la t0, trap_handler\n\t csrw mtvec, t0" : : : "t0", "memory");
    wr_mtimecmp(rd_mtime() + QUANTUM);

    /* enable machine timer interrupt; set MIE and MPIE so the first mret runs
     * the launched task with interrupts on.
     */
    asm volatile(
        "li t0, 0x80\n\t csrs mie, t0\n\t li t0, 0x88\n\t csrs mstatus, t0"
        : : : "t0", "memory");
}
