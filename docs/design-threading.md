# Design note: eForth interpreter performance

This note records the performance state of the self-hosting eForth interpreter
and the levers that remain. It is a feasibility summary, not an implementation
spec.

## Current status

The self-host bootstrap has been cut substantially from its starting point, and
there is still headroom. The inner interpreter is bound by memory latency, not
by instruction count, so the effective levers are the ones that reduce the
*number of primitive dispatches* on the hot path rather than the ones that shave
work inside a single dispatch. The hot path is dictionary search, and its cost
is dominated by kernel words that are threaded from many smaller words.

### The inner interpreter (NEXT)

NEXT is direct-threaded. A colon body is a list of one-cell tokens, and each
token is the target's address: for a primitive the token is its code address,
for a colon word its body address. NEXT reads the instruction pointer (a
register cell), reads the token it points to, and either jumps straight to it
(primitive) or nests into it (colon word). A traced dispatch confirms the jump
lands on the token itself (`pc == token`), so there is no second indirection to
remove -- direct-threaded code is already the representation, not an available
optimization.

Each executed word pays several MUXLEQ instructions of dispatch overhead, and
the dependent token fetch that drives NEXT is the critical path. That fetch is
what the levers below are judged against.

### The dispatch-count rule

Two changes look similar but are not. Shaving MUXLEQ instructions *inside* a
primitive that was already one dispatch does nothing: the per-dispatch cost is
dominated by the dependent token-fetch stall, so removing work that sits off
that path is a wash. Collapsing a colon word that costs *many* dispatches into a
single native primitive is different: it removes whole NEXT stalls, including the
nest/unnest return-stack traffic of every intermediate call. The first kind is a
wash; the second kind moves the clock. Every result below follows this rule.

### What has been done

Native shift. MUXLEQ has no shifter, so the `shift` primitive ran a bit-serial
loop that iterated once per cell bit. It was rewritten to a native VM
shift-right-by-one reached through a reserved MUX mask-address escape
(`0x7FFFFFFE`); see `muxleq.c` and `forth/20-target-vm.fth`. This is a
dispatch-count cut of the second kind -- it removed a branch-heavy threaded loop
from the single hottest path -- and it dropped the bootstrap by about 2.6x while
staying byte-exact.

Native cell fetch/store. `@` was the colon word `2/ 2/ [@]` and `!` was
`2/ 2/ [!]`; each `2/` is itself `#1 rshift`, so one `@` cost several nested
colon calls plus their return-stack traffic. Both were folded into single native
primitives (`op@`/`op!` in `forth/20-target-vm.fth`) that inline the byte-to-cell
shift into the load and store. Because the self-host runs its own metacompiler
tooling on these kernel words, the fold shortens the executing path, not just the
emitted image. Measured against a deterministic MUXLEQ-operation count (immune to
thermal drift), total operations fell from 10.30 billion to 8.85 billion, a 14.1%
reduction, and the bootstrap stays byte-exact.

Inlining those primitives. `@`/`!` were still colon words, so every use compiled
a call that nested, ran `op@`, and unnested -- three dispatches and return-stack
traffic where one would do. Once each body was a single primitive they qualified
for the same treatment the other hot primitives already get: a compile-time macro
(`:m @ op@`, `:m !  op!`) that inlines the op at every call site, with the word
header kept only for interpretation and `'`. This is pure inlining -- no new
instruction, and the token count is unchanged (`op@` in place of a call token) --
and it took total operations from 8.85 to 8.39 billion, 18.6% below the baseline.
The `see` golden was regenerated because `@`/`!` now decompile as the inline
primitive rather than a call.

The search inner loop. With the kernel primitives inlined, the largest remaining
cost is dictionary search: `(search)` walks a linked list of headers per source
token, and each candidate node read the node's name length with `count`, which
calls the multi-way `c@` colon word. But a header's name field is cell-aligned
(`thead` aligns it and prepends exactly one link cell), so the length byte is
simply the low byte of the name cell. Reading it as `nfa @` masked with `$9F` --
`@` being the now-inlined `op@` -- replaces the `c@` colon call on the hottest
loop in the metacompile, with no change to header format or behavior. Total
operations fell from 8.39 to 7.04 billion, 31.7% below the baseline, byte-exact.
This is real work removed, not just dispatch: wall-clock tracked it down from the
starting point, so it is not one of the latency-bound washes below.

The same loop then re-read the *search token's* length on every probe (`r@
count`), though the token is fixed while the chain is walked. Computing it once
into a hidden `stoklen` cell and reading it back with the inlined `@` removes the
second per-probe `c@` too. A scratch cell was used rather than the return stack
precisely to avoid the delicate rstack juggling a two-value hoist would need, so
the loop's stack discipline is unchanged. Total operations fell from 7.04 to 5.96
billion, 42.2% below the baseline, byte-exact.

With both byte reads gone, the remaining per-probe cost was the `compare` call
itself, which begins by re-checking the two lengths before touching any byte.
That check is now done inline in `(search)`: the node length is compared against
`stoklen` directly, and `compare` is called only when the lengths match. Since
most probes are length mismatches, the common path now skips the `compare` call
and its nest/unnest entirely. Total operations fell from 5.96 to 5.07 billion,
50.8% below the baseline, byte-exact.

`op@`/`op!` add no new VM instruction: they are reached through the existing
`SHR1` escape, so they cost nothing against the machine's identity. Inlining them,
and reading an aligned length with that same inlined `@`, add nothing either. That
is what keeps this whole line of work on the right side of minimalism, and what
separates it from the byte-op idea that was reverted.

### What was measured and rejected

Native byte fetch/store (rejected: convention in the ISA). `c@`/`c!` were the
largest remaining offenders -- multi-way colon words that reach the target byte
through an `rshift` of 8, 16, or 24, and `rshift` loops one `SHR1` per bit, so an
offset-3 byte cost up to 24 iterations; `c@` fires once per tokenized source
character. Folding them into two native byte ops (`CAT`/`CAS`) cut total
operations from 8.85 to 4.86 billion -- a big, real, byte-exact win. It was still
reverted, on a design ground rather than a correctness one. A byte load computes
`(m[v>>2] >> ((v&3)*8)) & 0xFF`: it hard-codes four-bytes-per-cell, little-endian,
byte-addressing-on-a-cell-machine -- a *software storage convention* pushed down
into the VM. That is categorically different from `SHR1`, which transforms a cell
*value* as pure arithmetic and encodes no layout. The boundary this fixes: the VM
ISA may gain only convention-free, value-arithmetic primitives that fill a gap the
same-lane MUX provably cannot express (shift is the archetype); byte packing,
strings, and anything that is a loop over those primitives (multiply, divide,
block moves) belong to the eForth software layer. The same rule rejects native
multiply/divide (already pure Forth; a loop over add/shift, no substrate gap) and
native block memory ops (O(N) work inside one instruction breaks the
bounded-step model).

Native indirect ops (a wash). The self-modifying `iLOAD`/`iSTORE`/`iJMP` idioms
were reimplemented as native reserved-mask escapes. The result was byte-exact and
correct but left the bootstrap unchanged. These primitives were already one
dispatch, so collapsing their internal MUXLEQ instructions removed work off the
critical path; the critical path is the dependent token-fetch load, which the
native form still performs. This is a dispatch-count cut of the first kind, and
the decisive evidence that the interpreter is memory-latency-bound rather than
dispatch-bound. The prototype was reverted.

By the same argument, a native NEXT op, a decoded-dispatch shadow, and software
prefetch are all predicted washes: none shortens the dependent token-fetch chain.

Metacompiler superinstructions (app scope, not self-host). Fusing hot adjacent
primitive pairs into single tokens through a metacompiler peephole reduces token
fetches in the *emitted* image, but the self-host executes its metacompiler
tooling from working RAM built by the kernel's runtime `compile,`, which a
metacompiler-side peephole never touches. The gain therefore lands on programs
that run the emitted image, not on the bootstrap itself. A runtime-`compile,`
wrapper-elision variant was measured net-negative. Neither is pursued.

### The floor, in numbers

The bottleneck is the dependent token fetch, and the image overflows L1D, so each
NEXT pays cache-miss latency the substrate cannot hide. The measured
operations-per-second sits well below the microbenchmark ceiling, and the gap is
stall on that fetch. Reducing dispatch count is the only thing that has moved it.

### Remaining lever

With both per-probe `c@` calls gone and the `compare` call skipped on length
mismatches, per-probe work is now down to an inlined `@`, a mask, and a length
subtract. Further per-probe savings would be marginal; what remains is the probe
*count*. `(search)` still walks one linear chain of every header; bucketing the
dictionary by name length would turn that into a walk of one short chain, and is
the biggest remaining payoff. But it changes header threading in both the
metacompiler (`thead`) and the runtime, which is structurally larger than anything
done so far. Memory is not the obstacle: the self-host runs in a fixed 65536-cell
arena (`MUX_MIN_CELLS`) and the image uses only about 6600 cells, so bucket tables
fit with room to spare. It is deferred for the threading-format change, not for
space.

What is deliberately not on the list is a native op to make `c@` itself O(1) --
say a general variable shift (`m[b] >>= m[a]`) so `rshift` stops looping. The
minimalism principle rejects it, and it is worth being precise about why. `SHR1`
earns its place as the atomic generator of the one capability the substrate lacks:
downward bit movement. Upward movement is already free (addition's carry
propagates low to high, so a left shift is just `dup +`); same-lane logic is MUX;
arithmetic and compare-branch are SUBLEQ. Nothing cheaply moves a bit *down* a
lane, so `SHR1` fills that gap -- and once it exists, a variable shift is simply N
of it, exactly as multiply is shift-add and divide is shift-subtract. A barrel
shift adds no capability; it is a composition over `SHR1`, the same category as
the native multiply/divide already rejected, and so it belongs to software. The
only thing that would justify building it is a pragmatic O(1)-vs-O(N) decision for
the large-application direction, where compiled C shifts by variable amounts
constantly -- a platform call driven by a real workload, not a minimalism-
sanctioned one.

## Keeping the self-host intact

Every change here alters the generated image, so each needs a fresh golden and
must keep the self-host bootstrap byte-exact (stage0 == stage1). That, plus the
golden suite, is the acceptance gate for any work in this area.
