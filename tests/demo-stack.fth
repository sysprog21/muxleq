\ ceForth-conformance stack words: depth, 2over, 2swap.
\ depth is now in the default forth vocab (was system-only, so 'depth' at the REPL threw -13).
\ roll is deferred: the metacompiler can't run 'recurse' at build time and no demo needs it.
: t
  depth . cr                       \ empty stack -> 0
  1 2 3 4 2over depth . cr         \ 2over adds a copy of the 2nd pair -> depth 6
  2drop 2drop 2drop                \ clear
  1 2 3 4 2swap . . . . cr         \ 2swap -> 3 4 1 2, printed top-first: 2 1 4 3
  1 2 3 4 2over . . . . . . cr     \ 2over -> 1 2 3 4 1 2, printed top-first: 2 1 4 3 2 1
;
t
bye
