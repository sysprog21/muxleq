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
  emits it to avoid a cell-width bit loop. This is an ISA reservation like the
  `0xffffffff` I/O marker: it is matched on the raw operand before any arena
  masking, and a genuine mask address is a small cell index, so no MUXLEQ
  emitter uses `0x7ffffffe`. It is the only such reservation. Downward bit
  movement is the one thing same-lane MUX and upward-carrying SUBLEQ have no
  direct primitive for -- only a bit-serial loop -- so a right shift fills that
  gap; a variable shift, multiply, and divide are compositions of it, and byte
  access is a storage convention, so all of those stay in the eForth software
  layer rather than the ISA.

## eForth Target Encoding

The eForth image targets this host encoding directly. It is expressed in the
metacompiler constants, not in the VM instruction shape:

- `forth/10-meta-assembler.fth`: `=cell` is `4`.
- Target image stores and loads pack/unpack four little-endian bytes per target
  cell.
- Target dictionary alignment is 4-byte.
- Target decimal output and checksums mask target cells with `0xffffffff`.
- Target signed-decimal output splits negative values at `0x80000000`.
- `forth/20-target-vm.fth`: `bwidth` is `$20`.
- `MUXR` masks with `$80000000` (`muxflag`, i.e. `signbit`).
- Halt and I/O use the `0xffffffff` marker.

The metacompiler keeps a byte-addressed dictionary pointer internally: it divides
by four when emitting a VM cell address and multiplies by four when reconstructing
a target byte address. That keeps packed name strings byte-dense while the
generated MUXLEQ image stays cell-addressed.

`mwidth` is `$40`: the boot-time width probe only needs to reject machines wider
than the supported maximum, and 32 fits under that guard. The hard boot check
compares the measured width against `bwidth` (`$20`); a mismatch takes the boot
failure path (message `err-str` in `forth/20-target-vm.fth`, "Error: Not a 32-bit
MUXLEQ VM").

Cell addressing is fundamental to this host, not a mode. A byte-addressed
LLVM/C backend or kernel targeting MUXLEQ must map its byte-addressed model onto
this cell-addressed one, or add a compatibility layer; the host itself provides
no indirect addressing or interrupts.

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
