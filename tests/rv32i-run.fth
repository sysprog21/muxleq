\ RV32I program runner: a Forth-driven fetch-decode-execute loop runs
\ hand-encoded programs from guest RAM (rvram) with a self-advancing RVPC. rvstep executes each
\ instruction; ecall (SYSTEM 0x73) sets rvstate and the host (this harness) services it -- write
\ (a7=64) emits guest bytes, exit (a7=93) halts. Programs terminate via jal-self-loop or exit.
hex
\ The fetch-decode-execute runner (rvrun), its ecall write/exit servicing, and the guest-RAM
\ helpers are built into the image now, so this test only loads programs and asserts registers.
\ rvrun ( haltpc -- ) runs from entry 0 (sp=x2=0x8000) until the program exits/traps or RVPC == haltpc;
\ output-producing programs (write/exit) pass an unreachable FFFF haltpc. rvg! stores a guest cell.
variable wl  variable wh
: g! rvg! ;                              ( v c -- : store guest cell c )
: w! ( lo hi a -- )  2/ >r  r@ 1+ g!  r> g! ;   ( store a 32-bit word at byte address a )
: chkreg ( idx wlo whi -- )  wh !  wl !  rv-idx ! rvrd
  rv-s1lo @ wl @ =  rv-s1hi @ wh @ =  and  if ." OK" else ." FAIL" then cr ;

\ program 1: sum 1..5 into x1 (ADDI/ADD/BLT backward branch, JAL halt)
0093 0000 00 w!
0113 0010 04 w!
0213 0060 08 w!
80B3 0020 0C w!
0113 0011 10 w!
4CE3 FE41 14 w!
006F 0000 18 w!
18 rvrun   \ halt at 0x18
01 000F 0000 chkreg   \ x1 = 15

\ program 2: store 0x123 to mem[0x80], load it back to x3 (SW/LW running from RAM)
0093 1230 00 w!
0293 0800 04 w!
A023 0012 08 w!
A183 0002 0C w!
006F 0000 10 w!
10 rvrun   \ halt at 0x10
03 0123 0000 chkreg   \ x3 = 0x123

\ program 3: JAL/JALR call+return. main sets x10=7, calls double (x10*=2), returns, halts.
0513 0070 00 w!
00EF 0080 04 w!
006F 0000 08 w!
0533 00A5 0C w!
8067 0000 10 w!
08 rvrun   \ halt at 0x08 (returned here)
0A 000E 0000 chkreg   \ x10 = 14

\ program 4: write(1, 0x40, 3) emits "Hi\n", then exit. Exercises ecall write + exit.
0513 0010 00 w!
0593 0400 04 w!
0613 0030 08 w!
0893 0400 0C w!
0073 0000 10 w!
0893 05D0 14 w!
0073 0000 18 w!
6948 000A 40 w!   \ data at 0x40: 'H' 'i' 0x0A
FFFF rvrun   \ program exits via ecall(93); haltpc is an unreachable sentinel
0A 0003 0000 chkreg   \ a0 = write return count = 3 (output "Hi" + newline appears above)

\ program 5: rv32emu's build/hello.elf, a real prebuilt RV32I binary (objcopy -O binary, entry 0,
\ 73 bytes). Uses only addi/beq/jal/ecall: writes "Hello World!\n" five times then exit(0).
0293 00 g!
0000 01 g!
0313 02 g!
0050 03 g!
006F 04 g!
0040 05 g!
0013 06 g!
0000 07 g!
8063 08 g!
0262 09 g!
0893 0A g!
0400 0B g!
0513 0C g!
0010 0D g!
0593 0E g!
03C0 0F g!
0613 10 g!
00D0 11 g!
0073 12 g!
0000 13 g!
8293 14 g!
0012 15 g!
F06F 16 g!
FE5F 17 g!
0893 18 g!
05D0 19 g!
0513 1A g!
0000 1B g!
0073 1C g!
0000 1D g!
6548 1E g!
6C6C 1F g!
206F 20 g!
6F57 21 g!
6C72 22 g!
2164 23 g!
000A 24 g!
FFFF rvrun   \ entry 0; terminates via ecall(93)

\ program 6: illegal-encoding trap. x3 is cleared, then mul x3,x1,x2 (RV32M, unsupported) at
\ 0xc halts the runner ("illegal instruction at c"); x3 stays 0 -- the mul never executed.
0193 0000 00 w!
0093 0050 04 w!
0113 0030 08 w!
81B3 0220 0C w!
FFFF rvrun   \ traps at 0xc
03 0000 0000 chkreg   \ x3 = 0 (mul did not execute)

\ program 7: unknown-opcode trap. FENCE (0x0000000F) is not implemented; the runner traps at 0.
000F 0000 00 w!
FFFF rvrun   \ traps at 0 with an "illegal instruction at 0" report

\ program 8: byte-memory integration. strcpy-style loop copies "OK!\n" (LB/SB in a running
\ loop, BNE branch) from guest 0x40 to 0x50, then write(1,0x50,4) prints it, then exit.
0293 0400 00 w!
0313 0500 04 w!
0393 0040 08 w!
8503 0002 0C w!
0023 00A3 10 w!
8293 0012 14 w!
0313 0013 18 w!
8393 FFF3 1C w!
96E3 FE03 20 w!
0513 0010 24 w!
0593 0500 28 w!
0613 0040 2C w!
0893 0400 30 w!
0073 0000 34 w!
0893 05D0 38 w!
0073 0000 3C w!
4B4F 20 g!   \ 'O' 'K' at 0x40
0A21 21 g!   \ '!' 0x0A at 0x42
FFFF rvrun   \ prints OK! then exits

\ program 9: stack round-trip. sp (preset to 0x8000, top of 32 KiB guest RAM, by rvrun) -= 4;
\ SW a0=0x42 to [sp]; LW it back into a1; sp += 4. Proves the runner initializes sp so
\ stack-using programs work.
0113 FFC1 00 w!
0513 0420 04 w!
2023 00A1 08 w!
2583 0001 0C w!
0113 0041 10 w!
006F 0000 14 w!
14 rvrun   \ halt at 0x14
0B 0042 0000 chkreg   \ a1 = 0x42 (round-tripped through the stack)
02 8000 0000 chkreg   \ sp restored to 0x8000 (top of 32 KiB guest RAM)

\ program 10: unsupported-syscall halt. a7=0x22 (not write/exit), then ecall. The runner must
\ report "unsupported syscall 22" and halt -- distinct from a normal exit(93), which is silent.
0893 0220 00 w!   \ addi x17, x0, 0x22
0073 0000 04 w!   \ ecall
FFFF rvrun        \ halts via the unsupported-syscall diagnostic

\ program 11: halfword memory through the runner. SW a full word, overwrite its low half with SH,
\ then LW/LH/LHU it back -- proves SH writes 2 bytes only, LH sign-extends, LHU zero-extends, and a
\ positive LH (offset 2) does NOT sign-extend. Only the single-step rvstep path (rv32i-spec.fth) had
\ halfword coverage before; this exercises LH/LHU/SH through the live fetch-decode-execute loop.
0093 0400 00 w!   \ addi x1, x0, 0x40      (base)
2137 1111 04 w!   \ lui  x2, 0x11112
0113 2221 08 w!   \ addi x2, x2, 0x222     (x2 = 0x11112222)
A023 0020 0C w!   \ sw   x2, 0(x1)         mem[0x40] = 0x11112222
0193 FFF0 10 w!   \ addi x3, x0, -1        (x3 = 0xFFFFFFFF)
9023 0030 14 w!   \ sh   x3, 0(x1)         low half -> mem[0x40] = 0x1111FFFF
A203 0000 18 w!   \ lw   x4, 0(x1)         x4 = 0x1111FFFF  (SH left high half intact)
9283 0000 1C w!   \ lh   x5, 0(x1)         x5 = 0xFFFFFFFF  (sign-extend)
D303 0000 20 w!   \ lhu  x6, 0(x1)         x6 = 0x0000FFFF  (zero-extend)
9383 0020 24 w!   \ lh   x7, 2(x1)         x7 = 0x00001111  (positive half, no sign-extend)
006F 0000 28 w!   \ jal  x0, 0             (halt self-loop)
28 rvrun   \ halt at 0x28
04 FFFF 1111 chkreg   \ x4 = 0x1111FFFF
05 FFFF FFFF chkreg   \ x5 = 0xFFFFFFFF
06 FFFF 0000 chkreg   \ x6 = 0x0000FFFF
07 1111 0000 chkreg   \ x7 = 0x00001111

\ program 12: 32 KiB guest-RAM window. Store distinct sentinels at guest byte 0x40 and 0x4040, then
\ read back 0x40. Those two addresses ALIAS under a 512-cell mask ((0x4040>>1)&0x1FF == (0x40>>1)&0x1FF
\ == 0x20) but are distinct cells 0x20 vs 0x2020 in the 16384-cell window -- so x5 == 0x111 only if the
\ window really spans 32 KiB. Guards the rvrammask/rv-ram relocation against a silent shrink to 1 KiB.
0093 0400 00 w!   \ addi x1, x0, 0x40      (low base)
0113 1110 04 w!   \ addi x2, x0, 0x111     (sentinel A)
0213 2220 08 w!   \ addi x4, x0, 0x222     (sentinel B)
41B7 0000 0C w!   \ lui  x3, 0x4           (x3 = 0x4000)
8193 0401 10 w!   \ addi x3, x3, 0x40      (x3 = 0x4040, high base)
A023 0020 14 w!   \ sw   x2, 0(x1)         mem[0x40]   = 0x111
A023 0041 18 w!   \ sw   x4, 0(x3)         mem[0x4040] = 0x222  (aliases 0x40 iff mask == 0x1FF)
A283 0000 1C w!   \ lw   x5, 0(x1)         x5 = mem[0x40]
006F 0000 20 w!   \ jal  x0, 0             (halt self-loop)
20 rvrun   \ halt at 0x20
05 0111 0000 chkreg   \ x5 = 0x00000111  (0x222 here would mean the window collapsed to 1 KiB)
decimal cr bye
