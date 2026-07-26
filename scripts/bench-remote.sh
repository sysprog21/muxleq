#!/bin/sh

# Runs on the benchmark host (node1) inside a temp dir populated by bench.sh.
# Builds the VM from the shipped sources and reports throughput for a fixed,
# representative, deterministic workload set as Mops/s = dispatched MUXLEQ ops
# per second -- the precise, workload-normalized VM performance figure.
#
# Fails loudly on any build/run error or missing timing/count: a benchmark that
# silently reports a bogus 0 is worse than one that stops.
set -e
. ./bench.env # TIME, REPS, CFLAGS
MUXLEQ_CC=${MUXLEQ_CC:-${CC:-$(command -v clang >/dev/null 2>&1 && echo clang || echo cc)}}

command -v /usr/bin/time >/dev/null 2>&1 || {
    echo "bench: /usr/bin/time not found (install the 'time' package)" >&2
    exit 1
}

$MUXLEQ_CC $CFLAGS -o muxleq muxleq.c

TOTAL_OPS=0
TOTAL_T=0

# Report throughput for one FIXED-WORK workload as Mops/s = million dispatched
# instructions per second. NOTE the unit: -s counts dispatch() entries, NOT raw
# MUXLEQ ops -- fused MOVE/SUBLEQ that execute inline never re-enter dispatch
# (muxleq.c), so the true op count is higher; this "op" is one dispatched
# instruction, i.e. the interpreter's dispatch rate. It is still an exact,
# deterministic performance figure: the count is identical every run
# (machine-independent), so it is captured ONCE with -s, while wall-clock is
# measured over REPS UNINSTRUMENTED runs (the -s counter itself perturbs timing)
# keeping the best (min) user time -- the least-perturbed sample. Exact
# numerator over a noise-minimized denominator, so the raw count is never shown
# on its own -- always turned into a rate.
run() {
    name=$1
    shift
    "$@" >input.tmp
    ./muxleq -s <input.tmp >/dev/null 2>stats.tmp
    ops=$(awk '/dispatched instructions:/ { print $3 }' stats.tmp)
    [ -n "$ops" ] || { echo "bench: $name produced no dispatch count" >&2; exit 1; }
    best=
    i=0
    while [ "$i" -lt "$REPS" ]; do
        /usr/bin/time -p ./muxleq <input.tmp >/dev/null 2>time.tmp
        t=$(awk '/^user/ { print $2 }' time.tmp)
        [ -n "$t" ] || { echo "bench: $name produced no timing" >&2; exit 1; }

        # a 0.00s sample means the workload is too short to time reliably -- the
        # min would latch onto it and divide by zero below, so fail loud
        # instead.
        awk -v t="$t" 'BEGIN { exit (t > 0) ? 0 : 1 }' || {
            echo "bench: $name user time is ${t}s -- workload too short; raise TIME/REPS" >&2
            exit 1
        }
        best=$(awk -v a="$t" -v b="${best:-99999}" 'BEGIN { print (a < b) ? a : b }')
        i=$((i + 1))
    done
    TOTAL_OPS=$(awk -v a="$TOTAL_OPS" -v b="$ops" 'BEGIN { printf "%.0f", a + b }')
    TOTAL_T=$(awk -v a="$TOTAL_T" -v b="$best" 'BEGIN { print a + b }')
    awk -v n="$name" -v o="$ops" -v t="$best" 'BEGIN {
        printf "  %-11s %15s ops  best %8.3fs  %9.1f Mops/s\n", n, o, t, o / t / 1e6 }'
}

echo "=== muxleq throughput on $(hostname), best user of $REPS reps (Mops/s = M dispatched instructions/s) ==="
run ms-timer  sh -c "echo '$TIME ms bye'"
run chacha20  cat tests/chacha20.fth
run self-host cat build/muxleq.fth
awk -v o="$TOTAL_OPS" -v t="$TOTAL_T" 'BEGIN {
    printf "  %-11s %15s ops  sum  %8.3fs  %9.1f Mops/s\n", "overall", o, t, o / t / 1e6 }'
