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
#include "stage0.c"
};

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
         * manipulation) */
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

/*
 * SUBLEQ with extended fusion for Forth patterns
 */
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

int main(void)
{
    /* Set I/O buffering: line for interactive, full for piped. */
    const int mode = isatty(fileno(stdout)) ? _IOLBF : _IOFBF;
    setvbuf(stdout, NULL, mode, BUFSIZ);
    if (mode == _IOFBF)
        setvbuf(stdin, NULL, _IOFBF, BUFSIZ);

    /* Fetch first instruction and start execution by calling the dispatcher. */
    const uint16_t pc = 0;
    const uint16_t addr_a = m[pc + A];
    const uint16_t addr_b = m[pc + B];
    const uint16_t addr_c = m[pc + C];
    return dispatch(pc, addr_a, addr_b, addr_c);
}
