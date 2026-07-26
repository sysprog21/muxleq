
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
