\ Ported from externals/eforth/tests/demo/18_does.fs -- create..does> defining words.
\ demo adapted: dropped the 'see x' / 'see xyz' lines (see = muxleq's decompiler, address
\ output, implementation-specific). The create/does> behavior and the values are verbatim.
.( lesson 18 - create..does> )

: const
  create
    , ." created "
  does>
    @ ." fetched " ;

.( 123 const x ) cr 123 const x
.( x => ) x . cr cr

.( create...does> for a data structure ) cr
: vec3
  create
    rot , swap , ,
  does>
    dup >r @
    r@ 1 th @
    r> 2 th @ ;
: 3. ( x y z -- ) rot . swap . . ;
.( 111 222 333 vec3 xyz ) cr 111 222 333 vec3 xyz
.( xyz => ) xyz 3. cr cr
bye
