\ Bubble sort demo -- in-place array mutation with compare-and-swap, a different
\ data-manipulation shape from the read-only/marking demos. Sorts a fixed array
\ and prints it before and after. Uses 'for'/'next' for the outer passes and a
\ single 'do'/'loop' inner scan to avoid the fragile nested-'do/loop' 'j i'
\ pattern. Deterministic; a golden test. (The Bubble Sort benchmark from §5.)
create arr  5 , 2 , 8 , 1 , 9 , 3 , 7 , 4 , 6 , 0 ,
10 constant N
variable tmp
: swap-cells ( a b -- ) over @ tmp !  dup @ rot !  tmp @ swap ! ;
: .arr N 0 do i cells arr + @ . loop cr ;
: sort
  N 1- for
    N 1- 0 do
      i cells arr + dup cell+          ( pI pI1 )
      2dup @ swap @ <                  ( pI pI1 : arr[i] > arr[i+1]? )
      if swap-cells else 2drop then
    loop
  next ;
.arr sort .arr
bye
