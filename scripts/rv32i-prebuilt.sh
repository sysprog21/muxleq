#!/bin/sh

# Run the RV32I test coverage from prebuilt binaries when no RISC-V toolchain is
# installed. The lowering (rvopt) and the VM (muxleq) build from C with no cross
# toolchain, so the toolchain is only ever needed to produce the .elf inputs.
# This fetches those .elf inputs from the rolling "rv32i-latest" pre-release and
# runs the same rvopt-mux + muxleq gate the toolchain path runs locally.
#
# Exit 0 conformance ran and all passed; 1 a real lowering/run failure or a
# structurally malicious archive; 77 skip. Skip covers every transient or
# infrastructure condition (no network, no sha tool, torn/corrupt download,
# empty/demos-only release), so those never redden the gate; the authoritative
# RV32I gate is the toolchain CI job that builds from source. The caller maps 77
# to SKIP so an offline machine without the toolchain is not blocked.
set -eu

RVOPT="${RVOPT:?RVOPT must point at the built rvopt}"
MUXLEQ="${MUXLEQ:?MUXLEQ must point at the built muxleq}"

# rv32i-count.sh ships beside this script; resolve it from here so the caller's
# working directory does not matter.
here="$(CDPATH= cd "$(dirname "$0")" && pwd)"

# sysprog21/muxleq publishes the rolling pre-release; override REPO to test a
# fork.
REPO="${REPO:-sysprog21/muxleq}"
TAG="${RV32I_PREBUILT_TAG:-rv32i-latest}"
BASE="https://github.com/$REPO/releases/download/$TAG"
TIMEOUT="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
RUN_TIMEOUT="${RUN_TIMEOUT:-60}"

if ! command -v curl >/dev/null 2>&1; then
    echo "rv32i-prebuilt: no curl to fetch prebuilt binaries [SKIP]"
    exit 77
fi

if ! work="$(mktemp -d)"; then
    echo "rv32i-prebuilt: mktemp failed, no scratch space [SKIP]"
    exit 77
fi
trap 'rm -rf "$work"' EXIT
tgz="$work/rv32i-binaries.tar.gz"

# --max-time bounds a stalled transfer so a hung CDN degrades to the skip path
# below instead of hanging the whole make-check gate (--retry only re-attempts
# curl-detected errors, not a live-but-stalled read).
CURL="curl -fsSL --connect-timeout 10 --max-time 120 --retry 2"

sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    fi
}
if [ -z "$(command -v sha256sum || command -v shasum || true)" ]; then
    echo "rv32i-prebuilt: no sha256 tool to verify download [SKIP]"
    exit 77
fi

# Fetch the tarball and its checksum, retrying once. The producer republishes by
# delete+recreate, so a consumer that overlaps a republish can read a tarball
# and a checksum from different generations: a torn read, not corruption. One
# retry re-reads a settled pair; a mismatch that survives it is treated as a
# transient/broken release and skipped (77), not a hard gate failure (the
# authoritative RV32I gate is the toolchain CI job, which builds from source).
verified=false
tries=0
while [ "$tries" -lt 2 ]; do
    tries=$((tries + 1))
    if ! $CURL "$BASE/rv32i-binaries.tar.gz" -o "$tgz"; then
        echo "rv32i-prebuilt: could not download $BASE/rv32i-binaries.tar.gz [SKIP]"
        exit 77
    fi
    if ! $CURL "$BASE/rv32i-binaries.tar.gz.sha256" -o "$work/sum"; then
        echo "rv32i-prebuilt: no checksum asset published [SKIP]"
        exit 77
    fi
    want="$(awk '{ print $1 }' "$work/sum")"
    got="$(sha_of "$tgz")"
    if [ -n "$want" ] && [ "$want" = "$got" ]; then
        verified=true
        break
    fi
done
if [ "$verified" != true ]; then
    echo "rv32i-prebuilt: checksum mismatch after retry (want '$want' got '$got') -- transient or broken release [SKIP]" >&2
    exit 77
fi

# An empty archive is a broken/partial publish, not tampering: skip (77), don't
# fall through to the member-path check where a blank line would look
# "unexpected". A tar that cannot even be listed is a corrupt/broken publish
# (its checksum can still match if the producer hashed the broken bytes). Under
# set -e the bare assignment would abort with tar's status and the Makefile
# would turn that into a hard failure; the contract says a broken release skips,
# so catch it.
if ! members="$(tar -tzf "$tgz" 2>/dev/null)"; then
    echo "rv32i-prebuilt: malformed archive -- cannot list [SKIP]"
    exit 77
fi
if [ -z "$members" ]; then
    echo "rv32i-prebuilt: empty archive -- nothing runnable [SKIP]"
    exit 77
fi

# Validate members before extracting: the archive is untrusted input (the
# checksum proves it arrived intact, not that a compromised release is benign).
# Reject absolute paths, "..", anything outside the "rv32i/" prefix, and any
# symlink/hardlink member: a link could redirect a later member's write outside
# the temp dir even though its own name looks in-bounds. A structurally
# malicious archive is a loud refusal (exit 1), distinct from the transient
# skips above.
if printf '%s\n' "$members" | grep -qvE '^rv32i/' ||
    printf '%s\n' "$members" | grep -qE '(^|/)\.\.(/|$)'; then
    echo "rv32i-prebuilt: archive has unexpected member paths -- refusing to extract" >&2
    exit 1
fi

# LC_ALL=C so the "link to" hardlink marker is not translated out from under the
# grep in a non-English locale ("->" for symlinks is locale-stable).
if LC_ALL=C tar -tvzf "$tgz" | grep -qE ' -> | link to '; then
    echo "rv32i-prebuilt: archive contains link members -- refusing to extract" >&2
    exit 1
fi
if ! tar -xzf "$tgz" -C "$work" 2>/dev/null; then
    echo "rv32i-prebuilt: malformed archive -- cannot extract [SKIP]"
    exit 77
fi
root="$work/rv32i"

# One visible warning if no timeout tool bounds the VM runs (stock macOS has
# neither timeout nor gtimeout): a lowered ELF that loops would otherwise hang
# make check with no hint why.
if [ -z "$TIMEOUT" ]; then
    echo "rv32i-prebuilt: no timeout(1)/gtimeout -- VM runs are unbounded" >&2
fi

# Bound each VM run so a program lowered into an infinite loop fails fast
# instead of hanging the gate; unbounded when no timeout tool exists, as
# elsewhere.
run_vm() {
    if [ -n "$TIMEOUT" ]; then
        "$TIMEOUT" "$RUN_TIMEOUT" "$MUXLEQ" "$@"
    else
        "$MUXLEQ" "$@"
    fi
}

fail=0
ran=0
conformance=0

# rv32ui conformance: each self-checks by printing exactly "PASS\n". Present
# only once the release is built from a tree that stages these elfs; absent
# otherwise.
if [ -d "$root/riscv-tests" ]; then
    for elf in "$root"/riscv-tests/*.elf; do
        [ -f "$elf" ] || continue # no match -> the literal glob; skip it
        name="$(basename "$elf" .elf)"
        ran=$((ran + 1))
        conformance=$((conformance + 1))

        # Truncate the output up front so a diagnostic never reports a prior
        # test's bytes when rvopt/the VM fails before writing anything.
        : >"$work/t.out"
        if "$RVOPT" mux "$elf" >"$work/t.dec" 2>/dev/null &&
            run_vm "$work/t.dec" >"$work/t.out" 2>/dev/null &&
            printf 'PASS\n' | cmp -s - "$work/t.out"; then
            :
        else
            echo "  FAIL(mux): rv32ui-$name (got '$(tr -d '\n' <"$work/t.out")')"
            fail=1
        fi
    done
fi
if [ "$conformance" -gt 0 ]; then
    echo "rv32i-prebuilt: rv32ui conformance ($conformance tests)"
fi

# Demos + the -O0 unopt build self-validate by running to a clean exit, matching
# the toolchain "run" targets (which assert exit status, not output bytes).
for elf in "$root"/demos/*.elf "$root"/demos/hello.bin "$root"/unopt/unopt.elf; do
    [ -f "$elf" ] || continue
    ran=$((ran + 1))
    if "$RVOPT" mux "$elf" >"$work/t.dec" 2>/dev/null && run_vm "$work/t.dec" >/dev/null 2>&1; then
        :
    else
        echo "  FAIL(mux): $(basename "$elf") did not lower+run to a clean exit"
        fail=1
    fi
done

if [ "$ran" -eq 0 ]; then
    echo "rv32i-prebuilt: release carries no runnable RV32I binaries [SKIP]"
    exit 77
fi

# A real lowering/run failure fails the gate. But a demos-only release (no
# conformance elfs) is weaker coverage than the source path guarantees, so
# report it as a skip rather than a green pass that falsely implies the full
# rv32ui suite ran; a regressed instruction would otherwise ship undetected.
if [ "$fail" -ne 0 ]; then
    exit 1
fi
if [ "$conformance" -eq 0 ]; then
    echo "rv32i-prebuilt: $ran demos ran, but release has no rv32ui conformance elfs [SKIP]"
    exit 77
fi

# A real lowering/run failure (above) takes precedence: only a release that ran
# cleanly but carries fewer conformance elfs than it declares (count.txt, staged
# next to them) is a truncated release: skip, do not pass green on reduced
# coverage. count.txt is the only thing that sizes the suite, so it is required
# once conformance elfs are present; rv32i-count.sh is the single place that
# decides what reading it means, and comparing as strings keeps a value too wide
# for a shell integer out of test(1) arithmetic.
count_file="$root/riscv-tests/count.txt"
if [ ! -f "$count_file" ]; then
    echo "rv32i-prebuilt: release has no conformance count [SKIP]"
    exit 77
fi
if ! expected="$("$here/rv32i-count.sh" "$count_file")"; then
    echo "rv32i-prebuilt: invalid conformance count [SKIP]"
    exit 77
fi
if [ "$conformance" != "$expected" ]; then
    echo "rv32i-prebuilt: ran $conformance of $expected conformance tests, truncated release [SKIP]"
    exit 77
fi
echo "rv32i-prebuilt: $ran prebuilt RV32I programs lowered native + ran ($conformance rv32ui)"
