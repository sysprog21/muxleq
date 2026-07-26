\ Cooperative message-passing golden -- exercises the multitasker's send/receive
\ (system vocab), which tasker.fth does not cover. A producer task sends three
\ values to a consumer task; the consumer prints each as it arrives. Deterministic
\ because scheduling is cooperative: tasks yield only at 'pause', round-robin.
\ Cooperative send/receive between two tasks (the receiver must NOT toggle
\ multi/single itself -- the main task owns that; a nested single deadlocks it).
system +order
task: rx
task: tx
: .tx  10 rx send  20 rx send  30 rx send  begin pause again ;
: .rx  begin receive drop . again ;
single
' .tx tx activate
' .rx rx activate
: run  multi  20 for pause next  single ;
run cr
bye
