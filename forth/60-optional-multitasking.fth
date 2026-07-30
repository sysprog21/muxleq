\ Extended Multitasking Optional
opt.multi [if]
:s task:                           ( "name" -- : create a named task )
  create here b/buf allot 2/ 2/ task-init ;s
:s activate                        ( xt task-address -- : start task )
  dup task-init
  ( set execution word )
  dup >r swap 2/ 2/ swap [ {ip-save} ] literal + !
  r> this @ >r dup 2/ 2/ this ! r> swap ! ;s ( link in task )
[then]

opt.multi [if]
:s wait                            ( addr -- : wait for signal )
  begin pause @+ until #0 swap ! ;s
:s signal this swap ! ;s           ( addr -- : signal to wait )
[then]

opt.multi [if]
:s single                          ( -- : disable other tasks )
   #1 [ {single} ] literal ! ;s
:s multi                           ( -- : enable multitasking )
   #0 [ {single} ] literal ! ;s
[then]

opt.multi [if]
:s send                            ( msg task-addr -- : send message to task )
  this over [ {sender} ] literal +
  begin pause @+ 0= until          ( pause until zero )
  ! [ {message} literal + ! ;s     ( send message )
:s receive                         ( -- msg task-addr : block until message )
  begin pause [ {sender} ] up @ until ( wait until non-zero )
  [ {message} ] up @ [ {sender} ] up @
  #0 [ {sender} ] up ! ;s
[then]
