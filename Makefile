include mk/common.mk

# All generated artifacts (binaries, the baked image, the trace include, the
# relink sentinel) live under build/, so the working tree stays clean and build/
# is the single .gitignore entry. muxleq.c and rv32i.inc include the generated
# files with angle brackets (<stage0.c>, <rv32i-traces.inc>), so lookup skips the
# source directory and only -I$(OUT) resolves them: a stale root-level copy can
# never shadow the fresh build/ one. The flat remote profiling builds pass their
# own -I (build for bench-remote, . for duremark-remote, which regenerates flat).
OUT := build

CFLAGS += -O2 -std=c99
CFLAGS += -Wall -Wextra
# The RV32I toggle goes on the compile line, NOT into CFLAGS: a command-line
# `make CFLAGS=...` override replaces CFLAGS wholesale and would otherwise drop
# the -D, silently building the default despite ENABLE_RV32I=0.
ENABLE_RV32I ?= 1
ifeq ($(filter-out 0 1,$(ENABLE_RV32I)),)
else
$(error ENABLE_RV32I must be 0 or 1, got '$(ENABLE_RV32I)')
endif
RV32I_DEFS := -DENABLE_RV32I=$(ENABLE_RV32I)
ifeq ($(ENABLE_RV32I),1)
RV32I_TRACE_INC := $(OUT)/rv32i-traces.inc
endif
# Prefer clang for muxleq.c (musttail/preserve_none codegen), but honor an
# explicit CC=... the user sets on the command line or in the environment.
ifeq ($(origin CC),default)
MUXLEQ_CC ?= $(if $(shell command -v clang 2>/dev/null),clang,cc)
else
MUXLEQ_CC ?= $(CC)
endif

# Run serially: this build has no parallel steps to gain from "-j", and serial execution guarantees
# the "check"/"check-all" prerequisite order (the fast "budget" guard fails before the slow bootstrap).
.NOTPARALLEL:
.PHONY: FORCE help run bootstrap clean distclean check check-all budget golden golden-mandel bench profile-duremark verify-rv32i verify-microcode verify-rvopt-mux verify-rvopt-gate verify-duremark-rvopt verify-loader-rejects verify-mux32 verify-riscv-tests fuzz-rvopt sanitize duremark indent

BIN := $(OUT)/muxleq
RVOPT := $(OUT)/rvopt
MUXLEQ_FTH := $(OUT)/muxleq.fth
STAGE0_DEC := $(OUT)/stage0.dec
STAGE0_C := $(OUT)/stage0.c
STAGE1_DEC := $(OUT)/stage1.dec
ENABLE_SENTINEL := $(OUT)/.enable-rv32i
MUXLEQ_FORTH_MODULES := $(wildcard forth/*.fth)

# Bare-metal RISC-V toolchain prefix for the freestanding tests/rv32i programs
# and the vendored riscv-tests suite. Override as "make RVCROSS=...-". The RV32I
# .elf/.bin are generated under build/rv32i and never committed; when the
# toolchain is absent, the golden and rvopt gate skip their RV32I slices.
RVCROSS ?= riscv-none-elf-
RVELF_DIR := $(OUT)/rv32i
DUREMARK_ELF := $(RVELF_DIR)/duremark.elf
HAVE_RVCC := $(shell command -v $(RVCROSS)gcc 2>/dev/null)

all: $(BIN) ## Build the default muxleq VM.

help: ## List public make targets.
	$(Q)awk 'BEGIN { FS = ":.*##"; } /^[A-Za-z0-9_.-]+:.*##/ { printf "%-24s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

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

$(BIN): muxleq.c rv32i.inc $(RV32I_TRACE_INC) $(STAGE0_C) $(ENABLE_SENTINEL) | $(OUT)
	$(VECHO) "  CC+LD\t$@\n"
	$(Q)$(MUXLEQ_CC) $(CFLAGS) $(RV32I_DEFS) -I$(OUT) -o $@ muxleq.c

# ENABLE_RV32I only changes CFLAGS, which make does not track as a dependency,
# so `make ENABLE_RV32I=0` after a default build would not relink. Record the
# value in a sentinel rewritten only when it changes, and hang $(BIN) off it.
$(ENABLE_SENTINEL): FORCE | $(OUT)
	$(Q)printf '%s\n' '$(ENABLE_RV32I)' | cmp -s - $@ 2>/dev/null || \
	    printf '%s\n' '$(ENABLE_RV32I)' >$@

FORCE:

# Standalone RV32I->MUXLEQ optimizer. Built outside the image, so it costs zero
# self-host cells; not a prerequisite of the default build. The -dump/-check
# textual-IR round-trip is exercised (under ASan) by the sanitize target.
$(RVOPT): rvopt.c | $(OUT)
	$(VECHO) "  CC+LD\t$@\n"
	$(Q)$(CC) $(CFLAGS) -o $@ rvopt.c

# Native 16-bit MUXLEQ emission, the coverage NOT already in verify-rvopt-gate:
# the "-x" runner contract via a hand-written smoke image and the differential
# fuzz (random programs assembled in Python, native -x vs -r, no toolchain). The
# 7-demo + unopt differential lives in the gate (run by "make check"); this
# target is its synthetic-coverage complement.
verify-rvopt-mux: $(BIN) $(RVOPT) ## Verify 16-bit native rvopt emission.
	$(Q)$(RUN) ./$(BIN) -x tests/native-smoke.dec > $(TMPDIR)/native-smoke.out 2>&1 \
	    && cmp -s tests/expected/native-smoke.out $(TMPDIR)/native-smoke.out \
	    || { echo "verify-rvopt-mux: native-smoke output mismatch"; exit 1; }
	$(Q)if command -v python3 >/dev/null 2>&1; then \
	    python3 scripts/rvopt-fuzz.py --n 18 --body 20 --seed 1 >/dev/null \
	        || { echo "verify-rvopt-mux: differential fuzz FAILED (see stderr above)"; exit 1; }; \
	else $(PRINTF) "verify-rvopt-mux: python3 absent, skipping differential fuzz\n"; fi
	$(Q)$(PRINTF) "verify-rvopt-mux: -x smoke + differential fuzz\n"

# Wide (32-bit-cell) native emission, the coverage NOT already in
# verify-rvopt-gate: the "-x32" runner contract via a hand-written smoke image
# (MOVE, SUBLEQ arithmetic + branch-to-halt, PUT at the 32-bit encoding) and the
# wide differential fuzz. The 7-demo + unopt differential lives in the gate (run
# by "make check").
verify-mux32: $(BIN) $(RVOPT) ## Verify wide 32-bit-cell native emission.
	$(Q)$(RUN) ./$(BIN) -x32 tests/mux32-smoke.dec > $(TMPDIR)/mux32-smoke.out 2>&1 \
	    && cmp -s tests/expected/mux32-smoke.out $(TMPDIR)/mux32-smoke.out \
	    || { echo "verify-mux32: -x32 wide-VM smoke output mismatch"; exit 1; }
	$(Q)if command -v python3 >/dev/null 2>&1; then \
	    python3 scripts/rvopt-fuzz.py --wide --n 18 --body 20 --seed 1 >/dev/null \
	        || { echo "verify-mux32: -mux32 differential fuzz FAILED (see stderr above)"; exit 1; }; \
	else $(PRINTF) "verify-mux32: python3 absent, skipping -mux32 differential fuzz\n"; fi
	$(Q)$(PRINTF) "verify-mux32: -x32 smoke + wide differential fuzz\n"

# Fast rvopt correctness slice for the pre-commit gate. rvopt is built OUTSIDE
# the image, so "make check"/bootstrap never touched it before: a non-compiling
# or miscompiling optimizer passed the gate silently. This wires the
# differential oracle in cheaply: every demo, lowered by BOTH backends (-mux/-x
# 16-bit and -mux32/-x32 wide), must reproduce the "-r" interpreter
# byte-for-byte; unopt adds the one register-promotion loop the -O2 demos lack
# (0 promotable loops). ~15 s (no fuzz, no rv32ui): the exhaustive layers stay
# in verify-rvopt-mux/verify-riscv-tests and check-all. The demo binaries are
# built from source into build/rv32i, so the differential needs the RISC-V
# toolchain and skips when it is absent; the toolchain-free JALR-reject checks
# always run.
verify-rvopt-gate: $(BIN) $(RVOPT) $(if $(HAVE_RVCC),rvelf $(RVELF_DIR)/unopt.elf) ## Run fast rvopt differential checks.
	$(Q)if [ -n "$(HAVE_RVCC)" ]; then \
	    for e in $(RVELF_FILES); do \
	        ./$(RVOPT) -mux $(RVELF_DIR)/$$e.elf > $(TMPDIR)/gate-$$e.dec 2>/dev/null \
	            && $(RUN) ./$(BIN) -x $(TMPDIR)/gate-$$e.dec > $(TMPDIR)/gate-$$e.x 2>&1 \
	            && ./$(RVOPT) -mux32 $(RVELF_DIR)/$$e.elf > $(TMPDIR)/gate-$$e.d32 2>/dev/null \
	            && $(RUN) ./$(BIN) -x32 $(TMPDIR)/gate-$$e.d32 > $(TMPDIR)/gate-$$e.x32 2>&1 \
	            && ./$(BIN) -r $(RVELF_DIR)/$$e.elf > $(TMPDIR)/gate-$$e.r 2>&1 \
	            && cmp -s $(TMPDIR)/gate-$$e.x $(TMPDIR)/gate-$$e.r \
	            && cmp -s $(TMPDIR)/gate-$$e.x32 $(TMPDIR)/gate-$$e.r \
	            || { echo "verify-rvopt-gate: native $$e (-x/-x32) differs from -r"; exit 1; }; \
	    done; \
	    ./$(RVOPT) -mux $(RVELF_DIR)/unopt.elf > $(TMPDIR)/gate-unopt.dec 2>/dev/null \
	        && $(RUN) ./$(BIN) -x $(TMPDIR)/gate-unopt.dec > $(TMPDIR)/gate-unopt.x 2>&1 \
	        && ./$(RVOPT) -mux32 $(RVELF_DIR)/unopt.elf > $(TMPDIR)/gate-unopt.d32 2>/dev/null \
	        && $(RUN) ./$(BIN) -x32 $(TMPDIR)/gate-unopt.d32 > $(TMPDIR)/gate-unopt.x32 2>&1 \
	        && ./$(BIN) -r $(RVELF_DIR)/unopt.elf > $(TMPDIR)/gate-unopt.r 2>&1 \
	        && cmp -s $(TMPDIR)/gate-unopt.x $(TMPDIR)/gate-unopt.r \
	        && cmp -s $(TMPDIR)/gate-unopt.x32 $(TMPDIR)/gate-unopt.r \
	        || { echo "verify-rvopt-gate: unopt (-x/-x32, register promotion) differs from -r"; exit 1; }; \
	else $(PRINTF) "verify-rvopt-gate: RVELF/unopt differential [SKIP: no $(RVCROSS)gcc]\n"; fi
	$(Q)printf '\223\002\000\001\023\003\000\000\263\202\142\000\147\200\002\000\223\010\320\005\023\005\000\000\163\000\000\000' > $(TMPDIR)/rvopt-jalr-runtime.bin
	$(Q)printf '\357\000\100\001\357\000\000\001\223\010\320\005\023\005\000\000\163\000\000\000\147\200\000\000' > $(TMPDIR)/rvopt-jalr-multiret.bin
	$(Q)$(RUN) ./$(BIN) -r $(TMPDIR)/rvopt-jalr-runtime.bin >/dev/null 2>&1 \
	    && ! ./$(RVOPT) -mux $(TMPDIR)/rvopt-jalr-runtime.bin >/dev/null 2>$(TMPDIR)/rvopt-reject.err \
	    && grep -q 'unsupported JALR at pc 12' $(TMPDIR)/rvopt-reject.err \
	    && ! ./$(RVOPT) -mux32 $(TMPDIR)/rvopt-jalr-runtime.bin >/dev/null 2>$(TMPDIR)/rvopt-reject.err \
	    && grep -q 'unsupported op at pc 12' $(TMPDIR)/rvopt-reject.err \
	    || { echo "verify-rvopt-gate: -r must run runtime JALR AND -mux/-mux32 must reject it"; exit 1; }
	$(Q)$(RUN) ./$(BIN) -r $(TMPDIR)/rvopt-jalr-multiret.bin >/dev/null 2>&1 \
	    && ! ./$(RVOPT) -mux $(TMPDIR)/rvopt-jalr-multiret.bin >/dev/null 2>$(TMPDIR)/rvopt-reject.err \
	    && grep -q 'unsupported JALR at pc 20' $(TMPDIR)/rvopt-reject.err \
	    && ./$(RVOPT) -mux32 $(TMPDIR)/rvopt-jalr-multiret.bin > $(TMPDIR)/rvopt-jalr-multiret.d32 \
	    && $(RUN) ./$(BIN) -x32 $(TMPDIR)/rvopt-jalr-multiret.d32 > $(TMPDIR)/rvopt-jalr-multiret.x32 2>&1 \
	    && ./$(BIN) -r $(TMPDIR)/rvopt-jalr-multiret.bin > $(TMPDIR)/rvopt-jalr-multiret.r 2>&1 \
	    && cmp -s $(TMPDIR)/rvopt-jalr-multiret.x32 $(TMPDIR)/rvopt-jalr-multiret.r \
	    || { echo "verify-rvopt-gate: multi-ret JALR -mux32 differs from -r"; exit 1; }
	$(Q)$(PRINTF) "verify-rvopt-gate: native/JALR "; $(call notice, [OK])

verify-duremark-rvopt: $(RVOPT) $(if $(HAVE_RVCC),$(DUREMARK_ELF)) ## Verify current rvopt DureMark limits.
	$(Q)if [ -z "$(HAVE_RVCC)" ]; then \
	    $(PRINTF) "verify-duremark-rvopt: DureMark limits [SKIP: no $(RVCROSS)gcc]\n"; \
	else \
	    if ./$(RVOPT) -mux $(DUREMARK_ELF) >/dev/null 2>$(TMPDIR)/duremark-rvopt.err \
	        || ! grep -q 'unsupported JALR at pc' $(TMPDIR)/duremark-rvopt.err; then \
	        echo "verify-duremark-rvopt: -mux must reject DureMark runtime JALR"; exit 1; fi; \
	    if ./$(RVOPT) -mux32 $(DUREMARK_ELF) >/dev/null 2>$(TMPDIR)/duremark-rvopt.err \
	        || ! grep -q 'unsupported op at pc' $(TMPDIR)/duremark-rvopt.err; then \
	        echo "verify-duremark-rvopt: -mux32 must reject unresolved DureMark ecall"; exit 1; fi; \
	    $(PRINTF) "verify-duremark-rvopt: DureMark limits "; $(call notice, [OK]); \
	fi

verify-loader-rejects: $(BIN) tests/loader-bad-token.dec tests/loader-out-of-range.dec tests/loader-bad-operand.dec tests/loader-bad-fused-operand.dec ## Verify malformed image rejection.
	$(Q)for f in tests/loader-bad-token.dec tests/loader-out-of-range.dec; do \
	    ! ./$(BIN) -x $$f >/dev/null 2>$(TMPDIR)/loader.err \
	        && grep -q 'bad cell' $(TMPDIR)/loader.err \
	        || { echo "verify-loader-rejects: -x accepted $$f"; exit 1; }; \
	    ! ./$(BIN) -x32 $$f >/dev/null 2>$(TMPDIR)/loader.err \
	        && grep -q 'bad cell' $(TMPDIR)/loader.err \
	        || { echo "verify-loader-rejects: -x32 accepted $$f"; exit 1; }; \
	done
	$(Q)! ./$(BIN) -x tests/loader-bad-operand.dec >/dev/null 2>$(TMPDIR)/loader.err \
	    && grep -q 'bad operand a=32768 at pc 0' $(TMPDIR)/loader.err \
	    || { echo "verify-loader-rejects: -x accepted invalid operand"; exit 1; }
	$(Q)! ./$(BIN) -x tests/loader-bad-fused-operand.dec >/dev/null 2>$(TMPDIR)/loader.err \
	    && grep -q 'bad operand a=32768 at pc 3' $(TMPDIR)/loader.err \
	    || { echo "verify-loader-rejects: -x accepted invalid fused operand"; exit 1; }
	$(Q)yes 0 | head -n 32769 > $(TMPDIR)/loader-oversized.dec; \
	    ! ./$(BIN) -x $(TMPDIR)/loader-oversized.dec >/dev/null 2>$(TMPDIR)/loader.err \
	        && grep -q 'exceeds' $(TMPDIR)/loader.err \
	        || { echo "verify-loader-rejects: -x accepted oversized image"; exit 1; }
	$(Q)yes 0 | head -n 2097153 > $(TMPDIR)/loader-oversized32.dec; \
	    ! ./$(BIN) -x32 $(TMPDIR)/loader-oversized32.dec >/dev/null 2>$(TMPDIR)/loader.err \
	        && grep -q 'exceeds' $(TMPDIR)/loader.err \
	        || { echo "verify-loader-rejects: -x32 accepted oversized image"; exit 1; }
	$(Q)$(PRINTF) "verify-loader-rejects: malformed -x/-x32 images rejected "; $(call notice, [OK])

# Official RV32I compliance: the riscv-tests rv32ui suite (BSD), shallow-cloned
# and pinned by the sub-Makefile, built with a muxleq env (entry 0, stdout
# PASS/FAIL) and run through -r, the native -mux emitter, AND the wide -mux32
# emitter (which reaches ld_st, over the 16-bit ceiling). Needs the RISC-V
# toolchain; skips gracefully when absent, like the differential fuzz above.
verify-riscv-tests: $(BIN) $(RVOPT) ## Run rv32ui compliance tests when toolchain exists.
	$(Q)if command -v $(RVCROSS)gcc >/dev/null 2>&1; then \
	    $(MAKE) --no-print-directory -C tests/rv32i/riscv-tests check check-mux check-x32 \
	        CROSS=$(RVCROSS) MUXLEQ=$(CURDIR)/$(BIN) RVOPT=$(CURDIR)/$(RVOPT) \
	        TIMEOUT="$(TIMEOUT)" RUN_TIMEOUT="$(RUN_TIMEOUT)" \
	        || { echo "verify-riscv-tests: a rv32ui compliance test FAILED"; exit 1; }; \
	else $(PRINTF) "verify-riscv-tests: RISC-V toolchain ($(RVCROSS)gcc) absent, skipping rv32ui suite\n"; fi

# Deep on-demand differential fuzz: random programs (ALU/shift/immediate +
# load/store round-trips + forward branches) with random 32-bit seeds, native -x
# vs the -r interpreter. Override N/BODY/SEED, e.g. "make fuzz-rvopt N=200 SEED=9".
# BODY default 24 keeps ~88% of programs under the 32768-cell image (bigger just
# skips more, since load/store and branch ops are 2 words each). Failure prints a
# --seed/--only/--body repro command.
fuzz-rvopt: $(BIN) $(RVOPT) ## Differential-fuzz rvopt emitted programs.
	$(Q)python3 scripts/rvopt-fuzz.py --n $(if $(N),$(N),64) --body $(if $(BODY),$(BODY),24) --seed $(if $(SEED),$(SEED),1)

run: $(BIN) ## Run the interactive VM.
	$(Q)./$(BIN)

# Source formatter and lint. C sources are reformatted in place with
# clang-format (the project .clang-format), Python scripts with black. The Forth
# half lints the forth/ modules and the .fth tests: it catches the multi-line
# "( )" comment that compiles under gforth yet breaks the self-host bootstrap
# with -13, plus hard tabs, and strips trailing whitespace with --fix. Reflowing
# Forth leading whitespace is opt-in (scripts/forth-indent.py --reindent), NOT
# run here, because the metacompiler's label and fall-through idioms are hand-
# tuned and do not nest mechanically. Each half degrades to a skip when its tool
# is absent. The generated $(MUXLEQ_FTH) is not linted; its modules are.
CFMT_SRC := muxleq.c rv32i.inc rvopt.c
PYFMT_SRC := $(wildcard scripts/*.py)
FORTH_SRC := $(MUXLEQ_FORTH_MODULES) $(wildcard tests/*.fth)
indent: ## Format C/Python and lint Forth sources.
	$(Q)if command -v clang-format >/dev/null 2>&1; then \
	    clang-format -i $(CFMT_SRC) || exit 1; \
	    $(PRINTF) "indent: clang-format C sources "; $(call notice, [OK]); \
	else $(PRINTF) "indent: clang-format absent, skipping C sources\n"; fi
	$(Q)if command -v black >/dev/null 2>&1; then \
	    black -q $(PYFMT_SRC) || exit 1; \
	    $(PRINTF) "indent: black Python sources "; $(call notice, [OK]); \
	else $(PRINTF) "indent: black absent, skipping Python sources\n"; fi
	$(Q)if command -v python3 >/dev/null 2>&1; then \
	    python3 scripts/forth-indent.py --fix $(FORTH_SRC) >/dev/null; \
	    python3 scripts/forth-indent.py $(FORTH_SRC) || exit 1; \
	    $(PRINTF) "indent: Forth sources clean "; $(call notice, [OK]); \
	else $(PRINTF) "indent: python3 absent, skipping Forth lint\n"; fi

$(STAGE0_C): $(STAGE0_DEC) | $(OUT)
	$(Q)sed 's/$$/,/' $^ > $@

$(OUT)/rv32i-traces.inc: $(STAGE0_DEC) rv32i-traces.inc.in scripts/gen-rv32i-traces.py | $(OUT)
	$(VECHO) "  GEN\t$@\n"
	$(Q)python3 scripts/gen-rv32i-traces.py $(STAGE0_DEC) rv32i-traces.inc.in $@

$(MUXLEQ_FTH): $(MUXLEQ_FORTH_MODULES) scripts/update-muxleq-fth.sh | $(OUT)
	$(Q)sh scripts/update-muxleq-fth.sh $@ $(MUXLEQ_FORTH_MODULES)

$(STAGE0_DEC): $(MUXLEQ_FTH) | $(OUT)
	$(VECHO) "  FORTH\t$@\n"
	$(Q)gforth $< > $@

# Golden-output regression suite: each test's stdout must match
# tests/expected/<name>.out byte-for-byte. A substring grep would miss most
# drift; this is the safety net for interpreter/fusion work. "define" compiles
# and runs new words at runtime (the decode-once guard).
GOLDEN_FILES := \
	loops radix sqrt \
	fibonacci bitcount clz crc log arith prng-bench \
	life rainbow control editor \
	define chacha20 scheduler tasker sieve collatz base recurse rot13 double sort heap except eof \
	eforth-hello eforth-f eforth-loops eforth-trig eforth-multiply \
	eforth-array eforth-does eforth-ascii \
	eforth-text eforth-money eforth-temp eforth-weather eforth-calendar \
	eforth-fig eforth-stack eforth-msgpass eforth-value rv32i-spec rv32i-run

# Bound each test run so a mis-fused interpreter that loops forever fails the
# gate instead of hanging it -- an infinite loop is the likeliest fusion bug.
# Degrade to no bound if timeout(1)/gtimeout is unavailable.
TIMEOUT := $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
RUN_TIMEOUT ?= 60
RUN = $(TIMEOUT) $(if $(TIMEOUT),$(RUN_TIMEOUT))
GOLDEN_RUN = $(RUN) ./$(BIN)

# RV32I programs exercised end-to-end through the "-r" ELF loader. Built from
# source into build/rv32i (see rvelf); output is compared against
# tests/expected/rv32i-<name>.out. Needs the RISC-V toolchain, so the golden
# slice skips them when it is absent.
RVELF_FILES := hello fibonacci primes crc16 mul bgcd bsort
# Flat (objcopy -O binary) programs, to exercise the -r flat-binary path as well
# as the ELF path. hello.bin is the same program as hello.elf, so it reuses
# tests/expected/rv32i-hello.out.
RVFLAT_FILES := hello
RVELF_RUN = $(RUN) ./$(BIN) -r

golden: $(BIN) $(if $(HAVE_RVCC),rvelf) ## Run byte-exact golden output tests.
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
	$(Q)$(if $(HAVE_RVCC),$(foreach e,$(RVELF_FILES),\
	    $(PRINTF) "golden rv32i/$(e).elf ... "; \
	    if $(RVELF_RUN) $(RVELF_DIR)/$(e).elf > $(TMPDIR)/golden.out 2>/dev/null \
	        && cmp -s tests/expected/rv32i-$(e).out $(TMPDIR)/golden.out; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "DRIFT or VM error\n"; exit 1; \
	    fi; \
	),$(PRINTF) "golden rv32i/* ... [SKIP: no $(RVCROSS)gcc]\n")
	$(Q)$(if $(HAVE_RVCC),$(foreach f,$(RVFLAT_FILES),\
	    $(PRINTF) "golden rv32i/$(f).bin ... "; \
	    if $(RVELF_RUN) $(RVELF_DIR)/$(f).bin > $(TMPDIR)/golden.out 2>/dev/null \
	        && cmp -s tests/expected/rv32i-$(f).out $(TMPDIR)/golden.out; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "DRIFT or VM error\n"; exit 1; \
	    fi; \
	))

golden-mandel: $(BIN) tests/expected/mandel-prefix.out ## Check the bounded Mandelbrot prefix.
	$(Q)test -n "$(TIMEOUT)" || { echo "golden-mandel: timeout(1)/gtimeout required"; exit 1; }
	$(Q)command -v stdbuf >/dev/null 2>&1 || { echo "golden-mandel: stdbuf required for killed-run stdout"; exit 1; }
	$(Q)bytes=$$(wc -c < tests/expected/mandel-prefix.out); \
	    $(TIMEOUT) $(if $(TIMEOUT),$(RUN_TIMEOUT)) stdbuf -o0 ./$(BIN) < tests/mandel.fth 2>/dev/null \
	        | tr -d '\r' | head -c $$bytes > $(TMPDIR)/mandel-prefix.out; \
	    cmp -s tests/expected/mandel-prefix.out $(TMPDIR)/mandel-prefix.out \
	        || { echo "golden-mandel: prefix drift"; exit 1; }
	$(Q)$(PRINTF) "golden-mandel: bounded mandel prefix "; $(call notice, [OK])
# The pre-commit gate: cell-budget guard + byte-exact golden diff + the rvopt native
# differential (the AOT optimizer's -x/-x32 output must match -r) + the self-hosting
# proof. rvopt runs before the slow bootstrap so an optimizer regression fails fast.
check: budget golden verify-rvopt-gate bootstrap ## Run the fast pre-commit gate.

# Self-host ceiling guard. The image + its re-assembled copy + the metacompiler dictionary must all
# fit 32768 cells (empirical hard ceiling ~12888, where bootstrap starts to fail). Fail loudly HERE if
# stage0.dec exceeds the budget, instead of a cryptic -13/hang deep in "make bootstrap". Bump MAX_CELLS
# consciously (with evidence bootstrap still holds) if the image legitimately needs to grow.
MAX_CELLS ?= 12500
budget: $(STAGE0_DEC) ## Check the self-host image cell budget.
	$(Q)cells=$$(grep -c . $(STAGE0_DEC)); \
	    if [ "$$cells" -gt $(MAX_CELLS) ]; then \
	        $(PRINTF) "budget: image is $$cells cells, over the $(MAX_CELLS)-cell budget (ceiling ~12888) -- shrink the image or bump MAX_CELLS if bootstrap still holds\n"; \
	        exit 1; \
	    else $(PRINTF) "budget: image $$cells / $(MAX_CELLS) cells "; $(call notice, [OK]); fi

# DureMark benchmark on the RV32I simulator (upstream list+matrix+state workloads, vendored under
# tests/rv32i/duremark/). ~3.2 G dispatched MUXLEQ ops / ~16 s for one iteration -- a benchmark-scale
# load, deliberately OUT of the fast "make check"; it runs in check-all and on demand. Needs the 32 KiB
# guest window (its ~4.5 KB image never fit the old 1 KiB). The checksum is byte-identical to a native
# build, so a drift means the RV32I microcode or the guest-RAM window regressed.
duremark: $(BIN) $(if $(HAVE_RVCC),$(DUREMARK_ELF)) ## Run the RV32I DureMark benchmark.
	$(Q)if [ -z "$(HAVE_RVCC)" ]; then $(PRINTF) "duremark rv32i ... [SKIP: no $(RVCROSS)gcc]\n"; else \
	    $(PRINTF) "duremark rv32i ... "; \
	    if $(TIMEOUT) $(if $(TIMEOUT),90) ./$(BIN) -r $(DUREMARK_ELF) > $(TMPDIR)/duremark.out 2>/dev/null \
	        && cmp -s tests/expected/duremark.out $(TMPDIR)/duremark.out; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "DRIFT or VM error\n"; exit 1; fi; fi

# Deep pre-release gate: the standard check plus the slow/opt-in exhaustive checks (RV32I conformance,
# the Z3 ALU proof, the ASan+UBSan run, and the DureMark benchmark). Minutes; needs z3-solver + a
# sanitizer-capable compiler.
check-all: check verify-rv32i verify-microcode verify-rvopt-mux verify-mux32 verify-duremark-rvopt verify-loader-rejects verify-riscv-tests sanitize duremark ## Run deep validation.

# bootstrapping
bootstrap: $(STAGE0_DEC) $(STAGE1_DEC) ## Prove self-host bootstrap is byte-exact.
	$(Q)if diff $(STAGE0_DEC) $(STAGE1_DEC); then \
	$(call notice, [OK]); \
	else \
	$(PRINTF) "Unable to bootstrap. Aborting"; \
	exit 1; \
	fi;

$(STAGE1_DEC): $(BIN) $(MUXLEQ_FTH) | $(OUT)
	$(VECHO)  "Bootstrapping... "
	$(Q)./$(BIN) < $(MUXLEQ_FTH) > $@

TMPDIR := $(shell mktemp -d)

# Consolidated throughput benchmark. Builds the VM on a quiet remote host (node1
# by default -- localhost load makes wall-clock timing unreliable) and reports, per
# workload, Mops/s = million dispatched instructions / best user second (one "op"
# is one dispatch() entry -- -s does not count fused inline ops, so the raw op count
# is higher). The DETERMINISTIC dispatch count (exact, machine-independent) over the
# best-of-REPS uninstrumented
# time, so the raw count is always turned into a precise, comparable rate rather than
# shown bare. All params pass through the environment to scripts/bench.sh (which
# defaults them): "BENCH_HOST=node2 TIME=20000 REPS=9 make bench" and "make bench
# TIME=20000" both work. scripts/bench.sh ships the sources and runs bench-remote.sh.
bench: $(STAGE0_C) $(RV32I_TRACE_INC) ## Run remote throughput benchmarks.
	$(Q)ENABLE_RV32I=$(ENABLE_RV32I) sh scripts/bench.sh

profile-duremark: $(MUXLEQ_FTH) ## Profile DureMark on the remote host.
	$(Q)sh scripts/duremark-profile.sh

# RV32I instruction-level conformance. The official riscv-arch-test ELFs can't run
# on this 16-bit substrate (they link past the 32767-cell guest window), so
# compliance is validated per-instruction: scripts/rv32i-conformance.py
# runs an independent Python reference model (anchored to tests/rv32i-spec.fth's
# Codex-verified vectors via --verify-model) and drives the SAME operands through
# the :a rvstep microcode, self-checking each. Slow (thousands of vectors through
# the eForth text interpreter, minutes) so it is NOT part of "make check" -- run it
# explicitly. Any FAIL or VM error (a stray "?") fails the target.
verify-rv32i: $(BIN) ## Run generated RV32I instruction conformance.
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
# "make check".
verify-microcode: ## Prove RV32I microcode with the Python/Z3 model.
	$(Q)python3 scripts/verify-microcode.py

# Build with AddressSanitizer + UndefinedBehaviorSanitizer and run every golden program plus the -r
# paths AND the standalone rvopt emitter (its own malloc + na[]/graph pointer arithmetic, invisible to
# the byte-diff goldens); -fno-sanitize-recover makes any out-of-bounds read/write or UB abort with a
# non-zero exit, failing the target. The default -O2 goldens compare only stdout and cannot see this class of latent
# memory/UB bug (sanitizer diagnostics go to stderr) -- this target is the guard for it, and would have
# caught the halt-path OOB. Build at -O2 so the threaded interpreter keeps the same tail-call
# shape as the release binary; UBSan remains best-effort after optimization. Slow (sanitizers + the heavy
# tests) and needs a sanitizer-capable compiler, so it is opt-in, not part of "make check". Leak detection
# is off (the VM runs then exits; the -r loader's input buffer is intentionally held in a global until exit).
SANFLAGS := -O2 -std=c99 -fsanitize=address,undefined -fno-sanitize-recover=all -g
SAN_RUN = ASAN_OPTIONS=detect_leaks=0 $(TIMEOUT) $(if $(TIMEOUT),120) $(TMPDIR)/muxleq.san
# A curated set, not the whole golden suite: every test shares the same C interpreter, so running all
# 47 (~7 min under sanitizers) is redundant. These exercise the DISTINCT C paths -- chacha20 the heavy
# peek-ahead fusion, sieve array/loop memory, editor the block buffer, tasker the multitasker switch,
# collatz recursion, eforth-does the self-modifying code field, eof the EOF-halt (vs the bye/negative-
# branch halt in the rest), rv32i-run the RV32I microcode + guest LB/SB + ecall -- plus the -r loader
# and guest execution via the RVELF paths below.
SANITIZE_FILES := chacha20 sieve editor tasker collatz eforth-does eof rv32i-run
# sanitize exercises -r, the rv32i-run microcode, and the rvopt differential
# (the last drives the normal $(BIN), which is a stub under ENABLE_RV32I=0), so
# the suite only makes sense with RV32I enabled. Refuse other modes with a clear
# message instead of failing obscurely mid-suite.
sanitize: $(STAGE0_C) $(RV32I_TRACE_INC) $(BIN) $(RVOPT) $(if $(HAVE_RVCC),rvelf) tests/loader-bad-token.dec tests/loader-out-of-range.dec tests/loader-bad-operand.dec tests/loader-bad-fused-operand.dec ## Run ASan/UBSan validation.
	$(Q)[ "$(ENABLE_RV32I)" = 1 ] || { echo "make sanitize requires ENABLE_RV32I=1 (it exercises -r and the RV32I paths)"; exit 1; }
	$(Q)$(MUXLEQ_CC) $(SANFLAGS) $(RV32I_DEFS) -I$(OUT) -o $(TMPDIR)/muxleq.san muxleq.c
	$(Q)$(foreach t,$(SANITIZE_FILES),\
	    $(PRINTF) "sanitize $(t) ... "; \
	    if $(SAN_RUN) < tests/$(t).fth >/dev/null 2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR or timeout\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	)
	$(Q)$(if $(HAVE_RVCC),$(foreach e,$(RVELF_FILES),\
	    $(PRINTF) "sanitize rv32i/$(e).elf ... "; \
	    if $(SAN_RUN) -r $(RVELF_DIR)/$(e).elf >/dev/null 2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	),$(PRINTF) "sanitize rv32i/* ... [SKIP: no $(RVCROSS)gcc]\n")
	$(Q)$(if $(HAVE_RVCC),$(foreach f,$(RVFLAT_FILES),\
	    $(PRINTF) "sanitize rv32i/$(f).bin ... "; \
	    if $(SAN_RUN) -r $(RVELF_DIR)/$(f).bin >/dev/null 2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	))
	# The emitted-image runners: -r only sanitizes the interpreter. Run each
	# demo's native image through muxleq.san -x (16-bit) and -x32 (wide) so the
	# run/run32 loops, load_muxleq32 parsing/allocation, index masking, and SMC
	# operand patching are ASan/UBSan-checked -- the -O2 goldens compare only
	# stdout and are blind to an out-of-bounds that does not change output.
	$(Q)$(if $(HAVE_RVCC),$(foreach e,$(RVELF_FILES),\
	    $(PRINTF) "sanitize -x/-x32 native runner rv32i/$(e).elf ... "; \
	    if ./$(RVOPT) -mux $(RVELF_DIR)/$(e).elf > $(TMPDIR)/san-x.dec 2>$(TMPDIR)/san.err \
	        && $(SAN_RUN) -x $(TMPDIR)/san-x.dec >/dev/null 2>$(TMPDIR)/san.err \
	        && ./$(RVOPT) -mux32 $(RVELF_DIR)/$(e).elf > $(TMPDIR)/san-x32.dec 2>$(TMPDIR)/san.err \
	        && $(SAN_RUN) -x32 $(TMPDIR)/san-x32.dec >/dev/null 2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	))
	$(Q)$(PRINTF) "sanitize loader rejects ... "; \
	    ! $(SAN_RUN) -x tests/loader-bad-token.dec >/dev/null 2>$(TMPDIR)/san.err \
	        && grep -q 'bad cell' $(TMPDIR)/san.err \
	        && ! grep -Eq 'ERROR: AddressSanitizer|runtime error:' $(TMPDIR)/san.err \
	        && ! $(SAN_RUN) -x32 tests/loader-out-of-range.dec >/dev/null 2>$(TMPDIR)/san.err \
	        && grep -q 'bad cell' $(TMPDIR)/san.err \
	        && ! grep -Eq 'ERROR: AddressSanitizer|runtime error:' $(TMPDIR)/san.err \
	        && ! $(SAN_RUN) -x tests/loader-bad-operand.dec >/dev/null 2>$(TMPDIR)/san.err \
	        && grep -q 'bad operand a=32768 at pc 0' $(TMPDIR)/san.err \
	        && ! grep -Eq 'ERROR: AddressSanitizer|runtime error:' $(TMPDIR)/san.err \
	        && ! $(SAN_RUN) -x tests/loader-bad-fused-operand.dec >/dev/null 2>$(TMPDIR)/san.err \
	        && grep -q 'bad operand a=32768 at pc 3' $(TMPDIR)/san.err \
	        && ! grep -Eq 'ERROR: AddressSanitizer|runtime error:' $(TMPDIR)/san.err \
	        || { $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; }; \
	    $(call notice, [OK])
	$(Q)$(CC) $(SANFLAGS) -o $(TMPDIR)/rvopt.san rvopt.c
	$(Q)$(if $(HAVE_RVCC),$(foreach e,$(RVELF_FILES),\
	    $(PRINTF) "sanitize rvopt emit rv32i/$(e).elf ... "; \
	    if ASAN_OPTIONS=detect_leaks=0 sh -c '$(TMPDIR)/rvopt.san -mux $(RVELF_DIR)/$(e).elf >/dev/null \
	        && $(TMPDIR)/rvopt.san -dump $(RVELF_DIR)/$(e).elf | $(TMPDIR)/rvopt.san -check - >/dev/null' \
	        2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	),$(PRINTF) "sanitize rvopt emit rv32i/* ... [SKIP: no $(RVCROSS)gcc]\n")
	$(Q)if command -v python3 >/dev/null 2>&1; then \
	    $(PRINTF) "sanitize rvopt emit fuzz (every op path incl LB/LH/LHU/SH, SRL/SRA, JALR) ... "; \
	    if python3 scripts/rvopt-fuzz.py --rvopt $(TMPDIR)/rvopt.san --n 25 --body 14 --seed 1 \
	        >/dev/null 2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	    $(PRINTF) "sanitize rvopt -mux32 emit fuzz (wide backend: SMC patch, write loop, shift loops) ... "; \
	    if python3 scripts/rvopt-fuzz.py --wide --rvopt $(TMPDIR)/rvopt.san --n 25 --body 14 --seed 1 \
	        >/dev/null 2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	else $(PRINTF) "sanitize rvopt emit fuzz: python3 absent, skipping\n"; fi

clean: ## Remove built binaries and the relink sentinel.
	$(RM) $(BIN) $(RVOPT) $(ENABLE_SENTINEL)

distclean: clean ## Remove the whole build/ tree (generated image too).
	$(RM) -r $(OUT)
