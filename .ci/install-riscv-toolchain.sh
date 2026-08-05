#!/usr/bin/env bash

# Install the xPack GNU RISC-V bare-metal toolchain (riscv-none-elf-), which
# matches the project default RVCROSS prefix, so make check and friends build
# the RV32I programs from source with no RVCROSS override. Adds the toolchain to
# PATH for later CI steps and skips the download when the cache already holds
# the requested version. Bump XPACK_RISCV_VERSION (and XPACK_RISCV_SHA256)
# together to move to a newer release.
set -eu

VERSION="${XPACK_RISCV_VERSION:-15.2.0-1}"
ARCH="${XPACK_RISCV_ARCH:-linux-x64}"
DEST="${XPACK_RISCV_DIR:-$HOME/riscv-none-elf-gcc}"

# SHA-256 of xpack-riscv-none-elf-gcc-15.2.0-1-linux-x64.tar.gz from the xPack
# release notes. Override alongside XPACK_RISCV_VERSION / XPACK_RISCV_ARCH.
SHA256="${XPACK_RISCV_SHA256:-aaaa8060c914851a3e5ee1ba82cc3d6f80972f90638a05c6e823a37557a33758}"
TARBALL="xpack-riscv-none-elf-gcc-${VERSION}-${ARCH}.tar.gz"
URL="https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v${VERSION}/${TARBALL}"

# A restored cache may hold an older toolchain; the version marker forces a
# refresh when the requested version changed, closing the stale-cache gap.
if [ ! -x "$DEST/bin/riscv-none-elf-gcc" ] ||
    [ "$(cat "$DEST/.xpack-version" 2>/dev/null || true)" != "$VERSION" ]; then
    echo "Installing xPack riscv-none-elf-gcc $VERSION"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fL --retry 3 "$URL" -o "$tmp/$TARBALL"

    # Verify the download before trusting the compiler it contains.
    if command -v sha256sum >/dev/null 2>&1; then
        echo "$SHA256  $tmp/$TARBALL" | sha256sum -c -
    elif command -v shasum >/dev/null 2>&1; then
        echo "$SHA256  $tmp/$TARBALL" | shasum -a 256 -c -
    else
        echo "error: no sha256 tool to verify the toolchain download" >&2
        exit 1
    fi

    rm -rf "$DEST"
    mkdir -p "$DEST"
    tar -xzf "$tmp/$TARBALL" -C "$DEST" --strip-components=1
    printf '%s\n' "$VERSION" >"$DEST/.xpack-version"
fi

# Export for subsequent GitHub Actions steps.
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$DEST/bin" >>"$GITHUB_PATH"
fi

"$DEST/bin/riscv-none-elf-gcc" --version | head -1
