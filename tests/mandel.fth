.( example: Mandelbrot set )

\ This program renders the Mandelbrot set to a text console. It uses
\ 4-bit fixed-point arithmetic to simulate fractional numbers on an
\ integer-only system. The core algorithm iterates the formula z = z^2 + c
\ for each point on a 2D grid and selects a character to display based
\ on how quickly the point's magnitude escapes a fixed threshold.

\ --- Constants and Configuration ---

16 constant scale           \ The core of the fixed-point math system.
                            \ Represents the value of 1.0. Must be a power of 2.

64 constant thresh          \ Escape threshold. A point has "escaped" if its
                            \ magnitude |z| > 2. This constant is pre-calculated
                            \ for the scaled environment: (2*scale)^2 / scale.

48 constant maxiter         \ Maximum iterations. Prevents infinite loops for
                            \ points that are inside the Mandelbrot set.

\ The boundaries of the complex plane to be rendered. These values are
\ pre-multiplied by 'scale' to avoid repeated calculations later.
-32 constant xmin           \ Real axis (x) minimum, scaled (-2.0 * 16)
 16 constant xmax           \ Real axis (x) maximum, scaled (1.0 * 16)
  1 constant xstep          \ Step size for x-axis (scaled)
-20 constant ymin           \ Imaginary axis (y) minimum, scaled (-1.25 * 16)
 20 constant ymax           \ Imaginary axis (y) maximum, scaled (1.25 * 16)
  1 constant ystep          \ Step size for y-axis (scaled)

\ A simple palette for mapping iteration counts to display characters.
create palette
    char . c, char - c, char - c, char = c, char o c,
    char + c, char * c, char # c, char % c, bl c,

\ --- Variables for Main Loop Control ---

variable x                  \ Stores the current x-coordinate (real part)
variable y                  \ Stores the current y-coordinate (imaginary part)
variable ci                 \ Caches the current y-coord for the inner loop

\ --- Core Words ---

: output ( iter -- )        \ Selects and emits a character from the palette.
    5 / palette + c@ emit ; \ Maps a range of counts to each character.

: muls ( a b -- ab/scale )  \ Performs scaled multiplication for fixed-point numbers.
    * scale / ;             \ Multiplies two scaled numbers and rescales the result.

\ --- Complex Number Arithmetic ---

: c2 ( ar ai -- ar' ai' )    \ Calculates a complex square: z' = z^2
    \ Implements z^2 = (ar^2 - ai^2) + (2*ar*ai)i using scaled math.
    2dup muls 2* >r         \ Calculate new imag part (2*ar*ai/s) and stash it.
    dup muls >r             \ Calculate ai*ai/s and stash it.
    dup muls r> -           \ new_ar = ar*ar/s - ai*ai/s.
    r> ;                    \ Retrieve the stashed new imaginary part.

: abs2 ( ar ai -- |z|^2/scale ) \ Calculates the scaled squared magnitude of z.
    \ Implements |z|^2/s = (ar*ar/s) + (ai*ai/s).
    dup muls swap dup muls + ;

\ --- Mandelbrot Iteration Logic ---

: iter ( cr ci n zr zi -- cr ci n+1 zr' zi' ) \ Performs one z = z^2 + c step.
    c2 >r >r 1+             \ Calculate z^2, stash results, increment n.
    r> 3 pick +             \ zr_new = zr_temp + cr.
    r> 3 pick + ;           \ zi_new = zi_temp + ci.

: point ( cr ci -- n )      \ Calculates escape iterations for a single point.
    0 0 0                   \ Initialize stack with n=0, zr=0, zi=0.
    begin
        iter                \ Perform one z = z^2 + c step.
        2dup abs2 thresh >  \ Check if |z|^2 has escaped the threshold.
        >r 2 pick maxiter > r> or \ Check if max iterations was reached.
    until                   \ Loop until one of the above conditions is true.

    \ The loop is done. The stack is ( cr ci n zr zi ).
    \ This complex sequence correctly isolates 'n' for the result.
    \ Step-by-step:
    \   ( cr ci n zr zi ) drop drop -> ( cr ci n )
    \   ( cr ci n ) rot rot         -> ( n cr ci )
    \   ( n cr ci ) drop drop       -> ( n )
    drop drop rot rot drop drop ;

\ --- Top-Level Rendering Loop ---

: mandel ( -- )             \ Renders the full Mandelbrot set.
    cr
    ymin y !
    begin                   \ Outer loop for the y-coordinate.
        y @ ymax > 0=
    while
        y @ ci !            \ Cache y-value as 'ci' for the inner loop.
        xmin x !            \ Reset x to the start of the row.
        begin               \ Inner loop for the x-coordinate.
            x @ xmax > 0=
        while
            x @ ci @ point output
            x @ xstep + x ! \ Move to the next x position.
        repeat
        cr                  \ Newline after drawing a full row.
        y @ ystep + y !     \ Move to the next y position.
    repeat ;

mandel
