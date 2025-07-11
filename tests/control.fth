( example: control structure )

: safe-control-test ( -- )
  ." === Control Structure Tests ===" cr
  
  ( Test 1: Basic if/then - conditional execution )
  ( Stack: 1 -> | Expected: "OK" )
  ." 1. if/then: "
  1 if ." OK" then cr
  
  ( Test 2: Basic begin/until - post-test loop )
  ( Counts down 3,2,1 until zero reached )
  ." 2. begin/until: "
  3 begin dup . 1- dup 0= until drop cr
  
  ( Test 3: Counted loop - do/loop )
  ( Loop from 0 to limit-1, print indices )
  ." 3. do/loop: "
  3 0 do i . loop cr
  
  ( Test 4: Conditional loop - ?do with equal bounds )
  ( Should skip when start equals limit )
  ." 4. ?do skip: "
  5 5 ?do ." X" loop ." (empty)" cr
  
  ( Test 5: Conditional loop - ?do normal operation )
  ( Behaves like do when start not equal to limit )
  ." 5. ?do normal: "
  3 0 ?do i . loop cr
  
  ( Test 6: Nested loops with index access )
  ( Outer loop uses i, inner loop uses j )
  ." 6. nested: "
  2 0 do 2 0 do i . j . loop loop cr
  
  ( Test 7: Case statement - multi-way branch )
  ( Selector 2 should match second case )
  ." 7. case: "
  2 case 1 of ." one" endof 2 of ." two" endof endcase cr
  
  ( Test 8: Early exit with leave )
  ( Exit loop when counter reaches 2 )
  ." 8. leave: "
  5 0 do i . i 2 = if leave then loop cr
  
  ( Test 9: Custom increment with +loop )
  ( Add 3 to index each iteration )
  ." 9. +loop: "
  10 0 do i . 3 +loop cr
  
  ." === Tests complete ===" cr ;

\ Expected Output:
\ 1. if/then: OK
\ 2. begin/until: 3 2 1
\ 3. do/loop: 0 1 2
\ 4. ?do skip: (empty)
\ 5. ?do normal: 0 1 2
\ 6. nested: 0 0 0 1 1 0 1 1
\ 7. case: two
\ 8. leave: 0 1 2
\ 9. +loop: 0 3 6 9

safe-control-test
