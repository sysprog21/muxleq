#!/usr/bin/env python3
import sys

high = 1 << 21
src = high + 1
cells = {
    0: src,
    1: high,
    2: 0x80000006,  # MOVE marker to the first cell past the old 2M window.
    3: high,
    4: 0xFFFFFFFF,  # PUT high cell.
    5: 0,
    6: 0,
    7: 0,
    8: 0xFFFFFFFF,  # SUBLEQ 0,0,-1 halt.
    src: ord("K"),
}

for i in range(src + 1):
    print(cells.get(i, 0))
