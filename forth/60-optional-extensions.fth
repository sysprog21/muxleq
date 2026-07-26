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
