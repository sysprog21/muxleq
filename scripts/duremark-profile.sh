#!/bin/sh

# Build and profile DureMark on node1 only. This wrapper ships just the files
# needed by scripts/duremark-profile-remote.sh; it never builds or runs locally.
set -e

HOST=node1
PERF_REPS=${PERF_REPS:-3}

case $PERF_REPS in '' | *[!0-9]* | 0)
    echo "profile-duremark: PERF_REPS must be a positive integer" >&2
    exit 1
    ;;
esac

quote_env_value() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

files="muxleq.c rv32i.inc rv32i-traces.inc.in scripts/gen-rv32i-traces.py build/muxleq.fth tests/rv32i/duremark/duremark.elf scripts/duremark-profile-remote.sh"

for f in $files; do
    [ -e "$f" ] || { echo "profile-duremark: missing $f" >&2; exit 1; }
done

{
    printf "PERF_REPS=%s\n" "$PERF_REPS"
    if [ "${CFLAGS+x}" ]; then
        printf "CFLAGS="
        quote_env_value "$CFLAGS"
        printf "\n"
    fi
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
} >profile.env

REMOTE=
cleanup() {
    rm -f profile.env
    [ -n "$REMOTE" ] && ssh "$HOST" "rm -rf \"$REMOTE\"" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

REMOTE=$(ssh "$HOST" 'mktemp -d') || { echo "profile-duremark: cannot reach $HOST" >&2; exit 1; }
COPYFILE_DISABLE=1 tar --no-xattrs -czf - $files profile.env | ssh "$HOST" "tar xzf - -C \"$REMOTE\""
ssh "$HOST" "cd \"$REMOTE\" && sh scripts/duremark-profile-remote.sh"
