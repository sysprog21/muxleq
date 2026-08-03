# DureMark, an RV32I benchmark (list + matrix + state workloads, vendored from
# https://github.com/sergev/duremark under MIT, see LICENSE).
#
# A freestanding, entry-0 RV32I build. run.c replaces upstream main.c with a
# fixed-iteration, clockless harness that prints a deterministic checksum. Base
# RV32I has no MUL/DIV, so the matrix and number-format workloads need soft
# multiply/divide/modulo; soft.c supplies self-contained versions (jal/ret only)
# because libgcc's div/mod helpers return through a "jr t0" runtime JALR that
# "rvopt mux" cannot lower. soft.c is linked BEFORE libgcc, so it resolves
# __mulsi3/__udivsi3/__umodsi3/__modsi3 and libgcc's "jr t0" millicode for those
# is never pulled; libgcc stays on the link line only as a fallback for any other
# pure-RV32I int helper a future codegen might emit (e.g. __clzsi2), so the build
# does not break the moment GCC references one. With the div/mod helpers replaced,
# the whole image lowers to native MUXLEQ, so "make run" lowers it and asserts the
# checksum. The linked image fits the 32 KiB guest window. The .elf is generated,
# never committed: the top-level build places it under build/rv32i by invoking
# this Makefile with OUT set.
CROSS  ?= riscv-none-elf-
OUT    ?= .
# VM binaries the run target drives; overridable so the top-level build points
# them at its own $(OUT). Defaults resolve from this directory for a standalone
# "make run"; absolute paths from the top survive the -C into here.
RVOPT  ?= ../../../build/rvopt
MUXLEQ ?= ../../../build/muxleq
# Bound the VM run so a program lowered into an infinite loop fails the gate fast
# instead of burning the whole CI job timeout (mirrors the riscv-tests suite).
# Auto-detected; empty (no timeout tool) leaves the run unbounded.
TIMEOUT ?= $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
# The 500-iteration run is ~15 s natively; 120 s leaves headroom for a slow or
# emulated CI runner without letting a genuinely hung lowering run unbounded.
RUN_TIMEOUT ?= 120
# Optional prefix for the VM run so "make bench-rv32i" can time it; empty for the
# plain correctness gate. Wraps the timeout, so timing measures the bounded run.
TIME_P ?=
# Deterministic combined checksum of the three fixed-iteration workloads. Pins
# correct execution end to end: rvopt lowering + VM interpretation must agree
# with the reference RV32I run.
CHECKSUM = DureMark checksum 1069216870
CFLAGS  = -march=rv32i -mabi=ilp32 -mno-relax -O2 -ffreestanding -nostdlib -I.
# soft.c overrides libgcc's div/mod (see top comment); libgcc trails as a
# fallback for any other pure-RV32I helper. Its millicode is not pulled because
# soft.o already defines the four helpers the workloads reference.
LIBGCC := $(shell $(CROSS)gcc $(CFLAGS) -print-libgcc-file-name 2>/dev/null)
OBJS    = $(addprefix $(OUT)/,crt0.o run.o list.o matrix.o state.o soft.o)

$(OUT)/duremark.elf: $(OBJS) duremark.ld | $(OUT)
	$(CROSS)gcc $(CFLAGS) -Wl,-T,duremark.ld -o $@ $(OBJS) $(LIBGCC)
	$(CROSS)objcopy --strip-all $@

$(OUT):
	mkdir -p $@

$(OUT)/%.o: %.c duremark.h | $(OUT)
	$(CROSS)gcc $(CFLAGS) -c -o $@ $<

$(OUT)/crt0.o: crt0.S | $(OUT)
	$(CROSS)gcc $(CFLAGS) -c -o $@ $<

# Lower to native MUXLEQ, run on the VM, and assert the deterministic checksum.
# Land output in a file first so a VM crash surfaces as this target's failure
# rather than being masked by the diff pipeline's exit status.
run: $(OUT)/duremark.elf
	$(RVOPT) mux $(OUT)/duremark.elf > $(OUT)/duremark.dec
	$(TIME_P) $(TIMEOUT) $(if $(TIMEOUT),$(RUN_TIMEOUT)) $(MUXLEQ) $(OUT)/duremark.dec > $(OUT)/duremark.out
	@printf '%s\n' '$(CHECKSUM)' | diff -u - $(OUT)/duremark.out \
	    && echo "duremark: checksum OK" \
	    || { echo "duremark: checksum MISMATCH"; exit 1; }

clean:
	$(RM) $(OBJS) $(OUT)/duremark.elf $(OUT)/duremark.dec $(OUT)/duremark.out

.PHONY: run clean
