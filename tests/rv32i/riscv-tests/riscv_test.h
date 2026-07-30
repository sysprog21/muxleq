// Minimal muxleq test environment for the vendored riscv-tests rv32ui suite.
//
// Replaces the upstream env (tohost/fromhost MMIO, link @ 0x8000_0000, trap
// vectors) with the muxleq RV32I ABI: entry _start at guest address 0, and
// pass/fail reported on STDOUT via the write(64)/exit(93) ecalls. The guest
// exit code is NOT propagated by the runner (it halts silently,
// muxleq.fth:2346), so stdout is the only pass/fail channel -- the verify
// target checks it is exactly "PASS\n".
#ifndef MUXLEQ_RISCV_TEST_H
#define MUXLEQ_RISCV_TEST_H

#define TESTNUM gp /* the suite's per-case number register (test_macros.h) */

/* ISA-selector markers: muxleq needs no per-ISA setup. Both U-mode widths map
 * here so an rv64ui body compiles unchanged as rv32 (the rv32ui shim remaps
 * RVTEST_RV64U -> RVTEST_RV32U; __riscv_xlen==32 drops the 64-bit-only cases).
 */
#define RVTEST_RV32U
#define RVTEST_RV64U

#define RVTEST_CODE_BEGIN \
    .text;                \
    .global _start;       \
    _start:

#define RVTEST_CODE_END

/* write(1, msg, 5); exit(code). SYS_WRITE=64, SYS_EXIT=93 (see hello.S). */
#define RVTEST_PASS     \
    li a7, 64;          \
    li a0, 1;           \
    la a1, muxleq_pass; \
    li a2, 5;           \
    ecall;              \
    li a7, 93;          \
    li a0, 0;           \
    ecall;

#define RVTEST_FAIL     \
    li a7, 64;          \
    li a0, 1;           \
    la a1, muxleq_fail; \
    li a2, 5;           \
    ecall;              \
    li a7, 93;          \
    li a0, 1;           \
    ecall;

#define RVTEST_DATA_BEGIN \
    .align 4;             \
    muxleq_pass:          \
    .ascii "PASS\n";      \
    muxleq_fail:          \
    .ascii "FAIL\n";      \
    .align 4;

#define RVTEST_DATA_END

#endif /* MUXLEQ_RISCV_TEST_H */
