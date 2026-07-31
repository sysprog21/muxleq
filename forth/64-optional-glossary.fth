
\ Word Glossary and Analysis Optional
opt.glossary [if]
:s .n . ;s                         ( n -- : display an address )
:s .pwd dup ." PWD:" .n ;s         ( pwd -- pwd )
:s .nfa dup ."  NFA:" nfa .n ;s    ( pwd -- pwd : print NFA addr )
:s .cfa dup ."  CFA:" cfa .n ;s    ( pwd -- pwd : print CFA addr )
:s .blank ." --- " ;s              ( -- : print attribute not set )
:s .immediate                      ( nfa -- nfa : is word immediate? )
   dup [ $40 ] literal and if ." IMM " exit then .blank ;s
:s .compile-only                   ( nfa -- nfa : is word compile-only? )
   dup [ $20 ] literal and if ." CMP " exit then .blank ;s
:s .hidden                         ( nfa -- nfa : is word hidden? )
   dup [ $80 ] literal and if ." HID " exit then .blank ;s
:s =vm [ to' pause ] literal @ ;s  ( pause = last defined BLT )
:s =exit [ to' pause ] literal cell+ @ ;s ( exit follows BLT )
:s rvm? dup @ =vm u<= swap cell+ @ =exit = and ;s ( cfa -- f )
:s cvm?                            ( cfa -- f )
   dup @ [ t' compile ] literal 2/ 2/ = swap cell+ rvm? and ;s
:s vm? dup rvm? swap cvm? or ;s    ( cfa -- f )
:s .built-in dup cfa vm? if ." BLT " exit then .blank ;s
:s display                         ( pwd -- pwd : display info about word )
  dup .pwd .nfa .cfa space .built-in nfa count
  .immediate .compile-only .hidden
  [ $1F ] literal and type cr ;s
:s (w) begin ?dup while display @ repeat ;s ( voc -- )
:s .voc dup  ." voc: " . cr ;s     ( voc -- voc )
: glossary get-order for aft .voc @ (w) then next ; ( -- )
[then]
