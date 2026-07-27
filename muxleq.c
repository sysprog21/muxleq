/*
 * MUXLEQ virtual machine.
 *
 * This program executes a two-instruction (SUBLEQ and MUX) program from a
 * static memory array. It supports standard input/output and halts when the
 * program counter moves to a negative address.
 */

/* isatty()/fileno() are POSIX; request them under a strict -std=c99 on glibc
 * (macOS exposes them regardless, so this only matters when building on Linux).
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#ifndef ENABLE_RV32I
#define ENABLE_RV32I 1
#endif

/* Tail-call optimization attribute */
#if defined(__has_attribute) && __has_attribute(musttail)
#define MUST_TAIL __attribute__((musttail))
#else
#define MUST_TAIL
#endif

/* preserve_none + musttail miscompiles under ASan on current clang (a SEGV in
 * the dispatch chain), so drop the attribute in sanitizer builds; release keeps
 * it. See make sanitize.
 */
#if defined(__clang__) && defined(__has_attribute) &&                \
    __has_attribute(preserve_none) &&                                \
    !(defined(__has_feature) && __has_feature(address_sanitizer)) && \
    !defined(__SANITIZE_ADDRESS__)
#define VM_ABI __attribute__((preserve_none))
#else
#define VM_ABI
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

/* Cell 6 is hardwired to 0, so a MUX whose mask address is 6 masks against zero
 * and is therefore a pure MOVE. Both the 16-bit and wide VMs and the RV32I MOVE
 * encoding (RV32I_MOVE_C) share this convention.
 */
#define ZERO_MASK_ADDR 6

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
static bool prof_enabled = false;      /* -s or -p given */
static bool prof_stats = false;        /* -s: instruction mix */
static bool prof_heat = false;         /* -p: PC heat map */
static bool validate_operands = false; /* -x image: reject malformed a/b */
static uint64_t prof_total = 0;
static uint64_t prof_op[OP_COUNT] = {0};
static uint64_t prof_heat_map[MEM_SIZE];

/* Classify a cell by its operands into GET/PUT/MUX/SUBLEQ. Single source of
 * truth for the opcode class (stable under the image's operand self-
 * modification); used by the fusion predicates and the profiler. The hot
 * dispatch below open-codes the same decision with explicit branch hints, so
 * keep the two in sync.
 */
static inline uint8_t classify(uint16_t a, uint16_t b, uint16_t c)
{
    if (a == IO_MARKER)
        return OP_GET;
    if (b == IO_MARKER)
        return OP_PUT;
    if ((c & NEGATIVE_FLAG) && (c != IO_MARKER))
        return OP_MUX;
    return OP_SUBLEQ;
}

/* Forward declarations for the mutually recursive VM functions. */
static VM_ABI int dispatch(uint16_t pc,
                           uint16_t addr_a,
                           uint16_t addr_b,
                           uint16_t addr_c);

static inline bool can_fetch_instruction(uint16_t pc)
{
    return pc <= MEM_SIZE - INSN_SIZE;
}

static inline bool is_memory_addr(uint16_t addr)
{
    return addr < MEM_SIZE;
}

static int reject_bad_operand(uint16_t pc, const char *operand, uint16_t addr)
{
    fprintf(stderr, "muxleq: bad operand %s=%u at pc %u\n", operand,
            (unsigned) addr, (unsigned) pc);
    return 1;
}

static int validate_memory_operands(uint16_t pc,
                                    uint16_t addr_a,
                                    uint16_t addr_b)
{
    if (addr_a == IO_MARKER) {
        if (UNLIKELY(!is_memory_addr(addr_b)))
            return reject_bad_operand(pc, "b", addr_b);
    } else if (addr_b == IO_MARKER) {
        if (UNLIKELY(!is_memory_addr(addr_a)))
            return reject_bad_operand(pc, "a", addr_a);
    } else if (UNLIKELY(!is_memory_addr(addr_a))) {
        return reject_bad_operand(pc, "a", addr_a);
    } else if (UNLIKELY(!is_memory_addr(addr_b))) {
        return reject_bad_operand(pc, "b", addr_b);
    }
    return 0;
}

#define VALIDATE_OPERANDS_OR_RETURN(pc, addr_a, addr_b)             \
    do {                                                            \
        if (UNLIKELY(validate_operands)) {                          \
            const int rc__ =                                        \
                validate_memory_operands((pc), (addr_a), (addr_b)); \
            if (UNLIKELY(rc__ != 0))                                \
                return rc__;                                        \
        }                                                           \
    } while (0)

/* Load an instruction's three operand cells into fresh consts. The caller must
 * have verified the slot is addressable (can_fetch_instruction) first.
 */
#define LOAD_OPERANDS(base, va, vb, vc) \
    const uint16_t va = m[(base) + A];  \
    const uint16_t vb = m[(base) + B];  \
    const uint16_t vc = m[(base) + C]

/* Fetch the next instruction's operands and tail-call dispatch. A pc above the
 * last full instruction slot includes the MUXLEQ halt / negative-branch marker
 * (e.g. a 0xFFFF exit target) and the final one/two cells of memory; halt
 * BEFORE the loads so m[pc + A..C] never reads past the 32768-cell array.
 * dispatch() also halts on an invalid pc by returning 0, and it discards the
 * fetched operands in that case, so returning 0 here is byte-for-byte identical
 * behavior without the OOB read.
 */
#define FETCH_AND_DISPATCH(next_pc)                 \
    do {                                            \
        const uint16_t fpc = (next_pc);             \
        if (UNLIKELY(!can_fetch_instruction(fpc)))  \
            return 0;                               \
        LOAD_OPERANDS(fpc, fa, fb, fc);             \
        MUST_TAIL return dispatch(fpc, fa, fb, fc); \
    } while (0)

/* A move is a MUX whose mask is zero (address 6 is hardwired 0). */
static bool is_move_instruction(uint16_t a, uint16_t b, uint16_t c)
{
    if (classify(a, b, c) != OP_MUX)
        return false;
    const uint16_t mask_addr = c & MEM_MASK;
    return (mask_addr == ZERO_MASK_ADDR) || (m[mask_addr] == 0);
}

static bool is_subleq_instruction(uint16_t a, uint16_t b, uint16_t c)
{
    return classify(a, b, c) == OP_SUBLEQ;
}

#if ENABLE_RV32I
static void rv32i_store_invalidates_hot_trace(uint16_t addr);
static void rv32i_disable(void);
#else
static inline void rv32i_store_invalidates_hot_trace(UNUSED uint16_t addr) {}

static inline void rv32i_disable(void) {}
#endif

static inline void store_cell(uint16_t addr, uint16_t value)
{
    /* On a non-'-r' run the hot-trace set is empty; the invalidation check
     * short-circuits on its disabled flag, so this stays a predicted-not-taken
     * branch on the common path.
     */
    rv32i_store_invalidates_hot_trace(addr);
    m[addr] = value;
}

static inline void raw_store_cell(uint16_t addr, uint16_t value)
{
    m[addr] = value;
}

static inline uint16_t UNUSED raw_subleq_cell(uint16_t addr_a, uint16_t addr_b)
{
    const uint16_t result = (uint16_t) (m[addr_b] - m[addr_a]);
    raw_store_cell(addr_b, result);
    return result;
}

#define EXEC_MOVE(a, b) store_cell(b, m[(a)])
#define EXEC_SUBLEQ(a, b, result)                         \
    const uint16_t result = (uint16_t) (m[(b)] - m[(a)]); \
    store_cell(b, result)
#define EXEC_SUBLEQ_DROP(a, b) store_cell(b, (uint16_t) (m[(b)] - m[(a)]))
#define EXEC_RAW_MOVE(a, b) raw_store_cell(b, m[(a)])
#define EXEC_RAW_SUBLEQ(a, b, result)                     \
    const uint16_t result = (uint16_t) (m[(b)] - m[(a)]); \
    raw_store_cell(b, result)
#define EXEC_RAW_SUBLEQ_DROP(a, b) \
    raw_store_cell(b, (uint16_t) (m[(b)] - m[(a)]))
#define SUBLEQ_BRANCHES(result) ((result) == 0 || ((result) & NEGATIVE_FLAG))

/* Optional prefix input fed before real stdin: -r synthesizes an RV32I loader
 * here.
 */
static const char *prefix_in = NULL;
static size_t prefix_len = 0, prefix_pos = 0;

static VM_ABI int get(uint16_t pc,
                      UNUSED uint16_t addr_a,
                      uint16_t addr_b,
                      UNUSED uint16_t addr_c)
{
    const int input = prefix_pos < prefix_len
                          ? (unsigned char) prefix_in[prefix_pos++]
                          : getchar();
    if (UNLIKELY(input == EOF))
        return 0; /* Halt on End-of-File. */

    store_cell(addr_b, (uint16_t) input);
    FETCH_AND_DISPATCH(pc + INSN_SIZE);
}

static VM_ABI int put(uint16_t pc,
                      uint16_t addr_a,
                      UNUSED uint16_t addr_b,
                      UNUSED uint16_t addr_c)
{
    if (UNLIKELY(putchar(m[addr_a]) == EOF))
        return 3; /* Halt on output error. */

    FETCH_AND_DISPATCH(pc + INSN_SIZE);
}

/* MUX with extended fusion for Forth inner interpreter patterns */
static VM_ABI int mux(uint16_t pc,
                      uint16_t addr_a,
                      uint16_t addr_b,
                      uint16_t addr_c)
{
    const uint16_t mask_addr = addr_c & MEM_MASK;

    if (LIKELY(mask_addr == ZERO_MASK_ADDR)) {
        /* Address 6 is always 0 - pure move (99.7% of MUX operations) */
        store_cell(addr_b, m[addr_a]);
    } else {
        const uint16_t mask = m[mask_addr];
        if (UNLIKELY(mask == 0)) {
            store_cell(addr_b, m[addr_a]);
        } else {
            store_cell(addr_b, (m[addr_a] & ~mask) | (m[addr_b] & mask));
        }
    }

    /* Look ahead for fusion opportunities after MUX */
    const uint16_t next_pc = pc + INSN_SIZE;
    if (UNLIKELY(!can_fetch_instruction(next_pc)))
        return 0;

    LOAD_OPERANDS(next_pc, next_a, next_b, next_c);
    VALIDATE_OPERANDS_OR_RETURN(next_pc, next_a, next_b);

    /* Pattern 1: MUX + SUBLEQ */
    if (is_subleq_instruction(next_a, next_b, next_c)) {
        EXEC_SUBLEQ(next_a, next_b, result);

        if (UNLIKELY(SUBLEQ_BRANCHES(result))) {
            FETCH_AND_DISPATCH(next_c);
        } else {
            /* Extend to 3-instruction fusion for common Forth patterns */
            const uint16_t third_pc = next_pc + INSN_SIZE;
            if (LIKELY(can_fetch_instruction(third_pc))) {
                LOAD_OPERANDS(third_pc, third_a, third_b, third_c);
                VALIDATE_OPERANDS_OR_RETURN(third_pc, third_a, third_b);

                /* MUX + SUBLEQ + MOVE (common: load, operate, store) */
                if (is_move_instruction(third_a, third_b, third_c)) {
                    EXEC_MOVE(third_a, third_b);
                    FETCH_AND_DISPATCH(third_pc + INSN_SIZE);
                } else {
                    FETCH_AND_DISPATCH(third_pc);
                }
            } else {
                FETCH_AND_DISPATCH(third_pc);
            }
        }
    }
    /* Pattern 2: MUX + MOVE */
    else if (is_move_instruction(next_a, next_b, next_c)) {
        EXEC_MOVE(next_a, next_b);

        /* Try to extend: MUX + MOVE + SUBLEQ (common in Forth stack
         * manipulation)
         */
        const uint16_t third_pc = next_pc + INSN_SIZE;
        if (LIKELY(can_fetch_instruction(third_pc))) {
            LOAD_OPERANDS(third_pc, third_a, third_b, third_c);
            VALIDATE_OPERANDS_OR_RETURN(third_pc, third_a, third_b);

            if (is_subleq_instruction(third_a, third_b, third_c)) {
                EXEC_SUBLEQ(third_a, third_b, result);

                if (UNLIKELY(SUBLEQ_BRANCHES(result))) {
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
static VM_ABI int subleq(uint16_t pc,
                         uint16_t addr_a,
                         uint16_t addr_b,
                         uint16_t addr_c)
{
    EXEC_SUBLEQ(addr_a, addr_b, result);

    const uint16_t next_pc = pc + INSN_SIZE;
    if (UNLIKELY(SUBLEQ_BRANCHES(result) && addr_c != next_pc)) {
        FETCH_AND_DISPATCH(addr_c); /* Branch taken, cannot fuse. */
    } else {
        /* No branch - look for fusion opportunities */
        if (UNLIKELY(!can_fetch_instruction(next_pc)))
            return 0;

        LOAD_OPERANDS(next_pc, next_a, next_b, next_c);
        VALIDATE_OPERANDS_OR_RETURN(next_pc, next_a, next_b);

        /* Pattern 1: SUBLEQ + SUBLEQ */
        if (is_subleq_instruction(next_a, next_b, next_c)) {
            EXEC_SUBLEQ(next_a, next_b, result2);

            if (UNLIKELY(SUBLEQ_BRANCHES(result2))) {
                FETCH_AND_DISPATCH(next_c);
            } else {
                /* Try to extend: SUBLEQ + SUBLEQ + MOVE (arithmetic + cleanup)
                 */
                const uint16_t third_pc = next_pc + INSN_SIZE;
                if (LIKELY(can_fetch_instruction(third_pc))) {
                    LOAD_OPERANDS(third_pc, third_a, third_b, third_c);
                    VALIDATE_OPERANDS_OR_RETURN(third_pc, third_a, third_b);

                    if (is_move_instruction(third_a, third_b, third_c)) {
                        EXEC_MOVE(third_a, third_b);
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
            EXEC_MOVE(next_a, next_b);
            const uint16_t third_pc = next_pc + INSN_SIZE;
            if (LIKELY(can_fetch_instruction(third_pc))) {
                LOAD_OPERANDS(third_pc, third_a, third_b, third_c);
                VALIDATE_OPERANDS_OR_RETURN(third_pc, third_a, third_b);

                if (is_subleq_instruction(third_a, third_b, third_c)) {
                    EXEC_SUBLEQ(third_a, third_b, result2);
                    if (UNLIKELY(SUBLEQ_BRANCHES(result2)))
                        FETCH_AND_DISPATCH(third_c);
                    else
                        FETCH_AND_DISPATCH(third_pc + INSN_SIZE);
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
}

#if ENABLE_RV32I
#include "rv32i.inc"
#else
#define RV32I_DISPATCH_HOOK(pc, addr_a, addr_b, addr_c) \
    do {                                                \
    } while (0)

static void load_rv32i(UNUSED const char *path)
{
    fprintf(stderr, "muxleq: RV32I support disabled (ENABLE_RV32I=0)\n");
    exit(1);
}
#endif

static VM_ABI int dispatch(uint16_t pc,
                           uint16_t addr_a,
                           uint16_t addr_b,
                           uint16_t addr_c)
{
    /* Halt if the program counter cannot address a full instruction. */
    if (UNLIKELY(!can_fetch_instruction(pc)))
        return 0;

    VALIDATE_OPERANDS_OR_RETURN(pc, addr_a, addr_b);

    if (UNLIKELY(prof_enabled)) {
        prof_total++;
        if (prof_heat)
            prof_heat_map[pc & MEM_MASK]++;
        if (prof_stats)
            prof_op[classify(addr_a, addr_b, addr_c)]++;
    }

    RV32I_DISPATCH_HOOK(pc, addr_a, addr_b, addr_c);

    /* Dispatch to the appropriate handler based on the operand values. */
    if (UNLIKELY(addr_a == IO_MARKER))
        MUST_TAIL return get(pc, addr_a, addr_b, addr_c);

    if (UNLIKELY(addr_b == IO_MARKER))
        MUST_TAIL return put(pc, addr_a, addr_b, addr_c);

    if ((addr_c & NEGATIVE_FLAG) && (addr_c != IO_MARKER))
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

/* -x FILE: load a standalone MUXLEQ image (decimal cells, one per line -- the
 * stage0.dec format) into m[] and run it from pc 0, replacing the baked eForth
 * image. This is how host-emitted native code runs on the two ops with no
 * eForth layer: 'rvopt -mux prog > prog.dec' then './muxleq -x prog.dec'.
 * Untrusted input, so bounds-check like the -r loader: reject an image larger
 * than the cell array or a non-numeric cell; never partially load.
 */
static void load_muxleq(const char *path)
{
    rv32i_disable();
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "muxleq: cannot open '%s'\n", path);
        exit(1);
    }
    memset(m, 0, sizeof m); /* overwrite the baked eForth image */
    validate_operands = true;
    size_t n = 0;

    /* One whitespace-delimited token per cell. Parse with strtol so a token
     * that is non-numeric, out of long range, or outside a 16-bit cell is
     * rejected, not silently wrapped -- this is untrusted input. The %31s width
     * caps the token so a pathological line cannot overflow the buffer.
     */
    for (char tok[32]; fscanf(f, "%31s", tok) == 1;) {
        errno = 0;
        char *end;
        const long v = strtol(tok, &end, 10);
        if (*end != '\0' || errno == ERANGE || v < -32768 || v > 65535) {
            fprintf(stderr, "muxleq: '%s' has a bad cell '%s'\n", path, tok);
            fclose(f);
            exit(1);
        }
        if (n >= MEM_SIZE) {
            fprintf(stderr, "muxleq: '%s' exceeds the %d-cell image\n", path,
                    MEM_SIZE);
            fclose(f);
            exit(1);
        }
        m[n++] = (uint16_t) v;
    }
    const bool io_err = ferror(f);
    fclose(f);
    if (io_err) {
        fprintf(stderr, "muxleq: error reading '%s'\n", path);
        exit(1);
    }
    if (n == 0) {
        fprintf(stderr, "muxleq: '%s' is empty\n", path);
        exit(1);
    }
}

/* Wide (32-bit-cell) MUXLEQ VM -- the '-x32' runner for rvopt '-mux32' images.
 *
 * A SEPARATE interpreter from the 16-bit machine above: its cells are uint32_t,
 * so the address space is far larger (bigger guest programs than the 15-bit
 * wall allows) and a whole 32-bit RV32I register fits in ONE cell (native
 * 32-bit SUBLEQ arithmetic, no lo/hi split). It runs on its OWN heap memory and
 * never touches the baked eForth image in m[], so the self-host bootstrap is
 * unaffected. Deliberately correctness-first: a plain fetch/dispatch loop with
 * no fusion (the fused 16-bit path stays the perf demonstrator).
 *
 * Encoding scales the 16-bit one exactly: the sign/branch bit is 1<<31, the
 * I/O/halt marker is 0xFFFFFFFF, MUX mask-address 6 is hardwired 0, and a MOVE
 * is a MUX with c = (1<<31)|6. The array is a fixed power-of-two window that
 * bounds untrusted input; every index is masked into it (a no-op for the valid
 * < window-size addresses rvopt emits, and OOB-safe for a malformed image).
 */
#define MEM_SIZE32 (1 << 21) /* 2M cells (8 MiB); the wide-image ceiling */
#define IDX32 (MEM_SIZE32 - 1)
#define IO_MARKER32 0xFFFFFFFFu
#define NEG_FLAG32 0x80000000u
#define ADDR_MASK32 \
    0x7FFFFFFFu /* strip the sign bit to get a MUX mask address */

static uint32_t *load_muxleq32(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "muxleq: cannot open '%s'\n", path);
        exit(1);
    }
    uint32_t *m32 = calloc(MEM_SIZE32, sizeof *m32);
    if (!m32) {
        fprintf(stderr, "muxleq: out of memory for the wide image\n");
        exit(1);
    }
    size_t n = 0;

    /* One decimal token per cell (the -mux32 .dec format). strtoll rejects a
     * non-numeric / out-of-32-bit token instead of wrapping -- untrusted input.
     * Signed (-1) and unsigned (4294967295) spellings of a cell both parse.
     */
    for (char tok[32]; fscanf(f, "%31s", tok) == 1;) {
        errno = 0;
        char *end;
        const long long v = strtoll(tok, &end, 10);
        if (*end != '\0' || errno == ERANGE || v < -2147483648LL ||
            v > 4294967295LL) {
            fprintf(stderr, "muxleq: '%s' has a bad cell '%s'\n", path, tok);
            fclose(f);
            free(m32);
            exit(1);
        }
        if (n >= MEM_SIZE32) {
            fprintf(stderr, "muxleq: '%s' exceeds the %d-cell wide image\n",
                    path, MEM_SIZE32);
            fclose(f);
            free(m32);
            exit(1);
        }
        m32[n++] = (uint32_t) v;
    }
    const bool io_err = ferror(f);
    fclose(f);
    if (io_err) {
        fprintf(stderr, "muxleq: read error on '%s'\n", path);
        free(m32);
        exit(1);
    }
    if (n == 0) {
        fprintf(stderr, "muxleq: '%s' is empty\n", path);
        free(m32);
        exit(1);
    }
    return m32;
}

static int run32(uint32_t *m32)
{
    uint32_t pc = 0;
    for (;;) {
        if (UNLIKELY(pc & NEG_FLAG32))
            return 0; /* negative pc: halt (as the 16-bit dispatch does) */
        const uint32_t a = m32[pc & IDX32];
        const uint32_t b = m32[(pc + B) & IDX32];
        const uint32_t c = m32[(pc + C) & IDX32];
        if (a == IO_MARKER32) { /* GET: read one byte into m32[b] */
            const int in = getchar();
            if (UNLIKELY(in == EOF))
                return 0;
            m32[b & IDX32] = (uint32_t) in;
            pc += INSN_SIZE;
        } else if (b == IO_MARKER32) { /* PUT: emit m32[a]'s low byte */
            if (UNLIKELY(putchar((int) (m32[a & IDX32] & 0xFF)) == EOF))
                return 3;
            pc += INSN_SIZE;
        } else if ((c & NEG_FLAG32) && c != IO_MARKER32) { /* MUX */
            const uint32_t maddr = c & ADDR_MASK32;
            const uint32_t mask =
                (maddr == ZERO_MASK_ADDR) ? 0 : m32[maddr & IDX32];
            m32[b & IDX32] = (m32[a & IDX32] & ~mask) | (m32[b & IDX32] & mask);
            pc += INSN_SIZE;
        } else { /* SUBLEQ: m32[b] -= m32[a]; branch to c if signed <= 0 */
            const uint32_t r = m32[b & IDX32] - m32[a & IDX32];
            m32[b & IDX32] = r;
            if (UNLIKELY(r == 0 || (r & NEG_FLAG32)))
                pc = c;
            else
                pc += INSN_SIZE;
        }
    }
}

/* Terminal raw mode for interactive use. eForth's accept/ktap already echo and
 * edit input one character at a time, so the kernel's cooked line discipline
 * fights the image: it double-echoes and buffers a whole line before delivering
 * a byte. Put an interactive tty into cbreak -- ICANON and ECHO off, everything
 * else (ISIG for ^C, ICRNL, OPOST) left intact -- so the image owns echo and
 * sees each keystroke immediately. That is what eForth's reader wants anyway
 * and what a modal editor requires. Non-tty stdin (pipes, the goldens,
 * bootstrap) is never touched, so their byte streams are unchanged.
 */
static struct termios cooked_termios;
static volatile sig_atomic_t raw_mode_active = 0;

static void leave_raw_mode(void)
{
    if (raw_mode_active) {
        raw_mode_active = 0; /* clear first: idempotent under a nested signal */
        tcsetattr(STDIN_FILENO, TCSANOW, &cooked_termios);
    }
}

/* Terminating signal: restore the tty, then die from the same signal. Installed
 * with SA_RESETHAND, so the disposition is already the default when we re-raise
 * (no handler recursion); leave_raw_mode() is idempotent for good measure. Only
 * async-signal-safe calls (tcsetattr, raise) run here.
 */
static void restore_and_reraise(int sig)
{
    leave_raw_mode();
    raise(sig);
}

static void install_restore(int sig)
{
    struct sigaction sa;
    sa.sa_handler = restore_and_reraise;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND; /* one-shot: default disposition on re-raise */
    sigaction(sig, &sa, NULL);
}

/* Returns true iff an interactive tty was switched into raw mode; the caller
 * then owns the matching (unbuffered) stdio buffering. Suspend/resume (^Z) is
 * deliberately NOT handled here -- it belongs to the editor's own input loop,
 * which knows when raw mode is active and can be validated on a real terminal.
 */
static bool enter_raw_mode(void)
{
    if (!isatty(STDIN_FILENO))
        return false;
    if (tcgetattr(STDIN_FILENO, &cooked_termios) != 0)
        return false;
    struct termios raw = cooked_termios;
    raw.c_lflag &= ~(tcflag_t) (ICANON | ECHO);
    raw.c_cc[VMIN] = 1;  /* VMIN drives blocking: a read waits for one byte */
    raw.c_cc[VTIME] = 0; /* no inter-byte timer */
    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0)
        return false;
    raw_mode_active = 1;
    atexit(leave_raw_mode);
    /* Restore on any signal that would otherwise leave the tty in cbreak.
     * SIGQUIT matters because ISIG is kept (^\ terminates); SIGHUP on session
     * loss; SIGSEGV so a crash never wedges the terminal.
     */
    install_restore(SIGINT);
    install_restore(SIGTERM);
    install_restore(SIGQUIT);
    install_restore(SIGHUP);
    install_restore(SIGSEGV);
    return true;
}

int main(int argc, char **argv)
{
    /* -r (RV32I via the eForth runner) and -x (a standalone MUXLEQ image) each
     * set up a whole run; they are mutually exclusive and single-use.
     */
    bool run_chosen = false;
    uint32_t *m32 = NULL; /* set by -x32: run the wide VM instead of dispatch */
    for (int i = 1; i < argc; i++) {
        const bool is_r = !strcmp(argv[i], "-r"), is_x = !strcmp(argv[i], "-x");
        const bool is_x32 = !strcmp(argv[i], "-x32");
        if (!strcmp(argv[i], "-s"))
            prof_stats = true;
        else if (!strcmp(argv[i], "-p"))
            prof_heat = true;
        else if (is_r || is_x || is_x32) {
            if (i + 1 >= argc) {
                fprintf(stderr, "muxleq: %s needs a FILE\n", argv[i]);
                return 1;
            }
            if (run_chosen) {
                fprintf(stderr, "muxleq: -r/-x/-x32 already given\n");
                return 1;
            }
            run_chosen = true;
            if (is_r)
                load_rv32i(argv[++i]);
            else if (is_x)
                load_muxleq(argv[++i]);
            else
                m32 = load_muxleq32(argv[++i]);
        } else
            fprintf(stderr, "muxleq: ignoring unknown argument '%s'\n",
                    argv[i]);
    }
    prof_enabled = prof_stats || prof_heat;

    /* Raw mode (interactive tty stdin) dictates the buffering, so decide it
     * first and set each stream's buffering exactly once (a second setvbuf on a
     * stream is undefined). Non-tty stdin skips raw mode, so pipes, the
     * goldens, and bootstrap keep their byte-identical buffered behavior.
     */
    if (enter_raw_mode()) {
        /* Unbuffered both ways: keystrokes arrive live, and echo/redraw are not
         * hidden behind a line buffer until a newline.
         */
        setvbuf(stdin, NULL, _IONBF, 0);
        setvbuf(stdout, NULL, _IONBF, 0);
    } else {
        const int mode = isatty(fileno(stdout)) ? _IOLBF : _IOFBF;
        setvbuf(stdout, NULL, mode, BUFSIZ);
        if (mode == _IOFBF)
            setvbuf(stdin, NULL, _IOFBF, BUFSIZ);
    }

    /* The wide VM is a separate run path; otherwise fetch the first 16-bit
     * instruction and start the dispatcher.
     */
    if (m32) {
        const int rc = run32(m32);
        free(m32);
        return rc;
    }
    const uint16_t pc = 0;
    const int rc = dispatch(pc, m[pc + A], m[pc + B], m[pc + C]);
    if (prof_enabled)
        report_profile();
    return rc;
}
