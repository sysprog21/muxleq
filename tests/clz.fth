.( example: clz )

decimal
: clz ( u -- : count leading zeros )
        ?dup 0= if $10 exit then
        $8000 0 >r begin
        2dup and 0=
        while
                r> 1+ >r 2/
        repeat
        2drop r> ;

.( to test the routines, type: )
.( 16 clz . => ) 16 clz .
