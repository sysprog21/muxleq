/*
 * A MUXLEQ virtual machine implementation.
 *
 * This program executes a two-instruction (SUBLEQ and MUX) program from a
 * static memory array. It supports standard input/output and halts when the
 * program counter moves to a negative address.
 */

#include <stdint.h>
#include <stdio.h>

/* Tail-call optimization attribute */
#if defined(__has_attribute) && __has_attribute(musttail)
#define MUST_TAIL __attribute__((musttail))
#else
#define MUST_TAIL
#endif

/* Unused parameter attribute to suppress compiler warnings */
#if defined(__GNUC__) || defined(__clang__)
#define UNUSED __attribute__((unused))
#else
#define UNUSED
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
#define FETCH_AND_DISPATCH(next_pc)                  \
    do {                                             \
        const uint16_t a = m[(next_pc) + A];         \
        const uint16_t b = m[(next_pc) + B];         \
        const uint16_t c = m[(next_pc) + C];         \
        MUST_TAIL return dispatch(next_pc, a, b, c); \
    } while (0)

static int get(uint16_t pc,
               UNUSED uint16_t addr_a,
               uint16_t addr_b,
               UNUSED uint16_t addr_c)
{
    const int input = getchar();
    if (input == EOF)
        return 0; /* Halt on End-of-File. */

    m[addr_b] = (uint16_t) input;
    FETCH_AND_DISPATCH(pc + INSN_SIZE);
}

static int put(uint16_t pc,
               uint16_t addr_a,
               UNUSED uint16_t addr_b,
               UNUSED uint16_t addr_c)
{
    if (putchar(m[addr_a]) == EOF)
        return 3; /* Halt on output error. */

    FETCH_AND_DISPATCH(pc + INSN_SIZE);
}

static int mux(uint16_t pc, uint16_t addr_a, uint16_t addr_b, uint16_t addr_c)
{
    const uint16_t mask = m[addr_c & MEM_MASK];
    m[addr_b] = (m[addr_a] & ~mask) | (m[addr_b] & mask);
    FETCH_AND_DISPATCH(pc + INSN_SIZE);
}

static int subleq(uint16_t pc,
                  uint16_t addr_a,
                  uint16_t addr_b,
                  uint16_t addr_c)
{
    const uint16_t result = m[addr_b] - m[addr_a];
    m[addr_b] = result;
    if ((result == 0) || (result & NEGATIVE_FLAG)) {
        FETCH_AND_DISPATCH(addr_c); /* Branch */
    } else {
        FETCH_AND_DISPATCH(pc + INSN_SIZE);
    }
}

static int dispatch(uint16_t pc,
                    uint16_t addr_a,
                    uint16_t addr_b,
                    uint16_t addr_c)
{
    /* Halt if the program counter becomes negative. */
    if ((pc & NEGATIVE_FLAG) != 0)
        return 0;

    /* Dispatch to the appropriate handler based on the operand values. */
    if (addr_a == IO_MARKER) /* Input */
        MUST_TAIL return get(pc, addr_a, addr_b, addr_c);

    if (addr_b == IO_MARKER) /* Output */
        MUST_TAIL return put(pc, addr_a, addr_b, addr_c);

    if ((addr_c & NEGATIVE_FLAG) && (addr_c != IO_MARKER)) /* MUX */
        MUST_TAIL return mux(pc, addr_a, addr_b, addr_c);

    /* Default to SUBLEQ operation. */
    MUST_TAIL return subleq(pc, addr_a, addr_b, addr_c);
}

int main(void)
{
    /* Disable buffering for stdout to ensure immediate output */
    if (setvbuf(stdout, NULL, _IONBF, 0) != 0)
        return 1; /* Non-zero return indicates failure */

    /* Fetch first instruction and start execution by calling the dispatcher. */
    const uint16_t pc = 0;
    const uint16_t addr_a = m[pc + A];
    const uint16_t addr_b = m[pc + B];
    const uint16_t addr_c = m[pc + C];
    return dispatch(pc, addr_a, addr_b, addr_c);
}
