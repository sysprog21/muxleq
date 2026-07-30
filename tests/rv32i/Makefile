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

$(addprefix $(OUT)/,fibonacci.o primes.o crc16.o mul.o bgcd.o bsort.o): print_dec.S

$(OUT):
	mkdir -p $@

$(OUT)/%.o: %.S | $(OUT)
	$(CROSS)as $(ASFLAGS) -o $@ $<

$(OUT)/%.elf: $(OUT)/%.o rv32i.ld
	$(CROSS)ld $(LDFLAGS) -o $@ $<

$(OUT)/%.bin: $(OUT)/%.elf
	$(CROSS)objcopy -O binary $< $@

run: $(PROGS)
	@for p in $(PROGS); do echo "== $$p =="; \
	    ../../build/rvopt mux $$p > $$p.dec && ../../build/muxleq $$p.dec; done

clean:
	$(RM) $(OUT)/*.o $(OUT)/*.elf $(OUT)/*.bin $(OUT)/*.dec

.PHONY: all run clean
