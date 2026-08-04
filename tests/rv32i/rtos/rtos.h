/*
 * Minimal preemptive RTOS core for the muxleq --timer/--indirect substrate.
 *
 * The core (rtos.c) provides priority scheduling, blocking counting semaphores,
 * and a priority-inheritance mutex. A scenario (test-rtos.c, test-semaphore.c)
 * supplies the task set, an idle task, and kmain, then links against the core
 * and the shared trap handler (ktrap.S). Each scenario is its own standalone
 * image.
 *
 * rvopt rules every scenario must honor: no struct-array indexing and no modulo
 * (both lower to `mul`, which is RV32M); tasks are individual globals reached
 * through the static pointer array `tasks[]`, which MUST list the idle task
 * last (the scheduler falls back to it). Task frames are set up INLINE in kmain
 * so each entry address is a compile-time constant rvopt collects as an mret
 * dispatch target; a helper or a static initializer would hide it.
 */

#ifndef RTOS_H
#define RTOS_H
#include <stdint.h>

#define NREG 33 /* frame[0..31] = x0..x31, frame[32] = mepc */
enum { READY, RUNNING, BLOCKED, DEAD };

typedef struct tcb {
    uint32_t frame[NREG];   /* register save area; MUST be first (ktrap.S) */
    volatile uint8_t state; /* changed from another task's context, so a
                             * blocking spin must reload it every pass
                             */
    uint8_t prio;           /* effective priority (may be boosted by a mutex) */
    uint8_t base_prio;      /* original priority, restored on mutex unlock */
    struct tcb *wq_next;    /* wait-queue link (a task waits on one object) */
} tcb_t;

/* Intrusive FIFO wait queue, shared by semaphores and the mutex. */
typedef struct {
    tcb_t *head, *tail;
} waitq_t;

typedef struct {
    int count;
    waitq_t wq;
} sem_t;

typedef struct {
    tcb_t *owner; /* current holder, or NULL when free */
    waitq_t wq;   /* blocked lockers */
} mutex_t;

#define QUANTUM 40

/* mtime/mtimecmp are exposed as CSRs (this VM has no MMIO); mstatus.MIE is bit
 * 3. These are used by both the core and each scenario's kmain.
 */
static inline uint32_t rd_mtime(void)
{
    uint32_t v;
    asm volatile("csrr %0, 0xb00" : "=r"(v));
    return v;
}
static inline void wr_mtimecmp(uint32_t v)
{
    asm volatile("csrw 0x7c0, %0" : : "r"(v) : "memory");
}
static inline void irq_off(void)
{
    asm volatile("csrci mstatus, 8" : : : "memory");
}
static inline void irq_on(void)
{
    asm volatile("csrsi mstatus, 8" : : : "memory");
}

/* Scenario-provided state (a scenario defines these; the core reads them; no
 * struct-array indexing). */
extern tcb_t *const tasks[]; /* idle MUST be last */
extern const int ntasks;
extern int alive; /* non-idle tasks still running */

/* Owned elsewhere, NOT by scenarios: current_tcb by the core (rtos.c),
 * trap_handler by ktrap.S. A scenario reads and initializes current_tcb in
 * kmain but must not define it. */
extern tcb_t *current_tcb;      /* the running task; read by ktrap.S */
extern void trap_handler(void); /* ktrap.S */

/* Core API. */
void scheduler_tick(void); /* called by ktrap.S at a timer safepoint */
void sem_wait(sem_t *s);
void sem_post(sem_t *s);
void mutex_lock(mutex_t *m);
void mutex_unlock(mutex_t *m);
void task_exit(void);

#endif /* RTOS_H */
