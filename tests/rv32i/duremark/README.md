# DureMark on MUXLEQ

DureMark -- a tiny CoreMark-alike (linked-list, 10×10 matrix, and number-format
state-machine workloads) -- built freestanding for the RV32I simulator and run
through the MUXLEQ VM with `../../../muxleq -r duremark.elf`.

This is the first benchmark-class workload the simulator runs: its ~4.5 KB guest
image (code + ~1.5 KB of static buffers + stack) needs the 32 KiB guest-RAM
window and would not have fit the earlier 1 KiB one.

## Layout

- `list.c`, `matrix.c`, `state.c`, `duremark.h`, `LICENSE` -- vendored verbatim
  from https://github.com/sergev/duremark (MIT). The three `du_bench_*` workloads
  run unmodified.
- `run.c` -- replaces upstream `main.c`. The simulator has no wall clock, so this
  drops the timing/auto-scaling and the float/`printf` scoring, runs a FIXED
  iteration count, and prints the combined workload checksum via the `write(64)`
  ecall. The checksum is byte-identical to a native build, so it is a real
  correctness oracle for the RV32I microcode, not just a smoke test.
- `crt0.S` -- entry at guest address 0 (the runner requires it), sets `sp`, calls
  `du_main`, then `exit(93)`.
- `duremark.ld` -- links everything low from address 0; `sp` grows down from
  `0x8000` (top of the 32 KiB window).

## Base ISA only

Built `-march=rv32i` (no RV32M). The matrix workload's 32-bit multiply and
`% 1000` resolve to rv32i `libgcc` software routines (`__mulsi3`/`__umodsi3`),
which are themselves pure RV32I -- no `MUL`/`DIV` instruction is emitted.

## Build / run

Needs a bare-metal `riscv-none-elf-*` toolchain (the `.elf` is committed so the
VM and `make duremark` work without one).

```
make                       # rebuild duremark.elf
make run                   # build + run under the VM
```

From the repo root, `make duremark` runs the committed image under a timeout and
diffs the checksum against `tests/expected/duremark.out`; it is part of
`make check-all` but not the fast `make check` (one iteration is ~3.2 G dispatched
MUXLEQ ops, ~16 s).
