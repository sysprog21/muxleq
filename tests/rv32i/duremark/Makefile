# DureMark for the muxleq RV32I runner ("build/muxleq -r duremark.elf").
#
# A freestanding, entry-0 RV32I build of the DureMark benchmark (list + matrix +
# state workloads, vendored from https://github.com/sergev/duremark under MIT,
# see LICENSE).
# run.c replaces upstream main.c with a fixed-iteration, clockless harness that
# prints a deterministic checksum. Matrix multiply/modulo resolve to rv32i
# libgcc soft routines, so this stays pure RV32I (no RV32M). The linked image
# fits the 32 KiB guest window. The .elf is generated, never committed: the
# top-level build places it under build/rv32i by invoking this Makefile with
# OUT set.
CROSS  ?= riscv-none-elf-
OUT    ?= .
CFLAGS  = -march=rv32i -mabi=ilp32 -mno-relax -O2 -ffreestanding -nostdlib -I.
LIBGCC := $(shell $(CROSS)gcc $(CFLAGS) -print-libgcc-file-name 2>/dev/null)
OBJS    = $(addprefix $(OUT)/,crt0.o run.o list.o matrix.o state.o)

$(OUT)/duremark.elf: $(OBJS) duremark.ld | $(OUT)
	$(CROSS)gcc $(CFLAGS) -Wl,-T,duremark.ld -o $@ $(OBJS) $(LIBGCC)
	$(CROSS)objcopy --strip-all $@

$(OUT):
	mkdir -p $@

$(OUT)/%.o: %.c duremark.h | $(OUT)
	$(CROSS)gcc $(CFLAGS) -c -o $@ $<

$(OUT)/crt0.o: crt0.S | $(OUT)
	$(CROSS)gcc $(CFLAGS) -c -o $@ $<

run: $(OUT)/duremark.elf
	../../../build/muxleq -r $(OUT)/duremark.elf

clean:
	$(RM) $(OBJS)

.PHONY: run clean
