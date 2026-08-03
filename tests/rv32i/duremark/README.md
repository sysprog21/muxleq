# DureMark

DureMark, a tiny CoreMark-alike (linked-list, 10×10 matrix, and number-format
state-machine workloads).

## Layout

- `run.c`: replaces upstream `main.c` with a fixed-iteration, clockless harness
  that prints the combined workload checksum via the `write(64)` ecall.
- `crt0.S`: entry at guest address 0, sets `sp`, calls `du_main`, then `exit(93)`.
- `duremark.ld`: links everything low from address 0; `sp` grows down from
  `0x8000` (top of the 32 KiB window).

## Base ISA only

Built `-march=rv32i` (no RV32M). The matrix workload's 32-bit multiply and
`% 1000` resolve to rv32i `libgcc` software routines (`__mulsi3`/`__umodsi3`),
which are themselves pure RV32I; no `MUL`/`DIV` instruction is emitted.

## Build

Needs a bare-metal `riscv-none-elf-*` toolchain:

```
make   # build duremark.elf
```
