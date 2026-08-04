# rvopt native-MUXLEQ emission

> `muxleq.fth:N` line references index the generated `build/muxleq.fth` -- the
> in-order concatenation of the `forth/*.fth` source modules. Edit the modules,
> not the concatenation.

Status: IMPLEMENTED. Native emission lowers an RV32I program to a standalone
MUXLEQ image that runs on the two ops directly, with no eForth VM layer. The
design content below (image layout, per-op lowering) is the as-built
architecture; the staged slices and open questions it closed with were all
resolved in implementation.

## As-built summary (what rvopt does today)

`rvopt` (a standalone C compiler, zero image cells) turns an RV32I ELF32 / flat
binary into a graph IR (a flat `struct node` array: linear decode + intra-block
value/def-use edges + a memory-order chain) and emits:

- `rvopt mux prog` -- a standalone MUXLEQ image run by `./build/muxleq prog.dec`
  (`NEG_FLAG = 1<<31`). A whole RV32I register is ONE 32-bit cell, so the ALU is
  native single-cell SUBLEQ/MUX (no lo/hi halves, no carry/borrow votes -- only
  the compares sign-flip at bit31). The address space is the wide host window
  (not the retired 15-bit / 32768-cell wall), so large-`.data` programs run.
- `rvopt dump` / `rvopt check` -- textual IR round-trip for the folder and decode
  passes.

Op coverage spans the rv32ui base set (ADD/SUB/SLT[U]/AND/OR/XOR + immediates,
all shifts, LUI/AUIPC, all branches, JAL, LB/LH/LHU/LW/SB/SH/SW, ecall
write/exit). JALR is lowered for statically resolvable targets (rs1 a
compile-time constant in the same block, e.g. an auipc/lui/li/addi result) and
the standard return form; other runtime-computed JALRs are rejected with an
unsupported-JALR error. Encoding is checked at decode -- JALR takes funct3 000,
SYSTEM only the exact ecall and ebreak words -- so a reserved form is an
unsupported op rather than a jump or an exit.

Optimizations: SW high-byte/address-share, const-OPIMM + mv-copy folding,
same-block store-to-load forwarding, and simple-loop register promotion. def-use
lists are built (shown in `dump`) for later passes; the current folder and
forwarding use their own cprop / memory-chain walks. Self-modifying guest code
is DETECTED and cleanly REJECTED (the constant-target case); running SMC (hybrid
deopt) is deferred until a real SMC program appears.

Compliance: the `mux` path is 40/40 rv32ui, INCLUDING ld_st (~188k cells) --
the wide host window holds programs the old narrow image could not. It rejects
self-modifying code (detect_smc) rather than miscompile it (`mux` only lowers a
JALR whose target cprop resolves statically -- a runtime-computed JALR is a clean
hard error, not silent). A bounded randomized fuzzer (`scripts/rvopt-fuzz.py`)
compares `rvopt mux | muxleq` against an independent Python RV32I model, and
`make check-sanitize` runs the VM and emitter under ASan/UBSan.

## Goal and the one idea that makes it win

Emit a **standalone MUXLEQ image** -- not Forth -- that the VM runs directly on
the two ops, with NO eForth and no `vm` layer.

The emitted image is a complete OISC program: it sets up guest registers as
cells, runs the translated logic, emits output via `PUT` (`b == -1`), and halts
by branching negative (`c == -1`). It never touches the eForth image.

## Contract

```
rvopt mux prog.elf > prog.dec   # emit a standalone MUXLEQ image
./build/muxleq prog.dec          # load prog.dec and run from pc 0
```

- `.dec` format = one decimal or `0x` cell per token (human-inspectable, same
  mental model as `stage0.dec`).
- The VM loads a `FILE` into a wide image, then runs from pc 0. The loader
  bounds-checks untrusted input against the configured host cap.
- rvopt assigns every address at emit time (it lays out registers + code +
  data), so there is NO runtime relocation and NO runtime assembler -- rvopt, not
  the VM, does the layout.

## Image layout (rvopt-assigned absolute cell addresses)

ONE allocator with reserved, non-overlapping ranges assigns every cell (entry
code, address 6, constants, and the regfile can otherwise collide). Address-6
subtlety: the VM treats MUX *mask address* 6 as zero regardless of `m[6]` -- so a
MOVE is `c = 0x80000006` (NEG_FLAG | 6), and `m[6]` is NOT a general zero cell
for SUBLEQ arithmetic; use a SEPARATE constant-zero cell. Because a `c=0x80000006`
MOVE is a copy for ANY src/dst, code can start at cell 0 with no jump-over
prologue; the low code cells (incl. cell 6) are just ordinary operands.

```
0            entry: the first real instruction (VM starts here; regs zero-fill)
code         one MUXLEQ macro sequence per basic block
data:                (everything below sits AFTER the code)
constants    a zero cell (SUBLEQ / halt), a -1 cell, the immediate + shared pool
regfile      x0..x31, one 32-bit cell each. x0 is a read-only zero cell.
scratch      per-block temporaries (compare results, shift accumulators)
guest RAM    the RV program's .rodata/.bss at a fixed cell base. Loads/stores
             with a computed address use SMC: patch a later MUXLEQ operand cell
             then execute it. A patched operand is an alias barrier and MUST be
             re-read live -- the same self-modifying-operand invariant the
             interpreter honors; the emitter never bakes a patched operand.
```

Native code lives in `m[]` like guest RAM does -- it does NOT go through the
self-host bootstrap, so the self-host headroom does not constrain it.

## Per-op lowering

- ALU reg/imm (ADD/SUB/AND/OR/XOR/SLT/shifts): single-cell arithmetic. AND/OR/XOR
  lower to native MUX, not SUBLEQ bit loops; a whole register is one cell, so
  there is no cross-cell carry.
- LUI/AUIPC: constant / pc+imm into a reg (pc is a compile-time constant per
  instruction -- no runtime PC needed).
- Branches (BEQ/BNE/BLT[U]/BGE[U]): compute the compare into a scratch cell, then
  a native MUXLEQ branch to the taken block or fall through.
- JAL: set link (pc+4 const) into rd + branch to the target block (direct, target
  known at emit time).
- JALR (as-built): two static forms are handled and cover all of rv32ui + the
  demos: (1) a STATIC-TARGET JALR whose `rs1` cprop resolves to a compile-time
  address (`resolve_jalr` records the target node, like a JAL) -- emit a direct
  jump plus the pc+4 link if rd != 0; (2) the `jalr x0,x1,0` return form -- a
  single reachable `jal ra` call site whose return address is checked against the
  stored value, then jump to the block after the call. Anything else is a clean
  hard error, deferred until a real program needs runtime dispatch.
- LOAD/STORE: address = reg+imm; SMC-patch the operand of a MOVE/SUBLEQ to that
  cell, execute; byte/half via MUX/shift + alignment rules.
- ecall: write(64) = a loop emitting a2 guest bytes from [a1] via `PUT`;
  exit(93) = branch negative (halt).

## Validation

- Correctness: `make check-mux` checks the hand-written image, a high-address
  fixture, the rvopt image-size ceiling, and randomized `rvopt mux` fuzz against
  the Python RV32I model.
- `make check-sanitize` runs the VM and `rvopt mux` fuzz under ASan/UBSan.

## Resolved decisions (how the open questions landed)

- Guest-RAM cell base: rvopt lays out a compact power-of-two guest-RAM window it
  owns (base + mask, above the code + imm pool + regfile), assigned at emit time.
- x0 handling: an x0 destination is dropped (`decode_word` maps `rd==0` to NONE);
  x0 reads use the zero-initialized x0 regfile cell.
- Prologue register init: the emitter zero-fills the entire regfile at entry (the
  `.dec` zero-fill); a stack-using program initializes sp itself in guest crt0.
- SMC operand-patch discipline: patched operand cells are alias barriers, re-read
  live; the emitter never bakes a patched operand. detect_smc additionally
  REJECTS a reachable constant-target store into re-executable code, closing the
  silent-miscompile hole.

## Zicsr / machine CSRs (RV32I RTOS)

Supported CSR ops (`K_CSR`, opcode 0x73, funct3 != 0): `CSRRW/CSRRS/CSRRC`
(register) and `CSRRWI/CSRRSI/CSRRCI` (5-bit zimm). Privileged: `MRET`, `WFI`.
`K_SYSTEM` still means `ecall`/`ebreak` only; any other privileged/reserved
encoding (sret, funct3 4) stays `K_ILL`. An unsupported CSR *number* is rejected
at emit with `rvopt mux: unsupported CSR 0x..`.

CSR state lives in a dedicated data-cell block (`m.csr_base`, `CSR_COUNT` cells),
plain operands the guest reads/writes live (never executed, never cached as an
immediate), so a timer that patches them under the running guest is always seen
fresh (satisfies the SMC re-entrancy invariant, TODO.md 26-28). Supported numbers:

| CSR       | number | notes                                          |
|-----------|--------|------------------------------------------------|
| mstatus   | 0x300  | only MIE (bit 3) / MPIE (bit 7) are meaningful  |
| mie       | 0x304  | only MTIE (bit 7)                               |
| mtvec     | 0x305  | trap vector base (must be a compile-time addr)  |
| mepc      | 0x341  | interrupted PC (a block-leader guest PC)        |
| mcause    | 0x342  | timer interrupt = 0x80000007                    |
| mip       | 0x344  | only MTIP (bit 7)                               |
| mtime     | 0xB00  | reused mcycle number (no MMIO on this VM)       |
| mtimecmp  | 0x7C0  | custom M-mode number (no MMIO on this VM)       |
| mscratch  | 0x340  | trap-handler save-area pointer (context switch) |

`emit_csr32` builds the new value in a scratch cell from the ORIGINAL csr/source
(so `CSRRS/C` with `rd == rs1` is correct), then reads the old csr into `rd`; a
set/clear with a zero mask (`rs1==x0` / `zimm==0`) is a pure read and does NOT
write. Immediate set/clear applies each zimm bit via the 2^b mask pool, so no imm
slot is consumed. Test: `tests/rv32i/rtos/test-csr.S` (via `make check-rtos`).

## Indirect-jump entry dispatch (`rvopt mux --indirect`)

rvopt keeps no runtime PC, so a `ret`/`jalr` to a runtime-computed address is
normally a hard error. `--indirect` opts into dispatching a `ret` (`jalr x0,x1,0`)
over a collected set of function-pointer / task-entry addresses (in addition to
the usual `jal`-return sites): a task's first activation `ret`s to its entry, not
a call-return site. `collect_entry_targets` gathers word-store (`sw`) values that
are known constants landing on a real decoded instruction; the mechanism is
opt-in because a code pointer and a data pointer written to memory are not
distinguishable in a single RWX image (a stored `la sp, data` looks identical to
a stored task entry), so enabling it unconditionally would try to emit data as
code. Off by default: ordinary programs (the rv32ui conformance suite) are
unaffected. Proven by the cooperative kernel (`make check-rtos`, transcript
`ABABAB!`).

## Timer interrupts and mret

Design (block-boundary delivery, matches eternal's edge-trigger shape but with
`mtvec`/`mepc` replacing the magic `mem[0]`/`mem[1]`):

- Opt-in `--timer`. Register promotion and load-forwarding are disabled for
  timer images so the regfile cells are canonical at every safepoint (a delivered
  interrupt saves and later restores the guest registers straight from their
  cells).
- `mtime` ticks in RETIRED GUEST INSTRUCTIONS: each safepoint adds its own
  block's guest-instruction count, independent of MUXLEQ fusion/lowering. Only
  blocks that reach a safepoint contribute, so it is a "retired instructions in
  safepoint blocks" clock rather than a whole-program cycle count. That is
  self-consistent with `mtimecmp = mtime + QUANTUM` and bounds preemption
  latency to one block, which is the intent.
- Safepoints are backward-branch/jump-target leaders (loop headers): the natural
  preemption points, far fewer than every leader. This covers the `wfi` wait-loop
  idiom (`wfi; j wait`), where `wfi` itself is a nop and the loop header re-checks
  the timer each pass; a bare non-looping `wfi` is not a real wait and is not a
  safepoint. At a safepoint, if `mstatus.MIE` and `mie.MTIE` are set and
  `mtime >= mtimecmp`, deliver: `mepc = <safepoint guest PC>`, `mcause =
  0x80000007`, `mip |= MTIP`, save+clear `mstatus.MIE` into MPIE, jump to the
  statically-resolved `mtvec` block. Because delivery happens at a block boundary
  BEFORE the block body runs, `mepc` is the block start and resume re-runs the
  block cleanly (no partial-instruction state).
- `mret` restores `mstatus.MIE` from MPIE and dispatches `mepc` over the safepoint
  set AND the `--indirect` entry-target set (a preempted task resumes at a
  safepoint; a task's first launch resumes at its entry), the same compare-chain
  shape as the entry dispatch.
- The delivery preamble uses only rvopt's internal scratch cells, never the guest
  regfile, so all guest registers are intact when the handler starts. A
  preemptive kernel can therefore save and restore the full register context in
  the handler with the standard `mscratch` save-area technique (`csrrw sp,
  mscratch, sp`); no register-spill ABI in rvopt is needed.
- `wfi` busy-waits (re-checks the timer) rather than halting while interrupts are
  enabled.
- `mip.MTIP` is an approximation, not a continuously-maintained CLINT bit: it is
  set at a delivery-enabled safepoint and cleared when the guest writes
  `mtimecmp` (matching the rearm-to-a-future-deadline idiom). Between those
  points it is not recomputed, so a guest that polls `mip.MTIP` with interrupts
  disabled, or after writing `mtimecmp <= mtime`, may read a stale value. Timer
  delivery is unaffected (it is gated on `mtime >= mtimecmp`, never on `mip`).
- `mtime` is a single 32-bit cell (real RISC-V is 64-bit) and the deadline test
  is a plain unsigned `mtime >= mtimecmp`. It therefore has a wrap horizon at
  2^32 retired guest instructions: once `mtime` nears `0xffffffff`, a rearm to
  `mtime + QUANTUM` wraps `mtimecmp` below `mtime`, and the unsigned compare
  reports "expired" for the roughly one-quantum window until `mtime` itself
  wraps past it, delivering one spurious early tick. A normal handler self-heals
  (the trap path retires enough instructions to carry `mtime` across the wrap
  before it rearms `mtimecmp`), so the scheduler just sees a single slightly
  early preemption per 2^32 instructions. A signed compare would only move the
  window to the signed boundary, not remove it; the wrap-correct form is the
  difference test `(int32_t)(mtime - mtimecmp) >= 0`, deliberately not spent
  here since it would enlarge every safepoint for a benign, astronomically rare,
  self-correcting event on a teaching substrate.
- Tests (`make check-rtos`): `tests/rv32i/rtos/test-timer.S` (expected `TTR`; the
  second interrupt observes the memory/CSR state the first one left), and
  `tests/rv32i/rtos/`, a preemptive RTOS on this substrate: an asm trap
  handler (`ktrap.S`) saves full register context via `mscratch` and calls a C
  scheduler in the shared core `rtos.c` (priority scheduling, blocking counting
  semaphores, a priority-inheritance mutex, and an idle task). Blocking needs no
  synchronous switch: a blocked task parks itself (state BLOCKED) and spins at a
  `wfi` safepoint while the scheduler skips non-READY tasks. The core drives two
  scenarios. `test-rtos.c` runs the classic priority-inversion setup: a low task
  holds the mutex, a high task blocks on it (lifting the holder to the high
  priority so a middle task cannot preempt it and starve the high task), so the
  high task runs before the middle one and the transcript is `LHM` (without
  priority inheritance it would be `LMH`). `test-semaphore.c` covers the counting
  path: a high-priority producer fills one semaphore to 3 before a low-priority
  consumer drains it in order, transcript `ABC`.
