#!/usr/bin/env python3
"""Independent RV32I base-ISA reference model (a plain transcription of the
spec). Emitter-independent: given decoded operands it returns the architectural
result of every RV32I base integer instruction, for differential testing of a
backend (scripts/rvopt-fuzz.py imports alu/sx32/branch_taken) against a source
of truth that shares no code with the backend under test.

Coverage -- the full RV32I base integer ISA:
  OP / OP-IMM   ADD SUB SLL SLT SLTU XOR SRL SRA OR AND (+ the immediate forms)
  LUI, AUIPC
  JAL, JALR     (branch target and pc+4 link)
  BRANCH        BEQ BNE BLT BGE BLTU BGEU
  LOAD          LB LH LW LBU LHU (width + sign/zero extension)
  STORE         SB SH SW         (width + low-byte value)
FENCE and SYSTEM (ECALL/EBREAK) transfer no register/memory value and are not
modeled here. Run `python3 scripts/rv32i-conformance.py` to self-check the model.

All operands and results are uint32 unless noted; immediates are passed already
sign-extended (Python ints), matching how a decoder hands them to the backend.
"""

MASK = 0xFFFFFFFF


def sx32(v):
    """Interpret a uint32 as signed."""
    v &= MASK
    return v - (1 << 32) if v & 0x80000000 else v


def sxb(v, bits):
    """Sign-extend the low `bits` bits of v to a Python int."""
    m = 1 << (bits - 1)
    v &= (1 << bits) - 1
    return (v ^ m) - m


# --- OP / OP-IMM: result of `rd = rs1 OP (rs2 | imm)`, all uint32 -------------
def alu(funct3, funct7, a, b):
    """R-type / I-type ALU. b is rs2 (R) or the sign-extended immediate (I).
    funct7 selects SUB (0x20) vs ADD and SRA (0x20) vs SRL for the shift slot."""
    a &= MASK
    b &= MASK
    sh = b & 31
    if funct3 == 0:  # ADD / SUB
        return (a - b if funct7 == 0x20 else a + b) & MASK
    if funct3 == 1:  # SLL
        return (a << sh) & MASK
    if funct3 == 2:  # SLT (signed)
        return 1 if sx32(a) < sx32(b) else 0
    if funct3 == 3:  # SLTU (unsigned)
        return 1 if a < b else 0
    if funct3 == 4:  # XOR
        return a ^ b
    if funct3 == 5:  # SRL / SRA
        if funct7 == 0x20:
            return (sx32(a) >> sh) & MASK
        return (a >> sh) & MASK
    if funct3 == 6:  # OR
        return a | b
    if funct3 == 7:  # AND
        return a & b
    raise ValueError(funct3)


# --- LUI / AUIPC: 20-bit upper immediate --------------------------------------
def lui(imm20):
    return (imm20 & 0xFFFFF) << 12


def auipc(pc, imm20):
    return (pc + lui(imm20)) & MASK


# --- JAL / JALR: taken target and the pc+4 link written to rd -----------------
def jal_target(pc, imm):
    return (pc + imm) & MASK


def jalr_target(rs1, imm):
    return (rs1 + imm) & MASK & ~1  # low bit cleared per spec


def link(pc):
    return (pc + 4) & MASK  # JAL/JALR write pc+4 to rd


# --- BRANCH: is the branch taken? ---------------------------------------------
def branch_taken(funct3, a, b):
    a &= MASK
    b &= MASK
    if funct3 == 0:  # BEQ
        return a == b
    if funct3 == 1:  # BNE
        return a != b
    if funct3 == 4:  # BLT
        return sx32(a) < sx32(b)
    if funct3 == 5:  # BGE
        return sx32(a) >= sx32(b)
    if funct3 == 6:  # BLTU
        return a < b
    if funct3 == 7:  # BGEU
        return a >= b
    raise ValueError(funct3)


# --- LOAD / STORE: width and the loaded/stored value --------------------------
_LOAD_BYTES = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}  # LB LH LW LBU LHU
_STORE_BYTES = {0: 1, 1: 2, 2: 4}  # SB SH SW


def load_bytes(funct3):
    return _LOAD_BYTES[funct3]


def load(funct3, raw):
    """raw = the little-endian unsigned value of load_bytes(funct3) memory bytes
    at the effective address; return the value written to rd (uint32)."""
    if funct3 == 0:  # LB
        return sxb(raw, 8) & MASK
    if funct3 == 1:  # LH
        return sxb(raw, 16) & MASK
    if funct3 == 2:  # LW
        return raw & MASK
    if funct3 == 4:  # LBU
        return raw & 0xFF
    if funct3 == 5:  # LHU
        return raw & 0xFFFF
    raise ValueError(funct3)


def store_bytes(funct3):
    return _STORE_BYTES[funct3]


def store(funct3, val):
    """Return the little-endian unsigned value of store_bytes(funct3) bytes that
    SB/SH/SW writes to memory (the low bits of rs2)."""
    return val & ((1 << (8 * _STORE_BYTES[funct3])) - 1)


def _selfcheck():
    # OP / OP-IMM
    assert alu(0, 0x00, 5, 7) == 12  # ADD
    assert alu(0, 0x20, 5, 7) == MASK - 1  # SUB -> -2
    assert alu(1, 0x00, 1, 31) == 0x80000000  # SLL
    assert alu(2, 0x00, MASK, 0) == 1 and alu(2, 0x00, 1, 0) == 0  # SLT (-1<0)
    assert alu(3, 0x00, MASK, 0) == 0  # SLTU (0xFFFFFFFF !< 0)
    assert alu(5, 0x00, 0x80000000, 4) == 0x08000000  # SRL
    assert alu(5, 0x20, 0x80000000, 4) == 0xF8000000  # SRA (sign fill)
    assert alu(4, 0, 0xF0, 0x0F) == 0xFF and alu(6, 0, 0xF0, 0x0F) == 0xFF
    assert alu(7, 0, 0xF0, 0x1F) == 0x10  # AND
    # LUI / AUIPC / JAL / JALR
    assert lui(0xABCDE) == 0xABCDE000
    assert auipc(0x1000, 1) == 0x2000
    assert jal_target(0x100, -8) == 0xF8 and link(0x100) == 0x104
    assert jalr_target(0x101, 4) == 0x104  # low bit cleared
    # BRANCH
    assert branch_taken(4, MASK, 0) and not branch_taken(6, MASK, 0)  # BLT vs BLTU
    assert branch_taken(5, 0, 0) and branch_taken(7, MASK, 0)  # BGE, BGEU
    # LOAD / STORE
    assert load(0, 0x80) == MASK - 0x7F  # LB 0x80 -> -128
    assert load(4, 0x80) == 0x80  # LBU
    assert load(1, 0x8000) == 0xFFFF8000 and load(5, 0x8000) == 0x8000  # LH/LHU
    assert load(2, 0xDEADBEEF) == 0xDEADBEEF  # LW
    assert store(0, 0x1234) == 0x34 and store(1, 0x12345678) == 0x5678  # SB/SH
    assert store(2, 0xDEADBEEF) == 0xDEADBEEF  # SW
    print("rv32i-conformance: model self-check OK")


if __name__ == "__main__":
    _selfcheck()
