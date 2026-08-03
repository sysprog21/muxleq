/*
 * Self-contained RV32I soft multiply/divide/modulo for DureMark.
 *
 * Base RV32I has no MUL/DIV, so the matrix and number-format workloads
 * reference __mulsi3/__udivsi3/__umodsi3/__modsi3. libgcc supplies those, but
 * its div/mod helpers return through a shared millicode tail via "jr t0" -- a
 * runtime JALR that "rvopt mux" cannot lower. These replacements call nothing
 * and return with a plain ret, so the whole image lowers to native MUXLEQ.
 * Linking these instead of libgcc leaves the arithmetic (and the checksum)
 * unchanged.
 */
#include <stdint.h>

uint32_t __mulsi3(uint32_t a, uint32_t b)
{
    uint32_t r = 0;
    while (b) {
        if (b & 1)
            r += a;
        a <<= 1;
        b >>= 1;
    }
    return r;
}

/* One restoring-division pass yields both quotient and remainder. Static so it
 * inlines into each entry point; even un-inlined it is a jal/ret leaf, still
 * lowerable. Written with shifts and subtracts only, so it emits no div/mod op
 * and cannot recurse into these helpers. For b == 0 the loop naturally yields q
 * = 0xFFFFFFFF and r = a, matching RISC-V DIVU/REMU; the DureMark workloads
 * never divide by zero (every divisor is a nonzero constant), so that is
 * defensive only.
 */
static uint32_t udivmod(uint32_t a, uint32_t b, uint32_t *rem)
{
    uint32_t q = 0, r = 0;
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((a >> i) & 1);
        if (r >= b) {
            r -= b;
            q |= 1u << i;
        }
    }
    if (rem)
        *rem = r;
    return q;
}

uint32_t __udivsi3(uint32_t a, uint32_t b)
{
    return udivmod(a, b, 0);
}

uint32_t __umodsi3(uint32_t a, uint32_t b)
{
    uint32_t r;
    udivmod(a, b, &r);
    return r;
}

int32_t __modsi3(int32_t a, int32_t b)
{
    uint32_t ua = a < 0 ? -(uint32_t) a : (uint32_t) a;
    uint32_t ub = b < 0 ? -(uint32_t) b : (uint32_t) b;
    uint32_t r;
    udivmod(ua, ub, &r);

    /* Negate in the unsigned domain: r can be 0x80000000 on the div-by-zero
     * path (a == INT32_MIN, b == 0), and -(int32_t) 0x80000000 is signed
     * overflow.
     */
    return a < 0 ? (int32_t) -(uint32_t) r : (int32_t) r; /* remainder's sign = dividend's */
}
