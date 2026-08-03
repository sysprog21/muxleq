include mk/common.mk

# All generated artifacts (binaries and the baked image) live under build/, so
# the working tree stays clean and build/ is the single .gitignore entry.
# muxleq.c includes the generated file with angle brackets (<stage0.c>), so lookup skips the
# source directory and only -I$(OUT) resolves them: a stale root-level copy can
# never shadow the fresh build/ one.
OUT := build

CFLAGS += -O2 -std=c99
CFLAGS += -Wall -Wextra
# Prefer clang for muxleq.c when available -- it is the reference compiler the
# interpreter's hot loop is benchmarked under -- but honor an explicit CC=... the
# user sets on the command line or in the environment.
ifeq ($(origin CC),default)
MUXLEQ_CC ?= $(if $(shell command -v clang 2>/dev/null),clang,cc)
else
MUXLEQ_CC ?= $(CC)
endif

# Run serially: this build has no parallel steps to gain from "-j", and serial execution guarantees
# the "check"/"check-all" prerequisite order.
.NOTPARALLEL:
.PHONY: FORCE help run bootstrap clean distclean check check-all golden golden-see golden-pty golden-mandel verify-loader-rejects verify-mux verify-eforth-stage0 verify-eforth-repl fuzz-rvopt sanitize indent check-format rv32i rv32i-check rv32i-prebuilt rv32i-auto verify-prebuilt

BIN := $(OUT)/muxleq
RVOPT := $(OUT)/rvopt
MUXLEQ_FTH := $(OUT)/muxleq.fth
STAGE0_DEC := $(OUT)/stage0.dec
STAGE0_C := $(OUT)/stage0.c
STAGE1_DEC := $(OUT)/stage1.dec
MUXLEQ_FORTH_MODULES := $(wildcard forth/*.fth)

all: $(BIN) ## Build the default muxleq VM.

help: ## List public make targets.
	$(Q)awk 'BEGIN { FS = ":.*##"; } /^[A-Za-z0-9_.-]+:.*##/ { printf "%-24s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

$(OUT):
	$(Q)mkdir -p $@

$(BIN): muxleq.c $(STAGE0_C) | $(OUT)
	$(VECHO) "  CC+LD\t$@\n"
	$(Q)$(MUXLEQ_CC) $(CFLAGS) -I$(OUT) -o $@ muxleq.c

FORCE:

# Standalone RV32I->MUXLEQ optimizer. Built outside the image, so it costs zero
# self-host cells; not a prerequisite of the default build. The dump/check
# textual-IR round-trip is exercised (under ASan) by the sanitize target.
$(RVOPT): rvopt.c | $(OUT)
	$(VECHO) "  CC+LD\t$@\n"
	$(Q)$(CC) $(CFLAGS) -o $@ rvopt.c

# Encoding cases for the two opcodes whose fields decode_word has to check: JALR
# takes funct3 000 only, and SYSTEM takes just the exact ecall and ebreak words.
# Each case is "name:comma-separated hex words"; the li ahead of the tested word
# is the constant the resolver would otherwise fold into a jump or an exit.
# ebreak decodes: analyze_syscalls() marks it SYS_BAD, not the decode gate.
# The last four are control-flow cases, not encodings: an ecall entered by a
# jump or by a return past its own li a7, an unresolvable jalr reached only
# through a second one, and a target a later leader invalidates.
RVOPT_BAD_ENC := \
	reserved-JALR-funct3-1:00800093,00009067,05d00893,00000073 \
	reserved-JALR-funct3-7:00800093,0000f067,05d00893,00000073 \
	reserved-JALR-link-funct3-2:00800093,0000a0e7,05d00893,00000073 \
	reserved-ret-funct3-1:00c000ef,05d00893,00000073,00009067 \
	CSR-funct3-1:05d00893,00001073 \
	CSR-funct3-5:05d00893,00005073 \
	ebreak:05d00893,00100073 \
	ecall-with-rd:05d00893,000000f3 \
	ecall-with-rs1:05d00893,00008073 \
	jumped-into-ecall:01000093,00008067,05d00893,00000013,00000073 \
	returned-into-ecall:05d00893,008000ef,00000073,04000893,00008067 \
	chain-uncovers-JALR:01000113,00010067,00800093,00010067,00800093,00008067 \
	JALR-invalidated-target:00000c63,01000113,00000013,00010067,05d00893,00000073,00800193,00018067
# The jump-over cases exercise reachability, not the decode gate: an off-path
# word must not change what the reachable path lowers to, whatever it decodes
# to. In the last three that word is itself a control transfer aimed at a live
# instruction, which must not split the block that instruction sits in.
RVOPT_OK_ENC := \
	JALR:00800093,00008067,05d00893,00000073 \
	ret:00c000ef,05d00893,00000073,00008067 \
	ecall-exit:05d00893,00000073 \
	ecall-write:04000893,00000073 \
	jump-over-reserved-JALR:0100006f,01400093,00009067,00008067,05d00893,00000073 \
	jump-over-CSR:0100006f,01400093,00001073,00008067,05d00893,00000073 \
	jump-over-JALR:0100006f,01400093,00000013,00008067,05d00893,00000073 \
	jump-over-JAL:00c0006f,0100006f,00000013,05d00893,00000013,00000073 \
	jump-over-branch:00c0006f,00000863,00000013,05d00893,00000013,00000073
# Two static jalrs in a chain: the block that makes the second resolvable is
# reachable only through the first. Each target writes one byte of the "AB" at
# the end of the image, so the check is the exact output of a run; lowering
# without an error proves nothing, since a dropped half still exits cleanly.
RVOPT_CHAIN_ENC := \
	00800093,00008067, \
	00100513,04000593,00100613,04000893,00000073, \
	02400113,00010067, \
	00100513,04100593,00100613,04000893,00000073, \
	05d00893,00000073, \
	00004241
PACK_WORDS = python3 -c 'import sys, struct; sys.stdout.buffer.write(b"".join(struct.pack("<I", int(w, 16)) for w in sys.argv[1].split(",")))'

# Standalone native-image emission: run a hand-written smoke image (MOVE, SUBLEQ
# arithmetic + branch-to-halt, PUT at the 32-bit encoding), a high-address
# image, and wide differential fuzz.
verify-mux: $(BIN) $(RVOPT) ## Verify wide 32-bit-cell native emission.
	$(Q)$(RUN) ./$(BIN) tests/mux-smoke.dec > $(TMPDIR)/mux-smoke.out 2>&1 \
	    && cmp -s tests/expected/mux-smoke.out $(TMPDIR)/mux-smoke.out \
	    || { echo "verify-mux: wide-VM smoke output mismatch"; exit 1; }
	$(Q)if command -v python3 >/dev/null 2>&1; then \
	    python3 scripts/gen-mux-high-image.py > $(TMPDIR)/mux-high.dec \
	        && $(RUN) ./$(BIN) $(TMPDIR)/mux-high.dec > $(TMPDIR)/mux-high.out 2>&1 \
	        && printf K | cmp -s - $(TMPDIR)/mux-high.out \
	        || { echo "verify-mux: high-address image failed"; exit 1; }; \
	else $(PRINTF) "verify-mux: high-address image [SKIP: no python3]\n"; fi
	$(Q)if command -v python3 >/dev/null 2>&1; then \
	    $(CC) $(CFLAGS) -DMUX_MAX_CELLS=2048 -DMUX_ALLOW_SMALL_CAP \
	        -o $(TMPDIR)/rvopt-small rvopt.c \
	        && python3 -c 'import sys; sys.stdout.buffer.write(b"\x13\0\0\0" * 1024)' > $(TMPDIR)/rvopt-nops.bin \
	        && ! $(TMPDIR)/rvopt-small mux $(TMPDIR)/rvopt-nops.bin >/dev/null 2>$(TMPDIR)/rvopt-small.err \
	        && grep -q 'image needs' $(TMPDIR)/rvopt-small.err \
	        || { echo "verify-mux: rvopt mux ceiling guard failed"; exit 1; }; \
	else $(PRINTF) "verify-mux: rvopt ceiling guard [SKIP: no python3]\n"; fi
	$(Q)if command -v python3 >/dev/null 2>&1; then \
	    python3 -c 'import sys; sys.stdout.buffer.write((0xfff0000f).to_bytes(4, "little"))' > $(TMPDIR)/rvopt-bad-fence.bin \
	        && ! $(RVOPT) mux $(TMPDIR)/rvopt-bad-fence.bin >/dev/null 2>$(TMPDIR)/rvopt-bad-fence.err \
	        && grep -q 'unsupported op' $(TMPDIR)/rvopt-bad-fence.err \
	        || { echo "verify-mux: reserved FENCE was accepted"; exit 1; }; \
	    python3 -c 'import sys; sys.stdout.buffer.write((0x8000000f).to_bytes(4, "little"))' > $(TMPDIR)/rvopt-resv-tso.bin \
	        && ! $(RVOPT) mux $(TMPDIR)/rvopt-resv-tso.bin >/dev/null 2>$(TMPDIR)/rvopt-resv-tso.err \
	        && grep -q 'unsupported op' $(TMPDIR)/rvopt-resv-tso.err \
	        || { echo "verify-mux: reserved fm=8 (non-RW) FENCE was accepted"; exit 1; }; \
	    python3 -c 'import sys; sys.stdout.buffer.write((0x8330000f).to_bytes(4, "little"))' > $(TMPDIR)/rvopt-tso.bin \
	        && $(RVOPT) mux $(TMPDIR)/rvopt-tso.bin >/dev/null 2>&1 \
	        || { echo "verify-mux: FENCE.TSO (a nop here) was rejected"; exit 1; }; \
	else $(PRINTF) "verify-mux: FENCE reject/accept [SKIP: no python3]\n"; fi
	$(Q)if command -v python3 >/dev/null 2>&1; then \
	    for c in $(RVOPT_BAD_ENC); do \
	        $(PACK_WORDS) "$${c#*:}" > $(TMPDIR)/rvopt-enc.bin \
	            || { echo "verify-mux: cannot encode $${c%%:*}"; exit 1; }; \
	        ! $(RVOPT) mux $(TMPDIR)/rvopt-enc.bin >/dev/null 2>$(TMPDIR)/rvopt-enc.err \
	            && grep -q 'unsupported op' $(TMPDIR)/rvopt-enc.err \
	            || { echo "verify-mux: accepted $${c%%:*}"; exit 1; }; \
	    done; \
	    for c in $(RVOPT_OK_ENC); do \
	        $(PACK_WORDS) "$${c#*:}" > $(TMPDIR)/rvopt-enc.bin \
	            || { echo "verify-mux: cannot encode $${c%%:*}"; exit 1; }; \
	        $(RVOPT) mux $(TMPDIR)/rvopt-enc.bin >/dev/null 2>&1 \
	            || { echo "verify-mux: rejected $${c%%:*}"; exit 1; }; \
	    done; \
	    $(PACK_WORDS) "$(RVOPT_CHAIN_ENC)" > $(TMPDIR)/rvopt-chain.bin \
	        && $(RVOPT) mux $(TMPDIR)/rvopt-chain.bin > $(TMPDIR)/rvopt-chain.dec 2>&1 \
	        && $(RUN) ./$(BIN) $(TMPDIR)/rvopt-chain.dec > $(TMPDIR)/rvopt-chain.out 2>&1 \
	        && printf AB | cmp -s - $(TMPDIR)/rvopt-chain.out \
	        || { echo "verify-mux: static JALR chain lost its second target"; exit 1; }; \
	else $(PRINTF) "verify-mux: JALR/SYSTEM encoding gate [SKIP: no python3]\n"; fi
	$(Q)if command -v python3 >/dev/null 2>&1; then \
	    python3 scripts/rv32i-conformance.py >/dev/null \
	        || { echo "verify-mux: RV32I reference-model self-check FAILED"; exit 1; }; \
	    python3 scripts/rvopt-fuzz.py --wide --n 18 --body 20 --seed 1 >/dev/null \
	        || { echo "verify-mux: mux differential fuzz FAILED (see stderr above)"; exit 1; }; \
	else $(PRINTF) "verify-mux: python3 absent, skipping mux differential fuzz\n"; fi
	$(Q)$(PRINTF) "verify-mux: smoke + high-address + rvopt ceiling + wide differential fuzz\n"

verify-eforth-stage0: $(STAGE0_DEC) ## Verify gforth can emit the 32-bit-cell eForth image.
	$(Q)awk '{ for (i = 1; i <= NF; i++) if (++n == 10) \
	        rc = ($$i == 32 || $$i == "0x20" || $$i == "0x00000020") ? 0 : 1 } \
	    END { exit (n >= 10 ? rc : 1) }' $(STAGE0_DEC) \
	    || { echo "verify-eforth-stage0: bwidth cell (10th token) is not 32"; exit 1; }
	$(Q)grep -Eq -- '(^|[[:space:]])(-2147483642|-0x7FFFFFFA|0x80000006)([[:space:]]|$$)' $(STAGE0_DEC) \
	    || { echo "verify-eforth-stage0: missing 0x80000006 MUX/MOVE marker"; exit 1; }
	$(Q)$(PRINTF) "verify-eforth-stage0: gforth 32-bit target image "; $(call notice, [OK])

verify-eforth-repl: $(BIN) ## Smoke-test the 32-bit-cell eForth REPL.
	$(Q)printf 'bye\n' | $(RUN) ./$(BIN) > $(TMPDIR)/eforth-bye.out 2>&1 \
	    && test ! -s $(TMPDIR)/eforth-bye.out \
	    || { echo "verify-eforth-repl: bye did not exit cleanly"; exit 1; }
	$(Q)printf '1 2 + . bye\n' | $(RUN) ./$(BIN) > $(TMPDIR)/eforth-plus.out 2>&1 \
	    && printf ' 3' | cmp -s - $(TMPDIR)/eforth-plus.out \
	    || { echo "verify-eforth-repl: arithmetic smoke failed"; exit 1; }
	$(Q)printf 'hex cell . decimal bye\n' | $(RUN) ./$(BIN) > $(TMPDIR)/eforth-cell.out 2>&1 \
	    && printf ' 4' | cmp -s - $(TMPDIR)/eforth-cell.out \
	    || { echo "verify-eforth-repl: cell-size smoke failed"; exit 1; }
	$(Q)printf ': maker create , does> @ . ; 9 maker x x bye\n' | $(RUN) ./$(BIN) > $(TMPDIR)/eforth-does.out 2>&1 \
	    && printf ' 9' | cmp -s - $(TMPDIR)/eforth-does.out \
	    || { echo "verify-eforth-repl: does> smoke failed"; exit 1; }
	$(Q)printf ': foo 0 do i . loop ; 3 foo bye\n' | $(RUN) ./$(BIN) > $(TMPDIR)/eforth-loop.out 2>&1 \
	    && printf ' 0 1 2' | cmp -s - $(TMPDIR)/eforth-loop.out \
	    || { echo "verify-eforth-repl: do/loop smoke failed"; exit 1; }
	$(Q)printf '9 . 10 . 11 . 99 . 100 . bye\n' | $(RUN) ./$(BIN) > $(TMPDIR)/eforth-number.out 2>&1 \
	    && printf ' 9 10 11 99 100' | cmp -s - $(TMPDIR)/eforth-number.out \
	    || { echo "verify-eforth-repl: multi-digit number smoke failed"; exit 1; }
	$(Q)printf '100 constant x x . bye\n' | $(RUN) ./$(BIN) > $(TMPDIR)/eforth-constant.out 2>&1 \
	    && printf ' 100' | cmp -s - $(TMPDIR)/eforth-constant.out \
	    || { echo "verify-eforth-repl: constant number smoke failed"; exit 1; }
	$(Q)printf 'here 100 , here swap - . here cell- @ . bye\n' | $(RUN) ./$(BIN) > $(TMPDIR)/eforth-store.out 2>&1 \
	    && printf ' 4 100' | cmp -s - $(TMPDIR)/eforth-store.out \
	    || { echo "verify-eforth-repl: cell store smoke failed"; exit 1; }
	$(Q)printf 'forth-wordlist forth-wordlist forth-wordlist forth-wordlist forth-wordlist forth-wordlist forth-wordlist forth-wordlist 8 set-order definitions : z 1 ; z . bye\n' | $(RUN) ./$(BIN) > $(TMPDIR)/eforth-order.out 2>&1 \
	    && printf ' 1' | cmp -s - $(TMPDIR)/eforth-order.out \
	    || { echo "verify-eforth-repl: max search-order smoke failed"; exit 1; }
	$(Q)$(PRINTF) "verify-eforth-repl: 32-bit eForth REPL smokes "; $(call notice, [OK])

verify-loader-rejects: $(BIN) tests/loader-bad-token.dec tests/loader-out-of-range.dec ## Verify malformed image rejection.
	$(Q)for flag in -r -x -s -p; do \
	    ! ./$(BIN) $$flag >/dev/null 2>$(TMPDIR)/loader.err \
	        && grep -q 'unknown option' $(TMPDIR)/loader.err \
	        || { echo "verify-loader-rejects: $$flag did not report unknown option"; exit 1; }; \
	done
	$(Q)for f in tests/loader-bad-token.dec tests/loader-out-of-range.dec; do \
	    ! ./$(BIN) $$f >/dev/null 2>$(TMPDIR)/loader.err \
	        && grep -q 'bad cell' $(TMPDIR)/loader.err \
	        || { echo "verify-loader-rejects: accepted $$f"; exit 1; }; \
	done
	$(Q)printf '6 4294967295 0 4 4 4294967295 010\n' > $(TMPDIR)/loader-dec010.dec; \
	    ./$(BIN) $(TMPDIR)/loader-dec010.dec > $(TMPDIR)/loader.out \
	        && printf '\n' | cmp -s - $(TMPDIR)/loader.out \
	        || { echo "verify-loader-rejects: parsed leading-zero decimal as non-decimal"; exit 1; }
	$(Q)printf '6 4294967295 0 4 4 4294967295 0x0A\n' > $(TMPDIR)/loader-hex.dec; \
	    ./$(BIN) $(TMPDIR)/loader-hex.dec > $(TMPDIR)/loader.out \
	        && printf '\n' | cmp -s - $(TMPDIR)/loader.out \
	        || { echo "verify-loader-rejects: rejected 0x-prefixed cell"; exit 1; }
	$(Q)$(MUXLEQ_CC) $(CFLAGS) -DMUX_MAX_CELLS=131072 -I$(OUT) \
	        -o $(TMPDIR)/muxleq-small muxleq.c
	$(Q)yes 0 | head -n 131073 > $(TMPDIR)/loader-oversized.dec; \
	    ! $(TMPDIR)/muxleq-small $(TMPDIR)/loader-oversized.dec >/dev/null 2>$(TMPDIR)/loader.err \
	        && grep -q 'exceeds' $(TMPDIR)/loader.err \
	        || { echo "verify-loader-rejects: accepted oversized image"; exit 1; }
	$(Q)$(PRINTF) "verify-loader-rejects: malformed images rejected "; $(call notice, [OK])

# Deep on-demand wide differential fuzz for the standalone 32-bit emitter.
# Sweeps many seeds (not just seed 1) across cycled image sizes; ~2 min. On a
# failure it prints the exact single-program reproduce command; scale coverage
# vs time via SEEDS/N/BODY (e.g. SEEDS=300 ~4 min, SEEDS=40 ~30 s).
fuzz-rvopt: $(BIN) $(RVOPT) ## Differential-fuzz rvopt mux across many seeds (~2 min).
	$(Q)python3 scripts/rvopt-fuzz.py --wide --seeds $(if $(SEEDS),$(SEEDS),120) \
	    --n $(if $(N),$(N),64) --body $(if $(BODY),$(BODY),24) --seed $(if $(SEED),$(SEED),1)

# RV32I cross-build and conformance. Building the test programs needs a bare-metal
# RISC-V toolchain (riscv-none-elf-* by default; CI installs the xPack build), but
# rvopt and muxleq build from plain C, so the toolchain is only ever needed to
# produce the .elf inputs, never to lower or run them. "make check" therefore
# covers RV32I either way (rv32i-auto): with the toolchain it builds from source,
# without it it fetches prebuilt .elf inputs from the rolling pre-release. Each
# group builds into its own build/rv32i subdir so the intermediate crt0.o that
# unopt and duremark share never collides.
# Cross prefix for the RV32I sub-makes and the toolchain probe. Default matches
# the sub-makes' own CROSS default; deriving it from CROSS preserves the older
# `make rv32i CROSS=<prefix>` knob (hardcoding CROSS=$(RVCROSS) on the sub-make
# lines below would otherwise defeat a user's CROSS override).
RVCROSS ?= $(if $(CROSS),$(CROSS),riscv-none-elf-)
RV32I_OUT := $(abspath $(OUT)/rv32i)
# One output dir per group. The build (rv32i) and run (rv32i-check) targets must
# pass the same dir for a group; naming it once keeps them from drifting, which
# would make "run" rebuild into a fresh tree instead of running what was built.
RV32I_DEMOS := $(RV32I_OUT)/demos
RV32I_UNOPT := $(RV32I_OUT)/unopt
RV32I_DUREMARK := $(RV32I_OUT)/duremark

rv32i: ## Cross-build the RV32I test programs into build/rv32i (needs riscv-none-elf-gcc).
	$(Q)$(MAKE) -C tests/rv32i          OUT=$(RV32I_DEMOS)    CROSS=$(RVCROSS)
	$(Q)$(MAKE) -C tests/rv32i/unopt    OUT=$(RV32I_UNOPT)    CROSS=$(RVCROSS)
	$(Q)$(MAKE) -C tests/rv32i/duremark OUT=$(RV32I_DUREMARK) CROSS=$(RVCROSS)

# Point the sub-make run/check recipes at the binaries this build produced, as
# absolute paths that survive the -C into each subdir. Without this they would
# fall back to their hardcoded ../../build defaults and run a stale or wrong VM
# under a non-default OUT.
RV32I_VM := RVOPT=$(abspath $(RVOPT)) MUXLEQ=$(abspath $(BIN))

rv32i-check: $(BIN) $(RVOPT) rv32i ## Lower the RV32I programs and run the rv32ui conformance suite.
	$(Q)$(MAKE) -C tests/rv32i       OUT=$(RV32I_DEMOS) CROSS=$(RVCROSS) $(RV32I_VM) run
	$(Q)$(MAKE) -C tests/rv32i/unopt OUT=$(RV32I_UNOPT) CROSS=$(RVCROSS) $(RV32I_VM) run
	$(Q)$(MAKE) -C tests/rv32i/riscv-tests CROSS=$(RVCROSS) $(RV32I_VM) check
# Stage the rv32ui .elf inputs (built in-tree) under build/rv32i so the published
# tarball carries them, letting the toolchain-less prebuilt path run the full
# conformance suite, not just the demos. count.txt records the expected number so
# the prebuilt consumer can reject a truncated release instead of passing green
# on a reduced suite.
	$(Q)mkdir -p $(RV32I_OUT)/riscv-tests
	$(Q)cp tests/rv32i/riscv-tests/*.elf $(RV32I_OUT)/riscv-tests/
	$(Q)ls tests/rv32i/riscv-tests/*.elf | wc -l | tr -d ' ' > $(RV32I_OUT)/riscv-tests/count.txt

# Toolchain-less RV32I coverage: fetch prebuilt .elf inputs from the rolling
# pre-release and run the same rvopt-mux + muxleq gate over them. The script
# exits 77 for any transient/degraded condition (no network, no conformance
# elfs, torn download) and prints the specific reason itself; treat 77 as a skip
# so an offline machine is not blocked.
rv32i-prebuilt: $(BIN) $(RVOPT) ## Run RV32I tests from the prebuilt release (no toolchain).
	$(Q)RVOPT=$(abspath $(RVOPT)) MUXLEQ=$(abspath $(BIN)) scripts/rv32i-prebuilt.sh; rc=$$?; \
	    if [ $$rc -eq 77 ]; then $(PRINTF) "rv32i-prebuilt "; $(call notice, [SKIP]); \
	    elif [ $$rc -ne 0 ]; then exit 1; fi

# Offline contract test for the prebuilt-release script: mock curl, crafted
# tarballs, asserts the 0/1/77 exit contract. Needs no toolchain or network; the
# pass cases additionally run when rv32i-check has populated build/rv32i.
verify-prebuilt: $(BIN) $(RVOPT) ## Contract-test scripts/rv32i-prebuilt.sh offline.
	$(Q)RVOPT=$(abspath $(RVOPT)) MUXLEQ=$(abspath $(BIN)) tests/rv32i-prebuilt-test.sh

# What "make check" uses: build+run from source when the cross toolchain is
# present, else fall back to the prebuilt release. A machine with neither the
# toolchain nor network skips rather than failing the gate.
rv32i-auto: $(BIN) $(RVOPT) ## RV32I coverage: from source if toolchain present, else prebuilt.
	$(Q)if [ -n "$(RVCROSS)" ] && command -v $(RVCROSS)gcc >/dev/null 2>&1 \
	    && command -v $(RVCROSS)objcopy >/dev/null 2>&1 \
	    && command -v $(RVCROSS)as >/dev/null 2>&1 \
	    && command -v $(RVCROSS)ld >/dev/null 2>&1; then \
	    if $(MAKE) -C tests/rv32i/riscv-tests upstream/.rev >/dev/null 2>&1; then \
	        $(MAKE) rv32i-check; \
	    else \
	        $(PRINTF) "rv32i-auto: "; $(call notice, [SKIP: cannot fetch the riscv-tests conformance suite (offline?)]); \
	    fi; \
	else \
	    $(PRINTF) "rv32i-auto: no complete $(RVCROSS) toolchain -- running the prebuilt release\n"; \
	    $(MAKE) rv32i-prebuilt; \
	fi

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
# Derived from the same pathspec .ci/check-format.sh checks, so "make indent"
# formats exactly what CI enforces (tracked C/include sources outside tests/).
CFMT_SRC := $(shell git ls-files -- '*.c' '*.inc' ':!tests/')
PYFMT_SRC := $(wildcard scripts/*.py)
FORTH_SRC := $(MUXLEQ_FORTH_MODULES) $(wildcard tests/*.fth)
# clang-format output is version-sensitive, so the project pins version 20.
# Detect a clang-format-20 binary first, otherwise accept a plain clang-format
# only when it reports major version 20. A present but wrong-versioned
# clang-format is an error; a missing one degrades to a skip.
CLANG_FORMAT := $(shell command -v clang-format-20 2>/dev/null || \
    { command -v clang-format >/dev/null 2>&1 && \
      clang-format --version | grep -q 'version 20\.' && command -v clang-format; })
indent: ## Format C/Python and lint Forth sources.
	$(Q)if [ -n "$(CLANG_FORMAT)" ]; then \
	    $(CLANG_FORMAT) -i $(CFMT_SRC) || exit 1; \
	    $(PRINTF) "indent: $(notdir $(CLANG_FORMAT)) C sources "; $(call notice, [OK]); \
	elif command -v clang-format >/dev/null 2>&1; then \
	    echo "indent: clang-format $$(clang-format --version | grep -oE '[0-9]+' | head -1) found, version 20 required"; exit 1; \
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

# Check-only counterpart to indent, mirroring the CI format job: fail (do not
# reformat) when a project C source drifts from clang-format 20 or lacks a
# trailing newline. Same file scope as indent via .ci/check-format.sh.
check-format: ## Verify C formatting and trailing newlines (no reformat).
	$(Q).ci/check-newline.sh
	$(Q).ci/check-format.sh

$(STAGE0_C): $(STAGE0_DEC) | $(OUT)
	$(Q)sed 's/$$/,/' $^ > $@

# The generated image is the 32-bit eForth target. Reconsider it every build;
# the script rewrites the file, bumping its mtime so stage0/stage1 rebuild,
# only when the stamped content actually changes.
$(MUXLEQ_FTH): $(MUXLEQ_FORTH_MODULES) scripts/update-muxleq-fth.sh FORCE | $(OUT)
	$(Q)sh scripts/update-muxleq-fth.sh $@ $(MUXLEQ_FORTH_MODULES)

$(STAGE0_DEC): $(MUXLEQ_FTH) | $(OUT)
	$(VECHO) "  FORTH\t$@\n"
	$(Q)gforth $< > $@

# Golden-output regression suite: each test's stdout must match
# tests/expected/<name>.out byte-for-byte on the default 32-bit eForth. The
# fixtures are 32-bit captures; the former 16-bit ones (wrap, sign display,
# cell strides, scheduler counts) were re-blessed against the wide cell.
GOLDEN_FILES := \
	loops radix sqrt \
	fibonacci bitcount clz log \
	life rainbow control \
	tasker sieve collatz base recurse rot13 double sort heap except eof \
	arith crc define prng-bench scheduler chacha20 \
	hello bigf asterisks trig multiply \
	array does ascii \
	text money temp weather calendar \
	fig stack msgpass value

# Bound each test run so a mis-fused interpreter that loops forever fails the
# gate instead of hanging it -- an infinite loop is the likeliest fusion bug.
# Degrade to no bound if timeout(1)/gtimeout is unavailable.
TIMEOUT := $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
RUN_TIMEOUT ?= 60
RUN = $(TIMEOUT) $(if $(TIMEOUT),$(RUN_TIMEOUT))
GOLDEN_RUN = $(RUN) ./$(BIN)

golden: $(BIN) ## Run byte-exact 32-bit golden output tests.
	$(Q)test -n "$(TIMEOUT)" || $(PRINTF) \
	    "golden: WARNING: no timeout(1)/gtimeout; a hung test will not be bounded\n"
	$(Q)$(foreach t,$(GOLDEN_FILES),\
	    $(PRINTF) "golden $(t) ... "; \
	    if $(GOLDEN_RUN) < tests/$(t).fth > $(TMPDIR)/golden.out 2>/dev/null \
	        && cmp -s tests/expected/$(t).out $(TMPDIR)/golden.out; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "DRIFT or VM error\n"; exit 1; \
	    fi; \
	)

golden-see: $(BIN) tests/expected/see.out ## Check the address-normalized `see` decompiler output.
	$(Q)if $(GOLDEN_RUN) < tests/see.fth > $(TMPDIR)/see.raw 2>/dev/null \
	    && sed -E 's/^ *[0-9]+ [|]/# |/; s/[0-9]+/#/g' $(TMPDIR)/see.raw > $(TMPDIR)/see.out \
	    && cmp -s tests/expected/see.out $(TMPDIR)/see.out; \
	then :; \
	else \
	    echo "golden-see: decompiler output drift or VM error (see tests/see.fth)"; exit 1; \
	fi
	$(Q)$(PRINTF) "golden-see: normalized decompiler output "; $(call notice, [OK])

# Keystrokes for the pty editor tests: go to block 5, blank it, arrow-down one
# row (this is the only path that drives the normal-mode ESC/arrow timed-peek --
# EDIT_PEEK + the poll() in get() + varrow's CSI decode), insert text, repaint.
# Shared by golden-pty and the sanitize pty run. A lone python3 guard on its own
# recipe line only exits that line's subshell, so the whole target is one shell.
EDITOR_KEYS := editor\r:5\r:z\033[BiHELLO ED\033:5\r

golden-pty: $(BIN) tests/expected/editor-pty.out ## PTY-driven modal editor screen golden.
	$(Q)if ! command -v python3 >/dev/null 2>&1; then \
	    $(PRINTF) "golden-pty: python3 absent, skipping\n"; \
	else \
	    printf '$(EDITOR_KEYS)' | python3 scripts/pty-run.py ./$(BIN) > $(TMPDIR)/editor-pty.out; rc=$$?; \
	    if [ $$rc -eq 77 ]; then $(PRINTF) "golden-pty: no pty available, skipping\n"; \
	    elif [ $$rc -ne 0 ]; then echo "golden-pty: harness failed (rc=$$rc)"; exit 1; \
	    elif cmp -s tests/expected/editor-pty.out $(TMPDIR)/editor-pty.out; then \
	        $(PRINTF) "golden-pty: modal editor screen "; $(call notice, [OK]); \
	    else echo "golden-pty: modal editor screen drift (see scripts/pty-run.py)"; exit 1; fi; \
	fi

golden-mandel: $(BIN) tests/expected/mandel-prefix.out ## Check the bounded Mandelbrot prefix.
	$(Q)test -n "$(TIMEOUT)" || { echo "golden-mandel: timeout(1)/gtimeout required"; exit 1; }
	$(Q)command -v stdbuf >/dev/null 2>&1 || { echo "golden-mandel: stdbuf required for killed-run stdout"; exit 1; }
	$(Q)bytes=$$(wc -c < tests/expected/mandel-prefix.out); \
	    $(TIMEOUT) $(if $(TIMEOUT),$(RUN_TIMEOUT)) stdbuf -o0 ./$(BIN) < tests/mandel.fth 2>/dev/null \
	        | tr -d '\r' | head -c $$bytes > $(TMPDIR)/mandel-prefix.out; \
	    cmp -s tests/expected/mandel-prefix.out $(TMPDIR)/mandel-prefix.out \
	        || { echo "golden-mandel: prefix drift"; exit 1; }
	$(Q)$(PRINTF) "golden-mandel: bounded mandel prefix "; $(call notice, [OK])
# The pre-commit gate: byte-exact 32-bit golden diff, pty editor screen, 32-bit
# image sanity smokes, and the 32-bit self-hosting proof.
check: golden golden-see golden-pty verify-eforth-stage0 verify-eforth-repl bootstrap rv32i-auto ## Run the fast pre-commit gate.

# Deep pre-release gate: the standard check plus wide native-image fuzz,
# loader rejection, the prebuilt-script contract test, and ASan+UBSan.
check-all: check verify-mux verify-loader-rejects verify-prebuilt sanitize ## Run deep validation.

# bootstrapping
bootstrap: $(STAGE0_DEC) $(STAGE1_DEC) ## Prove self-host bootstrap is byte-exact.
	$(Q)if diff $(STAGE0_DEC) $(STAGE1_DEC); then \
	    $(PRINTF) "bootstrap: self-host image byte-exact "; $(call notice, [OK]); \
	else \
	    $(PRINTF) "bootstrap: self-host image NOT byte-exact -- aborting\n"; \
	    exit 1; \
	fi

$(STAGE1_DEC): $(BIN) $(MUXLEQ_FTH) | $(OUT)
	$(VECHO)  "Bootstrapping... "
	$(Q)./$(BIN) < $(MUXLEQ_FTH) \
	    | awk '{ sub(/\r$$/, ""); if ($$0 !~ / redefined$$/) print }' > $@

TMPDIR := $(shell mktemp -d)

# Build with AddressSanitizer + UndefinedBehaviorSanitizer and run the default
# wide VM, the loader, and the standalone rvopt wide emitter.
SANFLAGS := -O2 -std=c99 -fsanitize=address,undefined -fno-sanitize-recover=all -g
SAN_RUN = ASAN_OPTIONS=detect_leaks=0 $(TIMEOUT) $(if $(TIMEOUT),120) $(TMPDIR)/muxleq.san
SANITIZE_FILES := tasker sieve collatz does eof recurse
sanitize: $(STAGE0_C) $(BIN) $(RVOPT) tests/loader-bad-token.dec tests/loader-out-of-range.dec ## Run ASan/UBSan validation.
	$(Q)$(MUXLEQ_CC) $(SANFLAGS) -I$(OUT) -o $(TMPDIR)/muxleq.san muxleq.c
	$(Q)$(PRINTF) "sanitize editor (pty) ... "; \
	    if ! command -v python3 >/dev/null 2>&1; then $(PRINTF) "[SKIP: no python3]\n"; \
	    else \
	        printf '$(EDITOR_KEYS)' | PTY_RUN_STDERR=1 ASAN_OPTIONS=detect_leaks=0 \
	            python3 scripts/pty-run.py $(TMPDIR)/muxleq.san >/dev/null 2>$(TMPDIR)/san.err; rc=$$?; \
	        if [ $$rc -eq 77 ]; then $(call notice, [SKIP: no pty]); \
	        elif [ $$rc -eq 0 ]; then $(call notice, [OK]); \
	        else $(PRINTF) "SANITIZER ERROR or harness failure\n"; cat $(TMPDIR)/san.err; exit 1; fi; \
	    fi
	$(Q)$(foreach t,$(SANITIZE_FILES),\
	    $(PRINTF) "sanitize $(t) ... "; \
	    if $(SAN_RUN) < tests/$(t).fth >/dev/null 2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR or timeout\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	)
	$(Q)$(PRINTF) "sanitize loader rejects ... "; \
	    ! $(SAN_RUN) tests/loader-bad-token.dec >/dev/null 2>$(TMPDIR)/san.err \
	        && grep -q 'bad cell' $(TMPDIR)/san.err \
	        && ! grep -Eq 'ERROR: AddressSanitizer|runtime error:' $(TMPDIR)/san.err \
	        && ! $(SAN_RUN) tests/loader-out-of-range.dec >/dev/null 2>$(TMPDIR)/san.err \
	        && grep -q 'bad cell' $(TMPDIR)/san.err \
	        && ! grep -Eq 'ERROR: AddressSanitizer|runtime error:' $(TMPDIR)/san.err \
	        || { $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; }; \
	    $(call notice, [OK])
	$(Q)if command -v python3 >/dev/null 2>&1; then \
	    $(PRINTF) "sanitize high-address image ... "; \
	    if python3 scripts/gen-mux-high-image.py > $(TMPDIR)/mux-high.dec \
	        && $(SAN_RUN) $(TMPDIR)/mux-high.dec > $(TMPDIR)/mux-high.out 2>$(TMPDIR)/san.err \
	        && printf K | cmp -s - $(TMPDIR)/mux-high.out; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; fi; \
	else $(PRINTF) "sanitize high-address image ... [SKIP: no python3]\n"; fi
	$(Q)$(CC) $(SANFLAGS) -o $(TMPDIR)/rvopt.san rvopt.c
	$(Q)$(PRINTF) "sanitize rvopt dump|check IR round-trip ... "; \
	    printf '\023\000\000\000\023\000\000\000\023\000\000\000\163\000\000\000' > $(TMPDIR)/rt.bin; \
	    if $(TMPDIR)/rvopt.san dump $(TMPDIR)/rt.bin > $(TMPDIR)/rt.ir 2>$(TMPDIR)/san.err \
	        && $(TMPDIR)/rvopt.san check - < $(TMPDIR)/rt.ir >/dev/null 2>>$(TMPDIR)/san.err \
	        && ! grep -Eq 'ERROR: AddressSanitizer|runtime error:' $(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR or dump|check round-trip failed\n"; cat $(TMPDIR)/san.err; exit 1; fi
	$(Q)if command -v python3 >/dev/null 2>&1; then \
	    $(PRINTF) "sanitize rvopt mux emit fuzz (wide backend: SMC patch, write loop, shift loops) ... "; \
	    if python3 scripts/rvopt-fuzz.py --wide --rvopt $(TMPDIR)/rvopt.san --n 25 --body 14 --seed 1 \
	        >/dev/null 2>$(TMPDIR)/san.err; \
	    then $(call notice, [OK]); \
	    else $(PRINTF) "SANITIZER ERROR\n"; cat $(TMPDIR)/san.err; exit 1; \
	    fi; \
	else $(PRINTF) "sanitize rvopt emit fuzz: python3 absent, skipping\n"; fi

clean: ## Remove built binaries.
	$(RM) $(BIN) $(RVOPT)

# The rm -rf $(OUT) below covers build/rv32i; the extra recursive step drops the
# only generated tree that lives outside build/: the riscv-tests in-tree .elf
# files and their upstream clone.
distclean: clean ## Remove the whole build/ tree (generated image too).
	$(RM) -r $(OUT)
	$(Q)$(MAKE) -C tests/rv32i/riscv-tests distclean
