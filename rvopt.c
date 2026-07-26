/*
 * rvopt -- standalone RV32I-to-MUXLEQ optimizer.
 *
 * Built OUTSIDE the self-hosted Forth image so it costs zero image cells. It
 * loads an RV32I program (the same ELF32-LE / flat binaries './muxleq -r'
 * accepts), decodes its words into an integer-indexed graph, and dumps or
 * checks that graph as text.
 *
 * Design, per TODO.md and the 'externals/ir' survey: nodes live in a plain
 * index-addressed array (indexes survive array growth; cached pointers do not),
 * and every node carries explicit control, memory, and value edges so later
 * passes have the dependencies spelled out rather than re-derived.
 *
 * Usage:
 *   rvopt -dump FILE    decode FILE, write the textual IR to stdout
 *   rvopt -check FILE    read a textual IR (use '-' for stdin), verify it
 */

#define _POSIX_C_SOURCE 200809L

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Guest RAM window, matched to muxleq.c's -r loader. */
#define RV_RAM_BYTES 32768

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

/* file loading (mirrors muxleq.c's bounds-checked -r loader) */

static uint32_t rd32(const unsigned char *p)
{
    return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t) p[3] << 24;
}
static uint16_t rd16(const unsigned char *p)
{
    return (uint16_t) (p[0] | p[1] << 8);
}

/* Read FILE into a freshly allocated buffer; return it and set *len. */
static unsigned char *slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        die("cannot open", path);
    unsigned char *b = NULL;
    size_t cap = 0, n = 0;
    for (int c; (c = fgetc(f)) != EOF;) {
        if (n == cap)
            b = xrealloc(b, cap = cap ? cap * 2 : 256);
        b[n++] = (unsigned char) c;
    }
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
        sprintf(buf, "x%d", r);
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
         * passes key off it; -check ignores it as it is not an edge.
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
    FILE *f = !strcmp(path, "-") ? stdin : fopen(path, "rb");
    if (!f)
        die("cannot open", path);

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

/* -mux lowering: emit a standalone native MUXLEQ image */

/* When true, the emit_* helpers only advance the native position and print
 * nothing -- a sizing pass that fills na[] so pass 2 can resolve every branch
 * target. Running the SAME emitter to size and to emit makes na[] correct by
 * construction (no per-macro hand-counted size to drift out of sync).
 */
static bool g_sizing = false;

/* Emit one MUXLEQ instruction (3 cells) and advance the native cell position.
 */
static void emit_i(int *p, int a, int b, int c)
{
    if (!g_sizing)
        printf("%d\n%d\n%d\n", a, b, c);
    *p += 3;
}

/* SLE0(a,b,L): T := a (MOVE, mask 32774=0x8006); T -= b (SUBLEQ); branch to L
 * when the 16-bit result a-b is SIGNED <= 0 (the VM's branch test is result==0
 * || bit15, i.e. signed<=0 -- NOT unsigned<=; see the macro-design note).
 * 2 instructions.
 */
static void emit_sle0(int *p, int a, int b, int L, int T)
{
    emit_i(p, a, T, 32774);
    emit_i(p, b, T, L);
}

/* Once SLE0 proves a-b <= 0 and leaves it in T, distinguish a-b == 0 (a==b)
 * from a-b < 0 (a!=b) by adding 1 (SUBLEQ of the -1 cell): '(a-b)+1 <= 0' iff
 * a-b < 0, '> 0' iff a-b == 0. Two signed SLE0 tests would be WRONG -- a-b ==
 * 0x8000 reads BOTH a-b and b-a as signed<=0 (codex 019f7e73).
 *
 * EQ16(a,b,L): branch to L iff a==b, else fall through. 5 instructions.
 */
static void emit_eq16(int *p, int a, int b, int L, int T, int Z, int NEG1)
{
    const int start = *p, ne = start + 15; /* fall-through (not equal) */
    emit_sle0(p, a, b, start + 9, T); /* a-b<=0 -> C; else a>b, not equal */
    emit_i(p, Z, Z, ne);              /* a>b: not equal, skip */
    emit_i(p, NEG1, T, ne);           /* C: (a-b)+1<=0 (a-b<0) -> not eq */
    emit_i(p, Z, Z, L);               /* a-b==0: equal -> L */
}

/* NE16(a,b,L): branch to L iff a!=b, else fall through. 4 instructions. */
static void emit_ne16(int *p, int a, int b, int L, int T, int Z, int NEG1)
{
    emit_sle0(p, a, b, *p + 9, T); /* a-b<=0 -> C; else a>b -> L (not eq) */
    emit_i(p, Z, Z, L);            /* a>b: not equal -> L */
    emit_i(p, NEG1, T, L);         /* C: (a-b)+1<=0 (a-b<0) -> L; else fall */
}

/* Native-image cell layout: every address the emitter needs, computed once in
 * emit_mux and threaded through emit_one (too many cells for a flat arg list).
 * imm_base/reg_base index arrays (immediate pairs, the 64-cell regfile); the
 * rest are single temp/constant cells.
 */
struct mlayout {
    int imm_base;   /* immediate-pair base */
    int spool_base; /* write-ecall byte pool (one cell per output byte) */
    int reg_base;   /* regfile base (lo,hi pairs) */
    int t0;         /* SLE0/EQ16/NE16 compare temp */
    int bt, d, v;   /* LTU16: bit15 temp, a-b diff, 3-vote counter */
    int sh1, sh2;   /* BLT/BGE: the two sign-flipped hi halves */
    int ol, oh;     /* ALU: output lo/hi pair (rd may alias rs1/rs2) */
    int z, neg1, one, sgn; /* constants: 0, -1, 1, 0x8000 */
    int m1f;               /* 0x1F: masks a register shift amount to 0..31 */
    int mff;               /* 0xFF: masks a stored byte to 0..255 */
    int winmask;    /* RAM window size - 1: masks a guest address in-window */
    int rambc;      /* holds the ram_base value (added after the mask) */
    int rsite;      /* the single call site's return address (checked by ret) */
    int mask_base;  /* 16 power-of-two cells 1..0x8000 (right-shift bits) */
    int ram_base;   /* guest RAM window (power-of-two cells), init from img */
    int winsize;    /* the power-of-two window size (cells) */
    int promo_base; /* register-promotion dedicated cell pairs (lo,hi) */
    int promo_imm_base; /* imm-pool index where promoted-slot offset cells start
                         */
};

/* BIT15C tail: branch to L iff bit15(BT) is CLEAR, else fall through. Isolates
 * bit15 with a MUX against the 0x8000 mask cell (c = 0x8000|sgn selects the SGN
 * cell as mask), so BT = BT & 0x8000 (0x8000 set / 0 clear); DEC then makes it
 * 0x7FFF (set, >0 -> fall) or -1 (clear, <=0 -> branch). This dodges the
 * 0x7FFF-overflow trap of a raw signed test (the interpreter's RVBIT15 trick).
 * The MAJ sites (carry/borrow/compare) compute their predicate straight into BT
 * and call this directly, skipping emit_bit15c's leading MOVE. 3 instructions.
 */
static void emit_bit15c_bt(int *p, int L, const struct mlayout *m)
{
    emit_i(p, m->z, m->bt, 0x8000 | m->sgn); /* BT &= 0x8000 (MUX mask SGN) */
    emit_i(p, m->one, m->bt, *p + 3);        /* BT -= 1 (DEC, falls through) */
    emit_i(p, m->z, m->bt, L);               /* BT<=0 (bit15 clear) -> L */
}

/* BIT15C(x,L): the tail above with x first MOVEd into BT. 4 instructions. */
static void emit_bit15c(int *p, int x, int L, const struct mlayout *m)
{
    emit_i(p, x, m->bt, 32774); /* BT = x (MOVE) */
    emit_bit15c_bt(p, L, m);
}

/* LTU16(a,b,L): branch to L iff a <u b (unsigned), else fall through. a <u b is
 * the borrow-out of a-b, so it folds into the same one-MUX top-bit MAJ as sub:
 * bit15(MUX(b|d, b&d, a)), d = a-b (identity fuzzed over 2M pairs).
 * ltu16_cells() measures the size, so callers never hand-count it.
 */
static void emit_ltu16(int *p, int a, int b, int L, const struct mlayout *m)
{
    /* a <u b == borrow-out of a-b == bit15(MUX(b|d, b&d, a)), d = a-b: the same
     * one-MUX top-bit MAJ proven for sub's borrow (identity fuzzed over 2M
     * pairs), replacing the three bit15 votes. T0 = b|d, BT = b&d, then BT
     * bit15 = (a<u b), tested in place.
     */
    emit_i(p, a, m->d, 32774);             /* D = a */
    emit_i(p, b, m->d, *p + 3);            /* D = a - b = diff */
    emit_i(p, b, m->t0, 32774);            /* T0 = b */
    emit_i(p, m->d, m->t0, 0x8000 | b);    /* T0 = (d & ~b) | b = b | d */
    emit_i(p, b, m->bt, 32774);            /* BT = b */
    emit_i(p, m->z, m->bt, 0x8000 | m->d); /* BT = b & d */
    emit_i(p, m->t0, m->bt, 0x8000 | a);   /* BT bit15 = (a <u b) */
    emit_bit15c_bt(p, *p + 9 + 3, m); /* bit15 clear (not less) -> skip JMP */
    emit_i(p, m->z, m->z, L);         /* less -> L */
}

/* Cell count of one emit_ltu16 (measured, not hand-counted, so it can't drift).
 * SLT/SLTU need forward labels that jump over a run of LTU16 macros; this sizes
 * that run by running the emitter with output suppressed.
 */
static int ltu16_cells(const struct mlayout *m)
{
    const bool save = g_sizing;
    g_sizing = true;
    int p = 0;
    emit_ltu16(&p, 0, 0, 0, m);
    g_sizing = save;
    return p;
}

/* MOVE the current 2-cell immediate constant into register rd's lo/hi pair (c =
 * 32774 = 0x8006, a mask-6 copy) and advance the immediate-pair index. Shared
 * by a li and by a JAL-with-link's return address.
 */
static void emit_imm_to_reg(int *p,
                            int imm_base,
                            int reg_base,
                            int rd,
                            int *imm)
{
    emit_i(p, imm_base + 2 * *imm, reg_base + 2 * rd, 32774);
    emit_i(p, imm_base + 2 * *imm + 1, reg_base + 2 * rd + 1, 32774);
    (*imm)++;
}

/* The ALU ops this emitter lowers natively: ADD/SUB, SLT/SLTU, XOR/OR/AND, the
 * immediate shifts SLLI/SRLI/SRAI, the register shifts SLL/SRL/SRA, and the
 * other immediate forms. K_OPIMM li12/deadi are handled by the fold paths.
 */
static bool mux_alu(const struct node *nd)
{
    const int f3 = nd->funct3;
    const int f7 = (nd->word >> 25) & 0x7f;
    if (nd->kind == K_OP) {
        /* funct7 must be a base-ISA value, else it is M-extension (MUL/DIV,
         * f7=0x01) or a reserved encoding -- reject, do not mislower as ADD.
         */
        if (f3 == 0)
            return f7 == 0x00 || f7 == 0x20; /* ADD / SUB */
        if (f3 == 1)
            return f7 == 0x00; /* SLL (register left shift) */
        if (f3 == 5)
            return f7 == 0x00 ||
                   f7 == 0x20; /* SRL / SRA (register right shift) */
        return f7 == 0x00;     /* SLT/SLTU/XOR/OR/AND */
    }
    if (nd->kind == K_OPIMM) {
        const int fk = fold_kind(nd->word);
        if (fk == FOLD_LI12 || fk == FOLD_DEADI)
            return false;
        if (f3 == 1)
            return f7 == 0x00; /* SLLI */
        if (f3 == 5)
            return f7 == 0x00 || f7 == 0x20; /* SRLI / SRAI */
        return true;                         /* ADDI/SLTI/SLTIU/XORI/ORI/ANDI */
    }
    return false;
}

/* One 16-bit half of a bitwise op into 'out'. AND/OR are one MUX each (mask =
 * the rs2 cell, c = 0x8000|b); XOR is out=~a then MUX(a,~a,b) == (a&~b)|(~a&b).
 */
static void emit_bitwise_half(int *p,
                              int f3,
                              int out,
                              int a,
                              int b,
                              const struct mlayout *m)
{
    switch (f3) {
    case 7: /* AND: out = a; out = (Z & ~b) | (out & b) = a & b */
        emit_i(p, a, out, 32774);
        emit_i(p, m->z, out, 0x8000 | b);
        return;
    case 6: /* OR: out = b; out = (a & ~b) | (out & b) = (a&~b) | b = a|b */
        emit_i(p, b, out, 32774);
        emit_i(p, a, out, 0x8000 | b);
        return;
    case 4: /* XOR: out = ~a; out = (a & ~b) | (out & b) = (a&~b)|(~a&b) */
        emit_i(p, m->neg1, out, 32774);
        emit_i(p, a, out, *p + 3); /* out = ONES - a = ~a (falls through) */
        emit_i(p, a, out, 0x8000 | b);
        return;
    }
}

/* rd = rs1 OP rs2 for a bitwise OP. Computes both halves into OL/OH before
 * writing rd, so rd aliasing rs1/rs2 is safe.
 */
static void emit_bitwise(int *p,
                         int f3,
                         int rlo,
                         int rhi,
                         int a_lo,
                         int a_hi,
                         int b_lo,
                         int b_hi,
                         const struct mlayout *m)
{
    emit_bitwise_half(p, f3, m->ol, a_lo, b_lo, m);
    emit_bitwise_half(p, f3, m->oh, a_hi, b_hi, m);
    emit_i(p, m->ol, rlo, 32774);
    emit_i(p, m->oh, rhi, 32774);
}

/* 16-bit 'dst += src': T = -src (Z - src), then dst -= T. D is the temp. */
static void emit_add16(int *p, int dst, int src, const struct mlayout *m)
{
    emit_i(p, m->z, m->d, 32774); /* T = 0 */
    emit_i(p, src, m->d, *p + 3); /* T = -src (falls through) */
    emit_i(p, m->d, dst, *p + 3); /* dst -= T => dst += src */
}

/* Materialize a compile-time 32-bit constant into rd (lo,hi) with NO immediate-
 * pool slot: start at 0 and sum the power-of-two mask cells for each set bit.
 * Used for a linking JALR's return address (pc+4), a value the emitter knows;
 * the emit size is fixed per node (the constant is fixed), so the two passes
 * agree. Emits at most 32 add16s -- fine for a non-hot control-flow op.
 */
static void emit_const16(int *p,
                         int rdst,
                         uint32_t bits,
                         const struct mlayout *m)
{
    emit_i(p, m->z, rdst, 32774); /* rdst = 0 */
    for (int b = 0; b < 16; b++)
        if ((bits >> b) & 1)
            emit_add16(p, rdst, m->mask_base + b, m); /* rdst += 2^b */
}

static void emit_const32(int *p,
                         int rlo,
                         int rhi,
                         uint32_t val,
                         const struct mlayout *m)
{
    emit_const16(p, rlo, val, m);       /* lo half */
    emit_const16(p, rhi, val >> 16, m); /* hi half */
}

/* rd = rs1 + rs2 (32-bit). lo add, then carry = MAJ(bit15 a_lo, bit15 b_lo,
 * !bit15 sum) folds into hi. Computes into OL/OH so rd may alias rs1/rs2.
 */
static void emit_add32(int *p,
                       int rlo,
                       int rhi,
                       int a_lo,
                       int a_hi,
                       int b_lo,
                       int b_hi,
                       const struct mlayout *m)
{
    emit_i(p, a_lo, m->ol, 32774); /* OL = a_lo */
    emit_add16(p, m->ol, b_lo, m); /* OL += b_lo */
    emit_i(p, a_hi, m->oh, 32774); /* OH = a_hi */
    emit_add16(p, m->oh, b_hi, m); /* OH += b_hi */
    /* carry-out = bit15(MUX(a|b, a&b, sum)): the top-bit carry MAJ folds into
     * one MUX, replacing three bit15 votes. Verified exhaustively vs the true
     * carry (RV32I oracle + 'make fuzz-rvopt'). D = a|b, BT = a&b, then BT =
     * (a|b & ~sum) | (a&b & sum) whose bit15 is the carry-out, tested in place.
     */
    emit_i(p, b_lo, m->d, 32774);           /* D = b_lo */
    emit_i(p, a_lo, m->d, 0x8000 | b_lo);   /* D = (a & ~b) | b = a | b */
    emit_i(p, a_lo, m->bt, 32774);          /* BT = a_lo */
    emit_i(p, m->z, m->bt, 0x8000 | b_lo);  /* BT = a & b */
    emit_i(p, m->d, m->bt, 0x8000 | m->ol); /* BT bit15 = carry-out */
    emit_bit15c_bt(p, *p + 9 + 3, m);  /* bit15 clear (no carry) -> skip INC */
    emit_i(p, m->neg1, m->oh, *p + 3); /* INC(OH): carry into hi */
    emit_i(p, m->ol, rlo, 32774);      /* rd.lo = OL */
    emit_i(p, m->oh, rhi, 32774);      /* rd.hi = OH */
}

/* rd = rs1 - rs2 (32-bit). lo sub, then borrow = MAJ(!bit15 a_lo, bit15 b_lo,
 * bit15 diff) = LTU16(a_lo,b_lo) decrements hi. Computes into OL/OH.
 */
static void emit_sub32(int *p,
                       int rlo,
                       int rhi,
                       int a_lo,
                       int a_hi,
                       int b_lo,
                       int b_hi,
                       const struct mlayout *m)
{
    emit_i(p, a_lo, m->ol, 32774);  /* OL = a_lo */
    emit_i(p, b_lo, m->ol, *p + 3); /* OL -= b_lo (falls through) */
    emit_i(p, a_hi, m->oh, 32774);  /* OH = a_hi */
    emit_i(p, b_hi, m->oh, *p + 3); /* OH -= b_hi */
    /* borrow-out = bit15(MUX(b|d, b&d, a)), d = a-b: same one-MUX top-bit MAJ
     * as add's carry (verified vs the RV32I oracle + fuzz). D = b|d, BT = b&d,
     * then BT = (b|d & ~a) | (b&d & a) whose bit15 is the borrow, tested in
     * place.
     */
    emit_i(p, b_lo, m->d, 32774);           /* D = b_lo */
    emit_i(p, m->ol, m->d, 0x8000 | b_lo);  /* D = (d & ~b) | b = b | d */
    emit_i(p, b_lo, m->bt, 32774);          /* BT = b_lo */
    emit_i(p, m->z, m->bt, 0x8000 | m->ol); /* BT = b & d */
    emit_i(p, m->d, m->bt, 0x8000 | a_lo);  /* BT bit15 = borrow-out */
    emit_bit15c_bt(p, *p + 9 + 3, m); /* bit15 clear (no borrow) -> skip DEC */
    emit_i(p, m->one, m->oh, *p + 3); /* DEC(OH): borrow from hi */
    emit_i(p, m->ol, rlo, 32774);     /* rd.lo = OL */
    emit_i(p, m->oh, rhi, 32774);     /* rd.hi = OH */
}

/* Shared tail of SLT/SLTU: given three LTU16 compares already sized, branch the
 * "less" cases to a rd=1 block and fall through to rd=0. lo_a/lo_b are the raw
 * low halves; hi_a/hi_b are the (possibly sign-flipped) high halves.
 */
static void emit_setless(int *p,
                         int rlo,
                         int rhi,
                         int hi_a,
                         int hi_b,
                         int lo_a,
                         int lo_b,
                         const struct mlayout *m)
{
    const int lc = ltu16_cells(m);
    const int base = *p + 3 * lc; /* the GE block, just past the 3 compares */
    const int ge = base, less = base + 9, done = base + 15;
    emit_ltu16(p, hi_a, hi_b, less, m); /* hi<hi -> less */
    emit_ltu16(p, hi_b, hi_a, ge, m);   /* hi>hi -> not less */
    emit_ltu16(p, lo_a, lo_b, less, m); /* hi==hi, lo<lo -> less */
    emit_i(p, m->z, rlo, 32774);        /* GE: rd = 0 */
    emit_i(p, m->z, rhi, 32774);
    emit_i(p, m->z, m->z, done);   /* JMP done */
    emit_i(p, m->one, rlo, 32774); /* LESS: rd = 1 */
    emit_i(p, m->z, rhi, 32774);
}

/* SLTU rd = (rs1 <u rs2) ? 1 : 0. rd is written only after all compares read
 * rs1/rs2, so rd may alias either operand.
 */
static void emit_sltu(int *p,
                      int rlo,
                      int rhi,
                      int a_lo,
                      int a_hi,
                      int b_lo,
                      int b_hi,
                      const struct mlayout *m)
{
    emit_setless(p, rlo, rhi, a_hi, b_hi, a_lo, b_lo, m);
}

/* SLT rd = (rs1 <s rs2) ? 1 : 0. Signed compare = unsigned on both hi halves
 * with bit15 flipped (x^0x8000 == x-0x8000 mod 65536), lo stays unsigned.
 */
static void emit_slt(int *p,
                     int rlo,
                     int rhi,
                     int a_lo,
                     int a_hi,
                     int b_lo,
                     int b_hi,
                     const struct mlayout *m)
{
    emit_i(p, a_hi, m->sh1, 32774); /* SH1 = rs1.hi ^ 0x8000 */
    emit_i(p, m->sgn, m->sh1, *p + 3);
    emit_i(p, b_hi, m->sh2, 32774); /* SH2 = rs2.hi ^ 0x8000 */
    emit_i(p, m->sgn, m->sh2, *p + 3);
    emit_setless(p, rlo, rhi, m->sh1, m->sh2, a_lo, b_lo, m);
}

/* One 32-bit left shift by 1 of the (lo,hi) pair OL/OH: MUXLEQ has no shift, so
 * a doubling is a self-add. The bit shifted out of lo (bit15) is the carry into
 * hi bit0; capture it in T0 (0/1) BEFORE doubling, then add it back to hi.
 */
static void emit_shl1(int *p, int ol, int oh, const struct mlayout *m)
{
    emit_i(p, m->z, m->t0, 32774);     /* CF = 0 */
    emit_bit15c(p, ol, *p + 15, m);    /* bit15(lo) clear -> skip the INC */
    emit_i(p, m->neg1, m->t0, *p + 3); /* set: CF = 1 (carry out of lo) */
    emit_add16(p, ol, ol, m);          /* lo <<= 1 */
    emit_add16(p, oh, oh, m);          /* hi <<= 1 */
    emit_add16(p, oh, m->t0, m);       /* hi += carry */
}

/* Cell count of one emit_shl1 (measured, not hand-counted). SLL needs it to
 * place the loop-exit label past the shift body.
 */
static int shl1_cells(const struct mlayout *m)
{
    const bool save = g_sizing;
    g_sizing = true;
    int p = 0;
    emit_shl1(&p, 0, 0, m);
    g_sizing = save;
    return p;
}

/* SLLI rd = rs1 << k (0..31): copy rs1 into OL/OH, double k times, MOVE to rd.
 * rd is written last so it may alias rs1. k==0 is a plain move.
 */
static void emit_slli(int *p,
                      int rlo,
                      int rhi,
                      int a_lo,
                      int a_hi,
                      int k,
                      const struct mlayout *m)
{
    emit_i(p, a_lo, m->ol, 32774); /* OL = rs1.lo */
    emit_i(p, a_hi, m->oh, 32774); /* OH = rs1.hi */
    for (int i = 0; i < k; i++)
        emit_shl1(p, m->ol, m->oh, m);
    emit_i(p, m->ol, rlo, 32774); /* rd.lo = OL */
    emit_i(p, m->oh, rhi, 32774); /* rd.hi = OH */
}

/* Test bit 'sb' of cell 'src' and, if set, OR power-of-two 2^db into cell 'dst'
 * (dst's bit is 0 so an add is an OR). No native shift, so this is the atom of
 * right-shift bit extraction. bit15 uses BIT15C (the 0x8000 sign trap); lower
 * bits use a direct signed<=0 test, valid because 2^sb (sb<15) is positive.
 */
static void emit_copybit(int *p,
                         int src,
                         int sb,
                         int dst,
                         int db,
                         const struct mlayout *m)
{
    if (sb == 15) {
        emit_bit15c(p, src, *p + 21, m); /* bit15 clear -> skip the add */
        emit_add16(p, dst, m->mask_base + db, m);
        return;
    }
    emit_i(p, src, m->bt, 32774);                         /* BT = src */
    emit_i(p, m->z, m->bt, 0x8000 | (m->mask_base + sb)); /* BT &= 2^sb */
    emit_i(p, m->z, m->bt, *p + 12);          /* BT<=0 (clear) -> skip add */
    emit_add16(p, dst, m->mask_base + db, m); /* set: dst |= 2^db */
}

/* dst = (src >> 8) & 0xFF: the high byte of a 16-bit cell into dst's low byte.
 * Eight copybits, vs the general emit_shift_right's ~24 for a >>8 (that treats
 * src as the low half of a 32-bit value whose top 16 bits are 0, so two-thirds
 * of its copybits only move zeros). Used by SW's little-endian byte split.
 */
static void emit_high_byte(int *p, int dst, int src, const struct mlayout *m)
{
    emit_i(p, m->z, dst, 32774); /* dst = 0 */
    for (int b = 0; b < 8; b++)
        emit_copybit(p, src, 8 + b, dst, b, m); /* dst bit b = src bit 8+b */
}

/* SRLI/SRAI rd = rs1 >> k (0..31), logical (arith=false) or arithmetic. Build
 * the result bit by bit into OL/OH: dest bit d takes src bit d+k (SRLI,
 * d<=31-k) or src bit min(d+k,31) (SRAI, d<=31, the top k bits copy the sign).
 * rd is written last so it may alias rs1. k==0 is a plain move.
 */
static void emit_shift_right(int *p,
                             int rlo,
                             int rhi,
                             int a_lo,
                             int a_hi,
                             int k,
                             bool arith,
                             const struct mlayout *m)
{
    if (k == 0) {
        emit_i(p, a_lo, rlo, 32774);
        emit_i(p, a_hi, rhi, 32774);
        return;
    }
    emit_i(p, m->z, m->ol, 32774); /* dest = 0 */
    emit_i(p, m->z, m->oh, 32774);
    const int dmax = arith ? 31 : 31 - k;
    for (int d = 0; d <= dmax; d++) {
        int sbit = d + k;
        if (sbit > 31) /* SRAI sign-fill: clamp to bit 31 */
            sbit = 31;
        const int src = sbit < 16 ? a_lo : a_hi;
        const int dst = d < 16 ? m->ol : m->oh;
        emit_copybit(p, src, sbit & 15, dst, d & 15, m);
    }
    emit_i(p, m->ol, rlo, 32774); /* rd.lo = OL */
    emit_i(p, m->oh, rhi, 32774); /* rd.hi = OH */
}

/* One 32-bit right shift by 1 of the (lo,hi) pair OL/OH. No native shift, so
 * each result bit is copied from the source bit one higher (bit 0 of hi feeds
 * bit 15 of lo). The vacated top bit is 0 (logical) or the old sign (arith).
 * Built into SH1/SH2 (a bit is read after a lower one is written) then moved
 * back; emit_copybit clobbers BT and emit_add16 clobbers D, so neither may hold
 * the accumulator halves.
 */
static void emit_shr1(int *p,
                      int ol,
                      int oh,
                      bool arith,
                      const struct mlayout *m)
{
    emit_i(p, m->z, m->sh1, 32774); /* new lo = 0 */
    emit_i(p, m->z, m->sh2, 32774); /* new hi = 0 */
    for (int b = 0; b < 15; b++)
        emit_copybit(p, ol, b + 1, m->sh1, b,
                     m);                   /* lo bit b = old lo bit b+1 */
    emit_copybit(p, oh, 0, m->sh1, 15, m); /* lo bit 15 = old hi bit 0 */
    for (int b = 0; b < 15; b++)
        emit_copybit(p, oh, b + 1, m->sh2, b,
                     m); /* hi bit b = old hi bit b+1 */
    if (arith)
        emit_copybit(p, oh, 15, m->sh2, 15,
                     m);          /* arith: hi bit 15 = old sign */
    emit_i(p, m->sh1, ol, 32774); /* lo = new lo */
    emit_i(p, m->sh2, oh, 32774); /* hi = new hi */
}

/* Cell count of one emit_shr1 (the arith flag adds a copybit, so it is a
 * parameter). SRL/SRA needs it to place the loop-exit label past the body.
 */
static int shr1_cells(bool arith, const struct mlayout *m)
{
    const bool save = g_sizing;
    g_sizing = true;
    int p = 0;
    emit_shr1(&p, 0, 0, arith, m);
    g_sizing = save;
    return p;
}

/* SLL rd = rs1 << (rs2 & 31): a runtime loop doubling the OL/OH accumulator the
 * masked count of times. V holds the counter (free during a shift); rd is
 * written after the loop so it may alias rs1 or rs2.
 */
static void emit_sll(int *p,
                     int rlo,
                     int rhi,
                     int a_lo,
                     int a_hi,
                     int rs2_lo,
                     const struct mlayout *m)
{
    emit_i(p, rs2_lo, m->v, 32774);         /* CNT = rs2.lo */
    emit_i(p, m->z, m->v, 0x8000 | m->m1f); /* CNT &= 0x1F */
    emit_i(p, a_lo, m->ol, 32774);          /* acc = rs1 */
    emit_i(p, a_hi, m->oh, 32774);
    const int loop = *p;
    const int done = loop + 3 + shl1_cells(m) + 3 + 3; /* test+body+DEC+JMP */
    emit_i(p, m->z, m->v, done);                       /* CNT==0 -> done */
    emit_shl1(p, m->ol, m->oh, m);                     /* acc <<= 1 */
    emit_i(p, m->one, m->v, *p + 3); /* CNT -= 1 (non-branching) */
    emit_i(p, m->z, m->z, loop);     /* back to the test */
    emit_i(p, m->ol, rlo, 32774);    /* rd.lo = acc.lo */
    emit_i(p, m->oh, rhi, 32774);    /* rd.hi = acc.hi */
}

/* SRL/SRA rd = rs1 >> (rs2 & 31), logical or arithmetic: the right-shift analog
 * of emit_sll -- a runtime loop applying emit_shr1 the masked count of times.
 * rd is written after the loop so it may alias rs1 or rs2.
 */
static void emit_srl(int *p,
                     int rlo,
                     int rhi,
                     int a_lo,
                     int a_hi,
                     int rs2_lo,
                     bool arith,
                     const struct mlayout *m)
{
    emit_i(p, rs2_lo, m->v, 32774);         /* CNT = rs2.lo */
    emit_i(p, m->z, m->v, 0x8000 | m->m1f); /* CNT &= 0x1F */
    emit_i(p, a_lo, m->ol, 32774);          /* acc = rs1 */
    emit_i(p, a_hi, m->oh, 32774);
    const int loop = *p;
    const int done =
        loop + 3 + shr1_cells(arith, m) + 3 + 3; /* test+body+DEC+JMP */
    emit_i(p, m->z, m->v, done);                 /* CNT==0 -> done */
    emit_shr1(p, m->ol, m->oh, arith, m);        /* acc >>= 1 */
    emit_i(p, m->one, m->v, *p + 3);             /* CNT -= 1 (non-branching) */
    emit_i(p, m->z, m->z, loop);                 /* back to the test */
    emit_i(p, m->ol, rlo, 32774);                /* rd.lo = acc.lo */
    emit_i(p, m->oh, rhi, 32774);                /* rd.hi = acc.hi */
}

/* Guest RAM is a power-of-two window of one cell per guest byte at ram_base; a
 * load/store address is a runtime value, so the access cell is selected by
 * SELF-MODIFYING CODE. emit_addr computes the native cell of guest byte rs1 +
 * imm + k into OL = ram_base + ((rs1.lo + imm + k) & winmask): the mask keeps
 * the address inside the window so the patched MOVE operand can never escape
 * the cell space or hit IO_MARKER; k selects the byte within a multi-byte
 * access. imm_cell holds the raw offset. This mirrors the interpreter's iLOAD/
 * iSTORE. Aligned half/word accesses (the only kind RV32I supports) keep every
 * byte inside the window, since a power-of-two window preserves alignment.
 */
static void emit_addr(int *p,
                      int rs1_lo,
                      int imm_cell,
                      int k,
                      const struct mlayout *m)
{
    emit_i(p, rs1_lo, m->ol, 32774);   /* OL = rs1.lo */
    emit_add16(p, m->ol, imm_cell, m); /* OL += imm (guest address) */
    for (int j = 0; j < k; j++)
        emit_add16(p, m->ol, m->one, m); /* OL += k (the k-th byte) */
    emit_i(p, m->z, m->ol,
           0x8000 | m->winmask);       /* OL &= window-1 (in-window) */
    emit_add16(p, m->ol, m->rambc, m); /* OL += ram_base (native) */
}

/* MOVE guest RAM[rs1 + imm + k] -> dst (patch the load MOVE's source, run it).
 */
static void emit_load_cell(int *p,
                           int k,
                           int dst,
                           int rs1_lo,
                           int imm_cell,
                           const struct mlayout *m)
{
    emit_addr(p, rs1_lo, imm_cell, k, m);
    const int mi = *p + 3;       /* the load MOVE lands here */
    emit_i(p, m->ol, mi, 32774); /* patch its source operand := OL */
    emit_i(p, 0, dst, 32774);    /* MOVE [addr] -> dst (source patched) */
}

/* Store val to the guest cell whose native address is already in OL: patch the
 * following MOVE's dest operand := OL (SMC), then run it.
 */
static void emit_store_at(int *p, int val, const struct mlayout *m)
{
    const int mi = *p + 3;           /* the store MOVE lands here */
    emit_i(p, m->ol, mi + 1, 32774); /* patch its dest operand := OL */
    emit_i(p, val, 0, 32774);        /* MOVE val -> [OL] (dest patched) */
}

/* MOVE val -> guest RAM[rs1 + imm + k] (patch the store MOVE's dest, run it).
 */
static void emit_store_cell(int *p,
                            int k,
                            int val,
                            int rs1_lo,
                            int imm_cell,
                            const struct mlayout *m)
{
    emit_addr(p, rs1_lo, imm_cell, k, m);
    emit_store_at(p, val, m);
}

/* BT = src & 0xFF (mask a 16-bit half down to its low byte via a MUX). */
static void emit_mask_byte(int *p, int src, const struct mlayout *m)
{
    emit_i(p, src, m->bt, 32774);            /* BT = src */
    emit_i(p, m->z, m->bt, 0x8000 | m->mff); /* BT &= 0xFF */
}

/* SB: guest RAM[rs1 + imm] = rs2 & 0xFF (each cell holds one byte). */
static void emit_store_byte(int *p,
                            int rs2_lo,
                            int rs1_lo,
                            int imm_cell,
                            const struct mlayout *m)
{
    emit_mask_byte(p, rs2_lo, m); /* BT = rs2.lo & 0xFF */
    emit_store_cell(p, 0, m->bt, rs1_lo, imm_cell, m);
}

/* LBU: rd = zero-extended guest RAM[rs1 + imm] (a byte, so hi = 0). */
static void emit_load_byte_u(int *p,
                             int rlo,
                             int rhi,
                             int rs1_lo,
                             int imm_cell,
                             const struct mlayout *m)
{
    emit_load_cell(p, 0, m->bt, rs1_lo, imm_cell, m); /* BT = byte */
    emit_i(p, m->bt, rlo, 32774);                     /* rd.lo = byte */
    emit_i(p, m->z, rhi, 32774);                      /* rd.hi = 0 */
}

/* LB: rd = sign-extended guest RAM[rs1 + imm] (a byte; bit 7 fills bits 8..31).
 * Starts from the LBU value, then a bit15-clear branch skips the sign fill.
 */
static void emit_load_byte(int *p,
                           int rlo,
                           int rhi,
                           int rs1_lo,
                           int imm_cell,
                           const struct mlayout *m)
{
    emit_load_cell(p, 0, m->t0, rs1_lo, imm_cell, m); /* T0 = byte */
    emit_i(p, m->t0, rlo, 32774);                     /* rd.lo = byte */
    emit_i(p, m->z, rhi, 32774);                      /* rd.hi = 0 (positive) */
    emit_i(p, m->t0, m->bt, 32774);                   /* BT = byte ... */
    for (int j = 0; j < 8; j++)
        emit_add16(p, m->bt, m->bt, m);       /* ... << 8: bit 7 -> bit 15 */
    emit_bit15c_bt(p, *p + 9 + 6, m);         /* bit 7 clear -> skip the fill */
    emit_i(p, m->neg1, rlo, 0x8000 | m->mff); /* rd.lo bits 8..15 = 1 */
    emit_i(p, m->neg1, rhi, 32774);           /* rd.hi = 0xFFFF */
}

/* Combine two consecutive guest cells into 'dst' as a little-endian 16-bit
 * half: dst = cell[a+k] | cell[a+k+1] << 8, where a is the base address
 * snapshotted in SH2. SH1 is scratch (holds the high cell shifted left 8).
 */
static void emit_load_half_le(int *p,
                              int dst,
                              int k,
                              int imm_cell,
                              const struct mlayout *m)
{
    emit_load_cell(p, k, dst, m->sh2, imm_cell, m); /* dst = cell[a+k] */
    emit_load_cell(p, k + 1, m->sh1, m->sh2, imm_cell,
                   m); /* SH1 = cell[a+k+1] */
    for (int j = 0; j < 8; j++)
        emit_add16(p, m->sh1, m->sh1, m); /* SH1 <<= 8 */
    emit_add16(p, dst, m->sh1, m);        /* dst |= SH1 */
}

/* LH/LHU: rd = the two bytes at guest RAM[rs1 + imm .. +1], little-endian (the
 * low half of emit_load_word). LHU zero-extends; LH fills rd.hi from bit 15.
 * rs1.lo is snapshot into SH2 first so rd may alias rs1.
 */
static void emit_load_half(int *p,
                           int rlo,
                           int rhi,
                           int rs1_lo,
                           int imm_cell,
                           bool sign,
                           const struct mlayout *m)
{
    emit_i(p, rs1_lo, m->sh2, 32774); /* snapshot base (rd may alias rs1) */
    emit_load_half_le(p, m->t0, 0, imm_cell, m); /* T0 = half */
    emit_i(p, m->t0, rlo, 32774);                /* rd.lo = half */
    emit_i(p, m->z, rhi, 32774); /* rd.hi = 0 (LHU / positive LH) */
    if (sign) {
        emit_bit15c(p, m->t0, *p + 12 + 3,
                    m);                 /* bit 15 clear -> skip the fill */
        emit_i(p, m->neg1, rhi, 32774); /* rd.hi = 0xFFFF */
    }
}

/* Store 'half''s two bytes little-endian at OL and OL+1, leaving OL advanced to
 * the OL+1 cell. The low byte is half & 0xFF; the high byte is half >> 8.
 */
static void emit_store_half_le(int *p, int half, const struct mlayout *m)
{
    emit_mask_byte(p, half, m); /* low byte = half & 0xFF */
    emit_store_at(p, m->bt, m);
    emit_add16(p, m->ol, m->one, m);    /* OL = &next cell */
    emit_high_byte(p, m->sh1, half, m); /* high byte = half >> 8 */
    emit_store_at(p, m->sh1, m);
}

/* SW: store rs2's four bytes little-endian into guest RAM[rs1 + imm .. +3]. The
 * high byte of each 16-bit half is x >> 8 (a right shift into a temp).
 */
static void emit_store_word(int *p,
                            int rs2_lo,
                            int rs2_hi,
                            int rs1_lo,
                            int imm_cell,
                            const struct mlayout *m)
{
    /* Aligned word: the four byte cells are consecutive in the window, so
     * compute the byte-0 native address once and OL += 1 for each next byte
     * instead of re-running emit_addr 4x (rs1+imm+mask+ram_base).
     */
    emit_addr(p, rs1_lo, imm_cell, 0, m); /* OL = &RAM[addr] */
    emit_store_half_le(p, rs2_lo, m);     /* bytes 0..1 = rs2.lo */
    emit_add16(p, m->ol, m->one, m);      /* OL = &RAM[addr+2] */
    emit_store_half_le(p, rs2_hi, m);     /* bytes 2..3 = rs2.hi */
}

/* SH: store rs2's low two bytes little-endian into guest RAM[rs1 + imm .. +1]
 * (the low half of emit_store_word).
 */
static void emit_store_half(int *p,
                            int rs2_lo,
                            int rs1_lo,
                            int imm_cell,
                            const struct mlayout *m)
{
    emit_addr(p, rs1_lo, imm_cell, 0, m); /* OL = &RAM[addr] */
    emit_store_half_le(p, rs2_lo, m);     /* bytes 0..1 = rs2.lo */
}

/* LW: rd = the four bytes at guest RAM[rs1 + imm .. +3], little-endian. Each
 * high byte is combined by a 16-bit << 8 (eight doublings). rs1.lo is snapshot
 * into SH2 first so rd may alias rs1.
 */
static void emit_load_word(int *p,
                           int rlo,
                           int rhi,
                           int rs1_lo,
                           int imm_cell,
                           const struct mlayout *m)
{
    emit_i(p, rs1_lo, m->sh2, 32774); /* snapshot base (rd may alias rs1) */
    emit_load_half_le(p, m->t0, 0, imm_cell,
                      m); /* T0 = cell[a] | cell[a+1]<<8 */
    emit_load_half_le(p, m->oh, 2, imm_cell,
                      m); /* OH = cell[a+2] | cell[a+3]<<8 */
    emit_i(p, m->t0, rlo, 32774);
    emit_i(p, m->oh, rhi, 32774);
}

/* Cell count of emit_addr with k=0 (measured), for the write loop's exit label.
 */
static int addr_cells(const struct mlayout *m)
{
    const bool save = g_sizing;
    g_sizing = true;
    int p = 0;
    emit_addr(&p, 0, 0, 0, m);
    g_sizing = save;
    return p;
}

/* A runtime write(1, a1, a2): PUT the a2 bytes of live guest RAM starting at
 * guest address a1, one per loop iteration. SH1 walks the guest pointer, SH2
 * counts down. Each byte's native cell is chosen by SMC (emit_addr) and PUT via
 * a patched output instruction. Reads live RAM, so it is correct after any SB.
 */
static void emit_write_dyn(int *p, const struct mlayout *m)
{
    const int a1 = m->reg_base + 2 * 11, a2 = m->reg_base + 2 * 12;
    emit_i(p, a1, m->sh1, 32774); /* PTR = a1 (guest buffer address) */
    emit_i(p, a2, m->sh2, 32774); /* CNT = a2 (length) */
    const int loop = *p;
    /* EQ16 test (not a signed<=0 SUBLEQ) so any length 0..0xFFFF terminates. */
    const int done =
        loop + 15 + addr_cells(m) + 21; /* eq16+addr+patch+PUT+inc+dec+jmp */
    emit_eq16(p, m->sh2, m->z, done, m->t0, m->z, m->neg1); /* CNT==0 -> done */
    emit_addr(p, m->sh1, m->z, 0, m);  /* OL = ram_base + (PTR & winmask) */
    const int mi = *p + 3;             /* the PUT lands here */
    emit_i(p, m->ol, mi, 32774);       /* patch its source operand := OL */
    emit_i(p, 0, 65535, 0);            /* PUT [addr] -> stdout (b=IO_MARKER) */
    emit_add16(p, m->sh1, m->one, m);  /* PTR += 1 */
    emit_i(p, m->one, m->sh2, *p + 3); /* CNT -= 1 (non-branching) */
    emit_i(p, m->z, m->z, loop);       /* back to the test */
}

/* 'ret' (jalr x0,x1,0): branch to the return site only if ra actually equals
 * that site's return address (rsite). Checking ra -- rather than trusting the
 * single-call-site shortcut -- stays correct however the callee was entered; if
 * ra does not match (an unsupported call shape), it halts rather than misjump.
 */
static void emit_ret(int *p,
                     const int *na,
                     int ret_node,
                     const struct mlayout *m)
{
    const int ra_lo = m->reg_base + 2 * 1, ra_hi = ra_lo + 1; /* x1 = ra */
    const int nomatch = *p + 27; /* past NE16 + NE16 + the branch */
    emit_ne16(p, ra_lo, m->rsite, nomatch, m->t0, m->z, m->neg1);
    emit_ne16(p, ra_hi, m->z, nomatch, m->t0, m->z, m->neg1);
    emit_i(p, m->z, m->z, na[ret_node]); /* ra matches -> return */
    emit_i(p, m->z, m->z, 65535);        /* no match -> halt (defensive) */
}

/* Resolve a JAL/branch target (pc+imm) to its native cell, aborting when it
 * does not land on a decoded instruction.
 */
static int mux_target(const struct graph *g,
                      const struct node *nd,
                      const int *na)
{
    const int tn = addr2node(g, nd->pc + (uint32_t) nd->imm);
    if (tn == NONE) {
        fprintf(stderr, "rvopt -mux: branch target out of range at pc %u\n",
                nd->pc);
        exit(1);
    }
    return na[tn];
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
            } else if (c.val[a7] ==
                       64) { /* write (fd a0 ignored, as the -r VM) */
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
 * succ[] and returns the count. Only 'jal ra' (rd == x1) has a return site
 * (matching the ret model); 'j'/'jal x5' and jalr do not fall through; an ecall
 * exit terminates.
 */
static int successors(const struct graph *g,
                      const struct sysinfo *sys,
                      int i,
                      int succ[2])
{
    const struct node *nd = &g->n[i];
    int n = 0;
    const int fall = addr2node(g, nd->pc + 4);
    const bool link = nd->kind == K_JAL && ((nd->word >> 7) & 31) == 1;
    const bool terminates = (nd->kind == K_JAL && !link) ||
                            nd->kind == K_JALR ||
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

/* Self-modifying-code guard. './muxleq -r' re-fetches each instruction from
 * guest RAM every step, so it honors a guest STORE into its own code; the
 * native -mux image bakes decode once, so such a store would silently run the
 * STALE instruction. Refuse rather than miscompile: reject a reachable STORE
 * whose target is a COMPILE-TIME CONSTANT (its base register li'd/la'd in the
 * same block, tracked by cprop) landing on a reachable instruction word. An
 * unknown base (sp-relative stack, computed pointer) is assumed disjoint from
 * code -- the standard freestanding convention; flagging those would reject
 * every real program (all push to sp). The store must also be able to
 * RE-EXECUTE the word it overwrites (reaches_after) -- overwriting an
 * already-passed word, e.g. code space reused as scratch, is harmless. The
 * residual gap -- a store into code through a RUNTIME-computed address -- is
 * not caught here (documented; '-r' stays correct).
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
                        "AOT-compilable -- run it under ./muxleq -r\n",
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
 * slot -- so it is excluded from the imm pool (mux_has_imm) and from the const
 * folder (below), and handled directly in emit_one. (addi rd, x0, 0 is
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
 * pass only IDENTIFIES opportunities (shown in -dump); the emit that consumes
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

/* Emit the pre-header loads (dir=load: slot memory -> dedicated cell) or the
 * post-loop stores (dir=store: cell -> slot memory) for one promoted loop.
 */
static void emit_promo_transfer(int *p,
                                const struct promo_loop *lp,
                                const struct mlayout *m,
                                bool load)
{
    for (int s = 0; s < lp->nslot; s++) {
        const int g = lp->slot[s].g;
        const int cell = m->promo_base + 2 * g;
        const int base = m->reg_base + 2 * lp->slot[s].base;
        const int immc = m->imm_base + 2 * (m->promo_imm_base + g);
        if (load)
            emit_load_word(p, cell, cell + 1, base, immc, m);
        else
            emit_store_word(p, cell, cell + 1, base, immc, m);
    }
}

static void emit_one(const struct graph *g,
                     int i,
                     const struct mlayout *m,
                     const int *na,
                     const struct sysinfo *sys,
                     const bool *folded,
                     const int *fwd,
                     const struct promo_emit *pe,
                     int ret_node,
                     int *p,
                     int *imm,
                     int *spool)
{
    const struct node *nd = &g->n[i];
    const int rd = (nd->word >> 7) & 31;
    const int fk = fold_kind(nd->word);

    /* Register promotion brackets a loop: the pre-header LOADS (slot memory ->
     * dedicated cell) prefix the sole-entry node, the post-loop STORES (cell ->
     * slot memory) prefix the sole-exit node. Both run before the node's own
     * code, so the cells are live for the loop and memory is current on exit
     * (incl. the exit node's own read of a live-out slot).
     */
    if (pe->pre[i] != NONE)
        emit_promo_transfer(p, &pe->loops[pe->pre[i]], m, true);
    if (pe->post[i] != NONE)
        emit_promo_transfer(p, &pe->loops[pe->post[i]], m, false);
    if (fk == FOLD_DEADI)
        return; /* nop: no code */
    if (is_mv(nd)) {
        /* mv rd, rs (= addi rd, rs, 0): a two-MOVE register copy, not add32; no
         * imm slot (see is_mv / mux_has_imm).
         */
        const int s = m->reg_base + 2 * nd->rs1, d = m->reg_base + 2 * rd;
        emit_i(p, s, d, 32774);         /* rd.lo = rs.lo */
        emit_i(p, s + 1, d + 1, 32774); /* rd.hi = rs.hi */
        return;
    }
    if (fk == FOLD_LI12 || folded[i]) {
        /* li12, or a const-folded ALU emitted as a 'li' of its result (already
         * staged in this node's imm cell).
         */
        emit_imm_to_reg(p, m->imm_base, m->reg_base, rd, imm);
        return;
    }
    if (nd->kind == K_JAL) {
        if (rd) /* link = pc+4 into rd (the pc+4 constant is the imm cell) */
            emit_imm_to_reg(p, m->imm_base, m->reg_base, rd, imm);
        emit_i(p, m->z, m->z, mux_target(g, nd, na)); /* unconditional branch */
        return;
    }
    if (nd->kind == K_BRANCH) {
        const int L = mux_target(g, nd, na);
        const int ft = na[i + 1]; /* not-taken = next instruction */
        const int s1 = m->reg_base + 2 * ((nd->word >> 15) & 31);
        const int s2 = m->reg_base + 2 * ((nd->word >> 20) & 31);
        switch (nd->funct3) {
        case 0: /* BEQ: taken iff lo==lo AND hi==hi */
            emit_ne16(p, s1, s2, ft, m->t0, m->z, m->neg1);
            emit_eq16(p, s1 + 1, s2 + 1, L, m->t0, m->z, m->neg1);
            return;
        case 1: /* BNE: taken iff hi!=hi OR lo!=lo */
            emit_ne16(p, s1 + 1, s2 + 1, L, m->t0, m->z, m->neg1);
            emit_ne16(p, s1, s2, L, m->t0, m->z, m->neg1);
            return;
        case 6: /* BLTU: taken iff hi<hi, or hi==hi and lo<lo */
            emit_ltu16(p, s1 + 1, s2 + 1, L, m);
            emit_ltu16(p, s2 + 1, s1 + 1, ft, m);
            emit_ltu16(p, s1, s2, L, m);
            return;
        case 7: /* BGEU: taken iff NOT(a<u b) -- invert BLTU's targets */
            emit_ltu16(p, s1 + 1, s2 + 1, ft, m);
            emit_ltu16(p, s2 + 1, s1 + 1, L, m);
            emit_ltu16(p, s1, s2, ft, m);
            emit_i(p, m->z, m->z, L); /* hi==hi and lo>=lo -> taken */
            return;
        case 4: /* BLT */
        case 5: /* BGE: signed compare = BLTU/BGEU on sign-flipped hi halves */
            /* x^0x8000 == x-0x8000 (mod 65536), so SUBLEQ of the SGN cell flips
             * bit15: maps signed order onto unsigned order for the hi compare.
             */
            emit_i(p, s1 + 1, m->sh1, 32774);  /* SH1 = rs1.hi */
            emit_i(p, m->sgn, m->sh1, *p + 3); /* SH1 ^= 0x8000 */
            emit_i(p, s2 + 1, m->sh2, 32774);  /* SH2 = rs2.hi */
            emit_i(p, m->sgn, m->sh2, *p + 3); /* SH2 ^= 0x8000 */
            if (nd->funct3 == 4) {             /* BLT: like BLTU on sh1/sh2 */
                emit_ltu16(p, m->sh1, m->sh2, L, m);
                emit_ltu16(p, m->sh2, m->sh1, ft, m);
                emit_ltu16(p, s1, s2, L, m);
            } else { /* BGE: like BGEU on sh1/sh2 */
                emit_ltu16(p, m->sh1, m->sh2, ft, m);
                emit_ltu16(p, m->sh2, m->sh1, L, m);
                emit_ltu16(p, s1, s2, ft, m);
                emit_i(p, m->z, m->z, L);
            }
            return;
        }
    }
    if (mux_alu(nd)) {
        if (rd == 0)
            return; /* result discarded (writes x0) */
        const int a_lo = m->reg_base + 2 * nd->rs1, a_hi = a_lo + 1;
        const int rlo = m->reg_base + 2 * rd, rhi = rlo + 1;
        if (nd->funct3 == 1) { /* left shift: SLLI (imm shamt) or SLL (rs2) */
            if (nd->kind == K_OPIMM)
                emit_slli(p, rlo, rhi, a_lo, a_hi, nd->imm & 31, m);
            else
                emit_sll(p, rlo, rhi, a_lo, a_hi, m->reg_base + 2 * nd->rs2, m);
            return;
        }
        if (nd->funct3 ==
            5) { /* right shift: SRL[I] (f7 0x00) / SRA[I] (0x20) */
            const bool arith = ((nd->word >> 25) & 0x7f) == 0x20;
            if (nd->kind == K_OPIMM) /* SRLI/SRAI: constant shamt */
                emit_shift_right(p, rlo, rhi, a_lo, a_hi, nd->imm & 31, arith,
                                 m);
            else /* SRL/SRA: runtime count in rs2 */
                emit_srl(p, rlo, rhi, a_lo, a_hi, m->reg_base + 2 * nd->rs2,
                         arith, m);
            return;
        }
        int b_lo;
        if (nd->kind == K_OPIMM) { /* second operand is the immediate pair */
            b_lo = m->imm_base + 2 * *imm;
            (*imm)++;
        } else { /* K_OP: second operand is rs2 */
            b_lo = m->reg_base + 2 * nd->rs2;
        }
        const int b_hi = b_lo + 1;
        const int f7 = (nd->word >> 25) & 0x7f;
        switch (nd->funct3) {
        case 0: /* ADD, or SUB when K_OP funct7 == 0x20 */
            if (nd->kind == K_OP && f7 == 0x20)
                emit_sub32(p, rlo, rhi, a_lo, a_hi, b_lo, b_hi, m);
            else
                emit_add32(p, rlo, rhi, a_lo, a_hi, b_lo, b_hi, m);
            break;
        case 2: /* SLT(I): signed set-less-than */
            emit_slt(p, rlo, rhi, a_lo, a_hi, b_lo, b_hi, m);
            break;
        case 3: /* SLTU(I): unsigned set-less-than */
            emit_sltu(p, rlo, rhi, a_lo, a_hi, b_lo, b_hi, m);
            break;
        default: /* XOR (4) / OR (6) / AND (7) */
            emit_bitwise(p, nd->funct3, rlo, rhi, a_lo, a_hi, b_lo, b_hi, m);
        }
        return;
    }
    if (nd->kind == K_LUI || nd->kind == K_AUIPC) {
        /* Upper immediate: rd = imm<<12 (LUI) or pc + imm<<12 (AUIPC). Both are
         * compile-time constants, staged in the immediate pool like a li.
         */
        if (rd)
            emit_imm_to_reg(p, m->imm_base, m->reg_base, rd, imm);
        return;
    }
    if (nd->kind == K_STORE &&
        (nd->funct3 == 0 || nd->funct3 == 1 || nd->funct3 == 2)) {
        const int imm_cell = m->imm_base + 2 * *imm;
        const int rs2 = m->reg_base + 2 * nd->rs2,
                  rs1 = m->reg_base + 2 * nd->rs1;
        (*imm)++; /* keep the imm slot even when promoted/dead (num_imm) */
        if (pe->cell[i] != NONE) {
            /* promoted slot: write the value to its dedicated cell, not memory
             * (word-only per compute_promotions, so a two-MOVE lo/hi copy).
             */
            const int c = m->promo_base + 2 * pe->cell[i];
            emit_i(p, rs2, c, 32774);
            emit_i(p, rs2 + 1, c + 1, 32774);
            return;
        }
        if (nd->funct3 == 0) /* SB */
            emit_store_byte(p, rs2, rs1, imm_cell, m);
        else if (nd->funct3 == 1) /* SH */
            emit_store_half(p, rs2, rs1, imm_cell, m);
        else /* SW */
            emit_store_word(p, rs2, rs2 + 1, rs1, imm_cell, m);
        return;
    }
    if (nd->kind == K_LOAD &&
        (nd->funct3 == 0 || nd->funct3 == 1 || nd->funct3 == 2 ||
         nd->funct3 == 4 || nd->funct3 == 5)) {
        const int imm_cell = m->imm_base + 2 * *imm;
        const int rs1 = m->reg_base + 2 * nd->rs1;
        (*imm)++; /* keep the imm slot even when promoted/forwarded (num_imm) */
        if (pe->cell[i] != NONE) {
            /* promoted slot: read its dedicated cell, not memory (word-only).
             * Takes precedence over forwarding -- the whole loop routes this
             * slot through the cell, which in-loop stores keep current.
             */
            if (rd) {
                const int c = m->promo_base + 2 * pe->cell[i],
                          d = m->reg_base + 2 * rd;
                emit_i(p, c, d, 32774);
                emit_i(p, c + 1, d + 1, 32774);
            }
            return;
        }
        if (rd && fwd[i] != NONE) {
            /* store-to-load forwarded: rd = the stored register (a copy, or
             * nothing when rd == rs2), no memory access.
             */
            if (fwd[i] != rd) {
                const int s = m->reg_base + 2 * fwd[i],
                          d = m->reg_base + 2 * rd;
                emit_i(p, s, d, 32774);
                emit_i(p, s + 1, d + 1, 32774);
            }
            return;
        }
        if (rd) {
            const int rlo = m->reg_base + 2 * rd, rhi = rlo + 1;
            switch (nd->funct3) {
            case 0: /* LB */
                emit_load_byte(p, rlo, rhi, rs1, imm_cell, m);
                break;
            case 1: /* LH */
                emit_load_half(p, rlo, rhi, rs1, imm_cell, true, m);
                break;
            case 2: /* LW */
                emit_load_word(p, rlo, rhi, rs1, imm_cell, m);
                break;
            case 4: /* LBU */
                emit_load_byte_u(p, rlo, rhi, rs1, imm_cell, m);
                break;
            default: /* LHU (5) */
                emit_load_half(p, rlo, rhi, rs1, imm_cell, false, m);
            }
        }
        return;
    }
    if (nd->kind == K_JALR) {
        /* Computed/linking JALR to a static target (resolve_jalr set nd->target
         * when rs1 was a compile-time constant): write the pc+4 link if rd !=
         * 0, then jump to the resolved cell. The runtime rs1 value is
         * irrelevant -- the target is a compile-time address -- so this is
         * correct even for 'jalr rd, rd, 0'.
         */
        if (nd->target != NONE) {
            if (rd)
                emit_const32(p, m->reg_base + 2 * rd, m->reg_base + 2 * rd + 1,
                             nd->pc + 4, m);
            emit_i(p, m->z, m->z, na[nd->target]);
            return;
        }
        /* Else 'jalr x0, x1, 0' (= ret) with one known call site. */
        if (rd == 0 && nd->rs1 == 1 && nd->imm == 0 && ret_node != NONE) {
            emit_ret(p, na, ret_node, m);
            return;
        }
        fprintf(stderr, "rvopt -mux: unsupported JALR at pc %u\n", nd->pc);
        exit(1);
    }
    if (nd->kind == K_SYSTEM) {
        if (sys[i].kind == SYS_EXIT) {
            emit_i(p, m->z, m->z, 65535); /* halt (branch to 0xFFFF) */
            return;
        }
        if (sys[i].kind == SYS_WRITE) {
            /* Constant-folded write: PUT each static source byte (staged in the
             * byte pool). The runner ignores the fd, so all go to stdout.
             */
            for (uint32_t k = 0; k < sys[i].len; k++) {
                emit_i(p, m->spool_base + *spool, 65535, 0);
                (*spool)++;
            }
            return;
        }
        if (sys[i].kind == SYS_WRITE_DYN) {
            emit_write_dyn(p, m); /* runtime PUT loop over live guest RAM */
            return;
        }
        fprintf(stderr, "rvopt -mux: unsupported ecall at pc %u\n", nd->pc);
        exit(1);
    }
    fprintf(stderr, "rvopt -mux: unsupported instruction at pc %u\n", nd->pc);
    exit(1);
}

/* True when this instruction needs a 2-cell immediate constant: a li's value, a
 * JAL-with-link's return address pc+4, an ALU-immediate's operand, or an
 * upper-immediate (LUI/AUIPC) result. The shift-immediates (SLLI/SRLI/SRAI,
 * funct3 1/5) are excluded -- their amount is baked into the emitted bit ops,
 * not read from an imm cell.
 */
static bool mux_has_imm(const struct node *nd)
{
    const int rd = (nd->word >> 7) & 31;
    const bool shift = nd->funct3 == 1 || nd->funct3 == 5;
    return fold_kind(nd->word) == FOLD_LI12 || (nd->kind == K_JAL && rd) ||
           (nd->kind == K_OPIMM && mux_alu(nd) && rd && !shift && !is_mv(nd)) ||
           ((nd->kind == K_LUI || nd->kind == K_AUIPC) && rd) ||
           (nd->kind == K_STORE && nd->funct3 <= 2) || /* SB/SH/SW offset */
           (nd->kind == K_LOAD && nd->funct3 != 3 &&
            nd->funct3 <= 5); /* LB/LH/LW/LBU/LHU offset */
}

/* Emit a '.dec' MUXLEQ image (one decimal cell per line, the stage0.dec format
 * './muxleq -x' loads) that runs the program directly on the two ops -- no
 * eForth vm. rvopt owns the whole image and assigns every address, so there is
 * no relocation. SUPPORTED so far: li/nop, JAL (unconditional branch, with an
 * optional link), the conditional branches BEQ/BNE/BLT/BGE/BLTU/BGEU (16-bit
 * compare macros over the two 32-bit register halves; the signed forms flip
 * both hi halves first), the ALU ops ADD/SUB/SLT/SLTU/AND/OR/XOR plus their
 * immediate forms (32-bit two-cell arithmetic: carry/borrow via a 3-vote
 * majority, set-less-than via the compare macros, bitwise via native MUX), the
 * upper immediates LUI/AUIPC (compile-time constant pairs), the immediate
 * shifts SLLI (k self-doublings) and SRLI/SRAI (bit-by-bit extraction), the
 * register shifts SLL (runtime doubling loop) and SRL/SRA (runtime by-1
 * right-shift loop), the memory ops SB/SH/SW (store) and LB/LBU/LH/LHU/LW
 * (load, sign/zero-extended) via self-modifying-code addressing into the guest
 * RAM window, JALR both in the 'ret' form (an ra-checked branch to the single
 * call site) and the computed/linking form when rs1 is a compile-time constant
 * (a static jump + a pc+4 link), and the exit/write ecalls (a static-buffer
 * write folds to inline PUTs; a runtime-buffer write emits a live-RAM PUT
 * loop); a JALR through a runtime-only rs1 (not 'ret') is rejected.
 *
 * Blocks are emitted in program order, so fall-through is automatic and a taken
 * branch just sets the SUBLEQ target cell to the callee block's native address
 * (na[] maps each guest instruction to its native cell). A li / a JAL link is
 * two native MOVEs (c = 0x8006 = 32774, whose hardwired mask-address-6 makes it
 * a copy regardless of m[6]) of the immediate halves into the register pair; a
 * JAL branch is 'SUBLEQ Z,Z,target' (Z-Z <= 0 always branches).
 *
 * Layout (one allocator, reserved non-overlapping ranges): code from cell 0,
 * then the immediate constant cells (program order), then the write-ecall byte
 * pool (one cell per output byte), then the 64-cell 32-bit register file
 * (x0..x31 as lo,hi pairs -- 0 at load, so x0 stays zero), then the scratch
 * temps (T0/BT/D/V/SH1/SH2/OL/OH), the constants Z/-1/1/0x8000/0x1F/0xFF, a
 * 16-cell power-of-two mask pool (for right-shift bit extraction), and the
 * guest RAM window (one cell per guest byte, addressed by self-modifying
 * load/store).
 *
 * Only REACHABLE instructions are emitted (a linear decode also turns trailing
 * .rodata into ILL nodes). A program that exits via an ecall halts there; one
 * that falls off the end reaches the epilogue, which PUTs the low byte of each
 * DEFINED register (ascending) then halts via 'SUBLEQ Z,Z,-1'.
 */
static void emit_mux(struct graph *g, const unsigned char *img, size_t used)
{
    /* na has one extra slot so a branch that is the last instruction can read
     * na[count] (= the epilogue). sys[] resolves each ecall; reach[] is the
     * emitted set.
     */
    int *na = xcalloc((size_t) g->count + 1, sizeof *na);
    struct sysinfo *sys = xcalloc((size_t) g->count, sizeof *sys);
    bool *reach = xcalloc((size_t) g->count, sizeof *reach);

    /* resolve_jalr FIRST: it marks static JALR targets as leaders, and
     * analyze_syscalls's constant folding must see that final leader set (a
     * JALR target entered by the jump must clear cprop there). Then
     * reachability follows the nd->target edges resolve_jalr set.
     */
    resolve_jalr(g);
    analyze_syscalls(g, used, sys);
    mark_reachable(g, sys, reach);
    detect_smc(g, sys,
               reach); /* refuse self-modifying code, never miscompile it */

    /* Constant-fold const-result OPIMMs to a 'li' of the result (milestone 2a).
     */
    bool *folded = xcalloc((size_t) g->count, sizeof *folded);
    int32_t *foldval = xcalloc((size_t) g->count, sizeof *foldval);
    compute_folds(g, reach, folded, foldval);
    int *fwd = xcalloc((size_t) g->count, sizeof *fwd);
    compute_forwards(g, reach, fwd); /* store-to-load forwarding */

    /* Register promotion: bracket each simple loop's carried slots with a
     * pre-header load + post-loop store and route in-loop word accesses through
     * a dedicated cell. Build the per-node emit map now; each slot's global
     * index g fixes its cell (promo_base + 2*g) and offset imm cell once the
     * layout below assigns promo_base / promo_imm_base.
     */
    struct promo_loop *loops = xcalloc((size_t) PROMO_MAX_LOOPS, sizeof *loops);
    const int nloops = compute_promotions(g, reach, loops);
    int *pro_pre = xcalloc((size_t) g->count, sizeof *pro_pre);
    int *pro_post = xcalloc((size_t) g->count, sizeof *pro_post);
    int *pro_cell = xcalloc((size_t) g->count, sizeof *pro_cell);
    for (int i = 0; i < g->count; i++)
        pro_pre[i] = pro_post[i] = pro_cell[i] = NONE;
    int npromo = 0;
    for (int l = 0; l < nloops; l++) {
        struct promo_loop *lp = &loops[l];

        /* Skip this loop (zeroing its slots so the data-region walk below emits
         * no offset cells for it, keeping num_imm in sync) if a single node
         * would carry two colliding edge actions: another loop already claims
         * its entry or exit node, or its own entry IS its exit. emit_one runs a
         * node's pre before its post, so any such sharing would order the
         * transfers wrong.
         */
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
    const struct promo_emit pe = {pro_pre, pro_post, pro_cell, loops};

    /* A reachable STORE mutates guest RAM, so a const-folded write (which reads
     * the STATIC image at emit time) would be stale -- fall back to the runtime
     * live-RAM loop for every write instead.
     */
    bool has_store = false;
    for (int i = 1; i < g->count; i++)
        if (reach[i] && g->n[i].kind == K_STORE)
            has_store = true;
    if (has_store)
        for (int i = 1; i < g->count; i++)
            if (sys[i].kind == SYS_WRITE)
                sys[i].kind = SYS_WRITE_DYN;

    /* The single call site for a 'ret' (jalr x0,x1,0): the one reachable 'jal
     * ra,...' (rd == x1). ret branches to the word after it, but only when ra
     * actually holds that return address (checked at run time). More than one
     * ra call site would need a multi-way dispatch (no demo needs it); ret_node
     * stays NONE then and a reachable ret aborts.
     */
    int ret_node = NONE, nlink = 0;
    uint32_t ret_addr = 0;
    for (int i = 1; i < g->count; i++)
        if (reach[i] && g->n[i].kind == K_JAL &&
            ((g->n[i].word >> 7) & 31) == 1) {
            nlink++;
            ret_addr = g->n[i].pc + 4;
            ret_node = addr2node(g, ret_addr);
        }
    if (nlink != 1)
        ret_node = NONE;

    /* Defined registers, immediate-pair count, and write-byte count -- over the
     * reachable set only, matching what is emitted.
     */
    bool def[32] = {false};
    int num_imm = 0, num_spool = 0;
    for (int i = 1; i < g->count; i++) {
        if (!reach[i])
            continue;
        const struct node *nd = &g->n[i];
        const int rd = (nd->word >> 7) & 31;
        if (mux_has_imm(nd))
            num_imm++;
        if (nd->kind == K_SYSTEM && sys[i].kind == SYS_WRITE)
            num_spool += (int) sys[i].len;

        /* Any op that writes a non-x0 rd: li, a JAL link, an ALU result, an
         * upper immediate, a load, or a resolved computed/linking JALR.
         */
        if (rd && (fold_kind(nd->word) == FOLD_LI12 || nd->kind == K_JAL ||
                   nd->kind == K_LUI || nd->kind == K_AUIPC ||
                   (nd->kind == K_LOAD && nd->funct3 != 3 && nd->funct3 <= 5) ||
                   (nd->kind == K_JALR && nd->target != NONE) || mux_alu(nd)))
            def[rd] = true;
    }
    int ndef = 0;
    for (int r = 0; r < 32; r++)
        ndef += def[r];

    /* Each promoted slot adds one offset imm pair (shared by its pre-header
     * load and post-loop store), placed after the program-order imm cells.
     */
    const int num_imm_prog = num_imm;
    num_imm += npromo;

    /* Sizing pass: run the emitter with output suppressed to fill na[]. The
     * layout addresses are all-0 dummies here (nothing is printed).
     */
    struct mlayout m = {0};
    g_sizing = true;
    int p = 0, imm = 0, spool = 0;
    for (int i = 1; i < g->count; i++) {
        na[i] = p;
        if (reach[i])
            emit_one(g, i, &m, na, sys, folded, fwd, &pe, ret_node, &p, &imm,
                     &spool);
    }
    const int nat = p;
    na[g->count] = nat; /* a last-instruction branch falls through to here */
    g_sizing = false;

    /* Data region: code | imm pairs | write bytes | regfile | promo cells |
     * temps | consts. Promoted-slot offset cells sit at the tail of the imm
     * pool (index promo_imm_base); the dedicated cell pairs sit just above the
     * 64-cell regfile.
     */
    m.imm_base = nat + 3 * ndef + 3; /* code = insns + PUTs + halt */
    m.promo_imm_base = num_imm_prog;
    m.spool_base = m.imm_base + 2 * num_imm;
    m.reg_base = m.spool_base + num_spool;
    m.promo_base = m.reg_base + 64;   /* dedicated promoted-slot cells */
    m.t0 = m.promo_base + 2 * npromo; /* compare temp (EQ16/NE16) */
    m.bt = m.t0 + 1;                  /* LTU16 bit15 temp */
    m.d = m.bt + 1;                   /* LTU16 a-b diff */
    m.v = m.d + 1;                    /* LTU16 3-vote counter */
    m.sh1 = m.v + 1;                  /* BLT/BGE sign-flipped rs1.hi */
    m.sh2 = m.sh1 + 1;                /* BLT/BGE sign-flipped rs2.hi */
    m.ol = m.sh2 + 1;                 /* ALU output lo */
    m.oh = m.ol + 1;                  /* ALU output hi */
    m.z = m.oh + 1;                   /* 0 (branch/halt) */
    m.neg1 = m.z + 1;                 /* -1 (equality add-1 test / INC) */
    m.one = m.neg1 + 1;               /* 1 (DEC) */
    m.sgn = m.one + 1;                /* 0x8000 (BIT15C MUX mask) */
    m.m1f = m.sgn + 1;                /* 0x1F (SLL shift-count mask) */
    m.mff = m.m1f + 1;                /* 0xFF (SB byte mask) */
    m.winmask = m.mff + 1;   /* RAM window size - 1 (in-window address mask) */
    m.rambc = m.winmask + 1; /* ram_base value (added after the mask) */
    m.rsite = m.rambc + 1; /* the call site's return address (ret's ra check) */
    m.mask_base = m.rsite + 1; /* 16 power-of-two cells 1..0x8000 */
    m.ram_base = m.mask_base + 16;
    m.winsize = 1; /* smallest power of two covering the touched guest bytes */
    while (m.winsize < (int) used)
        m.winsize <<= 1;

    /* Every cell used as a MUX mask address (via 0x8000|addr) must stay below
     * IO_MARKER's 0x7FFF (0x8000|0x7FFF == 0xFFFF decodes as halt); the highest
     * such cell is mask_base+15. The RAM window sits above and only needs to
     * fit the 15-bit cell space (its cells are SMC MOVE operands, not MUX
     * masks).
     */
    if (m.mask_base + 16 > 0x7FFF || m.ram_base + m.winsize > (1 << 15)) {
        fprintf(stderr, "rvopt -mux: image needs %d cells (> 32768)\n",
                m.ram_base + m.winsize);
        free(na);
        exit(1);
    }

    /* Emit pass: same emitter, real addresses. */
    p = imm = spool = 0;
    for (int i = 1; i < g->count; i++)
        if (reach[i])
            emit_one(g, i, &m, na, sys, folded, fwd, &pe, ret_node, &p, &imm,
                     &spool);
    for (int r = 0; r < 32; r++)
        if (def[r])
            emit_i(&p, m.reg_base + 2 * r, 65535,
                   0);           /* PUT reg[r].lo low byte */
    emit_i(&p, m.z, m.z, 65535); /* halt */

    /* Data: immediate halves (program order), the write-ecall bytes, 64 zeroed
     * register cells, the eight zero-init temps (T0/BT/D/V/SH1/SH2/OL/OH), then
     * Z/-1/1/0x8000/0x1F/0xFF, the window mask + ram_base + return-address
     * values, the 16 power-of-two mask cells, then the guest RAM window (a
     * power of two, init from the loaded image). The imm and byte walks mirror
     * the emit order (both skip unreachable nodes) so the pool indices line up.
     */
    for (int i = 1; i < g->count; i++) {
        if (!reach[i] || !mux_has_imm(&g->n[i]))
            continue;
        const struct node *nd = &g->n[i];
        uint32_t v = (uint32_t) nd->imm; /* li12, LUI, an ALU immediate */
        if (folded[i])
            v = (uint32_t) foldval[i]; /* const-folded ALU: stage its result */
        else if (nd->kind == K_JAL)
            v = nd->pc + 4; /* link = return address */
        else if (nd->kind == K_AUIPC)
            v = nd->pc + (uint32_t) nd->imm; /* pc-relative upper immediate */
        /* K_LOAD/K_STORE keep the raw offset; ram_base is added after masking
         */
        printf("%u\n%u\n", v & 0xFFFF, (v >> 16) & 0xFFFF);
    }
    for (int l = 0; l < nloops; l++) /* promoted-slot offset cells (g order) */
        for (int s = 0; s < loops[l].nslot; s++) {
            const uint32_t o = (uint32_t) loops[l].slot[s].imm;
            printf("%u\n%u\n", o & 0xFFFF, (o >> 16) & 0xFFFF);
        }
    for (int i = 1; i < g->count; i++)
        if (reach[i] && g->n[i].kind == K_SYSTEM && sys[i].kind == SYS_WRITE)
            for (uint32_t k = 0; k < sys[i].len; k++)
                printf("%u\n", img[sys[i].buf + k]);
    for (int k = 0; k < 64 + 2 * npromo + 8 + 1; k++)
        printf("0\n"); /* regfile + promoted cells + 8 temps + Z, all zero */
    printf("-1\n1\n32768\n31\n255\n"); /* -1, 1, 0x8000, 0x1F, 0xFF constants */
    printf("%d\n%d\n%u\n", m.winsize - 1, m.ram_base, /* winmask, ram_base, */
           ret_addr & 0xFFFF);   /* rsite (return address) */
    for (int b = 0; b < 16; b++) /* mask pool 1..0x8000 */
        printf("%d\n", 1 << b);
    for (int k = 0; k < m.winsize; k++) /* guest RAM window, init from img */
        printf("%u\n", k < (int) used ? img[k] : 0);
    free(pro_cell);
    free(pro_post);
    free(pro_pre);
    free(loops);
    free(fwd);
    free(folded);
    free(foldval);
    free(reach);
    free(sys);
    free(na);
}

int main(int argc, char **argv)
{
    if (argc == 3 && !strcmp(argv[1], "-dump")) {
        size_t used;
        unsigned char *img = load_guest(argv[2], &used);
        struct graph g = decode_graph(img, used);
        dump_graph(&g, argv[2]);

        /* Register-promotion opportunities (analysis only; the emit that
         * consumes them is a later milestone). Printed as ';' comment lines so
         * -check ignores them.
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
    if (argc == 3 && !strcmp(argv[1], "-check"))
        return check_ir(argv[2]);
    if (argc == 3 && !strcmp(argv[1], "-mux")) {
        size_t used;
        unsigned char *img = load_guest(argv[2], &used);
        struct graph g = decode_graph(img, used);
        emit_mux(&g, img, used);
        free_graph(&g);
        free(img);
        return 0;
    }

    fprintf(stderr,
            "usage: rvopt -dump FILE    (decode, write textual IR)\n"
            "       rvopt -check FILE   ('-' = stdin, verify textual IR)\n"
            "       rvopt -mux FILE     (emit native MUXLEQ .dec image)\n");
    return 2;
}
