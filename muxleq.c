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
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
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
static int dispatch(uint16_t pc,
                    uint16_t addr_a,
                    uint16_t addr_b,
                    uint16_t addr_c);

/* Fetch the next instruction's operands and tail-call dispatch. A negative
 * next_pc is the MUXLEQ halt / negative-branch marker (e.g. a 0xFFFF exit
 * target); check it here and halt BEFORE the loads, so the halt does not read
 * m[] out of bounds (m[next_pc + A..C] with next_pc >= 0x8000 is past the
 * 32768-cell array). dispatch() also halts on a negative pc by returning 0, and
 * it discards the fetched operands in that case, so returning 0 here is
 * byte-for-byte identical behavior without the OOB read.
 */
#define FETCH_AND_DISPATCH(next_pc)                 \
    do {                                            \
        const uint16_t fpc = (next_pc);             \
        if (UNLIKELY((fpc & NEGATIVE_FLAG) != 0))   \
            return 0;                               \
        const uint16_t fa = m[fpc + A];             \
        const uint16_t fb = m[fpc + B];             \
        const uint16_t fc = m[fpc + C];             \
        MUST_TAIL return dispatch(fpc, fa, fb, fc); \
    } while (0)

/* A move is a MUX whose mask is zero (address 6 is hardwired 0). */
static bool is_move_instruction(uint16_t a, uint16_t b, uint16_t c)
{
    if (classify(a, b, c) != OP_MUX)
        return false;
    const uint16_t mask_addr = c & MEM_MASK;
    return (mask_addr == 6) || (m[mask_addr] == 0);
}

static bool is_subleq_instruction(uint16_t a, uint16_t b, uint16_t c)
{
    return classify(a, b, c) == OP_SUBLEQ;
}

/* Optional prefix input fed before real stdin: -r synthesizes an RV32I loader
 * here.
 */
static const char *prefix_in = NULL;
static size_t prefix_len = 0, prefix_pos = 0;

static int get(uint16_t pc,
               UNUSED uint16_t addr_a,
               uint16_t addr_b,
               UNUSED uint16_t addr_c)
{
    const int input = prefix_pos < prefix_len
                          ? (unsigned char) prefix_in[prefix_pos++]
                          : getchar();
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
    if (UNLIKELY((next_pc & NEGATIVE_FLAG) !=
                 0)) /* PC went negative: halt (as dispatch would) */
        return 0;

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
        if (UNLIKELY((next_pc & NEGATIVE_FLAG) !=
                     0)) /* PC went negative: halt (as dispatch would) */
            return 0;

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
        if (prof_stats)
            prof_op[classify(addr_a, addr_b, addr_c)]++;
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

/* Guest RAM window in bytes. Must match rvrammask in muxleq.fth: mask $3FFF =>
 * 16384 cells => 32768 bytes. Guest RAM is a fixed high window in the image's
 * memory (not baked into the image), so loads past it are rejected. This size
 * is coupled to four call sites: rvrammask + rvcell,'s mask + rvrun's initial
 * guest sp in muxleq.fth, and here; they must move together.
 */
#define RV_RAM_BYTES 32768

static uint32_t rd32(const unsigned char *p)
{
    return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t) p[3] << 24;
}
static uint16_t rd16(const unsigned char *p)
{
    return (uint16_t) (p[0] | p[1] << 8);
}

/* -r FILE: run an RV32I program directly. FILE may be an ELF32 executable (its
 * PT_LOAD segments are flattened into the guest image at their virtual
 * addresses) or a flat binary (objcopy -O binary output), used as-is. The bytes
 * are then handed to the built-in runner by synthesizing its loader input --
 * hex 'rvcell,' calls (parsed cleanly as numbers, so no raw-byte/REPL desync)
 * followed by 'rvboot', served via the input prefix above. So `./muxleq -r
 * prog.elf` (or prog.bin) needs no host-side conversion.
 */
static void load_rv32i(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "muxleq: cannot open '%s'\n", path);
        exit(1);
    }
    unsigned char *bin = NULL;
    size_t cap = 0, n = 0;
    for (int c; (c = fgetc(f)) != EOF;) {
        if (n == cap) {
            unsigned char *grown = realloc(bin, cap = cap ? cap * 2 : 256);
            if (!grown) {
                free(bin);
                fclose(f);
                fprintf(stderr, "muxleq: out of memory\n");
                exit(1);
            }
            bin = grown;
        }
        bin[n++] = (unsigned char) c;
    }
    fclose(f);

    /* An ELF32 LE executable: flatten its PT_LOAD segments into a guest image
     * at their virtual addresses (bss beyond filesz stays zero). The runner
     * starts at guest 0, so the entry point must be 0. Anything else is treated
     * as a flat binary. Everything below parses UNTRUSTED bytes, so every
     * header field is bounds-checked against the file size before use.
     */
    if (n >= 52 && bin[0] == 0x7f && bin[1] == 'E' && bin[2] == 'L' &&
        bin[3] == 'F') {
        if (bin[4] != 1 || bin[5] != 1) { /* ELFCLASS32, ELFDATA2LSB */
            fprintf(stderr, "muxleq: '%s' is not a little-endian 32-bit ELF\n",
                    path);
            free(bin);
            exit(1);
        }
        const uint32_t entry = rd32(bin + 24), phoff = rd32(bin + 28);
        const uint16_t phentsize = rd16(bin + 42), phnum = rd16(bin + 44);

        /* Require a well-formed program-header table that fits entirely in the
         * file: each entry is
         * >= 32 bytes (an ELF32 phdr) and the whole table lies within n.
         * Written with subtraction and division so it cannot overflow. This
         * makes every rd32(ph + k), k <= 20, in-bounds.
         */
        if (phentsize < 32 || phoff > n || phnum > (n - phoff) / phentsize) {
            fprintf(stderr,
                    "muxleq: '%s' has a malformed ELF program-header table\n",
                    path);
            free(bin);
            exit(1);
        }
        unsigned char *img = calloc(RV_RAM_BYTES, 1);
        if (!img) {
            fprintf(stderr, "muxleq: out of memory\n");
            free(bin);
            exit(1);
        }
        size_t used = 0;
        for (uint16_t i = 0; i < phnum; i++) {
            const unsigned char *ph = bin + phoff + (size_t) i * phentsize;
            if (rd32(ph) != 1) /* PT_LOAD */
                continue;
            const uint32_t off = rd32(ph + 4), vaddr = rd32(ph + 8);
            const uint32_t filesz = rd32(ph + 16), memsz = rd32(ph + 20);
            if (memsz < filesz || (uint64_t) vaddr + memsz > RV_RAM_BYTES ||
                (uint64_t) off + filesz > n) {
                fprintf(stderr,
                        "muxleq: '%s' does not fit: a PT_LOAD segment maps %u "
                        "bytes at guest "
                        "address 0x%X, past the %d-byte guest RAM. '-r' runs "
                        "freestanding RV32I "
                        "programs (entry 0, <=%d bytes, write/exit ecalls "
                        "only), not libc binaries "
                        "linked high (e.g. at 0x10000).\n",
                        path, (unsigned) memsz, (unsigned) vaddr, RV_RAM_BYTES,
                        RV_RAM_BYTES);
                free(bin);
                free(img);
                exit(1);
            }
            memcpy(img + vaddr, bin + off, filesz);
            if (vaddr + memsz > used)
                used = vaddr + memsz;
        }
        if (entry != 0) {
            fprintf(stderr, "muxleq: '%s' entry 0x%X unsupported; must be 0\n",
                    path, (unsigned) entry);
            free(bin);
            free(img);
            exit(1);
        }
        free(bin);
        bin = img;
        n = used;
    } else if (n > RV_RAM_BYTES) {
        /* Flat binary: a larger image would overwrite the Forth image beyond
         * the guest window.
         */
        fprintf(stderr, "muxleq: '%s' is %zu bytes; guest RAM holds only %d\n",
                path, n, RV_RAM_BYTES);
        free(bin);
        exit(1);
    }

    const size_t cells = (n + 1) / 2;
    char *buf =
        malloc(cells * 14 + 64); /* "FFFF rvcell, " (13) per cell + framing */
    if (!buf) {
        fprintf(stderr, "muxleq: out of memory\n");
        exit(1);
    }

    /* '' ) <ok> !' silences the REPL " ok" prompt so only the guest's output
     * shows; the trailing 'bye' (below) halts the VM once the guest exits, so
     * '-r' runs the program and quits instead of dropping into the interactive
     * REPL and blocking on stdin.
     */
    size_t p = (size_t) sprintf(buf, "' ) <ok> ! hex rvorg\n");
    for (size_t i = 0; i < cells; i++) {
        const unsigned lo = bin[2 * i];
        const unsigned hi = 2 * i + 1 < n ? bin[2 * i + 1] : 0;
        p += (size_t) sprintf(buf + p, "%X rvcell, ", lo | hi << 8);
        if ((i & 7) == 7) /* keep lines under the input-buffer limit */
            buf[p++] = '\n';
    }
    p += (size_t) sprintf(buf + p, "\nrvboot bye\n");
    free(bin);
    prefix_in = buf;
    prefix_len = p;
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
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "muxleq: cannot open '%s'\n", path);
        exit(1);
    }
    memset(m, 0, sizeof m); /* overwrite the baked eForth image */
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

int main(int argc, char **argv)
{
    /* -r (RV32I via the eForth runner) and -x (a standalone MUXLEQ image) each
     * set up a whole run; they are mutually exclusive and single-use.
     */
    bool run_chosen = false;
    for (int i = 1; i < argc; i++) {
        const bool is_r = !strcmp(argv[i], "-r"), is_x = !strcmp(argv[i], "-x");
        if (!strcmp(argv[i], "-s"))
            prof_stats = true;
        else if (!strcmp(argv[i], "-p"))
            prof_heat = true;
        else if (is_r || is_x) {
            if (i + 1 >= argc) {
                fprintf(stderr, "muxleq: %s needs a FILE\n", argv[i]);
                return 1;
            }
            if (run_chosen) {
                fprintf(stderr, "muxleq: -r/-x already given\n");
                return 1;
            }
            run_chosen = true;
            if (is_r)
                load_rv32i(argv[++i]);
            else
                load_muxleq(argv[++i]);
        } else
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
