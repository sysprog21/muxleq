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
# staged release tree are present (e.g. after rv32i-release). Malicious archives
# are crafted with python3 when available. A final network-gated case runs the
# script against the REAL published release (real curl, real assets) to validate
# the URL, asset names, and format that the mock cannot check.
set -eu

here="$(CDPATH='' cd "$(dirname "$0")" && pwd)"
root="$(CDPATH='' cd "$here/.." && pwd)"
script="$root/scripts/rv32i-prebuilt.sh"

# The oracles below read count.txt through the same helper the script uses, so a
# change to what a usable count is cannot leave the test predicting the old
# contract. The fixtures, with their own expected exit codes, are what pin the
# helper itself.
count_sh="$root/scripts/rv32i-count.sh"

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

# Metadata contract cases: one conformance elf each, differing only in what
# count.txt says. Stub rvopt/muxleq replace the toolchain -- they lower nothing,
# they only let the conformance loop count the elf and see PASS -- so these run
# anywhere, unlike the pass cases below that need a staged release tree.
cat >"$bin/rvopt-stub" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 2 ]
[ "$1" = mux ]
printf '0\n'
EOF
cat >"$bin/muxleq-stub" <<'EOF'
#!/bin/sh
set -eu
printf 'PASS\n'
EOF
chmod +x "$bin/rvopt-stub" "$bin/muxleq-stub"

manifest="$root/scripts/rv32i-manifest.sh"

# Each case gets a manifest matching whatever it stages, so a count.txt case
# fails on the count and nothing else: without that they would all trip the
# consumer's manifest check first and pass for the wrong reason.
meta_case() { # name, count.txt body for printf %b ("-" stages no count.txt)
    m="$work/meta-$1"
    mkdir -p "$m/rv32i/riscv-tests"
    : >"$m/rv32i/riscv-tests/add.elf"
    [ "$2" = - ] || printf '%b' "$2" >"$m/rv32i/riscv-tests/count.txt"
    sh "$manifest" create "$m/rv32i"
    tar -czf "$fix/$1.tgz" -C "$m" rv32i
    sha_tool "$fix/$1.tgz" >"$fix/$1.sha"
}
meta_case valid-count '1\n'
meta_case missing-count -
meta_case empty-count ''
meta_case zero-count '0\n'
meta_case leading-zero-count '01\n'
meta_case junk-count '1x\n'
meta_case multiline-count '1\n\n'
meta_case crlf-count '1\r\n'
meta_case space-before-count ' 1\n'
meta_case space-after-count '1 \n'
meta_case huge-count '99999999999999999999999999\n'
meta_case mismatched-count '2\n'

# Manifest cases: a valid payload that the manifest no longer describes. Built
# by damaging valid-count's tree after its manifest was written, so each one
# differs from a passing release in exactly the way its name says.
man_case() { # name, then the damage to apply to the staged rv32i tree
    name=$1
    m="$work/man-$name"
    rm -rf "$m"
    mkdir -p "$m"
    cp -R "$work/meta-valid-count/rv32i" "$m/"
    shift
    "$@" "$m/rv32i"
    tar -czf "$fix/$name.tgz" -C "$m" rv32i
    sha_tool "$fix/$name.tgz" >"$fix/$name.sha"
}
drop_manifest() { rm -f "$1/MANIFEST.sha256"; }
edit_payload() { printf 'drift' >"$1/riscv-tests/add.elf"; }
# A stray .o, not another .elf: the conformance count must stay right, so the
# manifest is the only thing this case breaks.
add_payload() { : >"$1/riscv-tests/extra.o"; }
man_case no-manifest drop_manifest
man_case manifest-drift edit_payload
man_case manifest-extra add_payload

# Pass cases need real elfs and a real rvopt/muxleq; run them only when present.
# They come from the staging tree "make rv32i-release" builds, not build/rv32i:
# that tree is the release payload and the only one carrying a manifest, which
# the consumer now checks before it lowers anything. Each fixture re-creates the
# manifest after editing the tree, so a case fails on what its name says rather
# than on a manifest it was never meant to test.
RVOPT_BIN="${RVOPT:-$root/build/rvopt}"
MUXLEQ_BIN="${MUXLEQ:-$root/build/muxleq}"
staged="$root/build/rv32i-release/rv32i"
have_elfs=0
have_full=0
have_trunc=0
if [ -d "$staged/riscv-tests" ] && [ -x "$RVOPT_BIN" ] && [ -x "$MUXLEQ_BIN" ]; then
    tar -czf "$fix/full.tgz" -C "$root/build/rv32i-release" rv32i
    sha_tool "$fix/full.tgz" >"$fix/full.sha"
    d="$work/demosonly"
    mkdir -p "$d"
    cp -R "$staged" "$d/"
    rm -rf "$d/rv32i/riscv-tests"
    sh "$manifest" create "$d/rv32i"
    tar -czf "$fix/demos.tgz" -C "$d" rv32i
    sha_tool "$fix/demos.tgz" >"$fix/demos.sha"
    have_elfs=1

    # Truncated release: keep count.txt (claims the full suite) but drop all but
    # one conformance elf, so the consumer must reject it rather than pass
    # green.
    if [ -f "$staged/riscv-tests/count.txt" ]; then
        t="$work/trunc"
        mkdir -p "$t"
        cp -R "$staged" "$t/"
        # Filenames here are generated rv32ui test names (add.elf, ...), so
        # they are plain and ls is safe to read.
        # shellcheck disable=SC2012
        one="$(ls "$t"/rv32i/riscv-tests/*.elf | head -1)"
        find "$t/rv32i/riscv-tests" -name '*.elf' ! -path "$one" -delete
        sh "$manifest" create "$t/rv32i"
        tar -czf "$fix/trunc.tgz" -C "$t" rv32i
        sha_tool "$fix/trunc.tgz" >"$fix/trunc.sha"
        have_trunc=1

        # The full case asserts that a complete release runs green, so it needs
        # a tree that is one: a count.txt the elfs beside it match, and a
        # manifest describing what is there. A partial or stale staging tree is
        # not that release, and asserting 0 against it would redden the gate for
        # the script skipping exactly as it should. This case tars the tree as
        # staged, so unlike demos and trunc it cannot re-create the manifest --
        # it has to be handed one that already fits.
        # shellcheck disable=SC2012  # generated, plain filenames (see above)
        elfs=$(ls "$staged"/riscv-tests/*.elf 2>/dev/null | wc -l | tr -d ' ')
        want=$(sh "$count_sh" "$staged/riscv-tests/count.txt" || true)
        if [ "$elfs" = "$want" ] && sh "$manifest" verify "$staged" >/dev/null 2>&1; then
            have_full=1
        fi
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

# Read the helper directly. End to end a rejected count and a valid one that
# simply does not match the elfs both skip with 77, so only this can show which
# happened -- and that a decimal too wide for a shell integer survives verbatim
# rather than folding into arithmetic.
parse_case() { # name, count.txt body for printf %b, expected stdout ("-" fails)
    printf '%b' "$2" >"$work/parse.count"
    got=$(sh "$count_sh" "$work/parse.count" 2>/dev/null) || got=-
    if [ "$got" = "$3" ]; then
        pass=$((pass + 1))
        printf '  ok    %-18s %s\n' "$1" "$got"
    else
        failn=$((failn + 1))
        printf '  FAIL  %-18s %s (want %s)\n' "$1" "$got" "$3"
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
if [ "$have_full" = 1 ]; then
    assert full 0 # full tarball, all conformance PASS
else
    echo "  skip  full (no staged tree that is a complete, manifested release)"
fi
if [ "$have_elfs" = 1 ]; then
    assert demos 77 # demos-only release -> skip, not a green pass
else
    echo "  skip  demos (no built rvopt/muxleq + staged release tree)"
fi
if [ "$have_trunc" = 1 ]; then
    assert trunc 77 # count.txt claims full suite, only one elf present -> skip
else
    echo "  skip  trunc (no count.txt manifest to truncate)"
fi

# The metadata cases need a conformance loop that runs, not a real toolchain, so
# the asserts below use the stubs.
RVOPT_BIN="$bin/rvopt-stub"
MUXLEQ_BIN="$bin/muxleq-stub"
assert valid-count 0         # one line, one positive decimal -> the only pass
assert missing-count 77      # no count.txt at all -> skip
assert empty-count 77        # count.txt staged but empty -> skip
assert zero-count 77         # a release carrying elfs never declares none
assert leading-zero-count 77 # "01" is not what the producer writes
assert junk-count 77         # "1x" must not read as 1
assert multiline-count 77    # a trailing line is not a comment
assert crlf-count 77         # a CR is not part of the number
assert space-before-count 77 # padding fails the leading anchor
assert space-after-count 77  # and the trailing one
assert huge-count 77         # read as a string, so it mismatches, not errors
assert mismatched-count 77   # declares 2, carries 1
assert no-manifest 77        # nothing describes the payload
assert manifest-drift 77     # a listed file changed after staging
assert manifest-extra 77     # a file the manifest never listed
parse_case parse-plain '40\n' 40
parse_case parse-huge '99999999999999999999999999\n' 99999999999999999999999999
parse_case parse-crlf '1\r\n' -
parse_case parse-junk '1x\n' -

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
    curl -fsSL --connect-timeout 5 --max-time 30 -o "$live_tgz" \
        "https://github.com/$live_repo/releases/download/$live_tag/rv32i-binaries.tar.gz" 2>/dev/null; then

    # Mirror the script's own contract: it exits 0 only when the release carries
    # the COMPLETE conformance suite (count.txt present and the elf count
    # matches it); a demos-only OR truncated release exits 77. Predicting exp
    # from mere presence would falsely FAIL the test on a truncated release the
    # script legitimately skips.
    live_list="$work/live.list"
    tar -tzf "$live_tgz" 2>/dev/null >"$live_list" || true
    live_elfs=$(grep -cE '^rv32i/riscv-tests/[^/]+\.elf$' "$live_list" || true)
    tar -xzOf "$live_tgz" rv32i/riscv-tests/count.txt >"$work/live.count" 2>/dev/null || :
    live_count=$(sh "$count_sh" "$work/live.count" || true)

    # A release predating the manifest skips too, so extract and check that here
    # as well: predicting 0 from the elf count alone would fail this test for
    # the whole window between merging this and CI republishing.
    live_tree="$work/live-tree"
    mkdir -p "$live_tree"
    tar -xzf "$live_tgz" -C "$live_tree" 2>/dev/null || true
    if [ -n "$live_count" ] && [ "$live_elfs" = "$live_count" ] &&
        sh "$manifest" verify "$live_tree/rv32i" >/dev/null 2>&1; then
        exp=0 # full conformance suite, payload matches its manifest -> pass
    else
        exp=77 # demos-only, truncated, or unmanifested release -> skip
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
