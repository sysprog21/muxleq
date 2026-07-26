# Wider-address VM / bigger RV32I programs -- design note

Status: DESIGN, awaiting a maintainer architectural decision. Written 2026-07-21 to promote the gated
"Run larger RV32I binaries" TODO item (which asks for exactly this note). Grounds the choice in the actual
muxleq.c encoding and separates two needs the reopened optimizer track conflates.

## Why this exists

The reopened rvopt track wants "bigger programs" for two DIFFERENT reasons, and they have different fixes:

1. SIZE -- full RV32I compliance (rv32ui 40/40 has two IMAGE-SIZE skips: sra 33619 cells, ld_st 108315;
   both overflow the 32768-cell space) and the memory-lowering pass (measured need-free because the 7 demos
   emit at 1.4-18% of the ceiling). Both are blocked by the emitted image / guest address space, i.e. the
   15-bit wall.
2. OPTIMIZATION HEADROOM -- the folder/DCE/SCCP passes measure ~0 on the fair-target demos because they are
   gcc-`-O2` output, already optimally lowered (measured 2026-07-21: after const-OPIMM + mv folds captured
   the demo wins, every remaining folder sub-part + SCCP dead-arm is ~0 on the demos). This is NOT a size
   problem -- a bigger gcc-`-O2` program is still optimally lowered and still folds ~0.

These are orthogonal. The wider VM fixes (1). It does NOT fix (2). See "Recommendation".

## The 15-bit wall, precisely

muxleq.c (muxleq.c:40-43): `MEM_SIZE = 1<<15 = 32768`; `MEM_MASK = 32767`; cells are `uint16_t m[MEM_SIZE]`;
`NEGATIVE_FLAG = 0x8000` (bit 15 = the SUBLEQ sign / branch flag); `IO_MARKER = 0xFFFF` (input/output/halt).
So a 16-bit cell is fully spoken for: bits 0..14 are a 15-bit address, bit 15 is the negative/branch flag,
and 0xFFFF is reserved for I/O. There is NO spare bit to widen the address within a 16-bit cell -- 16-bit
addresses would collide with both NEGATIVE_FLAG and IO_MARKER. Widening REQUIRES wider cells.

Two distinct places hit the wall:
- rvopt `-mux` emits a STANDALONE image (code + imm pool + regfile + a power-of-two guest-RAM window) that
  must fit MEM_SIZE=32768 cells, run via `./build/muxleq -x`. A bigger guest program emits a bigger image ->
  overflow (this is the sra/ld_st skip, and the memory-lowering pass's would-be target).
- `./build/muxleq -r` runs guest RV32I in a FIXED 32 KiB window (byte $7000 = cell $3800). The guest address space
  is bounded by the same 32768-cell wall.

## The sacred constraint

muxleq.c is ONE binary running THREE things on the same `m[]`: the eForth REPL (the self-hosted 16-bit image
baked in from stage0.c), `-r` (RV32I microcode inside that image), and `-x` (a standalone rvopt image). The
eForth image is 16-bit-ENCODED (MUX mask 0x8000, operand cells, IO_MARKER) and `make bootstrap` must
reproduce it byte-for-byte. So the self-host VM CANNOT change width -- widening `m[]` to a wider cell would
misread the baked 16-bit image and break bootstrap. Any wider VM must be a SEPARATE execution path that runs
ONLY standalone rvopt images, never the eForth image.

## Options for SIZE (the wider VM)

A. WIDER CELLS, SEPARATE MODE (recommended shape). Add a `uint32_t`-cell VM variant that runs ONLY rvopt
   `-mux32` images via a new flag (e.g. `-x32`), never the eForth image, so the 16-bit self-host is
   untouched and bootstrap holds. Cost: parameterize muxleq.c's cell type + masks (MEM_SIZE, MEM_MASK,
   NEGATIVE_FLAG = 1<<31, IO_MARKER = 0xFFFFFFFF) behind a compile-time or runtime mode; teach rvopt a
   `-mux32` emitter (the macros are width-agnostic in shape -- the MUX/SUBLEQ ops don't care -- but every
   emitted operand + the mask/const pool must use the wide encoding). Doubles the memory footprint of the
   wide runner (4 bytes/cell) but that runner is a separate process, not the hot self-host. This is the only
   option that actually lets rvopt emit > 32768 cells. Keeps OISC purity (still two ops).

B. BANKING / WINDOWING in 16-bit (rejected). Keep 16-bit cells, add a bank register + a windowing
   convention so the guest addresses > 32768 via bank switches. In an OISC with no bank instruction this
   needs a software-convention bank cell that every load/store consults -- a large, invasive change to the
   emitter and a per-access cost, for a demonstrator that gains nothing a wider cell does not. Reject.

C. REBASE-LOW ELF LOADER, stay 16-bit (partial, orthogonal). The 50 rv32emu ELFs link at entry 0x10000
   (byte 0x10000 = cell 0x8000 > 32767, unrepresentable). A loader that rebases PC-relative code low would
   let SOME link-high programs load -- but only PC-relative ones (absolute refs break), and it does NOT
   raise the 32768-cell ceiling, so a program > 64 KB still does not fit. Useful only in combination, not a
   size fix on its own.

## The dependency stack for REAL bigger programs

Even with the wide VM, the rv32emu ELFs (the obvious "real" bigger programs) do NOT run, because they need,
in addition to size: (b) RV32M (mul/div -- rvopt is base rv32ui only, out of scope by prior decision);
(c) newlib libc syscalls (printf/malloc/gettimeofday -- only write/exit are implemented); (d) rebase-low
(they link at 0x10000). So "run a real rv32emu benchmark" is a STACK: wide VM + RV32M + libc + rebase, each
a milestone. The wide VM alone unblocks only hand-written FREESTANDING base-ISA programs that exceed 32768
cells -- of which none exist today (the biggest demo, bsort, emits ~4300 cells post-fold, 13% of the ceiling).

## Recommendation

Split the decision by the actual need:

1. For OPTIMIZATION HEADROOM (the reason the optimizer passes read ~0 on the -O2 demos): the wider VM is the
   WRONG fix. The cheap fix is an UN-OPTIMIZED benchmark -- BUILT (tests/rv32i/unopt): a base-ISA
   -O0 xorshift kernel, entry-0, write/exit, fits 32768 cells, emits ~13477 cells (5.6x the same source at
   -O2's 2407), byte-identical vs -r, wired into verify-rvopt-mux. MEASURED REFINEMENT of the earlier claim:
   the -O0 headroom is register SPILLS, NOT folding -- unopt dumps 17 LOAD + 14 STORE (every local spilled
   to the stack) vs -O2's 0/1, and the FOLDER moves it only -0.4% (13528 no-fold -> 13477); the folder is
   mined even on -O0. So the real lever for -O0 is DEAD-STORE ELIMINATION / DCE / MEMORY-CELL COALESCING (keep
   values in the regfile, drop the spill loads/stores) -- the memory-lowering milestone, which measured ~0 on
   the -O2 demos (0 spills) but now has a concrete target. Those passes need the INTER-BLOCK LIVENESS that
   milestone-1 def-use does not yet provide (caveat), so the next optimizer step is: extend def-use to
   a backward liveness pass, then dead-store/DCE measured on unopt. This unblocks the optimizer track
   WITHOUT the wide VM.

2. For SIZE (compliance 40/40 + memory-lowering + genuinely large programs): option A (wider cells, separate
   `-mux32`/`-x32` mode) is the only real path, and it is a real architectural project. Do NOT start it until
   there is a program that needs it -- and note that need is gated behind RV32M + libc + rebase for real
   ELFs, or a hand-written freestanding base-ISA program bigger than 32768 cells (which no one has). The
   memory-lowering pass, whose whole point was image size, is measured need-free at 5x+ headroom; sra (2.6%
   over) is the only concrete over-ceiling base-ISA artifact, and reaching 39/40 for one edge test does not
   justify a cell-width rewrite.

NET: the maintainer's "unblock bigger programs" splits cleanly. The optimizer-measurement half is unblocked
CHEAPLY by a `-O0` benchmark (no VM work). The size half (the literal wider VM) is a large project gated on
a real large-program need that does not exist yet; option A is its shape when that need arrives. Suggest
doing the `-O0` benchmark first (it directly feeds milestone 2's VALIDATE), and deferring the wide VM until a
concrete large base-ISA program forces it.
