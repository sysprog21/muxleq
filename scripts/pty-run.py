#!/usr/bin/env python3
"""Drive muxleq's interactive (raw-mode) editor over a pty and print its final
normalized screen.

A modal editor's cursor/redraw is the whole point and cannot be captured by a
pipe golden, so golden-pty feeds a fixed keystroke script (read as raw bytes from
stdin) into ./muxleq under a pty, waits for the screen to settle, and prints the
last full repaint with ANSI stripped and the 16x64 grid re-chunked into rows.
Output is byte-deterministic because the keystroke script blanks the block first,
so it does not depend on the image bytes the block buffer overlays.

Exit nonzero on: no raw mode, early process death, or a hang (timeout). No
wall-clock sleep is load-bearing for correctness -- settling is detected by a
quiet read, the sleeps only bound how long a hung run waits.
"""

import os
import re
import select
import subprocess
import sys
import termios
import time

RAW_WAIT = 3.0  # seconds to see the image switch the tty into raw mode
QUIET = 0.5  # seconds with no output => the editor has settled
TIMEOUT = 10.0  # overall hang guard
COLS, ROWS = 64, 16
NO_PTY = 77  # exit code: no usable pty here, treat as skip (not a failure)


def is_raw(fd):
    # The editor puts the tty in raw mode (ICANON and ECHO both cleared); the
    # ANSI redraws are the only visible output. ICANON-off is the signal that
    # the editor has taken over.
    lflag = termios.tcgetattr(fd)[3]
    return not (lflag & termios.ICANON)


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: pty-run.py BINARY  (keystrokes on stdin)\n")
        return 2
    keys = sys.stdin.buffer.read()
    try:
        master, slave = os.openpty()
    except OSError as e:
        sys.stderr.write(f"pty-run: no usable pty ({e}); skipping\n")
        return NO_PTY
    # The child's stderr is dropped so it never pollutes the captured screen,
    # except when PTY_RUN_STDERR is set (the sanitize run wants ASan/UBSan
    # reports to reach the caller).
    child_stderr = None if os.environ.get("PTY_RUN_STDERR") else subprocess.DEVNULL
    proc = subprocess.Popen(
        [sys.argv[1]],
        stdin=slave,
        stdout=slave,
        stderr=child_stderr,
        close_fds=True,
    )
    os.close(slave)
    start = time.monotonic()
    os.set_blocking(master, False)
    buf = b""

    def settle():
        """Read until QUIET seconds pass with no output, or the hang guard."""
        nonlocal buf
        last = time.monotonic()
        while time.monotonic() - last < QUIET:
            if time.monotonic() - start > TIMEOUT:
                sys.stderr.write("pty-run: timeout\n")
                proc.kill()
                sys.exit(1)
            ready, _, _ = select.select([master], [], [], QUIET)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    chunk = b""
                if chunk:
                    buf += chunk
                    last = time.monotonic()

    # The tty starts cooked; the editor switches it to raw only after its launch
    # word runs. Send the launch line (through the first CR) first, wait for the
    # editor to enter raw, then feed the editor keystrokes.
    nl = keys.find(b"\r")
    launch, rest = (keys[: nl + 1], keys[nl + 1 :]) if nl >= 0 else (keys, b"")
    os.write(master, launch)
    while not is_raw(master):
        if time.monotonic() - start > RAW_WAIT or proc.poll() is not None:
            sys.stderr.write("pty-run: editor never entered raw mode\n")
            proc.kill()
            return 1
        time.sleep(0.01)
    settle()
    if rest:
        os.write(master, rest)
        settle()

    # The script is expected to leave the process sitting in the editor's key
    # loop. Actual process death here -- an EOF exit or a crash -- means the
    # captured screen is meaningless. (A Forth throw would fall back to the REPL
    # without exiting; that surfaces instead as trailing bytes past the last
    # clear-screen, which fails the byte compare.)
    if proc.poll() is not None:
        sys.stderr.write("pty-run: process exited before capture (crash/EOF?)\n")
        return 1

    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()

    # Keep only the last full repaint (everything after the final clear-screen),
    # strip CSI escapes and carriage returns, then re-chunk the 16x64 grid into
    # rows for a readable, deterministic screen.
    clear = buf.rfind(b"\x1b[2J")
    text = buf[clear:] if clear >= 0 else buf
    text = re.sub(rb"\x1b\[[0-9;]*[A-Za-z]", b"", text).replace(b"\r", b"")
    out = sys.stdout.buffer
    for r in range(ROWS):
        out.write(text[r * COLS : (r + 1) * COLS] + b"\n")
    out.write(text[ROWS * COLS :] + b"\n")  # status line remainder
    return 0


if __name__ == "__main__":
    sys.exit(main())
