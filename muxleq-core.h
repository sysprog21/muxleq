/*
 * MUXLEQ core: the instruction encoding, and the interpreter that runs it.
 *
 * There are two kinds of consumer here, and an includer selects which one it is
 * by what it defines beforehand:
 *
 *   Include it bare and you get the encoding alone: the operand markers, the
 *   reserved mask addresses, and is_mux(). rvopt.c does this. A translator has
 *   to spell the very cells the VM decodes, so the two must agree on what a
 *   MOVE looks like; before this they agreed by both hardcoding 0x80000006,
 *   which is one copy too many of a number that can only ever change in both
 *   places at once.
 *
 *   Define MUX_GETC and MUX_PUTC and you additionally get the interpreter,
 *   shared verbatim by the native VM (muxleq.c) and the WebAssembly build
 *   (wasm/muxleq-wasm.c) so the self-modifying-code semantics have exactly one
 *   implementation. Those two hosts differ only in how they move bytes and in
 *   whether the interpreter is allowed to suspend, which is what the macros
 *   express. Including bare first and asking for the interpreter later works:
 *   the two sections carry separate guards, so the order does not matter, and
 *   defining only one of the two is a diagnosed error rather than a puzzle:
 *
 *   MUX_GETC()          int: next input byte, MUX_EOF once input is finished,
 *                       or MUX_WOULD_BLOCK when no byte is available yet and
 *                       the host wants to be resumed later.
 *   MUX_PUTC(v)         int: 0 on success, any other value to stop with that
 *                       value as the run status. That value is returned as-is,
 *                       so it must not collide with MUX_YIELD or MUX_NEED_INPUT
 *                       or the caller will read a failure as a suspension.
 *   MUX_OUT_OF_BUDGET() optional, but if you want it you must define it BEFORE
 *                       the include that brings in the interpreter: this header
 *                       defaults it to a constant 0, so defining it afterwards
 *                       earns a redefinition warning and a budget check that
 *                       silently compiled away to nothing, which on a browser
 *                       host is a slice that never yields. Evaluated once per
 *                       step, where the fused MOVE-plus-ALU pair below counts
 *                       as one step. A host that cannot block defines it to end
 *                       the slice so the event loop gets a turn; the native VM
 *                       leaves it at 0, where it compiles away entirely. The
 *                       slice is a responsiveness knob, not an instruction
 *                       count: callers size it by how long a turn took.
 *
 * A suspended run resumes by calling mux_exec() again with the same state: the
 * pc is only committed between instructions, so no instruction is ever half
 * executed across a yield.
 */

#ifndef MUXLEQ_CORE_H
#define MUXLEQ_CORE_H

#include <stdbool.h>
#include <stdint.h>

#if defined(__GNUC__) || defined(__clang__)
#define MUX_UNUSED __attribute__((unused))
#define MUX_UNLIKELY(x) __builtin_expect(!!(x), 0)

/* Spelled as an attribute rather than C11's _Noreturn: this builds as C99. It
 * earns its keep beyond documentation, since without it a checker has to assume
 * a failed guard falls through into the very use the guard exists to prevent.
 */
#define MUX_NORETURN __attribute__((noreturn))
#else
#define MUX_UNUSED
#define MUX_UNLIKELY(x) (x)
#define MUX_NORETURN
#endif

/* Cell 6 is hardwired to 0, so a MUX whose mask address is 6 masks against zero
 * and is therefore a pure MOVE.
 */
#define ZERO_MASK_ADDR 6u

#define IO_MARKER32 0xFFFFFFFFu
#define NEG_FLAG32 0x80000000u
#define ADDR_MASK32 0x7FFFFFFFu

/* A MUX whose mask address is this reserved (never-a-real-cell) value is a
 * native shift-right-by-one: [b] = [a] >> 1. Kept in sync with the SHR1 word in
 * forth/20-target-vm.fth, whose emitted mask cell (0xFFFFFFFE) masks to this
 * address; the eForth shift primitive uses it so a right shift costs one op per
 * bit instead of a full-cell-width bit loop.
 */
#define SHR1_MARK_ADDR 0x7FFFFFFEu

enum { A = 0, B = 1, C = 2, INSN_SIZE = 3 };

/* A negative c selects MUX over SUBLEQ, but c == IO_MARKER32 is a SUBLEQ jump
 * target, not a MUX, so that value must fall through. The guard is load-bearing
 * and shared by exec_alu() and mux_exec()'s MOVE gate; keep them in sync here.
 */
static inline bool is_mux(uint32_t c)
{
    return (c & NEG_FLAG32) && c != IO_MARKER32;
}

/* The c cell of a MOVE: a MUX masking against the hardwired zero at cell 6.
 *
 * The interpreter never reads this. It decomposes a cell with is_mux() and a
 * mask-address compare, so the two agree not because anything checks them but
 * because both are built from NEG_FLAG32 and ZERO_MASK_ADDR right here. That is
 * the whole point of the constant: an emitter that spelled 0x80000006 by hand
 * could drift from the interpreter, and one built from these two cannot. There
 * is nothing to assert, since any assertion would be phrased in the same two
 * constants and could not fail.
 */
#define MUX_MOVE_C (NEG_FLAG32 | ZERO_MASK_ADDR)

/* Compile-time assertion. A negative array bound rather than C11's
 * _Static_assert because this builds as C99; the name is what the compiler
 * prints, so it should read as the claim being made.
 */
#define MUX_STATIC_ASSERT(name, cond) typedef char name[(cond) ? 1 : -1]

/* Editor terminal-mode control: out-of-band values the modal editor writes down
 * the ordinary output path for the host to intercept rather than print. This is
 * a protocol between the image and whatever is hosting it, so every host has to
 * agree on the numbers, which is why they live here and not in one of them.
 * Kept in sync with the raw-on/raw-off/peek words in
 * forth/65-optional-editor.fth, the one copy a compiler cannot check.
 *
 * A host with no terminal (the browser) ignores the two mode switches; only the
 * peek has to mean something everywhere, because the image branches on its
 * answer. EDIT_PEEK_NONE is that answer when no key is waiting, and it is
 * deliberately outside the byte range so it cannot collide with a real key.
 */
#define EDIT_RAW_ON 0xFF01u
#define EDIT_RAW_OFF 0xFF00u
#define EDIT_PEEK 0xFF02u
#define EDIT_PEEK_NONE 0x100u


#endif /* MUXLEQ_CORE_H */

/* Everything above is the encoding, and a consumer that only needs to spell or
 * classify cells stops there. The interpreter below has to put an input byte
 * somewhere and send an output byte somewhere, so it exists only once a host
 * has said where.
 *
 * The two sections carry separate guards, and this one sits OUTSIDE the file
 * guard above on purpose. A translation unit is entitled to pick up the
 * encoding first, by way of some other header, and ask for the interpreter
 * afterwards; under a single file-wide guard that second include would expand
 * to nothing and the caller would get "incomplete type 'struct mux_state'"
 * pointing nowhere near the actual mistake.
 */
#if defined(MUX_GETC) != defined(MUX_PUTC)
#error "muxleq-core.h: define both MUX_GETC and MUX_PUTC, or neither"
#endif

#if defined(MUX_GETC) && defined(MUX_PUTC) && !defined(MUXLEQ_CORE_INTERP_H)
#define MUXLEQ_CORE_INTERP_H

/* Run status. MUX_OK and MUX_ERR_OUTPUT double as the native process exit code,
 * so their values are part of the CLI contract. The two yields are only ever
 * produced by a host that defines MUX_OUT_OF_BUDGET or returns MUX_WOULD_BLOCK.
 */
enum {
    MUX_OK = 0,         /* halted: pc went negative, or input ran out */
    MUX_ERR_OUTPUT = 3, /* host write failed */
    MUX_YIELD = 4,      /* slice spent, resumable */
    MUX_NEED_INPUT = 5, /* no input available, resumable */
};

#define MUX_EOF (-1)
#define MUX_WOULD_BLOCK (-2)

#ifndef MUX_OUT_OF_BUDGET
#define MUX_OUT_OF_BUDGET() 0
#endif

struct mux_state {
    uint32_t *m;
    uint32_t mask;
    uint32_t pc;
};

/* Execute one non-I/O instruction (a, b, c) and return the next pc. A MOVE
 * (mask address ZERO_MASK_ADDR) skips the general mask formula's dead read of
 * the destination; SHR1 is the reserved native right-shift; everything else is
 * a mask MUX or a SUBLEQ. The caller has already ruled out I/O.
 */
static inline uint32_t exec_alu(uint32_t *m32,
                                uint32_t mask32,
                                uint32_t a,
                                uint32_t b,
                                uint32_t c,
                                uint32_t pc)
{
    if (is_mux(c)) {
        const uint32_t maddr = c & ADDR_MASK32;
        if (maddr == ZERO_MASK_ADDR) { /* the common case: a MOVE */
            m32[b & mask32] = m32[a & mask32];
        } else if (maddr == SHR1_MARK_ADDR) {
            m32[b & mask32] = m32[a & mask32] >> 1;
        } else {
            const uint32_t mask = m32[maddr & mask32];
            m32[b & mask32] =
                (m32[a & mask32] & ~mask) | (m32[b & mask32] & mask);
        }
        return pc + INSN_SIZE;
    }

    const uint32_t r = m32[b & mask32] - m32[a & mask32];
    m32[b & mask32] = r;
    return (r == 0 || (r & NEG_FLAG32)) ? c : pc + INSN_SIZE;
}

/* Interpret from st->pc until the image halts, the host fails a write, input
 * blocks, or the slice runs out. st->pc is left where execution stopped, so a
 * yield is resumed by calling again.
 */
static inline int mux_exec(struct mux_state *st)
{
    uint32_t *m32 = st->m;
    const uint32_t mask32 = st->mask;
    uint32_t pc = st->pc;
    int rc;

    for (;;) {
        if (MUX_UNLIKELY(MUX_OUT_OF_BUDGET())) {
            rc = MUX_YIELD;
            break;
        }
        if (MUX_UNLIKELY(pc & NEG_FLAG32)) {
            rc = MUX_OK;
            break;
        }

        const uint32_t a = m32[pc & mask32];
        const uint32_t b = m32[(pc + B) & mask32];
        const uint32_t c = m32[(pc + C) & mask32];
        if (a == IO_MARKER32) {
            const int in = MUX_GETC();

            /* Leave pc on the read so the resumed run retries it; nothing has
             * been stored yet, so the retry is exact.
             */
            if (MUX_UNLIKELY(in == MUX_WOULD_BLOCK)) {
                rc = MUX_NEED_INPUT;
                break;
            }
            if (MUX_UNLIKELY(in == MUX_EOF)) {
                rc = MUX_OK;
                break;
            }
            m32[b & mask32] = (uint32_t) in;
            pc += INSN_SIZE;
        } else if (b == IO_MARKER32) {
            const int wrc = MUX_PUTC(m32[a & mask32]);
            if (MUX_UNLIKELY(wrc)) {
                rc = wrc;
                break;
            }
            pc += INSN_SIZE;
        } else if (is_mux(c) && (c & ADDR_MASK32) == ZERO_MASK_ADDR) {
            /* A MOVE. eForth fakes SUBLEQ's missing indirection by MOVEing a
             * live address into an operand field of the very next instruction,
             * then executing it. Fuse the pair: do the MOVE's store, then run
             * that next instruction here, forwarding the just-written field
             * from a register instead of storing it and reloading it through
             * the store-to-load stall. The store still happens, so state stays
             * byte-identical to running the two instructions in sequence; only
             * the reload is elided.
             *
             * Measured against a build with this branch disabled, over sieve,
             * crc, fibonacci and chacha20: MOVEs are ~43% of interpreter
             * iterations and the fusion fires on ~29% of them, about two thirds
             * of the MOVEs, worth 1.07x to 1.32x of wall clock depending on the
             * program. Both builds emit byte-identical output, which is the
             * check that keeps the operand forwarding honest.
             */
            const uint32_t d = b & mask32, va = m32[a & mask32];
            m32[d] = va;

            /* pc is unmasked (bit 31 is the halt flag); only memory accesses
             * mask. Fuse only when the store hit an operand slot of the next
             * word and that word is not the halt boundary.
             */
            const uint32_t next_pc = pc + INSN_SIZE;

            /* np is the masked next pc and, since A == 0, also its a-field
             * addr. (d - np) & mask32 is d's distance from np mod size, so <
             * INSN_SIZE means the MOVE's store landed on one of the next word's
             * 3 fields.
             */
            const uint32_t np = next_pc & mask32;
            if (!(next_pc & NEG_FLAG32) && ((d - np) & mask32) < INSN_SIZE) {
                const uint32_t nbs = (np + B) & mask32, ncs = (np + C) & mask32;
                const uint32_t na = d == np ? va : m32[np];
                const uint32_t nb = d == nbs ? va : m32[nbs];
                const uint32_t nc = d == ncs ? va : m32[ncs];
                if (na != IO_MARKER32 && nb != IO_MARKER32) {
                    pc = exec_alu(m32, mask32, na, nb, nc, next_pc);
                    continue;
                }
            }
            pc = next_pc;
        } else {
            pc = exec_alu(m32, mask32, a, b, c, pc);
        }
    }

    st->pc = pc;
    return rc;
}

#endif /* MUX_GETC && MUX_PUTC && !MUXLEQ_CORE_INTERP_H */
