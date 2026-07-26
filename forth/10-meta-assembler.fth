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
