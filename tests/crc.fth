.( example: CRC-16 )

: crc ( b u -- u : calculate ccitt-ffff CRC )
        $FFFF >r begin ?dup while
                over c@ r> swap
                ( CCITT polynomial $1021, or "x16 + x12 + x5 + 1" )
                over $8 rshift xor ( crc x )
                dup  $4 rshift xor ( crc x )
                dup  $5 lshift xor ( crc x )
                dup  $C lshift xor ( crc x )
                swap $8 lshift xor ( crc )
                $FFFF and          ( keep 16-bit; wide cell won't truncate )
                >r +string
        repeat r> nip ;

.( to test the routines, type: )

\ Calculate CRC of a single byte (value 1). Use a created buffer: c! is
\ ( c a -- ), so the old 'here 1 c!' stored HERE's scratch at address 1 and
\ CRC'd whatever byte sat at HERE -- deterministic but not the byte it claimed.
create one $01 c,
.( one 1 crc . => ) one 1 crc .                 \ CRC of the single byte 1

\ Calculate CRC of multiple bytes
create test-data $12 c, $34 c, $56 c, $78 c,
.( test-data 4 crc . => ) test-data 4 crc .     \ Calculate CRC of 4-byte sequence
