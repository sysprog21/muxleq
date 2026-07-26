( exaample: Game of Life )

\ Conway's Game of Life - 5x5 Real Rules

' ( <ok> !

\ Current generation (5x5 = 25 cells)
variable c00 variable c01 variable c02 variable c03 variable c04
variable c10 variable c11 variable c12 variable c13 variable c14
variable c20 variable c21 variable c22 variable c23 variable c24
variable c30 variable c31 variable c32 variable c33 variable c34
variable c40 variable c41 variable c42 variable c43 variable c44

\ Next generation
variable n00 variable n01 variable n02 variable n03 variable n04
variable n10 variable n11 variable n12 variable n13 variable n14
variable n20 variable n21 variable n22 variable n23 variable n24
variable n30 variable n31 variable n32 variable n33 variable n34
variable n40 variable n41 variable n42 variable n43 variable n44

variable gen-num

\ Get cell value (simple version)
: get-cell ( row col -- value )
  swap dup 0 = if
    drop dup 0 = if drop c00 @ exit then
    dup 1 = if drop c01 @ exit then
    dup 2 = if drop c02 @ exit then
    dup 3 = if drop c03 @ exit then
    dup 4 = if drop c04 @ exit then
    drop 0 exit
  then
  dup 1 = if
    drop dup 0 = if drop c10 @ exit then
    dup 1 = if drop c11 @ exit then
    dup 2 = if drop c12 @ exit then
    dup 3 = if drop c13 @ exit then
    dup 4 = if drop c14 @ exit then
    drop 0 exit
  then
  dup 2 = if
    drop dup 0 = if drop c20 @ exit then
    dup 1 = if drop c21 @ exit then
    dup 2 = if drop c22 @ exit then
    dup 3 = if drop c23 @ exit then
    dup 4 = if drop c24 @ exit then
    drop 0 exit
  then
  dup 3 = if
    drop dup 0 = if drop c30 @ exit then
    dup 1 = if drop c31 @ exit then
    dup 2 = if drop c32 @ exit then
    dup 3 = if drop c33 @ exit then
    dup 4 = if drop c34 @ exit then
    drop 0 exit
  then
  dup 4 = if
    drop dup 0 = if drop c40 @ exit then
    dup 1 = if drop c41 @ exit then
    dup 2 = if drop c42 @ exit then
    dup 3 = if drop c43 @ exit then
    dup 4 = if drop c44 @ exit then
    drop 0 exit
  then
  2drop 0
;

\ Set cell value (simple version)
: set-cell ( value row col -- )
  swap dup 0 = if
    drop dup 0 = if drop c00 ! exit then
    dup 1 = if drop c01 ! exit then
    dup 2 = if drop c02 ! exit then
    dup 3 = if drop c03 ! exit then
    dup 4 = if drop c04 ! exit then
    2drop exit
  then
  dup 1 = if
    drop dup 0 = if drop c10 ! exit then
    dup 1 = if drop c11 ! exit then
    dup 2 = if drop c12 ! exit then
    dup 3 = if drop c13 ! exit then
    dup 4 = if drop c14 ! exit then
    2drop exit
  then
  dup 2 = if
    drop dup 0 = if drop c20 ! exit then
    dup 1 = if drop c21 ! exit then
    dup 2 = if drop c22 ! exit then
    dup 3 = if drop c23 ! exit then
    dup 4 = if drop c24 ! exit then
    2drop exit
  then
  dup 3 = if
    drop dup 0 = if drop c30 ! exit then
    dup 1 = if drop c31 ! exit then
    dup 2 = if drop c32 ! exit then
    dup 3 = if drop c33 ! exit then
    dup 4 = if drop c34 ! exit then
    2drop exit
  then
  dup 4 = if
    drop dup 0 = if drop c40 ! exit then
    dup 1 = if drop c41 ! exit then
    dup 2 = if drop c42 ! exit then
    dup 3 = if drop c43 ! exit then
    dup 4 = if drop c44 ! exit then
    2drop exit
  then
  2drop drop
;

\ Count neighbors (center cell at row 2, col 2 only - simplified)
: count-neighbors-22 ( -- count )
  0
  1 1 get-cell +  \ Top-left
  1 2 get-cell +  \ Top
  1 3 get-cell +  \ Top-right
  2 1 get-cell +  \ Left
  2 3 get-cell +  \ Right
  3 1 get-cell +  \ Bottom-left
  3 2 get-cell +  \ Bottom
  3 3 get-cell +  \ Bottom-right
;

\ Apply Conway rules to center cell only
: evolve-center ( -- )
  count-neighbors-22  \ Get neighbor count
  dup 3 = if          \ 3 neighbors = birth/survival
    drop 1 2 2 set-cell
  else dup 2 = if     \ 2 neighbors = survival only
    drop 2 2 get-cell 2 2 set-cell  \ Keep current state
  else
    drop 0 2 2 set-cell  \ Death
  then then
;

\ Clear all cells
: clear-grid ( -- )
  0 0 0 set-cell  0 0 1 set-cell  0 0 2 set-cell  0 0 3 set-cell  0 0 4 set-cell
  0 1 0 set-cell  0 1 1 set-cell  0 1 2 set-cell  0 1 3 set-cell  0 1 4 set-cell
  0 2 0 set-cell  0 2 1 set-cell  0 2 2 set-cell  0 2 3 set-cell  0 2 4 set-cell
  0 3 0 set-cell  0 3 1 set-cell  0 3 2 set-cell  0 3 3 set-cell  0 3 4 set-cell
  0 4 0 set-cell  0 4 1 set-cell  0 4 2 set-cell  0 4 3 set-cell  0 4 4 set-cell
;

\ Display grid
: show-5x5 ( -- )
  ." Generation " gen-num @ . ." :" cr
  0 0 get-cell if [char] O else [char] . then emit
  0 1 get-cell if [char] O else [char] . then emit
  0 2 get-cell if [char] O else [char] . then emit
  0 3 get-cell if [char] O else [char] . then emit
  0 4 get-cell if [char] O else [char] . then emit cr
  1 0 get-cell if [char] O else [char] . then emit
  1 1 get-cell if [char] O else [char] . then emit
  1 2 get-cell if [char] O else [char] . then emit
  1 3 get-cell if [char] O else [char] . then emit
  1 4 get-cell if [char] O else [char] . then emit cr
  2 0 get-cell if [char] O else [char] . then emit
  2 1 get-cell if [char] O else [char] . then emit
  2 2 get-cell if [char] O else [char] . then emit
  2 3 get-cell if [char] O else [char] . then emit
  2 4 get-cell if [char] O else [char] . then emit cr
  3 0 get-cell if [char] O else [char] . then emit
  3 1 get-cell if [char] O else [char] . then emit
  3 2 get-cell if [char] O else [char] . then emit
  3 3 get-cell if [char] O else [char] . then emit
  3 4 get-cell if [char] O else [char] . then emit cr
  4 0 get-cell if [char] O else [char] . then emit
  4 1 get-cell if [char] O else [char] . then emit
  4 2 get-cell if [char] O else [char] . then emit
  4 3 get-cell if [char] O else [char] . then emit
  4 4 get-cell if [char] O else [char] . then emit cr cr
;

\ Setup test pattern
: setup-test ( -- )
  clear-grid
  0 gen-num !
  1 1 2 set-cell  \ . O .
  1 2 1 set-cell  \ O O O  (will test center cell)
  1 2 2 set-cell  \ . O .
  1 2 3 set-cell
  1 3 2 set-cell
;

\ Run Conway demo focusing on center cell
: conway-demo ( -- )
  ." Conway's Game of Life - 5x5 Grid" cr
  ." Testing center cell evolution with real rules" cr cr

  setup-test
  show-5x5

  gen-num @ 1+ gen-num !
  evolve-center
  show-5x5

  gen-num @ 1+ gen-num !
  evolve-center
  show-5x5

  gen-num @ 1+ gen-num !
  evolve-center
  show-5x5

  ." Demo complete!" cr
;

conway-demo
