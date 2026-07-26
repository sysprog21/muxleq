# Design note: eForth threading optimization (INLINE / STC) -- §5 Phase 2

This is the entry-gate design note for the one remaining perf lever (see TODO §2/§5). It is a
feasibility analysis, not an implementation spec -- enough to decide go/no-go and to know where
the real difficulty is before committing to a meta-compiler rewrite.

## The target

Measured (TODO §2, DONE.md): the inner-interpreter NEXT loop is ~39% of all executed MUXLEQ
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
`tests/chacha20.fth`. Profiled: chacha20 runs 400M fused dispatches, ~50M NEXT iterations, of
which ~14M are colon-word entries (`-p` heat map, PCs 164/173/179 vs the colon-enter tail). The
elidable share is the subset of those 14M that are leaf wrapper calls. So this optimization is an
APP speedup, not a self-host/headline speedup -- bench it on chacha20, not the self-host.

### Variant 1 (cheap, low-risk): wrapper-elision at runtime `compile,`

When runtime `compile,` (muxleq.fth:1022) is about to emit a reference to a word whose body is
exactly `[X][opExit]` (a one-word alias -- every `:to dup dup ;`-style wrapper), emit `X` instead.
No bytes are copied and nothing is relocated: `X` still references the primitive at its original
address, so the self-modifying operands stay put and work unchanged. This is the SAME transform
the metacompiler macros already perform and self-host -- just extended to runtime-compiled code.
It removes, per wrapper call, one colon-enter NEXT traversal + the `opExit` -- replacing 3 NEXT
cycles with 1. It speeds up runtime-compiled app/REPL code. Golden outputs are unchanged
(semantics identical), so the suite still gates it.

Bootstrap safety (corrected -- the earlier "path not hit" argument was wrong, per Codex): the
gforth build emits target image bodies via the `:m` macros / `t,` and never runs the target
`compile,`, so those bodies (e.g. `over`) are unaffected. The self-host DOES run the target
`compile,` -- it compiles muxleq.fth's own metacompiler tooling (`:m`, `:t`, the assembler words)
into the VM's WORKING dictionary while re-reading the source. But that tooling lives in working
RAM, not in the dumped target image, and the elision is semantically identical (same stack
effect, one fewer indirection). So `make bootstrap` should stay byte-exact -- but this MUST be
verified empirically, not asserted from the path being unreached.

CONSTANTS pinned for the implementation (from the metacompiler, 2026-07-18): `=unnest` (the
`opExit` reference that marks the alias tail) = 134; the `primitive` boundary = 308 (a ref `< 308`
is a primitive, `≥ 308` a colon word). Both are available at compile time as
`[ t' opExit half ] literal` and `[ primitive t@ ] literal`. These are HALVED token values --
compare them against the halved body cells `m[xt/2]`/`m[xt/2+1]`; if you ever compare doubled
code addresses instead, double the boundary too.

OPEN BLOCKER (why this is not yet implemented): the exact runtime cell representation
(xt → `2/` ref → body cells → boundary comparison) did not reconcile across REPL/`stage0.dec`
probes -- e.g. a wrapper body-cell read as 464 while the boundary is 308, which should be
impossible for a primitive-wrapper's first cell. `compile,` is the hottest compile path; a wrong
model there is silent miscompilation. The concrete first implementation step is to nail this
representation with authoritative instrumentation (the metacompiler's `to'` for target-only
words, or a VM-side `dump` of a known wrapper's cells) BEFORE touching `compile,`. Do not code
against the probe reads above until they reconcile.

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

1. NAIL THE REPRESENTATION FIRST (the open blocker). Instrument the metacompiler (`to'` for the
   target-only wrapper words) or add a throwaway VM-side `dump` to print, for `dup`/`drop`/`+`:
   the runtime xt, `xt 2/`, `m[xt/2]`, `m[xt/2+1]`, and confirm each equals `[primitive-ref][134]`
   with the primitive-ref `< 308`. Do not proceed until these reconcile -- the REPL/`stage0.dec`
   reads in this note did NOT (a body cell read as 464 against a 308 boundary), so the naive model
   is wrong somewhere and must be corrected before any `compile,` edit.
2. Implement the elision in runtime `compile,` (muxleq.fth:1022): if `m[xt/2] < [ primitive t@ ]`
   and `m[xt/2+1] == [ t' opExit half ]` and the word is not immediate, emit `m[xt/2]` instead of
   `xt 2/`. One conditional; no toggle needed (git is the A/B).
3. Validate: `make check` (goldens catch any output change) + `make bootstrap` MUST stay
   byte-exact (self-host uses macros, not this path, so it should be unaffected -- verify, don't
   assume). Then A/B chacha20's `-s` dispatch count with vs without the change.
Success criterion: chacha20 dispatch count drops measurably, all goldens byte-exact, bootstrap
holds. If it does, extend the alias set / consider transitive elision. If step 1 can't be made to
reconcile cleanly, or bootstrap breaks, stop -- the current interpreter is a sound stopping point
(TODO §2 go/no-go), and this note records exactly why.

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
