#!/usr/bin/env bash
# Every tracked project source must end with a trailing newline (.editorconfig's
# insert_final_newline). clang-format does not enforce this and forth-indent.py
# does not check it, so C/.inc and Forth are covered here; black/shfmt already
# enforce it for Python/shell. Vendored guest programs are excluded: tests/ for C,
# externals/ for Forth (the project lints tests/*.fth, so Forth keeps tests/).
set -eu

ret=0
check() {
    while IFS= read -r -d '' f; do
        if [ -n "$(tail -c1 <"$f")" ]; then
            echo "Error: no newline at end of file: $f" >&2
            ret=1
        fi
    done < <(git ls-files -z -- "$@")
}

check '*.c' '*.inc' ':!tests/'
check '*.fth' ':!externals/'

exit $ret
