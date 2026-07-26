( example: ANSI escape sequences )

\ Demonstrates ANSI escape sequences for colored text output

' ( <ok> !  \ Disable "ok" prompt for cleaner output [non-portable]

\ Helper: Send ANSI escape sequence prefix ESC[
: esc[  ( -- )
  27 emit   \ ESC character (ASCII 27)
  91 emit   \ '[' character (ASCII 91)
;

\ ANSI Foreground Color Words (30-37 range)
\ Format: ESC[3<digit>m where digit = 0-7 for different colors
: black   ( -- )  esc[  51 emit 48 emit  109 emit ;
: red     ( -- )  esc[  51 emit 49 emit  109 emit ;
: green   ( -- )  esc[  51 emit 50 emit  109 emit ;
: yellow  ( -- )  esc[  51 emit 51 emit  109 emit ;
: blue    ( -- )  esc[  51 emit 52 emit  109 emit ;
: magenta ( -- )  esc[  51 emit 53 emit  109 emit ;
: cyan    ( -- )  esc[  51 emit 54 emit  109 emit ;
: white   ( -- )  esc[  51 emit 55 emit  109 emit ;
: reset   ( -- )  esc[  48 emit        109 emit ; \ Reset all attributes

\ Demo: Print "Rainbow" with each letter in a different color
: rainbow ( -- )
  red     82 emit    \ 82 = ASCII 'R'
  yellow  97 emit    \ 97 = ASCII 'a')
  green  105 emit    \ 105 = ASCII 'i'
  cyan   110 emit    \ 110 = ASCII 'n'
  blue    98 emit    \ 98 = ASCII 'b'
  magenta 111 emit   \ 111 = ASCII 'o'
  white  119 emit    \ 119 = ASCII 'w'
  reset  cr          \ Reset colors and newline
;

\ Display colorful "Rainbow" text
rainbow  \ Display colorful "Rainbow" text
