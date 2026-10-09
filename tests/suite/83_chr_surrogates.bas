rem ---------------------------------------------------------------
rem  A SURROGATE CODE POINT HAS NO UTF-8 SPELLING (2026-10-09).
rem
rem  U+D800..U+DFFF are reserved for UTF-16's surrogate pairs and are
rem  not characters. RFC 3629 section 3 forbids encoding them: the
rem  three bytes ED A0 80 that the bit pattern for U+D800 would give
rem  are ill-formed UTF-8, and a strict reader rejects them.
rem  chr$(55296) produced exactly those bytes, and so did string$ and
rem  the pad family (lfill$, rfill$, center$), which all build their
rem  characters through the same encoder -- whose header promised
rem  "no argument can make it emit a byte that UTF-8 does not have".
rem
rem  The decision: a surrogate becomes U+FFFD, the replacement
rem  character, whose encoding EF BF BD is written out in the Unicode
rem  standard -- the same answer the JSON decoder already gives an
rem  unpaired \u escape. The neighbours either side of the range,
rem  U+D7FF (ED 9F BF) and U+E000 (EE 80 80), are characters and
rem  must be untouched; their bytes are derived by hand from the
rem  three-byte pattern 1110xxxx 10xxxxxx 10xxxxxx.
rem
rem  asc() is the decoder on the other side of the same gap: given
rem  the ill-formed bytes ED A0 80 from outside (a file, bytestr$) it
rem  answered 55296, a code chr$ will no longer produce. It now
rem  answers 65533 too, so asc never names a surrogate.
rem
rem  hx$ renders bytes, not text, so a one-byte difference cannot
rem  hide inside a terminal's idea of a glyph.
rem ---------------------------------------------------------------

function hx$(s$) local r$, i
  r$ = ""
  for i = 1 to bytelen(s$)
    r$ = r$ + hex$(byteat(s$, i)) + " "
  next
  return r$
endfunction

fffd$ = "EF BF BD "

test_case("surrogates/the replacement character is what the standard says")
assert_eq(hx$(chr$(65533)), fffd$, "U+FFFD is EF BF BD")

test_case("surrogates/chr$ of every edge of the range is U+FFFD")
assert_eq(hx$(chr$(55296)), fffd$, "U+D800, the first high surrogate")
assert_eq(hx$(chr$(56319)), fffd$, "U+DBFF, the last high surrogate")
assert_eq(hx$(chr$(56320)), fffd$, "U+DC00, the first low surrogate")
assert_eq(hx$(chr$(57343)), fffd$, "U+DFFF, the last low surrogate")
assert_eq(asc(chr$(55296)), 65533, "and asc reads back the replacement")

test_case("surrogates/the neighbours are characters and are untouched")
assert_eq(hx$(chr$(55295)), "ED 9F BF ", "U+D7FF is itself")
assert_eq(hx$(chr$(57344)), "EE 80 80 ", "U+E000 is itself")
assert_eq(asc(chr$(55295)), 55295, "asc(chr$(U+D7FF)) round-trips")
assert_eq(asc(chr$(57344)), 57344, "asc(chr$(U+E000)) round-trips")

test_case("surrogates/string$ and the pad family share the encoder")
assert_eq(hx$(string$(2, 55296)), fffd$ + fffd$, "string$ of a surrogate")
assert_eq(hx$(lfill$("x", 3, 56320)), fffd$ + fffd$ + "78 ", "lfill$ pads with U+FFFD")
assert_eq(hx$(rfill$("x", 3, 57343)), "78 " + fffd$ + fffd$, "rfill$ pads with U+FFFD")
assert_eq(hx$(center$("x", 3, 55296)), fffd$ + "78 " + fffd$, "center$ pads with U+FFFD")

test_case("surrogates/asc of ill-formed surrogate bytes answers U+FFFD")
bad$ = bytestr$(237) + bytestr$(160) + bytestr$(128)
assert_eq(asc(bad$), 65533, "ED A0 80 is not U+D800")
bad$ = bytestr$(237) + bytestr$(191) + bytestr$(191)
assert_eq(asc(bad$), 65533, "ED BF BF is not U+DFFF")
good$ = bytestr$(237) + bytestr$(159) + bytestr$(191)
assert_eq(asc(good$), 55295, "ED 9F BF is U+D7FF, a real character")
