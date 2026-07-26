\ RV32I microcode smoke test. The 'opt.rv32i' section in muxleq.fth implements RV32I execute ops as
\ assembler-layer microcode (raw MUXLEQ the VM runs directly, kin to the ':a' primitives): each RV32I
\ register is two 16-bit MUXLEQ cells (low/high). Bridged to Forth by the ':to' wrappers +
\ rv-s1*/rv-s2*/rv-r*/rv-sh/rv-idx address constants, and bootstrapped WITH muxleq.fth so
\ 'make bootstrap' re-assembles and byte-checks it. Covered: AND (one same-lane MUX per half), ADD
\ (per-half SUBLEQ add + cross-cell carry), SLL (doubling with the half-boundary spill), and indexed
\ register-file read/write (reg[i] at halved base + 2*i, x0 hard-wired zero).
hex
\ alternating-bit mask: 0xFF00FF00 & 0x0F0F0F0F = 0x0F000F00
FF00 rv-s1hi ! FF00 rv-s1lo !  0F0F rv-s2hi ! 0F0F rv-s2lo !
rvand rv-rhi @ u. rv-rlo @ u.       \ F00 F00
\ low-only mask: 0xFFFFFFFF & 0x0000FFFF = 0x0000FFFF (high half cleared)
FFFF rv-s1hi ! FFFF rv-s1lo !  0000 rv-s2hi ! FFFF rv-s2lo !
rvand rv-rhi @ u. rv-rlo @ u.       \ 0 FFFF
\ high-only mask: 0xFFFFFFFF & 0xFFFF0000 = 0xFFFF0000 (low half cleared)
FFFF rv-s1hi ! FFFF rv-s1lo !  FFFF rv-s2hi ! 0000 rv-s2lo !
rvand rv-rhi @ u. rv-rlo @ u.       \ FFFF 0
cr
\ 32-bit ADD: SUBLEQ add per half + an explicit low->high carry = MAJ of the three sign bits,
\ masked with 0x8000 (not '-if', which mis-signs 0x8000 because its own negation overflows).
\ 0x0000FFFF + 1 = 0x00010000 (carry into high half)
0000 rv-s1hi ! FFFF rv-s1lo !  0000 rv-s2hi ! 0001 rv-s2lo !
rvadd rv-rhi @ u. rv-rlo @ u.       \ 1 0
\ 0xFFFFFFFF + 1 = 0 (full 32-bit wrap)
FFFF rv-s1hi ! FFFF rv-s1lo !  0000 rv-s2hi ! 0001 rv-s2lo !
rvadd rv-rhi @ u. rv-rlo @ u.       \ 0 0
\ 0x00008000 + 0x00008000 = 0x00010000 (carry out of two INT16_MIN low halves)
0000 rv-s1hi ! 8000 rv-s1lo !  0000 rv-s2hi ! 8000 rv-s2lo !
rvadd rv-rhi @ u. rv-rlo @ u.       \ 1 0
\ 0x12340000 + 0x00005678 = 0x12345678 (independent halves, no carry)
1234 rv-s1hi ! 0000 rv-s1lo !  0000 rv-s2hi ! 5678 rv-s2lo !
rvadd rv-rhi @ u. rv-rlo @ u.       \ 1234 5678
cr
\ 32-bit SLL: shift left by doubling both halves rvsh times, spilling bit15(lo) into hi bit0.
\ Shifts genuinely move bits across the two 16-bit lanes -- NOT a MUX win. rvsh is pre-masked 0..31.
0001 rv-s1lo ! 0000 rv-s1hi !  000F rv-sh ! rvsll rv-rhi @ u. rv-rlo @ u.   \ 1<<15 = 0000 8000
0001 rv-s1lo ! 0000 rv-s1hi !  0010 rv-sh ! rvsll rv-rhi @ u. rv-rlo @ u.   \ 1<<16 = 0001 0000 (cross)
0001 rv-s1lo ! 0000 rv-s1hi !  001F rv-sh ! rvsll rv-rhi @ u. rv-rlo @ u.   \ 1<<31 = 8000 0000
FFFF rv-s1lo ! 0000 rv-s1hi !  0004 rv-sh ! rvsll rv-rhi @ u. rv-rlo @ u.   \ 0000FFFF<<4 = 000F FFF0
0001 rv-s1lo ! 0000 rv-s1hi !  0000 rv-sh ! rvsll rv-rhi @ u. rv-rlo @ u.   \ 1<<0  = 0000 0001 (no shift)
cr
\ Indexed register file: reg[i] = two cells at halved base + 2*i; write RSLT to reg[rvidx], read
\ reg[rvidx] into SRC1. x0 (index 0) is hard-wired zero -- writes to it are discarded.
5678 rv-rlo ! 1234 rv-rhi ! 0005 rv-idx ! rvwr   \ reg[5] = 0x12345678
0005 rv-idx ! rvrd  rv-s1hi @ u. rv-s1lo @ u.     \ 1234 5678
BBBB rv-rlo ! AAAA rv-rhi ! 0000 rv-idx ! rvwr   \ write to x0 discarded
0000 rv-idx ! rvrd  rv-s1hi @ u. rv-s1lo @ u.     \ 0 0
2222 rv-rlo ! 1111 rv-rhi ! 0001 rv-idx ! rvwr
4444 rv-rlo ! 3333 rv-rhi ! 001F rv-idx ! rvwr   \ x31
0001 rv-idx ! rvrd  rv-s1hi @ u. rv-s1lo @ u.     \ 1111 2222
001F rv-idx ! rvrd  rv-s1hi @ u. rv-s1lo @ u.     \ 3333 4444
0005 rv-idx ! rvrd  rv-s1hi @ u. rv-s1lo @ u.     \ 1234 5678 (unchanged by other writes)
cr
\ Instruction field decode: rvfield = (rv-s1lo >> rv-sh) & rv-mask. Right shift slides a field down
\ to bit 0 (loop 16-shift times pulling the top bit down). Fields of ADD x5,x1,x2 = 0x002082B3,
\ ir_lo = 0x82B3, ir_hi = 0x0020.
82B3 rv-s1lo ! 0000 rv-sh ! 007F rv-mask ! rvfield rv-rlo @ u.   \ opcode = 33
82B3 rv-s1lo ! 0007 rv-sh ! 001F rv-mask ! rvfield rv-rlo @ u.   \ rd     = 5
82B3 rv-s1lo ! 000C rv-sh ! 0007 rv-mask ! rvfield rv-rlo @ u.   \ funct3 = 0
0020 rv-s1lo ! 0004 rv-sh ! 001F rv-mask ! rvfield rv-rlo @ u.   \ rs2    = 2
8000 rv-s1lo ! 000F rv-sh ! FFFF rv-mask ! rvfield rv-rlo @ u.   \ 0x8000>>15 = 1 (right-shift proof)
cr
\ R-type fetch-decode-execute over the ADD/AND/SLL subset: a raw 32-bit instruction word (two cells)
\ is decoded with rvfield, its rs1/rs2 read from the register file, dispatched on funct3 to the
\ execute op, and rd written back -- all computation in the assembler-layer microcode, sequenced here
\ by the harness. Scope: dispatch keys on funct3 only (opcode/funct7 unchecked, so SUB would alias
\ ADD) and has no default trap; both are fine for these fixed inputs, and belong in real decode.
\ Folding this sequence into one microcode entry needs a subroutine call/return convention -- next.
variable IL  variable IH  variable RD  variable F3  variable RS1  variable RS2
: field ( src shift mask -- v )  rv-mask ! rv-sh ! rv-s1lo ! rvfield rv-rlo @ ;
: seed ( lo hi idx -- )  rv-idx ! rv-rhi ! rv-rlo ! rvwr ;
: run ( irlo irhi -- )
  IH ! IL !
  IL @ 7 1F field RD !                            \ rd     = ir_lo >> 7  & 0x1F
  IL @ C 7  field F3 !                            \ funct3 = ir_lo >> 12 & 0x7
  IL @ F 1  field  IH @ 0 F field 2* +  RS1 !     \ rs1    = bit15(ir_lo) | (ir_hi & 0xF) << 1
  IH @ 4 1F field RS2 !                           \ rs2    = ir_hi >> 4  & 0x1F
  RS1 @ rv-idx ! rvrd                             \ SRC1 = reg[rs1]
  RS2 @ rv-idx ! rvrd2                            \ SRC2 = reg[rs2]
  F3 @ case
    0 of rvadd endof                              \ ADD
    7 of rvand endof                              \ AND
    1 of rv-s2lo @ 1F and rv-sh ! rvsll endof     \ SLL by reg[rs2] & 0x1F
  endcase
  RD @ rv-idx ! rvwr ;                            \ reg[rd] = RSLT
: show ( idx -- )  rv-idx ! rvrd rv-s1hi @ u. rv-s1lo @ u. cr ;
0005 0000 01 seed  0003 0000 02 seed               \ reg[1]=5, reg[2]=3
82B3 0020 run  05 show                             \ ADD x5,x1,x2 : 5+3  = 0 8
F333 0020 run  06 show                             \ AND x6,x1,x2 : 5&3  = 0 1
93B3 0020 run  07 show                             \ SLL x7,x1,x2 : 5<<3 = 0 28
cr
\ Single-entry decode+execute: rvstep takes a raw 32-bit R-type instruction word (rv-il/rv-ih),
\ decodes rd/funct3/rs1/rs2 with five rvfield.sub calls (rs1 straddles the 16-bit cell boundary),
\ loads rs1/rs2, dispatches on funct3 to the op .sub, and writes rd -- all in ONE microcode entry
\ via the call/return convention. Encodings computed offline (funct7 rs2 rs1 funct3 rd opcode=0x33).
: seedr rv-idx ! rv-rhi ! rv-rlo ! rvwr ;          ( lo hi idx -- : seed a register )
: showr rv-idx ! rvrd rv-s1hi @ u. rv-s1lo @ u. cr ; ( idx -- )
: run rv-ih ! rv-il ! rvstep ;                     ( ir_lo ir_hi -- : one instruction )
0005 0000 01 seedr  0003 0000 02 seedr             \ reg[1]=5, reg[2]=3
82B3 0020 run  05 showr                            \ ADD x5,x1,x2  : 5+3  = 0 8
F333 0020 run  06 showr                            \ AND x6,x1,x2  : 5&3  = 0 1
93B3 0020 run  07 showr                            \ SLL x7,x1,x2  : 5<<3 = 0 28
FFFF 0000 14 seedr  0001 0000 15 seedr             \ reg[20]=0xFFFF, reg[21]=1
0B33 015A run  16 showr                            \ ADD x22,x20,x21 : 0xFFFF+1 = 1 0 (carry, hi regs)
8033 0020 run  00 showr                            \ ADD x0,x1,x2 : rd=x0 stays = 0 0
0001 0000 08 seedr  0010 0000 09 seedr             \ reg[8]=1, reg[9]=16
1533 0094 run  0A showr                            \ SLL x10,x8,x9 : 1<<16 = 1 0 (half-boundary)
decimal cr
bye
