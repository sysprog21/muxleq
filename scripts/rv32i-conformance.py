#!/usr/bin/env python3
"""Generate a comprehensive RV32I conformance test for the muxleq microcode.

Compliance validation, substrate-appropriate. The official riscv-arch-test ELFs
cannot run on muxleq (they link at ~0x10000 = cell 0x8000 > the 32767-cell guest
window, are KB-scale, and need a full syscall ABI). So we
validate at the INSTRUCTION level instead: an independent Python reference model
(a plain transcription of the RV32I base spec) computes the expected result of
each instruction, and the generated .fth drives the SAME operands through the
`:a rvstep` microcode and self-checks (OK per vector, FAIL with got/want). muxleq
matching the reference across a systematic operand space IS the conformance claim.

Independence guard: `--verify-model` re-derives every expected value in the
hand-written, Codex-verified tests/rv32i-spec.fth from this model. If the model
disagrees with those anchors, it is wrong and must not be trusted to generate new
vectors. Run it before regenerating:

    python3 scripts/rv32i-conformance.py --verify-model
    python3 scripts/rv32i-conformance.py > tests/rv32i-conform.fth

The generated file reuses rv32i-spec.fth's harness verbatim (rs1=x1, rs2=x2,
rd=x3), so keep the two in sync -- the harness is copied from there, not forked.
"""
import os
import sys

MASK = 0xFFFFFFFF


def sx32(v):
    """Interpret a uint32 as signed."""
    v &= MASK
    return v - (1 << 32) if v & 0x80000000 else v


# --- RV32I reference model: result of `rd = rs1 OP (rs2 | imm)`, all uint32 ---
def alu(funct3, funct7, a, b):
    """R-type / I-type ALU. b is rs2 (R) or the sign-extended immediate (I).
    funct7 selects SUB (0x20) vs ADD and SRA (0x20) vs SRL for the shift slot."""
    a &= MASK
    b &= MASK
    sh = b & 31
    if funct3 == 0:                      # ADD / SUB
        return (a - b if funct7 == 0x20 else a + b) & MASK
    if funct3 == 1:                      # SLL
        return (a << sh) & MASK
    if funct3 == 2:                      # SLT (signed)
        return 1 if sx32(a) < sx32(b) else 0
    if funct3 == 3:                      # SLTU (unsigned)
        return 1 if a < b else 0
    if funct3 == 4:                      # XOR
        return a ^ b
    if funct3 == 5:                      # SRL / SRA
        if funct7 == 0x20:
            return (sx32(a) >> sh) & MASK
        return (a >> sh) & MASK
    if funct3 == 6:                      # OR
        return a | b
    if funct3 == 7:                      # AND
        return a & b
    raise ValueError(funct3)


def branch_taken(funct3, a, b):
    a &= MASK
    b &= MASK
    return {
        0: a == b,                       # BEQ
        1: a != b,                       # BNE
        4: sx32(a) < sx32(b),            # BLT
        5: sx32(a) >= sx32(b),           # BGE
        6: a < b,                        # BLTU
        7: a >= b,                       # BGEU
    }[funct3]


# --- instruction encoders (rs1=1, rs2=2, rd=3), returning a uint32 word ---
def enc_r(funct7, funct3):
    return (funct7 << 25) | (2 << 20) | (1 << 15) | (funct3 << 12) | (3 << 7) | 0x33


def enc_i(funct3, imm):
    return ((imm & 0xFFF) << 20) | (1 << 15) | (funct3 << 12) | (3 << 7) | 0x13


def enc_i_shift(funct7, funct3, shamt):
    return (funct7 << 25) | ((shamt & 31) << 20) | (1 << 15) | (funct3 << 12) | (3 << 7) | 0x13


def enc_b(funct3, imm):
    imm &= 0x1FFF
    b12 = (imm >> 12) & 1
    b11 = (imm >> 11) & 1
    b10_5 = (imm >> 5) & 0x3F
    b4_1 = (imm >> 1) & 0xF
    return (b12 << 31) | (b10_5 << 25) | (2 << 20) | (1 << 15) | (funct3 << 12) | \
           (b4_1 << 8) | (b11 << 7) | 0x63


def enc_j(imm):
    imm &= 0x1FFFFF
    b20 = (imm >> 20) & 1
    b10_1 = (imm >> 1) & 0x3FF
    b11 = (imm >> 11) & 1
    b19_12 = (imm >> 12) & 0xFF
    return (b20 << 31) | (b10_1 << 21) | (b11 << 20) | (b19_12 << 12) | (3 << 7) | 0x6F


def enc_u(opcode, imm20):        # LUI=0x37, AUIPC=0x17; rd=x3
    return ((imm20 & 0xFFFFF) << 12) | (3 << 7) | opcode


def enc_jalr(imm):               # rs1=x2, funct3=0, rd=x3
    return ((imm & 0xFFF) << 20) | (2 << 15) | (0 << 12) | (3 << 7) | 0x67


def lui_val(imm20):
    return (imm20 << 12) & MASK


def auipc_val(imm20, pc):
    return (pc + (imm20 << 12)) & MASK


def jal_target(pc, imm):
    return (pc + imm) & MASK


def jalr_target(base, imm):      # low bit cleared per spec
    return (base + imm) & 0xFFFFFFFE


def sxb(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def dec_i_imm(w):
    return sxb((w >> 20) & 0xFFF, 12)


def dec_b_imm(w):
    imm = ((w >> 31 & 1) << 12) | ((w >> 7 & 1) << 11) | ((w >> 25 & 0x3F) << 5) | ((w >> 8 & 0xF) << 1)
    return sxb(imm, 13)


def dec_j_imm(w):
    imm = ((w >> 31 & 1) << 20) | ((w >> 21 & 0x3FF) << 1) | ((w >> 20 & 1) << 11) | ((w >> 12 & 0xFF) << 12)
    return sxb(imm, 21)


def lohi(v):
    """uint32 -> (low16, high16) as 4-hex-digit uppercase strings (muxleq is UPPER-hex only)."""
    v &= MASK
    return "%04X" % (v & 0xFFFF), "%04X" % ((v >> 16) & 0xFFFF)


# --- vector generation ---------------------------------------------------------
EDGES = [0x00000000, 0x00000001, 0x00000002, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF,
         0xFFFFFFFE, 0x55555555, 0xAAAAAAAA, 0x12345678, 0xDEADBEEF, 0x0000FFFF,
         0xFFFF0000, 0x00010000, 0x00008000, 0x0000000F]

# a compact but spanning cross set for the O(n^2) R-type ops (keeps the golden fast)
CROSS = [0x00000000, 0x00000001, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x55555555,
         0xAAAAAAAA, 0x12345678, 0x0000FFFF, 0xFFFF0000]
SHIFT_VALS = [0x00000001, 0x80000000, 0x12345678, 0xFFFFFFFF, 0xDEADBEEF, 0x0000FFFF]

R_OPS = [  # name, funct3, funct7
    ("ADD", 0, 0x00), ("SUB", 0, 0x20), ("SLT", 2, 0x00), ("SLTU", 3, 0x00),
    ("XOR", 4, 0x00), ("OR", 6, 0x00), ("AND", 7, 0x00),
]
I_OPS = [  # name, funct3  (ADDI/SLTI/SLTIU/XORI/ORI/ANDI)
    ("ADDI", 0), ("SLTI", 2), ("SLTIU", 3), ("XORI", 4), ("ORI", 6), ("ANDI", 7),
]
IMMS = [0x000, 0x001, 0x7FF, 0x800, 0xFFF, 0x555, 0xAAA]  # 12-bit, incl. sign boundary


def gen_rtype(out):
    out.append("\\ === R-type ALU: cross-product of edge operands (SLT/SLTU signed/unsigned) ===")
    for name, f3, f7 in R_OPS:
        il, ih = lohi(enc_r(f7, f3))
        for a in CROSS:
            for b in CROSS:
                w = alu(f3, f7, a, b)
                alo, ahi = lohi(a); blo, bhi = lohi(b); wlo, whi = lohi(w)
                out.append("%s %s %s %s %s %s %s %s chk  \\ %s a=%08X b=%08X" %
                           (alo, ahi, blo, bhi, il, ih, wlo, whi, name, a, b))


def gen_shifts(out):
    out.append("\\ === shifts SLL/SRL/SRA (R) and SLLI/SRLI/SRAI (I): every shamt 0..31 ===")
    # R-type shifts: rs2 supplies the amount (and >32 must mask to low 5 bits)
    for name, f3, f7 in [("SLL", 1, 0x00), ("SRL", 5, 0x00), ("SRA", 5, 0x20)]:
        il, ih = lohi(enc_r(f7, f3))
        for a in SHIFT_VALS:
            for sh in list(range(32)) + [32, 33, 63, 0xFF]:   # incl. amounts that must mask
                w = alu(f3, f7, a, sh)
                alo, ahi = lohi(a); blo, bhi = lohi(sh); wlo, whi = lohi(w)
                out.append("%s %s %s %s %s %s %s %s chk  \\ %s a=%08X sh=%d" %
                           (alo, ahi, blo, bhi, il, ih, wlo, whi, name, a, sh & 31))
    # I-type shifts: shamt is encoded in the instruction (0..31 only)
    for name, f3, f7 in [("SLLI", 1, 0x00), ("SRLI", 5, 0x00), ("SRAI", 5, 0x20)]:
        for a in SHIFT_VALS:
            for sh in range(32):
                il, ih = lohi(enc_i_shift(f7, f3, sh))
                w = alu(f3, f7, a, sh)
                alo, ahi = lohi(a); wlo, whi = lohi(w)
                out.append("%s %s 0000 0000 %s %s %s %s chk  \\ %s a=%08X sh=%d" %
                           (alo, ahi, il, ih, wlo, whi, name, a, sh))


def gen_itype(out):
    out.append("\\ === I-type ALU immediates (sign-extended 12-bit) ===")
    for name, f3 in I_OPS:
        for a in EDGES:
            for imm in IMMS:
                il, ih = lohi(enc_i(f3, imm))
                w = alu(f3, 0x00, a, sx32(imm if imm < 0x800 else imm - 0x1000))
                alo, ahi = lohi(a); wlo, whi = lohi(w)
                out.append("%s %s 0000 0000 %s %s %s %s chk  \\ %s a=%08X imm=%03X" %
                           (alo, ahi, il, ih, wlo, whi, name, a, imm))


def gen_branches(out):
    out.append("\\ === branches BEQ/BNE/BLT/BGE/BLTU/BGEU: taken -> pc+off, else pc+4 ===")
    pc = 0x100
    pairs = [(0x5, 0x5), (0x5, 0x6), (0x80000000, 0), (0, 0x80000000),
             (0xFFFFFFFF, 1), (1, 0xFFFFFFFF), (0x7FFFFFFF, 0x80000000)]
    offs = [8, 4, -8, 0x100, -0x100, 0xFFE, -0x1000]   # exercise the scrambled B-immediate too
    for name, f3 in [("BEQ", 0), ("BNE", 1), ("BLT", 4), ("BGE", 5), ("BLTU", 6), ("BGEU", 7)]:
        for off in offs:
            il, ih = lohi(enc_b(f3, off))
            for a, b in pairs:
                tgt = (pc + off) & MASK if branch_taken(f3, a, b) else pc + 4
                alo, ahi = lohi(a); blo, bhi = lohi(b)
                plo, phi = lohi(pc); tlo, thi = lohi(tgt)
                out.append("%s %s 01 seedr  %s %s 02 seedr  %s %s setpc" % (alo, ahi, blo, bhi, plo, phi))
                out.append("%s %s brun  %s %s chkpc  \\ %s a=%08X b=%08X off=%d" %
                           (il, ih, tlo, thi, name, a, b, off))


def gen_jal(out):
    out.append("\\ === JAL: RVPC=target, link x3=PC+4 (checked by chkj against 0x204) ===")
    pc = 0x200
    for off in [0x4, 0x2, 0x100, -0x100, 0x1000, 0x800, 0xFF000, -0x10, 0xFFFFE, -0x100000]:
        il, ih = lohi(enc_j(off))
        tgt = jal_target(pc, off)
        plo, phi = lohi(pc); tlo, thi = lohi(tgt)
        out.append("%s %s setpc  %s %s jrun  %s %s chkj  \\ JAL off=%d" %
                   (plo, phi, il, ih, tlo, thi, off))


def gen_jalr(out):
    out.append("\\ === JALR: RVPC=(x2+imm)&~1 (low bit cleared), link x3=0x204 ===")
    pc = 0x200
    for base in [0x400, 0x401, 0x1000, 0x0, 0xFFFE, 0x12344]:
        for imm in [0, 16, -4, 2047, -2048, 1, 3]:     # odd base/imm exercise the &~1 alignment
            il, ih = lohi(enc_jalr(imm))
            tgt = jalr_target(base, imm)
            blo, bhi = lohi(base); plo, phi = lohi(pc); tlo, thi = lohi(tgt)
            out.append("%s %s 02 seedr" % (blo, bhi))
            out.append("%s %s setpc  %s %s jrun  %s %s chkj  \\ JALR base=%08X imm=%d" %
                       (plo, phi, il, ih, tlo, thi, base, imm))


def gen_upper(out):
    out.append("\\ === upper immediates LUI (rd=imm20<<12) / AUIPC (rd=pc+imm20<<12) ===")
    imm20s = [0x00000, 0x00001, 0x7FFFF, 0x80000, 0xFFFFF, 0x12345, 0xABCDE, 0xFFFFE]
    for imm in imm20s:
        il, ih = lohi(enc_u(0x37, imm))
        wlo, whi = lohi(lui_val(imm))
        out.append("%s %s runi  %s %s eqx3  \\ LUI 0x%05X" % (il, ih, wlo, whi, imm))
    for imm in imm20s:
        for pc in [0x2000, 0x00001234, 0xFFFF0000]:
            il, ih = lohi(enc_u(0x17, imm))
            wlo, whi = lohi(auipc_val(imm, pc))
            plo, phi = lohi(pc)
            out.append("%s %s setpc  %s %s runi  %s %s eqx3  \\ AUIPC 0x%05X pc=%08X" %
                       (plo, phi, il, ih, wlo, whi, imm, pc))


def harness():
    """Extract ONLY the reusable harness from rv32i-spec.fth: `hex`, the WLO/WHI variables, and the
    complete `: ... ;` word definitions. Everything else there (vector lines AND the seedr/setpc
    setup lines that precede branch/jump vectors) must be excluded, or its orphan stack effects
    corrupt our run. A definition block runs from a line whose code starts with `:` to the line
    whose code ends with `;`. chkj checks x3==0x204, so JAL vectors use pc=0x200 (see gen_jal)."""
    here = os.path.dirname(os.path.abspath(__file__))
    spec = os.path.join(here, os.pardir, "tests", "rv32i-spec.fth")
    lines = ["hex", "variable WLO  variable WHI"]
    in_def, defs = False, 0
    for line in open(spec):
        s = line.rstrip("\n")
        code = s.split("\\", 1)[0].strip()
        if not in_def and code.startswith(":"):
            in_def = True
            defs += 1
        if in_def:
            lines.append(s)
            if ";" in code.split():          # `;` as a token (may trail a `( -- )` stack comment)
                in_def = False
    if defs < 9:
        sys.exit("error: expected 9 harness defs in rv32i-spec.fth, found %d -- did it change?" % defs)
    return lines


def _model_result(word, a, b):
    """The reference result for a `chk` (R/I-type ALU) instruction, x1=a, x2=b."""
    op = word & 0x7F
    f3 = (word >> 12) & 7
    f7 = (word >> 25) & 0x7F
    if op == 0x33:                        # R-type: b is rs2
        return alu(f3, f7, a, b)
    if op == 0x13:                        # I-type
        if f3 in (1, 5):                  # shift-immediate: shamt from bits[24:20]
            return alu(f3, f7, a, (word >> 20) & 31)
        return alu(f3, 0x00, a, dec_i_imm(word))
    return None


def verify_model():
    """Independence anchor: replay EVERY vector in the hand-written, Codex-verified rv32i-spec.fth
    against this reference model (not muxleq) and confirm each self-check would pass. This is a tiny
    stack interpreter for the harness vocabulary, so it validates the ALU model AND branch_taken /
    enc_b/enc_j decode / JAL / JALR / LUI / AUIPC -- every instruction type the spec covers. Memory
    ops (LB/LH/LW/SB/SH/SW) are skipped (no guest-memory model; rv32i-run.fth covers those live)."""
    here = os.path.dirname(os.path.abspath(__file__))
    spec = os.path.join(here, os.pardir, "tests", "rv32i-spec.fth")
    reg = {1: 0, 2: 0}
    pc = 0
    stack = []
    last = {}                             # result of the most recent brun/jrun/runi
    ok = bad = skip = 0
    in_def = False

    def fail(msg, line):
        print("MODEL MISMATCH (%s): %s" % (msg, line.strip()), file=sys.stderr)

    for line in open(spec):
        code = line.split("\\", 1)[0]
        stripped = code.strip()
        if not in_def and stripped.startswith(":"):   # skip whole `: ... ;` definition blocks
            in_def = True
        if in_def:
            if ";" in code.split():
                in_def = False
            continue
        if stripped in ("hex", "decimal", "bye", "decimal cr", "") or "variable" in code:
            continue
        for t in code.split():
            try:
                stack.append(int(t, 16)); continue
            except ValueError:
                pass
            if t == "seedr":
                idx = stack.pop(); hi = stack.pop(); lo = stack.pop()
                reg[idx] = (hi << 16) | lo
            elif t == "setpc":
                hi = stack.pop(); lo = stack.pop(); pc = (hi << 16) | lo
            elif t == "chk":
                whi = stack.pop(); wlo = stack.pop(); ih = stack.pop(); il = stack.pop()
                bhi = stack.pop(); blo = stack.pop(); ahi = stack.pop(); alo = stack.pop()
                got = _model_result((ih << 16) | il, (ahi << 16) | alo, (bhi << 16) | blo)
                want = (whi << 16) | wlo
                if got == want: ok += 1
                else: bad += 1; fail("chk got=%X want=%X" % (got, want), line)
            elif t in ("brun", "jrun", "runi"):
                ih = stack.pop(); il = stack.pop(); word = (ih << 16) | il
                op = word & 0x7F
                if op == 0x63:                                   # branch
                    taken = branch_taken((word >> 12) & 7, reg[1], reg[2])
                    last = {"pc": (pc + dec_b_imm(word)) & MASK if taken else pc + 4}
                elif op == 0x6F:                                 # JAL
                    last = {"pc": jal_target(pc, dec_j_imm(word)), "link": (pc + 4) & MASK}
                elif op == 0x67:                                 # JALR (rs1 from the word)
                    base = reg[(word >> 15) & 0x1F]
                    last = {"pc": jalr_target(base, dec_i_imm(word)), "link": (pc + 4) & MASK}
                elif op == 0x37:                                 # LUI
                    last = {"x3": word & 0xFFFFF000}
                elif op == 0x17:                                 # AUIPC
                    last = {"x3": (pc + (word & 0xFFFFF000)) & MASK}
                else:                                            # loads/stores: no memory model
                    last = {"skip": True}
            elif t == "chkpc":
                whi = stack.pop(); wlo = stack.pop(); want = (whi << 16) | wlo
                if last.get("pc") == want: ok += 1
                else: bad += 1; fail("chkpc got=%X want=%X" % (last.get("pc"), want), line)
            elif t == "chkj":                                    # ( pclo pchi -- ); link asserted ==0x204
                phi = stack.pop(); plo = stack.pop(); want = (phi << 16) | plo
                if last.get("pc") == want and last.get("link") == 0x204: ok += 1
                else: bad += 1; fail("chkj got=%X/%X want=%X/204" %
                                     (last.get("pc"), last.get("link"), want), line)
            elif t == "eqx3":
                whi = stack.pop(); wlo = stack.pop(); want = (whi << 16) | wlo
                if last.get("skip"): skip += 1
                elif last.get("x3") == want: ok += 1
                else: bad += 1; fail("eqx3 got=%X want=%X" % (last.get("x3"), want), line)
            # else: an unknown token (rvstep internals etc.) -- ignore
    print("model vs rv32i-spec.fth anchors: %d ok, %d mismatched, %d memory-skipped" %
          (ok, bad, skip), file=sys.stderr)
    return bad == 0


def main(argv):
    if "--verify-model" in argv:
        sys.exit(0 if verify_model() else 1)
    if not verify_model():
        sys.exit("refusing to generate: model disagrees with rv32i-spec.fth anchors")
    out = ["\\ RV32I conformance suite -- GENERATED by scripts/rv32i-conformance.py; do not edit.",
           "\\ Independent Python reference model vs the :a rvstep microcode, self-checking (OK/FAIL).",
           "\\ Regenerate: python3 scripts/rv32i-conformance.py > tests/rv32i-conform.fth"]
    out += harness()
    gen_rtype(out)
    gen_shifts(out)
    gen_itype(out)
    gen_branches(out)
    gen_jal(out)
    gen_jalr(out)
    gen_upper(out)
    out.append("decimal cr bye")
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv)
