defined eforth [if] ' ) <ok> ! [then] ( Turn off ok prompt )

\ MUXLEQ eForth Cross-Compiler and Virtual Machine
\
\ This file contains a cross compiler and eForth interpreter for the
\ two-instruction MUXLEQ CPU architecture. This version of Forth is
\ derived from an eForth implementation designed for a 16-bit MUXLEQ CPU.
\
\ The MUXLEQ architecture extends SUBLEQ with a multiplexing operation:
\ - SUBLEQ: Mem[b] = Mem[b] - Mem[a]; if Mem[b] <= 0 then pc = c
\ - MUX: If c < -1, then Mem[b] = (Mem[a] & ~Mem[c]) | (Mem[b] & Mem[c])
\ - I/O: a=-1 for input, b=-1 for output, c=-1 to halt
\
\ The cross compiler is compatible with Gforth and has been tested.

only forth definitions hex

\ Feature Configuration
1 constant opt.multi      ( Enable multitasking with "pause" primitive )
1 constant opt.editor     ( Include block-based text editor )
1 constant opt.better-see ( Enhanced decompiler for "see" command )
1 constant opt.control    ( Extended control structures do/loop, case/of )
1 constant opt.allocate   ( Dynamic memory allocation allocate/free )
1 constant opt.glossary   ( Word glossary and analysis tools )
1 constant opt.divmod     ( Hardware division/modulo primitive )
 1 constant opt.rv32i      ( RV32I microcode interpreter )
\ RV32I guest RAM lives in a fixed high-memory window ($7000 byte = cell $3800), NOT baked into the
\ image (same trick as buf0/=thread): only touched while running an RV program, never during
\ self-host bootstrap, so it costs zero image cells. Base is a plain forth constant so the tvar
\ block (rvrambase) and the runner (rv-ram) both read it.
7000 constant rvram       ( RV32I: guest-RAM base byte address; guest cell 0 lives here )

\ System options bit flags
: sys.echo-off 1 or ;     ( bit #1 = turn character echoing off )
: sys.cksum    2 or ;     ( bit #2 = enable system checksumming )
: sys.eof      8 or ;     ( bit #4 = terminate on EOF )
0 sys.eof sys.echo-off constant opt.sys

\ Compatibility Layer for Different Forth Systems
defined (order) 0= [if]
: (order) ( w wid*n n -- wid*n w n )
  dup if
    1- swap >r recurse over r@ xor
    if 1+ r> -rot exit then rdrop
  then ;
: -order get-order (order) nip set-order ; ( wid -- )
: +order dup >r -order get-order r> swap 1+ set-order ;
[then]

defined [unless] 0= [if]
: [unless] 0= postpone [if] ; immediate
[then]

defined eforth [if]
  : wordlist here cell allot 0 over ! ; ( -- wid : allocate wordlist )
[then]

\ Meta-Compiler Vocabulary Setup
wordlist constant meta.1        ( Meta-compiler word set )
wordlist constant target.1      ( Target eForth word set )
wordlist constant assembler.1   ( MUXLEQ assembler word set )
wordlist constant target.only.1 ( Target-only word set )

defined eforth [if] system +order [then]
meta.1 +order definitions

\ Target System Constants
   2 constant =cell   ( Target cell size in bytes )
\ tflash working area. Self-host needs the running image + this buffer + the metacompiler's own
\ dictionary growth to fit in the VM's 32768 cells. The RV32I microcode grows the image, so shrink
\ the buffer when opt.rv32i is on to keep that sum under the ceiling; the base eForth keeps 0x4000.
opt.rv32i [if] 3000 [else] 4000 [then] constant size    ( Size of image working area )
 100 constant =buf    ( Size of text input buffers in target )
 100 constant =stksz  ( Size of return and variable stacks )
FC00 constant =thread ( Initial start of thread area )
0008 constant =bksp   ( Backspace character value )
000A constant =lf     ( Line feed character value )
000D constant =cr     ( Carriage Return character value )
007F constant =del    ( Delete character )

\ Target Memory Management
create tflash tflash size cells allot size erase  \ Target memory image
variable tzreg 0 tzreg !        ( Target zero register address )
variable tareg 1 tareg !        ( Target A register address )
variable tdp 0 tdp !            ( Target dictionary pointer )
variable tlast 0 tlast !        ( Last defined target word pointer )
variable tlocal 0 tlocal !      ( Local variable allocator )
variable voc-last 0 voc-last !  ( Last defined in any vocabulary )

\ Meta-Compiler Core Words
: :m meta.1 +order definitions : ; \ Start meta-compiler definition
: ;m postpone ; ; immediate         \ End meta-compiler definition

:m tcell 2 ;m                      ( -- 2 : bytes in a target cell )
:m there tdp @ ;m                  ( -- a : target dictionary pointer )
:m tc! tflash + c! ;m              ( c a -- : target write char )
:m tc@ tflash + c@ ;m              ( a -- c : target get char )
:m t! over FF and over tc! swap 8 rshift swap 1+ tc! ;m ( u a -- : store )
:m t@ dup tc@ swap 1+ tc@ 8 lshift or ;m ( a -- u : target fetch )
:m taligned dup 1 and + ;m         ( u -- u : align target pointer )
:m talign there 1 and tdp +! ;m    ( -- : align target dic. pointer )
:m tc, there tc! 1 tdp +! ;m       ( c -- : write char to target dic. )
:m t, there t! 2 tdp +! ;m         ( u -- : write cell to target dic. )
:m tallot tdp +! ;m                ( u -- : allocate bytes in target dic. )
:m mdrop drop ;m                   ( u -- : always call drop )
:m mswap swap ;m                   ( u u -- u u : always call swap )
:m mdecimal decimal ;m             ( -- : always call decimal )
:m mhex hex ;m                     ( -- : always call hex )

\ String packing for different Forth systems
defined eforth [if]
  :m tpack dup tc, for aft count tc, then next drop ;m
  :m parse-word bl word ?nul count ;m ( -- a u )
  :m limit ;m                       ( u -- u16 : not needed on 16-bit )
[else]
  :m tpack talign dup tc, 0 ?do count tc, loop drop ;m
  :m limit FFFF and ;m              ( u -- u16 : limit to 16 bits )
[then]

:m $literal talign [char] " word count tpack talign ;m

\ Number output for different systems
defined eforth [if]
:m #dec s>d if [char] - emit then (.) ;m ( n16 -- )
[else]
  :m #dec dup 8000 u>= if negate limit -1 >r else 0 >r then
     0 <# #s r> sign #> type ;m ( n16 -- )
[then]

:m msep A emit ;m                  ( -- : emit space as separator )
:m mdump taligned                  ( a u -- : dump target memory )
  begin ?dup
  while swap dup @ limit #dec msep tcell + swap tcell -
  repeat drop ;m
:m save-target decimal tflash there mdump ;m ( -- : output target image )
:m .end only forth definitions decimal ;m     ( -- : cleanup and exit )

\ Target Word Creation and Management
:m atlast tlast @ ;m               ( -- a : last defined target word )
:m local? tlocal @ ;m              ( -- u : local variable offset )
:m lallot >r tlocal @ r> + tlocal ! ;m ( u -- : allocate in locals )

:m tuser                           ( --, "name", Created-Word: -- u )
  get-current >r meta.1 set-current create r>
  set-current tlocal @ =cell lallot , does> @ ;m

:m tvar get-current >r             ( --, "name", Created-Word: -- a )
     meta.1 set-current create
   r> set-current there , t, does> @ ;m

:m label: get-current >r           ( --, "name", Created-Word: -- a )
     meta.1 set-current create
   r> set-current there , does> @ ;m

:m tdown =cell negate and ;m       ( a -- a : align down )
:m tnfa =cell + ;m                 ( pwd -- nfa : move to name field )
:m tcfa tnfa dup c@ 1F and + =cell + tdown ;m ( pwd -- cfa : to code field )
:m compile-only voc-last @ tnfa t@ 20 or voc-last @ tnfa t! ;m
:m immediate   voc-last @ tnfa t@ 40 or voc-last @ tnfa t! ;m
:m half dup 1 and abort" unaligned" 2/ ;m ( a -- a : meta 2/ )
:m double 2* ;m                    ( a -- a : meta-comp 2* )

\ Word finding and compilation
defined eforth [if]
:m (') bl word find ?found cfa ;m
:m t' (') >body @ ;m               ( --, "name" )
:m to' target.only.1 +order (') >body @ target.only.1 -order ;m
[else]
:m t' ' >body @ ;m                 ( --, "name" )
:m to' target.only.1 +order ' >body @ target.only.1 -order ;m
[then]

:m tcompile to' half t, ;m
:m >tbody =cell + ;m
:m tcksum taligned dup C0DE - FFFF and >r ( a u -- u : checksum )
   begin ?dup
   while swap dup t@ r> + FFFF and >r =cell + swap =cell -
   repeat drop r> ;m
:m mkck dup there swap - tcksum ;m ( -- u : checksum of image )
:m postpone                        ( --, "name" )
   target.only.1 +order t' target.only.1 -order 2/ t, ;m

\ Target Word Header Creation
:m thead talign there tlast @ t, dup tlast ! voc-last !
   parse-word talign tpack talign ;m ( --, "name" )
:m header >in @ thead >in ! ;m     ( --, "name" )

:m :ht                             ( "name" -- : forth routine, no header )
  get-current >r target.1 set-current create
  r> set-current CAFE talign there ,
  does> @ 2/ t, ;m

:m :t header :ht ;m                ( "name" -- : forth routine )
:m :to                             ( "name" -- : forth, target only )
  header
  get-current >r
    target.only.1 set-current create
  r> set-current
  CAFE talign there ,
  does> @ 2/ t, ;m

:m :a                              ( "name" -- : assembly routine )
  1234 target.1 +order definitions
  create talign there , assembler.1 +order does> @ 2/ t, ;m

:m (fall-through); 1234 <>
   if abort" unstructured" then assembler.1 -order ;m
:m (a); (fall-through); ;m

defined eforth [if] system -order [then]

\ MUXLEQ Assembly Language Primitives
:m Z tzreg @ t, ;m                 ( -- : Address 0 must contain 0 )
:m A, Z ;m                         ( -- : Synonym for 'Z', temp location )
:m V, tareg @ t, ;m                ( -- : Address 1 also contains 0 )
:m NADDR there 2/ 1+ t, ;m         ( --, jump to next cell )
:m HALT Z Z -1 t, ;m               ( --, Halt the virtual machine )
:m JMP 2/ Z Z t, ;m                ( a --, Jump to location )
:m ADD swap 2/ t, Z NADDR Z 2/ t, NADDR Z Z NADDR ;m
:m SUB swap 2/ t, 2/ t, NADDR ;m   ( a a -- : subtract )
:m NOOP Z Z NADDR ;m               ( -- : No operation )
:m ZERO dup 2/ t, 2/ t, NADDR ;m   ( a -- : zero a location )
:m PUT 2/ t, -1 t, NADDR ;m        ( a -- : output a byte )
:m GET 2/ -1 t, t, NADDR ;m        ( a -- : input a byte )

\ MUXLEQ Assembler Control Structures
assembler.1 +order definitions
: begin talign there ;             ( -- a )
: again JMP ;                      ( a -- )
: mark there 0 t, ;                ( -- a : create hole in dictionary )
: if talign                        ( a -- a : conditional branch )
   2/ dup t, Z there 2/ 4 + dup t, Z Z 6 + t, Z Z NADDR Z t,
   mark ;
: until 2/ dup t, Z there 2/ 4 + dup t, Z Z 6 + t,
   Z Z NADDR Z t, 2/ t, ;          ( a -- a )
: else talign Z Z mark swap there 2/ swap t! ; ( a -- a )
: +if talign Z 2/ t, mark ;        ( a -- a )
: -if talign
   2/ t, Z there 2/ 4 + t, Z Z there 2/ 4 + t, Z Z mark ;
: then begin 2/ swap t! ;          ( a -- )
: while if swap ;                  ( a a -- a a )
: repeat JMP then ;                ( a a -- )
assembler.1 -order

\ Target System Variables and Memory Layout
meta.1 +order definitions
  0 t, 0 t,                        \ both locations must be zero
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
  \ decode: rvo-alt = funct7 bit5 = instr bit 30 = ir_hi >> 14 & 1  (ADD/SUB, SRL/SRA discriminator)
  rvih rvs1lo MMOV  rvc14 rvsh MMOV  one rvmask MMOV
  rvr15 rvlink MMOV  t' rvfield.sub JMP  label: rvd6  rvrlo rvo-alt MMOV
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
rvd5 half rvr11 t!  rvd6 half rvr15 t!  ( rvd4/rvr10 dropped: rs1-low now uses a direct mask )
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

\ Target Word Definition Infrastructure
:m munorder target.only.1 -order talign ;m
:m (;t)
   CAFE <> if abort" Unstructured" then
   munorder ;m
:m ;t (;t) opExit ;m
:m :s tlast @ {system} t@ tlast ! F00D :t drop 0 ;m
:m :so  tlast @ {system} t@ tlast ! F00D :to drop 0 ;m
:m ;s drop CAFE ;t F00D <> if abort" unstructured" then
  tlast @ {system} t! tlast ! ;m
:m :r tlast @ {root-voc} t@ tlast ! BEEF :t drop 0 ;m
:m ;r drop CAFE ;t BEEF <> if abort" unstructured" then
  tlast @ {root-voc} t! tlast ! ;m
:m :e tlast @ {editor} t@ tlast ! DEAD :t drop 0 ;m
:m ;e drop CAFE ;t DEAD <> if abort" unstructured" then
  tlast @ {editor} t! tlast ! ;m
:m system[ tlast @ {system} t@ tlast ! BABE ;m
:m ]system BABE <> if abort" unstructured" then
   tlast @ {system} t! tlast ! ;m
:m root[ tlast @ {root-voc} t@ tlast ! D00D ;m
:m ]root D00D <> if abort" unstructured" then
   tlast @ {root-voc} t! tlast ! ;m

\ Cross-Compiler Control Structures
:m : :t ;m                         ( -- ???, "name" : start cross-compilation )
:m ; ;t ;m                         ( ??? -- : end cross-compilation )
:m begin talign there ;m           ( -- a : meta 'begin' )
:m until talign opJumpZ 2/ t, ;m   ( a -- : meta 'until' )
:m again talign opJump  2/ t, ;m   ( a -- : meta 'again' )
:m if opJumpZ there 0 t, ;m        ( -- a : meta 'if' )
:m tmark opJump there 0 t, ;m      ( -- a : meta mark location )
:m then there 2/ swap t! ;m        ( a -- : meta 'then' )
:m else tmark swap then ;m         ( a -- a : meta 'else' )
:m while if ;m                     ( -- a : meta 'while' )
:m repeat swap again then ;m       ( a a -- : meta 'repeat' )
:m aft drop tmark begin swap ;m    ( a -- a a : meta 'aft' )
:m next talign opNext 2/ t, ;m     ( a -- : meta 'next' )
:m for opToR begin ;m              ( -- a : meta 'for' )

\ Execution token constants
:m =jump   [ t' opJump  half ] literal ;m ( -- a )
:m =jumpz  [ t' opJumpZ half ] literal ;m ( -- a )
:m =unnest [ t' opExit  half ] literal ;m ( -- a )
:m =>r     [ t' opToR   half ] literal ;m ( -- a )
:m =next   [ t' opNext  half ] literal ;m ( -- a )

\ Compile commonly used primitives
:m dup opDup ;m                    ( -- : compile opDup into dictionary )
:m drop opDrop ;m                  ( -- : compile opDrop into dictionary )
:m swap opSwap ;m                  ( -- : compile opSwap into dictionary )
:m >r opToR ;m                     ( -- : compile opToR into dictionary )
:m r> opFromR ;m                   ( -- : compile opFromR into dictionary )
:m 0= op0= ;m                      ( -- : compile op0= into dictionary )
:m mux opMux ;m                    ( -- : compile opMux into dictionary )
:m exit opExit ;m                  ( -- : compile opExit into dictionary )
:m rshift shift ;m                 ( -- : compile shift into dictionary )

\ Core Target Forth Words
:to + + ; ( n n -- n : addition )
:to - - ; ( n1 n2 -- n : subtract n2 from n1 )
:to bye bye ; ( -- : halt the system )
:to dup dup ; ( n -- n n : duplicate top of stack )
:to drop opDrop ; ( n -- : drop top of variable stack )
:to swap opSwap ; ( x y -- y x : swap two variables on stack )
:to rshift shift ; ( u n -- u : logical right shift by "n" )
:so [@] [@] ;s ( vma -- : fetch -VM Address- )
:so [!] [!] ;s ( u vma -- : store to -VM Address- )
:to 0= op0= ; ( n -- f : equal to zero )
:so leq0 leq0 ;s ( n -- 0|1 : less than or equal to zero )
:so mux opMux ;s ( u1 u2 sel -- u : bitwise multiplex op. )
:so pause pause ;s ( -- : pause current task, task switch )

: 2* dup + ; ( u -- u : multiply by two )

\ Constant creation
:s (const) r> [@] ;s compile-only  ( R: a --, -- u )
:m constant :t mdrop (const) t, munorder ;m

\ System constants
system[
 0 constant #0                     ( --  0 : push the number zero )
 1 constant #1                     ( --  1 : push one )
-1 constant #-1                    ( -- -1 : push negative one )
 2 constant #2                     ( --  2 : push two )
-2 constant -cell                  ( -- -2 : push negative two )
]system

: 1+ #1 + ;                        ( n -- n : increment value )
: 1- #1 - ;                        ( n -- n : decrement value )

\ Literal compilation
:s (push) r> dup [@] swap 1+ >r ;s ( -- n : inline push value )
:m lit (push) t, ;m                ( n -- : compile a literal )
:m literal lit ;m                  ( n -- : synonym for "lit" )
:m ] ;m                            ( -- : meta-compiler version of "]" )
:m [ ;m                            ( -- : meta-compiler version of "[" )

\ User variables and other runtime constructs
:s (up) r> dup [@] [ {up} half ] literal [@] 2* + swap 1+ >r ;s
  compile-only                     ( -- n : user variable implementation )
:s (var) r> 2* ;s compile-only     ( R: a --, -- a )
:s (user) r> [@] [ {up} half ] literal [@] 2* + ;s compile-only
  ( R: a --, -- u )
:m up (up) t, ;m                   ( n -- : compile user variable )
:m [char] char (push) t, ;m        ( --, "name" : compile char )
:m char   char (push) t, ;m        ( --, "name" : compile char )
:m variable :t mdrop (var) 0 t, munorder ;m ( --, "name": create variable )
:m user :t mdrop (user) local? =cell lallot t, munorder ;m

:to ) ; immediate                  ( -- : NOP, terminate comment )

\ Extended Forth Words
: over swap dup >r swap r> ;       ( n1 n2 -- n1 n2 n1 )
: invert #-1 swap - ;              ( u -- u : bitwise invert )
: xor >r dup invert swap r> mux ;  ( u u -- u : bitwise xor )
: or over mux ;                    ( u u -- u : bitwise or )
: and #0 swap mux ;                ( u u -- u : bitwise and )
: 2/ #1 rshift ;                   ( u -- u : divide by two )
: @ 2/ [@] ;                       ( a -- u : fetch a cell )
: ! 2/ [!] ;                       ( u a -- : write a cell )
:s @+ dup @ ;s                     ( a -- a u : non-destructive load )

\ User variables for I/O vectoring
user <ok>                          ( -- a : okay prompt xt location )
system[
  user <emit>                      ( -- a : emit xt location )
  user <key>                       ( -- a : key xt location )
  user <echo>                      ( -- a : echo xt location )
  user <literal>                   ( -- a : literal xt location )
  user <tap>                       ( -- a : tap xt location )
  user <expect>                    ( -- a : expect xt location )
  user <error>                     ( -- a : error xt container )
]system

\ System access words
:s <boot> [ {boot} ] literal ;s    ( -- a : cold xt location )
:s <quit> [ {quit} ] literal ;s    ( -- a : quit xt location )
: current [ {current} ] literal ;  ( -- a : get current vocabulary )
: root-voc [ {root-voc} ] literal ; ( -- a : get root vocabulary )
: this [ 0 ] up ;                  ( -- a : address of task thread memory )
: pad this [ 3C0 ] literal + ;     ( -- a : index into pad area )

8 constant #vocs                   ( -- u : number of vocabularies )
: context [ {context} ] literal ;  ( -- a )

\ More variables
variable blk                       ( -- a : loaded block )
variable scr                       ( -- a : latest listed block )
2F t' scr >tbody t!                ( Set default block to list )

user base                          ( -- a : numeric radix )
user dpl                           ( -- a : decimal point variable )
user hld                           ( -- a : hold space index for numeric I/O )
user state                         ( -- f : interpreter state )
user >in                           ( -- a : input buffer position )
user span                          ( -- a : number of chars saved by expect )

$20 constant bl                    ( -- 32 : space character )

\ System information
system[
       h constant h?               ( -- a : dictionary pointer location )
{cycles} constant cycles           ( -- a : number of task switches )
    {sp} constant sp              ( -- a : variable stack pointer )
  {user} constant user?           ( -- a : user allocation variable )
         variable calibration 1400 t' calibration >tbody t!
]system

\ Arithmetic and Logic Operations
:s radix base @ ;s                 ( -- u : retrieve base )
: here h? @ ;                      ( -- u : dictionary pointer )
: sp@ sp @ 1+ ;                    ( -- a : Fetch variable stack pointer )
: sp! 1- [ {sp} half ] literal [!] #1 drop ;
: rp@ [ {rp} half ] literal [@] 1- ; compile-only
: rp! r> swap [ {rp} half ] literal [!] >r ; compile-only
: hex [ $10 ] literal base ! ;     ( -- : hexadecimal base )
: decimal [ $A ] literal base ! ;  ( -- : decimal base )
: octal [ $8 ] literal base ! ;    ( -- : octal base )
:to ] #-1 state ! ;                ( -- : return to compile mode )
:to [  #0 state ! ; immediate      ( -- : initiate command mode )
: nip swap drop ;                  ( x y -- y : remove second item )
: tuck swap over ;                 ( x y -- y x y : save item )
: ?dup dup if dup then ;           ( x -- x x | 0 : conditional dup )
: r@ r> r> tuck >r >r ; compile-only ( R: n -- n, -- n )
: rot >r swap r> swap ;            ( x y z -- y z x : "rotate" stack )
: -rot rot rot ;                   ( x y z -- z x y : reverse rotate )
: 2drop drop drop ;                ( x x -- : drop two items )
: 2dup  over over ;                ( x y -- x y x y )
:s shed rot drop ;s                ( x y z -- y z : drop third stack item )

\ Comparison operators
: = - 0= ;                         ( u1 u2 -- f : equality )
: <> = 0= ;                        ( u1 u2 -- f : inequality )
: 0> leq0 0= ;                     ( n -- f : greater than zero )
: 0<> 0= 0= ;                      ( n -- f : not equal to zero )
: 0<= 0> 0= ;                      ( n -- f : less than or equal to zero )

: <                                ( n1 n2 -- f : less than )
   2dup leq0 swap leq0 if
     if
       2dup 1+ leq0 swap 1+ leq0
       if drop else if 2drop #0 exit then then
     else 2drop #-1 exit then     \ a0 && !b0
   else
     if 2drop #0 exit then        \ !a0 && b0
   then
   2dup - leq0 if
     swap 1+ swap - leq0 if #-1 exit then
     #0 exit
   then
   2drop #0 ;

: > swap < ;                       ( n1 n2 -- f : signed greater than )
: 0< #0 < ;                        ( n -- f : less than zero )
: 0>= 0< 0= ;                      ( n1 n2 -- f : greater or equal to zero )
: >= < 0= ;                        ( n1 n2 -- f : greater than or equal to )
: <= > 0= ;                        ( n1 n2 -- f : less than or equal to )
: u< 2dup 0>= swap 0>= <> >r < r> <> ; ( u1 u2 -- f : unsigned less than )
: u> swap u< ;                     ( u1 u2 -- f : unsigned greater than )
: u>= u< 0= ;                      ( u1 u2 -- f : unsigned greater or equal )
: u<= u> 0= ;                      ( u1 u2 -- f : unsigned less or equal )
: within over - >r - r> u< ;       ( u lo hi -- f )
: negate 1- invert ;               ( n -- n : twos complement negation )
: s>d dup 0< ;                     ( n -- d : signed to double width cell )
: abs s>d if negate then ;         ( n -- u : absolute value )

\ Cell and address arithmetic
2 constant cell                    ( -- u : bytes in cells )
: cell+ cell + ;                   ( a -- a : increment address by cell width )
: cells 2* ;                       ( u -- u : multiply # of cells to get bytes )
: th cells + ;                     ( a n -- a' : address of the n-th cell of array a )
opt.rv32i [if]
:to rvrd rvrd ;                    ( -- : SRC1 = reg[rvidx] )
:to rvwr rvwr ;                    ( -- : reg[rvidx] = RSLT, x0 discarded )
:to rvstep rvstep ;                ( -- : decode+execute one R-type word from rv-il/rv-ih )
rvil constant rv-il                ( -- a : instruction word low half )
rvih constant rv-ih                ( -- a : instruction word high half )
rvpclo constant rv-pclo  rvpchi constant rv-pchi   ( -- a : RVPC byte-address low/high halves )
rvo-ctrl constant rv-ctrl          ( -- a : 1 if the last-decoded op set RVPC itself, else 0 )
rvstate constant rv-state          ( -- a : 1 if the last op was an ecall the host must service, else 0 )
rvram constant rv-ram              ( -- a : guest-RAM base; cell i is at rv-ram 2* i * + )
rvo-rd  constant rv-rd             ( -- a : decoded rd, for the harness to read the result )
rvsh constant rv-sh                ( -- a : SLL shift amount cell )
rvidx constant rv-idx              ( -- a : register index cell )
rvmask constant rv-mask            ( -- a : field-extract mask cell )
rvs1lo constant rv-s1lo  rvs1hi constant rv-s1hi   ( -- a : SRC1 low/high halves )
rvs2lo constant rv-s2lo  rvs2hi constant rv-s2hi   ( -- a : SRC2 low/high halves )
rvrlo  constant rv-rlo   rvrhi  constant rv-rhi    ( -- a : RSLT low/high halves )
[then]
: cell- cell - ;                   ( a -- a : decrement address by cell width )
: execute 2/ >r ;                  ( xt -- : execute an execution token )
:s @execute ( ?dup 0= ?exit ) @ execute ;s ( xt -- )
: ?exit if rdrop then ; compile-only ( u --, R: -- |??? )

\ Input/Output and Terminal Control
: key? pause opGet                 ( -- c 0 | -1 : get byte of input )
   s>d if
     [ {options} ] literal @
     [ 8 ] literal and if bye then drop #0 exit
   then #-1 ;
: key begin <key> @execute until ; ( -- c )
: emit <emit> @execute ;           ( c -- : output byte )
: cr                               ( -- : emit new line )
  [ =cr ] literal emit
  [ =lf ] literal emit ;
: get-current current @ ;          ( -- wid : get definitions vocab. )
: set-current current ! ;          ( -- wid : set definitions vocab. )
:s last get-current @ ;s           ( -- wid : get last defined word )
: pick sp@ + [@] ;                 ( nu...n0 u -- nu : pick item on stack )
: 2swap rot >r rot r> ;            ( a b c d -- c d a b )
: 2over [ 3 ] literal pick [ 3 ] literal pick ; ( a b c d -- a b c d a b )
: +! 2/ tuck [@] + swap [!] ;      ( u a -- : add value to cell )
: lshift negate shift ;            ( u n -- u : left shift 'u' by 'n' )

\ Character operations
: c@                               ( a -- c : character load )
  @+ swap #1 and if
    [ 8 ] literal rshift exit
  then [ FF ] literal and ;
: c! swap [ FF ] literal and dup [ 8 ] literal lshift or swap
   tuck @+ swap #1 and 0= [ FF ] literal xor
   >r over xor r> and xor swap ! ; ( c a -- : character store )
:s c@+ dup c@ ;s                   ( b -- b u : non-destructive 'c@' )

\ Utility words
: max 2dup > mux ;                 ( n1 n2 -- n : highest of two numbers )
: min 2dup < mux ;                 ( n1 n2 -- n : lowest of two numbers )
: source-id [ {id} ] up @ ;        ( -- u : input type )
: 2! tuck ! cell+ ! ;              ( u1 u2 a -- : store two cells )
: 2@ dup cell+ @ swap @ ;          ( a -- u1 u2 : fetch two cells )
: 2>r r> swap >r swap >r >r ; compile-only ( n n --,R: -- n n )
: 2r> r> r> swap r> swap >r ; compile-only ( -- n n,R: n n -- )

system[ user tup =cell tallot ]system
: source tup 2@ ;                  ( -- a u : get terminal input source )
: aligned dup #1 and 0<> #1 and + ; ( u -- u : align up pointer )
: align here aligned h? ! ;        ( -- : align up dictionary pointer )
: allot h? +! ;                    ( n -- : allocate space in dictionary )
: , align here ! cell allot ;      ( u -- : write value into dictionary )
: c, here c! #1 allot ;            ( c -- : write character into dictionary )
: count dup 1+ swap c@ ;           ( b -- b c : advance string )
: +string #1 over min rot over + -rot - ; ( b u -- b u )

\ String and Text Processing
:s .emit                           \ c -- : print char, replacing non-graphic
  dup bl [ $7F ] literal within [char] . swap mux emit ;s
: type 1- for count emit next drop ; ( a u -- : type string )
: cmove                            ( b1 b2 n -- : move character blocks )
  #0 max for aft >r c@+ r@ c! 1+ r> 1+ then next 2drop ;
: fill                             ( b n c -- : fill array with character )
  swap #0 max for swap aft 2dup c! 1+ then next 2drop ;
: erase #0 fill ;                  ( b u -- : write zeros to array )

\ String literals
:s do$ 2r> 2* dup count + aligned 2/ >r swap >r ;s ( -- a )
:s ($) do$ ;s                      ( -- a : string address )
:s .$ do$ count type ;s            ( -- : print string in next cells )
:m ." .$ $literal ;m               \ --, ccc" : compile string
:m $" ($) $literal ;m              \ --, ccc" : compile string
: space bl emit ;                  ( -- : emit a space )
: chars ;                          ( n -- n : char count to au; identity, bytes are the unit )
: spaces                           ( n -- : emit n spaces, nothing for n<=0 )
  begin dup 0> while space 1- repeat drop ;

\ Exception Handling
: catch                            ( xt -- exception# | 0 )
   sp@ >r                          \ save data stack pointer
   [ {handler} ] up @ >r           \ and previous handler
   rp@ [ {handler} ] up !          \ set current handler
   execute                         \ execute returns if no throw
   r> [ {handler} ] up !           \ restore previous handler
   rdrop                           \ discard saved stack ptr
   #0 ;                            \ normal completion

: throw                            ( ??? exception# -- ??? exception# )
  ?dup if                          \ 0 throw is no-op
    [ {handler} ] up @ rp!         \ restore previous return stack
    r> [ {handler} ] up !          \ restore previous handler
    r> swap >r                     \ exception# on return stack
    sp! r>                         \ restore stack
  then ;

: abort #-1 throw ;                ( -- : abort execution )
:s (abort) do$ swap if count type abort then drop ;s ( n -- )
: depth [ {sp0} ] literal @ sp@ - 1- ;  ( -- n : stack depth; promoted to the forth vocab )
:s ?depth depth >= [ -$4 ] literal and throw ;s ( ??? n -- )

\ Double-Precision Arithmetic
: um+ 2dup + >r r@ 0>= >r          ( u u -- u carry )
  2dup and 0< r> or >r or 0< r> and negate r> swap ;
: dnegate invert >r invert #1 um+ r> + ; ( d -- d )
: d+ >r swap >r um+ r> + r> + ;    ( d d -- d )
: um*                              ( u u -- ud : double cell width multiply )
  #0 swap
  [ $F ] literal for               \ 16 times
    dup um+ 2>r dup um+ r> + r>
    if >r over um+ r> + then
  next shed ;
: * um* drop ;                     ( n n -- n : multiply two numbers )
: um/mod                           ( ud u -- ur uq : unsigned double div/mod )
  ?dup 0= [ -$A ] literal and throw \ divisor is non zero?
  2dup u<
  if
    negate
    [ $F ] literal for             \ 16 times
      >r dup um+ 2>r dup um+ r> + dup
      r> r@ swap >r um+ r> 0<> swap 0<> +
      if >r drop 1+ r> else drop then r>
    next
    drop swap exit
  then 2drop drop #-1 dup ;

: m/mod                            ( d n -- r q : floored division )
  s>d dup >r
  if negate >r dnegate r> then
  >r s>d if r@ + then r> um/mod r>
  if swap negate swap then ;
: /mod over 0< swap m/mod ;        ( u1 u2 -- u1%u2 u1/u2 )
: mod /mod drop ;                  ( u1 u2 -- u1%u2 )
: /   /mod nip ;                   ( u1 u2 -- u1/u2 )
: m*  2dup xor 0< >r abs swap abs um* r> if dnegate then ; ( n n -- d : signed double product )
: */mod >r m* r> m/mod ;           ( n1 n2 n3 -- rem quot : n1*n2/n3, double intermediate )
: */  */mod nip ;                  ( n1 n2 n3 -- quot : scaling multiply then divide )

\ Terminal I/O and Line Editing
:s (emit) pause opEmit ;s          ( c -- : output byte to terminal )
: echo <echo> @execute ;           ( c -- : emit a single character )
:s tap dup echo over c! 1+ ;s      ( bot eot cur c -- bot eot cur )
:s ktap                            ( bot eot cur c -- bot eot cur )
  \ Not EOL?
  dup dup [ =cr ] literal <> >r [ =lf ] literal  <> r> and if
    \ Not Del Char?
    dup [ =bksp ] literal <> >r [ =del ] literal <> r> and if
      bl tap                       \ replace any other character with bl
      exit
    then
    >r over r@ < dup if            \ if not at start of line
      [ =bksp ] literal dup echo bl echo echo \ erase char
    then
    r> +                           \ add 0/-1 to cur
    exit
  then drop nip dup ;s             \ set cur = eot

: accept                           ( b u -- b u : read line of user input )
  over + over begin
    2dup <>
  while
    key dup
    bl - [ $5F ] literal u<        \ magic: within 32-127?
    if tap else <tap> @execute then
  repeat drop over - ;

: expect <expect> @execute span ! drop ; ( a u -- )
: tib source drop ;                ( -- b : get Terminal Input Buffer )
: query                            ( -- : get new line of input )
  tib [ =buf ] literal <expect> @execute tup ! drop #0 >in ! ;
: -trailing for aft                ( b u -- b u : remove trailing spaces )
     bl over r@ + c@ < if r> 1+ exit then
   then next #0 ;

\ Text Parsing and Word Recognition
:s look                            \ b u c xt -- b u : skip until test succeeds
  swap >r -rot
  begin
    dup
  while
    over c@ r@ - r@ bl = [ 4 ] literal pick execute
    if rdrop shed exit then
    +string
  repeat rdrop shed ;s

:s unmatch if 0> exit then 0<> ;s  ( c1 c2 -- t )
:s match unmatch invert ;s         ( c1 c2 -- t )

: parse                            ( c -- b u ; <string> )
  >r tib >in @ + tup @ >in @ - r@
  >r over r> swap 2>r
  r@ [ t' unmatch ] literal look 2dup
  r> [ t' match   ] literal look swap
    r> - >r - r> 1+
  >in +!
  r> bl = if -trailing then
  #0 max ;

\ Number formatting
:s banner                          ( +n c -- : output 'c' 'n' times )
  >r begin dup 0> while r@ emit 1- repeat drop rdrop ;s
: hold #-1 hld +! hld @ c! ;       ( c -- : save char in hold space )
: #> 2drop hld @ this [ =num ] literal + over - ; ( u -- b u )
:s extract                         ( ud ud -- ud u : extract digit from number )
  dup >r um/mod r> swap >r um/mod r> rot ;s
:s digit                           ( u -- c : extract a character from number )
  [ 9 ] literal over < [ 7 ] literal and + [char] 0 + ;s
: #  #2 ?depth #0 radix extract digit hold ; ( d -- d )
: #s begin # 2dup or 0= until ;    ( d -- 0 )
: <# this [ =num ] literal + hld ! ; ( -- : start numeric output )
: sign 0>= ?exit [char] - hold ;   ( n -- )
: u.r >r #0 <# #s #> r> over - bl banner type ; ( u r -- )
: .r >r dup >r abs #0 <# #s r> sign #> r> over - bl banner type ; ( n r -- : signed, right-justified in field r )
: u. space #0 u.r ;                ( u -- : unsigned numeric output )

opt.divmod [if]
:s (.) abs radix opDivMod ?dup if (.) then digit emit ;s
: . space s>d if [char] - emit then (.) ; ( n -- )
[else]
: . space dup >r abs #0 <# #s r> sign #> type ; ( n -- )
[then]

\ Number Input and Conversion
: >number                          ( ud b u -- ud b u : convert string to number )
  dup 0= ?exit
  begin
    2dup 2>r drop c@ radix
    >r [char] 0 - [ 9 ] literal over <
    if
    [ 7 ] literal - dup [ $A ] literal < or then dup r> u<
    0= if
      drop
      2r>
      exit
    then
    swap radix um* drop rot radix um* d+
    2r>
    +string dup 0=
  until ;

: number?                          ( a u -- d -1 | a u 0 )
  #-1 dpl !
  radix >r
  over c@ [char] - = dup >r if +string then
  over c@ [char] $ = if hex +string then
  2>r #0 dup 2r>
  begin
    >number dup
  while over c@ [char] . <>
    if shed rot r> 2drop #0 r> base ! exit then
    1- dpl ! 1+ dpl @
  repeat
  2drop r> if dnegate then r> base ! #-1 ;

: .s depth for aft r@ pick . then next ; ( -- : show stack )

\ String Comparison and Dictionary Search
: compare                          ( a1 u1 a2 u2 -- n : string comparison )
  rot
  over - ?dup if >r 2drop r> nip exit then
  for
    aft
      count rot count rot - ?dup
      if rdrop nip nip exit then
    then
  next 2drop #0 ;

: nfa cell+ ;                      ( pwd -- nfa : move to name field address )
: cfa                              ( pwd -- cfa : move to Code Field Address )
  nfa c@+ [ 1F ] literal and + cell+ -cell and ;

:s (search)                        ( a wid -- PWD PWD 1 | PWD PWD -1 | 0 a 0 )
  ( Search for word "a" in "wid" )
  swap >r dup
  begin
    dup
  while
    \ $9F = $1F:word-length + $80:hidden
    dup nfa count [ $9F ] literal
    and r@ count compare 0=
    if ( found! )
      rdrop
      dup nfa [ $40 ] literal swap @ and 0<>
      #1 or negate exit
    then
    nip @+
  repeat
  rdrop 2drop #0 ;s

:s (find)                          ( a -- pwd pwd 1 | pwd pwd -1 | 0 a 0 )
  >r
  context
  begin
    @+
  while
    @+ @ r@ swap (search) ?dup
    if
      >r shed r> rdrop exit
    then
    cell+
  repeat drop #0 r> #0 ;s

: search-wordlist                  ( a wid -- PWD 1|PWD -1|a 0 )
   (search) shed ;
: find                             ( a -- pwd 1 | pwd -1 | a 0 )
  (find) shed ;
: compile r> dup [@] , 1+ >r ; compile-only ( -- )
:s (literal) state @ if compile (push) , then ;s ( u -- )
:to literal <literal> @execute ; immediate ( u -- )
: compile, 2/ , ;                  ( xt -- : compile execution token )
:s ?found ?exit                    ( b f -- b | ??? )
   space count type [char] ? emit cr [ -$D ] literal throw ;s

\ Interpreter and Compiler
: interpret                        ( b -- : interpret a counted word )
  find ?dup if
    state @
    if
      0> if cfa execute exit then ( execute immediate words )
      cfa compile, exit            ( compiling words are...compiled. )
    then
    drop
    ( perform "?compile" check )
    dup nfa c@ [ 20 ] literal and 0<> [ -$E ] literal and throw
    ( if not compiling, execute it then exit interpreter )
    cfa execute exit
  then
  ( not a word )
  dup >r count number? if rdrop    ( it is numeric! )
    dpl @ 0< if                    ( single cell number )
      drop                         ( drop high cell from 'number?' )
    else                           ( double cell number )
      state @ if swap then
      postpone literal             ( literal executed twice for double )
    then
    postpone literal exit
  then
  r> #0 ?found ;

\ Vocabulary and Search Order Management
: get-order                        ( -- widn...wid1 n : get current search order )
  context
   ( find first empty cell )
  #0 >r begin @+ r@ xor while cell+ repeat rdrop
  dup cell- swap
  context - 2/ dup >r 1- s>d [ -$32 ] literal and throw
  for aft @+ swap cell- then next @ r> ;

:r set-order                       ( widn ... wid1 n -- : set search order )
  dup #-1 = if drop root-voc #1 set-order exit then
  dup #vocs > [ -$31 ] literal and throw
  context swap for aft tuck ! cell+ then next #0 swap ! ;r

: (order)                          ( w wid*n n -- wid*n w n )
  dup if
    1- swap >r (order) over r@ xor
    if 1+ r> -rot exit then rdrop
  then ;
: -order                           ( wid -- : remove vocabulary from search order )
  get-order (order) nip set-order ;
: +order                           ( wid -- : add vocabulary to search order )
  dup >r -order get-order r> swap 1+ set-order ;

root[
  {forth-wordlist} constant forth-wordlist ( -- wid )
          {system} constant system         ( -- wid )
]root

:r forth                           ( -- : set system to default vocabularies )
   root-voc forth-wordlist #2 set-order ;r
:r only #-1 set-order ;r           ( -- : set minimal search order )

\ Word listing
:s .id                             ( pwd -- : print word )
  nfa count [ $1F ] literal and type space ;s
:r words                           ( -- : list all words in vocabularies )
  cr get-order
  begin ?dup while swap @
    begin ?dup
    while dup nfa c@ [ $80 ] literal and 0= if dup .id then @
    repeat
  1- repeat ;r

: definitions context @ set-current ; ( -- : set definitions vocabulary )
: word                             ( c -- b : parse a character delimited word )
  #1 ?depth parse here aligned dup >r 2dup ! 1+ swap cmove r> ;
:s token bl word ;s                ( -- b : get space delimited word )
:s ?unique                         ( a -- a : warn if word is not unique )
 dup get-current (search) 0= ?exit space
 2drop [ {last} ] literal @ .id ." redefined" cr ;s
:s ?nul                            ( b -- b : check not null )
   c@+ ?exit [ -$10 ] literal throw ;s
:s ?len                            ( b -- b : check length )
  c@+ [ 1F ] literal > [ -$13 ] literal and throw ;s

\ Colon Definitions and Compilation
:to char token ?nul count drop c@ ; ( "name", -- c )
:to [char] postpone char compile (push) , ; immediate
:to ;                              ( -- : end a word definition )
  [ $CAFE ] literal <> [ -$16 ] literal and throw
  [ =unnest ] literal ,            ( compile exit )
  postpone [                       ( back to command mode )
  ?dup if                          ( link word in if non 0 )
    get-current !                  ( this links the word in )
  then ; immediate compile-only

:to :                              ( "name", -- colon-sys )
  align                            ( must be aligned beforehand )
  here dup                         ( push location for ";" )
  [ {last} ] literal !             ( set last defined word )
  last ,                           ( point to previous word in header )
  token ?nul ?len ?unique          ( parse word and do basic checks )
  count + h? ! align               ( skip over packed word and align )
  [ $CAFE ] literal                ( push constant for compiler safety )
  postpone ] ;                     ( turn compile mode on )

:to :noname                        ( "name", -- xt : make definition with no name )
  align here #0 [ $CAFE ] literal postpone ] ;
:to '                              ( "name" -- xt : get xt of word )
  token find ?found cfa ;
:to recurse                        ( -- : recursive call to current definition )
    [ {last} ] literal @ cfa compile, ; immediate compile-only

:s toggle tuck @ xor swap ! ;s     ( u a -- : toggle bits at address )
:s hide token find ?found nfa [ $80 ] literal swap toggle ;s
:s mark here #0 , ;s compile-only

\ Control Structures
:to begin here ; immediate compile-only
:to if [ =jumpz ] literal , mark ; immediate compile-only
:to until 2/ postpone if ! ; immediate compile-only
:to again [ =jump ] literal , compile, ; immediate compile-only
:to then here 2/ swap ! ; immediate compile-only
:to while postpone if ; immediate compile-only
:to repeat swap postpone again postpone then ;
    immediate compile-only
:to else [ =jump ] literal , mark swap postpone then ;
    immediate compile-only
:to for [ =>r ] literal , here ; immediate compile-only
:to aft drop [ =jump ] literal , mark here swap ;
    immediate compile-only
:to next [ =next ] literal , compile, ; immediate compile-only

\ CREATE and DOES>
:s (marker) r> 2* @+ h? ! cell+ @ get-current ! ;s compile-only
: create state @ >r postpone : drop r> state ! compile (var)
   get-current ! ;
:to variable create #0 , ;
:to constant create -cell allot compile (const) , ;
:to value    create -cell allot compile (const) , ;  ( n --, "name" : a mutable constant )
:to user create -cell allot compile (user)
   cell user? +! user? @ , ;
: >body cell+ ;                    ( a -- a : move to a create word's body )
:to to token find ?found cfa >body ! ; ( n --, "name" : store n into the named value )
:s (does) 2r> 2* swap >r ;s compile-only
:s (comp)
  r> [ {last} ] literal @ cfa
  ! ;s compile-only
: does> compile (comp) compile (does) ;
   immediate compile-only
:to marker last align here create -cell allot compile
    (marker) , , ;                 \ --, "name"

\ Immediate Compilation Words
:to >r compile opToR ; immediate compile-only
:to r> compile opFromR ; immediate compile-only
:to rdrop compile rdrop ; immediate compile-only
:to exit compile opExit ; immediate compile-only
:s (s) align [char] " word count nip 1+ allot align ;s
:to ." compile .$ (s) ; immediate compile-only
:to $" compile ($) (s) ; immediate compile-only
:to abort" compile (abort) (s) ; immediate compile-only
:to ( [char] ) parse 2drop ; immediate \ c"xxx" --
:to .( [char] ) parse type ; immediate \ c"xxx" --
:to \ tib @ >in ! ; immediate      \ c"xxx" --
:to postpone token find ?found cfa compile, ; immediate
:s (nfa) last nfa toggle ;s        ( u -- )
:to immediate                      ( -- : mark previous word as immediate )
  [ $40 ] literal (nfa) ;
:to compile-only                   ( -- : mark previous word as compile-only )
  [ $20 ] literal (nfa) ;

\ Decompiler SEE
opt.better-see [unless]
:to see token find ?found cr       ( --, "name" : decompile word )
  begin @+ [ =unnest ] literal <>
  while @+ . cell+ here over < if drop exit then
  repeat @ u. ;
[then]

opt.better-see [if]
:s ndrop for aft drop then next ;s ( x0...xn n -- )
:s validate                        ( pwd cfa -- nfa | 0 )
  over cfa <> if drop #0 exit then nfa ;s
:s cfa?                            ( wid cfa -- nfa | 0 )
  cells >r
  begin
    dup
  while
    dup @ over r@ -rot within
    if dup @ r@ validate ?dup if rdrop nip exit then then
    @
  repeat rdrop ;s
:s name                            ( cfa -- a | 0 : search for CFA )
  >r
  get-order
  begin
    dup
  while
    swap r@ cfa? ?dup if
      >r 1- ndrop r> rdrop exit then
  1- repeat rdrop ;s
:s instruction                     ( u -- )
  [ primitive ] literal @ over u> if ."  VM    " 2* else
    dup name ?dup if space count [ $1F ] literal
    and type drop exit then
  then
  u. ;s
:s decompile                       ( a u -- a )
  dup [ =jumpz ] literal = if
    drop ."  jumpz " cell+ dup @ 2* u. exit
  then
  dup [ =jump ] literal = if
    drop ."  jump  " cell+ dup @ 2* u. exit
  then
  dup [ =next ] literal = if
    drop ."  next  " cell+ dup @ 2* u. exit
  then
  dup [ to' compile half ] literal = if
     drop ."  compile" cell+ dup @ instruction exit
  then
  dup [ to' (up) half ] literal = if drop
     ."  (up) " cell+ dup @ u. exit
  then
  dup [ to' (push) half ] literal = if drop
     ."  (push) " cell+ dup @ u. exit
  then
  dup [ to' (user) half ] literal = if drop
     ."  (user) " cell+ @ u. [ $7FFF ] literal exit
  then
  dup [ to' (const) half ] literal = if drop
     ."  (const) " cell+ @ u. [ $7FFF ] literal exit
  then
  dup [ to' (var) half ] literal = if drop
     ."  (var) " cell+ dup u. ."  -> " @ . [ $7FFF ] literal
     exit
  then
  dup [ to' .$ half ] literal = if drop ."  ." [char] "
    emit space
    cell+ count 2dup type [char] " emit + aligned cell -
  exit then
  dup [ to' ($) half ] literal = if drop ."  $" [char] "
  emit space
    cell+ count 2dup type [char] " emit + aligned cell -
  exit then
  instruction ;s
:s compile-only?                   ( pwd -- f )
   nfa [ $20 ] literal swap @ and 0<> ;s
:s immediate?                      ( pwd -- f )
  nfa [ $40 ] literal swap @ and 0<> ;s
:to see token dup find ?found swap ." : " count type cr
  dup >r cfa
  begin dup @ [ =unnest ] literal <>
  while
    dup dup [ $5 ] literal u.r ."  | "
    @ decompile cr cell+ here over u< if drop rdrop exit then
  repeat drop ."  ;"
  r> dup immediate? if ."  immediate" then
  compile-only? if ."  compile-only" then cr ;
[then]

\ Memory Dump and Checksums
: dump aligned                     ( a u -- : display section of memory )
  begin ?dup
  while swap @+ . cell+ swap cell-
  repeat drop ;
:s cksum aligned dup [ $C0DE ] literal - >r ( a u -- u )
  begin ?dup
  while swap @+ r> + >r cell+ swap cell-
  repeat drop r> ;s
: defined token find nip 0<> ;     ( -- f )

\ Conditional Compilation
:to [then] ; immediate             ( -- : end [if]...[else]...[then] )
:to [else]                         ( -- : skip until '[then]' )
 begin
  begin token c@+ while
   find drop cfa dup
    [ to' [else] ] literal = swap [ to' [then] ] literal = or
    ?exit repeat query drop again ; immediate
:to [if] ?exit postpone [else] ; immediate

\ Terminal Control and Timing
: ms for pause calibration @ for next next ; ( ms -- )
: bell [ $7 ] literal emit ;       ( -- : emit ASCII BEL character )
:s csi                             \ -- : ANSI Terminal Escape Sequence
  [ $1B ] literal emit [ $5B ] literal emit ;s
: page csi ." 2J" csi ." 1;1H" ;   ( -- : clear screen )
: at-xy radix decimal              ( x y -- : set cursor position )
   >r csi #0 u.r ." ;" #0 u.r ." H" r> base ! ;

\ Block Storage System
$400 constant b/buf                ( -- u : size of the block buffer )
system[
$200 constant c/buf                ( -- cu : cells in the block buffer )
variable <block>                   ( -- a : xt for "block" word )
$F400 constant buf0                ( -- ca : location of block buffer )
variable dirty0                    ( -- a : is block buffer dirty? )
variable blk0                      ( -- a : what block is stored in buffer? )
-1 t' blk0 >tbody t!               ( set initial loaded block to be invalid )
]system

:s (block)                         ( ca ca cu -- : transfer to/from storage )
  pause                            \ pause for multitasking
  for
    aft 2dup [@] swap [!] 1+ swap 1+ swap
    then
  next 2drop ;s
t' (block) t' <block> >tbody t!

:s valid? dup #1 [ $80 ] literal within ;s ( k -- k f )
:s transfer <block> @ execute ;s   ( a a u -- )
:s >blk 1- c/buf * ;s              ( k -- ca )
:s clean #0 dirty0 ! ;s            ( -- : opposite of 'update' )
:s invalidate #-1 blk0 ! ;s        ( -- : store invalid block # )
:s bput valid? if >blk buf0 2/ c/buf transfer exit then drop ;s
:s bget
  valid? if >blk buf0 2/ swap c/buf transfer exit then drop ;s
:s loaded? dup blk0 @ = ;s         ( k -- k f )

: update #-1 dirty0 ! ;            ( -- )
: save-buffers dirty0 @ if blk0 @ bput clean then ; ( -- )
: flush save-buffers invalidate ;  ( -- )
: empty-buffers clean invalidate ; ( -- )
: buffer                           ( k -- a )
  #1 ?depth                        \ sanity check stack depth
  valid?                           \ validity check
  0= [ -$23 ] literal and throw    \ throw if invalid
  loaded? if drop buf0 exit then   \ already loaded
  save-buffers                     \ save buffer if dirty
  blk0 !                           \ set current loaded block
  buf0 ;                           \ return block buffer location

: block
  loaded? if drop buf0 exit then   \ already loaded
  dup buffer swap bget ;           ( k -- a )
: blank bl fill ;                  ( a u -- : blank an area of memory )
: list                             ( k -- : display a block )
   page cr                         \ clean the screen
   dup >r block                    \ save block number and call "block"
   [ $F ] literal for              \ for each line in the block
     [ $F ] literal r@ - [ $3 ] literal u.r space
     [ $3F ] literal for count .emit next cr \ print line
   next drop r> scr ! ;

: get-input source >in @ source-id <ok> @ ; ( -- n1...n5 )
: set-input <ok> ! [ {id} ] up ! >in ! tup 2! ; ( n1...n5 -- )
:s ok state @ ?exit ."  ok" cr ;s  ( -- : okay prompt )
:s eval                            \ "word" --
   begin token c@+ while
     interpret #0 ?depth
   repeat drop <ok> @execute ;s
: evaluate                         ( a u -- : evaluate a string )
  get-input 2>r 2>r >r             \ save the current input state
  #0 #-1 [ to' ) ] literal set-input \ set new input
  [ t' eval ] literal catch        \ evaluate the string
  r> 2r> 2r> set-input             \ restore input state
  throw ;                          \ throw on error

:s line                            ( k l -- a u )
  [ $6 ] literal lshift swap block + [ $40 ] literal ;s
:s loadline line evaluate ;s      ( k l -- ??? : execute a line! )
: load                             ( k -- : execute a block )
   blk @ >r dup blk ! #0 [ $F ] literal for
   2dup 2>r loadline 2r> 1+ next 2drop r> blk ! ;

root[
  $FFFF constant eforth            ( --, version )
]root

\ I/O System Configuration
:s xio                             ( xt xt xt -- : exchange I/O )
  [ t' accept ] literal <expect> ! <tap> ! <echo> ! <ok> ! ;s
:s hand                            ( -- : setup terminal I/O )
  [ t' ok ] lit
  [ t' (emit) ] literal            ( Default: echo on )
  [ {options} ] literal @ #1 and
    if drop [ to' drop ] literal then
  [ t' ktap ] literal postpone [ xio ;s
:s pace [ $B ] literal emit ;s     ( -- : emit pacing character )
:s file                            ( -- : setup file I/O )
  [ t' pace ] literal
  [ to' drop ] literal
  [ t' ktap ] literal xio ;s
:s console
  [ t' key? ] literal <key> !
  [ t' (emit) ] literal <emit> !
  hand ;s
:s io! console ;s                  ( -- : setup system I/O )

\ Task Initialization and Management
:s task-init                       ( task-addr -- : initialize USER task )
  [ {up} ] literal @ swap [ {up} ] literal !
  this 2/ [ {next-task} ] up !
  \ Default execution token
  [ to' bye ] literal 2/ [ {ip-save} ] up !
  this [ =stksz        ] literal + 2/ [ {rp-save} ] up !
  this [ =stksz double ] literal + 2/ [ {sp-save} ] up !
  #0 [ {tos-save} ] up !
  decimal
  io!
  [ t' (literal) ] literal <literal> !
  [ to' bye ] literal <error> !
  #0 >in ! #-1 dpl !
  \ Set terminal input buffer location
  this [ =tib ] literal + #0 tup 2!
  [ {up} ] literal ! ;s

:s ini                             ( -- : initialize current task )
   [ {up} ] literal @ task-init ;s
:s (error)                         ( u -- : quit loop error handler )
   dup space . [char] ? emit cr #-1 = if bye then
   ini [ t' (error) ] literal <error> ! ;s

: quit                             ( -- : interpreter loop )
  [ t' (error) ] literal <error> ! \ set error handler
  begin                            \ infinite loop start...
   query [ t' eval ] literal catch \ evaluate a line
   ?dup if <error> @execute then   \ error?
  again ;                          \ do it all again...

:s (boot)                          ( -- : Forth boot sequence )
  forth definitions                ( set up dictionary / set it )
  ini                              ( initialize the current thread correctly )
  [ {options} ] literal @ #2 and if ( checksum on? )
  [ primitive ] literal @ 2* dup here swap - cksum
  [ check ] literal @ <> if ." bad cksum" bye then ( oops... )
  [ {options} ] literal @ #2 xor [ {options} ] literal !
  then
  <quit> @ execute ;s              ( call the interpreter loop )

\ Extended Multitasking Optional
opt.multi [if]
:s task:                           ( "name" -- : create a named task )
  create here b/buf allot 2/ task-init ;s
:s activate                        ( xt task-address -- : start task )
  dup task-init
  ( set execution word )
  dup >r swap 2/ swap [ {ip-save} ] literal + !
  r> this @ >r dup 2/ this ! r> swap ! ;s ( link in task )
[then]

opt.multi [if]
:s wait                            ( addr -- : wait for signal )
  begin pause @+ until #0 swap ! ;s
:s signal this swap ! ;s           ( addr -- : signal to wait )
[then]

opt.multi [if]
:s single                          ( -- : disable other tasks )
   #1 [ {single} ] literal ! ;s
:s multi                           ( -- : enable multitasking )
   #0 [ {single} ] literal ! ;s
[then]

opt.multi [if]
:s send                            ( msg task-addr -- : send message to task )
  this over [ {sender} ] literal +
  begin pause @+ 0= until          ( pause until zero )
  ! [ {message} literal + ! ;s     ( send message )
:s receive                         ( -- msg task-addr : block until message )
  begin pause [ {sender} ] up @ until ( wait until non-zero )
  [ {message} ] up @ [ {sender} ] up @
  #0 [ {sender} ] up ! ;s
[then]

\ Block Editor Optional
opt.editor [if]
: editor [ {editor} ] literal +order ; ( BLOCK editor )
:e q [ {editor} ] literal -order ;e    ( -- : quit editor )
:e ? scr @ . ;e                        ( -- : print block number )
:e l scr @ list ;e                     ( -- : list current block )
:e x q scr @ load editor ;e            ( -- : evaluate current block )
:e ia #2 ?depth [ $6 ] literal lshift + scr @ block + tib
  >in @ + swap source nip >in @ - cmove tib @ >in ! l ;e
:e a #0 swap ia ;e                     ( line --, "line" : insert line at )
:e w get-order [ {editor} ] literal #1 ( -- : list commands )
     set-order words set-order ;e
:e s update flush ;e                   ( -- : save edited block )
:e n  #1 scr +! l ;e                  ( -- : display next block )
:e p #-1 scr +! l ;e                  ( -- : display previous block )
:e r scr ! l ;e                       ( k -- : retrieve given block )
:e z scr @ block b/buf blank l ;e     ( -- : erase current block )
:e d #1 ?depth >r scr @ block r> [ $6 ] literal lshift +
   [ $40 ] literal blank l ;e         ( line -- : delete line )
[then]

\ Extended Control Structures Optional
opt.control [if]
: rpick                            ( n -- u, R: ??? -- ??? : pick from return stack )
  rp@ swap - 1- 2* @ ;
: many #0 >in ! ;                  ( -- : repeat current line )
:s (case) r> swap >r >r ;s compile-only
:s (of) r> r@ swap >r = ;s compile-only
:s (endcase) r> r> drop >r ;s
: case compile (case) [ $1E ] literal ; compile-only immediate
: of compile (of) postpone if ; compile-only immediate
: endof postpone else [ $1F ] literal ; compile-only immediate
: endcase
   begin
    dup [ $1F ] literal =
   while
    drop
    postpone then
   repeat
   [ $1E ] literal <> [ -$16 ] literal and throw
   compile (endcase) ; compile-only immediate
:s r+ 1+ ;s                        ( NB. Should be cell+ on most platforms )
:s (unloop) r> rdrop rdrop rdrop >r ;s compile-only
:s (leave) rdrop rdrop rdrop ;s compile-only
:s (j) [ $4 ] literal rpick ;s compile-only
:s (k) [ $7 ] literal rpick ;s compile-only
:s (do) r> dup >r swap rot >r >r r+ >r ;s compile-only
:s (?do)
   2dup <> if
     r> dup >r swap rot >r >r r+ >r exit
   then 2drop ;s compile-only
:s (loop)
  r> r> 1+ r> 2dup <> if
    >r >r 2* @ >r exit ( NB. 2* and 2/ cause porting problems )
  then >r 1- >r r+ >r ;s compile-only
:s (+loop)
   r> swap r> r> 2dup - >r
   #2 pick r@ + r@ xor 0>=
   [ $3 ] literal pick r> xor 0>= or if
     >r + >r 2* @ >r exit
   then >r >r drop r+ >r ;s compile-only
: unloop compile (unloop) ; immediate compile-only
: i compile r@ ; immediate compile-only ( current loop count )
: j compile (j) ; immediate compile-only ( nested loop count )
: k compile (k) ; immediate compile-only ( nested+1 loop count )
: leave compile (leave) ; immediate compile-only
: do compile (do) #0 , here ; immediate compile-only
: ?do compile (?do) #0 , here ; immediate compile-only
: loop                             ( increment loop count )
  compile (loop) dup 2/ ,
  compile (unloop)
  cell- here cell- 2/ swap ! ; immediate compile-only
: +loop                            ( increment loop by amount )
  compile (+loop) dup 2/ ,
  compile (unloop)
  cell- here cell- 2/ swap ! ; immediate compile-only
:s scopy                           ( b u -- b u : copy string into dictionary )
  align here >r aligned dup allot
  r@ swap dup >r cmove r> r> swap ;s
:s (macro) r> 2* 2@ swap evaluate ;s
: macro                            ( c" xxx" --, : create a late-binding macro )
  create postpone immediate
  -cell allot compile (macro)
  align here #2 cells + ,
  #0 parse dup , scopy 2drop ;
[then]

\ Dynamic Memory Allocation Optional
opt.allocate [if]
system[
  ( pointer to beginning of free space )
variable freelist 0 t, 0 t,
: >length #2 cells + ;             ( freelist -- length-field )
: pool                             ( default memory pool )
  [ $F800 ] literal [ $400 ] literal ;
: arena!                           ( start-addr len -- : initialize memory pool )
  >r dup [ $80 ] literal u< if
    [ -$B ] literal throw          \ arena too small
  then
  dup r@ >length !
  2dup erase
  over dup r> ! #0 swap ! swap cell+ ! ;
: arena?                           ( ptr freelist -- f : is ptr within arena? )
  dup >r @ 0= if rdrop drop #0 exit then
  r> swap >r dup >r @ dup r> >length @ + r> within ;
: >size                            ( ptr freelist -- size : get size of allocated ptr )
  over swap arena? 0= if [ -$3B ] literal throw then
  cell- @ cell- ;
: (allocate)                       ( u -- addr ior : dynamic allocate of 'u' bytes )
  >r
  aligned
  r@ @ 0= if pool r@ arena! then  ( init to default pool )
  dup 0= if rdrop drop #0 [ -$3B ] literal exit then
  cell+ r@ dup
  begin
  while dup @ cell+ @ #2 pick u<
    if
      @ @ dup                      ( get new link )
    else
      dup @ cell+ @ #2 pick - #2 cells max dup #2 cells =
      if
        drop dup @ dup @ rot
        ( prevent freelist address from being overwritten )
        dup r@ = if
          rdrop 2drop 2drop #0 [ -$3B ] literal exit
        then
        !
      else
        2dup swap @ cell+ ! swap @ +
      then
      2dup ! cell+ #0              ( store size, bump pointer )
    then                           ( and set exit flag )
  repeat
  rdrop nip dup 0= [ -$3B ] literal and ;
: (free)                           ( ptr freelist -- ior : free pointer )
  >r
  dup 0= if rdrop #0 exit then
  dup r@ arena? 0= if rdrop drop [ -$3C ] literal exit then
  cell- dup @ swap 2dup cell+ ! r> dup
  begin
    dup [ $3 ] literal pick u< and
  while
    @ dup @
  repeat
  dup @ dup [ $3 ] literal pick ! ?dup
  if
    dup [ $3 ] literal pick [ $5 ] literal pick + =
    if
      dup cell+ @ [ $4 ] literal pick +
      [ $3 ] literal pick cell+ ! @ #2 pick !
    else
      drop
    then
  then
  dup cell+ @ over + #2 pick =
  if
    over cell+ @ over cell+ dup @ rot + swap ! swap @ swap !
  else
    !
  then
  drop #0 ;
: (resize)                         ( a-addr1 u freelist -- a-addr2 ior )
  >r
  dup 0= if drop r> (free) exit then
  over 0= if nip r> (allocate) exit then
  2dup swap r@ >size u<= if drop #0 exit then
  r@ (allocate) if drop [ -$3D ] literal exit then
  over r@ >size
  #1 pick [ $3 ] literal pick >r >r cmove r> r> r>
  (free) if drop [ -$3D ] literal exit then #0 ;
]system
: allocate freelist (allocate) ;   ( u -- ptr ior )
: free freelist (free) ;           ( ptr -- ior )
: resize freelist (resize) ;       ( ptr u -- ptr ior )
[then]

\ Word Glossary and Analysis Optional
opt.glossary [if]
:s .n . ;s                         ( n -- : display an address )
:s .pwd dup ." PWD:" .n ;s         ( pwd -- pwd )
:s .nfa dup ."  NFA:" nfa .n ;s    ( pwd -- pwd : print NFA addr )
:s .cfa dup ."  CFA:" cfa .n ;s    ( pwd -- pwd : print CFA addr )
:s .blank ." --- " ;s              ( -- : print attribute not set )
:s .immediate                      ( nfa -- nfa : is word immediate? )
   dup [ $40 ] literal and if ." IMM " exit then .blank ;s
:s .compile-only                   ( nfa -- nfa : is word compile-only? )
   dup [ $20 ] literal and if ." CMP " exit then .blank ;s
:s .hidden                         ( nfa -- nfa : is word hidden? )
   dup [ $80 ] literal and if ." HID " exit then .blank ;s
:s =vm [ to' pause ] literal @ ;s  ( pause = last defined BLT )
:s =exit [ to' pause ] literal cell+ @ ;s ( exit follows BLT )
:s rvm? dup @ =vm u<= swap cell+ @ =exit = and ;s ( cfa -- f )
:s cvm?                            ( cfa -- f )
   dup @ [ t' compile ] literal 2/ = swap cell+ rvm? and ;s
:s vm? dup rvm? swap cvm? or ;s    ( cfa -- f )
:s .built-in dup cfa vm? if ." BLT " exit then .blank ;s
:s display                         ( pwd -- pwd : display info about word )
  dup .pwd .nfa .cfa space .built-in nfa count
  .immediate .compile-only .hidden
  [ $1F ] literal and type cr ;s
:s (w) begin ?dup while display @ repeat ;s ( voc -- )
:s .voc dup  ." voc: " . cr ;s     ( voc -- voc )
: glossary get-order for aft .voc @ (w) then next ; ( -- )
[then]

opt.rv32i [if]
\ Built-in RV32I loader + runner. Loads a flat RV32I image (the raw bytes objcopy -O binary
\ produces, or any stream of instruction words) into guest RAM and runs it from entry 0 through
\ the single-entry rvstep microcode, servicing ecall write(a7=64)/exit(a7=93) itself. This makes a
\ prebuilt binary runnable directly, with no host-side conversion:
\   objcopy -O binary prog.elf prog.bin
\   { printf '%d rvboot\n' "$(wc -c < prog.bin)"; cat prog.bin; } | ./muxleq
variable rvhalt  variable rvhpc  variable rvwp  variable rvwn  ( runner state )
: rvg@ ( c -- v )  2* rv-ram + @ ;                 ( read guest cell c )
: rvg! ( v c -- )  2* rv-ram + ! ;                 ( write guest cell c )
: rvgbyte ( ba -- b )  dup #1 and swap 2/ rvg@ swap if [ 8 ] literal rshift then [ FF ] literal and ;
: rvget ( idx -- lo )  rv-idx ! rvrd rv-s1lo @ ;   ( read reg[idx] low half )
: rvput ( val idx -- )  rv-idx ! rv-rlo ! #0 rv-rhi ! rvwr ;   ( reg[idx] = val )
\ write(a0=fd ignored, a1=buf, a2=len): emit len guest bytes to stdout, return len in a0
: rvwrite  [ 0B ] literal rvget rvwp !  [ 0C ] literal rvget rvwn !  rvwn @ [ 0A ] literal rvput
   begin rvwn @ while  rvwp @ rvgbyte emit  rvwp @ 1+ rvwp !  rvwn @ 1- rvwn !  repeat ;
: rvsyscall  [ 11 ] literal rvget                        ( a7 )
   dup [ 40 ] literal = if  drop rvwrite  exit then      ( write )
       [ 5D ] literal = if  #-1 rvhalt !  exit then      ( exit: halt silently )
   ." unsupported syscall " [ 11 ] literal rvget u. cr  #-1 rvhalt ! ;
: rvfetch  rv-pclo @ 2/  dup rvg@ rv-il !  1+ rvg@ rv-ih ! ;
: rvadv  rv-ctrl @ 0= if  rv-pclo @ [ 4 ] literal + rv-pclo !  then ; ( branches/jumps set RVPC )
: rvrunning  rvhalt @ #0 =  rv-pclo @ rvhpc @ <>  and ;
: rvrun ( haltpc -- )  rvhpc !  #0 rv-pclo ! #0 rv-pchi ! #0 rvhalt !
   [ 8000 ] literal #2 rvput                             ( sp x2 = 0x8000, top of 32 KiB guest RAM )
   begin rvrunning while  rvfetch rvstep
     rv-state @ if  rv-state @ #1 = if rvsyscall             ( 1 = ecall to service )
       else ." illegal instruction at " rv-pclo @ u. cr  #-1 rvhalt ! then  then ( 2 = trap )
     rvadv  repeat ;
variable rvlp                      ( -- a : guest-cell load pointer, in cells )
: rvorg  #0 rvlp ! ;               ( -- : reset the load pointer to guest cell 0 )
: rvcell, ( c -- )  rvlp @ [ 3FFF ] literal and rvg!  rvlp @ 1+ rvlp ! ; ( append a cell, masked to guest RAM )
: rvboot  [ FFFF ] literal rvrun ; ( -- : run the loaded image from entry 0 until exit/trap )
[then]

\ System Finalization
: cold [ {boot} ] literal 2* @execute ; ( -- : cold start )

t' (boot) half {boot} t!           ( Set starting Forth word )
t' quit {quit} t!                  ( Set initial Forth word )
atlast {forth-wordlist} t!         ( Make wordlist work )
{forth-wordlist} {current} t!      ( Set "current" dictionary )
there h t!                         ( Assign dictionary pointer )
local? {user}  t!                  ( Assign number of locals )
primitive t@ double mkck check t!  ( Set checksum over Forth )
atlast {last} t!                   ( Set last defined word )
save-target                        ( Output target image )
.end                               ( Return to normal Forth )
bye                                ( Exit cross-compiler )
