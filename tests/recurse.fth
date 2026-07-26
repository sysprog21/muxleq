\ Recursion demo -- exercises 'recurse' and the return stack (a capability the
\ iterative sieve/collatz/base demos don't touch). Recursive factorial and the
\ Ackermann function. Ackermann is kept to shallow arguments: ack(3,3) needs far
\ deeper recursion than the ~100-cell return stack allows, so we stop at
\ ack(3,2)=29 (max ~31 active frames). Deterministic; a golden test.
: fact ( n -- n! ) dup 2 < if drop 1 else dup 1- recurse * then ;
: ack ( m n -- v )
  over 0= if nip 1+ exit then
  dup 0= if drop 1- 1 recurse exit then
  over swap 1- recurse
  swap 1- swap recurse ;
: facts 8 1 do i fact . loop cr ;   \ 1! .. 7!
facts
2 0 ack .  2 1 ack .  2 2 ack .  2 3 ack .  3 0 ack .  3 1 ack .  3 2 ack .  cr
bye
