opt.rv32i [if]
\ Built-in RV32I loader + runner. Loads a flat RV32I image (the raw bytes objcopy -O binary
\ produces, or any stream of instruction words) into guest RAM and runs it from entry 0 through
\ the single-entry rvstep microcode, servicing ecall write(a7=64)/exit(a7=93) itself. This makes a
\ prebuilt binary runnable directly, with no host-side conversion:
\   objcopy -O binary prog.elf prog.bin
\   { printf '%d rvboot\n' "$(wc -c < prog.bin)"; cat prog.bin; } | ./muxleq
variable rvhalt  variable rvhpc  variable rvwp  variable rvwn  ( runner state )
: rvg@ ( c -- v )  2* rv-ram + @ ;                 ( read guest cell c )
: rvg! ( v c -- )  2* rv-ram + ! ;                 ( write guest cell c )
: rvgbyte ( ba -- b )  dup #1 and swap 2/ rvg@ swap if [ 8 ] literal rshift then [ FF ] literal and ;
: rvget ( idx -- lo )  rv-idx ! rvrd rv-s1lo @ ;   ( read reg[idx] low half )
: rvput ( val idx -- )  rv-idx ! rv-rlo ! #0 rv-rhi ! rvwr ;   ( reg[idx] = val )
\ write(a0=fd ignored, a1=buf, a2=len): emit len guest bytes to stdout, return len in a0
: rvwrite  [ 0B ] literal rvget rvwp !  [ 0C ] literal rvget rvwn !  rvwn @ [ 0A ] literal rvput
   begin rvwn @ while  rvwp @ rvgbyte emit  rvwp @ 1+ rvwp !  rvwn @ 1- rvwn !  repeat ;
: rvsyscall  [ 11 ] literal rvget                        ( a7 )
   dup [ 40 ] literal = if  drop rvwrite  exit then      ( write )
       [ 5D ] literal = if  #-1 rvhalt !  exit then      ( exit: halt silently )
   ." unsupported syscall " [ 11 ] literal rvget u. cr  #-1 rvhalt ! ;
: rvfetch  rv-pclo @ 2/  dup rvg@ rv-il !  1+ rvg@ rv-ih ! ;
: rvadv  rv-ctrl @ 0= if  rv-pclo @ [ 4 ] literal + rv-pclo !  then ; ( branches/jumps set RVPC )
: rvrunning  rvhalt @ #0 =  rv-pclo @ rvhpc @ <>  and ;
: rvrun ( haltpc -- )  rvhpc !  #0 rv-pclo ! #0 rv-pchi ! #0 rvhalt !
   [ 8000 ] literal #2 rvput                             ( sp x2 = 0x8000, top of 32 KiB guest RAM )
   begin rvrunning while  rvfetch rvstep
     rv-state @ if  rv-state @ #1 = if rvsyscall             ( 1 = ecall to service )
       else ." illegal instruction at " rv-pclo @ u. cr  #-1 rvhalt ! then  then ( 2 = trap )
     rvadv  repeat ;
variable rvlp                      ( -- a : guest-cell load pointer, in cells )
: rvorg  #0 rvlp ! ;               ( -- : reset the load pointer to guest cell 0 )
: rvcell, ( c -- )  rvlp @ [ 3FFF ] literal and rvg!  rvlp @ 1+ rvlp ! ; ( append a cell, masked to guest RAM )
: rvboot  [ FFFF ] literal rvrun ; ( -- : run the loaded image from entry 0 until exit/trap )
[then]

\ System Finalization
: cold [ {boot} ] literal 2* @execute ; ( -- : cold start )

t' (boot) half {boot} t!           ( Set starting Forth word )
t' quit {quit} t!                  ( Set initial Forth word )
atlast {forth-wordlist} t!         ( Make wordlist work )
{forth-wordlist} {current} t!      ( Set "current" dictionary )
there h t!                         ( Assign dictionary pointer )
local? {user}  t!                  ( Assign number of locals )
primitive t@ double mkck check t!  ( Set checksum over Forth )
atlast {last} t!                   ( Set last defined word )
save-target                        ( Output target image )
.end                               ( Return to normal Forth )
bye                                ( Exit cross-compiler )
