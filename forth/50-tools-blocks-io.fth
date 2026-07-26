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
