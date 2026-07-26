opt.rv32i [if]
\ Negation-safe bit15 test: leaves r1 so 'r1 +if' fires iff bit15(a) is set. Masks a with 0x8000
\ (MUX/AND -> exactly 0 or 0x8000) then DEC (0x8000->0x7FFF>0 fires, 0->-1 doesn't). Avoids '-if',
\ which mis-signs 0x8000 because its own negation overflows. Clobbers r1.
:m RVBIT15 r1 MMOV  r1 zreg rvsign MUXR  r1 DEC ;m  ( a -- )
\ The next three macros emit assembler.1 control flow (+if/else/then), which a :m macro can't see
\ under the default meta.1-only search order. Bracket their definitions with assembler.1 in scope;
\ get-order/set-order restore the search order exactly, whatever it was on entry.
get-order assembler.1 +order
\ Shift a 32-bit value (cells 'lo/'hi) left by one bit, injecting the bit15 spill from lo into hi.
:m SHL1 ( 'lo 'hi -- )  swap dup RVBIT15  dup ADD  dup dup ADD  r1 +if swap INC then ;m
\ ADD/SUB carry majority-vote step: add bit15('src) (VOTE+) or NOT bit15('src) (VOTE-) to counter r0.
:m VOTE+ ( 'src -- )  RVBIT15  r1 +if r0 INC then ;m
:m VOTE- ( 'src -- )  RVBIT15  r1 +if else r0 INC then ;m
set-order
\ Point r1 at reg[rvidx].lo: halved base + 2*rvidx (each register is two cells). Clobbers r1.
:m RVPTR rvbase r1 MMOV  rvidx r1 ADD  rvidx r1 ADD ;m  ( -- )
\ Invert cell a in place (a = ~a = -1 - a). Clobbers r0. No control flow, so it can be a macro.
:m RVINV  neg1 r0 MMOV  dup r0 SUB  r0 swap MMOV ;m  ( a -- )

\ Recurring op bodies are factored into a macro shared across routines: RVRD-BODY by both the kept
\ 'rvrd' standalone and 'rvrd.sub', RVAND-BODY/RVRD2-BODY by just the '.sub' form. None has an
\ internal label, so a macro can expand into multiple routines without a label collision.
:m RVAND-BODY rvs1lo rvrlo MMOV  rvrlo zreg rvs2lo MUXR  rvs1hi rvrhi MMOV  rvrhi zreg rvs2hi MUXR ;m
:m RVRD-BODY  RVPTR  rvs1lo r1 iLOAD  r1 INC  rvs1hi r1 iLOAD ;m
:m RVRD2-BODY RVPTR  rvs2lo r1 iLOAD  r1 INC  rvs2hi r1 iLOAD ;m
\ rvwr's body uses '+if'/'then', so bracket its definition with assembler.1 in scope (see SHL1 above).
get-order assembler.1 +order
:m RVWR-BODY  RVPTR  rvidx +if  rvrlo r1 iSTORE  r1 INC  rvrhi r1 iSTORE  then ;m
set-order

:a rvand.sub RVAND-BODY rvlink iJMP (a);   ( RV32I: RSLT = SRC1 & SRC2, one same-lane MUX/half; -> Mem[rvlink] )

\ ADD: RSLT = SRC1 + SRC2. Per-half add + a low->high carry = MAJ(bit15 SRC1lo, bit15 SRC2lo,
\ NOT bit15 sum_lo); >=2 votes -> carry, so increment the high half. VOTE+ counts a set bit15,
\ VOTE- a clear one; 'r0 ZERO / three votes / r0 DEC / +if' fires iff at least two voted.
:a rvadd.sub                       ( RV32I: RSLT = SRC1 + SRC2, 32-bit cross-cell carry; -> Mem[rvlink] )
  rvs1lo rvrlo MMOV  rvs2lo rvrlo ADD  rvs1hi rvrhi MMOV  rvs2hi rvrhi ADD
  r0 ZERO
  rvs1lo VOTE+
  rvs2lo VOTE+
  rvrlo  VOTE-
  r0 DEC  r0 +if rvrhi INC then  rvlink iJMP (a);

\ SUB: RSLT = SRC1 - SRC2. Per-half SUBLEQ subtract + a low->high borrow. Borrow-out of the low half
\ = MAJ(NOT bit15(a), bit15(b), bit15(diff)) -- the mirror of ADD's carry (a>=0 vote instead of a<0,
\ diff-sign instead of NOT sum-sign); >=2 votes -> borrow, so decrement the high half.
:a rvsub.sub
  rvs1lo rvrlo MMOV  rvs2lo rvrlo SUB  rvs1hi rvrhi MMOV  rvs2hi rvrhi SUB
  r0 ZERO
  rvs1lo VOTE-                                 \ + NOT bit15(a_lo)
  rvs2lo VOTE+                                 \ + bit15(b_lo)
  rvrlo  VOTE+                                 \ + bit15(diff_lo)
  r0 DEC  r0 +if rvrhi DEC then  rvlink iJMP (a);

\ SLL: RSLT = SRC1 << rvsh (logical, rvsh pre-masked to 0..31). Shift left by one rvsh times,
\ doubling both halves and spilling bit15(lo) into hi bit0 (SHL1). Bits genuinely cross the two
\ 16-bit lanes -- not a MUX win.
:a rvsll.sub                       ( RV32I: RSLT = SRC1 << rvsh, logical; -> Mem[rvlink] )
  rvs1lo rvrlo MMOV  rvs1hi rvrhi MMOV  rvsh r0 MMOV
  label: rvsll.sub.loop
  r0 +if
    rvrlo rvrhi SHL1
    r0 DEC  rvsll.sub.loop JMP
  then  rvlink iJMP (a);

\ SRL: RSLT = SRC1 >> shamt (logical, zero-fill). No native right shift, so build it left-to-right:
\ result starts 0, and for 32-shamt iterations we shift result left one bit and pull SRC1's current
\ top bit (bit31 = bit15 of the high half) into result bit0, while shifting the SRC1 copy left. After
\ the loop result holds SRC1's top 32-shamt bits, right-aligned = SRC1 >> shamt, top shamt bits zero.
\ r2/r3 = SRC1 work copy, r0 = count, r1 = RVBIT15 temp. shamt = reg[rs2] & 0x1F.
:a rvsrl.sub
  rvs2lo rvsh MMOV  rvsh zreg rv1f MUXR         \ shamt = reg[rs2] & 0x1F
  rvc32 r0 MMOV  rvsh r0 SUB                     \ count = 32 - shamt
  rvrlo ZERO  rvrhi ZERO
  rvs1lo r2 MMOV  rvs1hi r3 MMOV
  label: rvsrl.loop
  r0 +if
    rvrlo rvrhi SHL1                              \ result <<= 1
    r3 RVBIT15  r1 +if rvrlo INC then             \ pull bit31(SRC1) into result bit0
    r2 r3 SHL1                                    \ SRC1 copy <<= 1
    r0 DEC  rvsrl.loop JMP
  then  rvlink iJMP (a);

\ SRA: arithmetic right shift. SRA(v,s) = SRL(v,s) if v>=0, else ~SRL(~v,s) -- inverting a negative
\ operand makes it non-negative, the zero-filled SRL then leaves the top bits clear, and inverting
\ back sign-fills them. Same loop as SRL (distinct label), bracketed by a conditional invert of SRC1
\ (before) and the result (after), guarded by rvneg = original sign of SRC1.
:a rvsra.sub
  rvs1hi RVBIT15  r1 +if one rvneg MMOV else zreg rvneg MMOV then   \ rvneg = bit31(SRC1)
  rvneg r0 MMOV  r0 +if  rvs1lo RVINV  rvs1hi RVINV  then           \ if negative, SRC1 = ~SRC1
  rvs2lo rvsh MMOV  rvsh zreg rv1f MUXR                             \ shamt = reg[rs2] & 0x1F
  rvc32 r0 MMOV  rvsh r0 SUB                                        \ count = 32 - shamt
  rvrlo ZERO  rvrhi ZERO
  rvs1lo r2 MMOV  rvs1hi r3 MMOV
  label: rvsra.loop
  r0 +if
    rvrlo rvrhi SHL1                              \ result <<= 1
    r3 RVBIT15  r1 +if rvrlo INC then             \ pull bit31(SRC1) into result bit0
    r2 r3 SHL1                                    \ SRC1 copy <<= 1
    r0 DEC  rvsra.loop JMP
  then
  rvneg r0 MMOV  r0 +if  rvrlo RVINV  rvrhi RVINV  then             \ if negative, result = ~result
  rvlink iJMP (a);

\ SLTU: RSLT = (SRC1 < SRC2 unsigned) ? 1 : 0. High-half-first: if a_hi < b_hi -> 1; if a_hi > b_hi
\ -> 0; if a_hi == b_hi -> a_lo < b_lo. Each 16-bit "x < y unsigned" is the SUB borrow:
\ MAJ(NOT bit15 x, bit15 y, bit15 (x - y)) -- >=2 of the 3 votes. r2/r3 hold the 16-bit differences,
\ r0 the vote count, r1 the RVBIT15 temp. (SLT reuses this after flipping both operands' bit31.)
:a rvsltu.sub
  rvs1hi r2 MMOV  rvs2hi r2 SUB                 \ r2 = a_hi - b_hi
  r0 ZERO
  rvs1hi RVBIT15  r1 +if else r0 INC then       \ + NOT bit15(a_hi)
  rvs2hi RVBIT15  r1 +if r0 INC then            \ + bit15(b_hi)
  r2 RVBIT15  r1 +if r0 INC then                \ + bit15(a_hi - b_hi)
  r0 DEC  r0 +if                                \ a_hi < b_hi -> result 1
    one rvrlo MMOV  zreg rvrhi MMOV
  else
    rvs2hi r3 MMOV  rvs1hi r3 SUB               \ r3 = b_hi - a_hi
    r0 ZERO
    rvs2hi RVBIT15  r1 +if else r0 INC then     \ + NOT bit15(b_hi)
    rvs1hi RVBIT15  r1 +if r0 INC then          \ + bit15(a_hi)
    r3 RVBIT15  r1 +if r0 INC then              \ + bit15(b_hi - a_hi)
    r0 DEC  r0 +if                              \ a_hi > b_hi -> result 0
      zreg rvrlo MMOV  zreg rvrhi MMOV
    else                                        \ a_hi == b_hi -> compare low halves unsigned
      rvs1lo r2 MMOV  rvs2lo r2 SUB             \ r2 = a_lo - b_lo
      r0 ZERO
      rvs1lo RVBIT15  r1 +if else r0 INC then
      rvs2lo RVBIT15  r1 +if r0 INC then
      r2 RVBIT15  r1 +if r0 INC then
      r0 DEC  r0 +if  one rvrlo MMOV  else  zreg rvrlo MMOV  then
      zreg rvrhi MMOV
    then
  then
  rvlink iJMP (a);

\ OR: RSLT = SRC1 | SRC2. 'A B M MUXR' = Mem[A] = (Mem[B]&~Mem[M])|(Mem[A]&Mem[M]); with A=RSLT(=a),
\ B=SRC2(b), M=SRC1(a) this is (b&~a)|(a&a) = a|b -- one MUX per half (a MUX win, like AND).
:a rvor.sub
  rvs1lo rvrlo MMOV  rvrlo rvs2lo rvs1lo MUXR
  rvs1hi rvrhi MMOV  rvrhi rvs2hi rvs1hi MUXR  rvlink iJMP (a);

\ XOR: RSLT = SRC1 ^ SRC2 = (a|b) - (a&b). At each bit (a|b) >= (a&b), so the 16-bit subtract never
\ borrows across bits -- it is exactly the bitwise XOR. Two MUX (OR, AND into rvtmp) + a SUB per half.
:a rvxor.sub
  rvs1lo rvrlo MMOV  rvrlo rvs2lo rvs1lo MUXR       \ rvrlo = a | b
  rvs1lo rvtmp MMOV  rvtmp zreg rvs2lo MUXR         \ rvtmp = a & b
  rvtmp rvrlo SUB                                   \ rvrlo = (a|b) - (a&b) = a ^ b
  rvs1hi rvrhi MMOV  rvrhi rvs2hi rvs1hi MUXR
  rvs1hi rvtmp MMOV  rvtmp zreg rvs2hi MUXR
  rvtmp rvrhi SUB  rvlink iJMP (a);

\ Indexed register access. reg[i] occupies two consecutive cells (low, high) at halved address
\ rvbase + 2*i; build the pointer in r1 (rvbase + rvidx + rvidx), then iLOAD/iSTORE + INC walk it.
:a rvrd  RVRD-BODY  ;a              ( RV32I: SRC1 = reg[rvidx], both halves )
:a rvrd.sub  RVRD-BODY  rvlink iJMP (a);   ( callable read into SRC1 )

:a rvrd2.sub RVRD2-BODY rvlink iJMP (a);   ( RV32I: SRC2 = reg[rvidx], both halves; -> Mem[rvlink] )

:a rvwr      RVWR-BODY ;a           ( RV32I: reg[rvidx] = RSLT; writes to x0 are discarded )
:a rvwr.sub  RVWR-BODY rvlink iJMP (a);   ( callable write of RSLT: returns to Mem[rvlink] )

\ Decode workhorse: rvrlo = (rvs1lo >> rvsh) & rvmask -- extract one instruction field. Right shift
\ is done the SLL way in reverse: loop 16-rvsh times pulling the source's top bit down into r1, so
\ after the loop r1 holds the top 16-rvsh bits = source >> rvsh (the 'shift' primitive's trick).
\ Requires rvsh in 0..15 (every RV32I field shift is a constant < 16); other values are misuse --
\ 16-bit wraparound of 16-rvsh makes them undefined, not a guaranteed zero. Uses r3 for the bit15
\ test, not RVBIT15, since RVBIT15 clobbers r1 (the result accumulator).
:a rvfield.sub                     ( RV32I: rvrlo = field of rvs1lo per rvsh/rvmask; -> Mem[rvlink] )
  bwidth r0 MMOV  rvsh r0 SUB  rvs1lo r2 MMOV  r1 ZERO
  label: rvfield.sub.loop
  r0 +if
    r1 r1 ADD
    r2 r3 MMOV  r3 zreg rvsign MUXR  r3 DEC  r3 +if r1 INC then
    r2 r2 ADD  r0 DEC  rvfield.sub.loop JMP
  then
  r1 zreg rvmask MUXR  r1 rvrlo MMOV  rvlink iJMP (a);

\ rvstep: a SINGLE microcode entry that executes one RV32I ALU instruction over the register file,
\ from a raw 32-bit word in rvil/rvih. It decodes the fields with eight rvfield.sub calls (rd, funct3,
\ rs2, rs1 in two pieces, rvo-alt=funct7 bit5=instr bit 30, opcode, imm[11:0]), loads rs1 with rvrd,
\ then sets SRC2 by opcode: R-type (0x33) reads reg[rs2] with rvrd2.sub; I-type (0x13) uses the
\ sign-extended imm[11:0] (and forces rvo-alt=0 for funct3!=5, since only SRLI/SRAI use funct7). It
\ dispatches on funct3 to the matching op '.sub', then stores the result with rvwr. The same ALU subs
\ serve R- and I-type. LOAD (0x03) and STORE (0x23) short-circuit before the ALU dispatch: EA =
\ reg[rs1] + sign-extended immediate via rvadd.sub, guest RAM is one LE halfword per cell, and the
\ cell index is (EA >> 1) & rvrammask with byte parity EA & 1. A funct3 dispatch handles every width:
\ LB/LH/LW/LBU/LHU load with sign- or zero-extension, SB/SH/SW store (SB read-modify-writes the one
\ byte selected by parity). Supported: R-type ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND, their I-type
\ immediates ADDI/SLLI/SLTI/SLTIU/XORI/SRLI/SRAI/ORI/ANDI, and all RV32I loads/stores. Misaligned
\ half/word access is unsupported. Unknown opcodes and R-type M-extension (funct7 bit0) TRAP
\ (rvstate=2); even-but-illegal funct7 and out-of-range shift immediates still alias -- see the
\ encoding-trap block; real toolchains never emit those.
:a rvstep
  zreg rvstate MMOV                              \ clear the host-syscall signal; only ECALL sets it
  \ decode: rd = ir_lo >> 7 & 0x1F
  rvil rvs1lo MMOV  rvc7 rvsh MMOV  rv1f rvmask MMOV
  rvr7 rvlink MMOV  t' rvfield.sub JMP  label: rvd1   rvrlo rvo-rd MMOV
  \ decode: funct3 = ir_lo >> 12 & 0x7
  rvil rvs1lo MMOV  rvc12 rvsh MMOV  rvc7 rvmask MMOV
  rvr8 rvlink MMOV  t' rvfield.sub JMP  label: rvd2   rvrlo rvo-funct3 MMOV
  \ rs2 = ir_hi >> 4 & 0x1F is derived from rvo-imm below (same ir_hi>>4 field), saving a rvfield.sub.
  \ decode: rs1 = (ir_hi & 0xF) << 1 | bit15(ir_lo)  (straddles the 16-bit cell boundary).
  \ ir_hi & 0xF is a direct mask (shift 0 would loop rvfield.sub 16 times for a pure mask).
  rvih rvo-rs1 MMOV  rvo-rs1 zreg rvc15 MUXR
  rvo-rs1 rvo-rs1 ADD                            \ rs1_hi << 1
  rvil rvs1lo MMOV  rvc15 rvsh MMOV  one rvmask MMOV
  rvr11 rvlink MMOV  t' rvfield.sub JMP  label: rvd5  rvrlo rvo-rs1 ADD  \ OR in bit15(ir_lo)
  \ decode: rvo-alt = instr bit 30 as a positive flag  (ADD/SUB, SRL/SRA discriminator)
  rvih rvo-alt MMOV  rvo-alt zreg rvc4000 MUXR
  \ decode: opcode = ir_lo & 0x7F  (0x33 = R-type register-register, 0x13 = I-type immediate).
  \ Direct mask, not rvfield.sub: a shift of 0 makes rvfield.sub loop 16-0 = 16 times to reconstruct
  \ the whole word before masking -- its single most expensive call, on the hot per-instruction path.
  rvil rvo-op MMOV  rvo-op zreg rvc7f MUXR
  \ decode: imm[11:0] = ir_hi >> 4 & 0xFFF  (I-type immediate, sign bit = imm[11] = bit15(ir_hi))
  rvih rvs1lo MMOV  rvc4 rvsh MMOV  rvcfff rvmask MMOV
  rvr21 rvlink MMOV  t' rvfield.sub JMP  label: rvd8  rvrlo rvo-imm MMOV
  rvo-imm rvo-rs2 MMOV  rvo-rs2 zreg rv1f MUXR  \ rs2 = imm & 0x1F (both are ir_hi >> 4)
  \ rvo-itype = (opcode == 0x13) ? 1 : 0
  zreg rvo-itype MMOV  rvo-op r0 MMOV  rvc13 r0 SUB
  r0 +if else r0 -if else  one rvo-itype MMOV  then then
  \ rvo-mem = (opcode == 0x03 LOAD || opcode == 0x23 STORE) ? 1 : 0
  zreg rvo-mem MMOV
  rvo-op r0 MMOV  rvc3 r0 SUB   r0 +if else r0 -if else  one rvo-mem MMOV  then then
  rvo-op r0 MMOV  rvc35 r0 SUB  r0 +if else r0 -if else  one rvo-mem MMOV  then then
  \ rvo-jmp = (opcode == 0x6F JAL || opcode == 0x67 JALR) ? 1 : 0
  zreg rvo-jmp MMOV
  rvo-op r0 MMOV  rvc111 r0 SUB  r0 +if else r0 -if else  one rvo-jmp MMOV  then then
  rvo-op r0 MMOV  rvc103 r0 SUB  r0 +if else r0 -if else  one rvo-jmp MMOV  then then
  \ rvo-uop = (opcode == 0x37 LUI || opcode == 0x17 AUIPC) ? 1 : 0
  zreg rvo-uop MMOV
  rvo-op r0 MMOV  rvc55 r0 SUB  r0 +if else r0 -if else  one rvo-uop MMOV  then then
  rvo-op r0 MMOV  rvc23 r0 SUB  r0 +if else r0 -if else  one rvo-uop MMOV  then then
  \ rvo-ctrl = (opcode == 0x63 BRANCH || rvo-jmp) ? 1 : 0  -- the runner leaves RVPC alone when set
  rvo-jmp rvo-ctrl MMOV
  rvo-op r0 MMOV  rvc99 r0 SUB  r0 +if else r0 -if else  one rvo-ctrl MMOV  then then
  \ execute
  rvo-rs1 rvidx MMOV
  rvr1 rvlink MMOV  t' rvrd.sub  JMP  label: rvs1p   \ SRC1 = reg[rs1]
  \ memory opcodes (LOAD 0x03 / STORE 0x23) short-circuit the ALU path: aligned LW/SW only.
  \ EA = reg[rs1] + sign-extended immediate; guest RAM is one LE halfword per cell, so an aligned
  \ word is two consecutive cells at cell index (EA >> 1) & rvrammask. Sub-word and misaligned
  \ access are unsupported here. High address bits above the RAM window wrap by the mask.
  rvo-mem r0 MMOV  r0 +if
    \ SRC2 = sign-extended memory immediate: I-imm for LOAD; S-imm = imm[11:5]|imm[4:0] for STORE.
    \ imm[11:5] = rvo-imm & 0xFE0 already sits in place; imm[4:0] = rd; sign bit = bit15(ir_hi).
    rvo-imm rvs2lo MMOV                          \ LOAD default; STORE rewrites below
    rvo-op r0 MMOV  rvc35 r0 SUB
    r0 +if else r0 -if else
      rvs2lo zreg rvcfe0 MUXR  rvo-rd rvs2lo ADD  \ rvs2lo still = rvo-imm, so mask+OR in place
    then then
    rvih RVBIT15  r1 +if
      rvcf000 rvs2lo ADD  neg1 rvs2hi MMOV
    else
      zreg rvs2hi MMOV
    then
    rvr22 rvlink MMOV  t' rvadd.sub JMP  label: rvm1   \ RSLT = EA = reg[rs1] + imm
    \ byte parity = EA_lo & 1 (which byte in the cell); cell index = (EA_lo >> 1) & rvrammask
    rvrlo rvparity MMOV  rvparity zreg one MUXR
    rvrlo rvs1lo MMOV  one rvsh MMOV  rvrammask rvmask MMOV
    rvr23 rvlink MMOV  t' rvfield.sub JMP  label: rvm2
    rvrambase rvmaddr MMOV  rvrlo rvmaddr ADD
    \ access width = funct3 & 3 (0 byte, 1 half, 2 word); unsigned-load flag = funct3 & 4
    rvo-funct3 rvwidth MMOV  rvwidth zreg rvc3 MUXR
    rvo-funct3 rvuns MMOV    rvuns zreg rvc4 MUXR
    rvo-op r0 MMOV  rvc3 r0 SUB
    r0 +if else r0 -if else
      \ LOAD: build reg[rd] lo/hi per width, then write once. rvmw = cell[idx].
      rvmaddr r1 MMOV  rvmw r1 iLOAD
      rvwidth r0 MMOV  rvc2 r0 SUB                 \ width 2 -> LW: two cells
      r0 +if else r0 -if else
        rvmw rvrlo MMOV  rvmaddr r1 MMOV  r1 INC  rvrhi r1 iLOAD
      then then
      rvwidth r0 MMOV  one r0 SUB                  \ width 1 -> LH / LHU: whole cell
      r0 +if else r0 -if else
        rvmw rvrlo MMOV
        rvuns r0 MMOV  r0 +if  zreg rvrhi MMOV
        else  rvmw RVBIT15  r1 +if  neg1 rvrhi MMOV  else  zreg rvrhi MMOV  then  then
      then then
      rvwidth r0 MMOV                              \ width 0 -> LB / LBU: byte by parity
      r0 +if else r0 -if else
        rvparity r0 MMOV  r0 +if  rvc8 rvsh MMOV  else  zreg rvsh MMOV  then
        rvmw rvs1lo MMOV  rvcff rvmask MMOV
        rvr26 rvlink MMOV  t' rvfield.sub JMP  label: rvm5   \ rvrlo = (cell >> parity*8) & 0xFF
        rvuns r0 MMOV  r0 +if  zreg rvrhi MMOV
        else
          rvrlo r0 MMOV  r0 zreg rvc128 MUXR  r0 +if   \ bit7 set -> sign-extend
            rvcff00 rvrlo ADD  neg1 rvrhi MMOV
          else  zreg rvrhi MMOV  then
        then
      then then
      rvo-rd rvidx MMOV
      rvr24 rvlink MMOV  t' rvwr.sub JMP  label: rvm3
      vm JMP
    then then
    \ STORE: read reg[rs2], then write memory per width (SW two cells, SH one, SB RMW one byte)
    rvo-rs2 rvidx MMOV
    rvr25 rvlink MMOV  t' rvrd2.sub JMP  label: rvm4   \ rvs2 = reg[rs2], clobbers r1
    rvo-funct3 r0 MMOV  rvc2 r0 SUB                \ width 2 -> SW
    r0 +if else r0 -if else
      rvmaddr r1 MMOV  rvs2lo r1 iSTORE  r1 INC  rvs2hi r1 iSTORE  vm JMP
    then then
    rvo-funct3 r0 MMOV  one r0 SUB                 \ width 1 -> SH
    r0 +if else r0 -if else
      rvmaddr r1 MMOV  rvs2lo r1 iSTORE  vm JMP
    then then
    \ width 0 -> SB: read-modify-write the one byte selected by parity
    rvmaddr r1 MMOV  rvmw r1 iLOAD
    rvparity r0 MMOV  r0 +if
      rvmw zreg rvcff MUXR                         \ keep cell low byte, clear high
      rvs2lo rvtmp MMOV
      rvtmp rvtmp ADD  rvtmp rvtmp ADD  rvtmp rvtmp ADD  rvtmp rvtmp ADD
      rvtmp rvtmp ADD  rvtmp rvtmp ADD  rvtmp rvtmp ADD  rvtmp rvtmp ADD   \ rvtmp = rs2 low byte << 8
      rvtmp rvmw ADD
    else
      rvmw rvs2lo rvcff00 MUXR                     \ low byte from rs2, keep cell high byte
    then
    rvmaddr r1 MMOV  rvmw r1 iSTORE  vm JMP
  then
  \ BRANCH (opcode 0x63): compare reg[rs1],reg[rs2] by funct3, set RVPC = taken ? RVPC+Bimm : RVPC+4.
  \ B-imm bits 12|10:5|4:1|11 are scrambled; sign bit = ir_hi[15]. RVPC is a 32-bit byte address.
  rvo-op r0 MMOV  rvc99 r0 SUB
  r0 +if else r0 -if else
    rvo-rs2 rvidx MMOV
    rvr30 rvlink MMOV  t' rvrd2.sub JMP  label: rvb4   \ SRC2 = reg[rs2]; SRC1 = reg[rs1] already loaded
    \ eq = (SRC1 == SRC2): rvtmp starts 1, cleared if either half differs. A difference is nonzero iff
    \ it is >0 (+if) or has bit15 set (RVBIT15) -- covers 0x8000, which -if/'if' mis-handle.
    one rvtmp MMOV
    rvs1lo r0 MMOV  rvs2lo r0 SUB
    r0 +if  zreg rvtmp MMOV  then   r0 RVBIT15  r1 +if  zreg rvtmp MMOV  then
    rvs1hi r0 MMOV  rvs2hi r0 SUB
    r0 +if  zreg rvtmp MMOV  then   r0 RVBIT15  r1 +if  zreg rvtmp MMOV  then
    \ ltuns = unsigned(SRC1 < SRC2)
    rvr32 rvlink MMOV  t' rvsltu.sub JMP  label: rvb6
    rvrlo rvmw MMOV
    \ ltsig = signed(SRC1 < SRC2): flip bit31 of both hi halves, then unsigned-compare. No flip-back --
    \ SRC1/SRC2 are dead after this (reloaded for the B-imm decode and PC add below).
    rvsign rvs1hi ADD  rvsign rvs2hi ADD
    rvr31 rvlink MMOV  t' rvsltu.sub JMP  label: rvb5
    rvrlo rvneg MMOV
    \ select taken by funct3: 0 BEQ, 1 BNE, 4 BLT, 5 BGE, 6 BLTU, 7 BGEU
    zreg rvtaken MMOV
    rvo-funct3 r0 MMOV                r0 +if else r0 -if else  rvtmp rvtaken MMOV  then then
    rvo-funct3 r0 MMOV  one r0 SUB    r0 +if else r0 -if else  one rvtaken MMOV  rvtmp rvtaken SUB  then then
    rvo-funct3 r0 MMOV  rvc4 r0 SUB   r0 +if else r0 -if else  rvneg rvtaken MMOV  then then
    rvo-funct3 r0 MMOV  rvc5 r0 SUB   r0 +if else r0 -if else  one rvtaken MMOV  rvneg rvtaken SUB  then then
    rvo-funct3 r0 MMOV  rvc6 r0 SUB   r0 +if else r0 -if else  rvmw rvtaken MMOV  then then
    rvo-funct3 r0 MMOV  rvc7 r0 SUB   r0 +if else r0 -if else  one rvtaken MMOV  rvmw rvtaken SUB  then then
    \ decode B-imm into rvbimmlo/rvbimmhi
    zreg rvbimmlo MMOV
    rvil rvs1lo MMOV  rvc7 rvsh MMOV  rvc1e rvmask MMOV
    rvr27 rvlink MMOV  t' rvfield.sub JMP  label: rvb1   rvrlo rvbimmlo ADD  \ imm[4:1]
    rvih rvs1lo MMOV  rvc4 rvsh MMOV  rvc7e0 rvmask MMOV
    rvr28 rvlink MMOV  t' rvfield.sub JMP  label: rvb2   rvrlo rvbimmlo ADD  \ imm[10:5]
    rvil rvs1lo MMOV  rvc7 rvsh MMOV  one rvmask MMOV
    rvr29 rvlink MMOV  t' rvfield.sub JMP  label: rvb3                       \ bit11 = ir_lo[7]
    rvrlo r0 MMOV  r0 +if  rvc800 rvbimmlo ADD  then
    rvih RVBIT15  r1 +if  rvcf000 rvbimmlo ADD  neg1 rvbimmhi MMOV  else  zreg rvbimmhi MMOV  then
    \ RVPC = RVPC + (taken ? Bimm : 4) via rvadd.sub
    rvpclo rvs1lo MMOV  rvpchi rvs1hi MMOV
    rvtaken r0 MMOV  r0 +if
      rvbimmlo rvs2lo MMOV  rvbimmhi rvs2hi MMOV
    else
      rvc4 rvs2lo MMOV  zreg rvs2hi MMOV
    then
    rvr33 rvlink MMOV  t' rvadd.sub JMP  label: rvb7
    rvrlo rvpclo MMOV  rvrhi rvpchi MMOV
    vm JMP
  then then
  \ JUMP (JAL 0x6F / JALR 0x67): reg[rd] = RVPC+4, then RVPC = target. Compute target first (JAL uses
  \ RVPC + J-imm, JALR uses reg[rs1] + I-imm & ~1) while SRC1 = reg[rs1] is still live, then the link.
  rvo-jmp r0 MMOV  r0 +if
    zreg rvbimmlo MMOV  zreg rvbimmhi MMOV
    rvo-op r0 MMOV  rvc111 r0 SUB
    r0 +if else r0 -if else
      \ JAL: decode J-imm[20|10:1|11|19:12] into rvbimmlo/rvbimmhi, then target = RVPC + J-imm
      rvih rvs1lo MMOV  rvc4 rvsh MMOV  rvc7fe rvmask MMOV
      rvr34 rvlink MMOV  t' rvfield.sub JMP  label: rvj1   rvrlo rvbimmlo MMOV  \ imm[10:1]
      rvil r0 MMOV  r0 zreg rvcf000 MUXR  r0 rvbimmlo ADD                       \ imm[15:12]=ir_lo & 0xF000
      rvih r0 MMOV  r0 zreg rvc16 MUXR  r0 +if  rvc800 rvbimmlo ADD  then       \ imm[11]=ir_hi[4]
      rvih r0 MMOV  r0 zreg rvc15 MUXR  r0 rvbimmhi MMOV                        \ imm[19:16]=ir_hi & 0xF
      rvih RVBIT15  r1 +if  rvcfff0 rvbimmhi ADD  then                          \ sign imm[20]: bits 4..15
      rvpclo rvs1lo MMOV  rvpchi rvs1hi MMOV
      rvbimmlo rvs2lo MMOV  rvbimmhi rvs2hi MMOV
      rvr35 rvlink MMOV  t' rvadd.sub JMP  label: rvj2
      rvrlo rvbimmlo MMOV  rvrhi rvbimmhi MMOV
    then then
    rvo-op r0 MMOV  rvc103 r0 SUB
    r0 +if else r0 -if else
      \ JALR: SRC1 = reg[rs1] (still loaded); SRC2 = sign-extended I-imm; target = (SRC1+imm) & ~1
      rvo-imm rvs2lo MMOV
      rvih RVBIT15  r1 +if  rvcf000 rvs2lo ADD  neg1 rvs2hi MMOV  else  zreg rvs2hi MMOV  then
      rvr36 rvlink MMOV  t' rvadd.sub JMP  label: rvj3
      rvrlo rvbimmlo MMOV  rvrhi rvbimmhi MMOV
      rvbimmlo zreg rvcfffe MUXR                                                \ clear bit 0
    then then
    \ link = RVPC + 4 (RVPC still intact); rvadd leaves it in RSLT, which rvwr writes straight to rd
    rvpclo rvs1lo MMOV  rvpchi rvs1hi MMOV  rvc4 rvs2lo MMOV  zreg rvs2hi MMOV
    rvr37 rvlink MMOV  t' rvadd.sub JMP  label: rvj4
    rvo-rd rvidx MMOV
    rvr38 rvlink MMOV  t' rvwr.sub JMP  label: rvj5
    rvbimmlo rvpclo MMOV  rvbimmhi rvpchi MMOV
    vm JMP
  then
  \ U-TYPE (LUI 0x37 / AUIPC 0x17): U-imm = ir[31:12] already in place -> lo = ir_lo & 0xF000, hi = ir_hi.
  \ LUI writes it to rd; AUIPC adds RVPC first. reg[rd] = result.
  rvo-uop r0 MMOV  r0 +if
    rvil rvrlo MMOV  rvrlo zreg rvcf000 MUXR                \ RSLT lo = imm[15:12] = ir_lo & 0xF000
    rvih rvrhi MMOV                                          \ RSLT hi = imm[31:16]
    rvo-op r0 MMOV  rvc23 r0 SUB
    r0 +if else r0 -if else
      \ AUIPC: RSLT = RVPC + U-imm  (copy U-imm to SRC2 before rvadd overwrites RSLT)
      rvpclo rvs1lo MMOV  rvpchi rvs1hi MMOV
      rvrlo rvs2lo MMOV  rvrhi rvs2hi MMOV
      rvr39 rvlink MMOV  t' rvadd.sub JMP  label: rvu1
    then then
    rvo-rd rvidx MMOV
    rvr40 rvlink MMOV  t' rvwr.sub JMP  label: rvu2
    vm JMP
  then
  \ ECALL (the exact encoding 0x00000073: ir_lo==0x0073 AND ir_hi==0 -- this excludes ebreak 0x0010....
  \ and the CSR ops, which share opcode 0x73 but differ in ir_hi/funct3). The ISA only signals the host
  \ via rvstate; the runner reads a7 and emulates the syscall (write/exit). No reg write, no RVPC change.
  rvil r0 MMOV  rvc115 r0 SUB
  r0 +if else r0 -if else
    rvih r0 MMOV
    r0 +if else r0 -if else
      one rvstate MMOV
      vm JMP
    then then
  then then
  \ ENCODING TRAP: only R-type (0x33) and I-type (0x13) reach here (every other base opcode was
  \ short-circuited above). Trap (rvstate=2, host stops): (a) any UNKNOWN opcode -- FENCE 0x0F,
  \ atomics 0x2F, custom -- and (b) R-type M-extension, funct7 bit0 = instr bit25 = ir_hi bit9 (MUL/
  \ DIV/REM), which would otherwise alias a base ALU op. NOT a full RV32I validator: even-but-illegal
  \ R-type funct7 (e.g. 0x02) and out-of-range shift immediates still alias -- real toolchains never
  \ emit those, and M-extension is the encoding real compiled programs actually reach. rvtmp = legal.
  zreg rvtmp MMOV
  rvo-op r0 MMOV  rvc51 r0 SUB  r0 +if else r0 -if else  one rvtmp MMOV  then then
  rvo-op r0 MMOV  rvc13 r0 SUB  r0 +if else r0 -if else  one rvtmp MMOV  then then
  rvtmp r0 MMOV  r0 +if else r0 -if else  rvc2 rvstate MMOV  vm JMP  then then
  rvo-op r0 MMOV  rvc51 r0 SUB
  r0 +if else r0 -if else
    rvih r0 MMOV  r0 zreg rvc512 MUXR  r0 +if  rvc2 rvstate MMOV  vm JMP  then
  then then
  \ SRC2: I-type -> sign-extended immediate; R-type -> reg[rs2]
  rvo-itype r0 MMOV  r0 +if
    rvo-imm rvs2lo MMOV                          \ SRC2 low = imm[11:0]
    rvih RVBIT15  r1 +if                         \ imm sign bit (imm[11] = bit15 ir_hi)
      rvcf000 rvs2lo ADD  neg1 rvs2hi MMOV       \ sign-extend: low bits 12..15 set, high = 0xFFFF
    else
      zreg rvs2hi MMOV                           \ non-negative: high = 0
    then
    \ I-type uses funct7 (rvo-alt) only for SRLI/SRAI (funct3 5); force it 0 for all other I-type ops
    rvo-funct3 r0 MMOV  rvc5 r0 SUB
    r0 +if  zreg rvo-alt MMOV  then              \ funct3 > 5
    r0 -if  zreg rvo-alt MMOV  then              \ funct3 < 5
  else
    rvo-rs2 rvidx MMOV
    rvr2 rvlink MMOV  t' rvrd2.sub JMP  label: rvs2p   \ SRC2 = reg[rs2]
  then
  \ dispatch on funct3: 0=ADD/SUB, 1=SLL, 2=SLT, 3=SLTU, 4=XOR, 5=SRL/SRA, 6=OR, 7=AND -- each
  \ equality test calls one op .sub. 'r0 +if else r0 -if else <body> then then' runs body iff r0 == 0
  \ (r0<=0 and r0>=0); funct3-X is small so -if is negation-safe. Exactly one test matches; the rest
  \ skip. All eight funct3 values are now implemented (SLT/SLTU write a 0/1 to RSLT). funct7 on ops
  \ other than ADD/SRL is not validated -- callers pass legal encodings until an opcode/funct7 trap.
  rvo-funct3 r0 MMOV                             \ == 0 -> ADD (rvo-alt=0) or SUB (rvo-alt=1)
  r0 +if else r0 -if else
    rvo-alt r0 MMOV  r0 +if
      rvr14 rvlink MMOV  t' rvsub.sub JMP  label: rvs14p
    else
      rvr5 rvlink MMOV  t' rvadd.sub JMP  label: rvs5p
    then
  then then
  rvo-funct3 r0 MMOV  one r0 SUB                 \ == 1 -> SLL
  r0 +if else r0 -if else
    rvs2lo rvsh MMOV  rvsh zreg rv1f MUXR         \ shamt = reg[rs2] & 0x1F
    rvr4 rvlink MMOV  t' rvsll.sub JMP  label: rvs4p
  then then
  rvo-funct3 r0 MMOV  rvc2 r0 SUB                \ == 2 -> SLT (signed = unsigned with bit31 flipped)
  r0 +if else r0 -if else
    rvsign rvs1hi ADD  rvsign rvs2hi ADD         \ flip bit31 of both operands (a XOR 0x80000000)
    rvr18 rvlink MMOV  t' rvsltu.sub JMP  label: rvs18p
  then then
  rvo-funct3 r0 MMOV  rvc3 r0 SUB                \ == 3 -> SLTU (unsigned)
  r0 +if else r0 -if else
    rvr19 rvlink MMOV  t' rvsltu.sub JMP  label: rvs19p
  then then
  rvo-funct3 r0 MMOV  rvc4 r0 SUB                \ == 4 -> XOR
  r0 +if else r0 -if else
    rvr12 rvlink MMOV  t' rvxor.sub JMP  label: rvs12p
  then then
  rvo-funct3 r0 MMOV  rvc5 r0 SUB                \ == 5 -> SRL (rvo-alt=0) / SRA (rvo-alt=1)
  r0 +if else r0 -if else
    rvo-alt r0 MMOV  r0 +if
      rvr17 rvlink MMOV  t' rvsra.sub JMP  label: rvs17p
    else
      rvr16 rvlink MMOV  t' rvsrl.sub JMP  label: rvs16p
    then
  then then
  rvo-funct3 r0 MMOV  rvc6 r0 SUB                \ == 6 -> OR
  r0 +if else r0 -if else
    rvr13 rvlink MMOV  t' rvor.sub JMP  label: rvs13p
  then then
  rvo-funct3 r0 MMOV  rvc7 r0 SUB                \ == 7 -> AND
  r0 +if else r0 -if else
    rvr3 rvlink MMOV  t' rvand.sub JMP  label: rvs3p
  then then
  rvo-rd rvidx MMOV                              \ rvidx = rd
  rvr6 rvlink MMOV  t' rvwr.sub  JMP  label: rvs6p   \ reg[rd] = RSLT
  ;a
rvd1 half rvr7 t!  rvd2 half rvr8 t!   ( plant decode return addresses; rvd3/rvr9 dropped: rs2 from imm )
rvd5 half rvr11 t!  ( rvd4/rvr10 dropped: rs1-low direct mask; rvd6/rvr15 dropped: rvo-alt direct mask )
rvd8 half rvr21 t!  ( rvd7/rvr20 dropped: opcode now uses a direct mask, no rvfield.sub return slot )
rvs1p half rvr1 t!  rvs2p half rvr2 t!  rvs3p half rvr3 t!   ( plant execute return addresses )
rvs4p half rvr4 t!  rvs5p half rvr5 t!  rvs6p half rvr6 t!
rvs12p half rvr12 t!  rvs13p half rvr13 t!  rvs14p half rvr14 t!
rvs16p half rvr16 t!  rvs17p half rvr17 t!  rvs18p half rvr18 t!  rvs19p half rvr19 t!
rvm1 half rvr22 t!  rvm2 half rvr23 t!  rvm3 half rvr24 t!  ( memory path )
rvm4 half rvr25 t!  rvm5 half rvr26 t!
rvb1 half rvr27 t!  rvb2 half rvr28 t!  rvb3 half rvr29 t!  ( branch path )
rvb4 half rvr30 t!  rvb5 half rvr31 t!  rvb6 half rvr32 t!  rvb7 half rvr33 t!
rvj1 half rvr34 t!  rvj2 half rvr35 t!  rvj3 half rvr36 t!  ( jump path )
rvj4 half rvr37 t!  rvj5 half rvr38 t!
rvu1 half rvr39 t!  rvu2 half rvr40 t!  ( U-type path )
[then]

there 2/ primitive t!              ( set 'primitive', needed for VM )
