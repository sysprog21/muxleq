.( example: radix for number conversions )

decimal
: binary 2 base !  ;               \ octal is now a muxleq built-in; only binary needs defining

.( try converting numbers among different radices: )
.( decimal 12345 hex .           => ) decimal 12345 hex  .
.( decimal 100 binary .          => ) decimal 100 binary  .
.( binary 101010101010 decimal . => ) binary 101010101010 decimal .
