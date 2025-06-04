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

## Introduction
This project encompasses an assembler for a [SUBLEQ](https://esolangs.org/wiki/Subleq)
CPU variant called MUXLEQ, a virtual machine built upon that assembler capable
of running [Forth](https://www.forth.com/forth/), and a cross-compiler designed
to target the Forth VM, based on the eForth family of the Forth programming
language. The system is self-hosted, allowing users to create new and modified
systems seamlessly.

SUBLEQ is an esoteric and impractical single-instruction CPU, yet it achieves
Turing-completeness, demonstrating that even with such a limited instruction set,
it can perform any computable task given sufficient memory and time. Porting
a Forth implementation to SUBLEQ serves as a testament to its versatility —- if
you can adapt Forth to run on SUBLEQ, you can port it to virtually any platform.
There is a saying about Forth: "Forth is Sudoku for programmers." This aptly
captures an intricate and satisfying relationship with the language and the
project, serving as an experimental platform for demonstrating execution of
high-level programming languages with minimal effort.

## Build and Run
This setup requires the installation of a C compiler, [Gforth](https://gforth.org/),
and GNU Make.
* macOS: `brew install gforth`
* Ubuntu Linux / Debian: `sudo apt-get install gforth build-essential`

To run eForth on MUXLEQ, simply type:
```shell
$ make run
```

Below is an example session demonstrating basic usage:
```
words
21 21 + . cr
: hello ." Hello, World!" cr ;
hello
bye
```

This allows you to operate eForth within the system. For a list of available
commands, enter `words` and press Enter. In Forth, the term "word" refers to
a function. It is called a "word" because Forth functions are typically named
using space-delimited characters, often forming a single, descriptive term.
Words are organized into vocabularies, which collectively make up the dictionary
in Forth. Numbers are input in Reverse Polish Notation (RPN); for instance,
inputting:
```
2 2 + . cr
```

will display `4`.

To define a new function, use the following format:
```
: hello cr ." Hello, World!" ;
```

Remember that spaces are critical in eForth syntax. After defining a function,
simply type `hello` to execute it.

The system is self-hosting, meaning it can generate new eForth images using
the current eForth image and source code. While Gforth is used to compile the
image from `muxleq.fth`, the Forth system's self-hosting capability also allows
for building new images after modifying any Forth source files. To initiate
self-hosting and validation, run `make bootstrap`.

## MUXLEQ
The MUXLEQ architecture is an enhancement of the classic SUBLEQ
[one-instruction set computer](https://en.wikipedia.org/wiki/One-instruction_set_computer) (OISC),
offering an additional instruction that improves performance and reduces program
size. The MUXLEQ system retains simplicity, making it nearly as straightforward
to implement in hardware as SUBLEQ. Existing SUBLEQ programs typically run on
MUXLEQ without alterations.

Below is the pseudo code for the MUXLEQ variant:
```python
while pc >= 0:
    a = m[pc + 0]
    b = m[pc + 1]
    c = m[pc + 2]
    pc += 3
    if a == -1:
        m[b] = get_byte()  # Input a byte to memory at address b
    elif b == -1:
        put_byte(m[a])     # Output the byte stored at memory address a
    elif c != -1 and c < 0:
        m[b] = (m[a] & ~m[c]) | (m[b] & m[c])  # Multiplex operation
    else:
        r = m[b] - m[a]   # SUBLEQ subtraction
        if r <= 0:
            pc = c        # Branch if the result is less than or equal to zero
        m[b] = r
```

Removing the `elif c != -1 and c < 0:` clause effectively reverts MUXLEQ to a
typical SUBLEQ machine, as this conditional handles the multiplexing logic unique
to MUXLEQ.

SUBLEQ machines belong to a class called OISC, which uses a single instruction
to perform any computable task, albeit inefficiently. SUBLEQ originated from the
"URISC" concept introduced in the 1988 paper
[URISC: The Ultimate Reduced Instruction Set Computer](https://web.ece.ucsb.edu/~parhami/pubs_folder/parh88-ijeee-ultimate-risc.pdf).
The intent was to provide a simple platform for computer engineering students to
design their own instruction sets and microcode. SUBLEQ falls under arithmetic-based
OISCs, in contrast to other types like bit-manipulation or Transport Triggered
Architectures (MOVE-based). Despite its simplicity, SUBLEQ could be made more
efficient with the addition of just one extra instruction, such as NAND or a
Right Shift.

A single SUBLEQ instruction is structured as follows:
```
SUBLEQ a, b, c
```

Since SUBLEQ is the only available instruction, it is often abbreviated simply
as:
```
a b c
```

The three operands `a`, `b`, and `c` are stored in three consecutive memory
locations. Each operand represents an address in memory. The SUBLEQ instruction
performs the following operations in pseudo-code:
```python
    r = m[b] - m[a]
    if r <= 0:
        pc = c
    m[b] = r
```

There are three notable exceptions to the standard operation:
1. Halting Execution: If the address `c` is negative or refers to an invalid
   memory location outside the addressable range, the program halts.
2. Input Operation: If the address `a` is `-1`, a byte is read from the input
   and stored at address `b`.
3. Output Operation: If the address `b` is negative, a byte from address `a` is
   sent to the output.

The SUBLEQ specification does not dictate how numbers are represented. Key
considerations include:
- Bit Length: Numbers can be 8-bit, 16-bit, 32-bit, 64-bit, or even arbitrary
  precision.
- Negative Numbers: Typically implemented using two's complement, but other
  methods like sign-magnitude can also be used.

The simplicity of the MUXLEQ design allows for further optimizations by packing
additional functionality into the instruction set.
Some possible variants include:
* Bit Reversal: The multiplexed value could have its bits reversed during the
  operation. This functionality could be integrated into the `mux` instruction,
  allowing for efficient bit manipulation.
* Right Shift: Incorporating a right shift operation, even by just one position,
  would significantly enhance the arithmetic capabilities of the system.
* Comparison, the result of comparing `m[a]` and `m[b]` could be stored in
  `m[a]`, useful comparisons would be `is zero?`, signed or unsigned less than
  or greater than. Any of those five would be useful.
* The paper "[Subleq: An Area-Efficient Two-Instruction-Set Computer](https://janders.eecg.utoronto.ca/pdfs/esl.pdf)"
  introduces bit-reversal to enhance hardware efficiency. When the c operand is
  negative, the operation `r = reverse(reverse(m[b]) - reverse(m[a]))` is
  performed, where `reverse` flips the bits of a value. This modification turns
  the "less than or equal to zero" branch into a branch on evenness, allowing
  an efficient right shift with minimal additional hardware resources.

Although the current MUXLEQ variant already demonstrates considerable
improvements over SUBLEQ, there are a few missing features, such as the
"self-interpreter" feature found in some extended SUBLEQ variants. With further
effort, additional performance gains and capabilities could be implemented,
further closing the gap between minimalistic architecture and more conventional
designs.

## eForth
The image is a variant of Forth known as "eForth." This implementation of eForth
differs from standard ANS Forth implementations, notably lacking constructs like
the "do...loop" and its variants. The concept behind eForth was to develop a
system that required only a small set of primitives, around 30, written in
assembly to create a highly portable and reasonably efficient Forth. Bill
Muench originally developed eForth, with later enhancements made by Dr.
Chen-Hanson Ting.

`muxleq.fth` functions as both a cross-compiler and an eForth interpreter,
specifically designed for MUXLEQ. Written entirely in Forth, `muxleq.fth` has
been verified for compatibility with Gforth and can also be executed using
a pre-generated eForth image running on a MUXLEQ machine.

The cross-compilation process functions as
outlined below:
1. Assembler: A specialized assembler for the MUXLEQ architecture enables
   low-level machine code generation tailored to the instruction set.
2. Virtual machine: Leveraging the MUXLEQ assembler, a virtual machine is
   constructed. This VM is capable of supporting higher-level programming
   constructs, facilitating the seamless execution of Forth code within the
   MUXLEQ environment.
3. Forth word definitions: These definitions are instrumental in building
   a full-fledged Forth interpreter, allowing for the creation, compilation,
   and execution of Forth programs.
4. Forth image: The finalized Forth image, encapsulating the interpreter and
   its environment, is output to the standard output stream. This image
   initializes the VM with the necessary configurations and word definitions to
   operate effectively.

"Meta-compilation" in Forth refers to a process similar to cross-compilation,
though the term carries a distinct meaning in the Forth community compared to
its use in broader computer science. This difference stems from Forth's
evolution within the microcomputer scene, which was separate from the academic
environment of the 1980s and earlier. The term "meta-compilation" may have been
somewhat mistranslated. While most modern programs employ unit testing
frameworks, here, a meta-compilation system serves as an extensive testing
mechanism. If the system compiles image "A," which can then compile another
image "B," and "B" matches "A" byte-for-byte, this gives reasonable confidence
that the image is correct, or at least correct enough for self-compilation.

This process is performed with the following commands:
```shell
$ gforth muxleq.fth > stage0.dec
$ sed 's/$/,/' stage0.dec > stage0.c
$ cc -o muxleq muxleq.c
$ ./muxleq < muxleq.fth > stage1.dec
$ diff -w stage0.dec stage1.dec
```

The `stage0.dec` image was initially generated using Gforth to create the first
functional eForth for the MUXLEQ machine. Once the eForth image is ready, it
serves as the meta-compiler, capable of compiling itself and generating
`stage1.dec`. The image generated by Gforth should be identical to the one
produced by MUXLEQ eForth when using the same `muxleq.fth` file. If the two
images are identical, the bootstrapping process is considered complete. Although
the Gforth interpreter is no longer required, it is retained because it is
significantly faster than using MUXLEQ eForth to compile a new image.

It is noteworthy that approximately half of the memory allocated is dedicated to
the virtual machine, which facilitates the writing and execution of Forth code.
The `BLOCK` word-set within this implementation does not interact directly with
mass storage. Instead, it maps blocks to memory, enabling efficient memory
management and access.

## License
This package is released under the Public Domain and was initially written
by [Richard James Howe](https://github.com/howerj).

## Reference
* [SUBLEQ EFORTH: Forth Metacompilation for a SUBLEQ Machine](https://www.amazon.com/dp/B0B5VZWXPL)
