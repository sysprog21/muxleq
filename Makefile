include mk/common.mk

# All generated artifacts live under build/, so the working tree stays clean and
# build/ is the single .gitignore entry.
OUT := build

CFLAGS += -O2 -std=c99
CFLAGS += -Wall -Wextra

.PHONY: run bootstrap clean check golden golden-update

BIN := $(OUT)/muxleq
STAGE0_DEC := $(OUT)/stage0.dec
STAGE0_C := $(OUT)/stage0.c
STAGE1_DEC := $(OUT)/stage1.dec

all: $(BIN)

$(OUT):
	$(Q)mkdir -p $@

$(BIN): muxleq.c $(STAGE0_C) | $(OUT)
	$(VECHO) "  CC+LD\t$@\n"
	$(Q)$(CC) $(CFLAGS) -I$(OUT) -o $@ muxleq.c

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
	fibonacci bitcount clz crc log \
	life rainbow control editor \
	define

# Bound each test run so a mis-fused interpreter that loops forever fails the
# gate instead of hanging it -- an infinite loop is the likeliest fusion bug.
# Degrade to no bound if timeout(1)/gtimeout is unavailable.
TIMEOUT := $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
GOLDEN_RUN = $(TIMEOUT) $(if $(TIMEOUT),20) ./$(BIN)

golden: $(BIN)
	$(Q)$(foreach t,$(GOLDEN_FILES),\
	    $(PRINTF) "golden $(t) ... "; \
	    if $(GOLDEN_RUN) < tests/$(t).fth > $(TMPDIR)/golden.out 2>/dev/null \
	        && cmp -s tests/expected/$(t).out $(TMPDIR)/golden.out; \
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

# The pre-commit gate: byte-exact golden diff plus the self-hosting proof.
check: golden bootstrap

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

TIME = 5000
TMPDIR := $(shell mktemp -d)
bench: $(BIN)
	$(VECHO)  "Benchmarking... "
	$(Q)(echo "${TIME} ms bye" | time -p ./$(BIN) > /dev/null) 2> $(TMPDIR)/bench ; \
	if grep -q real $(TMPDIR)/bench; then \
	$(call notice, [OK]); \
	cat $(TMPDIR)/bench; \
	else \
	$(PRINTF) "Failed.\n"; \
	exit 1; \
	fi;

clean:
	$(RM) $(BIN)

distclean: clean
	$(RM) -r $(OUT)
