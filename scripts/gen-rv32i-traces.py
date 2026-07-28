#!/usr/bin/env python3
import string
import sys
from pathlib import Path

# These trace-cell constants mirror the RV32I_TRACE_* / RV32I_MOVE_C enum in
# rv32i.inc. They cannot be shared from a single file: this generator needs
# them to pattern-match the traces in stage0.dec before it can emit anything.
# Both copies are validated against the image -- here by the pattern match below
# (a mismatch aborts the build), in rv32i.inc by the golden gates.
MEM_SIZE = 1 << 15
NEGATIVE_FLAG = MEM_SIZE
INSN_SIZE = 3
RV32I_MOVE_C = NEGATIVE_FLAG | 6
ZERO = 0
BASE = 4
STRIDE = 7
DEC = 8
VALUE = 11
LIMIT = 12
CURSOR = 38
COND = 39


def u16(n):
    return n & 0xFFFF


def read_image(path):
    return [u16(int(line)) for line in Path(path).read_text().split()]


def at(m, base, offs):
    return m[base + offs]


def find_loader(m):
    for pc in range(0, len(m) - 38):
        q = at(m, pc, 17)
        checks = [
            (0, CURSOR),
            (1, pc + 3),
            (2, RV32I_MOVE_C),
            (3, ZERO),
            (4, VALUE),
            (5, RV32I_MOVE_C),
            (6, STRIDE),
            (7, CURSOR),
            (8, pc + 9),
            (9, BASE),
            (10, LIMIT),
            (11, RV32I_MOVE_C),
            (12, VALUE),
            (13, LIMIT),
            (14, pc + 15),
            (15, ZERO),
            (16, LIMIT),
            (18, VALUE),
            (19, pc + 23),
            (20, RV32I_MOVE_C),
            (21, ZERO),
            (22, ZERO),
            (23, q),
        ]
        if not all(at(m, pc, o) == u16(v) for o, v in checks) or q + 14 >= len(m):
            continue
        taken = [
            (0, STRIDE),
            (2, q + INSN_SIZE),
            (3, at(m, q, 1)),
            (5, RV32I_MOVE_C),
            (6, CURSOR),
            (8, RV32I_MOVE_C),
            (9, VALUE),
            (10, CURSOR),
            (11, RV32I_MOVE_C),
            (12, ZERO),
            (13, ZERO),
            (14, pc),
        ]
        if all(at(m, q, o) == u16(v) for o, v in taken):
            return pc
    raise SystemExit(
        "gen-rv32i-traces: loader trace not found in stage0.dec -- muxleq.fth "
        "codegen likely moved the RV32I hot traces. Update the patterns here to "
        "match, or build with ENABLE_RV32I=0 to skip the superinstructions."
    )


def find_trace(m, start, span, checks):
    for pc in range(start, len(m) - span):
        if all(at(m, pc, o) == u16(v(pc)) for o, v in checks):
            return pc
    raise SystemExit(
        "gen-rv32i-traces: hot trace not found in stage0.dec -- muxleq.fth "
        "codegen likely moved the RV32I hot traces. Update the patterns here to "
        "match, or build with ENABLE_RV32I=0 to skip the superinstructions."
    )


def find_pair_update(m, start, computed_dest, loader):
    for pc in range(start, len(m) - 20):
        alt_addr = at(m, pc, 1)
        # alt_addr is emitted as a cell and used to index m[] at runtime; a
        # drifted match holding a flag cell (>= MEM_SIZE) would index OOB.
        if alt_addr >= MEM_SIZE:
            continue
        checks = [
            (0, DEC),
            (2, pc + 3),
            (3, alt_addr),
            (4, pc + 7),
            (5, RV32I_MOVE_C),
            (6, COND),
            (7, ZERO),
            (8, RV32I_MOVE_C),
            (9, computed_dest),
            (10, pc + 12),
            (11, RV32I_MOVE_C),
            (12, ZERO),
            (13, COND),
            (14, RV32I_MOVE_C),
            (15, DEC),
            (16, computed_dest),
            (17, pc + 18),
            (18, ZERO),
            (19, ZERO),
            (20, loader),
        ]
        if all(at(m, pc, o) == u16(v) for o, v in checks):
            return pc, alt_addr
    raise SystemExit(
        "gen-rv32i-traces: pair-update trace not found in stage0.dec -- "
        "muxleq.fth codegen likely changed the RV32I hot trace shape. Update "
        "the patterns here, or build with ENABLE_RV32I=0 to skip the "
        "superinstructions."
    )


def main(argv):
    if len(argv) != 4:
        raise SystemExit("usage: gen-rv32i-traces.py stage0.dec template output")
    m = read_image(argv[1])
    loader = find_loader(m)
    taken = at(m, loader, 17)
    computed_dest = at(m, taken, 1)

    pair, alt_addr = find_pair_update(m, taken + 15, computed_dest, loader)
    reload = find_trace(
        m,
        pair + 21,
        11,
        [
            (0, lambda pc: computed_dest),
            (1, lambda pc: pc + 3),
            (2, lambda pc: RV32I_MOVE_C),
            (3, lambda pc: ZERO),
            (4, lambda pc: CURSOR),
            (5, lambda pc: RV32I_MOVE_C),
            (6, lambda pc: DEC),
            (7, lambda pc: computed_dest),
            (8, lambda pc: pc + 9),
            (9, lambda pc: ZERO),
            (10, lambda pc: ZERO),
            (11, lambda pc: loader),
        ],
    )
    fold = find_trace(
        m,
        reload + 12,
        53,
        [
            (0, lambda pc: LIMIT),
            (1, lambda pc: ZERO),
            (2, lambda pc: pc + 3),
            (3, lambda pc: ZERO),
            (4, lambda pc: LIMIT),
            (5, lambda pc: pc + 6),
            (39, lambda pc: DEC),
            (40, lambda pc: VALUE),
            (41, lambda pc: pc + 42),
            (42, lambda pc: ZERO),
            (43, lambda pc: VALUE),
            (44, lambda pc: pc + 48),
            (48, lambda pc: LIMIT),
            (49, lambda pc: COND),
            (50, lambda pc: RV32I_MOVE_C),
            (51, lambda pc: ZERO),
            (52, lambda pc: ZERO),
            (53, lambda pc: loader),
        ],
    )
    values = {
        "loader_loop": loader,
        "taken_trace": taken,
        "taken_trace_end": taken + 14,
        "taken_trace_fallthrough": at(m, taken, 2),
        "patched_move": taken + 6,
        "indirect_load_operand": loader + 3,
        "loop_exit_operand": loader + 23,
        "patched_move_dest_operand": taken + 7,
        "computed_dest_cell": computed_dest,
        "alt_addr_cell": alt_addr,
        "pair_update_loop": pair,
        "pair_update_loop_end": pair + 20,
        "altaddr_move_dest_operand": pair + 7,
        "cond_restore_src_operand": pair + 12,
        "cursor_reload_trace": reload,
        "cursor_reload_trace_end": reload + 11,
        "cursor_reload_src_operand": reload + 3,
        "condition_fold_loop": fold,
        "condition_fold_loop_end": fold + 53,
        "condition_fold_exit_operand": fold + 53,
    }
    tmpl = string.Template(Path(argv[2]).read_text())
    Path(argv[3]).write_text(tmpl.substitute(values))


if __name__ == "__main__":
    main(sys.argv)
