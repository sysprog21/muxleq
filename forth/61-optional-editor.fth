
\ Block Editor Optional
opt.editor [if]
: editor [ {editor} ] literal +order ; ( BLOCK editor )
:e q [ {editor} ] literal -order ;e    ( -- : quit editor )
:e ? scr @ . ;e                        ( -- : print block number )
:e l scr @ list ;e                     ( -- : list current block )
:e x q scr @ load editor ;e            ( -- : evaluate current block )
:e ia #2 ?depth [ $6 ] literal lshift + scr @ block + tib
  >in @ + swap source nip >in @ - cmove tib @ >in ! l ;e
:e a #0 swap ia ;e                     ( line --, "line" : insert line at )
:e w get-order [ {editor} ] literal #1 ( -- : list commands )
     set-order words set-order ;e
:e s update flush ;e                   ( -- : save edited block )
:e n  #1 scr +! l ;e                  ( -- : display next block )
:e p #-1 scr +! l ;e                  ( -- : display previous block )
:e r scr ! l ;e                       ( k -- : retrieve given block )
:e z scr @ block b/buf blank l ;e     ( -- : erase current block )
:e d #1 ?depth >r scr @ block r> [ $6 ] literal lshift +
   [ $40 ] literal blank l ;e         ( line -- : delete line )
[then]
