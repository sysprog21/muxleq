#!/usr/bin/env bash

# Install the pinned Emscripten SDK, for the WebAssembly build of the browser
# tutorial (make wasm / make check-wasm). Idempotent: a restored cache holding
# the pinned revision is left alone, so a cache hit costs nothing.
#
# Trust model, and it matches install-riscv-toolchain.sh rather than diverging
# from it: that script verifies a tarball against a pinned SHA-256 before
# running anything out of it, and this one verifies a git checkout against a
# pinned commit before running anything out of it. A tag is a mutable pointer,
# so checking out "6.0.5" and trusting it would let a retag silently swap the
# compiler CI runs; the tag is only a hint for the shallow fetch, and
# EMSDK_COMMIT is the thing actually enforced. Bump the two together.
set -eu

VERSION="${EMSDK_VERSION:-6.0.5}"
# Commit that tag 6.0.5 pointed at when it was pinned.
COMMIT="${EMSDK_COMMIT:-dfb9d1a46c3bb8f52e1e6324be23123b9d73c190}"
DEST="${EMSDK_DIR:-$HOME/emsdk}"
REPO_URL="${EMSDK_REPO:-https://github.com/emscripten-core/emsdk.git}"

# The marker records the commit, not just the version, so a cache holding a
# different revision under the same version string is refreshed rather than
# trusted. The Actions cache key hashes this script, so editing either pin above
# also busts the cache; the marker covers the case where it does not.
marker="$DEST/.emsdk-commit"

# The marker alone is not evidence: it is a file inside the cached tree, so a
# tree that is stale or tampered with carries whatever marker it likes. On a
# cache hit re-check the actual checkout, because this script ends by running
# emcc out of that tree and CI then runs it for real. Only a tree with no .git
# at all is taken on the marker's word, and that one cannot be re-checked.
cached_ok=false
if [ -x "$DEST/upstream/emscripten/emcc" ] &&
    [ "$(cat "$marker" 2>/dev/null || true)" = "$COMMIT" ]; then
    if git -C "$DEST" rev-parse --git-dir >/dev/null 2>&1; then
        [ "$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)" = "$COMMIT" ] &&
            cached_ok=true
    fi
fi

if [ "$cached_ok" = true ]; then
    echo "emsdk $VERSION ($COMMIT) already installed in $DEST"
else
    echo "Installing emsdk $VERSION ($COMMIT) into $DEST"

    # Reuse the clone only if it is actually a working repository. A restored
    # cache can be truncated or half-written, and testing for .git alone would
    # then send us down the fetch path to fail with a git error that says
    # nothing about the real problem. Anything unusable is thrown away and
    # re-cloned, so a bad cache heals instead of wedging the job.
    # Try to reuse the cached clone by fetching the pinned commit itself rather
    # than the tag: a non-forced tag fetch refuses to clobber an existing local
    # tag, so a moved tag used to die here on a raw git error. Any failure at
    # all, including a commit that does not exist because the pin was bumped
    # wrongly, falls through to a fresh clone, so the run ends at the explicit
    # check below with a message naming both SHAs instead of at git's exit 128.
    reused=false
    if [ -d "$DEST/.git" ] && git -C "$DEST" rev-parse --git-dir >/dev/null 2>&1; then
        if git -C "$DEST" fetch --depth 1 origin "$COMMIT" >/dev/null 2>&1 &&
            git -C "$DEST" checkout -q "$COMMIT" 2>/dev/null; then
            reused=true
        fi
    fi
    if [ "$reused" = false ]; then
        rm -rf "$DEST"

        # Shallow clone of the tag carrying this release. --branch takes a tag
        # as well as a branch name; what it resolved to is checked below.
        git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$DEST"
    fi

    # Enforce the pin before emsdk's own scripts run: past this point they
    # execute and download a compiler, so this is the last place a substituted
    # revision can be refused rather than merely reported. Not an absolute
    # barrier, and worth being honest about: the git commands above already
    # honour a restored .git/config and .git/hooks, so a cache an attacker could
    # write is not fully contained by a check that runs after them. Actions
    # caches are branch-scoped, which is what actually bounds that.
    got="$(git -C "$DEST" rev-parse HEAD)"
    if [ "$got" != "$COMMIT" ]; then
        echo "error: emsdk tag $VERSION resolves to $got, expected $COMMIT" >&2
        echo "       the tag moved, or EMSDK_VERSION was bumped without EMSDK_COMMIT" >&2
        exit 1
    fi
    echo "emsdk revision verified: $got"

    # install downloads and unpacks the toolchain; activate writes .emscripten
    # so emcc can find clang and node without emsdk_env.sh guessing.
    "$DEST/emsdk" install "$VERSION"
    "$DEST/emsdk" activate "$VERSION"
    echo "$COMMIT" >"$marker"
fi

# The caller still has to source emsdk_env.sh; print where it is rather than
# assume the caller knows the layout.
echo "emsdk_env: $DEST/emsdk_env.sh"
"$DEST/upstream/emscripten/emcc" --version | head -1
