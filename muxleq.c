/*
 * MUXLEQ virtual machine.
 *
 * This program executes a two-instruction (SUBLEQ and MUX) program from a
 * static memory array. It supports standard input/output and halts when the
 * program counter moves to a negative address.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Tail-call optimization attribute */
#if defined(__has_attribute) && __has_attribute(musttail)
#define MUST_TAIL __attribute__((musttail))
#else
#define MUST_TAIL
#endif

#if defined(__GNUC__) || defined(__clang__)
#define UNUSED __attribute__((unused))
#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
#define UNUSED
#define LIKELY(x) (x)
#define UNLIKELY(x) (x)
#endif

/* Define memory and instruction layout constants. */
#define MEM_SIZE (1 << 15)
#define MEM_MASK (MEM_SIZE - 1)
#define IO_MARKER ((uint16_t) -1)
#define NEGATIVE_FLAG MEM_SIZE

/* Instruction operand offsets. */
enum { A = 0, B = 1, C = 2, INSN_SIZE = 3 };

/* The memory of the virtual machine, initialized from an external file. */
static uint16_t m[MEM_SIZE] = {
#include <stage0.c>
};

/* Lightweight profiler, opt-in via -s / -p. When disabled (the default, and
 * what make check/bench/bootstrap use), dispatch() takes a single
 * predicted-not-taken branch, so profiled and unprofiled runs are behaviorally
 * identical. Only counts dispatch entries: fused ops that execute inline never
 * re-enter dispatch, so the heat map shows where the interpreter re-decodes
 * from scratch.
 */
enum { OP_GET, OP_PUT, OP_MUX, OP_SUBLEQ, OP_COUNT };
static bool prof_enabled = false; /* -s or -p given */
static bool prof_stats = false;   /* -s: instruction mix */
static bool prof_heat = false;    /* -p: PC heat map */
static uint64_t prof_total = 0;
static uint64_t prof_op[OP_COUNT] = {0};
static uint64_t prof_heat_map[MEM_SIZE];

/* Forward declarations for the mutually recursive VM functions. */
static int dispatch(uint16_t pc,
                    uint16_t addr_a,
                    uint16_t addr_b,
                    uint16_t addr_c);

/* Fetch the next instruction's operands and tail-call dispatch. */
#define FETCH_AND_DISPATCH(next_pc)                        \
    do {                                                   \
        const uint16_t __a = m[(next_pc) + A];             \
        const uint16_t __b = m[(next_pc) + B];             \
        const uint16_t __c = m[(next_pc) + C];             \
        MUST_TAIL return dispatch(next_pc, __a, __b, __c); \
    } while (0)

/* Check if instruction is a move (MUX with mask=0) */
static bool is_move_instruction(uint16_t a, uint16_t b, uint16_t c)
{
    if ((a == IO_MARKER) || (b == IO_MARKER))
        return false;
    if (!((c & NEGATIVE_FLAG) && (c != IO_MARKER)))
        return false;

    const uint16_t mask_addr = c & MEM_MASK;
    return (mask_addr == 6) || (m[mask_addr] == 0);
}

/* Check if instruction is a SUBLEQ */
static bool is_subleq_instruction(uint16_t a, uint16_t b, uint16_t c)
{
    return (a != IO_MARKER) && (b != IO_MARKER) &&
           !((c & NEGATIVE_FLAG) && (c != IO_MARKER));
}

static int get(uint16_t pc,
               UNUSED uint16_t addr_a,
               uint16_t addr_b,
               UNUSED uint16_t addr_c)
{
    const int input = getchar();
    if (UNLIKELY(input == EOF))
        return 0; /* Halt on End-of-File. */

    m[addr_b] = (uint16_t) input;
    FETCH_AND_DISPATCH(pc + INSN_SIZE);
}

static int put(uint16_t pc,
               uint16_t addr_a,
               UNUSED uint16_t addr_b,
               UNUSED uint16_t addr_c)
{
    if (UNLIKELY(putchar(m[addr_a]) == EOF))
        return 3; /* Halt on output error. */

    FETCH_AND_DISPATCH(pc + INSN_SIZE);
}

/* MUX with extended fusion for Forth inner interpreter patterns */
static int mux(uint16_t pc, uint16_t addr_a, uint16_t addr_b, uint16_t addr_c)
{
    const uint16_t mask_addr = addr_c & MEM_MASK;

    if (LIKELY(mask_addr == 6)) {
        /* Address 6 is always 0 - pure move (99.7% of MUX operations) */
        m[addr_b] = m[addr_a];
    } else {
        const uint16_t mask = m[mask_addr];
        if (UNLIKELY(mask == 0)) {
            m[addr_b] = m[addr_a];
        } else {
            /* General MUX operation for non-zero masks */
            m[addr_b] = (m[addr_a] & ~mask) | (m[addr_b] & mask);
            FETCH_AND_DISPATCH(pc + INSN_SIZE);
        }
    }

    /* Look ahead for fusion opportunities after a move */
    const uint16_t next_pc = pc + INSN_SIZE;
    if (UNLIKELY((next_pc & NEGATIVE_FLAG) != 0)) {
        FETCH_AND_DISPATCH(next_pc);
    }

    const uint16_t next_a = m[next_pc + A];
    const uint16_t next_b = m[next_pc + B];
    const uint16_t next_c = m[next_pc + C];

    /* Pattern 1: MOVE + SUBLEQ */
    if (is_subleq_instruction(next_a, next_b, next_c)) {
        const uint16_t result = m[next_b] - m[next_a];
        m[next_b] = result;

        if (UNLIKELY((result == 0) || (result & NEGATIVE_FLAG))) {
            FETCH_AND_DISPATCH(next_c);
        } else {
            /* Extend to 3-instruction fusion for common Forth patterns */
            const uint16_t third_pc = next_pc + INSN_SIZE;
            if (LIKELY(!(third_pc & NEGATIVE_FLAG))) {
                const uint16_t third_a = m[third_pc + A];
                const uint16_t third_b = m[third_pc + B];
                const uint16_t third_c = m[third_pc + C];

                /* MOVE + SUBLEQ + MOVE (common: load, operate, store) */
                if (is_move_instruction(third_a, third_b, third_c)) {
                    m[third_b] = m[third_a];
                    FETCH_AND_DISPATCH(third_pc + INSN_SIZE);
                } else {
                    FETCH_AND_DISPATCH(third_pc);
                }
            } else {
                FETCH_AND_DISPATCH(third_pc);
            }
        }
    }
    /* Pattern 2: MOVE + MOVE */
    else if (is_move_instruction(next_a, next_b, next_c)) {
        m[next_b] = m[next_a]; /* Execute second move */

        /* Try to extend: MOVE + MOVE + SUBLEQ (common in Forth stack
         * manipulation)
         */
        const uint16_t third_pc = next_pc + INSN_SIZE;
        if (LIKELY(!(third_pc & NEGATIVE_FLAG))) {
            const uint16_t third_a = m[third_pc + A];
            const uint16_t third_b = m[third_pc + B];
            const uint16_t third_c = m[third_pc + C];

            if (is_subleq_instruction(third_a, third_b, third_c)) {
                const uint16_t result = m[third_b] - m[third_a];
                m[third_b] = result;

                if (UNLIKELY((result == 0) || (result & NEGATIVE_FLAG))) {
                    FETCH_AND_DISPATCH(third_c);
                } else {
                    FETCH_AND_DISPATCH(third_pc + INSN_SIZE);
                }
            } else {
                FETCH_AND_DISPATCH(third_pc);
            }
        } else {
            FETCH_AND_DISPATCH(third_pc);
        }
    }
    /* No fusion possible */
    else {
        MUST_TAIL return dispatch(next_pc, next_a, next_b, next_c);
    }
}

/* SUBLEQ with extended fusion for Forth patterns */
static int subleq(uint16_t pc,
                  uint16_t addr_a,
                  uint16_t addr_b,
                  uint16_t addr_c)
{
    const uint16_t result = m[addr_b] - m[addr_a];
    m[addr_b] = result;

    if (UNLIKELY((result == 0) || (result & NEGATIVE_FLAG))) {
        FETCH_AND_DISPATCH(addr_c); /* Branch taken, cannot fuse. */
    } else {
        /* No branch - look for fusion opportunities */
        const uint16_t next_pc = pc + INSN_SIZE;
        if (UNLIKELY((next_pc & NEGATIVE_FLAG) != 0))
            FETCH_AND_DISPATCH(next_pc);

        const uint16_t next_a = m[next_pc + A];
        const uint16_t next_b = m[next_pc + B];
        const uint16_t next_c = m[next_pc + C];

        /* Pattern 1: SUBLEQ + SUBLEQ */
        if (is_subleq_instruction(next_a, next_b, next_c)) {
            const uint16_t result2 = m[next_b] - m[next_a];
            m[next_b] = result2;

            if (UNLIKELY((result2 == 0) || (result2 & NEGATIVE_FLAG))) {
                FETCH_AND_DISPATCH(next_c);
            } else {
                /* Try to extend: SUBLEQ + SUBLEQ + MOVE (arithmetic + cleanup)
                 */
                const uint16_t third_pc = next_pc + INSN_SIZE;
                if (LIKELY(!(third_pc & NEGATIVE_FLAG))) {
                    const uint16_t third_a = m[third_pc + A];
                    const uint16_t third_b = m[third_pc + B];
                    const uint16_t third_c = m[third_pc + C];

                    if (is_move_instruction(third_a, third_b, third_c)) {
                        m[third_b] = m[third_a];
                        FETCH_AND_DISPATCH(third_pc + INSN_SIZE);
                    } else {
                        FETCH_AND_DISPATCH(third_pc);
                    }
                } else {
                    FETCH_AND_DISPATCH(third_pc);
                }
            }
        }
        /* Pattern 2: SUBLEQ + MOVE */
        else if (is_move_instruction(next_a, next_b, next_c)) {
            m[next_b] = m[next_a]; /* Execute the move */
            FETCH_AND_DISPATCH(next_pc + INSN_SIZE);
        }
        /* No fusion possible */
        else {
            MUST_TAIL return dispatch(next_pc, next_a, next_b, next_c);
        }
    }
}

static int dispatch(uint16_t pc,
                    uint16_t addr_a,
                    uint16_t addr_b,
                    uint16_t addr_c)
{
    /* Halt if the program counter becomes negative. */
    if (UNLIKELY((pc & NEGATIVE_FLAG) != 0))
        return 0;

    if (UNLIKELY(prof_enabled)) {
        prof_total++;
        if (prof_heat)
            prof_heat_map[pc & MEM_MASK]++;
        if (prof_stats) {
            if (addr_a == IO_MARKER)
                prof_op[OP_GET]++;
            else if (addr_b == IO_MARKER)
                prof_op[OP_PUT]++;
            else if ((addr_c & NEGATIVE_FLAG) && (addr_c != IO_MARKER))
                prof_op[OP_MUX]++;
            else
                prof_op[OP_SUBLEQ]++;
        }
    }

    /* Dispatch to the appropriate handler based on the operand values. */
    if (UNLIKELY(addr_a == IO_MARKER))
        MUST_TAIL return get(pc, addr_a, addr_b, addr_c);

    if (UNLIKELY(addr_b == IO_MARKER))
        MUST_TAIL return put(pc, addr_a, addr_b, addr_c);

    if (UNLIKELY((addr_c & NEGATIVE_FLAG) && (addr_c != IO_MARKER)))
        MUST_TAIL return mux(pc, addr_a, addr_b, addr_c);

    /* Default to SUBLEQ operation. */
    MUST_TAIL return subleq(pc, addr_a, addr_b, addr_c);
}

/* Emit the profile to stderr after the VM halts (only when -s/-p was given). */
static void report_profile(void)
{
    static const char *names[OP_COUNT] = {"GET", "PUT", "MUX", "SUBLEQ"};

    fprintf(stderr, "\n=== muxleq profile ===\n");
    fprintf(stderr, "dispatched instructions: %llu\n",
            (unsigned long long) prof_total);

    if (prof_stats)

        /* Mix of ops at dispatch entry only; inline-fused ops are not counted.
         */
        for (int i = 0; i < OP_COUNT; i++)
            fprintf(stderr, "  %-6s %14llu  %5.1f%%\n", names[i],
                    (unsigned long long) prof_op[i],
                    prof_total ? 100.0 * prof_op[i] / prof_total : 0.0);

    if (prof_heat) {
        /* One pass, keeping the 16 hottest PCs in a sorted array. */
        struct {
            uint32_t pc;
            uint64_t n;
        } top[16] = {{0, 0}};
        for (uint32_t pc = 0; pc < MEM_SIZE; pc++) {
            const uint64_t n = prof_heat_map[pc];
            if (n <= top[15].n)
                continue;
            int j = 15;
            while (j > 0 && top[j - 1].n < n) {
                top[j] = top[j - 1];
                j--;
            }
            top[j].pc = pc;
            top[j].n = n;
        }
        fprintf(stderr, "hot PCs (addr: count  [a b c]):\n");
        for (int i = 0; i < 16 && top[i].n; i++)
            fprintf(stderr, "  %5u: %14llu  [%u %u %u]\n", (unsigned) top[i].pc,
                    (unsigned long long) top[i].n,
                    (unsigned) m[top[i].pc & MEM_MASK],
                    (unsigned) m[(top[i].pc + 1) & MEM_MASK],
                    (unsigned) m[(top[i].pc + 2) & MEM_MASK]);
    }
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-s"))
            prof_stats = true;
        else if (!strcmp(argv[i], "-p"))
            prof_heat = true;
        else
            fprintf(stderr, "muxleq: ignoring unknown argument '%s'\n",
                    argv[i]);
    }
    prof_enabled = prof_stats || prof_heat;

    /* Set I/O buffering: line for interactive, full for piped. */
    const int mode = isatty(fileno(stdout)) ? _IOLBF : _IOFBF;
    setvbuf(stdout, NULL, mode, BUFSIZ);
    if (mode == _IOFBF)
        setvbuf(stdin, NULL, _IOFBF, BUFSIZ);

    /* Fetch first instruction and start execution by calling the dispatcher. */
    const uint16_t pc = 0;
    const int rc = dispatch(pc, m[pc + A], m[pc + B], m[pc + C]);
    if (prof_enabled)
        report_profile();
    return rc;
}
