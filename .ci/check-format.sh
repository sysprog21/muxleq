#!/usr/bin/env bash
# Verify the project C sources match clang-format version 20 without modifying
# them. clang-format output is version-sensitive, so a different version is
# rejected even when CLANG_FORMAT is pre-set. Vendored guest programs under
# tests/ are excluded: they follow upstream style, not the project .clang-format.
set -euo pipefail

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

# Enforce version 20 regardless of how CLANG_FORMAT was chosen.
if ! "$CLANG_FORMAT" --version | grep -q 'version 20\.'; then
    echo "Error: $CLANG_FORMAT must be clang-format version 20, got:" >&2
    "$CLANG_FORMAT" --version >&2
    exit 1
fi

ret=0
while IFS= read -r -d '' file; do
    if ! "$CLANG_FORMAT" "$file" |
        diff -u -p --label="$file" --label="expected (clang-format 20)" "$file" -; then
        ret=1
    fi
done < <(git ls-files -z -- '*.c' '*.inc' ':!tests/')

exit $ret
