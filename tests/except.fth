\ Exception handling demo -- exercises catch/throw and, crucially, the stack
\ UNWINDING catch performs (no other test checks it; arith.fth only catches a
\ div-by-zero code). Run at the REPL because ''' fetches an xt from the input
\ stream and this dialect has no compile-time '[']' for use inside a word.
\ 'junk' pushes 10 20 30 then throws 88; if catch unwinds the stack to its
\ pre-catch depth, only the 5 below the catch (plus code 88) remains, so the
\ line prints '88 5', not '88 30'. Deterministic.
: thrower 99 throw ;
: nothrow 7 ;
: junk 10 20 30 88 throw ;
' thrower catch .
' nothrow catch . .
5 ' junk catch . .
cr
bye
