\ Arithmetic behavior a subleq/fusion bug would silently corrupt: sign, floored
\ division, mixed precision, and LOGICAL shifts. All cells are 32-bit two's
\ complement. Output is deterministic; used as a golden test. (These operands
\ sat at the 16-bit boundary on the retired 16-bit VM; at 32-bit they no longer
\ wrap, so the values below are the honest wide-cell results.)

\ small-magnitude add/subtract near zero (no wrap at 32-bit cells)
32767 1 + . cr          \ 32768
-32768 1 - . cr         \ -32769

\ floored division and modulo follow the sign of the divisor
-7 2 / . cr             \ -4
-7 2 mod . cr           \ 1
7 -2 / . cr             \ -4
7 -2 mod . cr           \ -1   (pins the floored rule: sign follows divisor)

\ unsigned view of a negative cell
-1 u. cr                \ 4294967295

\ mixed-precision multiply and divide (double results); . prints top first
5 dup um* . . cr        \ 0 25    (printed high then low)
100 0 10 um/mod . . cr  \ 10 0    (printed quotient then remainder)

\ division by zero throws -10; catch it so output stays clean
: div0 1 0 / ;
' div0 catch . cr       \ -10

\ shifts are LOGICAL, not arithmetic: rshift zero-fills the vacated high bits,
\ so 2/ (= 1 rshift) does NOT sign-extend. -2 2/ is 2147483647, not -1 -- a
\ gotcha a threading/fusion rewrite could silently break.
$8000 1 rshift . cr     \ 16384  (0x4000: logical zero-fill, not 0xC000)
$C000 2 rshift . cr     \ 12288  (0x3000)
-2 2/ . cr              \ 2147483647  (0xFFFFFFFE>>1 logical; NOT -1 -- 2/ is not arithmetic)
1 15 lshift . cr        \ 32768  (0x8000: no longer the sign bit at 32-bit)

\ compile-time numeric conversion: [ ... ] evaluates now, literal plants the result
: five [ 2 3 + ] literal ;
five . cr               \ 5

bye
