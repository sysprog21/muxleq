#!/bin/sh

# Consolidated benchmark suite. Builds and times the VM on a quiet remote host
# (node1 by default) because localhost load makes wall-clock timing unreliable.
# Ships the current sources, runs scripts/bench-remote.sh there, cleans up.
#
#   make bench                 # default: node1, TIME=5000, best of 5
#   BENCH_HOST=node2 make bench
#   TIME=20000 REPS=9 make bench
#   BENCH_CFLAGS='-O3 -std=c99' make bench
set -e
HOST=${BENCH_HOST:-node1}
TIME=${TIME:-5000}
REPS=${REPS:-5}
ENABLE_RV32I=${ENABLE_RV32I:-1}

case $TIME in '' | *[!0-9]* | 0) echo "bench: TIME must be a positive integer" >&2; exit 1 ;; esac
case $REPS in '' | *[!0-9]* | 0) echo "bench: REPS must be a positive integer" >&2; exit 1 ;; esac
case $ENABLE_RV32I in 0 | 1) ;; *) echo "bench: ENABLE_RV32I must be 0 or 1" >&2; exit 1 ;; esac

quote_env_value() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

files="muxleq.c rv32i.inc stage0.c build/muxleq.fth tests/chacha20.fth scripts/bench-remote.sh"
if [ "$ENABLE_RV32I" = 1 ]; then
    files="$files build/rv32i-traces.inc"
fi
for f in $files; do
    [ -f "$f" ] || { echo "bench: missing $f (run 'make' first)" >&2; exit 1; }
done

# Params travel in a sourced env file, never interpolated into the remote
# command line -- so nothing in TIME/REPS/CFLAGS can break out of the ssh shell.
{
    printf "TIME=%s\nREPS=%s\nCFLAGS=" "$TIME" "$REPS"
    quote_env_value "${BENCH_CFLAGS:--O2 -std=c99} -DENABLE_RV32I=$ENABLE_RV32I"
    printf "\n"
    if [ "${CC+x}" ]; then
        printf "CC="
        quote_env_value "$CC"
        printf "\n"
    fi
    if [ "${MUXLEQ_CC+x}" ]; then
        printf "MUXLEQ_CC="
        quote_env_value "$MUXLEQ_CC"
        printf "\n"
    fi
} >bench.env

# Signals route through the EXIT trap so cleanup runs exactly once and the
# script actually aborts (REMOTE is empty until mktemp succeeds).
REMOTE=
cleanup() {
    rm -f bench.env
    [ -n "$REMOTE" ] && ssh "$HOST" "rm -rf \"$REMOTE\"" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

REMOTE=$(ssh "$HOST" 'mktemp -d') || { echo "bench: cannot reach $HOST" >&2; exit 1; }

tar czf - $files bench.env | ssh "$HOST" "tar xzf - --warning=no-unknown-keyword -C \"$REMOTE\""
# $REMOTE comes from mktemp -d, so it is a safe path to interpolate.
ssh "$HOST" "cd \"$REMOTE\" && sh scripts/bench-remote.sh"
