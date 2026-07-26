.( example: producer/consumer )

\ Producer         Scheduler         Consumer
\ ---------        ----------        ----------
\ store4        ─▶ state2 = 0 ──┐
\                               │    mbflag? (now 1)───▶ sum4 & print
\ mbflag = 1                    │
\ ...xx done (prints)           │              ...yy done (prints)
\ state1 = 1  ──────────────────┘              state2 = 1

' ( <ok> ! ( disable ok prompt [non-portable] )
system +order

\ ----- task states: 0 = ready, 1 = waiting -------------------------
variable state1   0 state1 !      \ producer starts ready
variable state2   1 state2 !      \ consumer starts waiting

: ready1   0 state1 ! ;
: wait1    1 state1 ! ;
: ready2   0 state2 ! ;
: wait2    1 state2 ! ;

\ ----- one-slot mailbox (four 16-bit numbers) ----------------------
variable mbflag    0 mbflag !
create  mb  8 allot            \ mb[0] .. mb[3] (8 bytes)

: store4  ( n1 n2 n3 n4 -- )
  mb       !          mb 2 +  !
  mb 4 +   !          mb 6 +  !
  1 mbflag ! ;

: sum4    ( -- u )
  mb 6 + @  mb 4 + @ +  mb 2 + @ +  mb @ + ;

\ ----- dummy lock / unlock (single real thread) -------------------
: lock ;
: unlock ;

\ ------------------ producer task ---------------------------------
: xx
  1 2 3 4 store4        \ fill mailbox
  ready2                \ wake consumer
  lock ." ...xx done" cr unlock
  wait1 ;               \ producer finished

\ ------------------ consumer task ---------------------------------
: yy
  mbflag @ 0= if  wait2 exit  then
  sum4
  lock ." total=" . cr unlock
  lock ." ...yy done" cr unlock
  wait2 ;               \ consumer finished

\ ----- scheduler helpers ------------------------------------------
: running?   state1 @ 0=  state2 @ 0=  or ;  \ any task ready?

: scheduler
  begin running? while
    state1 @ 0= if  xx  then
    state2 @ 0= if  yy  then
  repeat ;

\ --------------------- GO -----------------------------------------
scheduler
.( VM: all tasks finished ) cr
