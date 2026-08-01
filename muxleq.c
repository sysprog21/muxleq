/*
 * MUXLEQ virtual machine.
 *
 * A 32-bit-cell, cell-addressed VM. With no argument it runs the baked eForth
 * image; given a FILE it loads and runs that standalone image instead.
 */

/* isatty()/fileno() are POSIX; request them under a strict -std=c99 on glibc
 * (macOS exposes them regardless, so this only matters when building on Linux).
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#if defined(__GNUC__) || defined(__clang__)
#define UNUSED __attribute__((unused))
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
#define UNUSED
#define UNLIKELY(x) (x)
#endif

/* Editor terminal-mode control. The modal editor emits these sentinels through
 * the normal output path; write_host_output() intercepts them. Kept in sync
 * with the raw-on/raw-off/peek words in forth/65-optional-editor.fth.
 */
#define EDIT_RAW_ON 0xFF01u
#define EDIT_RAW_OFF 0xFF00u
#define EDIT_PEEK 0xFF02u
#define EDIT_PEEK_MS 50 /* ttimeoutlen: an arrow burst arrives <50ms apart */

/* Cell 6 is hardwired to 0, so a MUX whose mask address is 6 masks against zero
 * and is therefore a pure MOVE.
 */
#define ZERO_MASK_ADDR 6u

enum { A = 0, B = 1, C = 2, INSN_SIZE = 3 };

static const uint32_t default_image[] = {
#include <stage0.c>
};

static void enter_raw_mode(void);
static void leave_raw_mode(void);

static volatile sig_atomic_t raw_mode_active = 0;
static volatile sig_atomic_t raw_wanted = 0;
static bool edit_peek_pending = false;

static int read_host_input(void)
{
    if (UNLIKELY(edit_peek_pending)) {
        edit_peek_pending = false;
        if (raw_mode_active) {
            struct pollfd pfd = {.fd = STDIN_FILENO, .events = POLLIN};
            int pr;
            do {
                pr = poll(&pfd, 1, EDIT_PEEK_MS);
            } while (pr < 0 && errno == EINTR);
            if (pr <= 0 || !(pfd.revents & POLLIN))
                return 0x100;
        }
    }
    return getchar();
}

static int write_host_output(uint32_t out)
{
    if (UNLIKELY(out == EDIT_RAW_ON)) {
        raw_wanted = 1;
        enter_raw_mode();
    } else if (UNLIKELY(out == EDIT_RAW_OFF)) {
        raw_wanted = 0;
        leave_raw_mode();
    } else if (UNLIKELY(out == EDIT_PEEK)) {
        edit_peek_pending = true;
    } else if (UNLIKELY(putchar((int) (out & 0xFF)) == EOF)) {
        return 3;
    }
    return 0;
}

#ifndef MUX_MAX_CELLS
#define MUX_MAX_CELLS (1u << 26) /* 64M cells / 256 MiB host cap */
#endif
#define MUX_MIN_CELLS \
    (1u << 16) /* 64K cells / 256 KiB: holds eForth high task area */
#if MUX_MAX_CELLS < MUX_MIN_CELLS || (MUX_MAX_CELLS & (MUX_MAX_CELLS - 1))
#error "MUX_MAX_CELLS must be a power of two >= MUX_MIN_CELLS"
#endif

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

struct muxleq_image {
    uint32_t *m;
    uint32_t mask;
    size_t size;
};

/* Print "muxleq: <message>" to stderr and exit non-zero. Process teardown
 * reclaims the image and any open file, so callers need not free before dying.
 */
static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs("muxleq: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(1);
}

static void grow_muxleq(struct muxleq_image *img, const char *path)
{
    if (img->size >= MUX_MAX_CELLS)
        die("'%s' exceeds the %u-cell wide image", path, MUX_MAX_CELLS);
    size_t new_size = img->size * 2;
    if (new_size > MUX_MAX_CELLS)
        new_size = MUX_MAX_CELLS;
    uint32_t *m = calloc(new_size, sizeof *m);
    if (!m)
        die("out of memory for the wide image");
    memcpy(m, img->m, img->size * sizeof *m);
    free(img->m);
    img->m = m;
    img->size = new_size;
    img->mask = (uint32_t) (new_size - 1);
}

static struct muxleq_image alloc_muxleq(size_t cells, const char *path)
{
    struct muxleq_image img = {.size = MUX_MIN_CELLS};
    while (img.size < cells) {
        if (img.size >= MUX_MAX_CELLS)
            die("'%s' exceeds the %u-cell wide image", path, MUX_MAX_CELLS);
        img.size *= 2;
    }
    img.mask = (uint32_t) (img.size - 1);
    img.m = calloc(img.size, sizeof *img.m);
    if (!img.m)
        die("out of memory for the wide image");
    return img;
}

static struct muxleq_image load_default(void)
{
    const size_t n = sizeof default_image / sizeof default_image[0];
    struct muxleq_image img = alloc_muxleq(n, "baked image");
    memcpy(img.m, default_image, n * sizeof *img.m);
    return img;
}

static struct muxleq_image load_muxleq(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f)
        die("cannot open '%s'", path);
    struct muxleq_image img = alloc_muxleq(1, path);
    size_t n = 0;

    /* One token per cell: decimal by default (rvopt output), or 0x-prefixed hex
     * (eForth bootstrap output). Signed (-1) and unsigned (4294967295)
     * spellings of a cell both parse.
     */
    for (char tok[32]; fscanf(f, "%31s", tok) == 1;) {
        errno = 0;
        char *end;
        const char *digits = tok;
        if (*digits == '-' || *digits == '+')
            digits++;
        const int base =
            digits[0] == '0' && (digits[1] == 'x' || digits[1] == 'X') ? 16
                                                                       : 10;
        const long long v = strtoll(tok, &end, base);
        if (*end != '\0' || errno == ERANGE || v < -2147483648LL ||
            v > 4294967295LL)
            die("'%s' has a bad cell '%s'", path, tok);
        if (n == img.size)
            grow_muxleq(&img, path);
        img.m[n++] = (uint32_t) v;
    }
    const bool io_err = ferror(f);
    fclose(f);
    if (io_err)
        die("read error on '%s'", path);
    if (n == 0)
        die("'%s' is empty", path);
    return img;
}

/* A negative c selects MUX over SUBLEQ, but c == IO_MARKER32 is a SUBLEQ jump
 * target, not a MUX, so that value must fall through. The guard is load-bearing
 * and shared by exec_alu() and run()'s MOVE gate; keep them in sync here.
 */
static inline bool is_mux(uint32_t c)
{
    return (c & NEG_FLAG32) && c != IO_MARKER32;
}

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

static int run(const struct muxleq_image *img)
{
    uint32_t *m32 = img->m;
    const uint32_t mask32 = img->mask;
    uint32_t pc = 0;
    for (;;) {
        if (UNLIKELY(pc & NEG_FLAG32))
            return 0;
        const uint32_t a = m32[pc & mask32];
        const uint32_t b = m32[(pc + B) & mask32];
        const uint32_t c = m32[(pc + C) & mask32];
        if (a == IO_MARKER32) {
            const int in = read_host_input();
            if (UNLIKELY(in == EOF))
                return 0;
            m32[b & mask32] = (uint32_t) in;
            pc += INSN_SIZE;
        } else if (b == IO_MARKER32) {
            const int rc = write_host_output(m32[a & mask32]);
            if (UNLIKELY(rc))
                return rc;
            pc += INSN_SIZE;
        } else if (is_mux(c) && (c & ADDR_MASK32) == ZERO_MASK_ADDR) {
            /* A MOVE. eForth fakes SUBLEQ's missing indirection by MOVEing a
             * live address into an operand field of the very next instruction,
             * then executing it. This idiom is ~23% of all ops (fusing it
             * measured ~1.5x on the compute goldens). Fuse the pair: do the
             * MOVE's store, then run that next instruction here, forwarding the
             * just-written field from a register instead of storing it and
             * reloading it through the store-to-load stall. The store still
             * happens, so state stays byte-identical to running the two
             * instructions in sequence; only the reload is elided.
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
}

static struct termios cooked_termios;
static bool tty_interactive = false;

static void leave_raw_mode(void)
{
    if (raw_mode_active) {
        raw_mode_active = 0;
        tcsetattr(STDIN_FILENO, TCSANOW, &cooked_termios);
    }
}

static void enter_raw_mode(void)
{
    if (!tty_interactive || raw_mode_active)
        return;
    struct termios raw = cooked_termios;
    raw.c_lflag &= ~(tcflag_t) (ICANON | ECHO);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0)
        raw_mode_active = 1;
}

static void restore_and_reraise(int sig)
{
    leave_raw_mode();
    raise(sig);
}

static void install_handler(int sig, void (*handler)(int), int flags)
{
    struct sigaction sa;
    sa.sa_handler = handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = flags;
    sigaction(sig, &sa, NULL);
}

static void suspend_handler(UNUSED int sig)
{
    leave_raw_mode();
    raise(SIGSTOP);
}

static void resume_handler(UNUSED int sig)
{
    if (raw_wanted)
        enter_raw_mode();
}

static bool terminal_setup(void)
{
    if (!isatty(STDIN_FILENO))
        return false;
    if (tcgetattr(STDIN_FILENO, &cooked_termios) != 0)
        return false;
    tty_interactive = true;
    atexit(leave_raw_mode);

    install_handler(SIGINT, restore_and_reraise, SA_RESETHAND);
    install_handler(SIGTERM, restore_and_reraise, SA_RESETHAND);
    install_handler(SIGQUIT, restore_and_reraise, SA_RESETHAND);
    install_handler(SIGHUP, restore_and_reraise, SA_RESETHAND);
    install_handler(SIGSEGV, restore_and_reraise, SA_RESETHAND);
    install_handler(SIGTSTP, suspend_handler, SA_RESTART);
    install_handler(SIGCONT, resume_handler, SA_RESTART);
    return true;
}

/* Report a usage error on stderr and return the process exit code. A non-NULL
 * opt names an unrecognized option; the single usage line lives only here.
 */
static int usage_error(const char *opt)
{
    if (opt)
        fprintf(stderr, "muxleq: unknown option '%s'\n", opt);
    fprintf(stderr, "usage: muxleq [--] [FILE]\n");
    return 1;
}

int main(int argc, char **argv)
{
    struct muxleq_image img = {0};
    const char *file = NULL;
    if (argc >= 2 && !strcmp(argv[1], "--")) {
        /* "--" ends option parsing: the next arg, if any, is a FILE even when
         * it begins with '-'.
         */
        if (argc > 3)
            return usage_error(NULL);
        file = argc == 3 ? argv[2] : NULL;
    } else if (argc == 2) {
        if (argv[1][0] == '-')
            return usage_error(argv[1]);
        file = argv[1];
    } else if (argc > 2) {
        return usage_error(NULL);
    }
    if (file)
        img = load_muxleq(file);

    if (terminal_setup()) {
        setvbuf(stdin, NULL, _IONBF, 0);
        if (isatty(fileno(stdout)))
            setvbuf(stdout, NULL, _IONBF, 0);
        else
            setvbuf(stdout, NULL, _IOFBF, BUFSIZ);
    } else {
        const int mode = isatty(fileno(stdout)) ? _IOLBF : _IOFBF;
        setvbuf(stdout, NULL, mode, BUFSIZ);
        if (mode == _IOFBF)
            setvbuf(stdin, NULL, _IOFBF, BUFSIZ);
    }

    if (!file)
        img = load_default();
    const int rc = run(&img);
    free(img.m);
    return rc;
}
