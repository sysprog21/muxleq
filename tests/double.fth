\ Double-precision (32-bit) arithmetic demo -- exercises um* (16x16->32),
\ d+ (32-bit add), and pictured numeric output (<# #s #>), none of which the
\ 16-bit demos reach. This eForth computes 32-bit values but has no d.; ud. is
\ defined here from the pictured-output words. Deterministic; a golden test.
: ud. ( ud -- ) <# #s #> type space ;
: demo
  decimal
  1000 1000 um* ud.                       \ 1000000
  60000 60000 um* ud.                      \ 3600000000  (> 32-bit signed)
  65535 65535 um* ud.                      \ 4294836225  (max u16 squared)
  cr
  60000 60000 um* 1000 1000 um* d+ ud.     \ 3600000000 + 1000000 = 3601000000
  cr ;
demo
bye
