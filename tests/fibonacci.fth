.( example: Fibonacci sequence )

: fibonacci ( n -- fib[n] )
    dup 2 < if exit then
    
    0 1                     \ Initial values: fib[0], fib[1]
    rot 1- for              \ Loop n-1 times
        over +              \ Calculate next fibonacci
        swap
    next
    nip ;                   \ Return result

\ Generate sequence using eForth constructs
: .fibonacci ( n -- )
    dup 1+ 0 swap for       \ Loop from 0 to n
        r@ fibonacci .
    next ;

\ Alternative: display first n fibonacci numbers
: fib-sequence ( n -- )
    for
        r@ fibonacci .
    next ;

.( to test the routines, type: )
.( 10 fib-sequence => ) 10 fib-sequence
