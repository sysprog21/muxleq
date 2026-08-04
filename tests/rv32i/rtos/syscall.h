/*
 * Freestanding syscall stub for the RV32I RTOS demos.
 *
 * The demos and kernel call putchar()/exit(). muxleq's live ABI is
 * a7=write(64)/exit(93) (see tests/rv32i/hello.S and
 * docs/rvopt-native-muxleq.md). This ONE stub bridges to it: putchar becomes a
 * 1-byte write(1,...), exit becomes exit(93). No per-program ecall emission, no
 * libc.
 */

#ifndef RTOS_SYSCALL_H
#define RTOS_SYSCALL_H

#define SYS_WRITE 64
#define SYS_EXIT 93

static inline void sys_write(int fd, const void *buf, int len)
{
    register int a0 asm("a0") = fd;
    register const void *a1 asm("a1") = buf;
    register int a2 asm("a2") = len;
    register int a7 asm("a7") = SYS_WRITE;
    asm volatile("ecall" : : "r"(a0), "r"(a1), "r"(a2), "r"(a7) : "memory");
}

static inline int putchar(int c)
{
    char ch = (char) c;
    sys_write(1, &ch, 1);
    return c;
}

static inline void exit(int code)
{
    register int a0 asm("a0") = code;
    register int a7 asm("a7") = SYS_EXIT;
    asm volatile("ecall" : : "r"(a0), "r"(a7) : "memory");
    __builtin_unreachable();
}

#endif /* RTOS_SYSCALL_H */
