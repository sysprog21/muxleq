\ value/to conformance (ceForth has both). A 'value' pushes its contents; 'to' overwrites it,
\ parsing the next word interpret-time (like ceForth's 'to'). Implemented as a mutable constant
\ (same (const) representation), since 'does>' can't be compiled by the metacompiler; 'to' inlines
\ ''''s body ('token find ?found cfa') to dodge the gforth-vs-target ''' ambiguity.
5 value x
x .                 \ 5
7 to x
x .                 \ 7
x 100 + value y
y .                 \ 107
1 to x
x . y .             \ 1 107 (to x does not touch y)
cr
bye
