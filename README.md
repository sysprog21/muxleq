# MUXLEQ

```
 _____ ______   ___  ___     ___    ___ ___       _______   ________
|\   _ \  _   \|\  \|\  \   |\  \  /  /|\  \     |\  ___ \ |\   __  \
\ \  \\\__\ \  \ \  \\\  \  \ \  \/  / \ \  \    \ \   __/ \ \  \|\  \
 \ \  \\|__| \  \ \  \\\  \  \ \    / / \ \  \    \ \  \   _\ \  \\\  \
  \ \  \    \ \  \ \  \\\  \  /     \/   \ \  \____\ \  \_|\ \ \  \\\  \
   \ \__\    \ \__\ \_______\/  /\   \    \ \_______\ \_______\ \_____  \
    \|__|     \|__|\|_______/__/ /\ __\    \|_______|\|_______|\|___| \__\
                            |__|/ \|__|                              \|__|
```

MUXLEQ is a minimalist esoteric machine. Its core is two instructions: the
classic `SUBLEQ` plus a multiplexing (MUX) operation that adds single-instruction
data movement and boolean logic. A small, disciplined set of native primitives is
layered on top by encoding them in otherwise-unused operand values; today that is
a single right-shift op. The result runs faster and in fewer cells than pure
SUBLEQ, and this project ships a complete, self-hosting development environment
for it.

MUXLEQ is a 32-bit-cell, cell-addressed VM. With no argument it runs the
self-hosting eForth image; given a FILE it loads and runs that standalone
MUXLEQ image instead: `./build/muxleq image.dec`.

## Introduction
This repository contains a full toolchain for the MUXLEQ architecture, including:
1. An assembler for the MUXLEQ instruction set.
2. A virtual machine built upon the assembler.
3. A cross-compiler that targets the VM with a version of the eForth programming language.
4. `rvopt`, a standalone RV32I-to-MUXLEQ compiler for wide native MUXLEQ images.

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

- `make check` runs the pre-commit gate: byte-exact 32-bit golden-output tests,
  the PTY editor golden, 32-bit eForth smokes, and the self-hosting bootstrap.
- `make check-all` runs `make check` plus wide native-image fuzz, loader rejection,
  and ASan/UBSan validation.
- `rvopt` is a standalone ahead-of-time compiler that lowers an RV32I ELF32/flat binary to a native
  MUXLEQ image running on the two ops directly, with no interpreter layer:
  `rvopt mux prog > prog.dec` then `./build/muxleq prog.dec`.
  See [`docs/rvopt-native-muxleq.md`](docs/rvopt-native-muxleq.md).
- RV32I test programs: freestanding RISC-V demos, benchmarks, and the official
  rv32ui conformance suite live in [`tests/rv32i/`](tests/rv32i). `make rv32i`
  cross-builds the demo, unopt, and DureMark programs into `build/rv32i`;
  `make rv32i-check` additionally lowers the demo and unopt programs with
  `rvopt mux`, runs them on the VM, and runs the rv32ui conformance suite
  (DureMark is build-checked only, since it uses computed jumps `rvopt` cannot
  lower). Both need a bare-metal
  `riscv-none-elf-*` toolchain, such as the
  [xPack GNU RISC-V toolchain](https://xpack-dev-tools.github.io/riscv-none-elf-gcc-xpack/).
  CI builds and runs everything with the xPack toolchain on every push. On the
  default branch it also packs `build/rv32i` into a compressed archive and
  publishes it as a rolling `rv32i-latest` pre-release, replaced on every push;
  every run additionally uploads the same tree as the `rv32i-binaries` workflow
  artifact. Either lets you download prebuilt images without a cross toolchain
  installed.
- [`docs/manual.md`](docs/manual.md) is the reference manual: the instruction set, memory image and
  self-modifying-operand rules, the build/bootstrap pipeline, the interpreter, and the eForth
  environment.

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
* Halt: a taken branch to a negative address halts the machine: the program
  counter itself goes negative. By convention the halt target is -1 (`Z, Z, -1`).

### The MUX Enhancement
MUXLEQ adds a multiplexing (MUX) instruction by encoding it into the `c` operand.
If `c` has its high bit set but is not -1 (`0xffffffff`, which stays the
halt/branch target), the MUX operation is performed instead of a branch.
This avoids needing a separate opcode, preserving the simple `a b c` instruction format.

The core MUXLEQ logic is as follows (one reserved mask value is additionally
dispatched as a native shift; see "Native primitives and their limits" below):
```python
# Pseudo-code for the MUXLEQ virtual machine; cells are unsigned 32-bit
while not (pc & 0x80000000): # run until the PC's high bit is set (halt)
    # every Mem[] index below is masked into the bounded host arena
    a = Mem[pc + 0]
    b = Mem[pc + 1]
    c = Mem[pc + 2]
    pc += 3

    if a == 0xFFFFFFFF:             # -1: input
        Mem[b] = get_byte()
    elif b == 0xFFFFFFFF:           # -1: output
        put_byte(Mem[a])
    elif (c & 0x80000000) and c != 0xFFFFFFFF: # high bit set: MUX or a native escape
        mask_addr = c & 0x7FFFFFFF             # low 31 bits address the mask cell
        if mask_addr == 0x7FFFFFFE:            # reserved: native shift-right-by-1
            Mem[b] = Mem[a] >> 1
        else:
            mask = Mem[mask_addr] # cell 6 is the zero register: a zero mask is a MOVE
            Mem[b] = (Mem[a] & ~mask) | (Mem[b] & mask) # Multiplex
    else:                           # SUBLEQ
        Mem[b] = Mem[b] - Mem[a]
        if Mem[b] == 0 or (Mem[b] & 0x80000000): # result <= 0 (signed)
            pc = c                  # Branch
```

MUX with constants `0` and `-1` can implement any boolean function:
- AND: Use selector = second operand
- OR: Use selector = ~first operand
- XOR: Combine multiple MUX operations
- NOT: MUX with swapped true/false values

The above are expensive in pure SUBLEQ (requiring dozens of instructions).

Setting the mask to 0 makes a single-instruction MOVE, replacing SUBLEQ's
multi-instruction copy sequence. Boolean masking through MUX likewise collapses
bit-twiddling that pure SUBLEQ would build from many subtract-and-branch steps.
Because MUX is a *same-lane* selector, though, it cannot move a bit between
positions (it cannot shift). That gap is what the native-primitive mechanism
below fills.

### Native primitives and their limits
Further instructions are encoded in otherwise-unused operand values: a MUX whose
mask address is a reserved, out-of-range value is dispatched as a native op
instead. The machine reserves exactly one such value today, a right shift
(`Mem[b] = Mem[a] >> 1`), which the eForth `shift` word uses in place of a
bit-serial loop.

That one op is not arbitrary; it marks the boundary of what belongs in the ISA.
The core is cheap at same-lane logic (MUX), arithmetic and branching (SUBLEQ), and
*upward* bit movement (a left shift is just `x + x`, since a carry propagates low
to high). Moving a bit the other way, *downward*, it can do only through a
bit-serial loop, so a right shift is the single primitive that turns that loop
into one step. Everything else is a composition of it: a variable shift is a loop
of right shifts (a barrel shift does the same in one step but adds no new
capability), multiply is shift-and-add, divide is shift-and-subtract, all in
software. Native byte load/store are deliberately excluded too: on a cell-addressed
machine they would bake a byte-packing convention into the VM. (A comparison op would not
qualify either: SUBLEQ already subtracts and branches, so it is no gap.) The one
further candidate that does fit the rule is a bit-reversal, genuinely
cross-lane, which the core cannot do, and per "[Subleq: An Area-Efficient
Two-Instruction-Set Computer](https://janders.eecg.utoronto.ca/pdfs/esl.pdf)" an
efficient route to arithmetic shifts, were a workload ever to justify it.

## eForth and Meta-Compilation
The Forth environment provided is a variant of **eForth**, designed by Bill Muench and C.H. Ting for portability and efficiency.
It is implemented with a small set of assembly primitives, making it ideal for unconventional targets like MUXLEQ.

The cross-compiler source lives in the numbered `forth/*.fth` modules, which
concatenate in order into the generated `build/muxleq.fth`, a Forth program
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
   generated `build/stage0.c`.
3. Run `build/muxleq` on `build/muxleq.fth` to produce a second image,
   `build/stage1.dec`.
4. Compare the two images.

If `build/stage0.dec` and `build/stage1.dec` are byte-for-byte identical, the
bootstrap succeeds.

## License
`MUXLEQ` is available under a permissive
[MIT](https://opensource.org/license/mit)-style license.
Use of this source code is governed by a MIT license that can be found
in the [LICENSE](LICENSE) file. 
It was originally written by [Richard James Howe](https://github.com/howerj).

## Reference
* [SUBLEQ EFORTH: Forth Metacompilation for a SUBLEQ Machine](https://www.amazon.com/dp/B0B5VZWXPL)
