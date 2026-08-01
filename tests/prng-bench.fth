.( example: 16-bit PRNG micro-benchmark )
\ A 16-bit xorshift PRNG (Marsaglia's (7,9,8) triple) folded into a running XOR
\ checksum. Delivered as a stdin test file, so the image and stage0.dec are
\ untouched and 'make bootstrap' stays byte-exact by construction -- zero image
\ cost. Its purpose is a deterministic, arithmetic-heavy workload for the '-s'
\ dispatch-count profiler (39,231,191 dispatched ops at n=10000 below: ~43% MUX,
\ ~57% SUBLEQ); the printed checksum is the golden that guards the generator.
decimal
: xs16 ( x -- x' )               \ one 16-bit xorshift step (Marsaglia 7,9,8)
    dup 7 lshift xor  $FFFF and  \ mask each lshift: the wide cell no longer
    dup 9 rshift xor             \ wraps at 16 bits the way this PRNG needs
    dup 8 lshift xor  $FFFF and ;
: bench ( seed n -- checksum )   \ fold n+1 generator outputs into an XOR checksum
    >r 0 r> for                  \ ( seed 0 ) with n on the return stack
        swap xs16                \ advance the generator
        swap over xor            \ fold the new output into the checksum
    next nip ;
.( 44257 10000 bench u. => ) 44257 10000 bench u.
cr
