\ Decompiler (see) regression fixture. golden-see pipes this output through an
\ address-normalizer (leading address column and digit runs -> #) so only each
\ word's mnemonic structure is asserted, not its absolute addresses. That makes
\ the golden stable across image shifts and identical for ENABLE_RV32I=0/1 -- it
\ pins the decompiler LOGIC, the one see path no other golden covers.
\ Words span all 12 decompile arms: instruction/VM (dump,+), jumpz/jump (dump,quit),
\ next (list), (push) (quit,cold), (const) (bl,b/buf), (var) (blk), (user) (base,>in),
\ (up) (set-input), compile ([char]), .$ strings (page), and ($) (qtest below --
\ no resident word uses $", so the fixture defines one).
see dump
see page
see quit
see list
see bl
see b/buf
see blk
see base
see >in
see +
see cold
see [char]
see set-input
: qtest $" hi" drop ;
see qtest
bye
