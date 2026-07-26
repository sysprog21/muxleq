/*
 * DureMark Matrix Operations Workload Simplified matrix operations with small
 * fixed-size matrices
 */

#include "duremark.h"

/* Define matrix size */
#define N 10

/* Backing store for A, B (matdat_t) and C (matres_t) laid out contiguously.
 * Typed as matres_t -- the widest element -- so the buffer is aligned for every
 * cast below. A uint8_t array only guarantees byte alignment, which is
 * undefined behavior for the int32_t accesses on strict-alignment targets.
 * Size: N*N*2 matres_t = N*N*8 bytes (A: 2B/elem, B: 2B/elem, C: 4B/elem).
 */
static matres_t mem_matrix[N * N * 2];

static void du_matrix_add_const(matdat_t *A, matdat_t val)
{
    for (uint16_t i = 0; i < N; i++) {
        for (uint16_t j = 0; j < N; j++)
            A[i * N + j] += val;
    }
}

static void du_matrix_mul_const(matres_t *C, matdat_t *A, matdat_t val)
{
    for (uint16_t i = 0; i < N; i++) {
        for (uint16_t j = 0; j < N; j++)
            C[i * N + j] = (matres_t) A[i * N + j] * (matres_t) val;
    }
}

static void du_matrix_mul(matres_t *C, matdat_t *A, matdat_t *B)
{
    for (uint16_t i = 0; i < N; i++) {
        for (uint16_t j = 0; j < N; j++) {
            uint32_t acc = 0;
            for (uint16_t k = 0; k < N; k++) {
                acc += (uint32_t) ((matres_t) A[i * N + k] *
                                   (matres_t) B[k * N + j]);
            }
            C[i * N + j] = (matres_t) acc;
        }
    }
}

static uint32_t du_matrix_sum(matres_t *C)
{
    uint32_t sum = 0;
    for (uint16_t i = 0; i < N; i++) {
        for (uint16_t j = 0; j < N; j++)
            sum += (uint32_t) C[i * N + j];
    }
    return sum;
}

void du_init_matrix(mat_params_t *p)
{
    matdat_t *A, *B;
    matdat_t val;
    uint16_t i;
    uint16_t j;
    int32_t seed = 1;
    int32_t order = 1;

    A = (matdat_t *) mem_matrix;
    B = A + N * N;

    for (i = 0; i < N; i++) {
        for (j = 0; j < N; j++) {
            seed = ((order * seed) % 65536);
            val = (matdat_t) (seed + order);
            if (val > 1000) {
                val = val % 1000;
            }
            B[i * N + j] = val;
            val = (matdat_t) (val + order);
            if (val > 1000) {
                val = val % 1000;
            }
            A[i * N + j] = val;
            order++;
        }
    }

    p->A = A;
    p->B = B;
    p->C = (matres_t *) (B + N * N);
}

uint32_t du_bench_matrix(mat_params_t *p, matdat_t val)
{
    matres_t *C;
    matdat_t *A;
    matdat_t *B;
    uint32_t sum;

    C = p->C;
    A = p->A;
    B = p->B;
    if (val == 0)
        val = 1;

    /* Add constant to A */
    du_matrix_add_const(A, val);

    /* Multiply A by constant */
    du_matrix_mul_const(C, A, val);
    sum = du_matrix_sum(C);

    /* Multiply A by B */
    du_matrix_mul(C, A, B);
    sum += du_matrix_sum(C);

    /* Restore A */
    du_matrix_add_const(A, (matdat_t) (-val));

    return (uint32_t) sum;
}
