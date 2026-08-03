defined <ok> [if] ' ( <ok> ! [then]  \ muxleq: suppress the "ok" prompt so the
\ first stdout byte is the PNG signature 0x89. gforth lacks <ok> and does not
\ prompt in batch mode, so it skips this. Keeps the source runnable on both.
defined warnings [if] warnings off [then]  \ gforth: our integer f*/f//fsqrt
\ deliberately shadow its float words; silence the redefinition notes.

\ Raytracer for MUXLEQ eForth -> RGB888 PNG on stdout.
\ Two spheres + shadow rays + checkerboard ground, quadratic ray-sphere
\ intersection, half-Lambert + Phong shading. One deterministic 64x32 frame
\ (fixed camera), streamed as a real PNG via the svpng stored-block technique.
\ Integer-only 16.16 fixed point: byte-stable across runs and machines. No VM,
\ CLI, or MMIO changes.
\
\ Portable Forth: the same source runs on muxleq eForth (32-bit cells,
\ `./build/muxleq < tests/raytracer.fth`) and on gforth (64-bit cells,
\ `gforth tests/raytracer.fth`), producing the identical PNG byte-for-byte.
\ The CRC folds are masked to 32 bits so the wider cell does not change them.

64 constant W
32 constant H
W 3 * 1 + constant PROW                 \ scanline bytes: filter(1) + W*3 pixels
2 H PROW 5 + * + 4 + constant IDATLEN   \ zlib hdr(2) + H stored blocks + adler(4)

\ ---- state (named cells, not magic addresses) ----
variable cosT  variable sinT
variable ox    variable oy    variable oz     \ ray origin (camera)
variable dx    variable dy    variable dz     \ ray direction
variable ctrx  variable ctry  variable ctrz  variable srad  \ sphere center/radius
variable qa    variable qb    variable qc    variable qt    \ quadratic scratch
variable ocx   variable ocy   variable ocz    \ O - C
variable nx    variable ny    variable nz     \ surface normal
variable colr  variable colg  variable colb  variable inten \ pixel color 0..31 + intensity
variable best  variable gx    variable gz     \ z-buffer + ground hit x/z
variable frame

\ ---- 16.16 fixed-point ----
: f* 65536 */ ;                     ( a b -- a*b>>16 : double-cell safe )
: f/ 65536 swap */ ;                ( a b -- a<<16/b )
: clamp0 dup 0< if drop 0 then ;
: modclamp ( a -- ) dup @ inten @ f* 31 min swap ! ; \ scale color cell by intensity, clamp 5-bit

variable qnum  variable qres  variable qbit
: isqrt ( n -- root )               \ bitwise integer sqrt, full positive 32-bit
  dup 1 < if drop 0 else
    qnum ! 0 qres ! 1073741824 qbit !     \ start bit = 2^30 (= 4^15)
    begin qbit @ qnum @ > while qbit @ 2/ 2/ qbit ! repeat
    begin qbit @ 0> while
      qres @ qbit @ +                     ( t )
      dup qnum @ > if                     \ t > num: this bit does not fit
        qres @ 2/ qres !
      else                                \ t <= num: subtract and set bit
        qnum @ over - qnum !  qres @ 2/ qbit @ + qres !
      then
      drop                                \ consume t (both branches leave it)
      qbit @ 2/ 2/ qbit !
    repeat
    qres @
  then ;
: fsqrt ( f -- f ) isqrt 8 lshift ; \ sqrt of a 16.16 value = isqrt(raw)*256

\ ---- sine table: 65536 * sin(2*pi*k/24), k=0..23 ----
create sintab
      0 ,  16896 ,  32768 ,  46336 ,  56832 ,  63232 ,
  65536 ,  63232 ,  56832 ,  46336 ,  32768 ,  16896 ,
      0 , -16896 , -32768 , -46336 , -56832 , -63232 ,
 -65536 , -63232 , -56832 , -46336 , -32768 , -16896 ,
: sin@ ( idx -- 65536*sin ) cells sintab + @ ;

\ ---- camera for the current frame counter ----
: setup-cam
  frame @ 24 mod
  dup sin@ sinT !
  6 + 24 mod sin@ cosT !            \ cos(theta) = sin(theta + 90deg)
  114688 sinT @ f* ox !             \ ox = R*sin        (R=448 -> 114688)
  -114688 114688 cosT @ f* + oz !   \ oz = -R + R*cos
  24576 sinT @ f* oy ! ;            \ oy = bob*sin      (bob=96 -> 24576)

\ c = dot(oc,oc) - r^2  (needs ocx/ocy/ocz and srad already set)
: set-qc ocx @ dup f* ocy @ dup f* + ocz @ dup f* + srad @ dup f* - qc ! ;

\ ---- ray-sphere intersection, stores normal, returns t (0 = miss) ----
: sphere-hit ( cx cy cz r -- t )   \ caller sets qa = dot(d,d) once per ray
  srad ! ctrz ! ctry ! ctrx !
  ox @ ctrx @ - ocx !  oy @ ctry @ - ocy !  oz @ ctrz @ - ocz !   \ oc = O - C
  ocx @ dx @ f* ocy @ dy @ f* + ocz @ dz @ f* + qb !   \ b = dot(oc,d)
  set-qc                                               \ c = dot(oc,oc)-r^2
  qb @ dup f* qa @ qc @ f* -                           \ disc = b^2 - a*c
  dup 0< if drop 0 else
    fsqrt qb @ negate swap - qa @ f/                   \ t = (-b - sqrt)/a; a>0 at frame 0
    dup 256 < if drop 0 else                           \ reject t below ~epsilon
      qt !
      qt @ dx @ f* ox @ + ctrx @ - srad @ f/ nx !      \ normal = (O + t*d - C) / r
      qt @ dy @ f* oy @ + ctry @ - srad @ f/ ny !
      qt @ dz @ f* oz @ + ctrz @ - srad @ f/ nz !
      qt @
    then
  then ;

\ ---- half-Lambert diffuse + Phong specular (colored) ----
: shade ( base_r base_g base_b -- )
  colb ! colg ! colr !
  nx @ -37888 f* ny @ 37888 f* + nz @ 37888 f* +       \ N.L, L~(-148,148,148)
  65536 + clamp0 1 rshift                              \ (N.L+1)/2; clamp0 guards the
                                                       \ numeric overshoot that a
                                                       \ logical rshift would blow up
  40960 f* 24576 + 65536 min inten !                   \ *160/256 +96/256, clamp 1.0 (8.8: 160,96)
  nx @ -21248 f* ny @ 21248 f* + nz @ 58112 f* + clamp0 \ specular dir (8.8: -83,83,227)
  dup f* 19712 f* inten @ + 6656 + 65536 min inten !   \ +spec*77/256 +26/256   (8.8: 77,26)
  colr modclamp  colg modclamp  colb modclamp ;        \ modulate base color, clamp 5-bit

\ ---- shadow ray from ground hit toward the light ----
: shadow? ( cx cy cz r -- flag )
  srad ! ctrz ! ctry ! ctrx !
  gx @ ctrx @ - ocx !
  -32768 ctry @ - ocy !            \ ground y = -128 (8.8) -> -32768 (16.16)
  gz @ ctrz @ - ocz !
  set-qc                           \ c = dot(oc,oc)-r^2
  ocx @ -37888 f* ocy @ 37888 f* + ocz @ 37888 f* +
  dup f* qc @ -
  0< if 0 else -1 then ;

\ ---- ground plane hit distance: t = (128 + oy) / |dy| ----
: ground-t ( |dy| -- t ) 32768 oy @ + swap f/ ;

\ store t as the nearest hit; return true iff it is a valid closer hit
: hit-closer ( t -- flag )
  dup 0 > if dup best @ < if best ! -1 else drop 0 then else drop 0 then ;
: halve-color colr @ 2/ colr !  colg @ 2/ colg !  colb @ 2/ colb ! ;
\ scene spheres ( -- cx cy cz r ), used by both sphere-hit and shadow?
: sphere1 20480 0 -131072 32768 ;      \ warm: center (0.3125, 0, -2.0) r=0.5
: sphere2 -20480 -8192 -98304 24576 ;  \ cool: center (-0.3125, -0.125, -1.5) r=0.375

\ ---- per-pixel color; fills colr/colg/colb 0..31. row passed on the stack:
\ i/j read the return stack, so they are only valid in the word that owns the
\ do/loop (render), not one call deep here. ----
: trace-pixel ( row -- )
  dup 2 rshift colr !  dup 3 rshift colg !  31 swap - colb !   \ background gradient (row<=31)
  1000000000 best !
  dx @ dup f* dy @ dup f* + dz @ dup f* + qa !         \ a = dot(d,d); shared by both spheres
  sphere1 sphere-hit hit-closer if 31 10 4 shade then  \ sphere 1: warm
  sphere2 sphere-hit hit-closer if 6 18 31 shade then  \ sphere 2: cool
  dy @ dup 0< if                                       \ ground plane (ray pointing down)
    negate ground-t hit-closer if                      \ closer than any sphere? best = t
      best @ dx @ f* ox @ + gx !                        \ hit.x = ox + t*dx  (t = best)
      best @ dz @ f* oz @ + gz !                        \ hit.z = oz + t*dz
      gx @ 65536 and  gz @ 65536 and  xor if
        26 colr ! 25 colg ! 22 colb !
      else
        10 colr ! 10 colg ! 8 colb !
      then
      sphere1 shadow? if halve-color then
      sphere2 shadow? if halve-color then
    then
  else drop then ;

\ =====================================================
\ PNG writer (svpng stored-block technique)
\ CRC32 over chunk type+data; Adler32 over uncompressed data.
\ =====================================================
variable crc  variable ada  variable adb

create crctab
        0 , $1DB71064 , $3B6E20C8 , $26D930AC ,
$76DC4190 , $6B6B51F4 , $4DB26158 , $5005713C ,
$EDB88320 , $F00F9344 , $D6D6A3E8 , $CB61B38C ,
$9B64C2B0 , $86D3D2D4 , $A00AE278 , $BDBDF21C ,

\ $FFFFFFFF and keeps CRC 32-bit on wider-cell hosts (gforth); a no-op on muxleq
: crc4 crc @ $F and cells crctab + @  crc @ 4 rshift  xor  $FFFFFFFF and  crc ! ;
: emitc ( b -- ) $FF and dup emit  crc @ xor crc !  crc4 crc4 ;   \ emit + fold CRC
: adlerbyte ( b -- )
  ada @ + 65521 mod ada !  adb @ ada @ + 65521 mod adb ! ;
\ Data byte: mask once so the emitted byte and the Adler-summed byte are
\ always identical -- that equality is what makes the PNG's Adler32 valid.
: emitd ( b -- ) $FF and dup emitc adlerbyte ;                    \ data byte: CRC + Adler
: raw8 ( b -- ) $FF and emit ;                                    \ raw byte, no CRC

: put32   ( x -- ) dup 24 rshift raw8  dup 16 rshift raw8  dup 8 rshift raw8  raw8 ;
: putc32  ( x -- ) dup 24 rshift emitc dup 16 rshift emitc dup 8 rshift emitc emitc ;
: putc16le ( x -- ) dup emitc  8 rshift emitc ;
: crc-init $FFFFFFFF crc ! ;   \ 32-bit all-ones (= -1 on muxleq's 32-bit cell)
: end-crc crc @ invert put32 ;

: png-sig
  137 raw8 80 raw8 78 raw8 71 raw8  13 raw8 10 raw8 26 raw8 10 raw8 ;
: ihdr
  13 put32 crc-init
  73 emitc 72 emitc 68 emitc 82 emitc          \ "IHDR"
  W putc32 H putc32
  8 emitc 2 emitc 0 emitc 0 emitc 0 emitc      \ depth 8, truecolor, deflate/no-filter/no-interlace
  end-crc ;
: idat-begin
  IDATLEN put32 crc-init                       \ zlib hdr + H stored blocks + adler32
  73 emitc 68 emitc 65 emitc 84 emitc          \ "IDAT"
  120 emitc 1 emitc                            \ zlib header 0x78 0x01
  1 ada ! 0 adb ! ;
: row-begin ( last -- )
  emitc                                        \ BFINAL (1 on final row)
  PROW putc16le  PROW invert putc16le          \ LEN / ~LEN (little-endian)
  0 emitd ;                                    \ filter byte 0
: idat-end
  adb @ 16 lshift ada @ or putc32              \ Adler32 = (b<<16)|a
  end-crc ;
: iend
  0 put32 crc-init
  73 emitc 69 emitc 78 emitc 68 emitc          \ "IEND"
  end-crc ;

\ =====================================================
\ Render one frame, streamed scanline by scanline.
\ =====================================================
: render
  0 frame ! setup-cam
  png-sig ihdr idat-begin
  H 0 do                                       \ row (outer index = i here, = j inside)
    i H 1 - = negate row-begin
    W 0 do                                     \ col = i, row = j
      i 32 - 11 lshift                         ( rx )   \ 16.16: (i-32)/32
      16 j - 11 lshift dy !                    \ dy = ry
      dup cosT @ f* sinT @ - dx !              \ dx = rx*cos - sin
      sinT @ f* negate cosT @ - dz !           \ dz = -(rx*sin) - cos
      j trace-pixel                            \ pass row (j valid here in render)
      colr @ 255 31 */ emitd
      colg @ 255 31 */ emitd
      colb @ 255 31 */ emitd
    loop
  loop
  idat-end iend
  bye ;                                        \ halt from inside the word: the
\ last stdout byte is the IEND CRC, so nothing after render can perturb the
\ stream (a trailing interpreter parse of `bye` on the same line does not).

render
