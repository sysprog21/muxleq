label: entry                       \ used to set entry point in next cell
  -1 t,                            \ system entry point, set later
opt.sys tvar {options}             ( system option flags )
  0 tvar primitive                 ( address lower must be VM primitive )
  =stksz half tvar stacksz         ( must contain stack size )
  0 tvar zreg                      ( must contain 0 )
 -1 tvar neg1                      ( must contain -1 )
  1 tvar one                       ( must contain  1 )
=cell 8 * tvar bwidth              ( must contain target bit width )
$40 tvar mwidth                    ( maximum machine width )
  0 tvar r0                        ( working pointer 1 register r0 )
  0 tvar r1                        ( register 1 )
  0 tvar r2                        ( register 2 )
  0 tvar r3                        ( register 3 )
  0 tvar r4                        ( register 4 )
  0 tvar h                         ( dictionary pointer )
  =thread half tvar {up}           ( Current task address Half size )
  0 tvar check                     ( used for system checksum )
  0 tvar {context}
20 tallot ( vocabulary context )
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
:m INC half neg1 half t, t, NADDR ;m ( b -- : increment location )
:m DEC half one half t, t, NADDR ;m ( b -- : decrement location )
:m MUXR >r half t, half t, r> half muxflag or t, ;m ( MUX with register )
:m MMOV swap zreg MUXR ;m          ( a a -- : move operation )
:m -MMOV swap neg1 MUXR ;m         ( a a -- : negative move operation )
:m SHR1 swap half t, half t, cellmask 1 - t, ;m ( src dst -- : dst = src >> 1, native )
:m iJMP there half 5 + cell>byte MMOV Z Z NADDR ;m ( a -- : indirect jump )
:m ONE! one swap MMOV ;m           ( a -- : set address to '1' )
:m NG1! neg1 swap MMOV ;m          ( a -- : set address to '-1' )
:m iSTORE there 4 cell>byte + MMOV 0 MMOV ;m ( a a -- : indirect store )
:m iLOAD there 3 cell>byte + MMOV 0 swap MMOV ;m ( a a -- : indirect load )

:m iADD                            ( a a -- : indirect add )
   half t, A, NADDR
   half t, V, NADDR
   there half 7 + dup dup t, t, NADDR
   A,   t, NADDR
   V, 0 t, NADDR
   A, A, NADDR
   V, V, NADDR ;m

:m iSUB                            ( a a -- : indirect subtract )
   half t, A, NADDR
   half >r
   there half 7 + dup dup t, t, NADDR
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
err-str half tvar err-str-addr

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
  start half entry t!              \ Set the system entry point
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
:a opDup ++sp tos {sp} iSTORE ;a
:a opFromR ++sp tos {sp} iSTORE tos {rp} iLOAD --rp ;a
:a opToR ++rp tos {rp} iSTORE (fall-through);
:a opDrop tos {sp} iLOAD --sp ;a
:a [@] tos tos iLOAD ;a
:a [!] r0 {sp} iLOAD r0 tos iSTORE --sp t' opDrop JMP (a);
\ Native cell fetch/store: fold the nested 2/ 2/ [@] chain behind @ and ! into
\ one primitive each -- a single dispatch on the hot dictionary-search path.
:a op@ tos tos SHR1 tos tos SHR1 tos tos iLOAD ;a
:a op! tos tos SHR1 tos tos SHR1 t' [!] JMP (a);
:a opEmit tos PUT t' opDrop JMP (a);
:a opExit ip {rp} iLOAD (fall-through);
:a rdrop --rp ;a
:a opIpInc ip INC ;a

:a opJumpZ
  tos r0 MMOV
  tos {sp} iLOAD --sp
  r0 if t' opIpInc JMP then r0 DEC r0 +if t' opIpInc JMP then
  (fall-through);

:a opJump ip ip iLOAD ;a

:a opNext r0 {rp} iLOAD
   r0 +if r0 DEC r0 {rp} iSTORE t' opJump JMP then
   --rp t' opIpInc JMP (a);

:a op0=
 \ assembly 'if' does not work for entire range
 tos if
   tos ZERO
 else \ deal with incorrect results
   tos DEC
   tos +if tos ZERO else tos NG1! then
 then ;a

:a leq0
  Z tos half t, there half 4 m+ t,
  tos half tos half t, t, vm half t,
  tos ONE! ;a

:a - tos {sp} iSUB t' opDrop JMP (a);
:a + tos {sp} iADD t' opDrop JMP (a);

:a shift
  \ One iteration per shifted bit, so callers pass an in-range |n| (0..bwidth).
  \ Out-of-range |n| still terminates (|n| iterations) but is unspecified: a
  \ count of exactly 0x80000000 hits the -if sign blind spot and is a no-op.
  tos r0 MMOV                       \ r0 = shift count n (signed)
  tos {sp} iLOAD --sp               \ tos = value to shift
  label: shift.loop
    r0 +if                          \ n > 0: right shift, one native op per bit
      tos tos SHR1
      r0 DEC
    shift.loop JMP then
    r0 -if                          \ n < 0: left shift, double per bit
      tos tos ADD
      r0 INC
    shift.loop JMP then
  ;a

:a opGet
   ++sp tos {sp} iSTORE
  tos GET ;a

:a opMux
  r4 {sp} iLOAD --sp
  r3 {sp} iLOAD --sp
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
:a opDivMod
  r0 {sp} iLOAD
  r1 ZERO
  label: divStep
    r1 INC
    tos r0 SUB
    r0 -if
      tos r0 ADD
      r1 DEC
      r1 tos MMOV
      r0 {sp} iSTORE
      vm JMP
    then
  divStep JMP
  (a);
[then]

\ Multitasking Support
opt.multi [if]
:a pause
  {single} +if vm JMP then
  r0 {up} iLOAD
  r0 +if
    {cycles} INC
    {up} r1 MMOV  r1 INC
      ip r1 iSTORE r1 INC
     tos r1 iSTORE r1 INC
    {rp} r1 iSTORE r1 INC
    {sp} r1 iSTORE
      r0 {rp0} MMOV stacksz {rp0} ADD
   {rp0} {sp0} MMOV stacksz {sp0} ADD
      r0 {up} MMOV r0 INC
      ip r0 iLOAD r0 INC
     tos r0 iLOAD r0 INC
    {rp} r0 iLOAD r0 INC
    {sp} r0 iLOAD
  then ;a
[else]
:m pause ;m                        ( -- [disabled] )
[then]

there half primitive t!            ( set 'primitive', needed for VM )
