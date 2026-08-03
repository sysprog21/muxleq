#!/bin/sh

# Read the conformance count a prebuilt release stages beside its elfs: one
# line, one positive decimal, nothing else. The producer writes exactly that,
# and repairing anything else would size the suite from a file nobody wrote --
# "1x2" is not 12, and a second line is not a comment. Prints the count, or
# exits nonzero when the file is missing or does not read that way. Shared so
# the prebuilt script and its contract test cannot drift on what a count is.
set -eu

[ "$#" -eq 1 ] || {
    echo "usage: rv32i-count.sh FILE" >&2
    exit 2
}
[ -f "$1" ] || exit 1
LC_ALL=C awk '
    NR == 1 && $0 ~ /^[1-9][0-9]*$/ { value = $0 }
    END {
        if (NR != 1 || value == "")
            exit 1
        print value
    }
' "$1"
