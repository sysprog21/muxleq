\ VM cooperative-multitasker guard (opt.multi). Two tasks each advance a shared
\ counter only when the round-robin scheduler yields to them via 'pause'; the
\ main task polls until both finish, then reports. If task switching broke, the
\ counters would never reach their targets and the poll would hang -- the golden
\ gate's timeout turns that into a failure. Exercises the task:/activate/multi/
\ single/pause path that no other golden touches.
system +order
variable ta
variable tb
: wa 3 for pause 1 ta +! next begin pause again ;
: wb 3 for pause 1 tb +! next begin pause again ;
task: t1
task: t2
' wa t1 activate
' wb t2 activate
: run multi begin pause ta @ 3 > tb @ 3 > and until single ;
run
ta @ . tb @ . cr
bye
