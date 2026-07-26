/*
 * RV32I loader and hot traces for muxleq.c. Included into muxleq.c so the hot
 * path can keep using the VM's static helpers without exporting an internal
 * API.
 */

/* Mirrored in scripts/gen-rv32i-traces.py, which pattern-matches the traces in
 * stage0.dec using the same values; keep the two in lockstep.
 */
enum {
    RV32I_MOVE_C = NEGATIVE_FLAG | ZERO_MASK_ADDR,
    RV32I_ZERO_CELL = 0,
    RV32I_TRACE_BASE = 4,
    RV32I_TRACE_STRIDE = 7,
    RV32I_TRACE_DEC = 8,
    RV32I_TRACE_VALUE = 11,
    RV32I_TRACE_LIMIT = 12,
    RV32I_TRACE_TMP = 13,
    RV32I_TRACE_CURSOR = 38,
    RV32I_TRACE_COND = 39,
    RV32I_TRACE_ALT_ADDR = 309,
};

struct rv32i_hot_trace {
    uint16_t loader_loop;
    uint16_t taken_trace, taken_trace_end, taken_trace_fallthrough;
    uint16_t patched_move, indirect_load_operand, loop_exit_operand;
    uint16_t patched_move_dest_operand, computed_dest_cell;
    uint16_t pair_update_loop, pair_update_loop_end;
    uint16_t altaddr_move_dest_operand, cond_restore_src_operand;
    uint16_t cursor_reload_trace, cursor_reload_trace_end;
    uint16_t cursor_reload_src_operand;
    uint16_t condition_fold_loop, condition_fold_loop_end;
    uint16_t condition_fold_exit_operand;
};

static bool rv32i_hot_trace_enabled = false;

/* Defines 'static const struct rv32i_hot_trace rv32i_hot_layout'. Being const
 * with compile-time initializers, the hot-path reads below (the dispatch-hook
 * guards and every trace body) fold to immediates -- no runtime struct load.
 */
#include <rv32i-traces.inc>

static inline bool rv32i_hot_cell(uint16_t addr,
                                  uint16_t begin,
                                  uint16_t end,
                                  uint16_t writable_a,
                                  uint16_t writable_b)
{
    return addr >= begin && addr <= end && addr != writable_a &&
           addr != writable_b;
}

static inline void rv32i_store_invalidates_hot_trace(uint16_t addr)
{
    if (!rv32i_hot_trace_enabled)
        return;

    /* A store into any live trace cell retires the whole trace set. Each
     * rv32i_hot_cell() spans one trace's range minus the operands that trace
     * legitimately self-patches; condition_fold self-patches nothing, so it is
     * a plain range test.
     */
    if ((rv32i_hot_cell(addr, rv32i_hot_layout.loader_loop,
                        rv32i_hot_layout.taken_trace_end,
                        rv32i_hot_layout.indirect_load_operand,
                        rv32i_hot_layout.loop_exit_operand) &&
         addr != rv32i_hot_layout.patched_move_dest_operand) ||
        rv32i_hot_cell(addr, rv32i_hot_layout.pair_update_loop,
                       rv32i_hot_layout.pair_update_loop_end,
                       rv32i_hot_layout.altaddr_move_dest_operand,
                       rv32i_hot_layout.cond_restore_src_operand) ||
        rv32i_hot_cell(addr, rv32i_hot_layout.cursor_reload_trace,
                       rv32i_hot_layout.cursor_reload_trace_end,
                       rv32i_hot_layout.cursor_reload_src_operand,
                       rv32i_hot_layout.cursor_reload_src_operand) ||
        (addr >= rv32i_hot_layout.condition_fold_loop &&
         addr <= rv32i_hot_layout.condition_fold_loop_end))
        rv32i_hot_trace_enabled = false;
}

static VM_ABI int rv32i_trace_taken(UNUSED uint16_t pc,
                                    UNUSED uint16_t addr_a,
                                    UNUSED uint16_t addr_b,
                                    UNUSED uint16_t addr_c)
{
    EXEC_RAW_SUBLEQ_DROP(RV32I_TRACE_STRIDE,
                         rv32i_hot_layout.computed_dest_cell);
    EXEC_RAW_MOVE(rv32i_hot_layout.computed_dest_cell,
                  rv32i_hot_layout.patched_move_dest_operand);

    const uint16_t patched_dest = m[rv32i_hot_layout.patched_move_dest_operand];
    if (UNLIKELY(patched_dest == IO_MARKER ||
                 (patched_dest >= rv32i_hot_layout.taken_trace &&
                  patched_dest <= rv32i_hot_layout.taken_trace_end)))
        FETCH_AND_DISPATCH(rv32i_hot_layout.patched_move);

    EXEC_MOVE(RV32I_TRACE_CURSOR, patched_dest);
    EXEC_RAW_MOVE(RV32I_TRACE_VALUE, RV32I_TRACE_CURSOR);
    EXEC_RAW_SUBLEQ_DROP(RV32I_ZERO_CELL, RV32I_ZERO_CELL);
    FETCH_AND_DISPATCH(rv32i_hot_layout.loader_loop);
}

static VM_ABI int rv32i_trace_loader(UNUSED uint16_t pc,
                                     UNUSED uint16_t addr_a,
                                     UNUSED uint16_t addr_b,
                                     UNUSED uint16_t addr_c)
{
    EXEC_RAW_MOVE(RV32I_TRACE_CURSOR, rv32i_hot_layout.indirect_load_operand);
    EXEC_RAW_MOVE(m[rv32i_hot_layout.indirect_load_operand], RV32I_TRACE_VALUE);
    EXEC_RAW_SUBLEQ_DROP(RV32I_TRACE_STRIDE, RV32I_TRACE_CURSOR);
    EXEC_RAW_MOVE(RV32I_TRACE_BASE, RV32I_TRACE_LIMIT);
    EXEC_RAW_SUBLEQ_DROP(RV32I_TRACE_VALUE, RV32I_TRACE_LIMIT);

    EXEC_RAW_SUBLEQ(RV32I_ZERO_CELL, RV32I_TRACE_LIMIT, result2);
    if (UNLIKELY(SUBLEQ_BRANCHES(result2)))
        MUST_TAIL return rv32i_trace_taken(
            rv32i_hot_layout.taken_trace, RV32I_TRACE_STRIDE,
            rv32i_hot_layout.computed_dest_cell,
            rv32i_hot_layout.taken_trace_fallthrough);

    EXEC_RAW_MOVE(RV32I_TRACE_VALUE, rv32i_hot_layout.loop_exit_operand);
    EXEC_RAW_SUBLEQ_DROP(RV32I_ZERO_CELL, RV32I_ZERO_CELL);
    FETCH_AND_DISPATCH(m[rv32i_hot_layout.loop_exit_operand]);
}

static VM_ABI int rv32i_trace_pair_update(UNUSED uint16_t pc,
                                          UNUSED uint16_t addr_a,
                                          UNUSED uint16_t addr_b,
                                          UNUSED uint16_t addr_c)
{
    EXEC_RAW_SUBLEQ_DROP(RV32I_TRACE_DEC, RV32I_TRACE_ALT_ADDR);
    EXEC_RAW_MOVE(RV32I_TRACE_ALT_ADDR,
                  rv32i_hot_layout.altaddr_move_dest_operand);

    const uint16_t patched_dest = m[rv32i_hot_layout.altaddr_move_dest_operand];
    if (UNLIKELY(patched_dest == IO_MARKER ||
                 (patched_dest >= rv32i_hot_layout.pair_update_loop &&
                  patched_dest <= rv32i_hot_layout.pair_update_loop_end)))
        FETCH_AND_DISPATCH(rv32i_hot_layout.altaddr_move_dest_operand - 1);
    EXEC_MOVE(RV32I_TRACE_COND, patched_dest);

    EXEC_RAW_MOVE(rv32i_hot_layout.computed_dest_cell,
                  rv32i_hot_layout.cond_restore_src_operand);
    const uint16_t restore_src = m[rv32i_hot_layout.cond_restore_src_operand];
    if (UNLIKELY(restore_src == IO_MARKER))
        FETCH_AND_DISPATCH(rv32i_hot_layout.cond_restore_src_operand);
    EXEC_RAW_MOVE(restore_src, RV32I_TRACE_COND);

    EXEC_RAW_SUBLEQ_DROP(RV32I_TRACE_DEC, rv32i_hot_layout.computed_dest_cell);
    EXEC_RAW_SUBLEQ_DROP(RV32I_ZERO_CELL, RV32I_ZERO_CELL);
    FETCH_AND_DISPATCH(rv32i_hot_layout.loader_loop);
}

static VM_ABI int rv32i_trace_cursor_reload(UNUSED uint16_t pc,
                                            UNUSED uint16_t addr_a,
                                            UNUSED uint16_t addr_b,
                                            UNUSED uint16_t addr_c)
{
    EXEC_RAW_MOVE(rv32i_hot_layout.computed_dest_cell,
                  rv32i_hot_layout.cursor_reload_src_operand);

    const uint16_t reload_src = m[rv32i_hot_layout.cursor_reload_src_operand];
    if (UNLIKELY(reload_src == IO_MARKER))
        FETCH_AND_DISPATCH(rv32i_hot_layout.cursor_reload_src_operand);

    EXEC_RAW_MOVE(reload_src, RV32I_TRACE_CURSOR);
    EXEC_RAW_SUBLEQ_DROP(RV32I_TRACE_DEC, rv32i_hot_layout.computed_dest_cell);
    EXEC_RAW_SUBLEQ_DROP(RV32I_ZERO_CELL, RV32I_ZERO_CELL);
    FETCH_AND_DISPATCH(rv32i_hot_layout.loader_loop);
}

static VM_ABI int rv32i_trace_condition_fold(UNUSED uint16_t pc,
                                             UNUSED uint16_t addr_a,
                                             UNUSED uint16_t addr_b,
                                             UNUSED uint16_t addr_c)
{
    for (;;) {
        raw_subleq_cell(RV32I_TRACE_LIMIT, RV32I_ZERO_CELL);
        raw_subleq_cell(RV32I_ZERO_CELL, RV32I_TRACE_LIMIT);
        raw_subleq_cell(RV32I_ZERO_CELL, RV32I_ZERO_CELL);

        if (!SUBLEQ_BRANCHES(
                raw_subleq_cell(RV32I_ZERO_CELL, RV32I_TRACE_COND))) {
            raw_subleq_cell(RV32I_ZERO_CELL, RV32I_ZERO_CELL);
        } else {
            raw_store_cell(RV32I_TRACE_TMP, m[RV32I_TRACE_COND]);
            raw_subleq_cell(RV32I_TRACE_STRIDE, RV32I_TRACE_TMP);
            if (!SUBLEQ_BRANCHES(
                    raw_subleq_cell(RV32I_ZERO_CELL, RV32I_TRACE_TMP)))
                raw_subleq_cell(RV32I_ZERO_CELL, RV32I_ZERO_CELL);
            else
                raw_subleq_cell(RV32I_TRACE_STRIDE, RV32I_TRACE_LIMIT);
        }

        raw_subleq_cell(RV32I_TRACE_COND, RV32I_ZERO_CELL);
        raw_subleq_cell(RV32I_ZERO_CELL, RV32I_TRACE_COND);
        raw_subleq_cell(RV32I_ZERO_CELL, RV32I_ZERO_CELL);
        raw_subleq_cell(RV32I_TRACE_DEC, RV32I_TRACE_VALUE);
        if (SUBLEQ_BRANCHES(
                raw_subleq_cell(RV32I_ZERO_CELL, RV32I_TRACE_VALUE))) {
            raw_store_cell(RV32I_TRACE_COND, m[RV32I_TRACE_LIMIT]);
            raw_subleq_cell(RV32I_ZERO_CELL, RV32I_ZERO_CELL);
            FETCH_AND_DISPATCH(m[rv32i_hot_layout.condition_fold_exit_operand]);
        }
        raw_subleq_cell(RV32I_ZERO_CELL, RV32I_ZERO_CELL);
    }
}

/* Must stay a macro, not a function: each arm does 'MUST_TAIL return' from
 * dispatch()'s own frame to keep the interpreter's tail-call chain intact.
 * Wrapping it in a function would put the return one frame too deep and break
 * the musttail contract dispatch() relies on.
 */
#define RV32I_DISPATCH_HOOK(pc, addr_a, addr_b, addr_c)                        \
    do {                                                                       \
        if (!rv32i_hot_trace_enabled)                                          \
            break;                                                             \
        if (UNLIKELY((pc) == rv32i_hot_layout.loader_loop &&                   \
                     (addr_a) == RV32I_TRACE_CURSOR &&                         \
                     (addr_b) == rv32i_hot_layout.indirect_load_operand &&     \
                     (addr_c) == RV32I_MOVE_C &&                               \
                     m[RV32I_TRACE_CURSOR] != IO_MARKER))                      \
            MUST_TAIL return rv32i_trace_loader((pc), (addr_a), (addr_b),      \
                                                (addr_c));                     \
        if (UNLIKELY((pc) == rv32i_hot_layout.taken_trace &&                   \
                     (addr_a) == RV32I_TRACE_STRIDE &&                         \
                     (addr_b) == rv32i_hot_layout.computed_dest_cell &&        \
                     (addr_c) == rv32i_hot_layout.taken_trace_fallthrough))    \
            MUST_TAIL return rv32i_trace_taken((pc), (addr_a), (addr_b),       \
                                               (addr_c));                      \
        if (UNLIKELY((pc) == rv32i_hot_layout.pair_update_loop &&              \
                     (addr_a) == RV32I_TRACE_DEC &&                            \
                     (addr_b) == RV32I_TRACE_ALT_ADDR &&                       \
                     (addr_c) ==                                               \
                         rv32i_hot_layout.pair_update_loop + INSN_SIZE))       \
            MUST_TAIL return rv32i_trace_pair_update((pc), (addr_a), (addr_b), \
                                                     (addr_c));                \
        if (UNLIKELY((pc) == rv32i_hot_layout.cursor_reload_trace &&           \
                     (addr_a) == rv32i_hot_layout.computed_dest_cell &&        \
                     (addr_b) == rv32i_hot_layout.cursor_reload_src_operand && \
                     (addr_c) == RV32I_MOVE_C &&                               \
                     m[rv32i_hot_layout.computed_dest_cell] != IO_MARKER))     \
            MUST_TAIL return rv32i_trace_cursor_reload((pc), (addr_a),         \
                                                       (addr_b), (addr_c));    \
        if (UNLIKELY((pc) == rv32i_hot_layout.condition_fold_loop &&           \
                     (addr_a) == RV32I_TRACE_LIMIT &&                          \
                     (addr_b) == RV32I_ZERO_CELL &&                            \
                     (addr_c) ==                                               \
                         rv32i_hot_layout.condition_fold_loop + INSN_SIZE))    \
            MUST_TAIL return rv32i_trace_condition_fold((pc), (addr_a),        \
                                                        (addr_b), (addr_c));   \
    } while (0)

static void rv32i_disable(void)
{
    rv32i_hot_trace_enabled = false;
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

/* -r FILE: run an RV32I program directly. FILE is either an ELF32-LE executable
 * (its PT_LOAD segments are flattened into the guest image at their virtual
 * addresses; entry must be 0) or a flat 'objcopy -O binary' image used as-is.
 * The bytes are handed to the image's built-in runner by synthesizing its
 * loader input -- hex 'rvcell,' calls followed by 'rvboot', fed through
 * prefix_in -- so './muxleq -r prog' needs no host-side conversion. Everything
 * here parses UNTRUSTED input, so every header field is bounds-checked before
 * use.
 */
static void load_rv32i(const char *path)
{
    rv32i_hot_trace_enabled = true;
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "muxleq: cannot open '%s'\n", path);
        exit(1);
    }
    unsigned char *bin = NULL;
    size_t cap = 0, n = 0;
    for (int c; (c = fgetc(f)) != EOF;) {
        if (n == cap) {
            if (UNLIKELY(cap > SIZE_MAX / 2)) {
                free(bin);
                fclose(f);
                fprintf(stderr, "muxleq: input too large\n");
                exit(1);
            }
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

    /* ELF32-LE executable: flatten its PT_LOAD segments into a zero-filled
     * guest image at their virtual addresses (bss beyond filesz stays zero).
     * The runner starts at guest 0, so entry must be 0. Anything else is
     * treated as a flat binary.
     */
    if (n >= 52 && bin[0] == 0x7f && bin[1] == 'E' && bin[2] == 'L' &&
        bin[3] == 'F') {
        if (bin[4] != 1 || bin[5] != 1) {
            fprintf(stderr, "muxleq: '%s' is not a little-endian 32-bit ELF\n",
                    path);
            free(bin);
            exit(1);
        }
        const uint32_t entry = rd32(bin + 24), phoff = rd32(bin + 28);
        const uint16_t phentsize = rd16(bin + 42), phnum = rd16(bin + 44);

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
            if (rd32(ph) != 1)
                continue;
            const uint32_t off = rd32(ph + 4), vaddr = rd32(ph + 8);
            const uint32_t filesz = rd32(ph + 16), memsz = rd32(ph + 20);
            if (memsz < filesz || (uint64_t) vaddr + memsz > RV_RAM_BYTES ||
                (uint64_t) off + filesz > n) {
                fprintf(stderr,
                        "muxleq: '%s' does not fit: a PT_LOAD segment maps %u "
                        "bytes at guest address 0x%X, past the %d-byte guest "
                        "RAM. '-r' runs freestanding RV32I programs (entry 0, "
                        "<=%d bytes, write/exit ecalls only), not libc "
                        "binaries linked high (e.g. at 0x10000).\n",
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
        fprintf(stderr, "muxleq: '%s' is %zu bytes; guest RAM holds only %d\n",
                path, n, RV_RAM_BYTES);
        free(bin);
        exit(1);
    }

    /* Per cell we emit at most "FFFF rvcell, " (13 chars) plus a newline every
     * eighth line, so 14 bytes/cell bounds the body; 64 covers the rvorg prefix
     * and rvboot suffix with slack. The asserts tie those magic numbers to the
     * literals so a format change cannot silently under-allocate.
     */
    _Static_assert(sizeof "FFFF rvcell, " <= 14,
                   "-r per-cell buffer too small");
    _Static_assert(
        sizeof "' ) <ok> ! hex rvorg\n" + sizeof "\nrvboot bye\n" <= 64,
        "-r framing buffer too small");
    const size_t cells = (n + 1) / 2;
    char *buf = malloc(cells * 14 + 64);
    if (!buf) {
        fprintf(stderr, "muxleq: out of memory\n");
        exit(1);
    }

    /* '' ) <ok> !' silences the REPL's " ok" prompt so only the guest's output
     * shows; the trailing 'rvboot bye' boots the guest and halts the VM when it
     * exits, so '-r' runs the program and quits instead of dropping into the
     * interactive REPL and blocking on stdin.
     */
    size_t p = (size_t) sprintf(buf, "' ) <ok> ! hex rvorg\n");
    for (size_t i = 0; i < cells; i++) {
        const unsigned lo = bin[2 * i];
        const unsigned hi = 2 * i + 1 < n ? bin[2 * i + 1] : 0;
        p += (size_t) sprintf(buf + p, "%X rvcell, ", lo | hi << 8);
        if ((i & 7) == 7)
            buf[p++] = '\n';
    }
    p += (size_t) sprintf(buf + p, "\nrvboot bye\n");
    free(bin);
    prefix_in = buf;
    prefix_len = p;
}
