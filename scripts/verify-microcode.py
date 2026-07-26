#!/usr/bin/env python3
"""Exhaustive symbolic proof of the RV32I 32-bit ADD/SUB/SLT/SLTU/SLL/SRL/SRA microcode.

muxleq runs RV32I on a 16-bit substrate, so a 32-bit register is two cells and the ALU microcode
(muxleq.fth, opt.rv32i) must synthesize each 32-bit op from 16-bit pieces by hand. rvadd/rvsub
derive the low->high carry/borrow from a majority vote of three sign bits:

    ADD carry  = 1 iff  MAJ( bit15(SRC1lo),  bit15(SRC2lo),  NOT bit15(sum_lo)  ) >= 2
    SUB borrow = 1 iff  MAJ( NOT bit15(SRC1lo), bit15(SRC2lo),  bit15(diff_lo)  ) >= 2

(the three VOTE+/VOTE- steps then `r0 DEC` then `r0 +if <hi> INC/DEC then` in the microcode).
The shifts have no native counterpart either: rvsll doubles both halves rvsh times spilling
bit15(lo) into hi bit0 (SHL1); rvsrl builds the result left-to-right pulling the source's top bit
down; rvsra brackets that with a conditional invert to sign-fill. SLTU compares high halves first (each
16-bit unsigned `<` is a SUB borrow-out vote) and falls to the low halves on a tie; SLT flips bit31
of both operands and reuses SLTU. This script models each op EXACTLY as the microcode computes it and
PROVES it equals the true 32-bit result (bvadd/bvsub, unsigned/signed `<`, and the shift operators
for every shamt 0..31) with Z3 -- the entire input space, where tests/rv32i-spec.fth and
scripts/rv32i-conformance.py can only SAMPLE. The microcode's history of sign/lane-boundary bugs
(the -if 0x8000 mis-sign, the SLL half-boundary spill) is exactly the bitvector-edge class SMT
settles once and for all; a mutation that drops the SHL1 spill is caught at shamt=1, src=0x8000.

    python3 scripts/verify-microcode.py      # PASS/FAIL per op; exit 1 on any FAIL or counterexample

Needs the z3 Python package (z3-solver). Host-side only -- no image, VM, or build involvement,
so it is a separate target (`make verify-microcode`), not part of `make check`.
"""
import sys

try:
    from z3 import (BitVec, BitVecVal, Concat, Extract, If, LShR, Solver, UGE, ULT, ZeroExt, sat,
                    unsat)
except ImportError:
    sys.exit("verify-microcode: needs the z3 Python package (pip install z3-solver)")

W = 16  # cell width in bits; an RV32I register is two of these (low, high)


def bit15(x):
    """Top bit of a W-bit cell as a 0/1 value, zero-extended back to W bits for summing."""
    return ZeroExt(W - 1, Extract(W - 1, W - 1, x))


def vote_ge2(a, b, c):
    """The microcode's `r0 ZERO / three votes / r0 DEC / r0 +if` = 1 iff at least two of a,b,c."""
    return If(UGE(a + b + c, 2), BitVecVal(1, W), BitVecVal(0, W))


def add_model(s1lo, s1hi, s2lo, s2hi):
    """rvadd: per-half add, carry = MAJ(bit15 s1lo, bit15 s2lo, NOT bit15 sum_lo)."""
    rslt_lo = s1lo + s2lo                                      # 16-bit wrap
    carry = vote_ge2(bit15(s1lo), bit15(s2lo), BitVecVal(1, W) - bit15(rslt_lo))
    rslt_hi = s1hi + s2hi + carry
    return Concat(rslt_hi, rslt_lo)


def sub_model(s1lo, s1hi, s2lo, s2hi):
    """rvsub: per-half subtract, borrow = MAJ(NOT bit15 s1lo, bit15 s2lo, bit15 diff_lo)."""
    rslt_lo = s1lo - s2lo                                      # 16-bit wrap
    borrow = vote_ge2(BitVecVal(1, W) - bit15(s1lo), bit15(s2lo), bit15(rslt_lo))
    rslt_hi = s1hi - s2hi - borrow
    return Concat(rslt_hi, rslt_lo)


def shl1(lo, hi):
    """The SHL1 microcode: shift the 32-bit (lo,hi) left one bit, spilling bit15(lo) into hi bit0."""
    return lo + lo, hi + hi + bit15(lo)


def sll_model(lo, hi, shamt):
    """rvsll: apply SHL1 shamt times (the microcode's doubling loop; shamt is pre-masked to 0..31)."""
    for _ in range(shamt):
        lo, hi = shl1(lo, hi)
    return lo, hi


def srl_model(lo, hi, shamt):
    """rvsrl: result starts 0; 32-shamt times, result <<= 1, then pull bit31 of the SRC1 copy into
    result bit0, then SRC1 copy <<= 1 -- so result ends holding SRC1's top 32-shamt bits, right-aligned
    = SRC1 >> shamt with zero fill. r2/r3 = SRC1 work copy in the microcode."""
    rlo, rhi = BitVecVal(0, W), BitVecVal(0, W)
    s_lo, s_hi = lo, hi
    for _ in range(32 - shamt):
        rlo, rhi = shl1(rlo, rhi)
        rlo = rlo + bit15(s_hi)                                   # rlo bit0 is 0 after shl1, so += is clean
        s_lo, s_hi = shl1(s_lo, s_hi)
    return rlo, rhi


def sra_model(lo, hi, shamt):
    """rvsra: the SRL loop bracketed by a conditional invert of SRC1 (before) and the result (after)
    when SRC1 < 0 -- inverting a negative operand makes the zero-filling SRL sign-fill instead."""
    neg = bit15(hi)                                              # bit31(SRC1)
    lo, hi = If(neg != 0, ~lo, lo), If(neg != 0, ~hi, hi)
    rlo, rhi = srl_model(lo, hi, shamt)
    return If(neg != 0, ~rlo, rlo), If(neg != 0, ~rhi, rhi)


def ult16(x, y):
    """16-bit `x < y` unsigned, computed the microcode's way: it is the SUB borrow-out, i.e.
    MAJ(NOT bit15 x, bit15 y, bit15(x - y)) >= 2. Returns a 0/1 value."""
    return vote_ge2(BitVecVal(1, W) - bit15(x), bit15(y), bit15(x - y))


def sltu_model(a_lo, a_hi, b_lo, b_hi):
    """rvsltu: high-half-first unsigned compare -- a_hi<b_hi -> 1; a_hi>b_hi -> 0; else a_lo<b_lo.
    Each 16-bit unsigned `<` is ult16 (the SUB-borrow vote). Result is a 0/1 word, hi half zero."""
    hi_lt = ult16(a_hi, b_hi)                     # a_hi < b_hi
    hi_gt = ult16(b_hi, a_hi)                     # b_hi < a_hi, i.e. a_hi > b_hi
    lo_lt = ult16(a_lo, b_lo)                     # low halves, only consulted when a_hi == b_hi
    rlo = If(hi_lt != 0, BitVecVal(1, W), If(hi_gt != 0, BitVecVal(0, W), lo_lt))
    return Concat(BitVecVal(0, W), rlo)


def slt_model(a_lo, a_hi, b_lo, b_hi):
    """rvslt: signed compare = unsigned compare after flipping bit31 of both operands (the microcode
    adds 0x8000 to each high half, which toggles bit15 = bit31 of the 32-bit value)."""
    flip = BitVecVal(0x8000, W)
    return sltu_model(a_lo, a_hi + flip, b_lo, b_hi + flip)


def prove_shift(name, model_fn, spec_fn):
    """Shift shamt is 0..31 and the microcode's loop count depends on it, so unroll each shift amount
    and prove microcode == spec over all 2^32 source words for every shamt."""
    lo, hi = BitVec("lo", W), BitVec("hi", W)
    src = Concat(hi, lo)
    for shamt in range(32):
        rlo, rhi = model_fn(lo, hi, shamt)
        s = Solver()
        s.add(Concat(rhi, rlo) != spec_fn(src, shamt))
        r = s.check()
        if r == unsat:
            continue
        if r == sat:
            m = s.model()
            print(f"FAIL  {name} shamt={shamt}: src={m[hi].as_long():#06x}{m[lo].as_long():04x}")
        else:
            print(f"UNKNOWN  {name} shamt={shamt}: Z3 returned {r}")
        return False
    print(f"PASS  {name}: microcode == spec for all 2^32 src, shamt 0..31")
    return True


def prove(name, model, spec, inputs):
    """UNSAT of (model != spec) proves equality over all inputs; a model is a counterexample."""
    s = Solver()
    s.add(model != spec)
    r = s.check()
    if r == unsat:
        print(f"PASS  {name}: microcode result == 32-bit spec for all 2^64 inputs")
        return True
    if r == sat:
        m = s.model()
        ce = ", ".join(f"{v}={m[v].as_long():#06x}" for v in inputs)
        print(f"FAIL  {name}: counterexample  {ce}")
    else:
        print(f"UNKNOWN  {name}: Z3 returned {r}")
    return False


def main():
    s1lo, s1hi, s2lo, s2hi = (BitVec(n, W) for n in ("s1lo", "s1hi", "s2lo", "s2hi"))
    inputs = [s1hi, s1lo, s2hi, s2lo]
    src1, src2 = Concat(s1hi, s1lo), Concat(s2hi, s2lo)        # the 32-bit operands
    ok = True
    ok &= prove("rvadd", add_model(s1lo, s1hi, s2lo, s2hi), src1 + src2, inputs)
    ok &= prove("rvsub", sub_model(s1lo, s1hi, s2lo, s2hi), src1 - src2, inputs)
    one32, zero32 = BitVecVal(1, 2 * W), BitVecVal(0, 2 * W)
    ok &= prove("rvsltu", sltu_model(s1lo, s1hi, s2lo, s2hi),            # unsigned set-less-than
                If(ULT(src1, src2), one32, zero32), inputs)
    ok &= prove("rvslt", slt_model(s1lo, s1hi, s2lo, s2hi),             # signed set-less-than
                If(src1 < src2, one32, zero32), inputs)
    ok &= prove_shift("rvsll", sll_model, lambda src, sh: src << sh)     # logical left
    ok &= prove_shift("rvsrl", srl_model, lambda src, sh: LShR(src, sh)) # logical right (zero fill)
    ok &= prove_shift("rvsra", sra_model, lambda src, sh: src >> sh)     # arithmetic right (sign fill)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
