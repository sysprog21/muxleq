#!/bin/sh
# Runs inside a temp dir on node1.
set -e

ELF=tests/rv32i/duremark/duremark.elf
CFLAGS=${CFLAGS:--O2 -std=c99 -Wall -Wextra}
. ./profile.env
MUXLEQ_CC=${MUXLEQ_CC:-${CC:-$(command -v clang >/dev/null 2>&1 && echo clang || echo cc)}}

case $PERF_REPS in '' | *[!0-9]* | 0)
    echo "profile-duremark: PERF_REPS must be a positive integer" >&2
    exit 1
    ;;
esac

command -v perf >/dev/null 2>&1 || {
    echo "profile-duremark: perf not found on $(hostname)" >&2
    exit 1
}
command -v gforth >/dev/null 2>&1 || {
    echo "profile-duremark: gforth not found on $(hostname)" >&2
    exit 1
}

echo "host: $(hostname)"
echo "generate: gforth build/muxleq.fth > stage0.dec"
gforth build/muxleq.fth >stage0.dec
echo "generate: sed 's/$/,/' stage0.dec > stage0.c"
sed 's/$/,/' stage0.dec >stage0.c
echo "generate: python3 scripts/gen-rv32i-traces.py stage0.dec rv32i-traces.inc.in rv32i-traces.inc"
python3 scripts/gen-rv32i-traces.py stage0.dec rv32i-traces.inc.in rv32i-traces.inc
echo "build: $MUXLEQ_CC $CFLAGS -I. -o muxleq muxleq.c"
$MUXLEQ_CC $CFLAGS -I. -o muxleq muxleq.c
RUN=./muxleq

echo
echo "command: $RUN -s -r $ELF"
$RUN -s -r "$ELF" >duremark-s.out 2>duremark-s.err
cat duremark-s.out
cat duremark-s.err
grep -q 'DureMark checksum 4147801864' duremark-s.out
grep -q 'dispatched instructions:' duremark-s.err

echo
echo "command: $RUN -p -r $ELF"
$RUN -p -r "$ELF" >duremark-p.out 2>duremark-p.err
cat duremark-p.out
cat duremark-p.err
grep -q 'DureMark checksum 4147801864' duremark-p.out
grep -q 'hot PCs' duremark-p.err

echo
i=1
while [ "$i" -le "$PERF_REPS" ]; do
    echo "command[$i/$PERF_REPS]: perf stat -e cycles,instructions,branches,branch-misses,cache-references,cache-misses $RUN -r $ELF"
    perf stat -e cycles,instructions,branches,branch-misses,cache-references,cache-misses \
        $RUN -r "$ELF" >duremark-perf.out 2>duremark-perf.err
    cat duremark-perf.out
    cat duremark-perf.err
    grep -q 'DureMark checksum 4147801864' duremark-perf.out
    i=$((i + 1))
done
