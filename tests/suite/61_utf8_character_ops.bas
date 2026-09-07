rem ---------------------------------------------------------------
rem  CHARACTER OPERATIONS COUNT CHARACTERS.
rem
rem  docs/language-reference.md:372 -- "Strings are 1-based and
rem  Unicode-aware (character operations count codepoints)" -- and
rem  byte access is deliberately a separate family (bytelen, byteat,
rem  bytestr$, bytemid$).  Six places in the engine measured or cut
rem  with BYTES anyway, and every one of them produced a string that
rem  is not valid UTF-8.  Nothing crashed and nothing was reported.
rem
rem  Every suite here was byte-exact green while all six were live,
rem  because the coverage was ASCII: 30_strlib_full exercises the
rem  case family on ASCII and Latin-1 only, 51_arith_faults tests
rem  "abcdef" - 2, and 01_print_using uses '!' and \...\ on ASCII.
rem  An ASCII test cannot see a defect that only splits a multi-byte
rem  character, so this file sweeps the ENCODING CLASSES: one, two,
rem  three and four byte characters, and a string that does not
rem  begin on a character boundary at all.
rem
rem  hx$ renders bytes, not text: a one-byte difference in a result
rem  must not be able to hide inside a terminal's idea of a glyph.
rem ---------------------------------------------------------------

function hx$(s$) local r$, i
  r$ = ""
  for i = 1 to bytelen(s$)
    r$ = r$ + hex$(byteat(s$, i)) + " "
  next
  return r$
endfunction

rem The four encoding widths, built through chr$ so the file's own
rem bytes are not the thing under test.
a1$ = "a"
a2$ = chr$(233)
a3$ = chr$(26085)
a4$ = chr$(128512)

test_case("utf8/the widths are what we think they are")
assert_eq(bytelen(a1$), 1, "ASCII is one byte")
assert_eq(bytelen(a2$), 2, "U+00E9 is two bytes")
assert_eq(bytelen(a3$), 3, "U+65E5 is three bytes")
assert_eq(bytelen(a4$), 4, "U+1F600 is four bytes")
assert_eq(len(a1$ + a2$ + a3$ + a4$), 4, "four characters, ten bytes")
assert_eq(bytelen(a1$ + a2$ + a3$ + a4$), 10, "ten bytes, four characters")

rem ---------------------------------------------------------------
rem  'string - n' removed BYTES.  "cafe"-with-an-accent minus one
rem  dropped the last byte of a two-byte character and left a lone
rem  0xC3: len() did not fall at all, and the result disagreed with
rem  left$(s$, len(s$)-1), which had always been right.
rem ---------------------------------------------------------------
test_case("utf8/string minus n removes characters")
s$ = "caf" + a2$
assert_eq(len(s$), 4, "four characters")
assert_eq(bytelen(s$), 5, "five bytes")
assert_eq(s$ - 1, "caf", "one character off a four-character string")
assert_eq(len(s$ - 1), 3, "and len falls by exactly one")
assert_eq(s$ - 2, "ca", "two characters off")
assert_eq(s$ - 4, "", "all four")
assert_eq(s$ - 9, "", "more than there are is a clamp, not an error")
assert_eq(s$ - 0, s$, "none is the string itself")
rem the invariant that ties it to the rest of the language
assert_eq(s$ - 1, left$(s$, len(s$) - 1), "s$ - n agrees with left$")
assert_eq(hx$(s$ - 1), "63 61 66 ", "and the bytes are whole")
rem every width, so the fix cannot be one-byte-character-shaped
w$ = a4$ + a3$ + a2$ + a1$
assert_eq(w$ - 1, a4$ + a3$ + a2$, "a 4-3-2-1 string loses its ASCII tail")
assert_eq(w$ - 2, a4$ + a3$, "then its two-byte character")
assert_eq(w$ - 3, a4$, "then its three-byte one")
assert_eq(w$ - 4, "", "then the astral one")

rem ---------------------------------------------------------------
rem  aucase$/alcase$ walked UTF-16 CODE UNITS, so a character above
rem  the BMP was split into its surrogate pair and each half encoded
rem  separately -- CESU-8, which is not UTF-8.  len() went 1 -> 2 and
rem  the round trip failed.  U+1F600 has no case mapping at all.
rem ---------------------------------------------------------------
test_case("utf8/case conversion above the BMP")
assert_eq(hx$(aucase$(a4$)), "F0 9F 98 80 ", "an astral character is not split")
assert_eq(hx$(alcase$(a4$)), "F0 9F 98 80 ", "in either direction")
assert_eq(len(aucase$(a4$)), 1, "and stays one character")
assert_eq(alcase$(aucase$(a4$)), a4$, "so the round trip holds")
m$ = "a" + chr$(128169) + "b"
assert_eq(hx$(aucase$(m$)), "41 F0 9F 92 A9 42 ", "the ASCII around it still cases")
rem the BMP was always right and must stay byte-for-byte right
assert_eq(aucase$("greek " + chr$(945)), "GREEK " + chr$(913), "Greek alpha still cases")
assert_eq(alcase$(chr$(1046)), chr$(1078), "Cyrillic still cases")
assert_eq(aucase$(chr$(8364)), chr$(8364), "the euro sign has no case")
assert_eq(aucase$("caf" + a2$), "CAF" + chr$(201), "and Latin-1 accents still case")

rem ---------------------------------------------------------------
rem  A string that BEGINS with a continuation byte.  bytemid$ on a
rem  chunk boundary hands you one, and docs/libraries/regex.md says
rem  regex_find$(".", ...) does too.  The codepoint table recorded a
rem  start only for a non-continuation byte, so those leading bytes
rem  belonged to no character: left$(s$,0) was not empty, insert$
rem  emitted them TWICE, and reverse$ dropped them.
rem ---------------------------------------------------------------
test_case("utf8/a string that does not start on a boundary")
orph$ = bytemid$("caf" + a2$, 5, 1) + "a"
assert_eq(bytelen(orph$), 2, "two bytes: an orphan continuation byte and 'a'")
assert_eq(left$(orph$, 0), "", "left$(x,0) is empty for EVERY x")
assert_eq(bytelen(insert$(orph$, "Z", 1)), 3, "2 bytes + 1 inserted = 3, never 4")
assert_eq(hx$(insert$(orph$, "Z", 1)), "5A A9 61 ", "and nothing is duplicated")
assert_eq(bytelen(reverse$(orph$)), 2, "reverse$ drops nothing")
assert_eq(hx$(reverse$(orph$)), "61 A9 ", "it visits every byte")
assert_eq(bytelen(stuffstring$(orph$, 1, 1, "Z")), 2, "stuffstring$ invents nothing")
rem THE invariant the slicers exist to keep, over every cut point
for i = 0 to len(orph$) + 1
  assert_eq(left$(orph$, i) + right$(orph$, len(orph$) - i), orph$, "left+right rebuilds the string")
next

rem ---------------------------------------------------------------
rem  chr$ above U+10FFFF overflowed `Chr($F0 or (c shr 18))` and
rem  emitted 0xFF, a byte that cannot occur in a UTF-8 stream at any
rem  position -- with no error and no round trip.  The bottom of the
rem  range was already clamped; the top is its mirror.
rem ---------------------------------------------------------------
test_case("utf8/chr$ stays inside the encodable range")
assert_eq(hx$(chr$(1114111)), "F4 8F BF BF ", "U+10FFFF is the last codepoint")
assert_eq(hx$(chr$(1114112)), "F4 8F BF BF ", "one past it clamps")
assert_eq(hx$(chr$(2147483647)), "F4 8F BF BF ", "and so does the saturation limit")
assert_eq(asc(chr$(1114111)), 1114111, "the last codepoint round-trips")
assert_eq(hx$(chr$(-1)), "0 ", "the bottom clamp is unchanged")
rem the same encoder builds padding runs, so they cannot be invalid either
assert_eq(hx$(string$(2, 2147483647)), "F4 8F BF BF F4 8F BF BF ", "string$ shares it")
assert_eq(hx$(lfill$("x", 2, -1)), "0 78 ", "lfill$ shares it too -- this emitted FF")
assert_eq(hx$(rfill$("x", 2, -1)), "78 0 ", "and rfill$")
assert_eq(hx$(center$("x", 3, -1)), "0 78 0 ", "and center$")
rem every boundary of the encoding, so no width is left unpinned
assert_eq(bytelen(chr$(127)), 1, "U+007F is one byte")
assert_eq(bytelen(chr$(128)), 2, "U+0080 is two")
assert_eq(bytelen(chr$(2047)), 2, "U+07FF is two")
assert_eq(bytelen(chr$(2048)), 3, "U+0800 is three")
assert_eq(bytelen(chr$(65535)), 3, "U+FFFF is three")
assert_eq(bytelen(chr$(65536)), 4, "U+10000 is four")

rem ---------------------------------------------------------------
rem  PRINT USING's string fields belong to tests/classic, NOT here.
rem  PRINT USING is a statement, so its result cannot be handed to an
rem  assert; it has to be compared as OUTPUT BYTES. phosphortest --
rem  the runner for this directory -- installs no OnOutput seam at
rem  all, so a program's print goes nowhere and these goldens record
rem  only the assertion counts. Putting the '!' and \...\ cases here
rem  would exercise the formatter while verifying nothing about what
rem  it wrote, which is the shape of coverage this whole file exists
rem  to complain about.
rem
rem  They live in tests/classic/01_print_using.bas, whose runner does
rem  compare bytes, alongside the ASCII cases that were already there.
rem ---------------------------------------------------------------

rem ---------------------------------------------------------------
rem  str$/stri$ and PRINT USING put an int% through a Double, so at
rem  10^15 the text became exponential and above 2^53 the low digits
rem  were simply gone -- while `print id%` and hex$(id%) of the same
rem  variable were exact.  A row id or a byte count written to a log
rem  through str$ could not be recovered from "1E15".
rem ---------------------------------------------------------------
test_case("utf8/str$ of an int% keeps its digits")
id% = 1000000000000001
assert_eq(str$(id%), "1000000000000001", "str$ does not go exponential at 10^15")
assert_eq(stri$(id%), "1000000000000001", "and neither does stri$")
row% = 1234567890123456789
assert_eq(str$(row%), "1234567890123456789", "nineteen digits survive")
assert_eq(str$(9223372036854775807), "9223372036854775807", "and so does the Int64 maximum")
rem The MINIMUM has to be computed, not written: -9223372036854775808 is unary
rem minus applied to 9223372036854775808, and that magnitude is one past the
rem Int64 maximum, so the literal is a Double before the minus ever reaches it.
rem It formats as a Double here for that reason -- correctly, and unchanged.
lo% = -9223372036854775807 - 1
assert_eq(str$(lo%), "-9223372036854775808", "and the minimum, once it is an int%")
p53% = 9007199254740993
assert_eq(str$(p53%), "9007199254740993", "2^53+1 is not rounded to 2^53")
rem the band below 10^15 must be untouched -- it was always exact
assert_eq(str$(999999999999999), "999999999999999", "the last value below the old cliff")
assert_eq(str$(0), "0", "zero")
assert_eq(str$(-7), "-7", "a small negative")
rem and a Double still formats as a Double, not as an integer
assert_eq(str$(1.5), "1.5", "a Double keeps its fraction")
assert_eq(str$(0.1), "0.1", "and its shortest form")
assert_eq(str$(1e15), "1E15", "and a Double at 10^15 still formats as one")
