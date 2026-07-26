#!/bin/sh
set -e

out=$1
shift

case $out in
'')
    echo "usage: update-muxleq-fth.sh OUT MODULE..." >&2
    exit 1
    ;;
esac
if [ "$#" -eq 0 ]; then
    echo "update-muxleq-fth.sh: no modules given" >&2
    exit 1
fi

tmp=$(mktemp "${TMPDIR:-/tmp}/muxleq.fth.XXXXXX")
trap 'rm -f "$tmp" "$tmp.rv"' EXIT HUP INT TERM

for f; do
    sed -n '1,$p' "$f" >>"$tmp"
done

# The image is self-hosting: both `gforth muxleq.fth` and `./muxleq < muxleq.fth`
# read this one file, so the RV32I switch has to live in the text itself (an
# `-e` preamble would reach gforth but not the self-host path, desyncing the
# bootstrap). Stamp opt.rv32i to the build's ENABLE_RV32I in both directions so
# the make flag, not the forth/ source default, is authoritative; then assert the
# stamp fired. sed is silent on a no-match, so a reformatted config line would
# otherwise ship the wrong image (RV32I microcode in an ENABLE_RV32I=0 build) with
# no gate to catch it. Fail loudly here instead.
rv=${ENABLE_RV32I:-1}
case $rv in
0 | 1) ;;
*)
    echo "update-muxleq-fth.sh: ENABLE_RV32I must be 0 or 1, got '$rv'" >&2
    exit 1
    ;;
esac
sed "s/^ *[01]  *constant  *opt\.rv32i/$rv constant opt.rv32i/" "$tmp" >"$tmp.rv"
mv "$tmp.rv" "$tmp"
grep -q "^$rv constant opt\.rv32i" "$tmp" || {
    echo "update-muxleq-fth.sh: failed to stamp opt.rv32i=$rv (config line format changed?)" >&2
    exit 1
}

if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
    exit 0
fi

mv "$tmp" "$out"
trap - EXIT HUP INT TERM
