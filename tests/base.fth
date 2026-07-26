\ Number-base converter: prints each value in decimal, hex, octal, and binary.
\ A small eForth application exercising 'base' and radix number output (a
\ capability the arithmetic-loop demos don't touch). '.base' prints an unsigned
\ number in a given radix, saving and restoring 'base' around it. Deterministic.
: .base ( n radix -- )  base @ >r  base !  u.  r> base ! ;
: convert ( n -- )
  dup 10 .base   dup 16 .base   dup 8 .base   2 .base   cr ;
255 convert
42 convert
1000 convert
32767 convert
bye
