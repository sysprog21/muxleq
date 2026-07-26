\ Define-and-execute guard for the decode-once interpreter work.
\
\ eForth compiles new words at runtime into threaded code that the inner
\ interpreter reads via iLOAD -- it is never executed as raw VM instructions.
\ That is the assumption an ahead-of-time decode of the initial image relies
\ on. If a future VM ever staled its decode on freshly compiled cells, this
\ test (and make bootstrap) would be the ones to catch it.

: sq dup * ;
: cube dup sq * ;
7 sq . cr
3 cube . cr

\ indirect dispatch through a runtime-computed execution token -- the iJMP
\ path a decode-once VM must get right
: forty-two 42 ;
' forty-two execute . cr

\ runtime control flow inside a runtime-defined word
: countup 0 begin dup 5 < while dup . 1+ repeat drop cr ;
countup

\ create stores cells; indexing reads them back
create tbl 10 , 20 , 30 ,
tbl @ . tbl 2 + @ . tbl 4 + @ . cr

\ does> patches runtime behavior into the word at definition time -- the
\ self-modifying code-field mechanism a decode-once VM must not stale on
: inc-field create , does> @ 1+ ;
41 inc-field answer
answer . cr

bye
