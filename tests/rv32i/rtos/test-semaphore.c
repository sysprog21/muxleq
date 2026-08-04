/*
 * RTOS scenario: counting-semaphore coverage. A high-priority producer posts 3
 * items to one counting semaphore before the low-priority consumer ever runs,
 * so the count accumulates to 3 (not just toggling 0/1); the consumer then
 * drains all 3 in order. The transcript "ABC" proves the semaphore counts up
 * and hands back exactly N items with none lost or duplicated.
 *
 * This complements test-rtos.c, which covers the other semaphore path: a waiter
 * blocking on an empty semaphore and being woken by a later post. Priorities
 * make the run deterministic: the producer (higher) always finishes all posts
 * and exits before the consumer is scheduled, so the count is 3 every run.
 */

#include "rtos.h"

#include "syscall.h"

static tcb_t tcb_prod, tcb_cons, tcb_idle;
static uint32_t stk_prod[256], stk_cons[256], stk_idle[128];
tcb_t *const tasks[] = {&tcb_prod, &tcb_cons, &tcb_idle}; /* idle last */
const int ntasks = 3;
int alive = 2; /* producer + consumer */

static sem_t items = {.count = 0};

static void producer(void)
{
    sem_post(&items);
    sem_post(&items);
    sem_post(&items); /* no waiter yet: count climbs to 3 (counting, not binary) */
    task_exit();
}

static void consumer(void)
{
    sem_wait(&items); /* count 3 -> 2, no block */
    putchar('A');
    sem_wait(&items); /* 2 -> 1 */
    putchar('B');
    sem_wait(&items); /* 1 -> 0 */
    putchar('C');
    task_exit();
}

static void idle(void)
{
    for (;;)
        asm volatile("wfi");
}

/* Frames are initialized INLINE so each `frame[32] = &task` stores a
 * compile-time constant rvopt can collect as an mret entry target.
 */
void kmain(void)
{
    tcb_prod.frame[2] = (uint32_t) (uintptr_t) &stk_prod[256];
    tcb_prod.frame[32] = (uint32_t) (uintptr_t) producer;
    tcb_prod.state = READY;
    tcb_prod.prio = tcb_prod.base_prio = 2; /* high: fills the sem, then exits */
    tcb_cons.frame[2] = (uint32_t) (uintptr_t) &stk_cons[256];
    tcb_cons.frame[32] = (uint32_t) (uintptr_t) consumer;
    tcb_cons.state = READY;
    tcb_cons.prio = tcb_cons.base_prio = 1; /* low: drains after the producer */
    tcb_idle.frame[2] = (uint32_t) (uintptr_t) &stk_idle[128];
    tcb_idle.frame[32] = (uint32_t) (uintptr_t) idle;
    tcb_idle.state = READY;
    tcb_idle.prio = tcb_idle.base_prio = 0;

    current_tcb = &tcb_prod; /* producer (highest) runs first, fills the sem */
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
