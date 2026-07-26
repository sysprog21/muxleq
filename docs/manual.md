# MUXLEQ Reference Manual

MUXLEQ is a two-instruction esoteric machine -- SUBLEQ plus a multiplexing (MUX)
operation -- hosting a complete, self-hosting 16-bit eForth. This manual documents
the instruction set, the memory image, the build/bootstrap pipeline, the C
interpreter, and how to test and extend the system. It describes the actual
implementation in `muxleq.c` and `muxleq.fth`; when in doubt, the code wins.

## 1. Instruction set

Every instruction is three consecutive cells `a b c`. Cells are 16-bit
(`uint16_t`). The address space is 15-bit: `MEM_SIZE = 1<<15 = 32768` cells,
`MEM_MASK = 0x7FFF`. `NEGATIVE_FLAG = 0x8000` is the sign/branch marker, and
`IO_MARKER = 0xFFFF` (unsigned `-1`) tags memory-mapped I/O.

The interpreter classifies each instruction from its operands, in this order:

| Condition                                   | Operation |
|---------------------------------------------|-----------|
| `a == 0xFFFF`                               | input: read one byte into `m[b]` |
| `b == 0xFFFF`                               | output: write `m[a]` as one byte |
| `c` has bit 15 set and `c != 0xFFFF`        | MUX (see below) |
| otherwise                                   | SUBLEQ |

Execution halts when the program counter goes negative (bit 15 set), or on EOF
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

When `c` has bit 15 set but is not the I/O marker, the instruction multiplexes
instead of branching:

```
m[b] = (m[a] & ~m[mask]) | (m[b] & m[mask])   where mask = c & 0x7FFF
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

## 2. Memory image

The whole 32768-cell image is baked into the C binary at compile time (see the
build pipeline). The current image occupies ~6428 cells; the rest is working RAM
(stacks, buffers, dictionary growth). Key fixed locations near the base include
the zero register (`zreg`, address 6, the MUX zero-mask), the `-1`/`1` constants,
and the working registers `r0..r4`, followed by the dictionary and task blocks.
The authoritative layout lives in `muxleq.fth` (the `meta.1` variable
definitions); do not hardcode addresses against this manual.

Encoding conventions shared by `muxleq.c` and `muxleq.fth`:

- Addresses are 15-bit; `NEGATIVE_FLAG` on a `uint16_t` marks a branch/PC-halt.
- `IO_MARKER = -1`: `a==-1` reads input, `b==-1` writes output. A negative `c` is
  a branch target, so `SUBLEQ Z,Z,-1` (branch always taken) halts by moving the PC
  negative -- that is the `HALT` idiom, not a distinct opcode.
- MUX is encoded by setting `NEGATIVE_FLAG` in `c` (while `c != -1`).

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
muxleq.fth  --gforth-->  stage0.dec  --sed 's/$/,/'-->  stage0.c  --#include-->  m[] in muxleq.c
```

- `muxleq.fth` (~1700 lines) is a Gforth-hosted meta-compiler that assembles the
  full eForth -- dictionary, inner interpreter, block editor, multitasker -- into
  MUXLEQ cells. It runs under both Gforth (to build) and the target VM (to
  self-host). Feature toggles are the `opt.*` constants near the top.
- `stage0.dec` / `stage0.c` are generated -- never edit them. Change the language
  or image via `muxleq.fth`; change the interpreter via `muxleq.c`.
- `muxleq.c` (~290 lines) `#include`s `stage0.c` to initialize `m[]`.

### Self-hosting invariant

`make bootstrap` feeds `muxleq.fth` to the built VM and checks that the VM
reproduces `stage0.dec` byte-for-byte:

```
gforth muxleq.fth > stage0.dec        # Gforth builds the image
sed 's/$/,/' stage0.dec > stage0.c    # cells become a C initializer list
cc -o muxleq muxleq.c                 # stage0.c is #included into m[]
./muxleq < muxleq.fth > stage1.dec    # the VM re-builds the image
diff stage0.dec stage1.dec            # must be identical
```

(`make bootstrap` runs exactly this.)

This is the project's strongest correctness test: the VM runs the entire
meta-compiler under its own execution. Any change to `muxleq.fth` or `muxleq.c`
must keep it holding. Note that the meta-compiler assembles into a dump buffer it
never executes -- it compiles *threaded code* (data the inner interpreter reads),
not fresh instructions the VM runs -- which is what lets the interpreter reason
about the image ahead of time.

## 4. The interpreter (`muxleq.c`)

`muxleq.c` is a `musttail`-threaded interpreter, not a switch loop. `dispatch()`
classifies each `a b c` instruction and tail-calls `get` / `put` / `mux` /
`subleq`; each handler tail-calls the next via `FETCH_AND_DISPATCH`. It uses
`__attribute__((musttail))` when the compiler exposes that attribute (recent
Clang/GCC); without it the macro is empty and tail-call elimination is not
guaranteed.

### Fusion

On the no-branch path, `mux()` and `subleq()` peek at the next one or two
instructions and execute fused MOVE/SUBLEQ sequences inline, tuned to the
patterns the image emits. Fusion must be semantically identical to executing the
operations one at a time. If codegen in `muxleq.fth` changes, the fusion
assumptions in `muxleq.c` may need to move with it -- verify with `make check`.

## 5. Profiling

The VM takes optional flags (default runs are byte-identical, so the gates are
unaffected):

- `-s` -- instruction mix (GET/PUT/MUX/SUBLEQ) at dispatch entry.
- `-p` -- per-PC heat map with the top-16 hottest program counters.

For example, `./muxleq -s < tests/sqrt.fth` reports MUX dispatches at ~46%, and
`-p` shows the hottest PCs are the inner-interpreter NEXT loop (`iLOAD` then
`iJMP`, `muxleq.fth:369-373`) -- the target for macro-op fusion. The profiler's
dispatch counts are deterministic, unlike wall-clock timing.

## 6. eForth environment

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
- Numbers are 16-bit two's complement: `32767 1 +` wraps to `-32768`.
- Division is floored -- the sign of `mod` follows the divisor: `-7 2 /` = `-4`, `-7 2 mod` = `1`,
  `7 -2 /` = `-4`. Division by zero throws `-10`; catch it with `: d 1 0 / ;  ' d catch .` → `-10`.
- `um*` leaves the double result low-then-high; `.` prints top first, so
  `5 dup um* . .` prints `0 25` (high, low).
- The multitasker words (`pause`/`task:`/`activate`/`multi`/`single`/`send`/`receive`) live in
  the `system` vocabulary: run `system +order` first, or they read as undefined (`-13`).
  See `tests/tasker.fth`. This multitasker is COOPERATIVE and single-threaded: tasks run a
  round-robin and only switch at an explicit `pause`, so execution is deterministic. It is NOT
  ceForth's model -- there `task`/`start` create and schedule real host OS threads and `send`/`recv`
  pass messages between them (preemptive, with `clock`/`rank`/`lock`, backed by `std::thread` +
  condition variables), which a single-threaded OISC VM cannot match. So ceForth's `mtask`/`mpi`
  demos do not port as conformance goldens: `mtask` is a `clock`-timing benchmark
  (nondeterministic), and `mpi` relies on preemptive thread scheduling. muxleq's cooperative
  `pause`/`send`/`receive` is an analogous messaging capability with a different API and semantics
  (a single-slot mailbox, not ceForth's stack-copy queue).
- This eForth is fairly complete (~250 words: `case`, `marker`, `pick`, `within`, `nip`/`tuck`,
  `2dup`/`2drop`, `type`, `cmove`, `fill`, `allocate`/`free`, `catch`/`throw`, `um*`/`d+`, the
  pictured-output words `<# # #s #>`, …). Recent ceForth-conformance additions: `*/`/`*/mod`/`m*`,
  `.r`, `th` (array cell index), `octal`, `chars`, `spaces`, `2over`, `2swap`, `depth` (now in the
  forth vocab), and `value`/`to`. `to` is interpret-time only (it parses the next word from input,
  like ceForth's `to`): `5 to x` works at the REPL but `: foo 5 to x ;` does not -- the compiled
  `to` has no input to read. (A `value` is a mutable `constant`; `to` writes any such word's cell,
  with no value-vs-constant type guard, same as ceForth.) Still absent and read as undefined
  (`-13`); external programs may need adapting: `vocabulary`, `defer`, `s"` (no string literals),
  `[']` (use `'` at the REPL only -- it reads the input stream, so it can't fetch an xt inside a
  `:` definition), `roll` (needs recursion the metacompiler can't build), and the `#`/`%`/`'c'`
  number-literal prefixes.
  (`evaluate` IS present, but needs an addr/len string you must build yourself since `s"` is
  absent.)
  Number input: decimal by default; `$FF` or `hex … decimal` for hex. Use `[char] A` (not
  `'A'`) for a character constant.
- `." text"` outside a definition is fragile. Common error codes: `-4` (stack underflow),
  `-13` (undefined word / compile-only misuse), `-14` (execution/output error). More in
  `externals/subleq/CLAUDE.md`.

## 7. Testing

`make check` is the pre-commit gate: `make golden` byte-compares a suite of
deterministic programs against `tests/expected/*.out` (the VM must exit 0 and
match, each run `timeout`-bounded so a mis-fused infinite loop fails rather than
hangs), followed by `make bootstrap`. Regenerate goldens intentionally with
`make golden-update`. `tests/define.fth` is the runtime define-and-execute guard
(colon defs, `execute`, `does>`, `create`). `mandel` is manual-only (it does not
self-halt).

## 8. References

- README.md -- project overview and the MUX encoding.
- CLAUDE.md -- operational notes and build-pipeline warnings.
- externals/subleq -- the SUBLEQ ancestor (Richard James Howe) and a sibling
  optimizer (`subleq.c`) whose macro-op decode inspires §2 of the roadmap.
