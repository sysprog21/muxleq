# RV32I compliance for `../../../muxleq` via the official riscv-tests rv32ui suite.
#
# The upstream test bodies are NOT vendored: this Makefile shallow-clones them
# (pinned to UPSTREAM_REV) into ./upstream (gitignored) and builds each with a
# minimal muxleq patch -- riscv_test.h (a test env: entry 0, stdout PASS/FAIL,
# replacing upstream's tohost/MMIO env) + link.ld (link at 0). test_macros.h and
# the rv64ui/*.S bodies come from the clone; -march=rv32i builds them as rv32
# (MASK_XLEN truncates the 64-bit constants, dropping the 64-bit-only cases).
UPSTREAM_URL ?= https://github.com/riscv-software-src/riscv-tests.git
UPSTREAM_REV ?= 34e6b6d1e7936b526075432fb730d89148623484

CROSS  ?= riscv-none-elf-
CC      = $(CROSS)gcc
# gcc (not as) so the C preprocessor runs the #include/#define/MASK_XLEN machinery.
CFLAGS  = -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -static -no-pie \
          -I. -Iupstream/isa/macros/scalar -Wl,--no-warn-rwx-segments
MUXLEQ ?= ../../../muxleq
RVOPT  ?= ../../../rvopt
# Bound each run so a regressed branch/jump that loops forever fails the gate
# instead of hanging it. The top Makefile passes its own detected value; a
# standalone run auto-detects. Empty (no timeout tool) => unguarded, as elsewhere.
TIMEOUT ?= $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)

# Base RV32I only. Excluded: fence_i (FENCE traps by design, docs/rv32i-muxleq-abi.md)
# and ma_data (misaligned access unsupported, muxleq.fth:752).
TESTS = simple add addi and andi auipc beq bge bgeu blt bltu bne jal jalr \
        lb lbu lh lhu lui lw or ori sb sh sll slli slt slti sltiu sltu \
        sra srai srl srli sub sw xor xori ld_st st_ld

ELFS = $(addsuffix .elf,$(TESTS))

# The subset the native emitter `rvopt -mux` can lower today. The one remaining
# skip is IMAGE-SIZE ONLY -- correct code that overflows the 32768-cell native
# image: ld_st (large .data, ~108k cells). sra USED to overflow (33619 cells) but
# the cumulative optimizer work (const-OPIMM + mv folds, store-to-load forwarding,
# the MUX-MAJ dispatch collapse) shrank it to 31981 -- under the ceiling with ~787
# cells to spare -- so it now emits and PASSes native (39/40). That headroom is
# TIGHT: a codegen change that regrows sra past 32768 fails this gate loudly --
# `rvopt -mux` aborts before emit ("image needs N cells (> 32768)", rvopt.c), and
# an oversized .dec is rejected by `muxleq -x` (n >= MEM_SIZE); neither silently
# wraps. Re-skip sra consciously if that day comes. Every rv32ui emitter OP is
# supported (LB/LH/LHU/SH,
# SRL/SRA, computed JALR all landed). A test that fails to emit here is a regression.
MUX_SKIP  = ld_st
MUX_TESTS = $(filter-out $(MUX_SKIP),$(TESTS))

all: $(ELFS)

# Shallow, pinned fetch of the exact commit (git clone --depth=1 cannot target a
# raw SHA, so init + fetch the SHA; GitHub allows fetching a reachable SHA). The
# .rev stamp records the fetched commit: the recipe runs every build (FORCE) but
# only re-fetches when the stamp is missing or its rev differs from UPSTREAM_REV,
# so bumping the pin re-clones automatically while an unchanged tree leaves the
# stamp (and thus the built .elf) untouched. Renamed from a temp so a failed
# fetch leaves no half-clone.
STAMP = upstream/.rev
$(STAMP): FORCE
	@if [ "`cat $@ 2>/dev/null`" != "$(UPSTREAM_REV)" ]; then \
	  echo "fetching riscv-tests @ $(UPSTREAM_REV) (shallow)"; \
	  rm -rf upstream upstream.tmp; \
	  git init -q upstream.tmp \
	    && ( cd upstream.tmp && git remote add origin $(UPSTREAM_URL) \
	         && git fetch -q --depth=1 origin $(UPSTREAM_REV) \
	         && git checkout -q FETCH_HEAD ) \
	    && echo "$(UPSTREAM_REV)" > upstream.tmp/.rev \
	    && mv upstream.tmp upstream; \
	fi

%.elf: riscv_test.h link.ld $(STAMP)
	$(CC) $(CFLAGS) -T link.ld -o $@ upstream/isa/rv64ui/$*.S

# Run each test through the VM and assert its stdout is EXACTLY "PASS\n" and it
# exited cleanly. Byte-exact via cmp (command substitution would hide a trailing
# newline); the exit-status check catches a timeout-killed hang or a host crash
# that printed PASS before dying. A trap/illegal-instruction prints a diagnostic,
# not PASS, so cmp rejects it.
check: $(ELFS)
	@fail=0; for t in $(TESTS); do \
	  $(TIMEOUT) $(if $(TIMEOUT),20) $(MUXLEQ) -r $$t.elf > .check.out 2>/dev/null; \
	  st=$$?; \
	  if [ $$st -ne 0 ] || ! printf 'PASS\n' | cmp -s - .check.out; then \
	    echo "  FAIL: rv32ui-$$t (status $$st, got '`tr -d '\n' < .check.out`')"; fail=1; fi; \
	done; \
	$(RM) .check.out; \
	if [ $$fail -eq 0 ]; then echo "riscv-tests: all $(words $(TESTS)) rv32ui tests PASS"; \
	else exit 1; fi

# Same byte-exact PASS gate, but each test is lowered to a native MUXLEQ image by
# `rvopt -mux` and run on the two ops via `-x` (no interpreter). Covers only the
# emittable subset; a test that fails to emit is a regression (the deferred ops
# are excluded via MUX_SKIP, not silently skipped here).
check-mux: $(addsuffix .elf,$(MUX_TESTS))
	@fail=0; for t in $(MUX_TESTS); do \
	  if $(RVOPT) -mux $$t.elf > .mux.dec 2>/dev/null; then \
	    $(TIMEOUT) $(if $(TIMEOUT),20) $(MUXLEQ) -x .mux.dec > .check.out 2>/dev/null; \
	    st=$$?; \
	    if [ $$st -ne 0 ] || ! printf 'PASS\n' | cmp -s - .check.out; then \
	      echo "  FAIL(mux): rv32ui-$$t (status $$st, got '`tr -d '\n' < .check.out`')"; fail=1; fi; \
	  else echo "  FAIL(mux): rv32ui-$$t did not emit (rvopt -mux abort)"; fail=1; fi; \
	done; \
	$(RM) .mux.dec .check.out; \
	if [ $$fail -eq 0 ]; then \
	  echo "riscv-tests(-mux): $(words $(MUX_TESTS))/$(words $(TESTS)) rv32ui emit native + PASS (skip: $(MUX_SKIP))"; \
	else exit 1; fi

clean:
	$(RM) *.elf .check.out .mux.dec

# `distclean` also drops the upstream clone (re-fetched on next build).
distclean: clean
	$(RM) -r upstream upstream.tmp

FORCE:
.PHONY: all check check-mux clean distclean FORCE
