label: entry                       \ used to set entry point in next cell
  -1 t,                            \ system entry point, set later
opt.sys tvar {options}             ( system option flags )
  0 tvar primitive                 ( address lower must be VM primitive )
  =stksz half tvar stacksz         ( must contain stack size )
  0 tvar zreg                      ( must contain 0 )
 -1 tvar neg1                      ( must contain -1 )
  1 tvar one                       ( must contain  1 )
$10 tvar bwidth                    ( must contain 16 bit width )
$40 tvar mwidth                    ( maximum machine width )
  0 tvar r0                        ( working pointer 1 register r0 )
  0 tvar r1                        ( register 1 )
  0 tvar r2                        ( register 2 )
  0 tvar r3                        ( register 3 )
  0 tvar r4                        ( register 4 )
  0 tvar h                         ( dictionary pointer )
  =thread half tvar {up}           ( Current task address Half size )
  0 tvar check                     ( used for system checksum )
  0 tvar {context} E tallot        ( vocabulary context )
  0 tvar {current}                 ( vocabulary to add new definitions to )
  0 tvar {forth-wordlist}          ( forth word list main vocabulary )
  0 tvar {editor}                  ( editor vocabulary )
  0 tvar {root-voc}                ( absolute minimum vocabulary )
  0 tvar {system}                  ( system functions vocabulary )
  0 tvar {boot}                    ( entry point of VM program )
  0 tvar {quit}                    ( Execution token called after init )
  0 tvar {last}                    ( last defined word )
  0 tvar {cycles}                  ( number of times we switched tasks )
  1 tvar {single}                  ( is multi processing off? +ve = off )
  0 tvar {user}                    ( Number of locals assigned )

\ Thread variables, not all of which are user variables
  0 tvar ip                        ( instruction pointer )
  0 tvar tos                       ( top of stack )
opt.rv32i [if]
  0 tvar rvs1lo  0 tvar rvs1hi     ( RV32I: SRC1 low/high 16-bit halves )
  0 tvar rvs2lo  0 tvar rvs2hi     ( RV32I: SRC2 low/high halves )
  0 tvar rvrlo   0 tvar rvrhi      ( RV32I: RSLT low/high halves )
  $8000 tvar rvsign                ( RV32I: high-bit mask for negation-safe signbit tests )
  0 tvar rvsh                      ( RV32I: shift amount, pre-masked to 0..31 by decode )
  0 tvar rvidx                     ( RV32I: register index 0..31 for indexed access )
  0 tvar rvmask                    ( RV32I: field-extract mask for rvfield.sub )
  0 tvar rvlink                    ( RV32I: subroutine return-address link cell )
  0 tvar rvil  0 tvar rvih         ( RV32I: instruction word, low/high 16-bit halves )
  0 tvar rvo-rs1  0 tvar rvo-rs2  0 tvar rvo-rd  ( RV32I: decoded register indices )
  0 tvar rvo-funct3                ( RV32I: decoded funct3 selecting the op )
  $1F tvar rv1f                    ( RV32I: low-5-bit mask, also SLL shamt = reg[rs2] & 0x1F )
   2 tvar rvc2   3 tvar rvc3   4 tvar rvc4  ( RV32I: decode/dispatch constants )
   5 tvar rvc5   6 tvar rvc6   7 tvar rvc7
  $C tvar rvc12  $13 tvar rvc13  $E tvar rvc14  $F tvar rvc15  $20 tvar rvc32
  $4000 tvar rvc4000              ( RV32I: instr bit30 mask for funct7 alt flag )
  $7F tvar rvc7f  $FFF tvar rvcfff  $F000 tvar rvcf000  ( RV32I: opcode/imm masks + sign-extend fill )
  $23 tvar rvc35   $FE0 tvar rvcfe0  ( RV32I: STORE opcode, S-imm bits 11..5 mask )
  $8 tvar rvc8   $FF tvar rvcff   $FF00 tvar rvcff00   $80 tvar rvc128  ( RV32I: byte shift/masks )
  $63 tvar rvc99   $1E tvar rvc1e   $7E0 tvar rvc7e0   $800 tvar rvc800  ( RV32I: BRANCH opcode, B-imm fields )
  $6F tvar rvc111  $67 tvar rvc103  ( RV32I: JAL / JALR opcodes )
  $37 tvar rvc55   $17 tvar rvc23   ( RV32I: LUI / AUIPC opcodes )
  $73 tvar rvc115  ( RV32I: SYSTEM opcode -- ecall )
  $33 tvar rvc51   $200 tvar rvc512  ( RV32I: R-type opcode, M-extension funct7 bit0 = instr bit25 )
  $7FE tvar rvc7fe  $10 tvar rvc16  $FFF0 tvar rvcfff0  $FFFE tvar rvcfffe  ( RV32I: J-imm fields, JALR mask )
  0 tvar rvtmp                     ( RV32I: scratch for XOR = a-or-b minus a-and-b )
  0 tvar rvneg                     ( RV32I: SRA sign flag: was SRC1 negative? )
  0 tvar rvo-alt                   ( RV32I: funct7 bit5 = instr bit 30, ADD/SUB + SRL/SRA discriminator )
  0 tvar rvo-op    0 tvar rvo-imm    0 tvar rvo-itype  ( RV32I: opcode, imm[11:0], is-I-type flag )
  0 tvar rvo-mem                   ( RV32I: is-memory flag, set for LOAD 0x03 / STORE 0x23 )
  0 tvar rvmaddr                   ( RV32I: guest-RAM cell pointer for load/store )
  0 tvar rvparity  0 tvar rvmw     ( RV32I: EA byte parity, loaded/RMW memory-cell scratch )
  0 tvar rvwidth   0 tvar rvuns    ( RV32I: access width funct3&3, unsigned-load flag funct3&4 )
  0 tvar rvpclo    0 tvar rvpchi   ( RV32I: program counter RVPC, byte address, low/high halves )
  0 tvar rvbimmlo  0 tvar rvbimmhi ( RV32I: decoded branch/jump immediate or target, sign-extended )
  0 tvar rvtaken                   ( RV32I: branch-taken flag )
  0 tvar rvo-jmp                   ( RV32I: is-jump flag, set for JAL 0x6F / JALR 0x67 )
  0 tvar rvo-uop                   ( RV32I: is-upper-immediate flag, set for LUI 0x37 / AUIPC 0x17 )
  0 tvar rvo-ctrl                  ( RV32I: is-control-flow flag = branch 0x63 or jump; runner skips RVPC+=4 )
  0 tvar rvstate                   ( RV32I: run-state signal the host reads -- 0 running, 1 ecall, 2 illegal )
  0 tvar rvr1  0 tvar rvr2  0 tvar rvr3  0 tvar rvr4   ( RV32I: rvstep per-call return slots )
  0 tvar rvr5  0 tvar rvr6  0 tvar rvr7  0 tvar rvr8
  0 tvar rvr9  0 tvar rvr10 0 tvar rvr11 0 tvar rvr12
  0 tvar rvr13 0 tvar rvr14 0 tvar rvr15 0 tvar rvr16
  0 tvar rvr17 0 tvar rvr18 0 tvar rvr19 0 tvar rvr20 0 tvar rvr21
  0 tvar rvr22 0 tvar rvr23 0 tvar rvr24 0 tvar rvr25 0 tvar rvr26  ( RV32I: memory-path return slots )
  0 tvar rvr27 0 tvar rvr28 0 tvar rvr29 0 tvar rvr30  ( RV32I: branch-path return slots )
  0 tvar rvr31 0 tvar rvr32 0 tvar rvr33
  0 tvar rvr34 0 tvar rvr35 0 tvar rvr36 0 tvar rvr37 0 tvar rvr38  ( RV32I: jump-path return slots )
  0 tvar rvr39 0 tvar rvr40         ( RV32I: U-type return slots )
  0 tvar rvregs  126 tallot        ( RV32I: register file x0..x31, 64 cells: 1 from tvar + 63 more )
  rvregs half tvar rvbase          ( RV32I: halved base address of the register file )
  $3FFF tvar rvrammask             ( RV32I: guest-RAM cell mask, indices 0..16383 = 32 KiB )
  \ rvram (the un-baked high window, explained in the constants header) has an address invariant we
  \ record here, verified by the RV goldens + sanitize: base cell ($3800) stays above MAX_CELLS so
  \ image growth can't reach it, and base+mask+1 ($7800) stays below buf0 (cell $7A00) and the 15-bit
  \ address ceiling ($8000). The window can't survive heavy interactive dictionary growth before an RV
  \ run; only the eForth teardown would, and that is deferred.
  rvram half tvar rvrambase        ( RV32I: halved cell base address of guest RAM = $3800 )
[then]
  =thread =stksz        + half dup tvar {rp0} tvar {rp}
  =thread =stksz double + half dup tvar {sp0} tvar {sp}
  200 constant =tib                ( Start of terminal input buffer )
  380 constant =num                ( Start of numeric input buffer )

\ User variables for multitasking
  tuser {next-task}                ( next task in task list )
  tuser {ip-save}                  ( saved instruction pointer )
  tuser {tos-save}                 ( saved top of variable stack )
  tuser {rp-save}                  ( saved return stack pointer )
  tuser {sp-save}                  ( saved variable stack pointer )
  tuser {handler}                  ( throw/catch handler )
  tuser {sender}                   ( multitasking; msg. send, 0 = no msg )
  tuser {message}                  ( multitasking; the message itself )
  tuser {id}                       ( executing from block or terminal? )

\ Advanced MUXLEQ Operations
:m INC 2/ neg1 2/ t, t, NADDR ;m   ( b -- : increment location )
:m DEC 2/ one  2/ t, t, NADDR ;m   ( b -- : decrement location )
:m MUXR >r 2/ t, 2/ t, r> 2/ $8000 or t, ;m ( MUX with register )
:m MMOV swap zreg MUXR ;m          ( a a -- : move operation )
:m -MMOV swap neg1 MUXR ;m         ( a a -- : negative move operation )
:m iJMP there 2/ 5 + 2* MMOV Z Z NADDR ;m ( a -- : indirect jump )
:m ONE! one swap MMOV ;m           ( a -- : set address to '1' )
:m NG1! neg1 swap MMOV ;m          ( a -- : set address to '-1' )
:m iSTORE there 4 2* + MMOV 0 MMOV ;m ( a a -- : indirect store )
:m iLOAD there 3 2* + MMOV 0 swap MMOV ;m ( a a -- : indirect load )

:m iADD                            ( a a -- : indirect add )
   2/ t, A, NADDR
   2/ t, V, NADDR
   there 2/ 7 + dup dup t, t, NADDR
   A,   t, NADDR
   V, 0 t, NADDR
   A, A, NADDR
   V, V, NADDR ;m

:m iSUB                            ( a a -- : indirect subtract )
   2/ t, A, NADDR
   2/ >r
   there 2/ 7 + dup dup t, t, NADDR
   A,   t, NADDR
   r> t, 0 t, NADDR
   A, A, NADDR ;m

\ Stack management operations
:m ++sp {sp} DEC ;m                ( -- : grow variable stack )
:m --sp {sp} INC ;m                ( -- : shrink variable stack )
:m --rp {rp} DEC ;m                ( -- : shrink return stack )
:m ++rp {rp} INC ;m                ( -- : grow return stack )

\ Error Handling and System Startup
\ Error message: "Error: Not a 16-bit SUBLEQ VM"
45 tvar err-str
  72 t, 72 t, 6F t, 72 t, 3A t, 20 t, 4E t,
  6F t, 74 t, 20 t, 61 t, 20 t, 31 t, 36 t, 2D t,
  62 t, 69 t, 74 t, 20 t, 53 t, 55 t, 42 t, 4C t,
  45 t, 51 t, 20 t, 56 t, 4D t, 0D t, 0A t, -1 t,
err-str 2/ tvar err-str-addr

assembler.1 +order
label: die
   err-str-addr r0 MMOV            \ load string address
   label: die.loop
     r1 r0 iLOAD                   \ load character
     r0 INC                        \ increment to next cell
     r1 +if
       r1 PUT                      \ output single byte
       die.loop JMP                \ sentinel is a negative value
     then

\ First VM word: "bye" - halt the Forth system
:a bye HALT (a);

\ MUXLEQ Virtual Machine Bootstrap
assembler.1 +order
label: start                       \ System Entry Point
  start 2/ entry t!                \ Set the system entry point
  r0 ONE!                          \ r0 = shift bit loop count
  r1 ONE!                          \ r1 = number of bits

\ 16-bit architecture verification
label: chk16
  r0 r0 ADD                        \ r0 = r0 * 2
  r1 INC                           \ r1++
  r1 r2 MMOV                       \ r2 = r1
  mwidth r2 SUB r2 +if die JMP then \ check length < max width
  r0 +if chk16 JMP then            \ check if still positive
  bwidth r1 SUB r1 if die JMP then \ r1 - bwidth should be 0

  {sp0} {sp} MMOV                  \ Setup initial variable stack
  {rp0} {rp} MMOV                  \ Setup initial return stack
  {boot} ip MMOV                   \ Get the first instruction to execute

\ Forth Inner Interpreter - the heart of the virtual machine
label: vm
  r0 ip iLOAD                      \ Get instruction to execute from IP
  ip INC                           \ IP now points to next instruction!
  primitive r1 MMOV                \ Copy as SUB is destructive
  r0 r1 SUB                        \ Check if it is a primitive
  r1 +if r0 iJMP then              \ Jump to VM functions if it is
  ++rp                             \ If not VM instruction, inc {rp}
  ip {rp} iSTORE                   \ and store ip to return stack
  r0 ip MMOV                       \ "r0" holds our next instruction
  vm JMP                           \ Continue forever...

:m ;a (fall-through); vm JMP ;m
assembler.1 -order

\ Virtual Machine Primitives
:a opSwap tos r0 MMOV tos {sp} iLOAD r0 {sp} iSTORE ;a
:a opDup ++sp tos {sp} iSTORE ;a   ( n -- n n )
:a opFromR ++sp tos {sp} iSTORE tos {rp} iLOAD --rp ;a
:a opToR ++rp tos {rp} iSTORE (fall-through); \ fall-through to opDrop
:a opDrop tos {sp} iLOAD --sp ;a   ( n -- )
:a [@] tos tos iLOAD ;a            ( a -- a : load SUBLEQ address )
:a [!] r0 {sp} iLOAD r0 tos iSTORE --sp t' opDrop JMP (a);
:a opEmit tos PUT t' opDrop JMP (a); ( n -- )
:a opExit ip {rp} iLOAD (fall-through); \ fall-through to rdrop
:a rdrop --rp ;a                   ( R: u -- )
:a opIpInc ip INC ;a               ( -- : increment instruction pointer )

:a opJumpZ                         ( u -- : Conditional jump on zero )
  tos r0 MMOV
  tos {sp} iLOAD --sp
  r0 if t' opIpInc JMP then r0 DEC r0 +if t' opIpInc JMP then
  (fall-through);

:a opJump ip ip iLOAD ;a           ( -- : Unconditional jump )

:a opNext r0 {rp} iLOAD            ( R: n -- | n-1 )
   r0 +if r0 DEC r0 {rp} iSTORE t' opJump JMP then
   --rp t' opIpInc JMP (a);

:a op0=                            ( n -- f : equal to zero )
 \ assembly 'if' does not work for entire range
 tos if
   tos ZERO
 else \ deal with incorrect results
   tos DEC
   tos +if tos ZERO else tos NG1! then
 then ;a

:a leq0                            ( n -- 0|1 : less than or equal to zero )
  Z tos 2/ t, there 2/ 4 + t,
  tos 2/ dup t, t, vm 2/ t,
  tos ONE! ;a

:a - tos {sp} iSUB t' opDrop JMP (a); ( n n -- n )
:a + tos {sp} iADD t' opDrop JMP (a); ( n n -- n )

:a shift                           ( u n -- u : right shift 'u' by 'n' places )
  bwidth r0 MMOV                   \ load machine bit width
  tos r0 SUB                       \ adjust tos by machine width
  tos {sp} iLOAD --sp              \ pop value to shift
  r1 ZERO                          \ zero result register
  label: shift.loop
    r1 r1 ADD                      \ double r1, equivalent to left shift by one
    \ work out what bit to shift into r1
    tos +if else
      tos r2 MMOV r2 INC r2 +if else r1 INC then then
    tos tos ADD                    \ double tos, equivalent to left shift by one
    r0 DEC                         \ decrement loop counter
  r0 +if shift.loop JMP then
  r1 tos MMOV ;a                   \ move result back into tos

:a opGet                           ( -- char )
   ++sp tos {sp} iSTORE
  tos GET ;a

:a opMux                           ( u1 u2 u3 -- u : bitwise multiplexor function )
  r4 {sp} iLOAD --sp               \ pop first input
  r3 {sp} iLOAD --sp               \ pop second input
  r3 r4 tos MUXR
  r3 tos MMOV ;a

opt.divmod [if]
\ Repeated-subtraction unsigned divide: r0 (dividend) -= tos (divisor) until it goes negative, then
\ correct back one step. The 'r0 -if' sign test has the INT16_MIN blind spot ('-if' mis-reads 0x8000
\ as non-negative), so it is only exact if the running remainder can never equal exactly 0x8000. That
\ holds for the SOLE caller, '(.)', which always passes a small radix (base, 2..36) as the divisor:
\ r0 starts <= 0x8000 and only decreases, and each terminating (r0 - radix) is a small negative
\ (-1..-radix), never -32768. Do NOT call opDivMod with a bit15-set divisor -- it would loop/misstep;
\ use a negation-safe sign test (mask+DEC+'+if', like RVBIT15) if that case is ever needed.
:a opDivMod                        ( u1 u2 -- u1 u2 )
  r0 {sp} iLOAD
  r1 ZERO                          \ zero quotient
  label: divStep
    r1 INC                         \ increment quotient
    tos r0 SUB                     \ repeated subtraction
    r0 -if
      tos r0 ADD                   \ correct remainder
      r1 DEC                       \ correct quotient
      r1 tos MMOV                  \ store results back to tos
      r0 {sp} iSTORE               \ ...and stack
      vm JMP                       \ finish...
    then
  divStep JMP                      \ perform another division step
  (a);
[then]

\ Multitasking Support
opt.multi [if]
:a pause                           ( -- : pause and switch task )
  \ {single} must be positive and not zero to turn off "pause"
  {single} +if vm JMP then         \ Do nothing if single-threaded mode
  r0 {up} iLOAD                    \ load next task pointer from user storage
  \ r0 should never be negative as this would mean the thread was
  \ above the 32768 mark where @ and ! would not work
  r0 +if
    {cycles} INC                   \ increment "pause" count
    {up} r1 MMOV  r1 INC           \ load TASK pointer, skip next task
      ip r1 iSTORE r1 INC          \ save registers to current task
     tos r1 iSTORE r1 INC          \ only a few need to be saved
    {rp} r1 iSTORE r1 INC
    {sp} r1 iSTORE
      r0 {rp0} MMOV stacksz {rp0} ADD \ change {rp0} to new location
   {rp0} {sp0} MMOV stacksz {sp0} ADD \ same but for {sp0}
      r0 {up} MMOV r0 INC          \ set next task
      ip r0 iLOAD r0 INC           \ reverse of save registers
     tos r0 iLOAD r0 INC
    {rp} r0 iLOAD r0 INC
    {sp} r0 iLOAD                  \ we're all restored
  then ;a
[else]
:m pause ;m                        ( -- [disabled] )
[then]
