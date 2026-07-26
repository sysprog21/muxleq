# rvopt native-MUXLEQ emission

> `muxleq.fth:N` line references index the generated `build/muxleq.fth` -- the
> in-order concatenation of the `forth/*.fth` source modules. Edit the modules,
> not the concatenation.

Status: IMPLEMENTED. Native emission lowers an RV32I program to a standalone MUXLEQ image that runs on the two ops directly, with no eForth vm layer, so it is the only path faster than the -r interpreter. It is now built and mature. The design content below (image layout, 32-bit macros, per-op lowering)
is the as-built architecture; the staged slices and open questions it closes with were all resolved in
implementation. The commit history records every measured optimization and the open frontier.

## As-built summary (what rvopt does today)

`rvopt` (a standalone 3810-line C compiler, zero image cells) turns an RV32I ELF32 / flat binary into a
graph IR (flat `struct node` array: linear decode + intra-block value/def-use edges + a memory-order
chain) and emits one of:

- `rvopt -mux prog` -- a standalone 16-bit-cell MUXLEQ image (`.dec`, decimal cells like `stage0.dec`) run
  by `./build/muxleq -x`. The payoff path: runs on the two ops + fusion directly, no eForth/`vm`/`rvstep`. A whole
  32-bit register is a lo/hi cell pair, so arithmetic is 2-cell macros (carry/borrow votes, bit15 sign).
- `rvopt -mux32 prog` -- a standalone 32-bit-cell WIDE image run by `./build/muxleq -x32` (a separate 2M-cell
  runner, `NEG_FLAG = 1<<31`). A whole register is ONE cell, so the ALU is native single-cell SUBLEQ/MUX (no
  lo/hi halves, no carry/borrow votes -- only the compares sign-flip at bit31); and the address space is not
  capped at the 15-bit / 32768-cell wall, so large-`.data` programs the 16-bit image cannot hold now run.
- "rvopt -dump" / "-check": textual IR round-trip for the folder and decode passes.

Op coverage is COMPLETE for the rv32ui base set (ADD/SUB/SLT[U]/AND/OR/XOR + immediates, all shifts,
LUI/AUIPC, all branches, JAL, computed/linking JALR, LB/LH/LHU/LW/SB/SH/SW, ecall write/exit).

Optimizations landed, each byte-identical vs `-r` and measured: the MUX-MAJ dispatch collapse
(add/sub carry, ltu16 compare, bit15 test -- the big `-s` wins, crc16 -35% / fibonacci -32% vs the naive
v0), SW high-byte/address-share, a const-OPIMM + mv-copy constant folder, and store-to-load forwarding
(redundant same-block reloads → register copies; unopt -7.7%). def-use lists are built (shown in `-dump`)
for later passes; the current folder and forwarding use their own cprop / memory-chain walks, not the
def-use arrays. Self-modifying guest code is DETECTED and cleanly REJECTED (the constant-target case);
running SMC (hybrid deopt) is deferred until a real SMC program appears.

Compliance (`make verify-riscv-tests`): the 16-bit `-mux`/`-x` path is 39/40 rv32ui -- its one skip is
ld_st, whose large `.data` needs ~76k cells to emit and so overflows the 32768-cell 16-bit image (rvopt
aborts before emit: "image needs N cells (> 32768)"). The wide `-mux32`/`-x32` path is 40/40, INCLUDING
ld_st (~188k cells): the 2M-cell runner holds it, so the wider-address VM that docs/design-wider-vm.md
scoped is now built and closes the last compliance skip. Both paths reject self-modifying code (detect_smc)
rather than miscompile it (`-mux32` only lowers a JALR whose target cprop resolves statically -- a
runtime-computed JALR is a clean hard error, not silent). Correctness net: differential vs `-r` (the
SMC-correct, live-fetching oracle)
plus a bounded randomized differential fuzzer (`scripts/rvopt-fuzz.py`, straight-line and bounded loops
across the op paths; `--wide` fuzzes `-mux32` too), all run under ASan/UBSan via `make sanitize` -- which now
also sanitizes the `-x`/`-x32` runners, not just the `-r` interpreter.

The design sections below (image layout `< 32768`, the lo/hi 2-cell 32-bit macros, per-op lowering) describe
the 16-bit `-mux` backend, which is where the layout constraints and the optimizer passes live. The wide
`-mux32` backend mirrors the same structure with a ONE-cell register file and a 2M-cell layout, replacing
every 2-cell lo/hi/carry macro with a native single-cell op, built slice by slice.

## Goal and the one idea that makes it win

Emit a **standalone MUXLEQ image** -- not Forth -- that the VM runs directly on its `dispatch()` loop (the two
ops + fusion), with NO eForth, no `vm`, no `rvstep`. That is why it can beat `-r`: `-r` pays ~6.5 `vm`
dispatches per guest instruction (each a heavy microcode call); native code pays only the MUXLEQ cells its
own logic needs, dispatched by the same tight C loop that runs eForth today.

The emitted image is a complete OISC program: it sets up guest registers as cells, runs the translated
logic, emits output via `PUT` (`b == -1`), and halts by branching negative (`c == -1`). It never touches
the eForth image.

## Contract

```
rvopt -mux prog.elf > prog.dec     # emit a standalone MUXLEQ image (decimal cells, like stage0.dec)
./build/muxleq -x prog.dec               # load prog.dec into m[], run from pc 0
```

- `.dec` format = one decimal cell per line (exactly `stage0.dec`'s format; human-inspectable, reuses the
  existing tooling mental model). A binary form can come later if `.dec` parsing is measurably slow.
- New VM flag `-x FILE` (small, ~15 lines in `muxleq.c:main`): read the `.dec` into `m[]` (overwriting the
  baked eForth image), zero the rest, then run the existing `dispatch(0, m[0..2])`. No other VM change; the
  GET/PUT/MUX/SUBLEQ/halt semantics and fusion are exactly as today. `-x` parses UNTRUSTED input, so it MUST
  bounds-check like the `-r` loader (muxleq.c:494): reject an image with more than `MEM_SIZE` (32768) cells
  and each cell to a 16-bit value -- never truncate, wrap, or partially load. Signed decimal is fine
  (`stage0.dec` already emits `-1` etc.).
- rvopt assigns every address at emit time (it lays out registers + code + data), so there is NO runtime
  relocation and NO runtime assembler -- the two blockers that ruled out native emission for milestone 2
  dissolve because rvopt, not the VM, does the layout.

## Image layout (rvopt-assigned absolute cell addresses, all < 32768)

ONE allocator with reserved, non-overlapping ranges assigns every cell (entry code, address 6,
constants, and the regfile can otherwise collide). Address-6 subtlety: the VM treats MUX *mask
address* 6 as zero regardless of `m[6]` (muxleq.c:189) -- so a MOVE is `c = 0x8006` (NEGATIVE_FLAG | 6), and
`m[6]` is NOT a general zero cell for SUBLEQ arithmetic; use a SEPARATE constant-zero cell. Slice 2 (built)
showed a `c=0x8006` MOVE is a copy for ANY src/dst regardless of what m[6] holds (the VM hardwires
mask-address 6 to zero) -- so NO low-cell reservation and NO jump-over prologue are needed: code can start
at cell 0 and the low code cells (incl. cell 6) are just ordinary operands. Only genuine SUBLEQ-zero /
constant needs are placed in the data region.

```
0            entry: the first real instruction (VM starts here; no prologue needed once regs zero-fill)
code         one MUXLEQ macro sequence per basic block (reuse rvopt's leaders/enders decomposition)
data:                (everything below sits AFTER the code, addresses assigned by the one allocator)
constants    a zero cell (SUBLEQ / halt), a -1 cell, the immediate + shared constant pool (0,1,-1,4,32,...)
prologue     when needed (control flow / sp): only sp (x2) is nonzero (guest-stack top); rest 0 by fill.
regfile      x0..x31 as 32 * 2 cells (lo,hi) = 64 cells. 32-bit two-cell storage is REQUIRED for
             byte-identical output (crc16/bgcd/bsort use full 32-bit; a 16-bit-only slice proves almost
             nothing). x0 is a read-only zero pair (or fold x0 reads to the constant-zero cell at emit
             time -- decide in slice 2).
scratch      per-block temporaries (add carry/borrow, compare results, shift accumulators)
guest RAM    the RV program's .rodata/.bss at a fixed cell base; guest byte addr A -> cell base+A/2,
             sub-cell byte via MUX/shift (same idea as the interpreter's rvg@/rvgbyte, muxleq.fth:2338).
             Loads/stores with a computed address use SMC: patch a later MUXLEQ operand cell then execute
             it (exactly how the image already does iLOAD/iSTORE, muxleq.fth:364-368). A patched operand is
             an alias barrier and MUST be re-read live -- the same self-modifying-operand invariant the
             interpreter honors; the emitter must never bake a patched operand into a decoded/fused view.
code         one MUXLEQ macro sequence per basic block (reuse rvopt's leaders/enders decomposition),
             blocks chained by native MUXLEQ branches; guest branch targets -> emitted block addresses.
```

Size budget: RV32I→MUXLEQ is ~15x code size, but native code lives in `m[]` like guest RAM does -- it does
NOT go through the self-host bootstrap, so the ~2200-cell self-host headroom does NOT constrain it. The
wall is the 15-bit address space (32768 cells). hello (~50 instrs → ~1-2k cells) fits trivially; the
compute demos (a few hundred instrs) fit; DureMark (~4.5 KB guest) likely does not and is out of v0 scope.

## Per-op lowering (the implementation bulk, staged)

- ALU reg/imm (ADD/SUB/AND/OR/XOR/SLT/shifts): 32-bit two-cell arithmetic. ADD = negate+SUBLEQ with a
  cross-cell carry; AND/OR/XOR = native MUX (`lower MUX to native AND/OR/XOR`, the standing design fact),
  NOT SUBLEQ bit loops; shifts = the interpreter's proven shift approach or a small unrolled sequence.
- LUI/AUIPC: constant / pc+imm into a reg pair (pc is a compile-time constant per instruction -- no runtime
  PC needed).
- Branches (BEQ/BNE/BLT[U]/BGE[U]): compute the compare into a scratch cell, then a native MUXLEQ branch
  (SUBLEQ's `c`) to the taken block or fall through. This is branchless-friendly but branches are native
  and cheap here.
- JAL: set link (pc+4 const) into rd + branch to the target block (direct, target known at emit time).
- JALR (as-built): a general JALR cannot "branch to the block whose address matches" without a runtime
  return-dispatch table. Two static forms ARE handled, and cover all of rv32ui + the demos: (1) a
  STATIC-TARGET JALR whose `rs1` cprop resolves to a compile-time address (`resolve_jalr` records the
  target node, like a JAL) -- emit a direct jump to that block plus the pc+4 link if rd != 0; (2) the
  `jalr x0,x1,0` return form (print_dec `ret`) -- a single reachable `jal ra` call site whose return
  address is checked against the stored value, then jump to the block after the call. Anything else (a
  runtime-computed non-ret JALR, or a `ret` with more than one call site) is a clean hard error, not a
  silent miscompile; it is deferred until a real program needs the runtime dispatch.
- LOAD/STORE: address = reg+imm; SMC-patch the operand of a MOVE/SUBLEQ to that cell, execute; byte/half
  via MUX/shift + the alignment rules the microcode already enforces.
- ecall: write(64) = a loop emitting a2 guest bytes from [a1] via `PUT`; exit(93) = branch negative (halt).

## Macro design: 32-bit compare + arithmetic (slice 3b/3c, PRE-CODE -- verify me)

All registers are (lo,hi) 16-bit cell pairs. Constants in the data region: `Z`=0, `ONE`=1,
`NEG1`/`ONES`=0xFFFF (=-1, also all-ones), `SGN`=0x8000. Per-block scratch temps `T0,T1,...` plus BT/D/V
for the compare/arithmetic macros. A "non-branching" SUBLEQ `(a,b,next)` sets b-=a and
always continues to `next` (the next native cell) whether or not it branches. MOVE = `(a,b,32774)`.
AND/OR verified empirically (MUX): `rd=rs1&rs2` = MOVE rs1->rd; `MUX(Z, rd, 0x8000|rs2)`; `rd=rs1|rs2` =
MOVE rs2->rd; `MUX(rs1, rd, 0x8000|rs2)`. XOR = (rs1&~rs2)|(~rs1&rs2), 2 MUX + an OR per half (or
`~x = ONES - x` since ONES is all-ones and x<=0xFFFF borrows nothing).

FOUNDATION FACT (corrects a first-draft error): SUBLEQ's branch test is `result==0
|| bit15(result)`, i.e. the 16-bit difference `a-b` interpreted as SIGNED <= 0 -- NOT unsigned a<=b (e.g.
`0-0x8001=0x7FFF`, no branch, yet 0<=0x8001 unsigned). So the SUBLEQ branch primitive is SLE0 =
"if (a-b) signed <= 0 goto L" = MOVE(a->T); `SUBLEQ(b,T,L)`. Unconditional JMP = `SUBLEQ(Z,Z,L)`.

16-bit EQUALITY (from SLE0 + an add-1 re-test): two signed SLE0 tests are WRONG -- `a-b == 0x8000` makes
BOTH `a-b` and `b-a` read as signed<=0. Instead, once SLE0 proves `a-b <= 0` and leaves it
in T, add 1 (`SUBLEQ` of a -1 cell): `(a-b)+1 <= 0` iff `a-b < 0` (a!=b), `> 0` iff `a-b == 0` (a==b).
`EQ16(a,b,L)` = `SLE0(a,b,C); JMP NE; C: SUBLEQ(NEG1,T,NE); JMP L; NE:` (5 insn). `NE16` = `SLE0(a,b,C);
JMP L; C: SUBLEQ(NEG1,T,L)` (4 insn, fall-through = equal). Verified: EQ16(0x8000,0)='not equal',
EQ16(5,5)='equal'. Needs a NEG1 (=-1=0xFFFF) constant cell in the layout.

16-bit UNSIGNED `a<b` (concrete impl for slice 3b-2/3c -- VERIFY ME). Two primitives:
- BIT15C(x,L) = "branch to L if bit15(x) is CLEAR" (4 insn): `MOVE(x->BT); MUX(Z,BT,SGN); DEC(BT);
  SUBLEQ(Z,BT,L)`. The MUX isolates bit15 (BT = x&0x8000 = 0 or 0x8000); DEC (SUBLEQ of a `1` cell) makes
  it -1 or 0x7FFF; `SUBLEQ(Z,BT,L)` branches when BT signed<=0, i.e. bit15 CLEAR. This is the RVBIT15 trick
  (muxleq.fth:574); it dodges the 0x7FFF overflow a naive `x+1<=0` sign test hits. INC = `SUBLEQ(NEG1,b,.)`.
- LTU16(a,b,L) via a VOTE COUNTER V (matches rvsltu.sub, muxleq.fth:679; majority exhaustively verified):
  `d=a-b`; `V=0`; `+= !bit15(a)`; `+= bit15(b)`; `+= bit15(d)`; branch to L iff V>=2. Each vote uses BIT15C
  (branch-past the INC when the wanted bit polarity fails). `V>=2` test: `DEC(V); SUBLEQ(Z,V,NOTMAJ);
  JMP L; NOTMAJ:` (after DEC, V>0 iff V was >=2; SUBLEQ branches on <=0 to NOTMAJ). ~22 insn. `a>b`=LTU16(b,a).
  Needs constants Z(0), ONE(1), NEG1(-1), SGN(0x8000) and temps BT, D, V.

32-bit branches (rs1 vs rs2, to guest target `L`, else fall through) compose hi-then-lo (structure
confirmed; the 16-bit predicates must be EQ16/LTU16 above, not the broken LE):
- BEQ: `NE16(rs1.lo,rs2.lo,FT); EQ16(rs1.hi,rs2.hi,L); FT:`
- BNE: `NE16(rs1.hi,rs2.hi,L); NE16(rs1.lo,rs2.lo,L);`  (fall through = equal)
- BLTU: `if LTU16(rs1.hi,rs2.hi) goto L; if LTU16(rs2.hi,rs1.hi) goto FT; if LTU16(rs1.lo,rs2.lo) goto L; FT:`
- BGEU: complement (swap L/FT).
- BLT (SIGNED, 0x8000 landmine): flip the hi sign bit into temps `sh1=rs1.hi^0x8000`, `sh2=rs2.hi^0x8000`
  (x^0x8000 == (x+0x8000) mod 65536), then UNSIGNED-compare sh1/sh2 for hi, lo stays unsigned:
  `if LTU16(sh1,sh2) goto L; if LTU16(sh2,sh1) goto FT; if LTU16(rs1.lo,rs2.lo) goto L; FT:`
  (edge-checked 0x80000000/0, 0x7fffffff/0x80000000, -1/0, min/max -- correct with corrected LTU16.)
- BGE: complement of BLT. SLT/SLTU: same compare writing 1/0 into rd instead of branching.

ADD `rd = rs1 + rs2` (32-bit): `rd.lo = rs1.lo + rs2.lo`; `carry = MAJ(bit15(rs1.lo), bit15(rs2.lo),
!bit15(lo_res))` (matches rvadd.sub, muxleq.fth:606); `rd.hi = rs1.hi + rs2.hi + carry`. 16-bit `b += a`
= `MOVE(Z->T); SUBLEQ(a,T,.); SUBLEQ(T,b,.)` (T=-a; b-=T => b+=a).
SUB `rd = rs1 - rs2` (direct, simpler than ~+1 via ADD): `rd.lo = rs1.lo - rs2.lo`;
`borrow = LTU16(rs1.lo, rs2.lo)`; `rd.hi = rs1.hi - rs2.hi - borrow` (matches rvsub.sub, muxleq.fth:614).
ADDI/etc = same with the immediate as a constant cell. x0 as source folds to Z; x0 as dest is dropped.

TWO HARD RULES: (1) rd == rs1 or rd == rs2 is legal RV32I -- ADD/SUB MUST compute into a
temp pair (out_lo,out_hi) and MOVE to rd only at the end, or snapshot the needed source halves first, else
the carry/hi step reads an already-overwritten operand. (2) temp cells: a single per-BLOCK pool (T0,T1,...)
is fine, but each macro must reserve enough temps internally and leave nothing a later instruction needs
live in them -- macro-local discipline, not fresh physical temps per instruction.

## Validation (the whole point is a measurable win)

- Correctness: "./build/muxleq -x prog.dec" stdout must be byte-identical to "./build/muxleq -r prog.elf" on all 7
  demos plus the unopt loop, and the wide "./build/muxleq -x32 prog.dec" is validated the same way.
- Performance: `./build/muxleq -s -x prog.dec` dispatched-op count must be BELOW `./build/muxleq -s -r prog.elf`. If it
  is not, native emission has failed its reason to exist -- report and diagnose, do not paper over.
  CAVEAT: `-s < -r` can fail STRUCTURALLY on tiny/IO-heavy programs -- a fixed prologue, the constant
  pool, and an expanded ecall-write loop can dominate a program that does little compute. So do NOT judge
  the milestone on slices 1-3, and pick the first fair win target as a TIGHT COMPUTE LOOP with little I/O
  and no hard ops: `fibonacci` or `primes` FIRST, then `crc16`; leave `bgcd`/`bsort` until branches, shifts,
  and memory are solid; `hello` is an I/O-dominated smoke test, not a perf proof.
- `make verify-rvopt-mux` (the 16-bit differential over the 7 demos + unopt + fuzz + SMC reject) and
  `make verify-mux32` (the wide `-x32` smoke + fixtures + all 7 demos vs `-r` + `--wide` fuzz + SMC reject)
  are wired into `check-all`; `make verify-riscv-tests` runs `check` (`-r` 40/40) + `check-mux` (16-bit
  39/40, skip ld_st) + `check-x32` (wide 40/40, incl. ld_st); `make sanitize` runs the emitter (every op
  path + loop fuzz, both `-mux` and `--wide`) AND the `-x`/`-x32` runners under ASan/UBSan.

## Staged slices (all landed -- the original build order, kept for the record)

These were the smallest-validated-increment stages; ALL are implemented. Ordered so the HARDEST
byte-identical pieces (sub-cell byte load/store alignment + sign extension, then shifts and signed
compares -- the 0x8000 compare landmine is handled in muxleq.fth:891) came last:

1. VM `-x` load-and-run + bounds-check + the smallest HAND-written `.dec`: a `c=0x8006` MOVE of a constant
   into a cell, `PUT` its low byte, negative halt. Proves the contract + load/run/PUT/halt. No rvopt yet.
2. rvopt `-mux` for the straight-line `ADDI rd,x0,imm` / `ADDI x0,..` subset (reuse `fold_kind`), no
   control flow: hello's entry `li x5,0; li x6,5` -> set the two reg pairs. Nail here: the layout allocator,
   the x0 policy, and the SMC operand re-read invariant. Validate reg-pair cells == interpreter (PUT the
   value or a tiny `-x` register dump).
3. Add reg-reg/reg-imm ADD/SUB (two-cell carry) + AND/OR/XOR (MUX) + a NATIVE branch -> a tight compute
   loop with no I/O and no hard ops. First FAIR perf target: `fibonacci` or `primes`, byte-identical vs
   `-r`, and `-s` BELOW `-r` (the first real milestone proof).
4. Add ecall write->PUT loop + exit->halt + JAL/`ret` dispatch -> `hello` end-to-end (I/O smoke, not a
   perf claim).
5. Add shifts + signed/unsigned SLT/compare -> `crc16`, then the load/store byte/half alignment -> `bgcd`,
   `bsort`. Each byte-identical vs both oracles + `-s` below `-r`.

## Resolved decisions (how the open questions landed)

- Guest-RAM cell base / byte-addressing: rvopt lays out a compact power-of-two guest-RAM window it owns
  (base + mask, above the code + imm pool + regfile), assigned by the one allocator at emit time.
- x0 handling: an x0 destination is dropped (`decode_word` maps `rd==0` to NONE); x0 reads use the
  zero-initialized x0 regfile pair (there is no separate folded-zero rewrite of x0 reads).
- Prologue register init: native `-mux` zero-fills the ENTIRE regfile at entry (the `.dec` zero-fill) and
  does not special-case sp -- a stack-using program initializes sp itself in guest crt0.
- SMC operand-patch discipline: patched operand cells are alias barriers, re-read live -- the same
  invariant the interpreter honors; the emitter never bakes a patched operand. detect_smc additionally
  REJECTS a reachable constant-target store into re-executable code, closing the silent-miscompile hole.
- Measurable win: confirmed on the fair compute targets (`fibonacci`/`primes`/`crc16`) -- native `-s` is
  well below `-r`, and the MUX-MAJ collapse compounded it (crc16 -35% vs the naive v0). I/O-dominated
  `hello` is a smoke test, not a perf proof, exactly as anticipated.
