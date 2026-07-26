\ Dynamic memory demo -- exercises the heap allocator (allocate/free, the
\ opt.allocate feature), which no other test touches. Allocates a buffer, fills
\ and sums it, frees it, then allocates again to show the heap still serves
\ requests. Prints only values (sums), never addresses, so it is deterministic.
\ ('fill'/'sum' are avoided as names -- 'fill' is a built-in word here.)
variable acc
: seq!   ( a n -- )   0 do dup i cells + i swap ! loop drop ;
: seqsum ( a n -- s ) 0 acc !  0 do dup i cells + @ acc +! loop drop acc @ ;
: demo
  10 cells allocate if drop ." alloc1 failed" cr exit then
  dup 10 seq!  dup 10 seqsum .  free if ." free1 failed" cr exit then
  5 cells allocate if drop ." alloc2 failed" cr exit then
  dup 5 seq!   dup 5 seqsum .   free if ." free2 failed" cr exit then
  space ." heap ok" cr ;
demo
bye
