include mk/common.mk

# Generated artifacts live under build/; it is the single .gitignore entry.
OUT := build

CFLAGS += -O2 -std=c99
CFLAGS += -Wall -Wextra

# Run serially: this build has no parallel steps to gain from `-j`, and serial execution guarantees
# the `check`/`check-all` prerequisite order (the fast `budget` guard fails before the slow bootstrap).
.NOTPARALLEL:
.PHONY: run bootstrap clean distclean check check-all budget golden golden-update bench verify-rv32i verify-microcode verify-rvopt verify-rvopt-mux verify-riscv-tests fuzz-rvopt sanitize duremark

BIN := $(OUT)/muxleq
STAGE0_DEC := $(OUT)/stage0.dec
RVCROSS ?= riscv-none-elf-
RVELF_DIR := $(OUT)/rv32i
DUREMARK_ELF := $(RVELF_DIR)/duremark.elf
HAVE_RVCC := $(shell command -v $(RVCROSS)gcc 2>/dev/null)
STAGE0_C := $(OUT)/stage0.c
STAGE1_DEC := $(OUT)/stage1.dec
RVOPT := $(OUT)/rvopt

all: $(BIN)

$(OUT):
	$(Q)mkdir -p $@

$(RVELF_DIR):
	$(Q)mkdir -p $@

# RV32I test binaries are generated from committed sources into build/rv32i and
# never checked in. rvelf builds the freestanding as/ld demos plus the flat
# hello.bin; unopt and duremark are C builds driven through their sub-Makefiles.
# All need the RISC-V toolchain, so every consumer gates on HAVE_RVCC and skips
# when it is absent.
.PHONY: rvelf
rvelf: | $(RVELF_DIR)
	$(Q)$(MAKE) --no-print-directory -C tests/rv32i OUT=$(CURDIR)/$(RVELF_DIR) CROSS=$(RVCROSS)

$(RVELF_DIR)/unopt.elf: | $(RVELF_DIR)
	$(Q)$(MAKE) --no-print-directory -C tests/rv32i/unopt OUT=$(CURDIR)/$(RVELF_DIR) CROSS=$(RVCROSS)

$(DUREMARK_ELF): | $(RVELF_DIR)
	$(Q)$(MAKE) --no-print-directory -C tests/rv32i/duremark OUT=$(CURDIR)/$(RVELF_DIR) CROSS=$(RVCROSS)

$(BIN): muxleq.c $(STAGE0_C) | $(OUT)
	$(VECHO) "  CC+LD\t$@\n"
	$(Q)$(CC) $(CFLAGS) -I$(OUT) -o $@ muxleq.c

# Standalone RV32I->MUXLEQ optimizer (skeleton). Built outside the image, so it
# costs zero self-host cells; not a prerequisite of the default build.
$(RVOPT): rvopt.c | $(OUT)
	$(VECHO) "  CC+LD\t$@\n"
	$(Q)$(CC) $(CFLAGS) -o $@ rvopt.c

# Round-trip every committed RV32I ELF through decode -> dump -> structural
# check. Proves the graph front end loads and self-verifies on real programs.
verify-rvopt: $(RVOPT)
	$(Q)for e in $(RVELF_FILES); do \
	    ./$(RVOPT) -dump $(RVELF_DIR)/$$e.elf | ./$(RVOPT) -check - >/dev/null \
	        || { echo "verify-rvopt: $$e.elf FAILED"; exit 1; }; \
	done
	$(Q)for f in $(RVFLAT_FILES); do \
	    ./$(RVOPT) -dump $(RVELF_DIR)/$$f.bin | ./$(RVOPT) -check - >/dev/null \
	        || { echo "verify-rvopt: $$f.bin FAILED"; exit 1; }; \
	done
	$(Q)./$(RVOPT) -dump tests/rv32i/hello.elf | grep -q 'fold=li12' \
	    || { echo "verify-rvopt: fold recognizer did not fire on hello (li12)"; exit 1; }
	$(Q)$(PRINTF) "verify-rvopt: all RV32I ELF+flat inputs decode + check clean\n"

# Native MUXLEQ emission: a standalone .dec image loaded by `-x` runs directly
# on the two ops (no eForth vm). Slice 1 = the `-x` contract via a hand-written
# smoke image; slice 2 = `rvopt -mux` for the li/nop subset (a real emitted
# image). Later slices add control flow + differential vs -r + the Forth-AOT.
verify-rvopt-mux: $(BIN) $(RVOPT)
	$(Q)$(TIMEOUT) $(if $(TIMEOUT),20) ./$(BIN) -x tests/native-smoke.dec > $(TMPDIR)/native-smoke.out 2>&1 \
	    && cmp -s tests/expected/native-smoke.out $(TMPDIR)/native-smoke.out \
	    || { echo "verify-rvopt-mux: native-smoke output mismatch"; exit 1; }
	$(Q)for t in li3 jump beq bne blt bge bltu bgeu alu sum slt slli srli sll mem word; do \
	    ./$(RVOPT) -mux tests/rvopt-$$t.bin > $(TMPDIR)/rvopt-$$t.dec 2>/dev/null \
	        && $(TIMEOUT) $(if $(TIMEOUT),20) ./$(BIN) -x $(TMPDIR)/rvopt-$$t.dec > $(TMPDIR)/rvopt-$$t.out 2>&1 \
	        && cmp -s tests/expected/rvopt-$$t.out $(TMPDIR)/rvopt-$$t.out \
	        || { echo "verify-rvopt-mux: rvopt -mux $$t output mismatch"; exit 1; }; \
	done
	$(Q)for e in $(RVELF_FILES); do \
	    ./$(RVOPT) -mux $(RVELF_DIR)/$$e.elf > $(TMPDIR)/mux-$$e.dec 2>/dev/null \
	        && $(TIMEOUT) $(if $(TIMEOUT),20) ./$(BIN) -x $(TMPDIR)/mux-$$e.dec > $(TMPDIR)/mux-$$e.x 2>&1 \
	        && ./$(BIN) -r $(RVELF_DIR)/$$e.elf > $(TMPDIR)/mux-$$e.r 2>&1 \
	        && cmp -s $(TMPDIR)/mux-$$e.x $(TMPDIR)/mux-$$e.r \
	        || { echo "verify-rvopt-mux: native $$e differs from -r"; exit 1; }; \
	done
	$(Q)if command -v python3 >/dev/null 2>&1; then \
	    python3 scripts/rvopt-fuzz.py --n 18 --body 20 --seed 1 >/dev/null \
	        || { echo "verify-rvopt-mux: differential fuzz FAILED (see stderr above)"; exit 1; }; \
	else $(PRINTF) "verify-rvopt-mux: python3 absent, skipping differential fuzz\n"; fi
	$(Q)$(TIMEOUT) $(if $(TIMEOUT),20) ./$(BIN) -r tests/rvopt-smc.bin >/dev/null 2>&1 \
	    && ! ./$(RVOPT) -mux tests/rvopt-smc.bin >/dev/null 2>&1 \
	    || { echo "verify-rvopt-mux: SMC guard -- -r must run rvopt-smc.bin AND -mux must reject it"; exit 1; }
	$(Q)test -z "$(HAVE_RVCC)" || ./$(RVOPT) -mux $(RVELF_DIR)/unopt.elf > $(TMPDIR)/unopt.dec 2>/dev/null \
	    && $(TIMEOUT) $(if $(TIMEOUT),20) ./$(BIN) -x $(TMPDIR)/unopt.dec > $(TMPDIR)/unopt.x 2>&1 \
	    && ./$(BIN) -r $(RVELF_DIR)/unopt.elf > $(TMPDIR)/unopt.r 2>&1 \
	    && cmp -s $(TMPDIR)/unopt.x $(TMPDIR)/unopt.r \
	    || { echo "verify-rvopt-mux: -O0 headroom benchmark (unopt) differs from -r"; exit 1; }
	$(Q)$(PRINTF) "verify-rvopt-mux: native MUXLEQ images run on the two ops (incl. 7 demos vs -r + fuzz + SMC reject + unopt)\n"

# Official RV32I compliance: the riscv-tests rv32ui suite (BSD), shallow-cloned
# and pinned by the sub-Makefile, built with a muxleq env (entry 0, stdout
# PASS/FAIL) and run through -r AND the native -mux emitter. Needs the RISC-V
# toolchain; skips gracefully when absent, like the differential fuzz above.
verify-riscv-tests: $(BIN) $(RVOPT)
	$(Q)if command -v $(RVCROSS)gcc >/dev/null 2>&1; then \
	    $(MAKE) --no-print-directory -C tests/rv32i/riscv-tests check check-mux \
	        CROSS=$(RVCROSS) MUXLEQ=$(CURDIR)/$(BIN) RVOPT=$(CURDIR)/$(RVOPT) \
	        TIMEOUT="$(TIMEOUT)" \
	        || { echo "verify-riscv-tests: a rv32ui compliance test FAILED"; exit 1; }; \
	else $(PRINTF) "verify-riscv-tests: RISC-V toolchain ($(RVCROSS)gcc) absent, skipping rv32ui suite\n"; fi

# Deep on-demand differential fuzz: random programs (ALU/shift/immediate +
# load/store round-trips + forward branches) with random 32-bit seeds, native -x
# vs the -r interpreter. Override N/BODY/SEED, e.g. `make fuzz-rvopt N=200 SEED=9`.
# BODY default 24 keeps ~88% of programs under the 32768-cell image (bigger just
# skips more, since load/store and branch ops are 2 words each). Failure prints a
# --seed/--only/--body repro command.
fuzz-rvopt: $(BIN) $(RVOPT)
	$(Q)python3 scripts/rvopt-fuzz.py --n $(if $(N),$(N),64) --body $(if $(BODY),$(BODY),24) --seed $(if $(SEED),$(SEED),1)

run: $(BIN)
	$(Q)./$(BIN)

$(STAGE0_C): $(STAGE0_DEC) | $(OUT)
	$(Q)sed 's/$$/,/' $^ > $@

$(STAGE0_DEC): muxleq.fth | $(OUT)
	$(VECHO) "  FORTH\t$@\n"
	$(Q)gforth $< > $@

# Golden-output regression suite: each test's stdout must match
# tests/expected/<name>.out byte-for-byte. A substring grep would miss most
# drift; this is the safety net for interpreter/fusion work. `define` compiles
# and runs new words at runtime (the decode-once guard).
GOLDEN_FILES := \
	loops radix sqrt \
	fibonacci bitcount clz crc log arith prng-bench \
	life rainbow control editor \
	define chacha20 scheduler tasker sieve collatz base recurse rot13 double sort heap except eof \
	demo-hello demo-f demo-loops demo-trig demo-multiply \
	demo-array demo-does demo-ascii \
	demo-text demo-money demo-temp demo-weather demo-calendar \
	demo-fig demo-stack demo-msgpass demo-value rv32i-spec rv32i-run

# Bound each test run so a mis-fused interpreter that loops forever fails the
# gate instead of hanging it -- an infinite loop is the likeliest fusion bug.
# Degrade to no bound if timeout(1)/gtimeout is unavailable.
TIMEOUT := $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
GOLDEN_RUN = $(TIMEOUT) $(if $(TIMEOUT),20) ./$(BIN)

# Prebuilt RV32I programs exercised end-to-end through the `-r` ELF loader (the
# committed .elf, so no RISC-V toolchain is needed at gate time). Output is
# compared against tests/expected/rv32i-<name>.out.
RVELF_FILES := $(if $(HAVE_RVCC),hello fibonacci primes crc16 mul bgcd bsort)
# Bare-metal RISC-V toolchain prefix for the freestanding tests/rv32i programs and
# the vendored riscv-tests compliance suite. Override as `make RVCROSS=...-`.
RVCROSS ?= riscv-none-elf-
# Flat (objcopy -O binary) programs, to exercise the -r flat-binary path as well as the ELF
# path. hello.bin is the same program as hello.elf, so it reuses tests/expected/rv32i-hello.out.
RVFLAT_FILES := $(if $(HAVE_RVCC),hello)
RVELF_RUN = $(TIMEOUT) $(if $(TIMEOUT),20) ./$(BIN) -r

golden: $(BIN) $(if $(HAVE_RVCC),rvelf)
	$(Q)test -n "$(TIMEOUT)" || $(PRINTF) \
	    "golden: WARNING: no timeout(1)/gtimeout; a hung test (e.g. broken task switching) will not be bounded\n"
	$(Q)$(foreach t,$(GOLDEN_FILES),\
	    $(PRINTF) "golden $(t) ... "; \
	    if $(GOLDEN_RUN) < tests/$(t).fth > $(TMPDIR)/golden.out 2>/dev/null \
	        && cmp -s tests/expected/$(t).out $(TMPDIR)/golden.out; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "DRIFT or VM error\n"; exit 1; \
	    fi; \
	)
	$(Q)$(foreach e,$(RVELF_FILES),\
	    $(PRINTF) "golden rv32i/$(e).elf ... "; \
	    if $(RVELF_RUN) $(RVELF_DIR)/$(e).elf > $(TMPDIR)/golden.out 2>/dev/null \
	        && cmp -s tests/expected/rv32i-$(e).out $(TMPDIR)/golden.out; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "DRIFT or VM error\n"; exit 1; \
	    fi; \
	)
	$(Q)$(foreach f,$(RVFLAT_FILES),\
	    $(PRINTF) "golden rv32i/$(f).bin ... "; \
	    if $(RVELF_RUN) $(RVELF_DIR)/$(f).bin > $(TMPDIR)/golden.out 2>/dev/null \
	        && cmp -s tests/expected/rv32i-$(f).out $(TMPDIR)/golden.out; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "DRIFT or VM error\n"; exit 1; \
	    fi; \
	)

# Regenerate goldens from the current binary. Run only after an intentional,
# reviewed behavior change -- never to paper over a regression. Each golden is
# written atomically and only if the VM exits cleanly (set -e + temp then mv).
golden-update: $(BIN)
	$(Q)set -e; $(foreach t,$(GOLDEN_FILES),\
	    $(GOLDEN_RUN) < tests/$(t).fth > $(TMPDIR)/golden.out 2>/dev/null; \
	    mv $(TMPDIR)/golden.out tests/expected/$(t).out;)
	$(Q)set -e; $(foreach e,$(RVELF_FILES),\
	    $(RVELF_RUN) $(RVELF_DIR)/$(e).elf > $(TMPDIR)/golden.out 2>/dev/null; \
	    mv $(TMPDIR)/golden.out tests/expected/rv32i-$(e).out;)

# The pre-commit gate: cell-budget guard + byte-exact golden diff + the self-hosting proof.
check: budget golden bootstrap

# Self-host ceiling guard. The image + its re-assembled copy + the metacompiler dictionary must all
# fit 32768 cells (empirical hard ceiling ~12888, where bootstrap starts to fail). Fail loudly HERE if
# stage0.dec exceeds the budget, instead of a cryptic -13/hang deep in `make bootstrap`. Bump MAX_CELLS
# consciously (with evidence bootstrap still holds) if the image legitimately needs to grow.
MAX_CELLS ?= 12500
budget: $(STAGE0_DEC)
	$(Q)cells=$$(grep -c . $(STAGE0_DEC)); \
	    if [ "$$cells" -gt $(MAX_CELLS) ]; then \
	        $(PRINTF) "budget: image is $$cells cells, over the $(MAX_CELLS)-cell budget (ceiling ~12888) -- shrink the image or bump MAX_CELLS if bootstrap still holds\n"; \
	        exit 1; \
	    else $(PRINTF) "budget: image $$cells / $(MAX_CELLS) cells "; $(call notice, [OK]); fi

# DureMark benchmark on the RV32I simulator (upstream list+matrix+state workloads, vendored under
# tests/rv32i/duremark/). ~3.2 G dispatched MUXLEQ ops / ~16 s for one iteration -- a benchmark-scale
# load, deliberately OUT of the fast `make check`; it runs in check-all and on demand. Needs the 32 KiB
# guest window (its ~4.5 KB image never fit the old 1 KiB). The checksum is byte-identical to a native
# build, so a drift means the RV32I microcode or the guest-RAM window regressed.
duremark: $(BIN) $(if $(HAVE_RVCC),$(DUREMARK_ELF))
	$(Q)$(PRINTF) "duremark rv32i ... "; \
	    if $(TIMEOUT) $(if $(TIMEOUT),90) ./$(BIN) -r $(DUREMARK_ELF) > $(TMPDIR)/duremark.out 2>/dev/null \
	        && cmp -s tests/expected/duremark.out $(TMPDIR)/duremark.out; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "DRIFT or VM error\n"; exit 1; fi

# Deep pre-release gate: the standard check plus the slow/opt-in exhaustive checks (RV32I conformance,
# the Z3 ALU proof, the ASan+UBSan run, and the DureMark benchmark). Minutes; needs z3-solver + a
# sanitizer-capable compiler.
check-all: check verify-rv32i verify-microcode verify-rvopt verify-rvopt-mux verify-riscv-tests sanitize duremark

# bootstrapping
bootstrap: $(STAGE0_DEC) $(STAGE1_DEC)
	$(Q)if diff $(STAGE0_DEC) $(STAGE1_DEC); then \
	$(call notice, [OK]); \
	else \
	$(PRINTF) "Unable to bootstrap. Aborting"; \
	exit 1; \
	fi;

$(STAGE1_DEC): $(BIN) muxleq.fth | $(OUT)
	$(VECHO)  "Bootstrapping... "
	$(Q)./$(BIN) < muxleq.fth > $@

TMPDIR := $(shell mktemp -d)

# Consolidated throughput benchmark. Builds the VM on a quiet remote host (node1
# by default -- localhost load makes wall-clock timing unreliable) and reports, per
# workload, Mops/s = million dispatched instructions / best user second (one "op"
# is one dispatch() entry -- -s does not count fused inline ops, so the raw op count
# is higher). The DETERMINISTIC dispatch count (exact, machine-independent) over the
# best-of-REPS uninstrumented
# time, so the raw count is always turned into a precise, comparable rate rather than
# shown bare. All params pass through the environment to scripts/bench.sh (which
# defaults them): `BENCH_HOST=node2 TIME=20000 REPS=9 make bench` and `make bench
# TIME=20000` both work. scripts/bench.sh ships the sources and runs bench-remote.sh.
bench: $(STAGE0_C)
	$(Q)sh scripts/bench.sh

# RV32I instruction-level conformance. The official riscv-arch-test ELFs can't run
# on this 16-bit substrate (they link past the 32767-cell guest window), so
# compliance is validated per-instruction: scripts/rv32i-conformance.py
# runs an independent Python reference model (anchored to tests/rv32i-spec.fth's
# Codex-verified vectors via --verify-model) and drives the SAME operands through
# the :a rvstep microcode, self-checking each. Slow (thousands of vectors through
# the eForth text interpreter, minutes) so it is NOT part of `make check` -- run it
# explicitly. Any FAIL or VM error (a stray `?`) fails the target.
verify-rv32i: $(BIN)
	$(Q)python3 scripts/rv32i-conformance.py > $(TMPDIR)/conform.fth
	$(Q)./$(BIN) < $(TMPDIR)/conform.fth > $(TMPDIR)/conform.out 2>&1; \
	    ok=$$(grep -c '^OK' $(TMPDIR)/conform.out); \
	    bad=$$(grep -ciE 'FAIL|\?$$' $(TMPDIR)/conform.out); \
	    $(PRINTF) "verify-rv32i: $$ok OK, $$bad bad\n"; \
	    if [ "$$bad" -eq 0 ] && [ "$$ok" -gt 0 ]; then $(call notice, [OK]); \
	    else $(PRINTF) "CONFORMANCE FAILURE\n"; grep -iE 'FAIL|\?$$' $(TMPDIR)/conform.out | head; exit 1; fi

# Exhaustive symbolic proof of the 32-bit ADD/SUB/SLT/SLTU/SLL/SRL/SRA microcode: verify-microcode.py
# models each op as the microcode computes it (majority-vote carry/borrow; the SHL1 doubling shifts)
# in Z3 and proves it equals the true 32-bit result over the entire input space (conformance above
# only samples). Needs the z3 Python package; host-side, no VM involvement, so it is NOT part of
# `make check`.
verify-microcode:
	$(Q)python3 scripts/verify-microcode.py

# Build with AddressSanitizer + UndefinedBehaviorSanitizer and run every golden program plus the -r
# paths AND the standalone rvopt emitter (its own malloc + na[]/graph pointer arithmetic, invisible to
# the byte-diff goldens); -fno-sanitize-recover makes any out-of-bounds read/write or UB abort with a
# non-zero exit, failing the target. The default -O2 goldens compare only stdout and cannot see this class of latent
# memory/UB bug (sanitizer diagnostics go to stderr) -- this target is the guard for it, and would have
# caught the halt-path OOB (b3bd2ca). Slow (sanitizers + the heavy tests) and needs a sanitizer-capable
# compiler, so it is opt-in, not part of `make check`. Leak detection is off (the VM runs then exits;
# the -r loader's input buffer is intentionally held in a global until exit).
SANFLAGS := -std=c99 -fsanitize=address,undefined -fno-sanitize-recover=all -g
SAN_RUN = ASAN_OPTIONS=detect_leaks=0 $(TIMEOUT) $(if $(TIMEOUT),120) $(TMPDIR)/muxleq.san
# A curated set, not the whole golden suite: every test shares the same C interpreter, so running all
# 47 (~7 min under sanitizers) is redundant. These exercise the DISTINCT C paths -- chacha20 the heavy
# peek-ahead fusion, sieve array/loop memory, editor the block buffer, tasker the multitasker switch,
# collatz recursion, demo-does the self-modifying code field, eof the EOF-halt (vs the bye/negative-
# branch halt in the rest), rv32i-run the RV32I microcode + guest LB/SB + ecall -- plus the -r loader
# and guest execution via the RVELF paths below.
SANITIZE_FILES := chacha20 sieve editor tasker collatz demo-does eof rv32i-run
sanitize: $(if $(HAVE_RVCC),rvelf) stage0.c $(BIN)
	$(Q)$(CC) $(SANFLAGS) -I$(OUT) -o $(TMPDIR)/muxleq.san muxleq.c
	$(Q)$(foreach t,$(SANITIZE_FILES),\
	    $(PRINTF) "sanitize $(t) ... "; \
	    if $(SAN_RUN) < tests/$(t).fth >/dev/null 2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR or timeout\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	)
	$(Q)$(foreach e,$(RVELF_FILES),\
	    $(PRINTF) "sanitize rv32i/$(e).elf ... "; \
	    if $(SAN_RUN) -r $(RVELF_DIR)/$(e).elf >/dev/null 2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	)
	$(Q)$(foreach f,$(RVFLAT_FILES),\
	    $(PRINTF) "sanitize rv32i/$(f).bin ... "; \
	    if $(SAN_RUN) -r $(RVELF_DIR)/$(f).bin >/dev/null 2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	)
	$(Q)$(CC) $(SANFLAGS) -o $(TMPDIR)/rvopt.san $(RVOPT).c
	$(Q)$(foreach e,$(RVELF_FILES),\
	    $(PRINTF) "sanitize rvopt emit rv32i/$(e).elf ... "; \
	    if ASAN_OPTIONS=detect_leaks=0 sh -c '$(TMPDIR)/rvopt.san -mux $(RVELF_DIR)/$(e).elf >/dev/null \
	        && $(TMPDIR)/rvopt.san -dump $(RVELF_DIR)/$(e).elf | $(TMPDIR)/rvopt.san -check - >/dev/null' \
	        2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	)
	$(Q)if command -v python3 >/dev/null 2>&1; then \
	    $(PRINTF) "sanitize rvopt emit fuzz (every op path incl LB/LH/LHU/SH, SRL/SRA, JALR) ... "; \
	    if python3 scripts/rvopt-fuzz.py --rvopt $(TMPDIR)/rvopt.san --n 25 --body 14 --seed 1 \
	        >/dev/null 2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	else $(PRINTF) "sanitize rvopt emit fuzz: python3 absent, skipping\n"; fi

clean:
	$(RM) $(BIN)

distclean: clean
	$(RM) -r $(OUT)
