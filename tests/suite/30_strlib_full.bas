rem ---------------------------------------------------------------
rem StrLib, the half nothing had run. check-coverage.py reported
rem 41/63: the case conversions, the padding family, the predicates,
rem the comparisons and the in-place editing.
rem
rem Examples/ calls most of these; what it does not do is say what
rem they should answer.
rem
rem One convention to hold on to: positions here are 1-BASED (Phosphor is base-1 everywhere), like
rem instr, and not 1-based like Delphi's own string routines.
rem ---------------------------------------------------------------

test_case("strlib/case")
assert_eq(proper$("hello world"), "Hello World", "proper$ capitalises each word")
assert_eq(swapcase$("Hello"), "hELLO", "swapcase$ turns each letter over")
rem The a- prefix is "Ansi", not "all": alcase$ and aucase$ go through
rem AnsiLowerCase and AnsiUpperCase, which follow the locale, while
rem lcase$ and ucase$ go through LowerCase and UpperCase, which only
rem know a-z. On plain ASCII the two pairs agree.
assert_eq(alcase$("HELLO World"), "hello world", "alcase$ lowercases the lot")
assert_eq(aucase$("hello world"), "HELLO WORLD", "aucase$ uppercases the lot")
assert_eq(alcase$("HELLO"), lcase$("HELLO"), "on ASCII the two agree")
assert_eq(aucase$("hello"), ucase$("hello"), "in both directions")

rem Where they part is anything outside a-z, which is most of the
rem alphabet in the language this engine was written in.
accented$ = "a" + chr$(231) + chr$(227) + "o"
assert_eq(ucase$(accented$), "A" + chr$(231) + chr$(227) + "O", "ucase$ leaves an accented letter alone")
assert_eq(aucase$(accented$), "A" + chr$(199) + chr$(195) + "O", "and aucase$ raises it")

test_case("strlib/padding-with-spaces")
rem ltab$ and rtab$ pad to a width with spaces, and trim what they are
rem given first, so leading blanks in the input do not count towards it.
assert_eq(ltab$("ab", 5), "   ab", "ltab$ pads on the left")
assert_eq(rtab$("ab", 5), "ab   ", "rtab$ pads on the right")
assert_eq(len(ltab$("ab", 5)), 5, "to exactly the width asked for")

rem A string already at or past the width comes back untouched rather
rem than truncated.
assert_eq(ltab$("abcdef", 3), "abcdef", "and never cuts anything off")

assert_eq(ltab$("  ab  ", 5), "   ab", "the input is trimmed before padding")

test_case("strlib/padding-with-a-character")
rem lfill$ and rfill$ take the fill as a CHARACTER CODE, not a string,
rem so the third argument is asc("0") and not "0".
assert_eq(lfill$("42", 5, asc("0")), "00042", "lfill$ pads on the left with the given character")
assert_eq(rfill$("42", 5, asc(".")), "42...", "rfill$ pads on the right")
assert_eq(len(rfill$("42", 5, asc("."))), 5, "to the width asked for")

test_case("strlib/centre")
assert_eq(center$("ab", 6), "  ab  ", "center$ splits the padding")
assert_eq(len(center$("ab", 6)), 6, "to the width asked for")
assert_eq(center$("ab", 6, asc("-")), "--ab--", "and its three-argument form takes a fill character")

test_case("strlib/predicates")
assert_true(isdigits("12345"), "isdigits accepts digits")
assert_false(isdigits("12a45"), "and refuses anything else")
assert_false(isdigits(""), "an empty string has no digits in it")

assert_true(isalnum("abc123"), "isalnum accepts letters and digits")
assert_false(isalnum("abc 123"), "and refuses a space")

assert_true(isspace("   "), "isspace accepts blanks")
assert_false(isspace(" a "), "and refuses anything else")

assert_true(islower("abc"), "islower accepts lower case")
assert_false(islower("aBc"), "and refuses a capital")
assert_true(isupper("ABC"), "isupper accepts upper case")
assert_false(isupper("AbC"), "and refuses a small letter")

test_case("strlib/containstext")
rem containstext ignores case, which is the difference between it and
rem instr. It answers a flag, not a position.
assert_true(containstext("Hello World", "WORLD"), "containstext ignores case")
assert_true(containstext("Hello World", "world"), "either way round")
assert_false(containstext("Hello World", "absent"), "and answers false when it is not there")

test_case("strlib/comparison")
rem strcmp answers the sign of the difference: negative, zero, positive.
assert_eq(strcmp("a", "b"), -1, "strcmp: a sorts before b")
assert_eq(strcmp("b", "a"), 1, "and b after a")
assert_eq(strcmp("a", "a"), 0, "and equal is zero")

assert_true(strcmp("A", "a"), "case matters to strcmp")
assert_eq(strcmpi("A", "a"), 0, "and does not to strcmpi")
assert_eq(strcmpi("ABC", "abc"), 0, "for a whole word")

test_case("strlib/editing")
rem Positions are 1-based here, like instr and every other index.
assert_eq(insert$("hello", "XX", 1), "XXhello", "insert$ at the start")
assert_eq(insert$("hello", "XX", 6), "helloXX", "insert$ at the end")
assert_eq(insert$("hello", "XX", 3), "heXXllo", "insert$ in the middle")

assert_eq(delete$("hello", 1, 2), "llo", "delete$ from the start")
assert_eq(delete$("hello", 2, 3), "ho", "delete$ from the middle")
assert_eq(delete$("hello", 1, 0), "hello", "deleting nothing changes nothing")

rem stuffstring$ is delete and insert in one call, and it is the one
rem place in this library that counts from 1, because it is Delphi's
rem StuffString underneath.
assert_eq(stuffstring$("hello", 1, 1, "J"), "Jello", "stuffstring$ replaces a run")

test_case("strlib/lines")
rem line$ picks one line out of a multi-line string, 1-based.
text$ = "first" + chr$(10) + "second" + chr$(10) + "third"
assert_eq(line$(text$, 1), "first", "line$ reads the first line")
assert_eq(line$(text$, 3), "third", "and the last")
assert_eq(line$(text$, 10), "", "a line past the end is empty rather than an error")

test_case("strlib/valcode")
rem val() sets a code that valcode reads back: zero when the whole
rem string was a number, and the position of the first offending
rem character when it was not.
x = val("123")
assert_eq(valcode(), 0, "a clean number leaves no code")
y = val("12abc")
assert_true(valcode(), "and a bad one leaves the position that stopped it")
