# Freestanding RV32I test programs, lowered to native MUXLEQ by "rvopt mux".
#
# Each program links at guest address 0 and uses only the write(64)/exit(93)
# ecalls. Building needs a bare-metal RISC-V toolchain (riscv-none-elf-* by
# default). The .elf and .bin are generated, never committed: the top-level
# build places them under build/rv32i by invoking this Makefile with OUT set,
# and CI publishes them as build artifacts. Run "make" here to build in place,
# or "make run" to lower each program with rvopt and run it on the VM.
CROSS   ?= riscv-none-elf-
OUT     ?= .
# VM binaries the run target drives. Overridable so the top-level build points
# them at its own $(OUT); the defaults resolve from this directory for a
# standalone "make run". Absolute paths from the top survive the -C into here.
RVOPT   ?= ../../build/rvopt
MUXLEQ  ?= ../../build/muxleq
# Bound each VM run so a program lowered into an infinite loop fails the gate
# fast instead of burning the whole CI job timeout (mirrors the riscv-tests
# suite). Auto-detected; empty (no timeout tool) leaves runs unbounded, as
# elsewhere in the tree.
TIMEOUT ?= $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
RUN_TIMEOUT ?= 60
ASFLAGS  = -march=rv32i -mabi=ilp32
# -s strips symbols, -n packs the load segment right after the headers (no page
# padding); the loader reads only PT_LOAD, so both just shrink the .elf.
LDFLAGS  = --oformat=elf32-littleriscv -s -n -T rv32i.ld

NAMES = hello fibonacci primes crc16 mul bgcd bsort
PROGS = $(addprefix $(OUT)/,$(addsuffix .elf,$(NAMES)))
# hello.bin is the same program as a flat objcopy image, exercising rvopt's
# flat-binary input path as well as the ELF path.
FLAT  = $(OUT)/hello.bin

all: $(PROGS) $(FLAT)

$(addprefix $(OUT)/,fibonacci.o primes.o crc16.o mul.o bgcd.o bsort.o): print-dec.S

$(OUT):
	mkdir -p $@

$(OUT)/%.o: %.S | $(OUT)
	$(CROSS)as $(ASFLAGS) -o $@ $<

$(OUT)/%.elf: $(OUT)/%.o rv32i.ld
	$(CROSS)ld $(LDFLAGS) -o $@ $<

$(OUT)/%.bin: $(OUT)/%.elf
	$(CROSS)objcopy -O binary $< $@

# Lower and run every .elf plus the flat $(FLAT) image, so rvopt's flat-binary
# input path is exercised too (not just ELF). Propagate failure: the loop's exit
# status would otherwise be only the last iteration's, so a middle program that
# fails to lower or crashes the VM would pass silently, and this target is a CI
# gate now.
run: $(PROGS) $(FLAT)
	@fail=0; for p in $(PROGS) $(FLAT); do echo "== $$p =="; \
	    $(RVOPT) mux $$p > $$p.dec \
	        && $(TIMEOUT) $(if $(TIMEOUT),$(RUN_TIMEOUT)) $(MUXLEQ) $$p.dec || fail=1; \
	done; exit $$fail

clean:
	$(RM) $(OUT)/*.o $(OUT)/*.elf $(OUT)/*.bin $(OUT)/*.dec

.PHONY: all run clean
