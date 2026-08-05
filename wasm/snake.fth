\ Snake, for the 24x24 display in the tutorial's last chapter.
\ Adapted from the Easy Forth book's snake by Nick Morgan.
\
\ The board is the "graphics" block: one cell per pixel, and the page paints
\ whatever color number it finds there. Nothing is pushed to the host, so the
\ whole game is just stores into Forth memory.

24 constant width
24 constant height

0 constant bg
1 constant wall
2 constant body
3 constant fruit

\ The snake is two parallel arrays of segment coordinates, head at index 0.
create snake-x  400 cells allot
create snake-y  400 cells allot

variable apple-x
variable apple-y
variable heading
variable length

1 constant go-left
2 constant go-up
3 constant go-right
4 constant go-down

\ What the page sends for the arrow keys.
$80 constant k-left
$81 constant k-up
$82 constant k-right
$83 constant k-down

: xy ( x y -- addr )  width * + cells graphics + ;
: draw ( color x y -- )  xy ! ;
: color@ ( x y -- color )  xy @ ;

: seg-x ( i -- addr )  cells snake-x + ;
: seg-y ( i -- addr )  cells snake-y + ;

: clear ( -- )
  height 0 do  width 0 do  bg i j draw  loop  loop ;

: walls ( -- )
  width 0 do
    wall i 0 draw   wall i height 1- draw
  loop
  height 0 do
    wall 0 i draw   wall width 1- i draw
  loop ;

: init-snake ( -- )
  4 length !
  length @ 1+ 0 do
    width 2/ i -  i seg-x !
    height 2/     i seg-y !
  loop
  go-right heading ! ;

\ "for ... next" counts down, so segments are copied from the tail forwards and
\ nothing is overwritten before it has been read.
: shift-body ( -- )
  length @ for
    r@ seg-x @  r@ 1+ seg-x !
    r@ seg-y @  r@ 1+ seg-y !
  next ;

: move-head ( -- )
  heading @ case
    go-left  of -1 snake-x +! endof
    go-right of  1 snake-x +! endof
    go-up    of -1 snake-y +! endof
    go-down  of  1 snake-y +! endof
  endcase ;

\ A snake cannot reverse into itself, so a turn only takes effect when it is
\ across the current heading.
: sideways? ( -- flag )  heading @ dup go-left = swap go-right = or ;
: upright?  ( -- flag )  heading @ dup go-up   = swap go-down  = or ;

: turn ( key -- ) case
    k-left  of upright?  if go-left  heading ! then endof
    k-up    of sideways? if go-up    heading ! then endof
    k-right of upright?  if go-right heading ! then endof
    k-down  of sideways? if go-down  heading ! then endof
  endcase ;

\ Retry until the chosen cell is empty. An apple dropped onto a body segment
\ turns a crash into a meal: show-apple paints fruit over the segment, then eat?
\ clears that cell to bg before crashed? reads it, so driving into your own body
\ there scores instead of ending the game. The caller must have drawn the snake
\ first, which is what setup now does.
: place-apple ( -- )
  begin
    width 4 - random 2 +  apple-x !
    height 4 - random 2 + apple-y !
    apple-x @ apple-y @ color@ bg =
  until ;

: show-apple ( -- )  fruit apple-x @ apple-y @ draw ;

: eat? ( -- )
  snake-x @ apple-x @ =
  snake-y @ apple-y @ = and if
    bg apple-x @ apple-y @ draw
    place-apple
    1 length +!
  then ;

: show-snake ( -- )
  length @ 0 do  body i seg-x @ i seg-y @ draw  loop
  bg length @ seg-x @  length @ seg-y @ draw ;

\ The head has already moved when this runs, so whatever is under it is what it
\ just ran into. The apple is cleared first, so only a wall or the body is left.
: crashed? ( -- flag )  snake-x @ snake-y @ color@ bg <> ;

\ show-snake before place-apple: the retry loop tests the screen, so the snake
\ has to be on it or the very first apple can still land on a segment.
: setup ( -- )  clear walls init-snake show-snake place-apple show-apple ;

: play ( -- )
  setup
  begin
    show-snake show-apple
    30 ms
    ekey ?dup if turn then
    shift-body move-head
    eat?
    crashed?
  until
  ." game over" cr ;
