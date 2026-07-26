\ 16-bit arithmetic edge cases -- the class of behavior a subleq/fusion bug
\ would silently corrupt (overflow, carry, sign, division). All cells are
\ 16-bit two's complement. Output is deterministic; used as a golden test.

\ signed overflow wraps at the 16-bit boundary
32767 1 + . cr          \ -32768
-32768 1 - . cr         \ 32767

\ floored division and modulo follow the sign of the divisor
-7 2 / . cr             \ -4
-7 2 mod . cr           \ 1
7 -2 / . cr             \ -4
7 -2 mod . cr           \ -1   (pins the floored rule: sign follows divisor)

\ unsigned view of a negative cell
-1 u. cr                \ 65535

\ mixed-precision multiply and divide (double results); . prints top first
5 dup um* . . cr        \ 0 25    (printed high then low)
100 0 10 um/mod . . cr  \ 10 0    (printed quotient then remainder)

\ division by zero throws -10; catch it so output stays clean
: div0 1 0 / ;
' div0 catch . cr       \ -10

bye
