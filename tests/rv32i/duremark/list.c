/*
 * DureMark Linked List Workload Simplified linked list operations: find,
 * reverse, bubble sort
 */

#include "duremark.h"

static du_list_node_t mem_list[32];

static du_list_node_t *du_list_find(du_list_node_t *list, uint16_t idx)
{
    while (list) {
        if (list->idx == idx)
            return list;
        list = list->next;
    }
    return NULL;
}

static du_list_node_t *du_list_reverse(du_list_node_t *list)
{
    du_list_node_t *prev = NULL;

    while (list) {
        du_list_node_t *tmp = list->next;
        list->next = prev;
        prev = list;
        list = tmp;
    }
    return prev;
}

/* Bubble sort by data value, or by index when by_idx is set, which restores the
 * original order after a data sort.
 */
static du_list_node_t *du_list_sort(du_list_node_t *list, bool by_idx)
{
    bool swapped;

    if (!list || !list->next)
        return list;
    swapped = true;
    while (swapped) {
        du_list_node_t *current = list;
        swapped = false;

        while (current && current->next) {
            du_list_node_t *next = current->next;
            uint16_t a = by_idx ? current->idx : current->data;
            uint16_t b = by_idx ? next->idx : next->data;

            if (a > b) {
                /* Swap data */
                uint16_t tmp_data = current->data;
                uint16_t tmp_idx = current->idx;
                current->data = next->data;
                current->idx = next->idx;
                next->data = tmp_data;
                next->idx = tmp_idx;
                swapped = true;
            }
            current = next;
        }
    }
    return list;
}

du_list_node_t *du_list_init(void)
{
    unsigned size = sizeof(mem_list) / sizeof(mem_list[0]);
    unsigned i;
    du_list_node_t *prev = NULL;

    /* Initialize list */
    for (i = 0; i < size; i++) {
        du_list_node_t *current = &mem_list[i];

        current->data = ((~i & 0xF) << 4) | (i & 0xF);
        current->idx = i;
        current->next = NULL;

        if (prev)
            prev->next = current;
        prev = current;
    }
    return mem_list;
}

uint32_t du_bench_list(du_results_t *res, int16_t finder_idx)
{
    du_list_node_t *list = res->list;
    unsigned find_num = 20;
    unsigned i;
    uint32_t sum = 0;

    /* Find operations */
    for (i = 0; i < find_num; i++) {
        du_list_node_t *found = du_list_find(list, (uint16_t) (finder_idx + i));
        if (found)
            sum += found->data;
        list = du_list_reverse(list);
    }

    /* Sort by data */
    list = du_list_sort(list, false);

    /* Restore original order */
    res->list = du_list_sort(list, true);

    return sum;
}
