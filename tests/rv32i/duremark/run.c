/*
 * Freestanding DureMark runner for the muxleq RV32I simulator.
 *
 * Replaces upstream main.c: no clock()/printf/float and no time-based
 * auto-scaling (the simulator has no wall clock). Runs a FIXED iteration count
 * of the three unmodified workloads (list/matrix/state) and prints the combined
 * checksum via the write(64) ecall -- a deterministic result the golden pins.
 * Guest RAM is the 32 KiB window, so the ~1.5 KB of static workload buffers fit
 * with the stack. Multiply/modulo in the matrix workload resolve to rv32i
 * libgcc soft routines (no RV32M).
 */
#include "duremark.h"

enum { SYS_WRITE = 64, SYS_EXIT = 93 };

/* Fixed workload repetitions. Deterministic; chosen to run well under the
 * golden's 20 s timeout on the interpreted OISC.
 */
enum { ITERATIONS = 1 };

static void du_write(const char *buf, unsigned len)
{
    register long a7 __asm__("a7") = SYS_WRITE;
    register long a0 __asm__("a0") = 1;
    register const char *a1 __asm__("a1") = buf;
    register unsigned a2 __asm__("a2") = len;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2) : "memory");
}

static void du_puts(const char *s)
{
    unsigned n = 0;
    while (s[n])
        n++;
    du_write(s, n);
}

static void du_putu(uint32_t v)
{
    char buf[10];
    int i = 10;
    if (v == 0) {
        du_write("0", 1);
        return;
    }
    while (v) {
        buf[--i] = (char) ('0' + v % 10);
        v /= 10;
    }
    du_write(buf + i, (unsigned) (10 - i));
}

void du_main(void)
{
    du_results_t res;
    uint32_t checksum = 0;
    unsigned i;

    res.execs = ID_LIST | ID_MATRIX | ID_STATE;
    res.list = du_list_init();
    du_init_matrix(&res.mat);
    du_init_state();

    for (i = 0; i < ITERATIONS; i++)
        checksum += du_bench_list(&res, (int16_t) (i & 0x7FFF));
    for (i = 0; i < ITERATIONS; i++)
        checksum += du_bench_matrix(&res.mat, (matdat_t) (i & 0x7FFF));
    for (i = 0; i < ITERATIONS; i++)
        checksum += du_bench_state((int16_t) (i & 0x7F));

    du_puts("DureMark checksum ");
    du_putu(checksum);
    du_puts("\n");
}
