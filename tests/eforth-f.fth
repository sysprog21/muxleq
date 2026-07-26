\ Conformance demo: the big F (ascii art).
\ Uses only .(  variable  :  cr  ." ; no compatibility alias needed.
.( example 2. the big f )

variable t2
: bar   cr ." *****" ;
: post  cr ." *    " ;
: f     bar post bar post post post ;

cr .( type 'f' and a return on your keyboard to execute =>)
f
bye
