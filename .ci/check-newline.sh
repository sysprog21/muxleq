#!/usr/bin/env bash
# Every tracked project C source must end with a trailing newline. Vendored
# guest programs under tests/ are excluded.
set -eu

ret=0
while IFS= read -r -d '' f; do
    if [ -n "$(tail -c1 <"$f")" ]; then
        echo "Error: no newline at end of file: $f" >&2
        ret=1
    fi
done < <(git ls-files -z -- '*.c' '*.inc' ':!tests/')

exit $ret
