#!/usr/bin/env bash

# Verify project sources are formatted, without modifying any file:
#   C / .inc  clang-format 20  (output is version-sensitive, so 20 is enforced)
#   Python    black --check
#   shell     shfmt            (indent width comes from .editorconfig)
#   Forth     scripts/forth-indent.py (the in-repo formatter)
# Vendored guest code under tests/ and externals/ follows upstream style, not
# the project's, so it is excluded (except Forth: the project lints tests/*.fth
# too, matching the Makefile's FORTH_SRC). Formatter versions are enforced
# because output drifts between them. black and shfmt are checked to the EXACT
# release CI pins (pipx black==X, shfmt by content hash) so local == CI;
# clang-format is checked to major 20 only, since CI installs it from apt where
# the 20.x patch floats and no exact pin would match across environments.
set -euo pipefail

ret=0

# Collect NUL-delimited, git-tracked paths matching the pathspecs into the array
# `files` (empty if none). Avoids xargs' "run once on empty input" wart and
# works under bash 3.2 (macOS) where `mapfile -d` is unavailable.
collect() {
    files=()
    while IFS= read -r -d '' f; do
        [ -e "$f" ] && files+=("$f")
    done < <(git ls-files -z -- "$@")
}

# Require formatter $1 (used for $2) on PATH and its --version to match the
# extended-regex pinned-version pattern $3; $4 is the human pin shown on a
# version miss. Exits on either. clang-format is checked below (it auto-detects
# the name).
require_fmt() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: $1 is required for $2" >&2
        exit 1
    }
    "$1" --version | grep -qE "$3" || {
        echo "Error: $1 must be $4, got: $("$1" --version)" >&2
        exit 1
    }
}

# C (clang-format, pinned to 20)
if [ -z "${CLANG_FORMAT:-}" ]; then
    if command -v clang-format-20 >/dev/null 2>&1; then
        CLANG_FORMAT=clang-format-20
    elif command -v clang-format >/dev/null 2>&1; then
        CLANG_FORMAT=clang-format
    else
        echo "Error: clang-format version 20 is required" >&2
        exit 1
    fi
fi
if ! "$CLANG_FORMAT" --version | grep -q 'version 20\.'; then
    echo "Error: $CLANG_FORMAT must be clang-format version 20, got:" >&2
    "$CLANG_FORMAT" --version >&2
    exit 1
fi
collect '*.c' '*.inc' ':!tests/'
if [ ${#files[@]} -gt 0 ]; then
    for file in "${files[@]}"; do
        if ! "$CLANG_FORMAT" "$file" |
            diff -u -p --label="$file" --label="expected (clang-format 20)" "$file" -; then
            ret=1
        fi
    done
fi

# Python (black)
require_fmt black "Python formatting" 'black, 26\.5\.1([^0-9]|$)' "version 26.5.1 (the exact release CI pins)"
collect '*.py' ':!tests/' ':!externals/'
if [ ${#files[@]} -gt 0 ]; then
    black --check --diff -- "${files[@]}" || ret=1
fi

# shell (shfmt reads indent width from .editorconfig)
require_fmt shfmt "shell formatting" '^v?3\.13\.1([^0-9]|$)' "version 3.13.1 (the exact release CI pins)"
collect '*.sh' ':!tests/' ':!externals/'
if [ ${#files[@]} -gt 0 ]; then
    shfmt -d -- "${files[@]}" || ret=1
fi

# Forth (in-repo formatter; also covers tests/*.fth, like the Makefile)
collect '*.fth' ':!externals/'
if [ ${#files[@]} -gt 0 ]; then
    python3 scripts/forth-indent.py "${files[@]}" || ret=1
fi

exit $ret
