#!/bin/sh
set -e

out=$1
shift

case $out in
    '') echo "usage: update-muxleq-fth.sh OUT MODULE..." >&2; exit 1 ;;
esac
if [ "$#" -eq 0 ]; then
    echo "update-muxleq-fth.sh: no modules given" >&2
    exit 1
fi

tmp=$(mktemp "${TMPDIR:-/tmp}/muxleq.fth.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM

for f do
    sed -n '1,$p' "$f" >>"$tmp"
done

if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
    exit 0
fi

mv "$tmp" "$out"
trap - EXIT HUP INT TERM
