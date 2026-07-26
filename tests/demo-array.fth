\ Conformance demo: array access via create/allot + th.
\ Conformance driver for 'th' (added to muxleq.fth). demo adapted: dropped the two 'see arr'
\ lines -- 'see' prints muxleq's decompiler output (addresses), which is implementation-specific,
\ not conformance-relevant. The array reads/writes (the demo's point) are verbatim.
.( lesson 17 - array access )

.( create arr 5 cells allot ) create arr 5 cells allot cr
: st th ;
: nd th ;
: rd th ;

.( 999 arr ! )      999 arr ! cr            \ same as regular variable
.( 111 arr 1 st ! ) 111 arr 1 st ! cr
.( 222 arr 2 nd ! ) 222 arr 2 nd ! cr
.( 333 arr 3 rd ! ) 333 arr 3 rd ! cr
.( 444 arr 4 th ! ) 444 arr 4 th ! cr cr

.( arr @      => ) arr @ . cr
.( arr 1 st @ => ) arr 1 st @ . cr
.( arr 2 nd @ => ) arr 2 nd @ . cr
.( arr 3 rd @ => ) arr 3 rd @ . cr
.( arr 4 th @ => ) arr 4 th @ . cr cr
bye
