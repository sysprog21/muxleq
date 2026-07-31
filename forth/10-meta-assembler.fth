wordlist constant meta.1        ( Meta-compiler word set )
wordlist constant target.1      ( Target eForth word set )
wordlist constant assembler.1   ( MUXLEQ assembler word set )
wordlist constant target.only.1 ( Target-only word set )

defined eforth [if] system +order [then]
meta.1 +order definitions

\ Target System Constants
   4 constant =cell   ( Target cell size in bytes; 32-bit target )
\ tflash working area. Self-host needs the running image + this buffer + the metacompiler's own
\ dictionary growth to fit in the VM arena (MUX_MIN_CELLS, 65536 cells on the 32-bit host).
4000 constant size    ( Size of image working area )
 100 constant =buf    ( Size of text input buffers in target )
180 constant =stksz ( Size of return and variable stacks )
3FC00 constant =thread ( Initial start of thread area )
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

:m tcell =cell ;m                  ( -- u : bytes in a target cell )
:m there tdp @ ;m                  ( -- a : target dictionary pointer )
:m tc! tflash + c! ;m              ( c a -- : target write char )
:m tc@ tflash + c@ ;m              ( a -- c : target get char )
:m t!                              ( u a -- : store target cell )
   over FF and over tc!
   swap 8 rshift swap 1+
   over FF and over tc!
   swap 8 rshift swap 1+
   over FF and over tc!
   swap 8 rshift swap 1+ tc! ;m
:m t@                              ( a -- u : target fetch )
   dup tc@ swap 1+ dup tc@ 8 lshift rot or
   swap 1+ dup tc@ 10 lshift rot or
   swap 1+ tc@ 18 lshift or ;m
:m taligned =cell 1- + =cell negate and ;m ( u -- u : align target pointer )
:m talign there taligned there - tdp +! ;m ( -- : align target dic. pointer )
:m tc, there tc! 1 tdp +! ;m       ( c -- : write char to target dic. )
:m t, there t! =cell tdp +! ;m     ( u -- : write cell to target dic. )
:m tallot tdp +! ;m                ( u -- : allocate bytes in target dic. )
:m mdrop drop ;m                   ( u -- : always call drop )
:m mswap swap ;m                   ( u u -- u u : always call swap )
:m m+ + ;m                         ( u u -- u : always call host + )
:m mdecimal decimal ;m             ( -- : always call decimal )
:m mhex hex ;m                     ( -- : always call hex )

\ String packing for different Forth systems
:m cellmask FFFF dup 10 lshift or ;m ( -- u : target cell mask 0xFFFFFFFF )
:m signbit 8000 10 lshift ;m ( -- u : target signed-decimal split 0x80000000 )
defined eforth [if]
  :m tpack dup tc, for aft count tc, then next drop ;m
  :m parse-word bl word ?nul count ;m ( -- a u )
  :m limit ;m                       ( u -- u : no-op; eForth cells are already target width )
[else]
  :m tpack talign dup tc, 0 ?do count tc, loop drop ;m
  :m limit cellmask and ;m          ( u -- u : clamp to the target cell, 0xFFFFFFFF )
[then]

:m $literal talign [char] " word count tpack talign ;m

:m msep A emit ;m                  ( -- : emit space as separator )
:m mminus 2D emit ;m               ( -- : emit '-' )
:m mprefix 30 emit 78 emit ;m      ( -- : emit '0x' )
:m hnib dup A u< if 30 m+ else 37 m+ then emit ;m ( u -- : emit one hex digit )
:m hbyte dup 4 rshift hnib F and hnib ;m ( u -- : emit two hex digits )
:m hcell mprefix dup 3 m+ tc@ hbyte dup 2 m+ tc@ hbyte
   dup 1 m+ tc@ hbyte tc@ hbyte ;m ( a -- : emit target cell as 0xhhhhhhhh )

\ Number output for different systems
:m mdump2 taligned                 ( a u -- : dump target memory )
  begin ?dup
  while swap dup hcell msep tcell + swap tcell -
  repeat drop ;m
:m save-target hex 0 there mdump2 ;m ( -- : output target image )
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
   r> set-current talign there , t, does> @ ;m

:m label: get-current >r           ( --, "name", Created-Word: -- a )
     meta.1 set-current create
   r> set-current there , does> @ ;m

:m tdown =cell negate and ;m       ( a -- a : align down )
:m tnfa =cell + ;m                 ( pwd -- nfa : move to name field )
:m tcfa tnfa dup c@ 1F and + =cell + tdown ;m ( pwd -- cfa : to code field )
:m compile-only voc-last @ tnfa t@ 20 or voc-last @ tnfa t! ;m
:m immediate   voc-last @ tnfa t@ 40 or voc-last @ tnfa t! ;m
:m half                            ( a -- a : target byte address -> cell address )
   dup =cell 1- and abort" unaligned" 2/ 2/ ;m
:m cell>byte 2* 2* ;m               ( a -- a : target cell address -> byte address )
:m double 2* ;m                    ( a -- a : meta-comp 2* )
:m muxflag signbit ;m              ( -- u : MUX opcode flag for current target cell )

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
:m tcksum taligned dup C0DE - cellmask and >r ( a u -- u : checksum )
   begin ?dup
   while swap dup t@ r> + cellmask and >r =cell + swap =cell -
   repeat drop r> ;m
:m mkck dup there swap - tcksum ;m ( -- u : checksum of image )
:m postpone                        ( --, "name" )
   target.only.1 +order t' target.only.1 -order half t, ;m

\ Target Word Header Creation
:m thead talign there tlast @ t, dup tlast ! voc-last !
   parse-word talign tpack talign ;m ( --, "name" )
:m header >in @ thead >in ! ;m     ( --, "name" )

:m :ht                             ( "name" -- : forth routine, no header )
  get-current >r target.1 set-current create
  r> set-current CAFE talign there ,
  does> @ half t, ;m

:m :t header :ht ;m                ( "name" -- : forth routine )
:m :to                             ( "name" -- : forth, target only )
  header
  get-current >r
    target.only.1 set-current create
  r> set-current
  CAFE talign there ,
  does> @ half t, ;m

:m :a                              ( "name" -- : assembly routine )
  1234 target.1 +order definitions
  create talign there , assembler.1 +order does> @ half t, ;m

:m (fall-through); 1234 <>
   if abort" unstructured" then assembler.1 -order ;m
:m (a); (fall-through); ;m

defined eforth [if] system -order [then]

\ MUXLEQ Assembly Language Primitives
:m Z tzreg @ t, ;m                 ( -- : Address 0 must contain 0 )
:m A, Z ;m                         ( -- : Synonym for 'Z', temp location )
:m V, tareg @ t, ;m                ( -- : Address 1 also contains 0 )
:m NADDR there half 1+ t, ;m       ( --, jump to next cell )
:m HALT Z Z -1 t, ;m               ( --, Halt the virtual machine )
:m JMP half Z Z t, ;m              ( a --, Jump to location )
:m ADD swap half t, Z NADDR Z half t, NADDR Z Z NADDR ;m
:m SUB swap half t, half t, NADDR ;m ( a a -- : subtract )
:m NOOP Z Z NADDR ;m               ( -- : No operation )
:m ZERO dup half t, half t, NADDR ;m ( a -- : zero a location )
:m PUT half t, -1 t, NADDR ;m      ( a -- : output a byte )
:m GET half -1 t, t, NADDR ;m      ( a -- : input a byte )

\ MUXLEQ Assembler Control Structures
assembler.1 +order definitions
defined eforth [if]
: ( begin bl word count >r c@ [char] ) = r> 1 = and until ; immediate
: \ 100 >in ! ; immediate
[then]
: begin talign there ;
: again JMP ;
: mark there 0 t, ;
: if talign
   half dup t, Z there half 4 + dup t, Z Z 6 + t, Z Z NADDR Z t,
   mark ;
: until half dup t, Z there half 4 + dup t, Z Z 6 + t,
   Z Z NADDR Z t, half t, ;
: else talign Z Z mark swap there half swap t! ;
: +if talign Z half t, mark ;
: -if talign
   half t, Z there half 4 + t, Z Z there half 4 + t, Z Z mark ;
: then begin half swap t! ;
: while if swap ;
: repeat JMP then ;
assembler.1 -order

\ Target System Variables and Memory Layout
meta.1 +order definitions
  0 t, 0 t,                        \ both locations must be zero
