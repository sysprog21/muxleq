#!/bin/sh

# Canonical content manifest for the rolling RV32I pre-release. The tarball's
# outer checksum shows the download arrived intact; this shows the extracted
# payload is the exact file set the producer staged. Neither is authentication.
#
#   rv32i-manifest.sh create ROOT   write ROOT/MANIFEST.sha256
#   rv32i-manifest.sh verify ROOT   compare ROOT against its own manifest
#
# A line is "<sha256><two spaces><path>", the path relative to ROOT, the file
# LC_ALL=C sorted and newline terminated, never listing the manifest itself.
# verify re-renders that text from the tree on disk and compares byte for byte,
# so a missing file, an extra one, a reordered or duplicated line and a stale
# digest all fail alike -- "sha256sum -c" would pass an extra file, since it
# only checks what the manifest already names.
set -eu

MANIFEST=MANIFEST.sha256

# "./$1" so a name starting with "-" stays a path rather than an option, and no
# pipe, so a failed hash is a failed sha_of: read through awk the failure is the
# pipeline's last command instead, and the file lands in the manifest with a
# blank digest that verify then reproduces, hiding every later edit to it.
if command -v sha256sum >/dev/null 2>&1; then
    sha_of() { _line=$(sha256sum "./$1") && printf '%s\n' "${_line%% *}"; }
elif command -v shasum >/dev/null 2>&1; then
    sha_of() { _line=$(shasum -a 256 "./$1") && printf '%s\n' "${_line%% *}"; }
else
    echo "rv32i-manifest: no SHA-256 tool" >&2
    exit 1
fi

# Write the canonical manifest for $1 to stdout. Nonzero if the tree holds
# anything that cannot appear in a payload, so a bad tree fails here rather than
# rendering a manifest that describes it.
render() {
    (
        cd "$1" || exit 1
        # A symlink, hardlink target outside the tree, device or fifo is not
        # payload; following one would also hash bytes from outside ROOT.
        if find . ! -type d ! -type f -print | read -r _; then
            echo "rv32i-manifest: non-regular member in $1" >&2
            exit 1
        fi
        # -print emits one line per file unless a name holds a newline, -exec
        # exactly one; a mismatch means a name would split across the lines every
        # step below reads, so refuse rather than hash the halves.
        if [ "$(find . -type f -print | wc -l)" \
            != "$(find . -type f -exec printf 'x\n' \; | wc -l)" ]; then
            echo "rv32i-manifest: newline in a member name in $1" >&2
            exit 1
        fi
        find . -type f -print | LC_ALL=C sort | while IFS= read -r p; do
            p=${p#./}
            case "$p" in
            "$MANIFEST") continue ;;
            # A backslash would make the hashers escape their output line, so the
            # digest would not start the line; payload names never need one.
            '' | /* | .. | ../* | */.. | */../* | *\\*)
                printf 'rv32i-manifest: unsafe path %s\n' "$p" >&2
                exit 1
                ;;
            esac
            h=$(sha_of "$p") || {
                printf 'rv32i-manifest: cannot hash %s\n' "$p" >&2
                exit 1
            }
            printf '%s  %s\n' "$h" "$p"
        done
    )
}

[ "$#" -eq 2 ] || {
    echo "usage: rv32i-manifest.sh create|verify ROOT" >&2
    exit 2
}
mode=$1
root=$2
[ -d "$root" ] || {
    echo "rv32i-manifest: not a directory: $root" >&2
    exit 1
}

# Outside ROOT: a scratch file inside it would be found by render and listed as
# payload.
tmp="$(mktemp)" || exit 1
trap 'rm -f "$tmp"' EXIT

case "$mode" in
create)
    render "$root" >"$tmp"
    mv "$tmp" "$root/$MANIFEST"
    ;;
verify)
    [ -f "$root/$MANIFEST" ] || {
        echo "rv32i-manifest: no $MANIFEST in $root" >&2
        exit 1
    }
    render "$root" >"$tmp"
    cmp -s "$tmp" "$root/$MANIFEST"
    ;;
*)
    echo "usage: rv32i-manifest.sh create|verify ROOT" >&2
    exit 2
    ;;
esac
