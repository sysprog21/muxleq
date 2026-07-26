/*
 * DureMark Benchmark - Main Header
 * Copyright (c) 2025 Serge Vakulenko
 *
 * Simplified CPU benchmark inspired by CoreMark Designed for 8-bit, 16-bit, and
 * 32-bit processors
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef uint32_t du_ticks_t;

/* Algorithm IDs */
enum {
    ID_LIST = 1 << 0,
    ID_MATRIX = 1 << 1,
    ID_STATE = 1 << 2,
};

/* List data structures */
typedef struct du_list_node {
    struct du_list_node *next;
    uint16_t data;
    uint16_t idx;
} du_list_node_t;

/* Matrix types */
typedef int16_t matdat_t;
typedef int32_t matres_t;

/* C holds the wider results, A and B the narrow inputs */
typedef struct mat_params {
    matdat_t *A, *B;
    matres_t *C;
} mat_params_t;

/* State machine states */
typedef enum {
    DU_STATE_START = 0,
    DU_STATE_DIGIT,
    DU_STATE_DOT,
    DU_STATE_SIGN,
    DU_STATE_INVALID,
    NUM_STATES
} du_state_t;

/* Results structure */
typedef struct {
    /* Inputs */
    unsigned long iterations;
    unsigned execs;

    /* Workload-specific data */
    du_list_node_t *list;
    mat_params_t mat;

    /* Outputs */
    uint32_t checksum;

    /* Timing (in ticks) */
    du_ticks_t list_ticks;
    du_ticks_t matrix_ticks;
    du_ticks_t state_ticks;
    du_ticks_t total_ticks;
} du_results_t;

/* Function declarations Workload benchmarks return a value derived from their
 * computed results. Callers must fold it into a checksum so the optimizer
 * cannot discard the work as dead code.
 */

/* List functions */
du_list_node_t *du_list_init(void);
uint32_t du_bench_list(du_results_t *res, int16_t finder_idx);

/* Matrix functions */
void du_init_matrix(mat_params_t *p);
uint32_t du_bench_matrix(mat_params_t *p, matdat_t val);

/* State machine functions */
void du_init_state(void);
uint32_t du_bench_state(int16_t step);
