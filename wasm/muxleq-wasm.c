/*
 * WebAssembly host for the MUXLEQ VM.
 *
 * A browser tab cannot block on a keystroke the way getchar() does, so this
 * host never blocks: mux_run() interprets for a bounded slice and returns,
 * leaving the pc where it stopped. The caller drains output, hands over any new
 * input, and calls again. The interpreter itself is muxleq-core.h, shared
 * verbatim with the native VM, so SMC behavior cannot drift between the two.
 *
 * Built for wasm32 this needs no libc and no imports at all. It also compiles
 * for the host, where main() drives the same resumable loop off stdin; that
 * build is what check-wasm diffs against the reference VM.
 */

#include <stdint.h>

/* The encoding half of the core: the EDIT_* protocol and MUX_STATIC_ASSERT,
 * both of which the declarations below need. The interpreter arrives with the
 * second include further down, once this host has said how it moves bytes. The
 * header guards its two halves separately, so taking them in two steps is a
 * supported way to include it rather than a trick.
 *
 * There is no terminal here, so this host drops the two EDIT_* mode switches
 * and answers only the peek.
 */
#include "muxleq-core.h"

/* 64K cells / 256 KiB, the same floor the native loader allocates: enough for
 * the baked eForth image plus its high task area. The image is fixed here
 * because the browser build only ever runs the baked eForth.
 */
#define MUX_CELLS (1u << 16)

/* Power-of-two ring sizes so the wrap is a mask. The output high-water mark
 * ends the slice early, which bounds how much can pile up before the host gets
 * a chance to drain.
 */
#define IN_QUEUE 4096u
#define OUT_BYTES 65536u
#define OUT_HIGH_WATER (OUT_BYTES / 2)

#if defined(__wasm__)
#define WASM_EXPORT(name) __attribute__((export_name(#name), used))
#else
#define WASM_EXPORT(name)
#endif

/* The module's entire interface to the page. Declared up front because these
 * are the ABI, not incidental externals: a caller drives the VM by resetting
 * it, pushing input, running a slice, draining output, and reading cells, in
 * that order. Nothing else is exported and nothing is imported.
 */
WASM_EXPORT(mux_reset) void mux_reset(void);
WASM_EXPORT(mux_run) int mux_run(uint32_t slice);
WASM_EXPORT(mux_push) int mux_push(uint32_t byte);
WASM_EXPORT(mux_eof) void mux_eof(void);
WASM_EXPORT(mux_out) uint8_t *mux_out(void);
WASM_EXPORT(mux_out_len) uint32_t mux_out_len(void);
WASM_EXPORT(mux_out_clear) void mux_out_clear(void);
WASM_EXPORT(mux_mem) uint32_t *mux_mem(void);
WASM_EXPORT(mux_cells) uint32_t mux_cells(void);
WASM_EXPORT(mux_out_high_water) uint32_t mux_out_high_water(void);

static uint32_t mem[MUX_CELLS];

static const uint32_t baked_image[] = {
#include <stage0.c>
};

/* The native loader grows its image to fit; this one is a fixed array, so an
 * image that outgrew it would be silently truncated and fail at run time in a
 * way nobody would trace back to here. Fail the build instead.
 */
MUX_STATIC_ASSERT(baked_image_fits,
                  sizeof baked_image / sizeof baked_image[0] <= MUX_CELLS);

static uint8_t in_queue[IN_QUEUE];
static uint32_t in_head, in_tail;
static int input_ended;

static uint8_t out_buf[OUT_BYTES];
static uint32_t out_len;

static uint32_t budget;
static int peek_pending;

static int wasm_getc(void);
static int wasm_putc(uint32_t out);

#define MUX_GETC() wasm_getc()
#define MUX_PUTC(v) wasm_putc(v)
#define MUX_OUT_OF_BUDGET() (budget-- == 0)
#include "muxleq-core.h"

static struct mux_state vm;

static int wasm_getc(void)
{
    const int empty = in_head == in_tail;
    if (peek_pending) {
        peek_pending = 0;

        /* A peek asks "is a key waiting?", which is answerable right now even
         * when a plain read would have to suspend.
         */
        if (empty)
            return (int) EDIT_PEEK_NONE;
    }
    if (empty)
        return input_ended ? MUX_EOF : MUX_WOULD_BLOCK;
    return in_queue[in_head++ & (IN_QUEUE - 1)];
}

static int wasm_putc(uint32_t out)
{
    if (out == EDIT_RAW_ON || out == EDIT_RAW_OFF)
        return 0;
    if (out == EDIT_PEEK) {
        peek_pending = 1;
        return 0;
    }

    /* Unreachable while the caller honors the contract: the high-water mark
     * below ends the slice as soon as the buffer is half full, and the caller
     * drains between slices. If it ever does happen, losing output silently
     * would be a transcript that quietly disagrees with what ran, so fail the
     * same way the native host fails a write.
     */
    if (out_len >= OUT_BYTES)
        return MUX_ERR_OUTPUT;
    out_buf[out_len++] = (uint8_t) (out & 0xFF);
    if (out_len >= OUT_HIGH_WATER)
        budget = 0; /* end the slice at the next instruction so it can drain */
    return 0;
}

/* Load the baked eForth image and start over from pc 0. */
WASM_EXPORT(mux_reset) void mux_reset(void)
{
    const uint32_t n = (uint32_t) (sizeof baked_image / sizeof baked_image[0]);
    for (uint32_t i = 0; i < MUX_CELLS; i++)
        mem[i] = i < n ? baked_image[i] : 0;
    vm.m = mem;
    vm.mask = MUX_CELLS - 1;
    vm.pc = 0;
    in_head = in_tail = out_len = 0;
    input_ended = peek_pending = 0;
}

/* Interpret for a slice of about "slice" steps, then return: MUX_YIELD when the
 * slice ran out, MUX_NEED_INPUT when the queue is empty, MUX_OK once the image
 * halts. "About" because a fused MOVE-plus-ALU pair spends one step; the caller
 * sizes the slice by how long a turn actually took, not by counting.
 */
WASM_EXPORT(mux_run) int mux_run(uint32_t slice)
{
    budget = slice;
    return mux_exec(&vm);
}

/* Queue one input byte.
 *
 * Returns 0 if the queue is full and the byte was dropped, so a caller feeding
 * a large paste can retry after the next slice.
 */
WASM_EXPORT(mux_push) int mux_push(uint32_t byte)
{
    if (in_tail - in_head >= IN_QUEUE)
        return 0;
    in_queue[in_tail++ & (IN_QUEUE - 1)] = (uint8_t) (byte & 0xFF);
    return 1;
}

/* Report end of input, so a read past the queue halts instead of suspending. */
WASM_EXPORT(mux_eof) void mux_eof(void)
{
    input_ended = 1;
}

WASM_EXPORT(mux_out) uint8_t *mux_out(void)
{
    return out_buf;
}

WASM_EXPORT(mux_out_len) uint32_t mux_out_len(void)
{
    return out_len;
}

WASM_EXPORT(mux_out_clear) void mux_out_clear(void)
{
    out_len = 0;
}

/* The whole cell array, so a page can watch a region of Forth memory (the
 * tutorial's frame buffer) without the image having to push it out a byte at a
 * time.
 */
WASM_EXPORT(mux_mem) uint32_t *mux_mem(void)
{
    return mem;
}

WASM_EXPORT(mux_cells) uint32_t mux_cells(void)
{
    return MUX_CELLS;
}

/* The point at which a turn is cut short so the caller can drain. Exported
 * rather than written down on both sides: the caller needs it to tell that kind
 * of yield from a genuinely slow one, and two copies of a threshold silently
 * disagree the moment one of them changes.
 */
WASM_EXPORT(mux_out_high_water) uint32_t mux_out_high_water(void)
{
    return OUT_HIGH_WATER;
}

#if !defined(__wasm__)
#include <stdio.h>

/* Host driver: run the same resumable loop against stdin/stdout so its output
 * can be diffed against the reference VM. Slices are deliberately small so the
 * suspend and resume paths are exercised many times per run.
 */
int main(void)
{
    mux_reset();
    for (;;) {
        const int status = mux_run(50000);
        for (uint32_t i = 0; i < out_len; i++) {
            /* The reference VM stops with MUX_ERR_OUTPUT when a write fails, so
             * this host has to as well. Ignoring it would turn a failed write
             * into a successful run with silently truncated output, and
             * check-wasm would then report a diff against the reference with no
             * hint that the cause was the pipe rather than the interpreter.
             */
            if (putchar(out_buf[i]) == EOF)
                return MUX_ERR_OUTPUT;
        }
        out_len = 0;
        if (status == MUX_OK)
            break;
        if (status != MUX_NEED_INPUT)
            continue;
        const int c = getchar();
        if (c == EOF)
            mux_eof();
        else
            mux_push((uint32_t) c);
    }
    return 0;
}
#endif
