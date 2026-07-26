# RV32I-on-MUXLEQ ABI and memory map

Entry-gate design artifact for running RISC-V RV32I as a microcode interpreter on the 16-bit
MUXLEQ VM. It settles the two decisions this design owes: the guest-address scheme, and
the implementation layer + packaging (assembler-layer microcode, bootstrapped WITH `muxleq.fth` for
self-hosting -- see Decision 1).

> STATUS: RV32I base is IMPLEMENTED and running real binaries. The "AS-BUILT" section immediately
> below is the accurate reference for the shipped simulator; the sections after it are the original
> design plan, kept for the rationale (Decision 1, the implementation hazards, Decision 2 all
> still hold) but SUPERSEDED where the as-built section says so (register layout, dispatch, and the
> cell budget diverged from the plan).

## AS-BUILT (all under `opt.rv32i` in `muxleq.fth`; `opt.rv32i=0` reproduces the 6555-cell base image byte-for-byte)

State is `tvar`/`tallot` cells in the `opt.rv32i` section, NOT a single contiguous `RBASE` block.
Key cells (Forth harness sees the `rv-*` constant bridges): register file `rvregs` (64 cells, x0..x31,
two cells each; `rvbase` = halved base; x0 is index-0 and `rvwr` drops writes to it); guest RAM
`rvram` (a fixed high-memory window at byte `$7000` = cell `$3800`, NOT baked into the image; 16384
cells = 32768 bytes = 32 KiB, one little-endian 16-bit halfword per cell; `rvrammask`=0x3FFF); PC
`rvpclo`/`rvpchi`; instruction `rvil`/`rvih`; decoded fields
`rvo-rd`/`rvo-funct3`/`rvo-rs1`/`rvo-rs2`/`rvo-alt`(funct7 bit5)/`rvo-op`/`rvo-imm`, and the class
flags `rvo-itype`/`rvo-mem`/`rvo-jmp`/`rvo-uop`/`rvo-ctrl`; operand/result scratch
`rvs1{lo,hi}`/`rvs2{lo,hi}`/`rvrlo`/`rvrhi` (SRC1/SRC2/RSLT); shift/index/mask `rvsh`/`rvidx`/`rvmask`;
per-op scratch `rvtmp`/`rvneg`/`rvparity`/`rvmw`/`rvwidth`/`rvuns`/`rvmaddr`/`rvbimm{lo,hi}`/`rvtaken`;
the run-state signal `rvstate` (0 running, 1 ecall, 2 illegal); and the VM's own `r0`..`r4`.

Execution is ONE microcode entry, `:a rvstep`, that decodes a raw 32-bit word (`rvil`/`rvih`) and
executes it: it extracts the fields with `rvfield.sub` calls, loads rs1, then dispatches by OPCODE via
a chain of short-circuit blocks -- memory (0x03/0x23), branch (0x63), jump (0x6F/0x67), upper-immediate
(0x37/0x17), ecall (exact 0x00000073), then an encoding trap -- before the R/I-type (0x33/0x13) ALU,
which dispatches on `funct3` with a COMPARE CHAIN (`r0 +if else r0 -if else … then then` = equal-zero),
NOT the computed `iJMP` jump table the plan proposed (open decision 2 resolved: compare chain). The op
bodies are `.sub` routines reached by a call/return convention: a caller loads `rvlink` from a
per-site slot planted at assemble time (`<label> half rvrNN t!`), `t' foo.sub JMP`s in, and the sub
returns `rvlink iJMP`. The single shared `rvlink` is safe because the calls are strictly LINEAR (never
nested). 32-bit ops are explicit half-by-half: ADD/SUB carry/borrow = a bit15 MAJORITY vote (`RVBIT15`
macro, negation-safe unlike `-if`); AND/OR/XOR = same-lane MUX; SLL/SRL/SRA = doubling/halving with the
16-bit half-boundary spill; SLT/SLTU = high-half-first compare; the scrambled B/J/U/S immediates each
have their own extractor.

Running programs: `rvstep` is one-shot (the harness presets `rvil`/`rvih` and calls it). A Forth-driven
runner in `tests/rv32i-run.fth` turns it into a fetch-decode-execute loop: per step it fetches the two
cells at `RVPC>>1` from `rvram` into `rvil`/`rvih`, calls `rvstep`, advances `RVPC+=4` only when
`rv-ctrl==0` (branches/jumps set RVPC themselves), and services `rv-state` (==1 → ecall write/exit,
>1 → "illegal instruction" halt). The ISA stays in microcode; the runner is a harness (the ABI's
harness allowance). `ecall` (SYSTEM) is emulated host-side: `write` (a7=64) emits `a2` guest bytes from
`a1` to stdout and returns the count in `a0`; `exit` (a7=93) halts. Unknown opcodes and RV32M (funct7
bit0) trap. FENCE (MISC-MEM, opcode 0x0F) is INTENTIONALLY trapped, not executed as a no-op: it is a
no-op on this single-hart, in-order, cacheless model with no memory reordering, so trap and no-op are
indistinguishable for any program that never executes FENCE -- and none of the freestanding demos emit it.
Implementing the no-op would spend scarce image cells (the self-host ceiling) for zero reachable behavior
change, so `tests/rv32i-run.fth` reuses FENCE (0x0000000F) as its unsupported-opcode trap probe.
(FENCE is base RV32I; FENCE.I is the separate `Zifencei` extension, likewise not implemented.) To run a
prebuilt binary directly, with no host-side conversion:
`riscv-none-elf-objcopy -O binary prog.elf prog.bin; ./muxleq -r prog.bin`. The `-r` flag loads the
flat binary into guest RAM and runs it from entry 0 via the image's built-in runner (`rvrun`/`rvboot`,
which also load inline-built programs with `rvorg`/`rvcell,`). Proven with a prebuilt `hello.elf`
(prints its message 5x, exits). Programs must fit the 32 KiB guest RAM (see next paragraph).

Scope of the shipped simulator: RV32I base only (no M/A/F/D, no CSRs, no interrupts); syscalls `write`
and `exit` only; entry must be 0; guest RAM is 32 KiB (32768 bytes). The self-host memory ceiling is the
binding constraint -- the image is 10643 cells and the hard ceiling is ~12888 (the self-host holds the running
image PLUS the copy it re-assembles PLUS the metacompiler dictionary, all in 32768 cells), so the
generous guest-RAM budget the plan below assumed does NOT hold today. Bigger programs need the eForth
teardown (Decision 1) -- NOT yet done. Built: an ELF PT_LOAD parser and the C runner. NOT built:
a pure-microcode runner, the teardown, and MMIO.

Conformance: RV32I compliance is validated at the INSTRUCTION level, because the official
riscv-arch-test ELFs can't run here (they link past the 32767-cell guest window). `scripts/rv32i-
conformance.py` holds an independent Python reference model of the RV32I base spec that generates a
systematic self-checking suite -- all 37 computational ops with edge-value cross-products, every
shift amount 0..31 + masking, signed/unsigned boundaries, 12-bit immediate sign boundaries, all
branches with scrambled B-immediates, JAL, JALR (incl. the `&~1` alignment), and LUI/AUIPC -- and
drives the same operands through `rvstep`. `--verify-model` anchors the model to every vector in the
Codex-verified `tests/rv32i-spec.fth` (133 ALU/branch/jump/upper-immediate cases) so it can't share
a bug with the microcode. `make verify-rv32i` runs it (~minutes, not in `make check`); as of
72a112b all 2974 vectors pass. Loads/stores + `ecall` are covered live in `tests/rv32i-run.fth`.

---

## Original plan (below) -- design rationale; superseded where the AS-BUILT section says so

## Substrate facts (what we build on)

- MUXLEQ cells are 16-bit (`uint16_t`); the address space is 15-bit: `MEM_SIZE = 32768` cells
  (`muxleq.c`), i.e. 64 KiB of byte space if every cell holds two bytes.
- The shipped eForth image currently occupies 10643 cells (`stage0.dec`); the rest is working RAM
  (dictionary growth, stacks, buffers). So 22125 cells are free with the image resident.
- MUXLEQ arithmetic is 16-bit two's complement; there is native same-lane MUX (bitwise select) but
  no cross-lane shift. Every 32-bit RV32I value is therefore TWO cells (low half / high half), and
  every op is written as explicit half-by-half microcode (see the MODEL section).

## Decision 1 -- assembler-layer microcode, packaged under `opt.rv32i` (self-hosting)

CORRECTED per maintainer direction (an earlier draft here chose a Forth-driven, colon-word
implementation -- that was the WRONG layer). The RV32I interpreter is hand-written MUXLEQ microcode
at the meta-ASSEMBLER level, not Forth colon words:

- Write it with `muxleq.fth`'s `assembler.1` macros -- `:a`/`label:`/`JMP`/`MMOV`/`MUXR`(MUX)/`+if`/
  `begin..until` and the self-modifying `iLOAD`/`iSTORE`/`iADD`/`iSUB`/`iJMP` (muxleq.fth:290-316) --
  with all state at fixed offsets via `tvar`/`tallot`, exactly as the VM's own `start`/`vm`
  bootstrap loop and `:a` primitives are assembled. The RV32I interpreter is raw MUXLEQ the VM
  executes DIRECTLY, kin to the `:a` primitives and the `vm` inner loop; it is NOT threaded code
  read via `iLOAD`, so it does NOT use the `:t`/`compile,` colon layer. Opcode dispatch is a
  computed `iJMP` jump table.
- The metacompiler emits the microcode IMAGE (cells); `muxleq.c` executing that image IS the RV32I
  simulator (OISC substrate + microcode = a standard RISC-V interface). Same pipeline
  as eForth: `rv32i.fth → cells → m[] → muxleq.c`.
- PACKAGING (MANDATED, maintainer direction): `rv32i.fth` MUST be bootstrapped WITH `muxleq.fth`
  for self-hosting, so `make bootstrap` re-assembles and byte-checks the microcode too. CAUTION
  (Codex): the self-host feeds ONLY `muxleq.fth` on the VM's stdin (`./muxleq < muxleq.fth`) and
  there is no target `include` word, so a plain host-side `include rv32i.fth` would build stage0 but
  NOT be reproduced by stage1, breaking bootstrap. Two self-host-safe options: (a) the microcode is
  an `opt.rv32i` section PHYSICALLY inside `muxleq.fth`; or (b) the Makefile concatenates
  `muxleq.fth`+`rv32i.fth` into the SAME source fed to BOTH stage0 (Gforth) and stage1 (the VM).
  `stage0.dec` grows,
  and `make bootstrap` must stay byte-identical: the RV32I simulator thereby inherits the
  self-hosting guarantee (the VM re-assembling itself reproduces the same microcode). A standalone
  RV-monitor image kept OUT of the bootstrap is NOT the plan -- it would forfeit self-hosting. If a
  larger compliance ELF ever needs more guest RAM than the combined image leaves, reclaim by making
  the eForth portion tear-downable AFTER the RV monitor is live (frees ~6555 cells ≈ 13 KiB),
  still within one self-hosted `muxleq.fth`+`rv32i.fth` build -- never by dropping self-hosting.
- Test discipline still hangs off `make golden && make bootstrap`: a thin Forth HARNESS presets the
  register/fixture cells, invokes the microcode entry once per instruction, and prints `rd`/`x0`
  for the golden. The harness is Forth; the decode+execute it drives is the assembler-layer
  microcode. (An offline reference model is a separate oracle.)

## Assembler-layer implementation hazards (Codex-flagged)

Writing self-hosting assembler-layer microcode has traps the colon layer doesn't:

- Only the ENTRY point needs to be a `:a` primitive (or a bridge) that returns to `vm` cleanly via
  `;a`/`vm JMP`; the internal per-op routines are just `label:` targets reached by `iJMP`. A Forth
  harness cannot call an arbitrary `label:` as a threaded word -- it must go through the `:a` entry.
  Don't make every routine a public `:a`.
- The self-modifying indirect macros (`iLOAD`/`iSTORE`/`iADD`/`iSUB`/`iJMP`) bake `there`-relative
  patch addresses, so the code must be assembled IN PLACE -- copying emitted cells elsewhere is not
  relocation-safe (the same reason INLINE was hard in the threading note).
- Placement relative to `there 2/ primitive t!` (muxleq.fth:494) matters: code BEFORE that boundary
  falls in the primitive address range NEXT's primitive check uses; code AFTER is not automatically
  callable as a primitive. Decide where the RV32I entry sits accordingly.
- The computed `iJMP` dispatch table must respect muxleq's half-address convention (`iJMP` does
  `there 2/ 5 + 2* MMOV …`) -- build targets with the existing assembler patterns, never raw byte
  addresses.

## Decision 2 -- guest byte↔cell addressing, little-endian

RISC-V is little-endian. Guest byte address `B` maps to MUXLEQ cell `B>>1`, byte-in-cell `B&1`:

- byte `B` even → low 8 bits of cell `B>>1`; byte `B` odd → high 8 bits of cell `B>>1`.
- A 32-bit word at 4-aligned byte address `B` occupies cells `B>>1` (bytes 0,1) and `(B>>1)+1`
  (bytes 2,3). Its value = `(cell[(B>>1)+1] << 16) | cell[B>>1]` -- low cell is the low half.
- LB/LH/SB/SH do sub-cell access by masking/merging the target half of a cell (a MUX or a
  mask-and-OR); SW/LW touch the two cells. LB/LH SIGN-extend the loaded byte/half into the 32-bit
  destination; LBU/LHU ZERO-extend -- get this right per-opcode, it is a common porting bug.
- Guest RAM base is a fixed cell offset `GBASE`; guest address 0 = cell `GBASE`. Keep `GBASE`
  above the interpreter's own region so guest stores can't corrupt microcode.

Misaligned access: the FIRST implementation declares misaligned instruction fetch and load/store
UNSUPPORTED (trap to a halt with a distinguishable code). RV32I permits this via the misaligned-
trap path; revisit only if a target program needs it. Do not leave it implementation-defined.

## Register file and scratch (fixed cell offsets)

> SUPERSEDED by AS-BUILT: the shipped code uses named `tvar` cells (`rvregs`, `rvpclo`/`rvpchi`, the
> `rvo-*` decode fields, `rvs1*`/`rvs2*`/`rvrlo`/`rvrhi`, etc.), not one contiguous `RBASE` block with
> these exact names. The register file is 64 cells as planned; there is no separate `CARRY` cell (ADD/
> SUB use a bit15 majority vote in scratch). The table below is the original estimate.

All at fixed offsets from a base `RBASE` (a reserved region, NOT eForth's dictionary), so the
microcode addresses them as constants.

| Region        | Cells | Notes                                                              |
|---------------|-------|-------------------------------------------------------------------|
| `x0..x31`     | 64    | 2 cells each (low/high). `x0` two cells are re-zeroed every instr. |
| `RVPC`        | 2     | 32-bit guest PC (byte address); advances by 4, or by a taken branch/jump target. |
| `IR`          | 2     | the fetched 32-bit instruction word (two cells).                  |
| decode fields | 6     | `OPCODE`,`RS1`,`RS2`,`RD`,`FUNCT3`,`FUNCT7` (small ints, 1 cell each). |
| `SRC1`,`SRC2` | 4     | 32-bit operands staged for the microcode (2 cells each).          |
| `IMM`         | 2     | 32-bit sign/zero-extended immediate.                              |
| `RSLT`        | 2     | 32-bit result before write-back to `rd`.                          |
| `TMP0..TMP7`  | 8     | 16-bit scratch for carry/borrow/shift-bit work (a few ops may pair two). |
| `CARRY`       | 1     | explicit low→high carry/borrow flag for ADD/SUB/SLT.              |

Register/scratch subtotal: **91 cells** (round up to 128 for alignment/growth headroom).

## Cell budget (hand-worked)

> SUPERSEDED by AS-BUILT: the interpreter came in at the HIGH end (~4400 cells of rv32i microcode;
> full image 10643). Critically, the "~22 000–24 000 cells of guest RAM" row did NOT materialize as a
> baked buffer -- the self-host ceiling (image + its re-assembled copy + dictionary in 32768 cells) caps
> the baked image near ~12888. Instead guest RAM was moved OUT of the image into a fixed high-memory
> window (byte `$7000` = cell `$3800`, un-baked like `buf0`/`=thread`), giving 32 KiB (16384 cells) at
> zero image cost -- bootstrap and RV-run touch that high memory at disjoint times. No teardown needed.
> The eForth-teardown row would only be needed to exceed the 15-bit address ceiling or to run RV after
> heavy interactive dictionary growth. The table below is the original estimate.

| Item                                   | Cells (est.) | Basis                                            |
|----------------------------------------|--------------|--------------------------------------------------|
| Register file + scratch                | ~128         | table above, padded                              |
| Fetch/decode/dispatch loop             | ~200         | fetch (2-cell load), field extraction, jump table |
| Per-op microcode (`.sl` routines)      | ~1500–4000   | OPTIMISTIC placeholder, ~40 base ops. Each MUXLEQ instruction is 3 cells, and cross-cell carry / doubling-halving shifts / sub-cell loads are bulky, so real per-op cost may run 2–3× a naive estimate. MEASURE it; do not trust this number. |
| Fixture area (raw instrs + presets)    | ~32          | a handful of hand-encoded instrs + register seeds |
| Interpreter subtotal                   | **~2–4 K**   | under the 22125 free cells even at the high end |
| Guest RAM for a full ELF               | ~22 000–24 000 | stale baked-buffer estimate; the shipped runner uses a 32 KiB high-memory window |
| Guest RAM if image torn down           | up to ~30 000 | would free the 10643-cell image, but is not needed for the shipped 32 KiB window |

Takeaway: the interpreter fits comfortably with the image resident even if the microcode is 2–3× my
estimate. A full compliance ELF is the only place the budget could bind, and the guest-RAM
figures above are provisional until the interpreter's actual size is measured; the
resident-vs-teardown decision is deferred until a real ELF size is known (Decision 1).

## x0 handling

`x0` gets its two cells like any register (uniform addressing keeps the write-back path branch-
free), and `finish()` re-zeros both cells after every instruction. A
write to `rd == x0` is thus allowed to happen and then erased; a read of `x0` always sees 0. The
smoke test asserts `x0` stays 0 across an `ADD`/`AND`/`SLL` whose `rd` is `x0`.

## MMIO (deferred)

Reserve a high guest-address window (e.g. the top 256 bytes of guest RAM) for a virtual UART;
leave it unmapped (a store there traps as unsupported) until MMIO is wired up. Documenting the
window now keeps guest RAM sizing honest.

## RV32I decode hazards to get right (before writing any op)

These are the standard RV32I traps a naive decoder falls into; the harness must handle them
even for the initial ADD/AND/SLL trio, and the full-ISA expansion depends on them:

- Immediates are per-format and bit-scrambled: `I` (ADDI/loads/JALR), `S` (stores), `B`
  (branches), `U` (LUI/AUIPC), `J` (JAL) each gather the immediate from different instruction bit
  positions, and all except the unsigned shift-amount are SIGN-extended from bit 31. Build one
  correct extractor per format, not a single shifter.
- Shifts: the shift amount is the low 5 bits (`shamt`, 0..31) of `rs2`/imm; `funct7` bit 30
  distinguishes SRL (logical, zero-fill) from SRA (arithmetic, sign-fill), and SUB from ADD. Decode
  `funct3` + `funct7` together, not `funct3` alone.
- `RVPC` is a 32-bit byte address but is bounded by the actual guest RAM; branch/jump targets are
  `RVPC + sign-extended byte offset`; `JALR` computes `(rs1 + imm)` then CLEARS bit 0.
- Loads sign- vs zero-extend per opcode (LB/LH vs LBU/LHU), as noted in the addressing section.
- `x0` as a source reads 0 (LUI/AUIPC/JAL effectively ignore rs1; many pseudo-ops use x0).

## Open decisions flagged for the implementer (1 and 2 RESOLVED; 3 still open -- see AS-BUILT)

1. Exact `RBASE`/`GBASE` cell offsets -- RESOLVED: named `tvar`s, not fixed offsets; guest RAM
   (`rvram`) is a distinct `tvar` region after the register file, so it cannot overlap microcode.
2. Jump table vs compare chain -- RESOLVED as a COMPARE CHAIN (opcode short-circuits + `funct3`
   equal-zero tests). Simple and correct; no measured need for a computed `iJMP` table.
3. Resident image vs teardown -- STILL OPEN, now purely a guest-RAM concern: the runner and
   real-binary support shipped with the image resident (32 KiB guest RAM); teardown is the
   unbuilt path to a larger guest RAM.

This doc originally satisfied the design-validation ask (register/scratch/microcode/stack/fixture
budget in cells, addressing scheme, image-coexistence decision). The full RV32I base ISA has since
been implemented -- see the AS-BUILT section above (ADD/AND/SLL through running a real prebuilt
hello.elf, plus the encoding trap).
