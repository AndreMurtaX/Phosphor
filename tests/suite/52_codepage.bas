rem ---------------------------------------------------------------
rem Bytes >= 128 must survive every function that handles text.
rem
rem This is the {$codepage UTF8} char-concatenation class, found and
rem swept for the THIRD time. `r := r + c` where c is a Char re-encodes
rem the byte; `r := r + Copy(s, i, 1)` does not. The two lines look the
rem same, one destroys data, and no compiler warning distinguishes them.
rem
rem Nothing here would have failed before the fix because no golden
rem pushed a non-ASCII byte through these particular functions -- which
rem is exactly why scripts/check-codepage.py now enforces the rule at
rem the source level instead of relying on a test remembering to try.
rem ---------------------------------------------------------------

test_case("codepage/proper$ keeps every byte it does not case")
e$ = "caf" + chr$(233) + " bar"
assert_eq(bytelen(e$), 9, "the input is 9 bytes: 'e' with an acute is two of them")
p$ = proper$(e$)
assert_eq(bytelen(p$), 9, "proper$ returned 'Caf??' -- 2 bytes destroyed -- before this")
assert_eq(byteat(p$, 4), 195, "the first byte of the accented letter survives")
assert_eq(byteat(p$, 5), 169, "and the second")
assert_eq(p$, "Caf" + chr$(233) + " Bar", "while the ASCII letters are still cased")

test_case("codepage/swapcase$ keeps every byte it does not case")
s$ = swapcase$("Caf" + chr$(233) + " bAR")
assert_eq(bytelen(s$), 9, "same class, same function shape, same fix")
assert_eq(s$, "cAF" + chr$(233) + " Bar", "ASCII flips, the rest is untouched")

test_case("codepage/an all-ASCII string is unchanged by either")
assert_eq(proper$("hello world"), "Hello World", "the ordinary case still works")
assert_eq(swapcase$("Hello World"), "hELLO wORLD", "and so does this one")

test_case("codepage/a string list's delimiter is a BYTE and keeps its value")
l@ = strings@()
strings_add(l@, "one")
strings_add(l@, "two")
strings_delimiter(l@, chr$(233))
rem A Char delimiter holds ONE byte, so it takes the first byte of the encoding.
rem What matters is that the byte is the one given, not '?' -- and that the round
rem trip agrees with itself.
t$ = strings_delimitedtext$(l@)
assert_eq(bytelen(t$), 7, "'one' + one delimiter byte + 'two'")
assert_eq(byteat(t$, 4), 195, "the delimiter byte survives; it used to be 63, '?'")
back@ = strings@()
strings_delimiter(back@, chr$(233))
strings_delimitedtext(back@, t$)
assert_eq(strings_count(back@), 2, "and the text splits back into two items")
assert_eq(strings_strings$(back@, 1), "one", "first item")
assert_eq(strings_strings$(back@, 2), "two", "second item")

test_case("codepage/the byte primitives still agree with all of it")
assert_eq(bytelen(chr$(233)), 2, "chr$ encodes, so this is two bytes")
assert_eq(bytelen(bytestr$(233)), 1, "bytestr$ does not, so this is one")
assert_eq(byteat(chr$(233), 1), 195, "and the encoding is the expected pair")
assert_eq(byteat(chr$(233), 2), 169, "second byte")
