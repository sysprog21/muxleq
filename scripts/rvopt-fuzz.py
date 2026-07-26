#!/usr/bin/env python3
"""Differential fuzzer for `rvopt -mux` native MUXLEQ emission.

Generates random RV32I programs over the emitter's SUPPORTED subset
(ADD/SUB/SLT[U]/AND/OR/XOR + immediates, SLL and SLLI/SRLI/SRAI, loads/stores,
forward branches/JALRs, and bounded loops), seeds the registers with random
32-bit values, folds the result into a checksum, and writes it out. Each program
is run two ways and the stdout is compared:

    oracle   = ./muxleq -r prog.bin           (the RV32I interpreter)
    emitted  = rvopt -mux prog.bin | muxleq -x prog.dec   (native two-op image)

With --wide the emitter under test is the 32-bit-cell backend instead:
    emitted  = rvopt -mux32 prog.bin | muxleq -x32 prog.dec

A mismatch is an emitter bug -- the interpreter is the reference. Random
hi-halves are deliberate: they exercise the 32-bit macro paths (carry/borrow
votes, hi bitwise, bit-extract) that a later known-hi-zero pass will touch, so a
pass that ever drops the high 16 bits shows up here even though the 7 demos
(all <=16-bit-ish) would not catch it.

Every program halts: straight-line ones are forward-only (each branch skips at
most the one guarded op that follows it), and every third program is a bounded
do-while loop (rc = K in [2,5]; a body that never writes rc; `bne rc,x0` back
to the head) that stresses loop-carried values and store/load ordering ACROSS
the back-edge -- the multi-iteration class only unopt covered. Reproduce a
failure with:
  rvopt-fuzz.py --seed S --only I --keep
"""
import argparse
import os
import random
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from importlib import import_module

_rv = import_module("rv32i-conformance")
alu, sx32 = _rv.alu, _rv.sx32   # the emitter-independent RV32I ALU model + sign-extend
branch_taken = _rv.branch_taken
MASK = 0xFFFFFFFF

# x0 zero; x10/x11/x12/x17 reserved for the write/exit ecalls; x29 = buffer ptr;
# x30 = scratch RAM base for load/store round-trips.
WORK = [5, 6, 7, 8, 9, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28]
SCRATCH = 0x800   # RAM window offset for SW/LW round-trips; well above the tiny code+buffer
R_OPS = [(0, 0x00), (0, 0x20), (2, 0x00), (3, 0x00), (4, 0x00), (6, 0x00),
         (7, 0x00), (1, 0x00), (5, 0x00), (5, 0x20)]  # ADD SUB SLT SLTU XOR OR AND SLL SRL SRA
I_OPS = [0, 2, 3, 4, 6, 7]                            # ADDI SLTI SLTIU XORI ORI ANDI
ISH = [(0x00, 1), (0x00, 5), (0x20, 5)]              # SLLI SRLI SRAI


def enc_r_rd(f7, f3, rd, rs1, rs2):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33


def enc_i_rd(f3, imm, rd, rs1):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13


def enc_ish_rd(f7, f3, sh, rd, rs1):
    return (f7 << 25) | ((sh & 31) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13


def enc_lui(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37


def enc_auipc(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x17


def enc_jalr(rd, rs1, imm):           # JALR is always funct3=0
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x67


def enc_s(f3, rs2, rs1, imm):         # store: SW f3=2, SB f3=0
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | 0x23


def enc_sw(rs2, rs1, imm):
    return enc_s(2, rs2, rs1, imm)


def enc_load(f3, rd, rs1, imm):       # load: LW f3=2, LBU f3=4
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x03


def enc_b_rr(f3, rs1, rs2, imm):      # B-type branch, configurable rs1/rs2
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | \
        (rs1 << 15) | (f3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63


BR_F3 = [0, 1, 4, 5, 6, 7]            # BEQ BNE BLT BGE BLTU BGEU


def enc_ecall():
    return 0x00000073


def li(words, rd, val, force_wide=False):
    """Set rd = val exactly. A value that fits signed-12 becomes ONE ADDI x0 --
    the form rvopt's constant tracker folds (needed so a7/a2 are known at the
    ecall); otherwise LUI + ADDI. force_wide=True always emits LUI+ADDI so the
    tracker sees rd as a runtime value (used for the write buffer pointer, to
    force the SYS_WRITE_DYN path that reads the live RAM the program just wrote)."""
    val &= MASK
    if not force_wide and (val < 0x800 or val >= MASK - 0x7FF):
        words.append(enc_i_rd(0, val & 0xFFF, rd, 0))   # ADDI rd, x0, imm12
        return
    hi = (val + 0x800) >> 12 & 0xFFFFF
    lo = val & 0xFFF                  # ADDI sign-extends; the +0x800 above compensates
    words.append(enc_lui(rd, hi))
    words.append(enc_i_rd(0, lo, rd, rd))


def build_program(rng, body_len):
    """Return (flat_bytes, seeds, ops, desc) for one random program (ALU +
    load/store round-trips + forward skip-next branches + forward computed/linking
    JALRs; always terminating)."""
    seeds = {r: rng.getrandbits(32) for r in WORK}
    words, desc = [], []
    for r in WORK:                    # prologue: seed every work register
        li(words, r, seeds[r])
    li(words, 30, SCRATCH, force_wide=True)   # x30 = scratch RAM base (wide: runtime addr)
    ops = []                          # (rd, rs1, rs2_or_imm, f3, f7, extra)
    for _ in range(body_len):
        kind = rng.randrange(6)
        rd = rng.choice(WORK)
        if kind == 5:                 # forward computed/linking JALR, jumping over one ADDI
            # auipc rtmp,0; addi rtmp,rtmp,16; jalr rlink,rtmp,0 -- rtmp becomes a
            # compile-time constant (auipc pc + 16), so rvopt resolves the jump to
            # a static forward target that skips exactly the guarded ADDI (proving
            # the jump). rtmp ends = auipc_pc+16 (the target); rlink = jalr_pc+4
            # (the link, x0 = no link). Forward-only -> always terminates.
            pc0 = 4 * len(words)      # guest byte address of the auipc (flat image @ 0)
            rtmp, rskip = rng.sample(WORK, 2)
            rlink = rng.choice(WORK + [0])
            while rlink == rtmp or rlink == rskip:
                rlink = rng.choice(WORK + [0])
            gs1 = rng.choice(WORK)
            gimm = rng.getrandbits(12)
            words.append(enc_auipc(rtmp, 0))            # rtmp = pc0
            words.append(enc_i_rd(0, 16, rtmp, rtmp))   # rtmp += 16 -> target pc0+16
            words.append(enc_jalr(rlink, rtmp, 0))      # jump rtmp, link rlink
            words.append(enc_i_rd(0, gimm, rskip, gs1)) # SKIPPED ADDI rskip = gs1+imm
            ops.append((rlink, rtmp, rskip, "JALR", pc0, None))
            desc.append("JALR link x%d, target x%d = pc+16, skip [x%d = x%d + %03x]" %
                        (rlink, rtmp, rskip, gs1, gimm))
        elif kind == 4:               # forward branch guarding the next ALU op (skip-if-taken)
            bf3 = rng.choice(BR_F3)
            b1, b2 = rng.choice(WORK), rng.choice(WORK)
            gs1 = rng.choice(WORK)
            gimm = rng.getrandbits(12)
            words.append(enc_b_rr(bf3, b1, b2, 8))    # taken -> skip the next 4-byte instr
            words.append(enc_i_rd(0, gimm, rd, gs1))  # guarded ADDI rd = gs1 + imm
            ops.append((rd, gs1, (b1, b2), "BR", bf3, gimm))
            desc.append("BR f3=%d if x%d,x%d then skip [x%d = x%d + %03x]" %
                        (bf3, b1, b2, rd, gs1, gimm))
        elif kind == 3:               # load/store round-trip through scratch RAM
            ops.append(_emit_ls(rng, rd, words, desc))
        elif kind == 0:               # R-type
            f3, f7 = rng.choice(R_OPS)
            rs1, rs2 = rng.choice(WORK), rng.choice(WORK)
            words.append(enc_r_rd(f7, f3, rd, rs1, rs2))
            ops.append((rd, rs1, rs2, f3, f7, None))
            desc.append("R f3=%d f7=%02x x%d = x%d,x%d" % (f3, f7, rd, rs1, rs2))
        elif kind == 1:               # I-type ALU
            f3 = rng.choice(I_OPS)
            rs1 = rng.choice(WORK)
            imm = rng.getrandbits(12)
            words.append(enc_i_rd(f3, imm, rd, rs1))
            ops.append((rd, rs1, None, f3, 0x00, imm))
            desc.append("I f3=%d x%d = x%d, imm=%03x" % (f3, rd, rs1, imm))
        else:                         # I-type shift (shamt encoded)
            f7, f3 = rng.choice(ISH)
            rs1 = rng.choice(WORK)
            sh = rng.randrange(32)
            words.append(enc_ish_rd(f7, f3, sh, rd, rs1))
            ops.append((rd, rs1, None, f3, f7, ("sh", sh)))
            desc.append("ISH f3=%d f7=%02x x%d = x%d << %d" % (f3, f7, rd, rs1, sh))
    return _finish(words, seeds, ops, desc)


def _finish(words, seeds, ops, desc):
    """Append the common epilogue -- dump ALL 16 work registers verbatim (no fold
    -- a fold could XOR away correlated bit errors) then write the whole 64-byte
    block, so every bit of every result is observed. It is exactly (2 + 16 + 9) =
    27 words (force-wide li is always 2), so the buffer sits just past all code,
    inside the window, and never aliases it -- true for a straight-line OR a loop
    body (the loop emits its body once; it runs K times but occupies code once).
    """
    nbytes = len(WORK) * 4
    bufaddr = (len(words) * 4 + 27 * 4 + 15) & ~15
    li(words, 29, bufaddr, force_wide=True)          # buf ptr (wide -> SYS_WRITE_DYN)
    for i, r in enumerate(WORK):
        words.append(enc_sw(r, 29, i * 4))           # store each reg to live RAM
    li(words, 10, 1)                                  # a0 = fd 1 (stdout)
    li(words, 11, bufaddr, force_wide=True)           # a1 = buf (wide -> dynamic write)
    li(words, 12, nbytes)                             # a2 = 64 bytes
    li(words, 17, 64)                                 # a7 = SYS_WRITE
    words.append(enc_ecall())
    li(words, 17, 93)                                 # a7 = SYS_EXIT
    li(words, 10, 0)
    words.append(enc_ecall())
    assert len(words) * 4 <= bufaddr, "epilogue overran the buffer slot"
    assert bufaddr + nbytes <= SCRATCH, "output buffer collided with scratch RAM"
    blob = b"".join(struct.pack("<I", w & MASK) for w in words)
    end = max(bufaddr + nbytes, SCRATCH + 16)          # window must cover buffer AND scratch
    blob += b"\x00" * (end - len(blob))
    return blob, seeds, ops, desc


def _emit_ls(rng, rd, words, desc, prefix=""):
    """Emit a store-then-load-back round-trip through scratch RAM (x30 base) and
    return its model tuple. Exercises every emitter load/store path and its
    sign/zero-extend: SB+LB/LBU (byte), SH+LH/LHU (half), SW+LW. rx is the value
    source (store); rd is the load dest. Shared by build_program and the loop body,
    so the variant/offset/encoder table lives in one place; prefix indents the loop
    body's desc lines. RNG draw order (rx, variant, off) is fixed for both callers.
    """
    rx = rng.choice(WORK)
    variant = rng.choice(("b", "bu", "h", "hu", "w"))
    if variant in ("b", "bu"):
        off = rng.choice((0, 1, 2, 3))
        words.append(enc_s(0, rx, 30, off))                  # SB
        words.append(enc_load(0 if variant == "b" else 4, rd, 30, off))
    elif variant in ("h", "hu"):
        off = rng.choice((0, 2, 4, 6))                       # half-aligned
        words.append(enc_s(1, rx, 30, off))                  # SH
        words.append(enc_load(1 if variant == "h" else 5, rd, 30, off))
    else:                                                    # word
        off = rng.choice((0, 4, 8, 12))
        words.append(enc_sw(rx, 30, off))
        words.append(enc_load(2, rd, 30, off))
    desc.append("%sLS %s x%d = mem[x%d, off=%d]" % (prefix, variant, rd, rx, off))
    return (rd, rx, None, "LS", variant, None)


def _loop_body_op(rng, rd, words, desc):
    """Append one ALU or load/store round-trip writing rd; return its model tuple.
    No nested control flow, so the loop's back-branch offset stays simple.
    """
    kind = rng.randrange(3)
    if kind == 0:                         # R-type
        f3, f7 = rng.choice(R_OPS)
        rs1, rs2 = rng.choice(WORK), rng.choice(WORK)
        words.append(enc_r_rd(f7, f3, rd, rs1, rs2))
        desc.append("  R f3=%d f7=%02x x%d = x%d,x%d" % (f3, f7, rd, rs1, rs2))
        return (rd, rs1, rs2, f3, f7, None)
    if kind == 1:                         # I-type ALU
        f3 = rng.choice(I_OPS)
        rs1 = rng.choice(WORK)
        imm = rng.getrandbits(12)
        words.append(enc_i_rd(f3, imm, rd, rs1))
        desc.append("  I f3=%d x%d = x%d, imm=%03x" % (f3, rd, rs1, imm))
        return (rd, rs1, None, f3, 0x00, imm)
    return _emit_ls(rng, rd, words, desc, "  ")   # load/store round-trip


def build_loop_program(rng, body_len):
    """A bounded do-while loop: rc = K; do { body } while (--rc != 0). Stresses
    loop-carried register values and store/load memory ordering ACROSS the
    back-edge -- the multi-iteration class only unopt covered, and exactly where
    store-to-load forwarding must NOT cross the loop-head leader. Body is ALU +
    load/store round-trips (no nested control flow). Always terminates in K
    iterations (rc decrements by one each pass, body never writes rc)."""
    seeds = {r: rng.getrandbits(32) for r in WORK}
    words, desc, ops = [], [], []
    for r in WORK:                    # prologue: seed every work register
        li(words, r, seeds[r])
    li(words, 30, SCRATCH, force_wide=True)   # x30 = scratch RAM base
    K = rng.randint(2, 5)
    rc = rng.choice(WORK)             # loop counter, excluded from body destinations
    li(words, rc, K)
    seeds[rc] = K                     # model: rc holds K entering the loop
    body_regs = [r for r in WORK if r != rc]
    loop_head = len(words)            # word index of the loop head (a leader)
    body_ops = []
    for _ in range(body_len):
        body_ops.append(_loop_body_op(rng, rng.choice(body_regs), words, desc))
    words.append(enc_i_rd(0, (-1) & 0xFFF, rc, rc))    # addi rc, rc, -1
    body_ops.append((rc, rc, None, 0, 0x00, (-1) & 0xFFF))
    back = (loop_head - len(words)) * 4                 # negative byte offset to head
    words.append(enc_b_rr(1, rc, 0, back))             # bne rc, x0, loop_head (control only)
    desc.insert(0, "LOOP counter x%d, %d iterations:" % (rc, K))
    ops.append(("LOOP", K))
    ops.extend(body_ops)
    ops.append(("ENDLOOP", None))
    return _finish(words, seeds, ops, desc)


def _expand_loops(ops):
    """Flatten ("LOOP", K) .. ("ENDLOOP", None) spans into the body repeated K
    times, so the linear model below replays a loop exactly as the guest runs it
    (a marker is a 2-tuple; a real op is a 6-tuple)."""
    out, i = [], 0
    while i < len(ops):
        if len(ops[i]) == 2 and ops[i][0] == "LOOP":
            k = ops[i][1]
            i += 1
            body = []
            while not (len(ops[i]) == 2 and ops[i][0] == "ENDLOOP"):
                body.append(ops[i])
                i += 1
            out.extend(body * k)
        else:
            out.append(ops[i])
        i += 1
    return out


def model(seeds, ops):
    """Compute the expected checksum the same way the program does."""
    reg = dict(seeds)
    for rd, rs1, rs2, f3, f7, extra in _expand_loops(ops):
        if f3 == "LS":                # load/store round-trip: rd = mem(rs1); f7 = variant
            v = reg[rs1]
            if f7 == "b":             # SB then LB: sign-extend bit 7
                v = (v & 0xFF) - (0x100 if v & 0x80 else 0)
            elif f7 == "bu":          # SB then LBU: zero-extend
                v = v & 0xFF
            elif f7 == "h":           # SH then LH: sign-extend bit 15
                v = (v & 0xFFFF) - (0x10000 if v & 0x8000 else 0)
            elif f7 == "hu":          # SH then LHU: zero-extend
                v = v & 0xFFFF
            reg[rd] = v & MASK        # "w" (SW/LW) falls through unchanged
            continue
        if f3 == "BR":                # branch (f7=funct3) guarding an ADDI rd = rs1 + imm
            b1, b2 = rs2
            if not branch_taken(f7, reg[b1], reg[b2]):       # taken -> skip the ADDI
                reg[rd] = alu(0, 0x00, reg[rs1],
                              sx32(extra if extra < 0x800 else extra - 0x1000))
            continue
        if f3 == "JALR":              # rd=rlink, rs1=rtmp, rs2=rskip, f7=auipc pc
            reg[rs1] = (f7 + 16) & MASK      # rtmp = auipc_pc + 16 (jump target addr)
            if rd != 0:                      # rlink = jalr_pc + 4 (x0 = no link)
                reg[rd] = (f7 + 12) & MASK
            # rskip is jumped over -> unchanged
            continue
        a = reg[rs1]
        if rs2 is not None:           # R-type
            b = reg[rs2]
        elif isinstance(extra, tuple):  # shift-immediate
            b = extra[1]
        else:                          # ALU immediate (sign-extended 12-bit)
            b = sx32(extra if extra < 0x800 else extra - 0x1000)
        reg[rd] = alu(f3, f7, a, b)
    return b"".join(struct.pack("<I", reg[r]) for r in WORK)


SKIP = "skip"   # sentinel: program too big to emit; not a pass, not a failure


class _Hang:                    # a timed-out run: an emitted program that never halts is a bug
    returncode = 124
    stdout = b""

    def __init__(self, cmd):
        self.stderr = ("timed out (hang): " + " ".join(cmd)).encode()


def run(cmd, stdin=None):
    try:
        return subprocess.run(cmd, capture_output=True, timeout=15, input=stdin, cwd=ROOT)
    except subprocess.TimeoutExpired:
        return _Hang(cmd)


def check_one(idx, blob, seeds, ops, muxleq, rvopt, tmp, keep, wide=False):
    emit_flag, run_flag = ("-mux32", "-x32") if wide else ("-mux", "-x")
    binp = os.path.join(tmp, "fuzz-%d.bin" % idx)
    with open(binp, "wb") as f:
        f.write(blob)
    ora = run([muxleq, "-r", binp])
    emit = run([rvopt, emit_flag, binp])
    if emit.returncode != 0 or not emit.stdout:
        msg = emit.stderr.decode(errors="replace").strip()
        # A program too big for the MUXLEQ image (32768 cells for -mux, the 2M
        # -x32 window for -mux32) is an expected abort, not a miscompile -- skip
        # it (counted) rather than fail. Any OTHER nonzero exit (unsupported op,
        # real crash) is a genuine failure.
        if "image needs" in msg:
            return SKIP
        return "rvopt %s failed (rc=%d): %s" % (emit_flag, emit.returncode, msg)
    decp = os.path.join(tmp, "fuzz-%d.dec" % idx)
    with open(decp, "wb") as f:
        f.write(emit.stdout)
    nat = run([muxleq, run_flag, decp])
    want = model(seeds, ops)
    # A tool that prints the right bytes but exits nonzero is still a defect.
    if ora.returncode != 0:
        return "-r exited %d: %s" % (ora.returncode, ora.stderr.decode(errors="replace").strip())
    if nat.returncode != 0:
        return "%s exited %d: %s" % (run_flag, nat.returncode, nat.stderr.decode(errors="replace").strip())
    if ora.stdout != want:
        return "ORACLE (-r) disagrees with the Python model -- bug in the fuzzer/generator"
    if nat.stdout != ora.stdout:
        if keep:
            os.rename(binp, os.path.join(ROOT, "rvopt-fuzz-fail.bin"))
        return "native %s %r != -r %r" % (run_flag, nat.stdout, ora.stdout)
    return None


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=64, help="number of programs")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--body", type=int, default=20,
                    help="ALU ops per program (>~24 often overflows the 32768-cell image and is skipped)")
    ap.add_argument("--only", type=int, default=-1, help="run just program index I")
    ap.add_argument("--keep", action="store_true", help="save a failing .bin to the repo root")
    ap.add_argument("--wide", action="store_true",
                    help="test the 32-bit-cell backend (rvopt -mux32 | muxleq -x32) instead of -mux/-x")
    ap.add_argument("--rvopt", default=os.path.join(ROOT, "build", "rvopt"),
                    help="rvopt binary to test (e.g. a sanitizer build, to run every "
                         "emitter path under ASan/UBSan)")
    a = ap.parse_args(argv[1:])
    muxleq = os.path.join(ROOT, "build", "muxleq")
    rvopt = a.rvopt
    for exe in (muxleq, rvopt):
        if not os.path.exists(exe):
            sys.exit("missing %s -- run `make %s` first" % (exe, os.path.basename(exe)))
    tested = skipped = 0
    with tempfile.TemporaryDirectory() as tmp:
        for i in range(a.n):
            if a.only >= 0 and i != a.only:
                continue
            rng = random.Random((a.seed << 20) ^ i)   # per-index reproducible
            # Every third program is a bounded loop (multi-iteration + loop-carried
            # memory across a back-edge); the rest are straight-line.
            builder = build_loop_program if i % 3 == 0 else build_program
            blob, seeds, ops, desc = builder(rng, a.body)
            err = check_one(i, blob, seeds, ops, muxleq, rvopt, tmp, a.keep, a.wide)
            if err is SKIP:
                skipped += 1
                continue
            if err:
                print("FAIL program %d (seed %d): %s" % (i, a.seed, err), file=sys.stderr)
                print("reproduce: scripts/rvopt-fuzz.py --seed %d --only %d --body %d --keep%s"
                      % (a.seed, i, a.body, " --wide" if a.wide else ""), file=sys.stderr)
                for d in desc:
                    print("   " + d, file=sys.stderr)
                return 1
            tested += 1
    if a.only < 0 and tested == 0:
        print("rvopt-fuzz: ALL %d programs overflowed the image -- lower --body" % skipped,
              file=sys.stderr)
        return 1
    print("rvopt-fuzz%s: %d programs x %d ops OK (seed %d) native == -r (%d skipped, too big)"
          % (" -mux32" if a.wide else "", tested, a.body, a.seed, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
