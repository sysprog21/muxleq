\ Sieve of Eratosthenes -- primes below 120. A computational eForth application
\ (and the Eratosthenes benchmark from the roadmap): a flag array in 'create'd
\ cells, marked by stepping each prime's multiples. Deterministic output, used
\ as a golden test.
120 constant N
create fl N cells allot
: prime? ( i -- f ) cells fl + @ 0= ;
: mark  ( i -- )    cells fl + 1 swap ! ;
: sieve
  fl N cells 0 fill
  2 begin dup N < while
    dup prime? if
      dup .
      dup 2* begin dup N < while dup mark over + repeat drop
    then
    1+
  repeat drop cr ;
sieve
bye
