# RV32I-on-MUXLEQ ABI and memory map (§5 Phase 5, sub-task 5.1)

Entry-gate design artifact for running RISC-V RV32I as a microcode interpreter on the 16-bit
MUXLEQ VM (TODO §5 Phase 5). This is the memory-map/ABI spec the 5.2 prototype builds against --
a plan and a cell budget, not code. It also settles the two decisions 5.1 owes: the guest-address
scheme, and the implementation layer + packaging (assembler-layer microcode, bootstrapped WITH
`muxleq.fth` for self-hosting -- see Decision 1).

## Substrate facts (what we build on)

- MUXLEQ cells are 16-bit (`uint16_t`); the address space is 15-bit: `MEM_SIZE = 32768` cells
  (`muxleq.c`), i.e. 64 KiB of byte space if every cell holds two bytes.
- The shipped eForth image currently occupies 6555 cells (`stage0.dec`); the rest is working RAM
  (dictionary growth, stacks, buffers). So ~26 000 cells are free with the image resident.
- MUXLEQ arithmetic is 16-bit two's complement; there is native same-lane MUX (bitwise select) but
  no cross-lane shift. Every 32-bit RV32I value is therefore TWO cells (low half / high half), and
  every op is written as explicit half-by-half microcode (see the Phase 5 MODEL in TODO §5).

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
  simulator (Goldcrest-VP: OISC substrate + microcode = a standard RISC-V interface). Same pipeline
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
  5.8 compliance ELF ever needs more guest RAM than the combined image leaves, reclaim by making
  the eForth portion tear-downable AFTER the RV monitor is live (frees ~6555 cells ≈ 13 KiB),
  still within one self-hosted `muxleq.fth`+`rv32i.fth` build -- never by dropping self-hosting.
- Test discipline still hangs off `make golden && make bootstrap`: a thin Forth HARNESS presets the
  register/fixture cells, invokes the microcode entry once per instruction, and prints `rd`/`x0`
  for the golden. The harness is Forth; the decode+execute it drives is the assembler-layer
  microcode. (A pure-Forth 32-bit reference model is a separate oracle, built at 5.6.)

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

| Item                                   | Cells (est.) | Basis                                            |
|----------------------------------------|--------------|--------------------------------------------------|
| Register file + scratch                | ~128         | table above, padded                              |
| Fetch/decode/dispatch loop             | ~200         | fetch (2-cell load), field extraction, jump table |
| Per-op microcode (`.sl` routines)      | ~1500–4000   | OPTIMISTIC placeholder, ~40 base ops. Each MUXLEQ instruction is 3 cells, and cross-cell carry / doubling-halving shifts / sub-cell loads are bulky, so real per-op cost may run 2–3× a naive estimate. MEASURE at 5.2; do not trust this number. |
| 5.2 fixture area (raw instrs + presets)| ~32          | a handful of hand-encoded instrs + register seeds |
| Interpreter subtotal (5.2–5.7)         | **~2–4 K**   | well under the ~26 000 free cells even at the high end |
| Guest RAM for a full ELF (5.8)         | ~22 000–24 000 | 32768 − 6555 (image) − interpreter; ~44–48 KiB -- NOT guaranteed until the interpreter is measured |
| Guest RAM if image torn down (5.8)     | up to ~30 000 | frees the 6555 image cells → ~60 KiB              |

Takeaway: 5.2–5.7 fit comfortably with the image resident even if the microcode is 2–3× my
estimate. 5.8's compliance ELFs are the only place the budget could bind, and the guest-RAM
figures above are provisional until the interpreter's actual size is measured at 5.2; the
resident-vs-teardown decision is deferred to 5.8 with a measured ELF size (Decision 1).

## x0 handling

`x0` gets its two cells like any register (uniform addressing keeps the write-back path branch-
free), and `finish()` re-zeros both cells after every instruction -- the Goldcrest approach. A
write to `rd == x0` is thus allowed to happen and then erased; a read of `x0` always sees 0. The
5.2 smoke asserts `x0` stays 0 across an `ADD`/`AND`/`SLL` whose `rd` is `x0`.

## MMIO (deferred to 5.8)

Reserve a high guest-address window (e.g. the top 256 bytes of guest RAM) for a virtual UART;
leave it unmapped (a store there traps as unsupported) until 5.8 wires up MMIO. Documenting the
window now keeps guest RAM sizing honest.

## RV32I decode hazards to get right at 5.2 (before writing any op)

These are the standard RV32I traps a naive decoder falls into; the 5.2 harness must handle them
even for its ADD/AND/SLL trio, and 5.7's expansion depends on them:

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

## Open decisions flagged for the implementer (not resolved here)

1. Exact `RBASE`/`GBASE` cell offsets -- pick once the interpreter's code size is known (after 5.2),
   so guest RAM can't overlap microcode.
2. Whether the field-decode + dispatch uses a computed `iJMP` jump table or a chain of compares --
   a speed/size trade-off to measure at 5.2, not guess now.
3. 5.8 only: resident image vs teardown, driven by the largest compliance ELF's measured size.

This doc satisfies the 5.1 validation ask (register/scratch/microcode/stack/fixture budget in
cells, addressing scheme, image-coexistence decision). It does NOT open the Phase 5 gate on its
own -- that also needs the 5.2 prototype proving ADD/AND/SLL end to end (TODO §5 entry gate).
