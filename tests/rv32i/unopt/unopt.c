/*
 * Freestanding base-RV32I (no mul/div) fold-headroom benchmark. An xorshift
 * PRNG folded into a sum, plus constant setup; du_main writes the 4-byte
 * checksum via the write ecall (inlined, so there is one function / one ret --
 * rvopt -mux supports a single ret call site). Under -O0 gcc leaves constants
 * un-folded and spills every var (redundant loads, mv's) -- real optimizer
 * headroom rvopt's folder captures; under -O2 it is tight. Same output either.
 */
void du_main(void)
{
    unsigned x = 0x1234567u, sum = 0u;
    for (int i = 0; i < 500; i++) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        sum += x + (unsigned) i;
    }
    unsigned char b[4] = {(unsigned char) sum, (unsigned char) (sum >> 8),
                          (unsigned char) (sum >> 16),
                          (unsigned char) (sum >> 24)};
    register long a7 __asm__("a7") = 64; /* write */
    register long a0 __asm__("a0") = 1;  /* fd (ignored by the VM) */
    register long a1 __asm__("a1") = (long) b;
    register long a2 __asm__("a2") = 4;
    __asm__ volatile("ecall" ::"r"(a7), "r"(a0), "r"(a1), "r"(a2) : "memory");
}
