#!/bin/sh

# Offline contract test for scripts/rv32i-prebuilt.sh. Drives the script with a
# mock curl serving crafted release tarballs and asserts its 0/1/77 exit
# contract, which no other gate exercises: the toolchain CI job builds from
# source and the live release is often demos-only, so the transient-skip and
# malicious-archive branches run nowhere else.
#
# The skip (77) and refuse (1) cases exit before any lowering, so they need no
# RISC-V toolchain, no network, and only a placeholder rvopt/muxleq. The pass
# (0) cases lower real elfs, so they run only when a built rvopt/muxleq and a
# populated build/rv32i tree are present (e.g. after rv32i-check). Malicious
# archives are crafted with python3 when available. A final network-gated case
# runs the script against the REAL published release (real curl, real assets) to
# validate the URL, asset names, and format that the mock cannot check.
set -eu

here="$(CDPATH= cd "$(dirname "$0")" && pwd)"
root="$(CDPATH= cd "$here/.." && pwd)"
script="$root/scripts/rv32i-prebuilt.sh"

sha_tool() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        shasum -a 256 "$1" | awk '{ print $1 }'
    fi
}
if [ -z "$(command -v sha256sum || command -v shasum || true)" ]; then
    echo "rv32i-prebuilt-test: no sha256 tool [SKIP]"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fix="$work/fix"
bin="$work/bin"
mkdir -p "$fix" "$bin"

# Mock curl: honors -o <file>, serves $FIXDIR/$SCENARIO.{tgz,sha}. The dlfail
# and nosha scenarios fail the matching fetch (exit 22) to exercise those skips.
cat >"$bin/curl" <<'EOF'
#!/bin/sh
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o)
        shift
        out="$1"
        ;;
    http*) url="$1" ;;
    esac
    shift
done
case "$url" in
*.sha256)
    [ "$SCENARIO" = nosha ] && exit 22
    cp "$FIXDIR/$SCENARIO.sha" "$out"
    ;;
*.tar.gz)
    [ "$SCENARIO" = dlfail ] && exit 22
    [ -n "${DLCOUNT:-}" ] && echo x >>"$DLCOUNT"
    cp "$FIXDIR/$SCENARIO.tgz" "$out"
    ;;
esac
EOF
chmod +x "$bin/curl"

# A valid tarball whose checksum we deliberately break (mismatch) or whose sha
# fetch we fail (nosha). Content is irrelevant: both exit before extraction.
mkdir -p "$work/tiny/rv32i/demos"
: >"$work/tiny/rv32i/demos/x.elf"
tar -czf "$fix/mismatch.tgz" -C "$work/tiny" rv32i
cp "$fix/mismatch.tgz" "$fix/nosha.tgz"
echo "0000000000000000000000000000000000000000000000000000000000000000" >"$fix/mismatch.sha"
: >"$fix/nosha.sha"

# Empty archive with a correct checksum: passes verification, then the empty
# guard skips it (a blank member line would otherwise look "unexpected"). A tar
# EOF is two zero blocks; build it directly, since GNU tar refuses to create an
# archive from an empty member list ("cowardly refusing"), unlike bsd tar.
dd if=/dev/zero bs=512 count=2 2>/dev/null | gzip -c >"$fix/empty.tgz"
sha_tool "$fix/empty.tgz" >"$fix/empty.sha"

have_py=0
if command -v python3 >/dev/null 2>&1; then
    python3 - "$fix" <<'PY'
import sys, tarfile, io
fix = sys.argv[1]
def reg(t, n, d=b"x"):
    ti = tarfile.TarInfo(n); ti.size = len(d); t.addfile(ti, io.BytesIO(d))
# A symlink member whose own name is in-bounds but redirects out of tree.
with tarfile.open(fix + "/symlink.tgz", "w:gz") as t:
    reg(t, "rv32i/demos/a.elf")
    ti = tarfile.TarInfo("rv32i/x"); ti.type = tarfile.SYMTYPE
    ti.linkname = "/etc/passwd"; t.addfile(ti)
# An absolute-path member outside the rv32i/ prefix.
with tarfile.open(fix + "/badpath.tgz", "w:gz") as t:
    reg(t, "rv32i/ok"); reg(t, "/etc/evil")
PY
    sha_tool "$fix/symlink.tgz" >"$fix/symlink.sha"
    sha_tool "$fix/badpath.tgz" >"$fix/badpath.sha"
    have_py=1
fi

# Pass cases need real elfs and a real rvopt/muxleq; run them only when present.
RVOPT_BIN="${RVOPT:-$root/build/rvopt}"
MUXLEQ_BIN="${MUXLEQ:-$root/build/muxleq}"
have_elfs=0
have_trunc=0
if [ -d "$root/build/rv32i/riscv-tests" ] && [ -x "$RVOPT_BIN" ] && [ -x "$MUXLEQ_BIN" ]; then
    tar -czf "$fix/full.tgz" -C "$root/build" rv32i
    sha_tool "$fix/full.tgz" >"$fix/full.sha"
    d="$work/demosonly"
    mkdir -p "$d"
    cp -R "$root/build/rv32i" "$d/"
    rm -rf "$d/rv32i/riscv-tests"
    tar -czf "$fix/demos.tgz" -C "$d" rv32i
    sha_tool "$fix/demos.tgz" >"$fix/demos.sha"
    have_elfs=1

    # Truncated release: keep count.txt (claims the full suite) but drop all but
    # one conformance elf, so the consumer must reject it rather than pass
    # green.
    if [ -f "$root/build/rv32i/riscv-tests/count.txt" ]; then
        t="$work/trunc"
        mkdir -p "$t"
        cp -R "$root/build/rv32i" "$t/"
        one="$(ls "$t"/rv32i/riscv-tests/*.elf | head -1)"
        find "$t/rv32i/riscv-tests" -name '*.elf' ! -path "$one" -delete
        tar -czf "$fix/trunc.tgz" -C "$t" rv32i
        sha_tool "$fix/trunc.tgz" >"$fix/trunc.sha"
        have_trunc=1
    fi
fi

pass=0
failn=0
assert() { # scenario expected_rc
    rc=0
    env PATH="$bin:$PATH" FIXDIR="$fix" SCENARIO="$1" \
        RVOPT="${RVOPT_BIN}" MUXLEQ="${MUXLEQ_BIN}" \
        sh "$script" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = "$2" ]; then
        pass=$((pass + 1))
        printf '  ok    %-9s exit %s\n' "$1" "$rc"
    else
        failn=$((failn + 1))
        printf '  FAIL  %-9s exit %s (want %s)\n' "$1" "$rc" "$2"
    fi
}

# For skip/refuse cases rvopt/muxleq are never invoked; a placeholder is fine.
[ -x "$RVOPT_BIN" ] || RVOPT_BIN=/usr/bin/true
[ -x "$MUXLEQ_BIN" ] || MUXLEQ_BIN=/usr/bin/true

assert mismatch 77 # checksum mismatch survives the retry -> skip
assert empty 77    # empty archive -> skip
assert dlfail 77   # tarball download fails -> skip
assert nosha 77    # checksum asset missing -> skip

# The mismatch exit alone does not prove the retry ran: a collapsed loop would
# also reach 77. Assert the tarball was fetched twice (one retry) so a regressed
# retry loop is caught, not silently accepted.
: >"$work/dl"
rc=0
env PATH="$bin:$PATH" FIXDIR="$fix" SCENARIO=mismatch DLCOUNT="$work/dl" \
    RVOPT="$RVOPT_BIN" MUXLEQ="$MUXLEQ_BIN" sh "$script" >/dev/null 2>&1 || rc=$?
n=$(grep -c x "$work/dl" 2>/dev/null || echo 0)
if [ "$rc" = 77 ] && [ "$n" = 2 ]; then
    pass=$((pass + 1))
    printf '  ok    %-9s %s tarball fetches\n' "retry" "$n"
else
    failn=$((failn + 1))
    printf '  FAIL  %-9s exit %s, %s fetches (want exit 77, 2 fetches)\n' "retry" "$rc" "$n"
fi
if [ "$have_py" = 1 ]; then
    assert symlink 1 # link member -> refuse
    assert badpath 1 # out-of-tree member -> refuse
else
    echo "  skip  symlink/badpath (no python3 to craft archives)"
fi
if [ "$have_elfs" = 1 ]; then
    assert full 0   # full tarball, all conformance PASS
    assert demos 77 # demos-only release -> skip, not a green pass
else
    echo "  skip  full/demos (no built rvopt/muxleq + build/rv32i tree)"
fi
if [ "$have_trunc" = 1 ]; then
    assert trunc 77 # count.txt claims full suite, only one elf present -> skip
else
    echo "  skip  trunc (no count.txt manifest to truncate)"
fi

# Live smoke against the real published release (real curl, real assets), which
# the mock cannot cover: it proves the URL, the asset names, the checksum asset,
# and the tarball format all resolve end to end. To avoid the "accepts 0 or 77"
# blind spot (a should-pass that regressed to 77 would slip through), first
# inspect what the real release actually carries and assert the EXACT exit: a
# release with conformance elfs must exit 0, a demos-only one must exit 77. Runs
# only with real rvopt/muxleq and a reachable release; the download gate
# degrades to a skip, so an outage never flakes.
live_rvopt="${RVOPT:-$root/build/rvopt}"
live_muxleq="${MUXLEQ:-$root/build/muxleq}"
live_repo="${REPO:-sysprog21/muxleq}"
live_tag="${RV32I_PREBUILT_TAG:-rv32i-latest}"
live_tgz="$work/live.tgz"
if [ -x "$live_rvopt" ] && [ -x "$live_muxleq" ] &&
    curl -fsS --connect-timeout 5 --max-time 30 -o "$live_tgz" \
        "https://github.com/$live_repo/releases/download/$live_tag/rv32i-binaries.tar.gz" 2>/dev/null; then

    # Mirror the script's own contract: it exits 0 only when the release carries
    # the COMPLETE conformance suite (count.txt present and the elf count
    # matches it); a demos-only OR truncated release exits 77. Predicting exp
    # from mere presence would falsely FAIL the test on a truncated release the
    # script legitimately skips.
    live_list="$work/live.list"
    tar -tzf "$live_tgz" 2>/dev/null >"$live_list" || true
    live_elfs=$(grep -cE '^rv32i/riscv-tests/[^/]+\.elf$' "$live_list" || true)
    live_count=$(tar -xzOf "$live_tgz" rv32i/riscv-tests/count.txt 2>/dev/null | tr -cd '0-9')
    if [ -n "$live_count" ] && [ "$live_count" -gt 0 ] && [ "$live_elfs" = "$live_count" ]; then
        exp=0 # full conformance suite present -> the real run must pass
    else
        exp=77 # demos-only or truncated release -> the real run must skip
    fi
    rc=0
    # No mock on PATH here: the real curl fetches the real assets.
    env RVOPT="$live_rvopt" MUXLEQ="$live_muxleq" sh "$script" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = "$exp" ]; then
        pass=$((pass + 1))
        printf '  ok    %-9s exit %s (real release, expected %s)\n' "live" "$rc" "$exp"
    else
        failn=$((failn + 1))
        printf '  FAIL  %-9s exit %s (real release, want %s)\n' "live" "$rc" "$exp"
    fi
else
    echo "  skip  live (no built rvopt/muxleq or release unreachable)"
fi

echo "rv32i-prebuilt-test: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
