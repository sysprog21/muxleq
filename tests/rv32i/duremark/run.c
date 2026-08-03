/*
 * Freestanding DureMark runner for the muxleq RV32I simulator.
 *
 * Replaces upstream main.c: no clock()/printf/float and no time-based
 * auto-scaling (the simulator has no wall clock). Runs a FIXED iteration count
 * of the three unmodified workloads (list/matrix/state) and prints the combined
 * checksum via the write(64) ecall -- a deterministic result the golden pins.
 * Guest RAM is the 32 KiB window, so the ~1.5 KB of static workload buffers fit
 * with the stack. Multiply/modulo in the matrix workload resolve to the
 * self-contained soft routines in soft.c (no RV32M, no libgcc millicode).
 */
#include "duremark.h"

enum { SYS_WRITE = 64, SYS_EXIT = 93 };

/* Fixed workload repetitions. Deterministic -- the count also feeds the printed
 * checksum, so changing it re-pins the value in the Makefile. Sized so the
 * rvopt-lowered run is a substantial benchmark (~15 s on the native VM) yet
 * stays well under the run gate's timeout. "make bench-rv32i" times it; "make
 * rv32i-check" pins the checksum.
 */
enum { ITERATIONS = 500 };

static void du_write(const char *buf, unsigned len)
{
    register long a0 __asm__("a0") = 1;
    register const char *a1 __asm__("a1") = buf;
    register unsigned a2 __asm__("a2") = len;

    /* Load a7 inside the template, not via a "register long a7" input: GCC
     * would hoist the loop-invariant syscall number out of the caller, leaving
     * each ecall's own block without it, and "rvopt mux" resolves the syscall
     * number only from in-block constants (it rejects the image otherwise).
     */
    __asm__ volatile("li a7, %1\n\tecall"
                     : "+r"(a0)
                     : "i"(SYS_WRITE), "r"(a1), "r"(a2)
                     : "a7", "memory");
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
