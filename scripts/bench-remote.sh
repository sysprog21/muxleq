#!/bin/sh
# Runs on the benchmark host (node1) inside a temp dir populated by bench.sh.
# Builds the VM from the shipped sources and times a fixed, representative,
# deterministic workload set. Reports best-of-REPS user time per workload plus
# the deterministic dispatch count for the heaviest one (the self-host).
#
# Fails loudly on any build/run error or missing timing: a benchmark that
# silently reports a bogus 0s is worse than one that stops.
set -e
. ./bench.env # TIME, REPS, CFLAGS

command -v /usr/bin/time >/dev/null 2>&1 || {
    echo "bench: /usr/bin/time not found (install the 'time' package)" >&2
    exit 1
}

cc $CFLAGS -o muxleq muxleq.c

# run NAME then a command whose stdout is fed to the VM; keep the fastest user
# time. set -e aborts if the generator or the VM exits non-zero; the timing
# check aborts if /usr/bin/time produced no 'user' line.
run() {
    name=$1
    shift
    "$@" >input.tmp
    best=
    i=0
    while [ "$i" -lt "$REPS" ]; do
        /usr/bin/time -p ./muxleq <input.tmp >/dev/null 2>time.tmp
        t=$(awk '/^user/ { print $2 }' time.tmp)
        [ -n "$t" ] || { echo "bench: $name produced no timing" >&2; exit 1; }
        best=$(awk -v a="$t" -v b="${best:-99999}" 'BEGIN { print (a < b) ? a : b }')
        i=$((i + 1))
    done
    printf '  %-12s best user %ss\n' "$name" "$best"
}

echo "=== muxleq bench on $(hostname), best of $REPS ==="
run ms-timer  sh -c "echo '$TIME ms bye'"
run chacha20  cat tests/chacha20.fth
run self-host cat muxleq.fth

# Deterministic instruction count (unaffected by machine load).
./muxleq -s <muxleq.fth >/dev/null 2>stats.txt
d=$(awk '/dispatched/ { print }' stats.txt)
[ -n "$d" ] || { echo "bench: self-host -s produced no count" >&2; exit 1; }
printf '  %-12s %s\n' self-host "$d"
