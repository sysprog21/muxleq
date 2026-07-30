# MUXLEQ host contract

MUXLEQ is a wide, cell-addressed host VM. `./muxleq` runs the baked eForth
image; `./muxleq FILE` runs a standalone `rvopt mux` image. It keeps muxleq's
direct self-modifying-code model: operand cells are ordinary memory cells, and
the interpreter rereads them when each instruction executes.

## Cell Encoding

- Cell width: 32 bits.
- Addressing: cell-addressed, not byte-addressed.
- Branch/sign bit: `0x80000000`.
- Address bits: `0x7fffffff`.
- I/O and halt marker: `0xffffffff`.
- MUX mask-address cell `6` is hardwired to zero, so
  `A B 0x80000006` is a MOVE.
- MUX mask-address `0x7ffffffe` is reserved as a native shift, so
  `A B 0xfffffffe` computes `[B] = [A] >> 1`. The eForth `shift` primitive
  emits it to avoid a cell-width bit loop. This is a new ISA reservation,
  like the `0xffffffff` I/O marker: it is matched on the raw operand before
  any arena masking, and a genuine mask address is a small cell index, so no
  MUXLEQ emitter uses `0x7ffffffe`.

## eForth-32 Target Encoding

The 32-bit eForth port targets this same host encoding directly. P0c changes
the metacompiler constants, not the VM instruction shape:

- `forth/10-meta-assembler.fth`: `=cell` becomes `4`.
- Target image stores and loads pack/unpack four little-endian bytes per target
  cell.
- Target dictionary alignment becomes 4-byte alignment.
- Target decimal output and checksums mask target cells with `0xffffffff`.
- Target signed-decimal output splits negative values at `0x80000000`.
- `forth/20-target-vm.fth`: `bwidth` becomes `$20`.
- `rvsign` and `MUXR` use `$80000000`.
- Halt and I/O keep muxleq's `0xffffffff` marker.

The existing 16-bit metacompiler divides byte addresses by two before emitting
operand cells. The 32-bit port keeps the same byte-addressed dictionary pointer
inside the metacompiler, but divides by four when emitting a VM cell address and
multiplies by four when reconstructing a target byte address. That keeps packed
strings byte-dense while the generated MUXLEQ image remains cell-addressed.

`mwidth` stays `$40`: the boot-time width probe only needs to reject machines
wider than the supported maximum, and 32 still fits under that guard. The
hard boot check must compare the measured width with the new `$20` `bwidth`;
otherwise the ported image will take the existing "Not a 16-bit SUBLEQ VM"
failure path.

Cell addressing is a P0 decision. The P1 Linux/toolchain work must retarget
eternal's byte-addressed backend and kernel assumptions to this cell-addressed
host, or add a separate compatibility mode later. P0b does not add indirect
addressing or interrupts.

## Host Arena

The architectural encoding leaves 31 address bits, but the host still bounds
untrusted images. The loader allocates at least `MUX_MIN_CELLS` (`1 << 16` by
default, 64K cells / 256 KiB) and then grows to the smallest power-of-two cell
window that holds the input image, up to `MUX_MAX_CELLS` (`1 << 26` by
default, 64M cells / 256 MiB). Every runtime memory access is masked into that
window.

That wrapping model is deliberate. It preserves the old muxleq behavior for
malformed or out-of-window operands without turning the VM into a faulting
machine, while the loader still rejects images larger than the configured host
cap.
