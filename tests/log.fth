.( example: integer logarithm )

decimal
: log ( u base -- u : compute the integer logarithm of u in 'base' )
        >r
        dup 0= if -$B throw then ( logarithm of zero is an error )
        0 swap
        begin
            swap 1+ swap r@ / dup 0= ( keep dividing until 'u' is 0 )
        until
        drop 1- rdrop ;

.( to test the routines, type: )
.( 1024  2 log . => ) 1024  2  log .
.( 1000 10 log . => ) 1000 10  log .
