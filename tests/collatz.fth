\ Collatz (3n+1 / hailstone) step counts for n = 1..20. A small computational
\ eForth application exercising even/odd branching ('1 and'), '2/', '3 *', and a
\ 'begin while repeat' loop -- a different shape from the array-based sieve.
\ Deterministic output, used as a golden test. Values stay within 16 bits for
\ this range (the 1..20 sequences peak at 160, well under 32767).
: collatz ( n -- steps )
  0 swap                              \ ( steps n )
  begin dup 1 > while
    dup 1 and if 3 * 1+ else 2/ then  \ odd: 3n+1   even: n/2
    swap 1+ swap                      \ steps++
  repeat drop ;
: run 21 1 do i collatz . loop cr ;
run
bye
