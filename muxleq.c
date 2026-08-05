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

static int read_host_input(void);
static int write_host_output(uint32_t out);

/* The interpreter itself lives in muxleq-core.h, shared with the WebAssembly
 * build. This host blocks on input and never runs out of budget, so both yield
 * statuses are unreachable here and mux_exec() returns only MUX_OK or
 * MUX_ERR_OUTPUT, which are the process exit codes.
 */
#define MUX_GETC() read_host_input()
#define MUX_PUTC(v) write_host_output(v)
#include "muxleq-core.h"

/* The EDIT_* sentinels this host intercepts are the image-to-host protocol and
 * come from muxleq-core.h. This one is not part of it: how long to wait for the
 * rest of an escape sequence is a tty policy, and a host without a tty has no
 * use for it.
 */
#define EDIT_PEEK_MS 50 /* ttimeoutlen: an arrow burst arrives <50ms apart */

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
    if (MUX_UNLIKELY(edit_peek_pending)) {
        edit_peek_pending = false;
        if (raw_mode_active) {
            struct pollfd pfd = {.fd = STDIN_FILENO, .events = POLLIN};
            int pr;
            do {
                pr = poll(&pfd, 1, EDIT_PEEK_MS);
            } while (pr < 0 && errno == EINTR);
            if (pr <= 0 || !(pfd.revents & POLLIN))
                return (int) EDIT_PEEK_NONE;
        }
    }

    /* The core compares against MUX_EOF, and the standard only promises EOF is
     * some negative value, so translate rather than assume they are the same.
     */
    const int c = getchar();
    return c == EOF ? MUX_EOF : c;
}

static int write_host_output(uint32_t out)
{
    if (MUX_UNLIKELY(out == EDIT_RAW_ON)) {
        raw_wanted = 1;
        enter_raw_mode();
    } else if (MUX_UNLIKELY(out == EDIT_RAW_OFF)) {
        raw_wanted = 0;
        leave_raw_mode();
    } else if (MUX_UNLIKELY(out == EDIT_PEEK)) {
        edit_peek_pending = true;
    } else if (MUX_UNLIKELY(putchar((int) (out & 0xFF)) == EOF)) {
        return MUX_ERR_OUTPUT;
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

struct muxleq_image {
    uint32_t *m;
    uint32_t mask;
    size_t size;
};

/* Print "muxleq: <message>" to stderr and exit non-zero. Process teardown
 * reclaims the image and any open file, so callers need not free before dying.
 */
MUX_NORETURN static void die(const char *fmt, ...)
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

static void suspend_handler(MUX_UNUSED int sig)
{
    leave_raw_mode();
    raise(SIGSTOP);
}

static void resume_handler(MUX_UNUSED int sig)
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
    struct mux_state st = {.m = img.m, .mask = img.mask, .pc = 0};
    const int rc = mux_exec(&st);
    free(img.m);
    return rc;
}
