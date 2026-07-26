.( example: bit counting )
\ http://forth.sourceforge.net/algorithm/bit-counting/index.html

decimal
: count-bits ( number -- bits )
        dup $5555 and swap 1 rshift $5555 and +
        dup $3333 and swap 2 rshift $3333 and +
        dup $0F0F and swap 4 rshift $0F0F and +
        $FF mod ;

.( to test the routines, type: )
.( 15  count-bits . => ) 15 count-bits .
.( 16  count-bits . => ) 16 count-bits .
.( 17  count-bits . => ) 17 count-bits .
