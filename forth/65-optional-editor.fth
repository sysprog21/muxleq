
\ Modal (vi-style) Block Editor Optional
\ A block is a fixed 16-row x 64-column grid (no newline); the cursor is clamped
\ to that grid and the block buffer IS the file. Normal mode: hjkl or the arrow
\ keys move, i insert (overwrite+advance), x delete (shift row left). A ':'
\ command line (echoed as you type) runs: :w save, :n/:p next/previous block,
\ :N go to block N, :z blank block, :x save+load (compile) the block on exit,
\ :q quit; ZZ also quits. Reuses page/csi/at-xy/block/update/flush/load/.emit;
\ needs raw single-key input (VM raw mode, toggled by raw-on/raw-off). This is
\ regression-tested by golden-pty (a pty screen capture), not a pipe golden.
opt.editor [if]
variable vx                            ( -- a : cursor column 0..63 )
variable vy                            ( -- a : cursor row 0..15 )
variable vload                         ( -- a : nonzero => load block on exit )
\ Terminal control rides out-of-band on emit: the VM's put() intercepts these
\ exact values instead of printing them. They MUST match EDIT_RAW_ON / RAW_OFF /
\ PEEK in muxleq.c (golden-pty exercises all three, so drift fails the gate).
:s raw-on  [ $FF01 ] literal emit ;s   ( -- : entry; VM switches the tty to raw )
:s raw-off [ $FF00 ] literal emit ;s   ( -- : exit; VM restores the cooked tty )
:s peek    [ $FF02 ] literal emit key ;s ( -- c : timed read after ESC; $100 if none )
:s vclampx vx @ #0 max [ $3F ] literal min vx ! ;s
:s vclampy vy @ #0 max [ $F ] literal min vy ! ;s
:s vat 1+ swap 1+ swap at-xy ;s        ( x y -- : at-xy, but 1-based like ANSI CUP )
:s vpos vx @ vy @ vat ;s               ( -- : move the terminal cursor, no repaint )
:s vrowa scr @ block vy @ [ $6 ] literal lshift + ;s ( -- a : current row start )
:s vcell vrowa vx @ + ;s               ( -- a : cursor byte )
:s vstatus                             ( -- : block number on the line below the grid )
  #0 [ $10 ] literal vat ." -- blk " radix decimal scr @ u. base ! ." --" ;s
:s vdraw                               ( -- : repaint the 16x64 grid plus status )
  page
  [ $F ] literal for
    [ $F ] literal r@ -                ( row 0..15 )
    dup #0 swap vat                    ( leave row; cursor to column 0 )
    scr @ block swap [ $6 ] literal lshift +
    [ $3F ] literal for count .emit next drop
  next
  vstatus
  vpos ;s
:s vrow                                ( -- : repaint the current row from the cursor right )
  vpos
  vcell [ $3F ] literal vx @ - for count .emit next drop
  vpos ;s
:s vblank scr @ block b/buf blank update ;s ( -- : erase current block )
:s vdel                                ( -- : delete char, shift row left, blank col 63 )
  vcell dup 1+ swap [ $3F ] literal vx @ - cmove
  vrowa [ $3F ] literal + bl swap c!
  update ;s
:s vinsert                             ( -- : overwrite cells in place until ESC )
  begin key dup [ $1B ] literal = if drop exit then
    dup vcell c! update .emit          ( write the char and show it at the cursor )
    #1 vx +! vx @ [ $3F ] literal > if vclampx vpos then ( reposition only at the margin )
  again ;s
:s vdigit? [char] 0 [char] 9 1+ within ;s ( c -- f )
:s vgo #1 max [ $7F ] literal min scr ! ;s ( n -- : select block, clamped to 1..127 )
:s vckey key dup .emit ;s              ( -- c : read a command key and echo it )
:s vcmd                                ( -- : open the ':' command line on the status row )
  #0 [ $10 ] literal vat [char] : emit csi ." K" ;s ( ':' then clear the rest of the line )
:s vcolon                              ( -- f : run a ':' command, nonzero quits )
  vckey
  dup vdigit? if                       ( :N -- go to block N )
    #0 swap
    begin [char] 0 - swap [ $A ] literal * + [ $7F ] literal min vckey dup vdigit? 0= until
    drop vgo vdraw #0 exit
  then
  dup [char] w = if drop update flush #0 exit then
  dup [char] n = if drop scr @ 1+ vgo vdraw #0 exit then
  dup [char] p = if drop scr @ 1- vgo vdraw #0 exit then
  dup [char] z = if drop vblank vdraw #0 exit then
  dup [char] x = if drop update flush #-1 vload ! #-1 exit then
  dup [char] q = if drop #-1 exit then
  drop #0 ;s
:s varrow                              ( -- : ESC seen; a CSI arrow only if one follows )
  peek [char] [ = if                   ( timed peek; lone ESC falls through as no-op )
    key
    dup [char] A = if drop #-1 vy +! vclampy vpos exit then ( up )
    dup [char] B = if drop  #1 vy +! vclampy vpos exit then ( down )
    dup [char] C = if drop  #1 vx +! vclampx vpos exit then ( right )
    dup [char] D = if drop #-1 vx +! vclampx vpos exit then ( left )
    drop
  then ;s
:s vkey                                ( c -- f : handle one normal key, nonzero quits )
  dup [char] h = if drop #-1 vx +! vclampx vpos #0 exit then
  dup [char] l = if drop  #1 vx +! vclampx vpos #0 exit then
  dup [char] k = if drop #-1 vy +! vclampy vpos #0 exit then
  dup [char] j = if drop  #1 vy +! vclampy vpos #0 exit then
  dup [char] i = if drop vinsert vpos #0 exit then
  dup [char] x = if drop vdel vrow #0 exit then
  dup [char] : = if drop vcmd vcolon dup if exit then drop vpos #0 exit then
  dup [char] Z = if drop key [char] Z = if #-1 exit then #0 exit then
  dup [char] q = if drop #-1 exit then
  dup [ $1B ] literal = if drop varrow #0 exit then ( arrow keys; lone ESC is a no-op )
  drop #0 ;s
:s vloop                               ( -- : the modal key loop )
  #0 vx ! #0 vy ! #0 vload ! scr @ vgo vdraw
  begin key vkey until ;s
: editor                               ( -- : enter the editor; :x loads on exit )
  raw-on [ t' vloop ] literal catch raw-off throw ( restore cooked, then re-raise )
  page
  vload @ if scr @ load then ;
[then]
