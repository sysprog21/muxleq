# MUXLEQ

```
       ______         _   _
       |  ____|       | | | |
  ___  | |__ ___  _ __| |_| |__
 / _ \ |  __/ _ \| '__| __| '_ \
|  __/ | | | (_) | |  | |_| | | |
 \___| |_|  \___/|_|   \__|_| |_|
 _____ ______   ___  ___     ___    ___ ___       _______   ________
|\   _ \  _   \|\  \|\  \   |\  \  /  /|\  \     |\  ___ \ |\   __  \
\ \  \\\__\ \  \ \  \\\  \  \ \  \/  / \ \  \    \ \   __/|\ \  \|\  \
 \ \  \\|__| \  \ \  \\\  \  \ \    / / \ \  \    \ \  \_|/_\ \  \\\  \
  \ \  \    \ \  \ \  \\\  \  /     \/   \ \  \____\ \  \_|\ \ \  \\\  \
   \ \__\    \ \__\ \_______\/  /\   \    \ \_______\ \_______\ \_____  \
    \|__|     \|__|\|_______/__/ /\ __\    \|_______|\|_______|\|___| \__\
                            |__|/ \|__|                              \|__|
```

MUXLEQ is a two-instruction esoteric programming language,
extending the classic `SUBLEQ` with a multiplexing operation for enhanced performance and reduced program size.
This project provides a complete, self-hosting development environment for it.

On top of that foundation it also hosts an RV32I ISA simulator: a RISC-V base-integer interpreter,
assembled by the eForth image itself, that runs real RV32I programs on the two-instruction machine
(`./build/muxleq -r`) -- a full RISC-V base ISA riding on a two-instruction OISC.

## Introduction
This repository contains a full toolchain for the MUXLEQ architecture, including:
1. An assembler for the MUXLEQ instruction set.
2. A virtual machine built upon the assembler.
3. A cross-compiler that targets the VM with a version of the eForth programming language.
4. An RV32I ISA simulator on top of MUXLEQ -- a RISC-V base-integer interpreter assembled into the eForth image, running RV32I programs via `./build/muxleq -r`.

The system is self-hosted, meaning the eForth environment can compile new versions of itself from source,
allowing for seamless modification and extension.

SUBLEQ is a Turing-complete One-Instruction Set Computer (OISC).
While esoteric, its ability to run a high-level language like Forth is a powerful demonstration of computational minimalism.
This project serves as an experimental platform for exploring the execution of high-level languages on a minimal hardware-like foundation.

## Getting Started
This project requires a C compiler, Gforth, and GNU Make.
* macOS: `brew install gforth`
* Ubuntu/Debian: `sudo apt-get install gforth build-essential`

Build the VM and start the eForth interpreter:
```shell
$ make run
```

An example session:
```
words
21 21 + . cr
: hello ." Hello, World!" cr ;
hello
bye
```

In Forth, executable commands are called "words."
The `words` command lists all defined functions in the dictionary.
Forth uses Reverse Polish Notation (RPN), so `21 21 + . cr` pushes 21,
then 21, adds them, prints the result, and adds a carriage return.

New words are defined with `: <name> <definition> ;`.
Once defined, the word `hello` can be executed by typing its name.

### Testing, benchmarking, and internals

- `make check` -- the pre-commit gate: byte-exact golden-output tests (`tests/*.fth` vs
  `tests/expected/*.out`, each run time-bounded), the `rvopt` AOT differential (its native
  `-x`/`-x32` images must reproduce `-r` on every demo), plus the self-hosting bootstrap, which
  checks the VM reproduces its own image byte-for-byte.
- `make bench` -- times the VM on a quiet remote host (`node1` by default, override with
  `BENCH_HOST`); localhost load makes wall-clock timing unreliable. Reports per-workload user
  time and a deterministic instruction count.
- `./build/muxleq -s` and `./build/muxleq -p` -- the built-in profiler: instruction mix and a per-PC heat
  map. Default runs (no flags) are byte-identical, so the gates are unaffected.
- `./build/muxleq -r prog` -- run an RV32I program (an ELF32 executable or a flat `objcopy` binary) on
  the RV32I microcode interpreter that the image itself assembles -- a RISC-V ISA hosted on the
  16-bit OISC. `make verify-rv32i` checks it against an independent reference model. See the
  manual's RV32I section.
- `rvopt` -- a standalone ahead-of-time compiler that lowers an RV32I ELF32/flat binary to a native
  MUXLEQ image running on the two ops directly, with no interpreter layer: `rvopt -mux prog >
  prog.dec` then `./build/muxleq -x prog.dec` for the 16-bit path (which beats `-r` on measured compute
  targets), or `rvopt -mux32` then `./build/muxleq -x32` for the wide 32-bit-cell backend. The wide path
  passes all 40 rv32ui compliance tests, including large programs the 16-bit image cannot hold; both
  are differential-tested against `-r`. See [`docs/rvopt-native-muxleq.md`](docs/rvopt-native-muxleq.md).
- [`docs/manual.md`](docs/manual.md) -- reference manual: the instruction set, memory image and
  self-modifying-operand rules, the build/bootstrap pipeline, the interpreter, the eForth
  environment, and the RV32I microcode runner.

## MUXLEQ Architecture
The MUXLEQ architecture extends the classic SUBLEQ OISC with a second instruction to improve performance without significantly increasing implementation complexity.
Existing SUBLEQ programs are generally compatible with MUXLEQ.

### The SUBLEQ Foundation
A SUBLEQ instruction consists of three operands, `a`, `b`, and `c`,
which are addresses pointing to memory locations.
```
a b c
```

The instruction performs the following operation:
```python
# Pseudo-code for a single SUBLEQ instruction
Mem[b] = Mem[b] - Mem[a]
if Mem[b] <= 0:
    pc = c
```

Special operand values trigger I/O or halt the machine:
* Input: If `a` is -1, a byte is read from input and stored at the address `b`.
* Output: If `b` is -1, the byte at address `a` is sent to the output.
* Halt: If `c` is a negative address, the program halts.

### The MUX Enhancement
MUXLEQ adds a multiplexing (MUX) instruction by encoding it into the `c` operand.
If `c` is negative (but not -1, which is reserved for I/O),
the MUX operation is performed instead of a branch.
This avoids needing a separate opcode, preserving the simple `a b c` instruction format.

The complete MUXLEQ logic is as follows:
```python
# Pseudo-code for the MUXLEQ virtual machine
while pc >= 0:
    a = Mem[pc + 0]
    b = Mem[pc + 1]
    c = Mem[pc + 2]
    pc += 3

    if a == -1:
        Mem[b] = get_byte()  # Input
    elif b == -1:
        put_byte(Mem[a])     # Output
    elif c < -1: # Negative 'c' triggers MUX
        # Multiplex: Mem[b] = (Mem[a] AND (NOT Mem[c])) OR (Mem[b] AND Mem[c])
        Mem[b] = (Mem[a] & ~Mem[c]) | (Mem[b] & Mem[c])
    else:
        Mem[b] = Mem[b] - Mem[a]
        if Mem[b] <= 0:
            pc = c # Branch
```

MUX with constants `0` and `-1` can implement any boolean function:
- AND: Use selector = second operand
- OR: Use selector = ~first operand
- XOR: Combine multiple MUX operations
- NOT: MUX with swapped true/false values

The above are expensive in pure SUBLEQ (requiring dozens of instructions).

Setting the selector to 0 creates single-instruction MOV, can replace SUBLEQ's 4-instruction copy sequence.
In addition, direct bit manipulation accelerates pointer arithmetic, array indexing, and indirect memory operations.

### Future Directions and Variants
The MUXLEQ design can be extended with other instructions by encoding them in the operands. Some potential enhancements include:
* Bit Reversal: As proposed in "[Subleq: An Area-Efficient Two-Instruction-Set Computer](https://janders.eecg.utoronto.ca/pdfs/esl.pdf)," a bit-reversal instruction can efficiently implement arithmetic shifts.
* Right Shift: A dedicated right-shift would significantly accelerate arithmetic operations.
* Comparison: A comparison instruction could store the result of `Mem[a]` vs. `Mem[b]` (e.g., is-zero, less-than) into `Mem[a]`.

## eForth and Meta-Compilation
The Forth environment provided is a variant of **eForth**, designed by Bill Muench and C.H. Ting for portability and efficiency.
It is implemented with a small set of assembly primitives, making it ideal for unconventional targets like MUXLEQ.

The cross-compiler source lives in the numbered `forth/*.fth` modules, which
concatenate in order into the generated `build/muxleq.fth` -- a Forth program
that translates eForth source into a MUXLEQ memory image. Edit the modules, not
the generated file. The cross-compilation proceeds in four stages:

1. Assembler: define the MUXLEQ machine-code primitives.
2. Virtual machine: build a VM layer over the assembler for high-level Forth.
3. Forth dictionary: define the core words.
4. Image generation: write the final memory image to standard output.

### Bootstrap and Validation
The system's correctness is validated through a self-hosting build process,
often called "meta-compilation" in the Forth community.
If a compiled system can recompile itself and produce a byte-for-byte identical output, the compiler is considered correct.

This validation can be run with a single command:
```shell
$ make bootstrap
```

This command performs the following steps, all under `build/`:
1. Concatenate the `forth/*.fth` modules into `build/muxleq.fth` and run it
   through Gforth to produce the first image, `build/stage0.dec`.
2. Compile the VM (`cc -Ibuild -o build/muxleq muxleq.c`), which `#include`s the
   generated `build/stage0.c` and `build/rv32i-traces.inc`.
3. Run `build/muxleq` on `build/muxleq.fth` to produce a second image,
   `build/stage1.dec`.
4. Compare the two images.

If `build/stage0.dec` and `build/stage1.dec` are byte-for-byte identical, the
bootstrap succeeds.

## License
This project is released into the Public Domain.
It was originally written by [Richard James Howe](https://github.com/howerj).

## Reference
* [SUBLEQ EFORTH: Forth Metacompilation for a SUBLEQ Machine](https://www.amazon.com/dp/B0B5VZWXPL)
