# Un-optimized (-O0) freestanding base-RV32I benchmark for the rvopt optimizer.
#
# The 7 demos are gcc -O2 (optimally lowered), so rvopt's folder and DCE passes
# read about 0 on them (measured). This -O0 build is the opposite: real
# un-optimized compiler output, every local spilled to the stack (17 LOAD / 14
# STORE vs the -O2 build's 0 / 1), un-folded constants, register moves, i.e.
# genuine optimizer headroom, and the concrete measurement target for the
# memory-lowering, dead-store, DCE, and coalescing passes that eliminate exactly
# those spills (the folder alone only moves it -0.4%). Base ISA (no mul/div),
# entry-0, write/exit, fits 32768 cells (emits about 13477). crt0 uses
# "jal ra, du_main" (a single ret call site) so rvopt mux can resolve the ret.
# The .elf is generated, never committed: the top-level build places it under
# build/rv32i by invoking this Makefile with OUT set.
CROSS  ?= riscv-none-elf-
OUT    ?= .
CFLAGS  = -march=rv32i -mabi=ilp32 -mno-relax -O0 -ffreestanding -nostdlib
OBJS    = $(addprefix $(OUT)/,crt0.o unopt.o)

$(OUT)/unopt.elf: $(OBJS) unopt.ld | $(OUT)
	$(CROSS)gcc $(CFLAGS) -Wl,-T,unopt.ld -o $@ $(OBJS)
	$(CROSS)objcopy --strip-all $@

$(OUT):
	mkdir -p $@

$(OUT)/%.o: %.c | $(OUT)
	$(CROSS)gcc $(CFLAGS) -c -o $@ $<
$(OUT)/crt0.o: crt0.S | $(OUT)
	$(CROSS)gcc $(CFLAGS) -c -o $@ $<

run: $(OUT)/unopt.elf
	../../../build/rvopt mux $(OUT)/unopt.elf > $(OUT)/unopt.dec \
	    && ../../../build/muxleq $(OUT)/unopt.dec | xxd

clean:
	$(RM) $(OBJS) $(OUT)/unopt.elf $(OUT)/unopt.dec

.PHONY: run clean
