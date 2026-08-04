#!/bin/sh
# RV32I RTOS-on-muxleq coverage suite: build each tests/rv32i/rtos/ program,
# lower it with `rvopt mux`, run it on muxleq, and assert the exact transcript.
# Coverage builds up from the primitive to the full RTOS:
#   1. context switch  cooperative two-task kernel exercising ctx-switch.S
#   2. Zicsr CSRs       CSR read/modify forms, plus unsupported-CSR rejection
#   3. timer interrupt  block-boundary timer + mret, plus runtime-mtvec rejection
#   4. preemptive RTOS  a shared core (rtos.c: priority scheduling, blocking
#                       semaphores, priority-inheritance mutex) under two
#                       scenarios: inversion avoidance (test-rtos.c) and a
#                       counting semaphore (test-semaphore.c), under preemption
# SKIPs (exit 0) without a bare-metal RISC-V toolchain (rvopt/muxleq build from C,
# but the .elf inputs need the cross tools).
#
# Convention (this harness only; muxleq's global ABI is unchanged):
#   - RV32I only, no M-extension (no mul/div/rem); verified per fixture.
#   - putchar -> write(64) of one byte, exit -> exit(93), a7 = syscall number
#     (see tests/rv32i/rtos/syscall.h).
#   - Links at guest address 0. C code sets sp to a reserved stack (rtos.ld).
#   - C code builds at -O0: rvopt resolves an ecall's syscall number by
#     block-local const-prop, so it cannot see an a7 an optimizer hoisted out of
#     a loop; -O0 keeps each putchar a self-contained call that reloads a7.
set -eu

here="$(CDPATH= cd "$(dirname "$0")" && pwd)"
root="$(CDPATH= cd "$here/.." && pwd)"
DIR="$root/tests/rv32i/rtos"
CROSS="${CROSS:-riscv-none-elf-}"
if ! command -v "${CROSS}gcc" >/dev/null 2>&1; then
    for d in /Users/jserv/rv/toolchain/bin "$HOME/rv/toolchain/bin"; do
        [ -x "$d/${CROSS}gcc" ] && {
            PATH="$d:$PATH"
            break
        }
    done
fi
RVOPT="${RVOPT:-$root/build/rvopt}"
MUXLEQ="${MUXLEQ:-$root/build/muxleq}"
# Bound each VM run so a --timer/mret/scheduler regression fails fast instead of
# hanging the gate; use timeout(1)/gtimeout when present, else run unbounded.
TIMEOUT=""
for t in timeout gtimeout; do
    command -v "$t" >/dev/null 2>&1 && {
        TIMEOUT="$t 10"
        break
    }
done
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for tool in gcc ld as objdump; do
    if ! command -v "${CROSS}${tool}" >/dev/null 2>&1; then
        echo "SKIP: ${CROSS}${tool} not found (bare-metal RISC-V toolchain required)"
        exit 0
    fi
done
GCC="${CROSS}gcc"
LD="${CROSS}ld"
AS="${CROSS}as"
OBJDUMP="${CROSS}objdump"

now_ms() { # milliseconds since epoch, portable across GNU/BSD date
    n=$(date +%s%N 2>/dev/null)
    case "$n" in '' | *[!0-9]*) echo $(($(date +%s) * 1000)) ;; *) echo $((n / 1000000)) ;; esac
}
run() { # dec-file expected-output label
    start=$(now_ms)
    $TIMEOUT "$MUXLEQ" "$1" >"$TMP/$3.got"
    ms=$(($(now_ms) - start))
    printf '%b' "$2" >"$TMP/$3.want"
    if ! cmp -s "$TMP/$3.got" "$TMP/$3.want"; then
        echo "FAIL $3:"
        printf 'got:  '
        od -An -tx1 -v "$TMP/$3.got"
        printf 'want: '
        od -An -tx1 -v "$TMP/$3.want"
        exit 1
    fi
    printf 'PASS %-12s cells=%-6s wall=%sms\n' "$3" "$(wc -l <"$1" | tr -d ' ')" "$ms"
}
no_mext() { # elf: fail if it contains an RV32M instruction
    "$OBJDUMP" -d "$1" | grep -Eq '\b(mul|mulh|div|divu|rem|remu)\b' &&
        {
            echo "FAIL $1: emitted an M-extension instruction"
            exit 1
        } || :
}

CFLAGS="-march=rv32i -mabi=ilp32 -ffreestanding -nostdlib -O0 -Wall"
ZFLAGS="-march=rv32i_zicsr -mabi=ilp32 -ffreestanding -nostdlib -O0 -Wall"
LDC="--oformat=elf32-littleriscv -s -n -T $DIR/rtos.ld"     # C: reserves a stack
LDS="--oformat=elf32-littleriscv -s -n -T $DIR/../rv32i.ld" # asm: no stack
"$GCC" $CFLAGS -c "$DIR/crt0.S" -o "$TMP/crt0.o"

# ---- 1. context switch: cooperative two-task kernel over ctx-switch.S --------
# The cooperative kernel IS the context-switch test: the two tasks alternate to
# "ABABAB!" only if every ctx_switch preserves and restores the callee-saved set.
echo "== context switch =="
"$GCC" $CFLAGS -c "$DIR/ctx-switch.S" -o "$TMP/ctx.o"
"$GCC" $CFLAGS -c "$DIR/test-ctx-switch.c" -o "$TMP/ctxsw.o"
no_mext "$TMP/ctxsw.o" # the only C in this test; the asm fixtures cannot emit M
"$LD" $LDC -o "$TMP/ctxsw.elf" "$TMP/crt0.o" "$TMP/ctxsw.o" "$TMP/ctx.o"
"$RVOPT" mux --indirect "$TMP/ctxsw.elf" >"$TMP/ctxsw.dec"
run "$TMP/ctxsw.dec" 'ABABAB!' "ctxsw"

# ---- 2. Zicsr: CSR read/modify forms + unsupported-CSR rejection -------------
echo "== CSR =="
"$AS" -march=rv32i_zicsr -mabi=ilp32 -o "$TMP/csr.o" "$DIR/test-csr.S"
"$LD" $LDS -o "$TMP/csr.elf" "$TMP/csr.o"
"$RVOPT" mux "$TMP/csr.elf" >"$TMP/csr.dec"
run "$TMP/csr.dec" 'C' "csr"
printf '\223\010\320\005\163\020\000\000' >"$TMP/bad.bin" # li a7,93 ; csrrw x0,0x0,x0
if "$RVOPT" mux "$TMP/bad.bin" >/dev/null 2>"$TMP/bad.err"; then
    echo "FAIL: unsupported CSR number was accepted"
    exit 1
fi
grep -q 'unsupported CSR' "$TMP/bad.err" || {
    echo "FAIL: wrong CSR reject msg"
    cat "$TMP/bad.err"
    exit 1
}
echo "PASS csr_reject   (unsupported CSR fails at emit)"

# ---- 3. timer interrupt + mret + runtime-mtvec rejection --------------------
echo "== timer =="
"$AS" -march=rv32i_zicsr -mabi=ilp32 -o "$TMP/timer.o" "$DIR/test-timer.S"
"$LD" $LDS -o "$TMP/timer.elf" "$TMP/timer.o"
"$RVOPT" mux --timer "$TMP/timer.elf" >"$TMP/timer.dec"
run "$TMP/timer.dec" 'TTR' "timer"
# A runtime (non-constant) mtvec must be rejected, not compiled against a stale vector.
printf '%s\n' '.text' '.global _start' '_start:' '  lw t0, 0(sp)' \
    '  csrw mtvec, t0' '  li t0,0x80' '  csrs mie,t0' '  csrsi mstatus,8' \
    '1: wfi' '  j 1b' >"$TMP/rt.S"
"$AS" -march=rv32i_zicsr -mabi=ilp32 -o "$TMP/rt.o" "$TMP/rt.S"
"$LD" $LDS -o "$TMP/rt.elf" "$TMP/rt.o"
if "$RVOPT" mux --timer "$TMP/rt.elf" >/dev/null 2>"$TMP/rt.err"; then
    echo "FAIL: runtime mtvec was accepted under --timer"
    exit 1
fi
grep -q 'compile-time mtvec' "$TMP/rt.err" || {
    echo "FAIL: wrong mtvec reject msg"
    cat "$TMP/rt.err"
    exit 1
}
echo "PASS mtvec_reject (runtime mtvec fails under --timer)"

# ---- 4. preemptive RTOS core (rtos.c) under two scenarios -------------------
# The capstone combines context switch (ktrap.S), CSRs, and the timer. The core
# rtos.c (scheduler, semaphores, priority-inheritance mutex) links against each
# scenario. 4a proves inheritance avoids inversion; 4b covers the counting sem.
echo "== preemptive RTOS =="
"$GCC" $ZFLAGS -c "$DIR/ktrap.S" -o "$TMP/ktrap.o"
"$GCC" $ZFLAGS -c "$DIR/rtos.c" -o "$TMP/rtos.o"
no_mext "$TMP/rtos.o"
# 4a. priority-inversion scenario: priority inheritance yields "LHM"
"$GCC" $ZFLAGS -c "$DIR/test-rtos.c" -o "$TMP/test-rtos.o"
no_mext "$TMP/test-rtos.o"
"$LD" $LDC -o "$TMP/rtos.elf" "$TMP/ktrap.o" "$TMP/rtos.o" "$TMP/test-rtos.o"
"$RVOPT" mux --timer "$TMP/rtos.elf" >"$TMP/rtos.dec"
run "$TMP/rtos.dec" 'LHM' "rtos" # priority inheritance avoids unbounded inversion
# 4b. counting-semaphore scenario: producer fills to 3, consumer drains "ABC"
"$GCC" $ZFLAGS -c "$DIR/test-semaphore.c" -o "$TMP/test-sem.o"
no_mext "$TMP/test-sem.o"
"$LD" $LDC -o "$TMP/sem.elf" "$TMP/ktrap.o" "$TMP/rtos.o" "$TMP/test-sem.o"
"$RVOPT" mux --timer "$TMP/sem.elf" >"$TMP/sem.dec"
run "$TMP/sem.dec" 'ABC' "semaphore"

echo "all RV32I RTOS checks passed"
