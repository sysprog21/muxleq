\ Emits the hand-written MUXLEQ smoke image for "make check-mux", one decimal
\ cell per line on stdout. Running it prints "AaC" (tests/expected/mux-smoke.out).
\
\ This is a generator rather than a committed .dec because the loader accepts
\ bare integers and nothing else: an image file has no comment syntax, so a
\ checked-in blob cannot say which part of the encoding each cell covers. The
\ cases here are MOVE, SUBLEQ arithmetic, a masked MUX, PUT, and the branch to a
\ negative pc that halts.

decimal   \ every literal below, and .r in cell,, is BASE-sensitive

\ Cell encoding, hand-copied from muxleq-core.h. Building move-c from its two
\ parts is for readability only: unlike MUX_MOVE_C, which the interpreter and
\ its emitters expand from one macro in one translation unit, nothing ties this
\ copy to the header. It can drift exactly as far as a literal 2147483654 could.
$80000000 constant negflag      \ NEG_FLAG32: set in c to select MUX over SUBLEQ
6 constant zero-mask            \ ZERO_MASK_ADDR
-1 constant io                  \ IO_MARKER32: a in a read, b in a write
negflag zero-mask or constant move-c \ c of a MOVE: [b] = [a]; MUX_MOVE_C
io constant halt                \ c that sends pc negative; same cell as io
: mux ( maskaddr -- c ) negflag or ;

\ Data cells. Seven instructions occupy 0..20, so the first datum sits at 21.
\ These addresses are what the code above stores and loads, so datum, below
\ asserts each one against the cell actually emitted.
21 constant zero        \ scratch: [zero] -= [zero] is 0, forcing the halt branch
22 constant out         \ the byte being built and printed
23 constant upper-a     \ 'A'
24 constant case-delta  \ -32: SUBLEQ subtracts it, so it adds 32 ('A' -> 'a')
25 constant mux-src     \ supplies the bits outside the mask
26 constant mux-dst     \ supplies the bits inside it, and receives the result
27 constant nibble      \ the MUX mask

variable pos 0 pos !
: cell, ( n -- ) $ffffffff and 0 .r cr 1 pos +! ;
: insn ( a b c -- ) rot cell, swap cell, cell, ;
: next-insn ( -- addr ) pos @ 3 + ;
: at ( addr -- ) pos @ <> abort" gen-mux-smoke: cell layout drifted" ;
\ Emit one datum, asserting it lands on the address its constant claims. Every
\ datum checks itself, so reordering the block below fails rather than silently
\ rewiring the code above it.
: datum, ( n addr -- ) at cell, ;

\ Code. The c of a PUT is never read, since b matching io short-circuits first.
upper-a out move-c insn              \ [out] = 'A'
out io 0 insn                        \ PUT 'A'
case-delta out next-insn insn        \ [out] -= -32 => 'a'; positive, no branch
out io 0 insn                        \ PUT 'a'
mux-src mux-dst nibble mux insn      \ [mux-dst] = ($40 & ~$0F) | ($03 & $0F)
mux-dst io 0 insn                    \ PUT 'C'
zero zero halt insn                  \ [zero] = 0 => branch negative, halting

\ Data.
0 zero datum,
0 out datum,
char A upper-a datum,
-32 case-delta datum,
$40 mux-src datum,
$03 mux-dst datum,
$0F nibble datum,

bye
