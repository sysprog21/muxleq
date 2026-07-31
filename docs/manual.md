# MUXLEQ Reference Manual

MUXLEQ is a minimalist esoteric machine -- SUBLEQ plus a multiplexing (MUX)
operation, and one native shift primitive reached through a reserved operand
encoding -- hosting a complete, self-hosting 32-bit eForth. This manual documents
the instruction set, the memory image, the build/bootstrap pipeline, the C
interpreter, and how to test and extend the system. It describes the actual
implementation in `muxleq.c` and the `forth/*.fth` modules; when in doubt, the
code wins.

Throughout, `muxleq.fth` names the generated `build/muxleq.fth`: the in-order
concatenation of the `forth/*.fth` source modules that Gforth and the VM
consume. Line numbers like `muxleq.fth:369` index that generated file; edit the
`forth/` modules, never the concatenation.

## 1. Instruction set

Every instruction is three consecutive cells `a b c`. Cells are 32-bit
(`uint32_t`). The architectural sign/branch bit is `0x80000000`, address bits
are `0x7fffffff`, and `IO_MARKER = 0xffffffff` (unsigned `-1`) tags
memory-mapped I/O.

The interpreter classifies each instruction from its operands, in this order:

| Condition                                   | Operation |
|---------------------------------------------|-----------|
| `a == 0xffffffff`                           | input: read one byte into `m[b]` |
| `b == 0xffffffff`                           | output: write `m[a]` as one byte |
| `c` has bit 31 set and `c != 0xffffffff`    | MUX, or a reserved-mask native op (see below) |
| otherwise                                   | SUBLEQ |

Execution halts when the program counter goes negative (bit 31 set), or on EOF
during input.

### SUBLEQ

```
r = m[b] - m[a]
m[b] = r
if r == 0 or r < 0:   pc = c        # branch taken
else:                 pc = pc + 3   # fall through
```

`SUBLEQ x, x, c` (a == b) always yields 0, so it zeroes `m[x]` and jumps to `c` --
the standard unconditional-jump idiom (with `x` a known-zero cell, `Z, Z, dest`).

### MUX

When `c` has bit 31 set but is not the I/O marker, the instruction multiplexes
instead of branching:

```
m[b] = (m[a] & ~m[mask]) | (m[b] & m[mask])   where mask = c & 0x7fffffff
pc = pc + 3
```

MUX is a *same-lane* bit selector: result bit *i* comes from bit *i* of `m[a]`
or `m[b]` according to bit *i* of the mask. With a zero mask it is a
single-instruction MOVE (`m[b] = m[a]`); it is the primitive from which boolean
logic is built, though a general AND/OR/XOR of two arbitrary values can take more
than one MUX (see README.md). It cannot move a bit across lanes, so it cannot
shift.

Cell address 6 is the zero register (`zreg`) and conventionally holds 0. A MUX
whose mask is address 6 (or any cell holding 0) selects every bit from `m[a]`,
i.e. a pure **MOVE** `m[b] = m[a]`; the interpreter fast-paths mask address 6 for
this reason. Single-instruction data movement is the feature that separates
MUXLEQ from pure SUBLEQ.

### Native shift escape

The core has no direct shift. MUX is same-lane, and SUBLEQ's carry propagates only
*upward* (so a left shift is just `m[b] += m[b]`); moving a bit the other way,
*down* a lane, is possible only through a bit-serial loop. One more mask value is
reserved to supply that directly. A MUX whose mask address is `0x7ffffffe` -- an
out-of-range value no real mask cell ever takes -- is dispatched as a native right
shift:

```
m[b] = m[a] >> 1
pc = pc + 3
```

The eForth `shift` word emits it instead of a bit-serial loop. The match is on the
raw `c` operand before any arena masking, exactly like the `0xffffffff` I/O
marker, so a genuine mask address (a small cell index) never collides with it, and
programs that use neither escape run as plain SUBLEQ+MUX.

This is the only such reservation, by design. A variable shift is a loop of these
right shifts (a barrel shift computes the same in one step, but adds no capability
the shift lacks), multiply is shift-and-add, divide is shift-and-subtract, and
byte access would bake a packing convention into a cell-addressed machine -- all
compositions or conventions that belong in the eForth software layer, not the ISA.
The rule for what may be added: a convention-free, value-only primitive the core
can otherwise reach only through a loop, filling a real directional gap. (A
comparison would not qualify -- SUBLEQ already subtracts and branches.)

## 2. Memory image

The image is baked into the C binary at compile time (see the build pipeline).
At startup the host allocates a power-of-two cell arena large enough for that
image, with room for stacks, buffers, and dictionary growth. Key fixed locations near the base include
the zero register (`zreg`, address 6, the MUX zero-mask), the `-1`/`1` constants,
and the working registers `r0..r4`, followed by the dictionary and task blocks.
The authoritative layout lives in `muxleq.fth` (the `meta.1` variable
definitions); do not hardcode addresses against this manual.

Encoding conventions shared by `muxleq.c` and `muxleq.fth`:

- Addresses use the low 31 bits; the high bit marks a branch/PC-halt.
- `IO_MARKER = -1`: `a==-1` reads input, `b==-1` writes output. A negative `c` is
  a branch target, so `SUBLEQ Z,Z,-1` (branch always taken) halts by moving the PC
  negative -- that is the `HALT` idiom, not a distinct opcode.
- MUX is encoded by setting the high bit in `c` (while `c != -1`).

### Self-modifying operands

The image implements all indirection by patching its own instruction operands at
runtime. The macros `iLOAD` / `iSTORE` / `iJMP` / `iADD` / `iSUB`
(`muxleq.fth:295-316`) each write an address into a *later* instruction's operand
cell and then execute it. Consequently:

- The memory image is not constant during execution -- operand *addresses* mutate.
- Any interpreter optimization must re-read operands live from `m[]` each time;
  it must never bake operand values, and it must not rewrite `m[]` to "optimize".
- The *class* of a cell (GET/PUT/MUX/SUBLEQ), however, is stable under this
  self-modification: only addresses change, never the class. This was verified
  across the self-host with zero reclassifications.

## 3. Build and bootstrap pipeline

```
forth/*.fth  --cat-->  build/muxleq.fth  --gforth-->  build/stage0.dec
    --sed 's/$/,/'-->  build/stage0.c  --#include-->  m[] in muxleq.c
```

- The language source is the numbered `forth/*.fth` modules, concatenated in
  order into the generated `build/muxleq.fth` -- a Gforth-hosted meta-compiler
  that assembles the full eForth (dictionary, inner interpreter, block editor,
  multitasker) into MUXLEQ cells. `build/muxleq.fth` runs under both Gforth (to
  build) and the target VM (to self-host). Feature toggles are the `opt.*`
  constants in `forth/00-config.fth`. Edit the modules; never the concatenation.
- Every generated artifact lives under `build/` (`build/muxleq.fth`,
  `build/stage0.dec` / `build/stage0.c`, the binaries)
  -- never edit them. Change the language via the `forth/` modules; change the
  interpreter via `muxleq.c`.
- `muxleq.c` `#include <stage0.c>` (resolved from `build/` by `-Ibuild`) to
  initialize the default image.

### Self-hosting invariant

`make bootstrap` feeds `build/muxleq.fth` to the built VM and checks that the VM
reproduces `build/stage0.dec` byte-for-byte:

```
sh scripts/update-muxleq-fth.sh build/muxleq.fth forth/*.fth  # concatenate modules
gforth build/muxleq.fth > build/stage0.dec        # Gforth builds the image
sed 's/$/,/' build/stage0.dec > build/stage0.c    # cells become a C init list
cc -Ibuild -o build/muxleq muxleq.c               # stage0.c #included
./build/muxleq < build/muxleq.fth > build/stage1.dec  # the VM re-builds the image
diff build/stage0.dec build/stage1.dec            # must be identical
```

(`make bootstrap` runs exactly this.)

This is the project's strongest correctness test: the VM runs the entire
meta-compiler under its own execution. Any change to the `forth/` modules or `muxleq.c`
must keep it holding. Note that the meta-compiler assembles into a dump buffer it
never executes -- it compiles *threaded code* (data the inner interpreter reads),
not fresh instructions the VM runs -- which is what lets the interpreter reason
about the image ahead of time.

## 4. The interpreter (`muxleq.c`)

`muxleq.c` is a wide VM loop. With no arguments it runs the baked 32-bit eForth
image. Given a `FILE` it loads a whitespace-delimited image and runs that
instead. Any option argument is rejected.

## 5. eForth environment

`muxleq.fth` builds a full eForth (~170 words). Feature toggles (the `opt.*`
constants) select the multitasker (`pause`, `task:`, `activate` in the `system`
vocabulary), block editor, extended control structures (`do`/`loop`, `case`),
dynamic allocation, glossary tools, enhanced `see`, and the hardware
division/modulo primitive. Each toggle builds and self-hosts on its own, except
that turning `opt.divmod` off makes the self-host impractically slow (software
division), so keep it on for bootstrap workflows.

### Programming gotchas

Each item below is a one-liner you can paste into `make run`.

- Compile-only words (`begin`/`until`/`while`/`repeat`/`if`/`then`/`for`/`next`) work only
  inside a `:` definition. A loop typed at the REPL throws `-14`; wrap it in a word:
  `3 for r@ . next` → `-14`, but `: cd 3 for r@ . next ; cd` → `3 2 1 0`.
- `for`/`next` is inclusive: `N for … next` runs the body N+1 times (`3 for` makes 4 passes,
  as the `3 2 1 0` above shows).
- Numbers are 32-bit two's complement: `2147483647 1 +` wraps to `-2147483648`.
- Division is floored -- the sign of `mod` follows the divisor: `-7 2 /` = `-4`, `-7 2 mod` = `1`,
  `7 -2 /` = `-4`. Division by zero throws `-10`; catch it with `: d 1 0 / ;  ' d catch .` → `-10`.
- `um*` leaves the double result low-then-high; `.` prints top first, so
  `5 dup um* . .` prints `0 25` (high, low).
- Shifts are LOGICAL, not arithmetic: `rshift` zero-fills the vacated high bits, and `2/` is
  defined as `1 rshift`, so `2/` does NOT sign-extend. `-2 2/` is `2147483647`, not `-1`;
  `$80000000 1 rshift` is `1073741824` (0x40000000), not 0xC0000000. For a signed
  (arithmetic) shift-right-by-1, sign-fill explicitly:
  `: asr1 dup 0< if 2/ $80000000 or else 2/ then ;` gives `-8 asr1` → `-4`.
- `case`/`of` parks the selector on the RETURN stack, not the data stack (`(case)` is
  `r> swap >r >r`). Each `of` compares against it via `r@`, and `endcase` drops it. Consequence: the
  DEFAULT arm (after the last `of`, before `endcase`) cannot `dup` the selector off the data stack --
  it isn't there. To use the selector's value in the default arm, recompute or re-fetch it from its
  source. This differs from the classic eForth `case` that leaves the selector on the data stack.
- The multitasker words (`pause`/`task:`/`activate`/`multi`/`single`/`send`/`receive`) live in
  the `system` vocabulary: run `system +order` first, or they read as undefined (`-13`).
  See `tests/tasker.fth`. This multitasker is COOPERATIVE and single-threaded: tasks run a
  round-robin and only switch at an explicit `pause`, so execution is deterministic. It is NOT a
  preemptive host-thread model -- a fuller Forth's `task`/`start` create and schedule real host OS
  threads and `send`/`recv` pass messages between them (preemptive, with `clock`/`rank`/`lock`,
  backed by `std::thread` + condition variables), which a single-threaded OISC VM cannot match. So
  preemptive-thread demos do not port as conformance goldens: a `clock`-timing benchmark is
  nondeterministic, and preemptive message passing relies on thread scheduling. muxleq's cooperative
  `pause`/`send`/`receive` is an analogous messaging capability with a different API and semantics
  (a single-slot mailbox, not a stack-copy queue).
- This eForth is fairly complete (~250 words: `case`, `marker`, `pick`, `within`, `nip`/`tuck`,
  `2dup`/`2drop`, `type`, `cmove`, `fill`, `allocate`/`free`, `catch`/`throw`, `um*`/`d+`, the
  pictured-output words `<# # #s #>`, …). Recent conformance additions: `*/`/`*/mod`/`m*`,
  `.r`, `th` (array cell index), `octal`, `chars`, `spaces`, `2over`, `2swap`, `depth` (now in the
  forth vocab), and `value`/`to`. `to` is interpret-time only (it parses the next word from input):
  `5 to x` works at the REPL but `: foo 5 to x ;` does not -- the compiled
  `to` has no input to read. (A `value` is a mutable `constant`; `to` writes any such word's cell,
  with no value-vs-constant type guard.) Still absent and read as undefined
  (`-13`); external programs may need adapting: `vocabulary`, `defer`, `s"` (no string literals),
  `[']` (use `'` at the REPL only -- it reads the input stream, so it can't fetch an xt inside a
  `:` definition), `roll` (needs recursion the metacompiler can't build), and the `#`/`%`/`'c'`
  number-literal prefixes.
  (`evaluate` IS present, but needs an addr/len string you must build yourself since `s"` is
  absent.)
  Number input: decimal by default; `$FF` or `hex … decimal` for hex. Use `[char] A` (not
  `'A'`) for a character constant.
- `." text"` outside a definition is fragile. Common error codes: `-4` (stack underflow),
  `-13` (undefined word / compile-only misuse), `-14` (execution/output error).

### Block editor

The editor (`opt.editor`, `forth/65-optional-editor.fth`, entered with `editor`) is a modal,
full-screen, vi-style editor over the block model -- the block buffer IS the file.
Normal mode: `hjkl` (or the arrow keys) move, `i` insert, `x` delete a character.
Colon commands:
`:w` saves (`update flush`), `:n`/`:p` step to the next/previous block, `:N` jumps
to block N (valid blocks are 1..127), `:z` blanks the current block, `:x` saves and
compiles (`load`) the block on exit, `:q` quits; `ZZ` also quits. The current block
number shows on the status line. It reads single keystrokes, so it needs an
interactive terminal (the VM puts a tty into raw mode; see the interpreter section).

A block is a fixed 1 KiB grid of 16 rows x 64 columns with NO newline concept.
What is implemented today:

- Cursor is `(x, y)` clamped to a constant `x 0..63`, `y 0..15` -- unlike a
  variable-length-line editor, there is no per-line length to clamp against.
- A row is always 64 cells, some of them spaces; trailing blanks are
  indistinguishable from typed spaces.
- `x` (delete char) shifts the row left from the cursor and blank-fills column 63.
- Insert (`i`) overwrites the cell at the cursor and advances, clamping at column
  63 -- a deliberately simple model; a true shift-right insert (dropping column
  63 on overflow) is a later refinement.
- `:w` maps to `update flush`; block selection (`:n`/`:p`/`:N`) clamps to 1..127;
  `ZZ`/`:q` exit.

Motions still to be added carry pinned conventions so they need no rework when
built: `0` to column 0, `$` to the last non-blank column (column 0 if the row is
blank), `^` to the first non-blank column; `dd` deletes a row (rows below shift
up, row 15 blank-fills) and `o`/`O` open a blank row (the row pushed off the
16-row grid is lost); `w`/`b` treat each row as one line, stepping over
whitespace-delimited words and crossing to the adjacent row at the 64-column edge.

## 6. Testing

`make check` is the pre-commit gate: `make golden` byte-compares a suite of
deterministic programs against `tests/expected/*.out` (the VM must exit 0 and
match, each run `timeout`-bounded so a mis-fused infinite loop fails rather than
hangs), then the PTY editor golden, 32-bit eForth smokes, and `make bootstrap`.
`make check-all` adds wide native-image fuzz, loader rejection, and ASan/UBSan.
Regenerate an expected file manually after an intentional, reviewed behavior
change. `tests/define.fth` is the runtime define-and-execute
guard (colon defs, `execute`, `does>`, `create`). `mandel` does not self-halt, so
its bounded prefix check is separate: `make golden-mandel`.

## 7. References

- README.md -- project overview and the MUX encoding.
- CLAUDE.md -- operational notes and build-pipeline warnings.
- docs/rvopt-native-muxleq.md -- the standalone RV32I-to-MUXLEQ compiler.
- The interpreter's runtime peek-ahead fusion is inspired by macro-op decoding of the
  SUBLEQ ancestor from which MUXLEQ descends.
