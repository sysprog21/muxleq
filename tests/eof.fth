\ EOF-terminate regression guard (opt.sys's sys.eof bit, muxleq.fth:31-32). This file has NO 'bye':
\ the VM must exit when stdin reaches end-of-file, not spin. If EOF handling regresses, 'make golden'
\ hangs and its timeout(1) bound fails the gate. The line below also proves normal execution still
\ happens before EOF -- a break that skipped the line would drop "5" from the golden.
decimal 2 3 + . cr
