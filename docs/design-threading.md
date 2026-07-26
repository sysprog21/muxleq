# Design note: eForth threading optimization (INLINE / STC)

> `muxleq.fth:N` line references index the generated `build/muxleq.fth` -- the
> in-order concatenation of the `forth/*.fth` source modules. Edit the modules,
> not the concatenation.

This is the entry-gate design note for the one remaining perf lever. It is a
feasibility analysis, not an implementation spec -- enough to decide go/no-go and to know where
the real difficulty is before committing to a meta-compiler rewrite.

## The target

Measured: the inner-interpreter NEXT loop is ~39% of all executed MUXLEQ
instructions on the self-host. NEXT is indirect-threaded: `r0 ip iLOAD` (= `m[m[ip]]`), then a
primitive/colon check, then either `iJMP` to the primitive or push-IP/set-IP for a colon word
(muxleq.fth:368-377). Every executed word pays ~6 MUXLEQ instructions of this overhead. The
prize is reclaiming that ~39%.

## How words are compiled today

- A colon body is a list of one-cell tokens. `compile, ( xt -- ) 2/ ,` (muxleq.fth:1022) emits
  each word reference as a single cell (the CFA, halved).
- NEXT derefs that cell twice (`m[m[ip]]`) to get the code address; below the `primitive`
  boundary (muxleq.fth:242,494) it is native code reached by `iJMP`, otherwise a colon body.
- A standalone primitive returns to NEXT (label `vm`, cell 164) via `;a` = `(fall-through);
  vm JMP` (muxleq.fth:379), or an explicit `vm JMP`, or by falling/jumping into another
  primitive's exit (e.g. `bye` muxleq.fth:345, `opEmit` :389, `opNext` :405, `opDivMod` :461).
  Whatever the form, inlining an op must omit its standalone dispatch/exit tail.

## INLINE -- two variants, and which regime each helps

There are two distinct things "INLINE" can mean here, and an investigation (below) shows the
cheap one is the right first step and the expensive one is what the earlier draft over-focused on.

### Finding: the win is regime-specific (measured, 2026-07-18)

The public words `dup`/`drop`/`swap`/`+`/… exist in TWO forms:
- The metacompiler macros `:m dup opDup ;m` (muxleq.fth:543-551): inside any metacompiled `:`
  definition, `dup` compiles the primitive `opDup` DIRECTLY -- no wrapper. Confirmed: `t' dup` in
  the metacompiler fails (garbage address) because `dup` there is the macro, not a target word.
- The public wrapper colon words `:to dup dup ;` (muxleq.fth:554-559): two cells
  `[primitive-ref][opExit]`, reachable only at VM runtime via the forth vocabulary.

Consequence: code built by the metacompiler -- which includes the ENTIRE self-host -- already
inlines primitives via the macros. So the measured ~39% NEXT overhead on the self-host will NOT
move from wrapper work; that figure is the irreducible cost of dispatching the primitive stream.
The wrapper round-trip is paid only by code compiled at VM runtime (apps, REPL) -- e.g.
`tests/chacha20.fth`. So this optimization is an APP speedup, not a self-host/headline speedup --
bench it on chacha20, not the self-host.

UPSIDE BOUND (measured 2026-07-19, `-s`/`-p` on the shipped build). chacha20 = 431.6M dispatches;
the NEXT/iLOAD machinery (top-4 hot PCs 744/729/738/750) ≈ 200M = 46%; `opExit` (cell 873) runs
11.77M times = the total colon-word RETURN count. Wrapper-elision removes ~2 NEXT iterations per
elided leaf-wrapper call (the note's "3 NEXT cycles → 1"). Elidable calls are the leaf
single-primitive-wrapper subset of those 11.77M returns -- and that subset is NOT measurable from
the PC heat map, because the OISC substrate is oblivious to eForth's threading structure (wrapper
bodies are `iLOAD`-read DATA, not executed PCs). So the honest figure is a BOUND, not a point:
the absolute ceiling (if EVERY colon call were a leaf wrapper) is 2 × 11.77M ≈ 23.5M fewer NEXT
iterations, i.e. ~44% of the ~53.8M NEXT iterations; using the top-4 NEXT PCs (~200M) as the
dispatch-cost proxy, that is ~87M fewer dispatched MUXLEQ instructions, or ~20% of the 431.6M
dispatches -- but chacha20 is compound-word-heavy
(its own crypto routines), so the realized figure is materially lower and app-specific. Pinning it
exactly needs eForth-aware instrumentation (a throwaway counter in the colon-enter path that tests
`body == [prim<boundary][opExit]`), which the substrate can't cheaply provide. NET for the go/no-go:
the ceiling is real and non-trivial for wrapper-heavy runtime-compiled code (up to ~1/5 of
dispatches), but it is APP-ONLY (self-host unaffected) and unproven below that loose ceiling -- so
the decision stays a risk-appetite call (a bounded app-compile win vs. editing the hottest compile
path), not an obvious yes.

### Variant 1 (cheap, low-risk): wrapper-elision at runtime `compile,`

When runtime `compile,` (muxleq.fth:1022) is about to emit a reference to a word whose body is
exactly `[X][opExit]` (a one-word alias -- every `:to dup dup ;`-style wrapper), emit `X` instead.
No bytes are copied and nothing is relocated: `X` still references the primitive at its original
address, so the self-modifying operands stay put and work unchanged. This is the SAME transform
the metacompiler macros already perform and self-host -- just extended to runtime-compiled code.
It removes, per wrapper call, one colon-enter NEXT traversal + the `opExit` -- replacing 3 NEXT
cycles with 1. It speeds up runtime-compiled app/REPL code. Golden outputs are unchanged
(semantics identical), so the suite still gates it.

Bootstrap safety (corrected -- the earlier "path not hit" argument was wrong): the
gforth build emits target image bodies via the `:m` macros / `t,` and never runs the target
`compile,`, so those bodies (e.g. `over`) are unaffected. The self-host DOES run the target
`compile,` -- it compiles muxleq.fth's own metacompiler tooling (`:m`, `:t`, the assembler words)
into the VM's WORKING dictionary while re-reading the source. But that tooling lives in working
RAM, not in the dumped target image, and the elision is semantically identical (same stack
effect, one fewer indirection). So `make bootstrap` should stay byte-exact -- but this MUST be
verified empirically, not asserted from the path being unreached.

CONSTANTS -- use the LIVE compile-time expressions, never hardcode. The alias tail is
`[ t' opExit half ] literal` (the `opExit`/`=unnest` reference) and the boundary is
`[ primitive t@ ] literal` (a ref `<` boundary is a primitive, `≥` a colon word). Both are HALVED
token values -- compare them against the halved body cells `m[xt/2]`/`m[xt/2+1]`; if you ever
compare doubled code addresses instead, double the boundary too. WARNING: do NOT bake the numeric
values. The boundary is `there 2/` captured after the assembler-layer primitives (muxleq.fth:1120),
so it shifts as earlier-emitted image content grows; `opExit`'s ref shifts too if anything before it
moves. An earlier draft pinned `=unnest`=134 / boundary=308 from the ~6555-cell image (2026-07-18);
those are now stale -- the `opExit` tail currently reads 873 and the boundary sits above ~1029.
Whether `opExit`'s own address drifted or 134 was mis-captured, the lesson is identical: use the
live compile-time expressions, never a hardcoded number. That stale mismatch is exactly what made
the naive reconciliation "impossible" (see RESOLVED below).

RESOLVED (2026-07-19, empirical): the representation is nailed and the model is confirmed. The
public wrapper `dup`/`drop`/`swap`/`+` bodies ARE `[primitive-ref][opExit-ref]` -- measured runtime
cells: dup `[786,873]`, drop `[828,873]`, swap `[768,873]`, + `[1029,873]`. cell1 is IDENTICALLY 873
(the shared `opExit` tail) and cell0 varies per word (the primitive), each `<` the current boundary.
The earlier "464 vs 308 impossible" alarm was purely the stale-constant drift above -- the model was
never wrong, the pinned numbers were. The elision test is therefore exactly the VM's own primitive
check that `see` already implements at `muxleq.fth:1886` (`cell < [ primitive ] @ → VM primitive`),
PLUS `cell1 == [ t' opExit half ]`. Verified it discriminates correctly: `see +` → `VM 2058`
(one-primitive wrapper, matches), while `see 2dup` → `over over` and `see negate` → `1- invert`
(multi-op colon words: cell0 ≥ boundary, and even a `[prim][prim]` word has cell1 ≠ opExit, so both
are correctly EXCLUDED). Net: step 1 of the bounded prototype is done -- the "we don't understand the
cell layout" blocker is gone; only the `compile,` edit itself (step 2, gated) remains.

### Variant 2 (expensive): copy a multi-instruction primitive body inline

Only needed to inline primitives that are more than a single dispatch (not required for the
wrapper-elision win above). THE OBSTACLE (non-obvious, and the reason this is not a memcpy):
MUXLEQ primitives self-modify
their own operand cells to do indirection, and the macros that emit them (`iLOAD`/`iSTORE`/
`iJMP`, muxleq.fth:295-316) compute their patch targets with `there`-relative addressing -- i.e.
absolute cell addresses fixed at the primitive's ORIGINAL location. A plain (memcpy)
copy of a primitive's compiled cells to a call site would leave those targets pointing back at
the original, so the inlined copy would patch the wrong cell. You cannot inline by *plain* copy --
either re-assemble the op, or copy and relocate every internal self-reference by the copy offset.

Two ways out:
- (a) Re-assemble, don't copy. Keep the inlinable word's definition as its assembler macro and
  have the compiler re-run that macro at each call site, so `there` resolves correctly for the
  copy. Clean, but requires the primitive set to be structured as re-invocable macros and the
  cross-compiler to invoke them mid-colon-definition.
- (b) Copy + relocate: copy the cells and fix up every internal `there`-relative operand target
  by the copy offset. Fragile -- you must know exactly which operands are self-references. Not
  recommended.
If Variant 2 is ever pursued, approach (a) is preferred over (b). It also naturally strips the
trailing `vm JMP` (the macro is the op's body; the `;a` exit is added only for standalone
primitives, not for the inline expansion). But note Variant 1 (wrapper-elision) captures the
realistic app win without any of this -- start there.

Scope the first cut to straight-line one-word aliases only. Do NOT elide/inline immediate words
or control-flow words: target control words patch token operands at compile time
(muxleq.fth:1141) and `create`/`does>` rewrites CFAs (muxleq.fth:1156); rewriting a reference to
those would corrupt the offsets they depend on. The wrapper-elision test (`body == [X][opExit]`
with `X < primitive` boundary and not immediate) excludes them structurally.

## STC -- murkier on this machine; not the first step

Classic STC (compile words to native CALL/RET, using the host's return-address stack) assumes a
machine with CALL/RET. MUXLEQ has neither. A "call" here is push-return-address + `iJMP`; a
"return" is pop + `iJMP` -- roughly the same ~6 instructions NEXT already spends. So full STC on
a call-less OISC does NOT obviously beat ITC the way it does on real hardware; its whole premise
(the host RAS) is absent. INLINE captures most of the realistic win with far less risk. Do
INLINE first; revisit STC only if INLINE measurements justify it.

## Bounded prototype (the go/no-go experiment)

Do Variant 1 (wrapper-elision), not Variant 2. Concrete steps, in order:

1. NAIL THE REPRESENTATION FIRST -- DONE (2026-07-19, see RESOLVED above). Confirmed via `'`/`@`
   probes and `see`: wrapper bodies are `[primitive-ref][opExit-ref]` with cell0 `<` the live
   `[ primitive ] @` boundary and cell1 `== [ t' opExit half ]` (currently 873; do NOT hardcode).
   `see` at `muxleq.fth:1886` already implements the primitive half of the test. Discrimination
   verified (`+` matches; `2dup`/`negate` correctly excluded). The blocker is cleared.
2. Implement the elision in runtime `compile,` (muxleq.fth:1022): if `m[xt/2] < [ primitive t@ ]`
   and `m[xt/2+1] == [ t' opExit half ]` and the word is not immediate, emit `m[xt/2]` instead of
   `xt 2/`. One conditional; no toggle needed (git is the A/B).
3. Validate: `make check` (goldens catch any output change) + `make bootstrap` MUST stay
   byte-exact (self-host uses macros, not this path, so it should be unaffected -- verify, don't
   assume). Then A/B chacha20's `-s` dispatch count with vs without the change.
Success criterion: chacha20 dispatch count drops measurably, all goldens byte-exact, bootstrap
holds. If it does, extend the alias set / consider transitive elision. If step 1 can't be made to
reconcile cleanly, or bootstrap breaks, stop -- the current interpreter is a sound stopping point,
and this note records exactly why.

## PROTOTYPE RUN -- result: NO-GO (measured 2026-07-19)

Step 2 was implemented and measured as a reversible experiment (reverted, not committed). The
elision in `compile,` is `dup @ [ primitive ] literal @ u<  over [ 2 ] literal + @ [ =unnest ]
literal =  and  if @ , exit then  2/ , ;` (metacompiler-layer notes: at compile,'s definition
point `else` and bare integer literals are NOT yet available -- use `if … exit then` and
`[ 2 ] literal`; the opExit ref is the existing `[ =unnest ] literal`, not a raw `t'` expression).

Results:
- CORRECT: the elision fires -- `: foo dup ;` compiles `foo`'s body cell0 = 786 (the dup PRIMITIVE),
  not 5011 (the dup wrapper). All 46 computational goldens (incl. `define` -- the runtime-compile
  guard -- `chacha20`, and every `rv32i` test) stay byte-exact. Only the address-dependent `editor`
  memory-dump golden shifts (expected image-layout drift, would just need a rebaseline).
- BOOTSTRAP HOLDS byte-exact. Note: the self-host DOES run target `compile,` for its
  working-dictionary tooling; what stays byte-exact is the DUMPED image (emitted via macros/`t,`),
  so bootstrap is unaffected either way.
- BUT IT DOES NOT HELP: chacha20 dispatches went UP, 431,633,095 → 432,883,904 (+0.29%), not down.

Why (consistent with the interpreter analysis): the C fusion (muxleq.c:185) is NOT wrapper-aware --
it fuses specific 2–3-instruction no-branch MUX/SUBLEQ adjacencies produced by the NEXT/primitive/
exit stream. Two things then combine: (a) that fusion already collapses most of the wrapper/NEXT
round-trip at runtime (the shipped fused build reduces DTC to ~2-3%), so elision has almost no
headroom left to recover; and
(b) the elided single-cell primitive ref CHANGES the instruction adjacency, so it loses some fusion
hits the wrapper stream was getting -- net slightly negative. The theoretical ~20% ceiling assumed
the wrapper cost was unrecovered; on the fused interpreter it already is. So Variant 1 is a measured
net-negative on the representative app, on top of being app-only and touching the hottest compile
path. DECISION: NO-GO. Leave the interpreter as-is; this note records the prototype and its numbers
so it need not be re-run. (STC/Variant 2 are strictly larger and riskier with no better prospect,
since they attack the same already-fused overhead.)

Caveat: chacha20 is the heavy runtime-compiled app benchmark and representative for this
app-only go/no-go, but it may underrepresent a wrapper-heavy REPL / tiny-word workload. If such a
workload ever becomes a target, a single synthetic "wrapper-storm" benchmark would be the way to
reopen this -- but nothing today needs it, so it stays NO-GO.

## Risks

- Miscompilation on the hot path: `compile,` compiles every runtime word reference. A wrong
  wrapper-detection test silently corrupts all runtime-compiled programs. This is why step 1
  (nail the representation) gates everything; the golden suite catches output changes but the
  debug cost is high.
- Bootstrap: `compile,` is a target word, so its own bytes shift in the image -- the VM rebuild
  must still reproduce them. Self-host compiles via macros, not this path, so it SHOULD be
  unaffected; verify with `make bootstrap`, do not assume.
- Scope creep to Variant 2: wrapper-elision needs NO body copy and NO operand relocation. Only
  the (unneeded-for-now) multi-instruction inline hits the self-modifying-operand problem.
- The golden suite (19 goldens + bootstrap, incl. define/does>/tasker/except/heap) is the safety
  net; every step must keep it byte-exact.
