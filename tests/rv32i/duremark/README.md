# DureMark

DureMark, a tiny CoreMark-alike (linked-list, 10×10 matrix, and number-format
state-machine workloads).

## Layout

- `run.c`: replaces upstream `main.c` with a fixed-iteration, clockless harness
  that prints the combined workload checksum via the `write(64)` ecall. Each
  `ecall` loads `a7` inside its own basic block so `rvopt mux` can resolve the
  syscall number.
- `crt0.S`: entry at guest address 0, sets `sp`, calls `du_main`, then `exit(93)`.
- `duremark.ld`: links everything low from address 0; `sp` grows down from
  `0x8000` (top of the 32 KiB window).
- `soft.c`: self-contained `__mulsi3`/`__udivsi3`/`__umodsi3`/`__modsi3`.

## Base ISA only

Built `-march=rv32i` (no RV32M), so the matrix workload's 32-bit multiply and
`% 1000` need software multiply/divide/modulo. `soft.c` supplies them instead of
`libgcc`: libgcc's div/mod helpers return through a shared millicode tail via
`jr t0`, a runtime `JALR` that `rvopt mux` cannot lower. The `soft.c` versions
use only `jal`/`ret`, so the whole image lowers to native MUXLEQ. No `MUL`/`DIV`
instruction is emitted either way.

## Build and run

Building the `.elf` needs a bare-metal `riscv-none-elf-*` toolchain; lowering and
running it do not (`rvopt` and `muxleq` are plain C).

```
make        # build duremark.elf
make run    # lower with 'rvopt mux', run on the muxleq VM, assert the checksum
```

The top-level `make bench-rv32i` times this run; `make rv32i-check` gates the
checksum. The iteration count in `run.c` also feeds the checksum, so changing it
re-pins the value in this directory's `Makefile`.
