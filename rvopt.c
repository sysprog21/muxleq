/*
 * rvopt -- standalone RV32I-to-MUXLEQ optimizer.
 *
 * Built OUTSIDE the self-hosted Forth image so it costs zero image cells. It
 * loads an RV32I program (an ELF32-LE or flat binary), decodes its words into
 * an integer-indexed graph, and lowers it to a standalone native MUXLEQ image
 * that the VM runs directly on the two ops.
 *
 * Nodes live in a plain index-addressed array (indexes survive array growth;
 * cached pointers do not), and every node carries explicit control, memory, and
 * value edges so later passes have the dependencies spelled out rather than
 * re-derived.
 *
 * Usage (FILE = "-" reads stdin):
 *   rvopt dump FILE    decode FILE, write the textual IR to stdout
 *   rvopt check FILE   verify a textual IR (as written by dump)
 *   rvopt mux FILE     lower to a native MUXLEQ image the VM runs directly
 */

#define _POSIX_C_SOURCE 200809L

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Guest RAM window for the lowered RV32I program. */
#define RV_RAM_BYTES 32768
#define MUX_OLD_MAX_CELLS (1 << 21)
#ifndef MUX_MAX_CELLS
#define MUX_MAX_CELLS (1 << 26)
#endif
#if MUX_MAX_CELLS <= MUX_OLD_MAX_CELLS && !defined(MUX_ALLOW_SMALL_CAP)
#error "MUX_MAX_CELLS must stay above the old 2M-cell ceiling"
#endif

/* No edge / no node. */
#define NONE (-1)

/* Decoded instruction class. One kind per RV32I major opcode; unknown or
 * data-decoded-as-code words become ILL (a linear sweep decodes rodata too --
 * reachability-guided decode is a later milestone).
 */
enum ins_kind {
    K_ILL = 0,
    K_LUI,
    K_AUIPC,
    K_JAL,
    K_JALR,
    K_BRANCH,
    K_LOAD,
    K_STORE,
    K_OPIMM,
    K_OP,
    K_FENCE,
    K_SYSTEM,
    K_KIND_COUNT
};

static const char *const kind_name[K_KIND_COUNT] = {
    "ILL",  "LUI",   "AUIPC", "JAL", "JALR",  "BRANCH",
    "LOAD", "STORE", "OPIMM", "OP",  "FENCE", "SYSTEM"};

/* One graph node per decoded word. rd/rs1/rs2 are 0..31 (or NONE when the
 * format has no such field). Edges are node indexes or NONE:
 *   next   -- fall-through control successor
 *   target -- direct branch/jump control successor (indirect => NONE)
 *   mem    -- previous memory-ordering node (load/store chain, alias barrier)
 *   vd1/vd2 -- producer node of rs1/rs2 within the basic block (NONE =>
 * live-in)
 */
struct node {
    uint32_t pc;   /* guest byte address */
    uint32_t word; /* raw instruction word */
    int kind;
    int rd, rs1, rs2;
    int32_t imm;
    uint8_t funct3;
    int leader; /* 1 if a basic-block leader */
    int next, target, mem, vd1, vd2;
};

struct graph {
    struct node *n;
    int count;
    int entry;

    /* Def-use lists (ir idea 3), derived from the vd1/vd2 producer edges: for
     * node i, its in-block users are use_edges[use_off[i] ..
     * use_off[i]+use_cnt[i]). These are INTRA-BLOCK (vd1/vd2 reset at leaders),
     * so use_cnt == 0 means "no in-block users", NOT globally dead -- a def can
     * still be live-out to a successor block. A future DCE MUST also prove
     * not-live-out (or these lists must be extended to inter-block liveness)
     * before treating a def as dead.
     */
    int *use_off, *use_cnt, *use_edges;
};

static void die(const char *msg, const char *arg)
{
    if (arg)
        fprintf(stderr, "rvopt: %s '%s'\n", msg, arg);
    else
        fprintf(stderr, "rvopt: %s\n", msg);
    exit(1);
}

static void *xrealloc(void *p, size_t n)
{
    void *q = realloc(p, n);
    if (!q)
        die("out of memory", NULL);
    return q;
}

static void *xcalloc(size_t count, size_t size)
{
    void *p = calloc(count, size);
    if (!p)
        die("out of memory", NULL);
    return p;
}

/* file loading (mirrors muxleq.c's bounds-checked loader) */

static uint32_t rd32(const unsigned char *p)
{
    return (uint32_t) p[0] | (uint32_t) p[1] << 8 | (uint32_t) p[2] << 16 |
           (uint32_t) p[3] << 24;
}
static uint16_t rd16(const unsigned char *p)
{
    return (uint16_t) (p[0] | p[1] << 8);
}

/* Open FILE for reading in binary mode, or stdin for "-"; die on failure. */
static FILE *open_input(const char *path)
{
    FILE *f = !strcmp(path, "-") ? stdin : fopen(path, "rb");
    if (!f)
        die("cannot open", path);
    return f;
}

/* Read FILE into a freshly allocated buffer; return it and set *len. A path of
 * "-" reads stdin.
 */
static unsigned char *slurp(const char *path, size_t *len)
{
    FILE *f = open_input(path);
    unsigned char *b = NULL;
    size_t cap = 0, n = 0;
    for (int c; (c = fgetc(f)) != EOF;) {
        if (n == cap)
            b = xrealloc(b, cap = cap ? cap * 2 : 256);
        b[n++] = (unsigned char) c;
    }
    if (f != stdin)
        fclose(f);
    *len = n;
    return b;
}

/* Flatten an RV32I program to a guest image of RV_RAM_BYTES. ELF32-LE with
 * entry 0 has its PT_LOAD segments mapped to their vaddrs; anything else is a
 * flat binary. *used is the highest byte touched. Every ELF field is
 * bounds-checked against the file size, exactly as the VM's loader does.
 */
static unsigned char *load_guest(const char *path, size_t *used)
{
    size_t n;
    unsigned char *bin = slurp(path, &n);

    if (n >= 52 && bin[0] == 0x7f && bin[1] == 'E' && bin[2] == 'L' &&
        bin[3] == 'F') {
        if (bin[4] != 1 || bin[5] != 1)
            die("not a little-endian 32-bit ELF", path);
        const uint32_t entry = rd32(bin + 24), phoff = rd32(bin + 28);
        const uint16_t phentsize = rd16(bin + 42), phnum = rd16(bin + 44);
        if (phentsize < 32 || phoff > n || phnum > (n - phoff) / phentsize)
            die("malformed ELF program-header table", path);
        if (entry != 0)
            die("ELF entry must be 0", path);
        unsigned char *img = xcalloc(RV_RAM_BYTES, 1);
        size_t hi = 0;
        for (uint16_t i = 0; i < phnum; i++) {
            const unsigned char *ph = bin + phoff + (size_t) i * phentsize;
            if (rd32(ph) != 1) /* PT_LOAD */
                continue;
            const uint32_t off = rd32(ph + 4), vaddr = rd32(ph + 8);
            const uint32_t filesz = rd32(ph + 16), memsz = rd32(ph + 20);
            if (memsz < filesz || (uint64_t) vaddr + memsz > RV_RAM_BYTES ||
                (uint64_t) off + filesz > n)
                die("ELF PT_LOAD segment does not fit guest RAM", path);
            memcpy(img + vaddr, bin + off, filesz);
            if (vaddr + memsz > hi)
                hi = vaddr + memsz;
        }
        free(bin);
        *used = hi;
        return img;
    }

    if (n > RV_RAM_BYTES)
        die("flat binary larger than guest RAM", path);
    unsigned char *img = xcalloc(RV_RAM_BYTES, 1);
    if (n) /* an empty file leaves bin == NULL; memcpy(_, NULL, 0) is UB */
        memcpy(img, bin, n);
    free(bin);
    *used = n;
    return img;
}

/* RV32I decode */

/* Sign-extend the low 'bits' of v. */
static int32_t sext(uint32_t v, int bits)
{
    const uint32_t m = (uint32_t) 1 << (bits - 1);
    return (int32_t) ((v ^ m) - m);
}

static void decode_word(uint32_t pc, uint32_t w, struct node *nd)
{
    nd->pc = pc;
    nd->word = w;
    nd->rd = nd->rs1 = nd->rs2 = NONE;
    nd->imm = 0;
    nd->funct3 = (w >> 12) & 7;
    const uint32_t op = w & 0x7f;
    const int rd = (w >> 7) & 31, rs1 = (w >> 15) & 31, rs2 = (w >> 20) & 31;

    switch (op) {
    case 0x37: /* LUI */
        nd->kind = K_LUI, nd->rd = rd, nd->imm = (int32_t) (w & 0xfffff000u);
        break;
    case 0x17: /* AUIPC */
        nd->kind = K_AUIPC, nd->rd = rd, nd->imm = (int32_t) (w & 0xfffff000u);
        break;
    case 0x6f: /* JAL */
        nd->kind = K_JAL, nd->rd = rd;
        nd->imm = sext(((w >> 31) & 1) << 20 | ((w >> 12) & 0xff) << 12 |
                           ((w >> 20) & 1) << 11 | ((w >> 21) & 0x3ff) << 1,
                       21);
        break;
    case 0x67: /* JALR */
        nd->kind = K_JALR, nd->rd = rd, nd->rs1 = rs1,
        nd->imm = sext(w >> 20, 12);
        break;
    case 0x63: /* BRANCH */
        nd->kind = K_BRANCH, nd->rs1 = rs1, nd->rs2 = rs2;
        nd->imm = sext(((w >> 31) & 1) << 12 | ((w >> 7) & 1) << 11 |
                           ((w >> 25) & 0x3f) << 5 | ((w >> 8) & 0xf) << 1,
                       13);
        break;
    case 0x03: /* LOAD */
        nd->kind = K_LOAD, nd->rd = rd, nd->rs1 = rs1,
        nd->imm = sext(w >> 20, 12);
        break;
    case 0x23: /* STORE */
        nd->kind = K_STORE, nd->rs1 = rs1, nd->rs2 = rs2;
        nd->imm = sext(((w >> 25) & 0x7f) << 5 | ((w >> 7) & 0x1f), 12);
        break;
    case 0x13: /* OP-IMM */
        nd->kind = K_OPIMM, nd->rd = rd, nd->rs1 = rs1;
        /* SLLI/SRLI/SRAI take a shamt, not a sign-extended immediate. */
        nd->imm = (nd->funct3 == 1 || nd->funct3 == 5) ? (int32_t) rs2
                                                       : sext(w >> 20, 12);
        break;
    case 0x33: /* OP */
        nd->kind = K_OP, nd->rd = rd, nd->rs1 = rs1, nd->rs2 = rs2;
        break;
    case 0x0f: /* MISC-MEM (FENCE) */
        nd->kind = K_FENCE;
        break;
    case 0x73: /* SYSTEM (ECALL/EBREAK) */
        nd->kind = K_SYSTEM;
        break;
    default:
        nd->kind = K_ILL;
        break;
    }
    /* x0 is hardwired zero: never a real def. */
    if (nd->rd == 0)
        nd->rd = NONE;
}

/* Map a guest byte address to its node index, or NONE if it is not a decoded
 * word start. START is node 0; instruction k (at pc = 4k) is node k+1.
 */
static int addr2node(const struct graph *g, uint32_t pc)
{
    if (pc & 3)
        return NONE;
    const int idx = 1 + (int) (pc / 4);
    return (idx >= 1 && idx < g->count) ? idx : NONE;
}

/* A control transfer ends a basic block; its successor starts a new one. */
static bool is_block_end(int kind)
{
    return kind == K_JAL || kind == K_JALR || kind == K_BRANCH ||
           kind == K_SYSTEM;
}

/* Build the def-use lists from the vd1/vd2 producer edges: a flat pool indexed
 * per producer node, filled by the standard two-pass count-then-fill (ir.c
 * ~1300 shape). Purely derived from vd1/vd2, so emit is unaffected. A
 * prerequisite for DCE/SCCP -- but note it is INTRA-BLOCK (see struct graph): 0
 * in-block users does NOT imply globally dead.
 */
static void build_use_lists(struct graph *g)
{
    g->use_off = xcalloc((size_t) g->count, sizeof *g->use_off);
    g->use_cnt = xcalloc((size_t) g->count, sizeof *g->use_cnt);
    int total = 0;
    for (int i = 0; i < g->count; i++) {
        const int prod[2] = {g->n[i].vd1, g->n[i].vd2};
        for (int k = 0; k < 2; k++)
            if (prod[k] != NONE) {
                g->use_cnt[prod[k]]++;
                total++;
            }
    }
    for (int i = 0, acc = 0; i < g->count; i++) {
        g->use_off[i] = acc;
        acc += g->use_cnt[i];
    }
    g->use_edges = xcalloc((size_t) (total ? total : 1), sizeof *g->use_edges);
    int *fill = xcalloc((size_t) g->count, sizeof *fill);
    for (int i = 0; i < g->count; i++) {
        const int prod[2] = {g->n[i].vd1, g->n[i].vd2};
        for (int k = 0; k < 2; k++)
            if (prod[k] != NONE) {
                const int p = prod[k];
                g->use_edges[g->use_off[p] + fill[p]++] = i;
            }
    }
    for (int i = 0; i < g->count; i++)
        if (fill[i] != g->use_cnt[i])
            die("def-use list build inconsistent", NULL);
    free(fill);
}

static struct graph decode_graph(const unsigned char *img, size_t used)
{
    /* Round up to whole words; node 0 is a synthetic START. */
    const int words = (int) ((used + 3) / 4);
    struct graph g = {0};
    g.count = words + 1;
    g.entry = words ? 1 : 0;
    g.n = xcalloc((size_t) g.count, sizeof *g.n);

    /* START: a control-only node flowing into the entry instruction. */
    g.n[0].kind = K_ILL;
    g.n[0].pc = 0;
    g.n[0].rd = g.n[0].rs1 = g.n[0].rs2 = NONE;
    g.n[0].next = g.entry;
    g.n[0].target = g.n[0].mem = g.n[0].vd1 = g.n[0].vd2 = NONE;

    for (int k = 0; k < words; k++) {
        const uint32_t pc = (uint32_t) (4 * k);
        decode_word(pc, rd32(img + 4 * k), &g.n[k + 1]);
    }

    /* Mark basic-block leaders: entry, any branch/jump target, and the word
     * after a control transfer. Value edges reset at each leader.
     */
    if (words)
        g.n[1].leader = 1;
    for (int i = 1; i < g.count; i++) {
        struct node *nd = &g.n[i];
        const int fall = addr2node(&g, nd->pc + 4);
        nd->next = is_block_end(nd->kind) && nd->kind != K_BRANCH ? NONE : fall;
        nd->target = NONE;
        if (nd->kind == K_JAL || nd->kind == K_BRANCH) {
            const int t = addr2node(&g, nd->pc + (uint32_t) nd->imm);
            nd->target = t;
            if (t != NONE)
                g.n[t].leader = 1;
        }
        if (is_block_end(nd->kind) && fall != NONE)
            g.n[fall].leader = 1;
    }

    /* Memory-order chain + intra-block value edges in one linear pass. */
    int last_def[32];
    for (int r = 0; r < 32; r++)
        last_def[r] = NONE;
    int mem_prev = NONE;
    for (int i = 1; i < g.count; i++) {
        struct node *nd = &g.n[i];
        if (nd->leader)
            for (int r = 0; r < 32; r++)
                last_def[r] = NONE;
        nd->vd1 = nd->rs1 > 0 ? last_def[nd->rs1] : NONE;
        nd->vd2 = nd->rs2 > 0 ? last_def[nd->rs2] : NONE;
        nd->mem = NONE;
        if (nd->kind == K_LOAD || nd->kind == K_STORE) {
            nd->mem = mem_prev;
            mem_prev = i;
        }
        if (nd->rd != NONE)
            last_def[nd->rd] = i;
    }
    build_use_lists(&g);
    return g;
}

/* Release a decoded graph (nodes + def-use pool). */
static void free_graph(struct graph *g)
{
    free(g->n);
    free(g->use_off);
    free(g->use_cnt);
    free(g->use_edges);
}

/* local folding */

/* Which instructions fold to a direct constant effect instead of a runtime op.
 * Keyed on the RAW word: decode_word normalizes rd==0 to NONE, but folding
 * needs the real rd. Kept deliberately tiny -- only encodings that are
 * trivially 32-bit-correct without add-with-carry: ADDI rd,x0,imm (load
 * immediate) and ADDI x0,rs,imm (the result is discarded, so a pure nop).
 * Everything else stays FOLD_NONE.
 */
enum fold_kind { FOLD_NONE = 0, FOLD_LI12, FOLD_DEADI, FOLD_COUNT };
static const char *const fold_name[FOLD_COUNT] = {"-", "li12", "deadi"};

static int fold_kind(uint32_t w)
{
    const unsigned op = w & 0x7f, f3 = (w >> 12) & 7;
    const unsigned rd = (w >> 7) & 31, rs1 = (w >> 15) & 31;
    if (op == 0x13 && f3 == 0) { /* ADDI */
        if (rd == 0)             /* result discarded -> dead */
            return FOLD_DEADI;
        if (rs1 == 0) /* x0 + imm -> load immediate */
            return FOLD_LI12;
    }
    return FOLD_NONE;
}

/* textual IR dump / load / check */

static void reg(char *buf, int r)
{
    if (r == NONE)
        strcpy(buf, "-");
    else
        snprintf(buf, 8, "x%d", r);
}

static void dump_graph(const struct graph *g, const char *path)
{
    printf("; rvopt IR v0  %s\n", path ? path : "-");
    printf("; nodes=%d entry=%d\n", g->count, g->entry);
    for (int i = 0; i < g->count; i++) {
        const struct node *nd = &g->n[i];
        char rd[8], rs1[8], rs2[8];
        reg(rd, nd->rd), reg(rs1, nd->rs1), reg(rs2, nd->rs2);

        /* word= is the raw instruction: the dump's only lossless record (kind +
         * funct3 alone cannot tell ADD from SUB or SRLI from SRAI). Later
         * passes key off it; check ignores it as it is not an edge.
         */
        printf(
            "%d %s pc=%08x word=%08x rd=%s rs1=%s rs2=%s imm=%d f3=%d "
            "next=%d target=%d mem=%d vd1=%d vd2=%d fold=%s uses=",
            i, kind_name[nd->kind], nd->pc, nd->word, rd, rs1, rs2, nd->imm,
            nd->funct3, nd->next, nd->target, nd->mem, nd->vd1, nd->vd2,
            fold_name[fold_kind(nd->word)]);
        if (g->use_cnt[i] == 0)
            putchar('-');
        else
            for (int u = 0; u < g->use_cnt[i]; u++)
                printf("%s%d", u ? "," : "", g->use_edges[g->use_off[i] + u]);
        putchar('\n');
    }
}

/* Find the whitespace-delimited token "key=<int>" on a line and parse the int
 * exactly (no substring matches, no trailing junk).
 *
 * Returns true and sets *out on a clean match; returns false and sets *bad=true
 * when the key is present but its value is not a clean integer; returns false
 * with *bad=false when absent.
 */
static bool token_int(const char *line, const char *key, long *out, bool *bad)
{
    const size_t klen = strlen(key);
    for (const char *p = line; *p;) {
        while (*p == ' ' || *p == '\t' || *p == '\n')
            p++;
        const char *tok = p;
        while (*p && *p != ' ' && *p != '\t' && *p != '\n')
            p++;
        if ((size_t) (p - tok) > klen + 1 && !strncmp(tok, key, klen) &&
            tok[klen] == '=') {
            char *end;
            const long v = strtol(tok + klen + 1, &end, 10);
            if (end != p) {
                *bad = true;
                return false;
            }
            *out = v;
            return true;
        }
    }
    return false;
}

/* Read a dumped IR from FILE ('-' = stdin) and structurally verify it: node
 * count matches the header, every edge (next/target/mem/vd1/vd2) is present and
 * indexes a real node (or NONE), the entry is in range, and the memory chain
 * only points backward (so it is acyclic). Exits nonzero on any violation.
 */
static int check_ir(const char *path)
{
    FILE *f = open_input(path);

    static const char *const edge_key[] = {"next", "target", "mem", "vd1",
                                           "vd2"};
    char line[512];
    int declared = -1, entry = -1, seen = 0, ok_edges = 1;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == ';') {
            long d, e;
            bool bad = false;
            if (token_int(line, "nodes", &d, &bad)) {
                declared = (int) d;
                entry = token_int(line, "entry", &e, &bad) ? (int) e : -1;
            }
            continue;
        }
        if (line[0] < '0' || line[0] > '9')
            continue;
        const int idx = atoi(line);
        if (idx != seen) {
            fprintf(stderr, "rvopt: node %d out of order (saw %d)\n", seen,
                    idx);
            ok_edges = 0;
        }
        long edges[5];
        for (int e = 0; e < 5; e++) {
            bool bad = false;
            if (!token_int(line, edge_key[e], &edges[e], &bad) || bad) {
                fprintf(stderr, "rvopt: node %d has malformed/missing %s\n",
                        idx, edge_key[e]);
                ok_edges = 0;
                edges[e] = NONE;
            }
            if (edges[e] != NONE && (edges[e] < 0 || edges[e] >= declared)) {
                fprintf(stderr, "rvopt: node %d %s -> %ld out of range\n", idx,
                        edge_key[e], edges[e]);
                ok_edges = 0;
            }
        }
        /* mem chain (index 2) must point strictly backward. */
        if (edges[2] != NONE && edges[2] >= idx) {
            fprintf(stderr, "rvopt: node %d mem -> %ld not backward\n", idx,
                    edges[2]);
            ok_edges = 0;
        }
        seen++;
    }
    if (f != stdin)
        fclose(f);

    if (declared < 0)
        die("no '; nodes=' header found", NULL);
    if (seen != declared) {
        fprintf(stderr, "rvopt: header declares %d nodes, found %d\n", declared,
                seen);
        return 1;
    }
    if (entry < 0 || entry >= declared) {
        fprintf(stderr, "rvopt: entry %d out of range\n", entry);
        return 1;
    }
    if (!ok_edges)
        return 1;
    printf("ok: %d nodes, entry %d\n", declared, entry);
    return 0;
}

/* mux lowering: emit a standalone native MUXLEQ image */

/* When true, the emit_* helpers only advance the native position and print
 * nothing -- a sizing pass that fills na[] so pass 2 can resolve every branch
 * target. Running the SAME emitter to size and to emit makes na[] correct by
 * construction (no per-macro hand-counted size to drift out of sync).
 */
static bool g_sizing = false;

/* A cell can exceed a signed int (the MOVE mask constant 0x80000006, a full
 * 32-bit li value), so take/print 64-bit and let the VM fold each back to
 * uint32 on load. MOVE32 is a MUX with mask-address 6 (hardwired 0); IOMARK32
 * (-1 == 0xFFFFFFFF) is the I/O / halt marker.
 */
#define MOVE32 2147483654LL /* 0x80000006 = (1<<31) | 6 */
#define IOMARK32 (-1LL)     /* 0xFFFFFFFF */

static void emit_i32(int *p, long long a, long long b, long long c)
{
    if (!g_sizing)
        printf("%lld\n%lld\n%lld\n", a, b, c);
    *p += 3;
}



/* Resolved effect of an ecall. SYS_WRITE folds a static-buffer write to inline
 * PUTs; SYS_WRITE_DYN emits a runtime PUT loop reading live guest RAM (for a
 * runtime buffer/length, or when a reachable STORE could have mutated the
 * bytes).
 */
enum sys_kind { SYS_NONE, SYS_EXIT, SYS_WRITE, SYS_WRITE_DYN, SYS_BAD };
struct sysinfo {
    enum sys_kind kind;
    uint32_t buf, len; /* SYS_WRITE: static source bytes [buf, buf+len) */
};

/* Compile-time constant register values, tracked in program order. li12 sets a
 * known value; any other write clears it; a basic-block leader clears all (a
 * branch join makes predecessor values unknown). x0 is always 0.
 */
struct cprop {
    uint32_t val[32];
    bool known[32];
};

static void cprop_clear(struct cprop *c)
{
    for (int r = 0; r < 32; r++)
        c->known[r] = false;
    c->known[0] = true; /* x0 == 0 always */
    c->val[0] = 0;
}

static void cprop_update(struct cprop *c, const struct node *nd)
{
    const int rd = (nd->word >> 7) & 31;
    if (rd == 0)
        return;
    if (fold_kind(nd->word) == FOLD_LI12) {
        c->known[rd] = true;
        c->val[rd] = (uint32_t) nd->imm;
        return;
    }

    /* Upper immediates are compile-time constants too: LUI rd = imm, AUIPC rd =
     * pc + imm (nd->imm already holds the << 12 value). Tracking them lets a
     * 'jalr rd, rs1, imm' whose rs1 is an auipc/lui result resolve to a static
     * target (resolve_jalr).
     */
    if (nd->kind == K_LUI) {
        c->known[rd] = true;
        c->val[rd] = (uint32_t) nd->imm;
        return;
    }
    if (nd->kind == K_AUIPC) {
        c->known[rd] = true;
        c->val[rd] = nd->pc + (uint32_t) nd->imm;
        return;
    }

    /* ADDI rd, rs1, imm folds through a known rs1 (the second half of 'la':
     * auipc then addi). funct3==0 only; other OP-IMMs stay unknown. (ADDI rd,
     * x0 is FOLD_LI12, handled above.)
     */
    if (nd->kind == K_OPIMM && nd->funct3 == 0 && c->known[nd->rs1]) {
        c->known[rd] = true;
        c->val[rd] = c->val[nd->rs1] + (uint32_t) nd->imm;
        return;
    }

    /* Every other rd-writing KIND makes rd a runtime value. Keyed on kind, not
     * a raw rd field, since BRANCH/STORE put immediate bits where rd sits.
     */
    switch (nd->kind) {
    case K_JAL:
    case K_JALR:
    case K_LOAD:
    case K_OP:
    case K_OPIMM:
        c->known[rd] = false;
        break;
    default: /* BRANCH/STORE/FENCE/SYSTEM: no rd */
        break;
    }
}

/* Resolve each ecall to SYS_EXIT / SYS_WRITE / SYS_WRITE_DYN / SYS_BAD via a
 * single program-order constant-propagation pass (operands are li'd in the
 * ecall's own block, so in-block constants suffice). 'used' bounds a foldable
 * write's static source; a runtime buffer/length falls to the dynamic loop.
 */
static void analyze_syscalls(const struct graph *g,
                             size_t used,
                             struct sysinfo *sys)
{
    struct cprop c;
    cprop_clear(&c);
    for (int i = 1; i < g->count; i++) {
        const struct node *nd = &g->n[i];
        if (nd->leader)
            cprop_clear(&c);
        sys[i].kind = SYS_NONE;
        if (nd->kind == K_SYSTEM) {
            const uint32_t funct12 = nd->word >> 20;
            const int a7 = 17, a1 = 11, a2 = 12; /* ecall ABI registers */
            if (funct12 != 0 || !c.known[a7]) {
                sys[i].kind = SYS_BAD; /* ebreak/CSR, or unresolved a7 */
            } else if (c.val[a7] == 93) {
                sys[i].kind = SYS_EXIT;
            } else if (c.val[a7] == 64) { /* write (fd a0 ignored) */
                if (c.known[a1] && c.known[a2] &&
                    (uint64_t) c.val[a1] + c.val[a2] <= used) {
                    sys[i].kind = SYS_WRITE; /* static buffer -> fold to PUTs */
                    sys[i].buf = c.val[a1];
                    sys[i].len = c.val[a2];
                } else {
                    sys[i].kind =
                        SYS_WRITE_DYN; /* runtime buffer/len -> loop */
                }
            } else {
                sys[i].kind = SYS_BAD; /* unknown syscall */
            }
        }
        cprop_update(&c, nd);
    }
}

/* Resolve computed/linking JALR targets. When rs1 is a compile-time constant
 * (an auipc/lui/li result in the same block), 'jalr rd, rs1, imm' jumps to a
 * STATIC guest address (rs1 + imm, low bit cleared); record its target NODE in
 * nd->target -- exactly like a JAL -- so the reachability walk follows it and
 * emit lowers a direct jump (+ a pc+4 link when rd != 0). A jalr whose rs1 is a
 * runtime value (notably 'ret', rs1 = ra, which cprop never knows since JAL
 * clears its rd) keeps target == NONE and falls back to the ra-checked ret
 * form. Same in-block cprop as analyze_syscalls; MUST run before mark_reachable
 * so the target joins the emitted set.
 */
static void resolve_jalr(struct graph *g)
{
    /* A resolved JALR is a NEW control-flow entry into its target, so that
     * target must become a leader -- otherwise this pass (and analyze_syscalls,
     * which shares the leader-clears-cprop rule) would leak the linear
     * predecessor's constants into a node reached only by the jump, and could
     * misresolve a later JALR or fold a write with registers not live on the
     * jumped-from path. Marking a target leader can change cprop clearing,
     * which can change which JALRs resolve, so iterate to a fixpoint (leaders
     * only grow; each pass re-resolves every JALR from scratch).
     */
    bool changed = true;
    while (changed) {
        changed = false;
        struct cprop c;
        cprop_clear(&c);
        for (int i = 1; i < g->count; i++) {
            struct node *nd = &g->n[i];
            if (nd->leader)
                cprop_clear(&c);
            if (nd->kind == K_JALR) {
                int tgt = NONE;
                if (c.known[nd->rs1]) {
                    const uint32_t a =
                        (c.val[nd->rs1] + (uint32_t) nd->imm) & ~1u;
                    tgt = addr2node(g, a); /* NONE if not a decoded instr */
                }
                nd->target = tgt; /* reset every pass so a stale target cannot
                                     survive a newly inserted leader
                                     */
                if (tgt != NONE && !g->n[tgt].leader) {
                    g->n[tgt].leader = 1;
                    changed = true;
                }
            }
            cprop_update(&c, nd);
        }
    }
}

/* Control-flow successors of node i: the fall-through (unless the node
 * terminates) plus a branch/jump target. Writes up to 2 node indexes into
 * succ[] and returns the count. Only 'jal ra' and resolved 'jalr ra,...' have a
 * return site (matching the ret model); 'j', 'jal x5', and runtime JALR do not
 * fall through; an ecall exit terminates.
 */
static int successors(const struct graph *g,
                      const struct sysinfo *sys,
                      int i,
                      int succ[2])
{
    const struct node *nd = &g->n[i];
    int n = 0;
    const int fall = addr2node(g, nd->pc + 4);
    const int rd = (nd->word >> 7) & 31;
    const bool link = rd == 1 && (nd->kind == K_JAL ||
                                  (nd->kind == K_JALR && nd->target != NONE));
    const bool terminates = (nd->kind == K_JAL && !link) ||
                            (nd->kind == K_JALR && !link) ||
                            (nd->kind == K_SYSTEM && sys[i].kind == SYS_EXIT);
    if (!terminates && fall != NONE)
        succ[n++] = fall;
    if (nd->target != NONE)
        succ[n++] = nd->target;
    return n;
}

/* Reachable-node set: DFS from the entry over successors(). Skips trailing
 * .rodata that a linear decode turned into ILL nodes (no path reaches them).
 */
static void mark_reachable(const struct graph *g,
                           const struct sysinfo *sys,
                           bool *reach)
{
    int *stack = xcalloc((size_t) g->count, sizeof *stack);
    int sp = 0;
    stack[sp++] = g->entry;
    while (sp) {
        const int i = stack[--sp];
        if (i == NONE || i <= 0 || i >= g->count || reach[i])
            continue;
        reach[i] = true;
        int succ[2];
        const int ns = successors(g, sys, i, succ);
        for (int k = 0; k < ns; k++)
            stack[sp++] = succ[k];
    }
    free(stack);
}

/* Can control reach node 'to' starting AFTER node 'from' executes (i.e. from
 * from's successors)? This decides whether a store into a code word could
 * RE-EXECUTE the modified instruction -- the real self-modifying-code hazard. A
 * store onto a word that is never revisited (code space used as scratch, a
 * store past the instruction it overwrites) is harmless and must not be
 * flagged.
 */
static bool reaches_after(const struct graph *g,
                          const struct sysinfo *sys,
                          int from,
                          int to)
{
    bool *seen = xcalloc((size_t) g->count, sizeof *seen);
    int *stack = xcalloc((size_t) g->count, sizeof *stack);
    int sp = 0, succ[2];
    for (int k = 0, ns = successors(g, sys, from, succ); k < ns; k++)
        stack[sp++] = succ[k];
    bool hit = false;
    while (sp && !hit) {
        const int i = stack[--sp];
        if (i == NONE || i <= 0 || i >= g->count || seen[i])
            continue;
        if (i == to) {
            hit = true;
            break;
        }
        seen[i] = true;
        int s2[2];
        for (int k = 0, m = successors(g, sys, i, s2); k < m; k++)
            stack[sp++] = s2[k];
    }
    free(seen);
    free(stack);
    return hit;
}

/* Self-modifying-code guard. An interpreter re-fetches each instruction from
 * guest RAM every step, so it honors a guest STORE into its own code; the
 * native mux image bakes decode once, so such a store would silently run the
 * STALE instruction. Refuse rather than miscompile: reject a reachable STORE
 * whose target is a COMPILE-TIME CONSTANT (its base register li'd/la'd in the
 * same block, tracked by cprop) landing on a reachable instruction word. An
 * unknown base (sp-relative stack, computed pointer) is assumed disjoint from
 * code -- the standard freestanding convention; flagging those would reject
 * every real program (all push to sp). The store must also be able to
 * RE-EXECUTE the word it overwrites (reaches_after) -- overwriting an
 * already-passed word, e.g. code space reused as scratch, is harmless. The
 * residual gap -- a store into code through a RUNTIME-computed address -- is
 * not caught here (documented).
 */
static void detect_smc(const struct graph *g,
                       const struct sysinfo *sys,
                       const bool *reach)
{
    struct cprop c;
    cprop_clear(&c);
    for (int i = 1; i < g->count; i++) {
        const struct node *nd = &g->n[i];
        if (nd->leader)
            cprop_clear(&c);
        if (reach[i] && nd->kind == K_STORE && nd->rs1 != NONE &&
            c.known[nd->rs1]) {
            const uint32_t base = c.val[nd->rs1] + (uint32_t) nd->imm;
            const int width = nd->funct3 == 0 ? 1 : nd->funct3 == 1 ? 2 : 4;
            for (int b = 0; b < width; b++) {
                const int tn = addr2node(g, (base + (uint32_t) b) & ~3u);
                if (tn != NONE && reaches_after(g, sys, i, tn)) {
                    fprintf(
                        stderr,
                        "rvopt: self-modifying store at pc=0x%X writes guest "
                        "code at 0x%X (re-executed as an instruction); not "
                        "AOT-compilable\n",
                        nd->pc, base + (uint32_t) b);
                    exit(1);
                }
            }
        }
        cprop_update(&c, nd);
    }
}

/* Lower one guest instruction to native MUXLEQ (or, in the sizing pass, just
 * advance *p). *imm is the running immediate-pair index and *spool the running
 * write-byte index; na[] maps guest instructions to native cells; m holds the
 * layout addresses (all-0 dummies in the sizing pass, which prints nothing). An
 * unsupported instruction or an out-of-range branch target aborts.
 * Constant-folding pass (milestone 2a): a block-local const propagation --
 * independent of analyze_syscalls's cprop -- that marks each reachable
 * non-shift OPIMM whose result is a compile-time constant (rs1 is a known
 * constant, so rd = rs1 op imm is known). A folded node is emitted as a plain
 * 'li' of the result from its OWN imm slot (foldval goes into that cell), so
 * num_imm is unchanged and the imm accounting stays in sync -- just cheaper
 * than the full ALU macro, and byte-identical. Results propagate within the
 * block, so const chains fold (la = lui+addi, then an addi on that, ...). Shift
 * OPIMMs (funct3 1/5) have no imm slot and are left alone (they need a
 * pool-free materializer).
 */

/* 'mv rd, rs' == 'addi rd, rs, 0' with rs != x0: a pure register copy, not a
 * real ALU op. Emitted as two MOVEs (not the full add32), and it needs NO imm
 * slot -- so it is excluded from the imm pool and from the const folder
 * (below), and handled directly when it is emitted. (addi rd, x0, 0 is
 * FOLD_LI12, a different case; addi rd, .., 0 with rd == x0 is FOLD_DEADI.)
 */
static bool is_mv(const struct node *nd)
{
    return nd->kind == K_OPIMM && nd->funct3 == 0 && nd->imm == 0 &&
           nd->rs1 != 0 && ((nd->word >> 7) & 31) != 0;
}

static void compute_folds(const struct graph *g,
                          const bool *reach,
                          bool *folded,
                          int32_t *foldval)
{
    struct cprop c;
    cprop_clear(&c);
    for (int i = 1; i < g->count; i++) {
        const struct node *nd = &g->n[i];
        if (nd->leader)
            cprop_clear(&c);
        const int rd = (nd->word >> 7) & 31;
        if (reach[i] && nd->kind == K_OPIMM && rd && nd->funct3 != 1 &&
            nd->funct3 != 5 && c.known[nd->rs1] &&
            fold_kind(nd->word) != FOLD_LI12 && !is_mv(nd)) {
            const uint32_t a = c.val[nd->rs1], b = (uint32_t) nd->imm;
            uint32_t r;
            switch (nd->funct3) {
            case 2: /* SLTI  */
                r = (int32_t) a < (int32_t) b;
                break;
            case 3: /* SLTIU */
                r = a < b;
                break;
            case 4: /* XORI  */
                r = a ^ b;
                break;
            case 6: /* ORI   */
                r = a | b;
                break;
            case 7: /* ANDI  */
                r = a & b;
                break;
            default: /* ADDI (funct3 0) */
                r = a + b;
                break;
            }
            folded[i] = true;
            foldval[i] = (int32_t) r;
            c.known[rd] = true;
            c.val[rd] = r; /* propagate so const chains fold */
        } else {
            cprop_update(&c, nd);
        }
    }
}

/* Store-to-load forwarding (redundant-load elimination). A reachable WORD load
 * from a stack slot that a WORD store wrote earlier IN THE SAME BASIC BLOCK,
 * with the stored value's register still live and no MAY-aliasing store
 * between, is redundant: its result is that store's rs2. fwd[L] records that
 * register (emit a copy, or nothing when rd == rs2, instead of the LW). Sound
 * because same-block = straight-line, so the store definitely ran; the walk
 * BLOCKS on any store that may overlap (a different base, or the same base with
 * an overlapping offset). Only word<-word is forwarded (no width mismatch /
 * re-extension). This is the lever for spill-heavy -O0 code
 * (tests/rv32i/unopt); the -O2 demos, with few loads, are unaffected.
 */
static void compute_forwards(const struct graph *g, const bool *reach, int *fwd)
{
    for (int i = 1; i < g->count; i++) {
        fwd[i] = NONE;
        const struct node *L = &g->n[i];
        if (!reach[i] || L->kind != K_LOAD || L->funct3 != 2 || L->rd == NONE)
            continue; /* reachable LW (word load) with rd != x0 only */
        for (int mp = L->mem; mp != NONE; mp = g->n[mp].mem) {
            /* Stop the walk at a block boundary (a leader in (mp, i] => mp is
             * in an earlier block, unsound to forward across) OR once the base
             * register L->rs1 is redefined in (mp, i): then mp's rs1 holds a
             * DIFFERENT address than L's, so mp->imm and L->imm are NOT
             * comparable (the classic store-forwarding miscompile). L's own def
             * of rd (k == i) reads rs1 first, so it does not count.
             */
            bool stop = false;
            for (int k = mp + 1; k <= i; k++)
                if (g->n[k].leader ||
                    (k != i && L->rs1 != 0 && g->n[k].rd == L->rs1)) {
                    stop = true;
                    break;
                }
            if (stop)
                break;
            const struct node *M = &g->n[mp];
            if (M->kind == K_LOAD)
                continue; /* a load does not modify memory */
            if (M->rs1 == L->rs1 && M->imm == L->imm && M->funct3 == 2) {
                bool redef = false; /* rs2 still live at L? */
                for (int k = mp + 1; !redef && k < i; k++)
                    if (g->n[k].rd == M->rs2)
                        redef = true;
                if (!redef)
                    fwd[i] = M->rs2; /* rs2 == x0 is fine: reads back as 0 */
                break;
            }
            if (M->rs1 != L->rs1)
                break; /* different base -> may alias -> block */
            const int mw = M->funct3 == 0 ? 1 : M->funct3 == 1 ? 2 : 4;
            if (!(M->imm + mw <= L->imm || L->imm + 4 <= M->imm))
                break; /* overlapping same-base range -> may alias -> block */
            /* same base, disjoint range -> no alias, keep walking back */
        }
    }
}

/* Register promotion ANALYSIS (loop-carried memory -> a dedicated cell). This
 * pass only IDENTIFIES opportunities (shown in dump); the emit that consumes
 * them (a pre-header load, in-loop cell moves, a post-loop store) is a later
 * milestone. Detects a SIMPLE natural loop: one back-edge (a reachable
 * branch/jump whose target is an earlier node = the header), a straight-line
 * body [header, latch] whose only control transfer is the latch's back-branch,
 * exactly ONE external entry edge, and the single exit = the latch's
 * fall-through. Within such a loop a stack slot (base, imm) is PROMOTABLE when:
 *   - the base register is loop-invariant (never written in the loop) -- else
 *     the slot address changes and the offsets are not comparable;
 *   - every memory op in the loop targets a KNOWN slot (an unknown-base load or
 *     store may alias everything and blocks ALL promotion in the loop);
 *   - no OTHER accessed slot overlaps this one's [imm, imm+4) range;
 *   - no write-ecall runs in the loop (it would observe stale memory for a slot
 *     held only in a cell).
 * The emit will bracket the loop with a pre-header load + post-loop store, so
 * memory stays correct for code outside the loop (incl. the zero-iteration and
 * live-in/live-out cases).
 */
#define PROMO_MAX_LOOPS 8
#define PROMO_MAX_SLOTS 8

struct promo_slot {
    int base, imm; /* the promotable stack slot: base register + offset */
    int g;         /* emit-assigned global slot index: cell pair is
                    * promo_base + 2*g; offset imm cell is
                    * imm_base + 2*(promo_imm_base + g)
                    */
};

struct promo_loop {
    int header, latch; /* back-edge target; back-branch */
    int entry, exit;   /* sole external entry node; the latch's fall-through */
    int nslot;
    struct promo_slot slot[PROMO_MAX_SLOTS];
};

static int compute_promotions(const struct graph *g,
                              const bool *reach,
                              struct promo_loop *out)
{
    int nloops = 0;
    for (int latch = 1; latch < g->count && nloops < PROMO_MAX_LOOPS; latch++) {
        const struct node *L = &g->n[latch];
        const int header = L->target;
        if (!reach[latch] || header == NONE || header >= latch ||
            !(L->kind == K_BRANCH || L->kind == K_JAL))
            continue; /* a reachable back-edge (target before the latch) */

        /* Body [header, latch] must be straight-line: only the latch is a
         * control transfer, and it is the sole exit (its fall-through leaves).
         */
        bool simple = true;
        for (int k = header; k < latch && simple; k++)
            if (g->n[k].target != NONE || is_block_end(g->n[k].kind))
                simple =
                    false; /* an internal branch/jump/ender -> not simple */
        if (!simple)
            continue;

        /* Exactly one external entry edge into the loop (a node OUTSIDE the
         * body whose next/target lands inside [header, latch]). Its source node
         * is where the emit will attach the pre-header load.
         */
        int entry = NONE, nentry = 0;
        for (int k = 1; k < g->count; k++) {
            if (k >= header && k <= latch)
                continue; /* inside the loop */
            const struct node *nk = &g->n[k];
            if ((nk->target >= header && nk->target <= latch) ||
                (nk->next >= header && nk->next <= latch)) {
                entry = k;
                nentry++;
            }

            /* Block ends carry no 'next', but two fall through to pc+4: a call
             * (JAL with link, rd==x1) via its return, and a non-exit ecall. A
             * such fall-through into the loop is an entry the raw next/target
             * miss -- count it, else it is an unseen second entry the
             * pre-header on 'entry' would not dominate. (An exit ecall does NOT
             * fall through, but lacking syscall analysis here, counting every
             * K_SYSTEM only over-rejects, which is safe.)
             */
            const bool call = nk->kind == K_JAL && ((nk->word >> 7) & 31) == 1;
            if (call || nk->kind == K_SYSTEM) {
                const int ret = addr2node(g, nk->pc + 4);
                if (ret >= header && ret <= latch) {
                    entry = k;
                    nentry++;
                }
            }
        }
        if (nentry != 1)
            continue; /* not a single-entry loop -> skip (conservative) */

        /* No ecall in the loop: a write would read stale slot memory, and
         * resolving write-vs-exit needs syscall analysis this pass avoids -- so
         * conservatively block on ANY K_SYSTEM in the body.
         */
        bool has_sys = false;
        for (int k = header; k <= latch && !has_sys; k++)
            if (g->n[k].kind == K_SYSTEM)
                has_sys = true;
        if (has_sys)
            continue;

        /* Collect slots. ALL loop memory ops must share ONE base register --
         * two DIFFERENT registers can hold the SAME address, which per-register
         * slot identity would treat as independent cells (a store to one
         * leaving the other's read stale); requiring a single base makes (base,
         * imm) an exact address. Accesses must be WORD width: the emit's
         * promotion is a word-granular cell move, so a byte/half access
         * (needing lane + extend handling) blocks it. A loop-variant base, a
         * second base, an unknown base, or a subword access blocks the whole
         * loop. The post-loop store attaches as a PREFIX of the exit node (the
         * latch's fall-through); that node must be reached ONLY from the latch,
         * else a non-loop path into it would wrongly run the stores. Count the
         * exit's predecessors (next/target + call/ecall fall-through to pc+4);
         * the latch itself is the single expected one.
         */
        const int exit = g->n[latch].next;
        if (exit == NONE)
            continue;
        int npred = 0;
        for (int k = 1; k < g->count; k++) {
            const struct node *nk = &g->n[k];
            if (nk->next == exit || nk->target == exit)
                npred++;
            else if (((nk->kind == K_JAL && ((nk->word >> 7) & 31) == 1) ||
                      nk->kind == K_SYSTEM) &&
                     addr2node(g, nk->pc + 4) == exit)
                npred++;
        }
        if (npred != 1)
            continue; /* exit not reached exclusively from the loop */

        struct promo_loop lp = {header, latch, entry, exit, 0, {{0, 0, 0}}};
        bool blocked = false;
        int loopbase = NONE;
        for (int k = header; k <= latch && !blocked; k++) {
            const struct node *nd = &g->n[k];
            if (nd->kind != K_LOAD && nd->kind != K_STORE)
                continue;
            if (nd->rs1 == NONE || nd->funct3 != 2) {
                blocked =
                    true; /* unknown base or subword -> unsafe to promote */
                break;
            }
            if (loopbase == NONE)
                loopbase = nd->rs1;
            else if (nd->rs1 != loopbase) {
                blocked = true; /* a second base register may alias the first */
                break;
            }

            /* base written anywhere in the loop -> address not loop-invariant
             */
            bool variant = false;
            for (int j = header; j <= latch; j++)
                if (g->n[j].rd == nd->rs1) {
                    variant = true;
                    break;
                }
            if (variant) {
                blocked = true;
                break;
            }
            bool known =
                false; /* same base is guaranteed, so imm alone identifies */
            for (int t = 0; t < lp.nslot; t++)
                if (lp.slot[t].imm == nd->imm)
                    known = true;
            if (!known && lp.nslot < PROMO_MAX_SLOTS)
                lp.slot[lp.nslot++] = (struct promo_slot) {nd->rs1, nd->imm, 0};
            else if (!known)
                blocked = true; /* out of slot room -> give up on this loop */
        }
        if (blocked)
            continue;

        /* Distinct same-base slots must be disjoint 4-byte ranges; an overlap
         * means one access could observe another's promoted-away write.
         */
        for (int a = 0; a < lp.nslot && !blocked; a++)
            for (int b = a + 1; b < lp.nslot; b++)
                if (!(lp.slot[a].imm + 4 <= lp.slot[b].imm ||
                      lp.slot[b].imm + 4 <= lp.slot[a].imm))
                    blocked = true;
        if (blocked || lp.nslot == 0)
            continue;

        /* The pre-header load prefixes the entry node and reads the base
         * register + slot memory; the entry node's own code runs AFTER it. So
         * the entry must not change what the preload just read: reject if it
         * writes the base register (a fall-through 'addi fp,sp,N' would preload
         * with the old base) or is a store (which could update a slot before
         * the loop should observe it). A pure jump-in entry (unopt's JAL) is
         * inert.
         */
        if (g->n[entry].rd == loopbase || g->n[entry].kind == K_STORE)
            continue;

        out[nloops++] = lp;
    }
    return nloops;
}

/* Per-node register-promotion emit info (built from compute_promotions after
 * the layout assigns each slot a cell + offset imm-pool index). All three
 * arrays are NONE-filled except at the relevant nodes.
 */
struct promo_emit {
    const int
        *pre; /* node -> loop whose pre-header LOADS attach here (entry) */
    const int
        *post; /* node -> loop whose post-loop STORES attach here (exit) */
    const int
        *cell; /* node -> a promoted in-loop LOAD/STORE's slot cell (lo) */
    const struct promo_loop *loops;
};

/* Assign each accepted promotable loop a contiguous slot index g and map its
 * in-loop word LOAD/STOREs to that slot. Rejects a loop (nslot = 0, so the
 * data-region walk emits no offset cells for it, keeping num_imm in sync) when
 * a single node would carry two colliding edge actions: another loop already
 * claims its entry or exit node, or its own entry IS its exit. The emitter runs
 * a node's pre before its post, so any such sharing would order the transfers
 * wrong. The slot index is width-independent; the emitter scales it to a cell
 * address when it places promo_base. The three pro_* arrays must be NONE-filled
 * by the caller.
 *
 * Returns npromo (total slots).
 */
static int assign_promo_slots(const struct graph *g,
                              struct promo_loop *loops,
                              int nloops,
                              int *pro_pre,
                              int *pro_post,
                              int *pro_cell)
{
    int npromo = 0;
    for (int l = 0; l < nloops; l++) {
        struct promo_loop *lp = &loops[l];
        if (lp->entry == lp->exit || pro_pre[lp->entry] != NONE ||
            pro_post[lp->entry] != NONE || pro_pre[lp->exit] != NONE ||
            pro_post[lp->exit] != NONE) {
            lp->nslot = 0;
            continue;
        }
        pro_pre[lp->entry] = l;
        pro_post[lp->exit] = l;
        for (int s = 0; s < lp->nslot; s++) {
            lp->slot[s].g = npromo++;
            for (int k = lp->header; k <= lp->latch; k++) {
                const struct node *nd = &g->n[k];
                if ((nd->kind == K_LOAD || nd->kind == K_STORE) &&
                    nd->funct3 == 2 && nd->rs1 == lp->slot[s].base &&
                    nd->imm == lp->slot[s].imm)
                    pro_cell[k] = lp->slot[s].g; /* this access -> the cell */
            }
        }
    }
    return npromo;
}

/* Data-cell layout of the emitted MUXLEQ image. */
struct m32 {
    int imm_base;       /* one cell per li / immediate-ALU / JAL-link value */
    int promo_imm_base; /* imm-pool index where promoted-slot offsets start */
    int ret_base;       /* one cell per known JAL-return address */
    int spool_base;     /* static write() source bytes */
    int reg_base;       /* 32-cell register file */
    int promo_base;     /* register-promotion dedicated word cells */
    int z, neg1;        /* the constants 0 and -1 (the equality add-1 test) */
    int sgn, one;       /* 0x80000000 (bit31 / sign flip) and 1 (the DEC) */
    int t0, t1, t2;     /* three scratch cells (also OL=t0, BT=t1 for memory) */
    int sh1, sh2;       /* the two sign-flipped halves for a signed compare */
    int m1f, mff;       /* 0x1F (shift-amount mask) and 0xFF (byte mask) */
    int winmask;        /* guest RAM window size - 1 (in-window address mask) */
    int rambc;          /* the ram_base value (added after the window mask) */
    int mask_base; /* 32 power-of-two cells 2^0..2^31 (shift bit extraction) */
    int ram_base;  /* guest RAM window (one cell per byte), init from img */
};

struct ret_sites {
    int n;
    int *target;    /* resolved callee entry node */
    int *node;      /* native destination nodes for pc+4 after jal ra */
    uint32_t *addr; /* guest return addresses compared against x1 */
};

/* An ALU funct3 the wide emitter lowers natively: ADD/SUB(0), SLT(2), SLTU(3),
 * XOR(4), OR(6), AND(7). Shifts (1/5) are a later slice.
 */
static bool alu_f3_ok32(int f3)
{
    return f3 == 0 || f3 == 2 || f3 == 3 || f3 == 4 || f3 == 6 || f3 == 7;
}

/* A node the wide ALU slice can lower. A K_OP must ALSO carry the base-ISA
 * funct7 (0x00, or 0x20 for SUB) -- else an RV32M or reserved encoding sharing
 * a funct3 (MUL as ADD, DIV as XOR, ...) would silently mislower; a K_OPIMM has
 * no funct7 field (the immediate occupies it) so funct3 alone decides.
 */
static bool op_ok32(const struct node *nd)
{
    if (nd->kind == K_OPIMM)
        return alu_f3_ok32(nd->funct3);
    if (nd->kind != K_OP || !alu_f3_ok32(nd->funct3))
        return false;
    const int f7 = (nd->word >> 25) & 0x7F;
    return nd->funct3 == 0 ? (f7 == 0x00 || f7 == 0x20) : f7 == 0x00;
}

/* A load/store this slice lowers (its offset needs an imm cell): all of
 * SB/SH/SW and LB/LH/LW/LBU/LHU. funct3 == 3 (RV64 doubleword) is excluded.
 */
static bool mem_ok32(const struct node *nd)
{
    return (nd->kind == K_STORE && nd->funct3 <= 2) || /* SB/SH/SW */
           (nd->kind == K_LOAD && nd->funct3 <= 5 &&
            nd->funct3 != 3); /* LB/LH/LW/LBU/LHU (funct3 0/1/2/4/5) */
}

/* A node consumes an imm cell iff it is a li or an immediate ALU op
 * (ADDI/ANDI/ORI/XORI, rd != x0), except 'mv' which is a pure register copy.
 * The count, emit, and data passes all key on this predicate so the imm-pool
 * indices line up.
 */
static bool imm_op32(const struct node *nd)
{
    if (fold_kind(nd->word) == FOLD_LI12)
        return true;
    if (is_mv(nd))
        return false;
    if (nd->kind == K_OPIMM && ((nd->word >> 7) & 31) &&
        alu_f3_ok32(nd->funct3))
        return true;
    if ((nd->kind == K_LUI || nd->kind == K_AUIPC) && ((nd->word >> 7) & 31))
        return true; /* upper immediate: a compile-time constant */
    if (mem_ok32(nd))
        return true; /* a load/store's byte offset */
    if (nd->kind == K_JALR && nd->target != NONE && ((nd->word >> 7) & 31))
        return true; /* static-target JALR link: pc+4 */
    return nd->kind == K_JAL &&
           ((nd->word >> 7) & 31); /* JAL-with-link: pc+4 */
}

/* Wide instruction shorthands. c = MOVE32 is a MOVE; c = *p+3 is a
 * non-branching SUBLEQ (b -= a, then fall through -- the target is the next
 * cell, so it is taken or not with the same effect); c = (1<<31)|mask is a MUX
 * whose mask value is the cell at 'mask'.
 */
static void mov32(int *p, long long s, long long d)
{
    emit_i32(p, s, d, MOVE32);
}
static void subnb32(int *p, long long a, long long b)
{
    emit_i32(p, a, b, *p + 3);
}
static void mux32op(int *p, long long a, long long b, long long mask)
{
    emit_i32(p, a, b, (1LL << 31) | mask);
}

/* SLE0(a,b,L): t0 = a - b; branch to L if signed <= 0 (else fall through). */
static void sle0_32(int *p,
                    long long a,
                    long long b,
                    long long L,
                    const struct m32 *m)
{
    mov32(p, a, m->t0);
    emit_i32(p, b, m->t0, L);
}

/* EQ32 / NE32(a,b,L): branch to L iff a == b / a != b. SLE0 proves a-b <= 0,
 * then adding 1 (SUBLEQ of -1) splits a-b < 0 (a<b) from a-b == 0 (equal).
 * Correct for any 32-bit a,b: equality is exact regardless of a-b overflow.
 * Each is a fixed-size block, so the two-pass sizing stays exact.
 */
static void eq32(int *p,
                 long long a,
                 long long b,
                 long long L,
                 const struct m32 *m)
{
    const long long start = *p, ne = start + 15; /* fall-through = not equal */
    sle0_32(p, a, b, start + 9, m);  /* a-b<=0 -> C (start+9); else a>b */
    emit_i32(p, m->z, m->z, ne);     /* a>b: not equal, skip */
    emit_i32(p, m->neg1, m->t0, ne); /* C: (a-b)+1<=0 (a<b) -> not equal */
    emit_i32(p, m->z, m->z, L);      /* a-b==0: equal -> L */
}
static void ne32(int *p,
                 long long a,
                 long long b,
                 long long L,
                 const struct m32 *m)
{
    const long long start = *p;
    sle0_32(p, a, b, start + 9, m); /* a-b<=0 -> C; else a>b -> L */
    emit_i32(p, m->z, m->z, L);     /* a>b: not equal -> L */
    emit_i32(p, m->neg1, m->t0, L); /* C: a<b -> L; else a==b, fall through */
}

/* LTU32(a,b,Lless,Lge): branch to Lless if a <u b (unsigned), else to Lge. The
 * borrow-out of a-b is bit31(MUX(b|d, b&d, a)), d = a-b -- the same one-MUX
 * top-bit identity at bit31 -- then a bit31 test picks the target. A fixed
 * 11-instruction (33-cell) block, so two-pass sizing stays exact.
 */
static void ltu32(int *p,
                  long long a,
                  long long b,
                  long long Lless,
                  long long Lge,
                  const struct m32 *m)
{
    mov32(p, a, m->t0);
    subnb32(p, b, m->t0); /* t0 = d = a - b */
    mov32(p, b, m->t1);
    mux32op(p, m->t0, m->t1, b); /* t1 = (d & ~b) | b = b | d */
    mov32(p, b, m->t2);
    mux32op(p, m->z, m->t2, m->t0);  /* t2 = b & d */
    mux32op(p, m->t1, m->t2, a);     /* t2's bit31 = borrow = (a <u b) */
    mux32op(p, m->z, m->t2, m->sgn); /* t2 &= 0x80000000 (isolate bit31) */
    subnb32(p, m->one, m->t2);     /* t2 -= 1: -1 if clear, 0x7FFFFFFF if set */
    emit_i32(p, m->z, m->t2, Lge); /* t2 <= 0 (bit31 clear, a >= b) -> Lge */
    emit_i32(p, m->z, m->z, Lless); /* else (bit31 set, a < b) -> Lless */
}

/* sh = rs ^ 0x80000000 (subtracting SGN flips bit31 and nothing lower), mapping
 * signed order onto the unsigned order LTU32 tests -- for BLT/BGE/SLT.
 */
static void signflip32(int *p, long long rs, long long sh, const struct m32 *m)
{
    mov32(p, rs, sh);
    subnb32(p, m->sgn, sh);
}

/* acc <<= 1: acc = acc + acc. t1 = -acc first (reads acc), then acc -= t1. */
static void dbl32(int *p, long long acc, const struct m32 *m)
{
    mov32(p, m->z, m->t1);
    subnb32(p, acc, m->t1);
    subnb32(p, m->t1, acc);
}

/* dst += m[cell] (cell holds a constant): t2 = -m[cell], then dst -= t2. */
static void addcell32(int *p,
                      long long dst,
                      long long cell,
                      const struct m32 *m)
{
    mov32(p, m->z, m->t2);
    subnb32(p, cell, m->t2);
    subnb32(p, m->t2, dst);
}

/* copybit: if bit sb of src is set, set bit db of dst (dst += 2^db). BT = src &
 * 2^sb via a MUX with the 2^sb mask cell; a SUBLEQ then skips the add when the
 * bit is clear. bit 31 (2^31 is negative) needs a DEC before the <=0 test so
 * "set" reads as > 0.
 */
static void copybit32(int *p,
                      long long src,
                      int sb,
                      long long dst,
                      int db,
                      const struct m32 *m)
{
    mov32(p, src, m->t1);
    mux32op(p, m->z, m->t1, m->mask_base + sb); /* t1 = src & 2^sb */
    if (sb == 31)
        subnb32(p, m->one, m->t1);     /* -1 if clear, 0x7FFFFFFF if set */
    emit_i32(p, m->z, m->t1, *p + 12); /* clear -> skip the 9-cell add */
    addcell32(p, dst, m->mask_base + db, m);
}

/* SLLI: rd = rs1 << k, k self-doublings of an accumulator. */
static void shift_left32(int *p,
                         long long rs1,
                         long long rd,
                         int k,
                         const struct m32 *m)
{
    if (k == 0) {
        mov32(p, rs1, rd);
        return;
    }
    mov32(p, rs1, m->t0);
    for (int i = 0; i < k; i++)
        dbl32(p, m->t0, m);
    mov32(p, m->t0, rd);
}

/* SRLI/SRAI: rd = rs1 >> k. Result bit d comes from source bit d+k; SRLI zeroes
 * the top k bits (dmax = 31-k), SRAI fills them with the sign bit 31 (dmax =
 * 31, source bit clamped to 31). Built bit-by-bit into a zeroed accumulator.
 */
static void shift_right32(int *p,
                          long long rs1,
                          long long rd,
                          int k,
                          bool arith,
                          const struct m32 *m)
{
    if (k == 0) {
        mov32(p, rs1, rd);
        return;
    }
    mov32(p, m->z, m->t0); /* acc = 0 */
    const int dmax = arith ? 31 : 31 - k;
    for (int d = 0; d <= dmax; d++) {
        int sbit = d + k;
        if (sbit > 31)
            sbit = 31; /* SRAI sign fill */
        copybit32(p, rs1, sbit, m->t0, d, m);
    }
    mov32(p, m->t0, rd);
}

/* A shift this slice lowers: immediate SLLI (funct7 0x00), SRLI (0x00), SRAI
 * (0x20), or register SLL (funct7 0x00) / SRL (0x00) / SRA (0x20). rd == x0 is
 * a valid nop, admitted here and dropped at emit time.
 */
static bool shift_ok32(const struct node *nd)
{
    const int f7 = (nd->word >> 25) & 0x7F;
    if (nd->kind == K_OP) { /* register shift: SLL, or SRL/SRA */
        if (nd->funct3 == 1)
            return f7 == 0x00;
        return nd->funct3 == 5 && (f7 == 0x00 || f7 == 0x20);
    }
    if (nd->kind != K_OPIMM)
        return false;
    if (nd->funct3 == 1)
        return f7 == 0x00;
    if (nd->funct3 == 5)
        return f7 == 0x00 || f7 == 0x20;
    return false;
}

/* SLL: rd = rs1 << (rs2 & 0x1F), a count-down loop that doubles an accumulator
 * the (runtime) shift-amount times. cnt = rs2 & 0x1F (t2), acc = rs1 (t0). The
 * body dbl32 is 9 cells, so the whole loop is fixed-size and the self-relative
 * loop/done addresses hold in both sizing and real passes.
 */
static void shift_left_reg32(int *p,
                             long long rs1,
                             long long rs2,
                             long long rd,
                             const struct m32 *m)
{
    mov32(p, rs2, m->t2);            /* cnt = rs2 */
    mux32op(p, m->z, m->t2, m->m1f); /* cnt &= 0x1F */
    mov32(p, rs1, m->t0);            /* acc = rs1 */
    const long long loop = *p;
    emit_i32(p, m->z, m->t2,
             loop + 18);           /* cnt == 0 -> done (test+body+dec+jmp) */
    dbl32(p, m->t0, m);            /* acc <<= 1 */
    subnb32(p, m->one, m->t2);     /* cnt -= 1 */
    emit_i32(p, m->z, m->z, loop); /* back to the test */
    mov32(p, m->t0, rd);           /* done: rd = acc */
}

/* Cell count of one shift_right32 by 1 (measured; SRL and SRA differ by the
 * sign-fill copybit), for the register-shift loop's exit label.
 */
static int shr1_cells32(bool arith, const struct m32 *m)
{
    const bool save = g_sizing;
    g_sizing = true;
    int p = 0;
    shift_right32(&p, 0, 0, 1, arith, m);
    g_sizing = save;
    return p;
}

/* SRL/SRA: rd = rs1 >> (rs2 & 0x1F), a count-down loop doing one right shift by
 * 1 per step (shift_right32 k=1, logical or arithmetic). cnt = rs2 & 0x1F
 * (sh2), acc = rs1 (sh1) -- NOT t0/t2, which shift_right32's copybit clobbers.
 * The body is fixed-size, so the self-relative loop/done addresses hold in both
 * passes.
 */
static void shift_right_reg32(int *p,
                              long long rs1,
                              long long rs2,
                              long long rd,
                              bool arith,
                              const struct m32 *m)
{
    mov32(p, rs2, m->sh2);            /* cnt = rs2 */
    mux32op(p, m->z, m->sh2, m->m1f); /* cnt &= 0x1F */
    mov32(p, rs1, m->sh1);            /* acc = rs1 */
    const long long loop = *p;
    /* test(3) + body + dec(3) + jmp(3) = 9 + shr1_cells before the done mov. */
    const long long done = loop + 9 + shr1_cells32(arith, m);
    emit_i32(p, m->z, m->sh2, done);               /* cnt == 0 -> done */
    shift_right32(p, m->sh1, m->sh1, 1, arith, m); /* acc >>= 1 */
    subnb32(p, m->one, m->sh2);                    /* cnt -= 1 */
    emit_i32(p, m->z, m->z, loop);                 /* back to the test */
    mov32(p, m->sh1, rd);                          /* done: rd = acc */
}

/* OL (t0) = the NATIVE cell address of guest byte (rs1 + imm + k): compute the
 * guest address, mask it into the power-of-two RAM window, then add ram_base.
 * The window is one cell per guest byte, so byte k is one cell past byte 0.
 */
static void emit_addr32(int *p,
                        long long rs1,
                        long long imm_cell,
                        int k,
                        const struct m32 *m)
{
    mov32(p, rs1, m->t0);             /* OL = rs1 */
    addcell32(p, m->t0, imm_cell, m); /* OL += imm (guest address) */
    for (int j = 0; j < k; j++)
        addcell32(p, m->t0, m->one, m);  /* OL += k (the k-th byte's cell) */
    mux32op(p, m->z, m->t0, m->winmask); /* OL &= window-1 (in-window) */
    addcell32(p, m->t0, m->rambc, m);    /* OL += ram_base (native cell) */
}

/* Store m[val] to the guest cell OL points at, by self-modifying a MOVE's dest
 * operand to OL then running it. (OL must already hold the native address.)
 */
static void store_at32(int *p, long long val, const struct m32 *m)
{
    const long long mi = *p + 3;        /* the store MOVE lands here */
    emit_i32(p, m->t0, mi + 1, MOVE32); /* patch its dest operand := OL */
    emit_i32(p, val, 0, MOVE32); /* MOVE m[val] -> m[OL] (dest patched) */
}

/* Load the guest cell OL points at into m[dst], by self-modifying a MOVE's
 * source operand to OL then running it.
 */
static void load_at32(int *p, long long dst, const struct m32 *m)
{
    const long long mi = *p + 3;    /* the load MOVE lands here */
    emit_i32(p, m->t0, mi, MOVE32); /* patch its source operand := OL */
    emit_i32(p, 0, dst, MOVE32);    /* MOVE m[OL] -> m[dst] (source patched) */
}

/* SB: store rs2's low byte to guest[rs1+imm]. BT (t1) = rs2 & 0xFF (the RAM
 * cell holds a bare byte), then an SMC store.
 */
static void emit_store_byte32(int *p,
                              long long rs2,
                              long long rs1,
                              long long imm_cell,
                              const struct m32 *m)
{
    mov32(p, rs2, m->t1);
    mux32op(p, m->z, m->t1, m->mff); /* BT = rs2 & 0xFF */
    emit_addr32(p, rs1, imm_cell, 0, m);
    store_at32(p, m->t1, m);
}

/* LBU: rd = guest[rs1+imm] (a bare 0..255 byte, so zero-extended for free). */
static void emit_load_byte_u32(int *p,
                               long long rd,
                               long long rs1,
                               long long imm_cell,
                               const struct m32 *m)
{
    emit_addr32(p, rs1, imm_cell, 0, m);
    load_at32(p, m->t1, m); /* BT = the byte */
    mov32(p, m->t1, rd);    /* rd = byte (high bits already 0) */
}

/* dst = byte 'bi' of src (bits [8*bi, 8*bi+7] moved down to [0,7]) via 8
 * copybits. Used to split a word into its four RAM-cell bytes. copybit uses
 * t1/t2, so dst must be sh1/sh2 (not a scratch cell).
 */
static void extract_byte32(int *p,
                           long long src,
                           int bi,
                           long long dst,
                           const struct m32 *m)
{
    mov32(p, m->z, dst);
    for (int j = 0; j < 8; j++)
        copybit32(p, src, 8 * bi + j, dst, j, m);
}

/* Sign-extend the value in 'acc' in place: if bit 'sb' is set, set every bit
 * above it (sb+1..31). copybit re-reads acc's bit sb (never modified, since
 * only higher bits change) and ORs 2^hb into the currently-zero high bits.
 */
static void sign_extend32(int *p, long long acc, int sb, const struct m32 *m)
{
    for (int hb = sb + 1; hb <= 31; hb++)
        copybit32(p, acc, sb, acc, hb, m);
}

/* SB/SH/SW as 'n' little-endian bytes (n = 2 half, 4 word; SB uses the cheaper
 * masked emit_store_byte32). The address is computed once; OL walks to the next
 * cell after each byte.
 */
static void emit_store_bytes32(int *p,
                               long long rs2,
                               long long rs1,
                               long long imm_cell,
                               int n,
                               const struct m32 *m)
{
    emit_addr32(p, rs1, imm_cell, 0, m);
    for (int i = 0; i < n; i++) {
        extract_byte32(p, rs2, i, m->sh1, m); /* sh1 = byte i */
        store_at32(p, m->sh1, m);             /* m[OL] = byte i */
        if (i < n - 1)
            addcell32(p, m->t0, m->one, m); /* OL += 1 (next byte cell) */
    }
}

/* LH/LHU/LW as 'n' little-endian bytes (n = 2 half, 4 word; LBU uses the
 * cheaper emit_load_byte_u32). Each RAM cell holds a bare 0..255 byte; copybit
 * places byte i's 8 bits at rd bits [8*i, 8*i+7], disjoint so the accumulator
 * ORs cleanly. 'sign' fills the top bits from the last byte's high bit (LH).
 */
static void emit_load_bytes32(int *p,
                              long long rd,
                              long long rs1,
                              long long imm_cell,
                              int n,
                              bool sign,
                              const struct m32 *m)
{
    emit_addr32(p, rs1, imm_cell, 0, m);
    mov32(p, m->z, m->sh2); /* acc = 0 */
    for (int i = 0; i < n; i++) {
        load_at32(p, m->sh1, m); /* sh1 = byte i */
        for (int j = 0; j < 8; j++)
            copybit32(p, m->sh1, j, m->sh2, 8 * i + j, m);
        if (i < n - 1)
            addcell32(p, m->t0, m->one, m); /* OL += 1 */
    }
    if (sign)
        sign_extend32(p, m->sh2, 8 * n - 1, m); /* LH: fill from bit 8n-1 */
    mov32(p, m->sh2, rd);                       /* rd = the assembled value */
}

/* LB: rd = sign-extended guest[rs1+imm] (a bare 0..255 byte; bit 7 fills bits
 * 8..31). Like LBU plus the sign fill.
 */
static void emit_load_byte_s32(int *p,
                               long long rd,
                               long long rs1,
                               long long imm_cell,
                               const struct m32 *m)
{
    emit_addr32(p, rs1, imm_cell, 0, m);
    load_at32(p, m->sh1, m);        /* sh1 = byte (0..255) */
    sign_extend32(p, m->sh1, 7, m); /* fill bits 8..31 from bit 7 */
    mov32(p, m->sh1, rd);
}

/* The value an imm cell holds: a JAL link is its return address (pc+4), an
 * AUIPC is pc + (imm<<12), everything else (li, immediate ALU, LUI) is the
 * (already <<12 for LUI) immediate.
 */
static long long imm_value32(const struct node *nd)
{
    if (nd->kind == K_JAL || nd->kind == K_JALR)
        return nd->pc + 4; /* JAL/JALR link: return address */
    if (nd->kind == K_AUIPC)
        return nd->pc + (uint32_t) nd->imm;
    return nd->imm;
}

/* Native address of a branch/jump target. Like mux_target32, but also resolves
 * a jump to the word ONE PAST the last instruction (pc == 4*(count-1)) to
 * na[count] = the epilogue, so a program that jumps to its end (rather than an
 * ecall/ret) lands correctly instead of erroring.
 */
static long long mux_target32(const struct graph *g,
                              const struct node *nd,
                              const int *na)
{
    const uint32_t t = nd->pc + (uint32_t) nd->imm;
    const int tn = addr2node(g, t);
    if (tn != NONE)
        return na[tn];
    if (!(t & 3) && t == 4u * (uint32_t) (g->count - 1))
        return na[g->count]; /* jump past the end -> the epilogue */
    fprintf(stderr, "rvopt mux: branch target out of range at pc %u\n", nd->pc);
    exit(1);
}

/* Cell count of emit_addr32 with k=0 (measured, not a formula), for the write
 * loop's exit label.
 */
static int addr_cells32(const struct m32 *m)
{
    const bool save = g_sizing;
    g_sizing = true;
    int p = 0;
    emit_addr32(&p, 0, 0, 0, m);
    g_sizing = save;
    return p;
}

/* A write(fd, a1, a2): PUT the a2 bytes of live guest RAM from guest address
 * a1, one per iteration. sh1 walks the guest pointer, sh2 counts down. Each
 * byte's native cell is chosen by SMC (emit_addr32) and PUT via a patched
 * output instruction, so it reads live RAM and is correct after any store. The
 * fd (a0) is ignored (all output goes to stdout).
 */
static void emit_write_dyn32(int *p, const struct m32 *m)
{
    const long long a1 = m->reg_base + 11, a2 = m->reg_base + 12;
    mov32(p, a1, m->sh1); /* PTR = a1 (guest buffer address) */
    mov32(p, a2, m->sh2); /* CNT = a2 (length) */
    const long long loop = *p;

    /* eq32 (not a signed SUBLEQ) so any 32-bit length terminates exactly: 15
     * (eq32) + addr + 3 (patch) + 3 (PUT) + 9 (PTR+=1) + 3 (CNT-=1) + 3.
     */
    const long long done = loop + 36 + addr_cells32(m);
    eq32(p, m->sh2, m->z, done, m);     /* CNT == 0 -> done */
    emit_addr32(p, m->sh1, m->z, 0, m); /* t0 = ram_base + (PTR & winmask) */
    const long long mi = *p + 3;        /* the PUT lands here */
    emit_i32(p, m->t0, mi, MOVE32);     /* patch its source operand := OL */
    emit_i32(p, 0, IOMARK32, 0);     /* PUT m[OL] -> stdout (source patched) */
    addcell32(p, m->sh1, m->one, m); /* PTR += 1 */
    subnb32(p, m->one, m->sh2);      /* CNT -= 1 (non-branching) */
    emit_i32(p, m->z, m->z, loop);   /* back to the test */
}

static void emit_promo_transfer32(int *p,
                                  const struct promo_loop *lp,
                                  const struct m32 *m,
                                  bool load)
{
    for (int s = 0; s < lp->nslot; s++) {
        const int g = lp->slot[s].g;
        const long long cell = m->promo_base + g;
        const long long base = m->reg_base + lp->slot[s].base;
        const long long immc = m->imm_base + m->promo_imm_base + g;
        if (load)
            emit_load_bytes32(p, cell, base, immc, 4, false, m);
        else
            emit_store_bytes32(p, cell, base, immc, 4, m);
    }
}

static bool ret_site_matches32(const struct graph *g,
                               const struct sysinfo *sys,
                               const struct ret_sites *rets,
                               int site,
                               int ret_node)
{
    return rets->target[site] == ret_node ||
           reaches_after(g, sys, rets->target[site], ret_node);
}

static int ret_site_count32(const struct graph *g,
                            const struct sysinfo *sys,
                            const struct ret_sites *rets,
                            int ret_node)
{
    int n = 0;
    for (int i = 0; i < rets->n; i++)
        if (ret_site_matches32(g, sys, rets, i, ret_node))
            n++;
    return n;
}

/* 'ret' (jalr x0,x1,0): jump to a matching call site's return address, but only
 * when ra actually equals it. Unknown ra halts rather than misjump.
 */
static void emit_ret_dispatch32(const struct graph *g,
                                const struct sysinfo *sys,
                                int *p,
                                const int *na,
                                const struct ret_sites *rets,
                                int ret_node,
                                const struct m32 *m)
{
    for (int i = 0; i < rets->n; i++) {
        if (!ret_site_matches32(g, sys, rets, i, ret_node))
            continue;
        const long long start = *p, nomatch = start + 15;
        ne32(p, m->reg_base + 1, m->ret_base + i, nomatch,
             m); /* ra != this return site */
        emit_i32(p, m->z, m->z, na[rets->node[i]]);
    }
    emit_i32(p, m->z, m->z, IOMARK32); /* no known return address matched */
}

/* Emit one wide instruction: li, or the native single-cell ALU. Every ALU form
 * computes into a scratch cell (t0) then MOVEs to rd, so rd may alias rs1/rs2.
 * The second operand is rs2's cell (K_OP) or the imm cell (K_OPIMM).
 */
static void emit_one32(const struct graph *g,
                       int i,
                       const struct sysinfo *sys,
                       const struct ret_sites *rets,
                       const struct m32 *m,
                       const int *na,
                       const bool *folded,
                       const int *fwd,
                       const struct promo_emit *pe,
                       int *p,
                       int *imm,
                       int *spool)
{
    const struct node *nd = &g->n[i];
    const int rd = (nd->word >> 7) & 31;
    const int fk = fold_kind(nd->word);

    /* Promotion brackets a loop (see emit_one32): the pre-header loads and
     * post-loop stores prefix the sole entry/exit node so the cells are live
     * across the loop and memory is current on exit.
     */
    if (pe->pre[i] != NONE)
        emit_promo_transfer32(p, &pe->loops[pe->pre[i]], m, true);
    if (pe->post[i] != NONE)
        emit_promo_transfer32(p, &pe->loops[pe->post[i]], m, false);
    if (fk == FOLD_DEADI)
        return; /* nop */
    if (fk == FOLD_LI12 || folded[i]) {
        mov32(p, m->imm_base + *imm, m->reg_base + rd); /* rd = imm */
        (*imm)++;
        return;
    }
    if (is_mv(nd)) {
        mov32(p, m->reg_base + nd->rs1, m->reg_base + rd);
        return;
    }
    if (nd->kind == K_JAL) {
        if (rd) { /* link = pc+4 into rd (its imm cell) */
            mov32(p, m->imm_base + *imm, m->reg_base + rd);
            (*imm)++;
        }
        emit_i32(p, m->z, m->z,
                 mux_target32(g, nd, na)); /* unconditional jump */
        return;
    }
    if (nd->kind == K_LUI || nd->kind == K_AUIPC) {
        if (rd) { /* a compile-time constant (imm<<12, or pc+imm<<12) into rd */
            mov32(p, m->imm_base + *imm, m->reg_base + rd);
            (*imm)++;
        }
        return;
    }
    if (nd->kind == K_BRANCH) {
        const long long L = mux_target32(g, nd, na); /* taken target */
        const long long s1 = m->reg_base + nd->rs1, s2 = m->reg_base + nd->rs2;
        const long long start = *p;
        switch (nd->funct3) {
        case 0:
            eq32(p, s1, s2, L, m);
            break;
        case 1:
            ne32(p, s1, s2, L, m);
            break;
        case 6: /* BLTU: less -> L, else fall (past the 33-cell block) */
            ltu32(p, s1, s2, L, start + 33, m);
            break;
        case 7: /* BGEU: not-less -> L, less -> fall */
            ltu32(p, s1, s2, start + 33, L, m);
            break;
        case 4: /* BLT: signed, via the sign-flipped halves */
            signflip32(p, s1, m->sh1, m);
            signflip32(p, s2, m->sh2, m);
            ltu32(p, m->sh1, m->sh2, L, start + 45, m);
            break;
        default: /* BGE (funct3 == 5): the BLT targets swapped */
            signflip32(p, s1, m->sh1, m);
            signflip32(p, s2, m->sh2, m);
            ltu32(p, m->sh1, m->sh2, start + 45, L, m);
            break;
        }
        return;
    }
    if (nd->kind ==
        K_STORE) { /* SB/SH/SW (no rd; an imm cell for the offset) */
        const long long rs2c = m->reg_base + nd->rs2,
                        rs1c = m->reg_base + nd->rs1, ic = m->imm_base + *imm;
        if (pe->cell[i] != NONE) {
            mov32(p, rs2c, m->promo_base + pe->cell[i]);
            (*imm)++;
            return;
        }
        if (nd->funct3 == 0)
            emit_store_byte32(p, rs2c, rs1c, ic, m); /* SB: masked low byte */
        else /* SH (funct3 1) = 2 bytes, SW (funct3 2) = 4 bytes */
            emit_store_bytes32(p, rs2c, rs1c, ic, nd->funct3 == 1 ? 2 : 4, m);
        (*imm)++;
        return;
    }
    if (nd->kind == K_LOAD) { /* LB/LH/LW/LBU/LHU */
        /* rd == x0: a dead load, so skip the cell/forward routing and the load
         * itself, but still consume the imm cell at the bottom (as with rd !=
         * 0) to keep the sizing and emit passes' imm counters in step.
         */
        if (rd) {
            const long long rdc = m->reg_base + rd,
                            rs1c = m->reg_base + nd->rs1,
                            ic = m->imm_base + *imm;
            if (pe->cell[i] != NONE) {
                mov32(p, m->promo_base + pe->cell[i], rdc);
                (*imm)++;
                return;
            }
            if (fwd[i] != NONE) {
                if (fwd[i] != rd)
                    mov32(p, m->reg_base + fwd[i], rdc);
                (*imm)++;
                return;
            }
            switch (nd->funct3) {
            case 0: /* LB: signed byte */
                emit_load_byte_s32(p, rdc, rs1c, ic, m);
                break;
            case 4: /* LBU: unsigned byte */
                emit_load_byte_u32(p, rdc, rs1c, ic, m);
                break;
            case 1: /* LH: signed half */
                emit_load_bytes32(p, rdc, rs1c, ic, 2, true, m);
                break;
            case 5: /* LHU: unsigned half */
                emit_load_bytes32(p, rdc, rs1c, ic, 2, false, m);
                break;
            default: /* LW (funct3 2): word */
                emit_load_bytes32(p, rdc, rs1c, ic, 4, false, m);
            }
        }
        (*imm)++; /* the imm cell is consumed even when rd == x0 */
        return;
    }
    if (nd->kind == K_SYSTEM) { /* ecall: exit (halt) or write */
        if (sys[i].kind == SYS_EXIT) {
            emit_i32(p, m->z, m->z, IOMARK32); /* halt (SUBLEQ Z,Z,-1) */
        } else if (sys[i].kind == SYS_WRITE) {
            for (uint32_t k = 0; k < sys[i].len; k++) {
                emit_i32(p, m->spool_base + *spool, IOMARK32,
                         0); /* PUT staged byte */
                (*spool)++;
            }
        } else { /* SYS_WRITE_DYN */
            emit_write_dyn32(p, m);
        }
        return;
    }
    if (nd->kind == K_JALR) {
        /* Static-target JALR (resolve_jalr set nd->target from a compile-time
         * rs1): write the pc+4 link if rd != 0, then jump to the resolved cell.
         * The runtime rs1 is irrelevant -- the target is a compile-time address
         * -- so this is correct even for 'jalr rd, rd, 0'.
         */
        if (nd->target != NONE) {
            if (rd) { /* link = pc+4 into rd (its imm cell) */
                mov32(p, m->imm_base + *imm, m->reg_base + rd);
                (*imm)++;
            }
            emit_i32(p, m->z, m->z, na[nd->target]); /* jump to the target */
            return;
        }
        /* Else 'jalr x0, x1, 0' (= ret) through known call-site returns. */
        if (rd == 0 && nd->rs1 == 1 && nd->imm == 0 &&
            ret_site_count32(g, sys, rets, i) > 0) {
            emit_ret_dispatch32(g, sys, p, na, rets, i, m);
            return;
        }
        fprintf(stderr, "rvopt mux: unsupported JALR at pc %u\n", nd->pc);
        exit(1);
    }
    if (!rd)
        return; /* ALU writing x0: result discarded, no imm cell consumed */
    if (nd->kind == K_OPIMM && (nd->funct3 == 1 || nd->funct3 == 5)) {
        /* SLLI / SRLI / SRAI: the shift amount is baked in, so no imm cell. */
        const long long rs1c = m->reg_base + nd->rs1, rdc = m->reg_base + rd;
        const int k = nd->imm & 31;
        if (nd->funct3 == 1)
            shift_left32(p, rs1c, rdc, k, m);
        else
            shift_right32(p, rs1c, rdc, k, (nd->word & 0x40000000) != 0, m);
        return;
    }
    if (nd->kind == K_OP && nd->funct3 == 1) { /* SLL: register shift left */
        shift_left_reg32(p, m->reg_base + nd->rs1, m->reg_base + nd->rs2,
                         m->reg_base + rd, m);
        return;
    }
    if (nd->kind == K_OP &&
        nd->funct3 == 5) { /* SRL/SRA: register shift right */
        shift_right_reg32(p, m->reg_base + nd->rs1, m->reg_base + nd->rs2,
                          m->reg_base + rd, (nd->word & 0x40000000) != 0, m);
        return;
    }
    const long long a = m->reg_base + nd->rs1;
    const long long b =
        nd->kind == K_OPIMM ? m->imm_base + *imm : m->reg_base + nd->rs2;
    if (nd->funct3 == 2 || nd->funct3 == 3) {
        /* SLT / SLTU: rd = (a < b) ? 1 : 0. LTU32 branches to a 1-into-rd or a
         * 0-into-rd block; SLT sign-flips first. The block sizes below are
         * fixed so the branch offsets are exact in both passes.
         */
        const long long rdc = m->reg_base + rd, start = *p;
        if (nd->funct3 == 3) { /* SLTU */
            ltu32(p, a, b, start + 33, start + 39,
                  m);                            /* less->set, ge->clear */
            mov32(p, m->one, rdc);               /* set: rd = 1 */
            emit_i32(p, m->z, m->z, start + 42); /* jump past clear */
            mov32(p, m->z, rdc);                 /* clear: rd = 0 */
        } else {                                 /* SLT (signed) */
            signflip32(p, a, m->sh1, m);
            signflip32(p, b, m->sh2, m);
            ltu32(p, m->sh1, m->sh2, start + 45, start + 51, m);
            mov32(p, m->one, rdc);               /* set: rd = 1 */
            emit_i32(p, m->z, m->z, start + 54); /* jump past clear */
            mov32(p, m->z, rdc);                 /* clear: rd = 0 */
        }
        if (nd->kind == K_OPIMM)
            (*imm)++;
        return;
    }
    switch (nd->funct3) {
    case 0: /* ADD, or SUB when K_OP funct7 == 0x20 */
        if (nd->kind == K_OP && ((nd->word >> 25) & 0x7F) == 0x20) {
            mov32(p, a, m->t0);   /* t0 = rs1 */
            subnb32(p, b, m->t0); /* t0 -= rs2 */
        } else {
            mov32(p, a, m->t0);       /* t0 = rs1 */
            mov32(p, m->z, m->t1);    /* t1 = 0 */
            subnb32(p, b, m->t1);     /* t1 = -b */
            subnb32(p, m->t1, m->t0); /* t0 -= (-b) = rs1 + b */
        }
        break;
    case 7: /* AND: t0 = (0 & ~b) | (rs1 & b) */
        mov32(p, a, m->t0);
        mux32op(p, m->z, m->t0, b);
        break;
    case 6: /* OR: t0 = (rs1 & ~b) | (b & b) = rs1 | b */
        mov32(p, b, m->t0);
        mux32op(p, a, m->t0, b);
        break;
    default: /* XOR (4): (rs1 & ~b) | (b & ~rs1), the two halves disjoint */
        mov32(p, m->z, m->t1);
        mux32op(p, a, m->t1, b); /* t1 = rs1 & ~b */
        mov32(p, m->z, m->t2);
        mux32op(p, b, m->t2, a); /* t2 = b & ~rs1 */
        mov32(p, m->t2, m->t0);
        mux32op(p, m->t1, m->t0, m->t2); /* t0 = (t1 & ~t2) | t2 = t1 | t2 */
        break;
    }
    mov32(p, m->t0, m->reg_base + rd); /* rd = result */
    if (nd->kind == K_OPIMM)
        (*imm)++;
}

/* Emit a WIDE (32-bit-cell) standalone MUXLEQ image the VM runs directly. A
 * whole 32-bit RV32I register lives in ONE cell, so the ALU is native
 * single-cell SUBLEQ/MUX (no lo/hi halves, no carry/borrow votes) and the
 * address space is not capped at 32768 cells. Covers li + the native ALU +
 * SLT/SLTU + LUI/AUIPC + all six branches + JAL (with an na[] target map),
 * shifts, memory, and ecalls. Arbitrary runtime JALR stays a hard error. The
 * epilogue PUTs each defined register's low byte then halts.
 */
static void emit_mux(struct graph *g, const unsigned char *img, size_t used)
{
    struct sysinfo *sys = xcalloc((size_t) g->count, sizeof *sys);
    bool *reach = xcalloc((size_t) g->count, sizeof *reach);
    resolve_jalr(g);
    analyze_syscalls(g, used, sys);
    mark_reachable(g, sys, reach);
    /* refuse self-modifying code, never miscompile it */
    detect_smc(g, sys, reach);

    bool *folded = xcalloc((size_t) g->count, sizeof *folded);
    int32_t *foldval = xcalloc((size_t) g->count, sizeof *foldval);
    compute_folds(g, reach, folded, foldval);
    int *fwd = xcalloc((size_t) g->count, sizeof *fwd);
    compute_forwards(g, reach, fwd);

    struct promo_loop *loops = xcalloc((size_t) PROMO_MAX_LOOPS, sizeof *loops);
    const int nloops = compute_promotions(g, reach, loops);
    int *pro_pre = xcalloc((size_t) g->count, sizeof *pro_pre);
    int *pro_post = xcalloc((size_t) g->count, sizeof *pro_post);
    int *pro_cell = xcalloc((size_t) g->count, sizeof *pro_cell);
    for (int i = 0; i < g->count; i++)
        pro_pre[i] = pro_post[i] = pro_cell[i] = NONE;
    const int npromo =
        assign_promo_slots(g, loops, nloops, pro_pre, pro_post, pro_cell);
    const struct promo_emit pe = {pro_pre, pro_post, pro_cell, loops};

    bool has_store = false;
    for (int i = 1; i < g->count; i++)
        if (reach[i] && g->n[i].kind == K_STORE)
            has_store = true;
    if (has_store)
        for (int i = 1; i < g->count; i++)
            if (sys[i].kind == SYS_WRITE)
                sys[i].kind = SYS_WRITE_DYN;

    /* Known return sites for 'ret' (jalr x0,x1,0): every reachable 'jal ra,...'
     * or resolved linking JALR contributes its pc+4. A runtime ret dispatch
     * compares x1 against those addresses and jumps to the matching native
     * block.
     */
    struct ret_sites rets = {
        0,
        xcalloc((size_t) g->count, sizeof *rets.target),
        xcalloc((size_t) g->count, sizeof *rets.node),
        xcalloc((size_t) g->count, sizeof *rets.addr),
    };
    for (int i = 1; i < g->count; i++) {
        const int rd = (g->n[i].word >> 7) & 31;
        const bool link_call =
            g->n[i].kind == K_JAL ||
            (g->n[i].kind == K_JALR && g->n[i].target != NONE);
        if (reach[i] && link_call && rd == 1 && g->n[i].target != NONE) {
            const uint32_t addr = g->n[i].pc + 4;
            const int node = addr2node(g, addr);
            if (node != NONE) {
                rets.target[rets.n] = g->n[i].target;
                rets.addr[rets.n] = addr;
                rets.node[rets.n] = node;
                rets.n++;
            }
        }
    }

    int nimm = 0, nspool = 0; /* imm/static-write cells; def regs get PUTs */
    bool def[32] = {false};
    for (int i = 1; i < g->count; i++) {
        if (!reach[i])
            continue;
        const struct node *nd = &g->n[i];
        const int rd = (nd->word >> 7) & 31;
        const int fk = fold_kind(nd->word);
        if (fk == FOLD_DEADI)
            continue; /* nop */
        if (fk == FOLD_LI12) {
            nimm++;
            def[rd] = true;
            continue;
        }
        if (op_ok32(nd)) {
            if (rd) { /* rd == x0 is a nop: no cell, no def */
                def[rd] = true;
                if (nd->kind == K_OPIMM && !is_mv(nd))
                    nimm++;
            }
            continue;
        }
        if (nd->kind == K_JAL || nd->kind == K_LUI || nd->kind == K_AUIPC) {
            if (rd) { /* JAL-link pc+4, or an upper-immediate constant, into rd
                       */
                nimm++;
                def[rd] = true;
            }
            continue;
        }
        if (shift_ok32(nd)) {
            if (rd) /* SLLI/SRLI/SRAI or SLL: defines rd, no imm cell */
                def[rd] = true;
            continue;
        }
        if (nd->kind == K_BRANCH && nd->funct3 != 2 && nd->funct3 != 3)
            continue; /* BEQ/BNE/BLT/BGE/BLTU/BGEU: no imm, no def */
        if (mem_ok32(nd)) {
            nimm++; /* the byte offset */
            if (nd->kind == K_LOAD && rd)
                def[rd] = true; /* LBU defines rd (SB does not) */
            continue;
        }
        if (nd->kind == K_SYSTEM && sys[i].kind != SYS_BAD) {
            if (sys[i].kind == SYS_WRITE)
                nspool += (int) sys[i].len;
            continue; /* ecall: exit/write, no imm cell, no def */
        }
        if (nd->kind == K_JALR && nd->target != NONE) {
            if (rd) { /* static-target JALR: pc+4 link into rd */
                nimm++;
                def[rd] = true;
            }
            continue;
        }
        if (nd->kind == K_JALR && rd == 0 && nd->rs1 == 1 && nd->imm == 0 &&
            ret_site_count32(g, sys, &rets, i) > 0)
            continue; /* ret: no imm cell, no def */
        fprintf(stderr,
                "rvopt mux: unsupported op at pc %u (no computed JALR / "
                "unresolved ecall yet)\n",
                nd->pc);
        free(rets.target);
        free(rets.node);
        free(rets.addr);
        free(pro_cell);
        free(pro_post);
        free(pro_pre);
        free(loops);
        free(fwd);
        free(folded);
        free(foldval);
        free(sys);
        free(reach);
        exit(1);
    }
    int ndef = 0;
    for (int r = 0; r < 32; r++)
        ndef += def[r];
    const int nret_pool = rets.n;
    const int nimm_prog = nimm;
    nimm += npromo;

    /* Sizing pass: variable-size ops mean the code length is not a formula --
     * run the emitter with output suppressed to fill na[] (branch/jump targets)
     * and measure the op length. A forward branch reads a not-yet-set na entry
     * here, but output is suppressed and every block is fixed-size, so the
     * count is exact; the real pass sees the fully-filled na[].
     */
    int *na = xcalloc((size_t) g->count + 1, sizeof *na);
    struct m32 m = {0};
    g_sizing = true;
    int p = 0, imm = 0, spool = 0;
    for (int i = 1; i < g->count; i++) {
        na[i] = p;
        if (reach[i])
            emit_one32(g, i, sys, &rets, &m, na, folded, fwd, &pe, &p, &imm,
                       &spool);
    }
    g_sizing = false;
    na[g->count] = p;                    /* a jump past the end lands here */
    const int code = p + 3 * (ndef + 1); /* ops + one PUT per def reg + halt */

    /* Layout: code | imm cells | return-site cells | static write bytes |
     * 32-cell regfile |
     * constants Z/-1/0x80000000/1 | scratch t0/t1/t2 | sign-flip sh1/sh2 |
     * 0x1F, 0xFF | winmask, rambc | 2^0..2^31 mask pool | guest RAM.
     */
    m.imm_base = code;
    m.promo_imm_base = nimm_prog;
    m.ret_base = m.imm_base + nimm;
    m.spool_base = m.ret_base + nret_pool;
    m.reg_base = m.spool_base + nspool;
    m.promo_base = m.reg_base + 32;
    m.z = m.promo_base + npromo;
    m.neg1 = m.z + 1;
    m.sgn = m.neg1 + 1;
    m.one = m.sgn + 1;
    m.t0 = m.one + 1;
    m.t1 = m.t0 + 1;
    m.t2 = m.t1 + 1;
    m.sh1 = m.t2 + 1;
    m.sh2 = m.sh1 + 1;
    m.m1f = m.sh2 + 1;
    m.mff = m.m1f + 1;
    m.winmask = m.mff + 1;
    m.rambc = m.winmask + 1;
    m.mask_base = m.rambc + 1;
    m.ram_base = m.mask_base + 32;
    /* smallest power of two covering the touched guest bytes */
    int winsize = 1;
    while (winsize < (int) used)
        winsize <<= 1;
    if (m.ram_base + winsize > MUX_MAX_CELLS) {
        fprintf(stderr, "rvopt mux: image needs %d cells (> %d)\n",
                m.ram_base + winsize, MUX_MAX_CELLS);
        free(na);
        free(rets.target);
        free(rets.node);
        free(rets.addr);
        free(pro_cell);
        free(pro_post);
        free(pro_pre);
        free(loops);
        free(fwd);
        free(folded);
        free(foldval);
        free(sys);
        free(reach);
        exit(1);
    }

    p = imm = spool = 0;
    for (int i = 1; i < g->count; i++)
        if (reach[i])
            emit_one32(g, i, sys, &rets, &m, na, folded, fwd, &pe, &p, &imm,
                       &spool);
    for (int r = 0; r < 32; r++)
        if (def[r])
            emit_i32(&p, m.reg_base + r, IOMARK32, 0); /* PUT rd's low byte */
    emit_i32(&p, m.z, m.z, IOMARK32); /* halt (SUBLEQ Z,Z,-1) */

    /* Data: imm values (program order), return-site addresses, static write
     * bytes, regfile, then the constants Z/-1/0x80000000/1, zeroed
     * t0/t1/t2/sh1/sh2, 0x1F/0xFF, winmask/rambc, the 2^0..2^31 mask pool, and
     * the guest RAM window.
     */
    for (int i = 1; i < g->count; i++)
        if (reach[i] && imm_op32(&g->n[i]))
            printf("%lld\n",
                   folded[i] ? (long long) foldval[i] : imm_value32(&g->n[i]));
    for (int l = 0; l < nloops; l++)
        for (int s = 0; s < loops[l].nslot; s++)
            printf("%d\n", loops[l].slot[s].imm);
    for (int i = 0; i < nret_pool; i++)
        printf("%u\n", rets.addr[i]);
    for (int i = 1; i < g->count; i++)
        if (reach[i] && g->n[i].kind == K_SYSTEM && sys[i].kind == SYS_WRITE)
            for (uint32_t k = 0; k < sys[i].len; k++)
                printf("%u\n", img[sys[i].buf + k]);
    for (int r = 0; r < 32; r++)
        printf("0\n"); /* regfile (x0 stays 0) */
    for (int pcell = 0; pcell < npromo; pcell++)
        printf("0\n"); /* promoted word cells */
    printf("0\n-1\n2147483648\n1\n0\n0\n0\n0\n0\n31\n255\n");
    /* Z, -1, SGN(0x80000000), 1, t0, t1, t2, sh1, sh2, 0x1F, 0xFF */
    printf("%d\n%d\n", winsize - 1, m.ram_base); /* winmask, rambc */
    for (int b = 0; b < 32; b++)
        printf("%lld\n", 1LL << b); /* mask pool 2^0 .. 2^31 */
    for (int k = 0; k < winsize; k++)
        printf("%u\n",
               k < (int) used ? img[k] : 0); /* guest RAM, init from img */
    free(na);
    free(pro_cell);
    free(pro_post);
    free(pro_pre);
    free(loops);
    free(fwd);
    free(folded);
    free(foldval);
    free(rets.target);
    free(rets.node);
    free(rets.addr);
    free(sys);
    free(reach);
}

int main(int argc, char **argv)
{
    if (argc == 3 && !strcmp(argv[1], "dump")) {
        size_t used;
        unsigned char *img = load_guest(argv[2], &used);
        struct graph g = decode_graph(img, used);
        dump_graph(&g, argv[2]);

        /* Register-promotion opportunities (analysis only; the emit that
         * consumes them is a later milestone). Printed as ';' comment lines so
         * check ignores them.
         */
        struct sysinfo *sys = xcalloc((size_t) g.count, sizeof *sys);
        analyze_syscalls(&g, used, sys);
        bool *reach = xcalloc((size_t) g.count, sizeof *reach);
        mark_reachable(&g, sys, reach);
        struct promo_loop loops[PROMO_MAX_LOOPS];
        const int nl = compute_promotions(&g, reach, loops);
        printf("; promotions: %d loop(s)\n", nl);
        for (int l = 0; l < nl; l++) {
            printf("; loop header=%d latch=%d entry=%d slots:", loops[l].header,
                   loops[l].latch, loops[l].entry);
            for (int s = 0; s < loops[l].nslot; s++)
                printf(" [x%d%+d]", loops[l].slot[s].base,
                       loops[l].slot[s].imm);
            putchar('\n');
        }
        free(reach);
        free(sys);
        free_graph(&g);
        free(img);
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "check"))
        return check_ir(argv[2]);

    /* The emit pipeline -- load guest image, decode to the graph, emit, free.
     */
    if (argc == 3 && !strcmp(argv[1], "mux")) {
        size_t used;
        unsigned char *img = load_guest(argv[2], &used);
        struct graph g = decode_graph(img, used);
        emit_mux(&g, img, used);
        free_graph(&g);
        free(img);
        return 0;
    }

    fprintf(stderr,
            "usage: rvopt <command> FILE   (FILE = '-' reads stdin)\n"
            "  dump  : decode FILE, write the textual IR to stdout\n"
            "  check : verify a textual IR (as written by dump)\n"
            "  mux   : emit a native MUXLEQ .dec image\n");
    return 2;
}
