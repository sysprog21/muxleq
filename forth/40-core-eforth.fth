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
:m until talign opJumpZ half t, ;m ( a -- : meta 'until' )
:m again talign opJump  half t, ;m ( a -- : meta 'again' )
:m if opJumpZ there 0 t, ;m        ( -- a : meta 'if' )
:m tmark opJump there 0 t, ;m      ( -- a : meta mark location )
:m then there half swap t! ;m      ( a -- : meta 'then' )
:m else tmark swap then ;m         ( a -- a : meta 'else' )
:m while if ;m                     ( -- a : meta 'while' )
:m repeat swap again then ;m       ( a a -- : meta 'repeat' )
:m aft drop tmark begin swap ;m    ( a -- a a : meta 'aft' )
:m next talign opNext half t, ;m   ( a -- : meta 'next' )
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
:m @ op@ ;m                        ( -- : compile op@ inline, no call frame )
:m ! op! ;m                        ( -- : compile op! inline, no call frame )

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
-4 constant -cell ( -- -cell : negative cell size )
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
:s (up) r> dup [@] [ {up} half ] literal [@] 2* 2* + swap 1+ >r ;s
  compile-only                     ( -- n : user variable implementation )
:s (var) r> 2* 2* ;s compile-only ( R: a --, -- a )
:s (user) r> [@] [ {up} half ] literal [@] 2* 2* + ;s compile-only
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
:to @ op@ ;                       ( a -- u : fetch a cell )
:to ! op! ;                       ( u a -- : write a cell )
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
4 constant cell ( -- u : bytes in cells )
: cell+ cell + ;                   ( a -- a : increment address by cell width )
: cells 2* 2* ;                   ( u -- u : multiply # of cells to get bytes )
: th cells + ;                     ( a n -- a' : address of the n-th cell of array a )
: cell- cell - ;                   ( a -- a : decrement address by cell width )
: execute 2/ 2/ >r ;              ( xt -- : execute an execution token )
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
: +! 2/ 2/ tuck [@] + swap [!] ;  ( u a -- : add value to cell )
: lshift negate shift ;            ( u n -- u : left shift 'u' by 'n' )

\ Character operations
: c@                               ( a -- c : character load )
  @+ swap [ 3 ] literal and dup if
    dup [ 1 ] literal = if drop [ 8 ] literal rshift [ FF ] literal and exit then
    [ 2 ] literal = if [ 10 ] literal rshift [ FF ] literal and exit then
    [ 18 ] literal rshift [ FF ] literal and exit
  then drop [ FF ] literal and ;
: c!                               ( c a -- : character store )
  swap [ FF ] literal and >r
  dup [ 3 ] literal and dup 0= if
    drop dup @ [ FF ] literal invert and r> or swap ! exit
  then
  dup [ 1 ] literal = if
    drop dup @ [ FF00 ] literal invert and r> [ 8 ] literal lshift or swap ! exit
  then
  [ 2 ] literal = if
    dup @ [ FF0000 ] literal invert and r> [ 10 ] literal lshift or swap ! exit
  then
  dup @ [ FF000000 ] literal invert and r> [ 18 ] literal lshift or swap ! ;
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
: aligned [ 3 ] literal + [ -4 ] literal and ; ( u -- u : align up pointer )
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
:s do$ 2r> 2* 2* dup count + aligned 2/ 2/ >r swap >r ;s ( -- a )
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
[ $1F ] literal
  for                              \ one pass per target cell bit
    dup um+ 2>r dup um+ r> + r>
    if >r over um+ r> + then
  next shed ;
: * um* drop ;                     ( n n -- n : multiply two numbers )
: um/mod                           ( ud u -- ur uq : unsigned double div/mod )
  ?dup 0= [ -$A ] literal and throw \ divisor is non zero?
  2dup u<
  if
    negate
[ $1F ] literal
    for                            \ one pass per target cell bit
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

system[ variable stoklen ]system   ( length of the word being searched for )

:s (search)                        ( a wid -- PWD PWD 1 | PWD PWD -1 | 0 a 0 )
  ( Search for word "a" in "wid" )
  swap >r r@ count nip stoklen ! dup
  begin
    dup
  while
    \ $9F = $1F:word-length + $80:hidden. nfa is cell-aligned, so the node length
    \ byte is the low byte of the name cell (inlined @, not a c@ call). The length
    \ is checked inline against the hoisted token length (stoklen); compare runs
    \ only on a length match, so a mismatched node skips the compare call entirely.
    dup nfa dup 1+ swap @ [ $9F ] literal and
    dup stoklen @ - if 2drop #0 else r@ 1+ stoklen @ compare 0= then
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
: compile, 2/ 2/ , ;              ( xt -- : compile execution token )
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
  context - 2/ 2/ dup >r 1- s>d [ -$32 ] literal and throw
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
:to until 2/ 2/ postpone if ! ; immediate compile-only
:to again [ =jump ] literal , compile, ; immediate compile-only
:to then here 2/ 2/ swap ! ; immediate compile-only
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
:s (marker) r> 2* 2* @+ h? ! cell+ @ get-current ! ;s compile-only
: create state @ >r postpone : drop r> state ! compile (var)
   get-current ! ;
:to variable create #0 , ;
:to constant create -cell allot compile (const) , ;
:to value    create -cell allot compile (const) , ;  ( n --, "name" : a mutable constant )
:to user create -cell allot compile (user)
   cell user? +! user? @ , ;
: >body cell+ ;                    ( a -- a : move to a create word's body )
:to to token find ?found cfa >body ! ; ( n --, "name" : store n into the named value )
:s (does) 2r> 2* 2* swap >r ;s compile-only
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
opt.decompiler [unless]
:to see token find ?found cr       ( --, "name" : decompile word )
  begin @+ [ =unnest ] literal <>
  while @+ . cell+ here over < if drop exit then
  repeat @ u. ;
[then]
