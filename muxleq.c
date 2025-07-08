/*
 * A MUXLEQ virtual machine implementation.
 *
 * This program executes a two-instruction (SUBLEQ and MUX) program from a
 * static memory array. It supports standard input/output and halts when the
 * program counter moves to a negative address.
 */

#include <stdint.h>
#include <stdio.h>

/* branch predictor hints */
#if defined(__GNUC__) || defined(__clang__)
#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
#define LIKELY(x) (x)
#define UNLIKELY(x) (x)
#endif

/* Define memory and instruction layout constants. */
#define MEM_SIZE (1 << 15)
#define MEM_MASK (MEM_SIZE - 1)
#define IO_MARKER ((uint16_t) -1) /* More idiomatic way to express all 1s. */
#define NEGATIVE_FLAG MEM_SIZE

/* Instruction operand offsets. */
enum { A = 0, B = 1, C = 2, INSN_SIZE = 3 };

/* The memory of the virtual machine, initialized from an external file. */
static uint16_t m[MEM_SIZE] = {
#include "stage0.c"
};

int main(void)
{
    /* Disable buffering for stdout to ensure immediate output */
    if (setvbuf(stdout, NULL, _IONBF, 0) != 0)
        return 1; /* Non-zero return indicates failure */

    uint16_t pc = 0;
    /* Loop until PC becomes negative. */
    while (LIKELY((pc & NEGATIVE_FLAG) == 0)) {
        /* Fetch instruction operands from memory. */
        const uint16_t addr_a = m[pc + A];
        const uint16_t addr_b = m[pc + B];
        const uint16_t addr_c = m[pc + C];

        /* Handle I/O as a special case. */
        if (UNLIKELY(addr_a == IO_MARKER)) { /* Input */
            const int input = getchar();
            if (input == EOF)
                break; /* Halt on End-of-File. */

            m[addr_b] = (uint16_t) input;
            pc += INSN_SIZE;
            continue;
        }

        if (UNLIKELY(addr_b == IO_MARKER)) { /* Output */
            if (putchar(m[addr_a]) == EOF)
                return 3; /* Halt on output error. */

            pc += INSN_SIZE;
            continue;
        }

        /* Check for MUX operation, encoded in a negative 'c' address. */
        if (UNLIKELY((addr_c & NEGATIVE_FLAG) && (addr_c != IO_MARKER))) {
            const uint16_t mask = m[addr_c & MEM_MASK];
            m[addr_b] = (m[addr_a] & ~mask) | (m[addr_b] & mask);
            pc += INSN_SIZE;
        } else {
            /* Default to SUBLEQ operation. */
            const uint16_t result = m[addr_b] - m[addr_a];
            m[addr_b] = result;
            if ((result == 0) || (result & NEGATIVE_FLAG)) {
                pc = addr_c; /* Branch if result is zero or negative. */
            } else {
                pc += INSN_SIZE;
            }
        }
    }

    return 0;
}
