( example: block editor )

' ( <ok> ! ( disable ok prompt [non-portable] )

\ This session creates a greeting program using the block editor, demonstrating
\ block editing workflow and word composition in a persistent block storage
\ system.

editor                              ( Enter block-based text editor )
                                    ( Now in editor context - editor commands available )

1 r                                 ( Retrieve block #1 into edit buffer )
                                    ( Block 1 is loaded from storage into memory )
z                                   ( Zero/erase entire block contents )
                                    ( Clears all 16 lines of the 1024-byte block )

( Add individual greeting functions to block lines )
0 a : hello ." Hello World!" cr ;
1 a : welcome ." Welcome to MUXLEQ!" cr ;
2 a : goodbye ." Goodbye for now!" cr ;
3 a : all-greets hello welcome goodbye ;

l                                   ( List current block contents )
                                    ( Shows all 16 lines: 0-3 have code, 4-15 empty )
                                    ( Verifies program structure before execution )
x                                   ( Execute block - compile all definitions )
                                    ( Compiles all : ... ; definitions into dictionary )
                                    ( Makes words available in main Forth system )
q                                   ( Quit editor, return to interpreter )
                                    ( Exit editor context, return to normal Forth )

all-greets                          ( Test the composite greeting word )

\ EDITOR COMMAND REFERENCE:
\ editor    - Enter block editor
\ n r       - Retrieve block number n
\ z         - Zero/erase current block
\ n a text  - Add text to line n (0-15)
\ l         - List all block lines
\ x         - Execute block (compile definitions)
\ q         - Quit editor
\ s         - Save block (if persistent storage enabled)
\ n         - Next block
\ p         - Previous block
