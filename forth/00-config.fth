defined eforth [if] ' ) <ok> ! [then] ( Turn off ok prompt )

\ MUXLEQ eForth Cross-Compiler and Virtual Machine
\
\ This file contains a cross compiler and eForth interpreter for the
\ two-instruction MUXLEQ CPU architecture. This version of Forth is
\ derived from an eForth implementation designed for a 16-bit MUXLEQ CPU.
\
\ The MUXLEQ architecture extends SUBLEQ with a multiplexing operation:
\ - SUBLEQ: Mem[b] = Mem[b] - Mem[a]; if Mem[b] <= 0 then pc = c
\ - MUX: If c < -1, then Mem[b] = (Mem[a] & ~Mem[c]) | (Mem[b] & Mem[c])
\ - I/O: a=-1 for input, b=-1 for output, c=-1 to halt
\
\ The cross compiler is compatible with Gforth and has been tested.

only forth definitions hex

\ Feature Configuration
1 constant opt.multi      ( Enable multitasking with "pause" primitive )
1 constant opt.editor     ( Include block-based text editor )
1 constant opt.better-see ( Enhanced decompiler for "see" command )
1 constant opt.control    ( Extended control structures do/loop, case/of )
1 constant opt.allocate   ( Dynamic memory allocation allocate/free )
1 constant opt.glossary   ( Word glossary and analysis tools )
1 constant opt.divmod     ( Hardware division/modulo primitive )
1 constant opt.rv32i      ( RV32I microcode interpreter; make ENABLE_RV32I=0 stamps this to 0 )
opt.rv32i [if]
\ RV32I guest RAM lives in a fixed high-memory window ($7000 byte = cell $3800), NOT baked into the
\ image (same trick as buf0/=thread): only touched while running an RV program, never during
\ self-host bootstrap, so it costs zero image cells. Base is a plain forth constant so the tvar
\ block (rvrambase) and the runner (rv-ram) both read it.
7000 constant rvram       ( RV32I: guest-RAM base byte address; guest cell 0 lives here )
[then]

\ System options bit flags
: sys.echo-off 1 or ;     ( bit #1 = turn character echoing off )
: sys.cksum    2 or ;     ( bit #2 = enable system checksumming )
: sys.eof      8 or ;     ( bit #4 = terminate on EOF )
0 sys.eof sys.echo-off constant opt.sys

\ Compatibility Layer for Different Forth Systems
defined (order) 0= [if]
: (order) ( w wid*n n -- wid*n w n )
  dup if
    1- swap >r recurse over r@ xor
    if 1+ r> -rot exit then rdrop
  then ;
: -order get-order (order) nip set-order ; ( wid -- )
: +order dup >r -order get-order r> swap 1+ set-order ;
[then]

defined [unless] 0= [if]
: [unless] 0= postpone [if] ; immediate
[then]

defined eforth [if]
  : wordlist here cell allot 0 over ! ; ( -- wid : allocate wordlist )
[then]

\ Meta-Compiler Vocabulary Setup
