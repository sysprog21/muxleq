# Freestanding entry for DureMark under the muxleq RV32I runner.
# Placed at guest address 0 (entry must be 0). rvrun already presets sp to the
# top of the 32 KiB guest window; set it here too so the ELF is self-contained.
.section .text.init
.global _start
_start:
    li   sp, 0x8000        # top of 32 KiB guest RAM
    call du_main           # run the benchmark, print the checksum
    li   a7, 93            # SYS_EXIT
    li   a0, 0
    ecall
1:  j 1b                   # never reached
