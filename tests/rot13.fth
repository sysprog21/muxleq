\ ROT13 cipher demo -- exercises character handling ('emit', '[char]', character
\ arithmetic, 'within') which the numeric demos don't touch. eForth here has no
\ string literals ('s"'), so we transform the alphabet directly rather than a
\ quoted string. Prints A-Z, then its ROT13, then ROT13 of a-z. Deterministic.
: rot13c ( c -- c' )
  dup [char] A [char] Z 1+ within if [char] A - 13 + 26 mod [char] A + exit then
  dup [char] a [char] z 1+ within if [char] a - 13 + 26 mod [char] a + exit then ;
: emit-alpha ( base -- ) 26 0 do dup i + emit loop drop ;
: rot-alpha  ( base -- ) 26 0 do dup i + rot13c emit loop drop ;
: show  [char] A emit-alpha cr  [char] A rot-alpha cr  [char] a rot-alpha cr ;
show
bye
