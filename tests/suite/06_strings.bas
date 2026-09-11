rem ---------------------------------------------------------------
rem StrLib plus the string indexing sugar (base-1 in Phosphor).
rem s$[n]  -> line n   (base-1)
rem s$[[n]] -> character n (base-1, by codepoint)
rem ---------------------------------------------------------------

test_case("str/case")
assert_eq(ucase$("Plan9Basic"), "PLAN9BASIC")
assert_eq(lcase$("Plan9Basic"), "plan9basic")
assert_eq(ucase$(""), "")

test_case("str/length")
assert_eq(len("abcde"), 5)
assert_eq(len(""), 0)

test_case("str/left-right")
assert_eq(left$("abcdef", 3), "abc")
assert_eq(right$("abcdef", 3), "def")
assert_eq(left$("ab", 10), "ab", "asking for more than exists")

test_case("str/trim")
assert_eq(trim$("  x  "), "x")
assert_eq(ltrim$("  x"), "x")
assert_eq(rtrim$("x  "), "x")
assert_eq(trim$(""), "")

test_case("str/reverse")
assert_eq(reverse$("abc"), "cba")
assert_eq(reverse$(""), "")

test_case("str/char-codes")
assert_eq(asc("A"), 65)
assert_eq(chr$(65), "A")
assert_eq(chr$(asc("z")), "z")

test_case("str/radix")
assert_eq(hex$(255), "FF")
assert_eq(bin$(10), "1010")
assert_eq(oct$(8), "10")

test_case("str/numeric-conversion")
assert_eq(val("3.5"), 3.5)
assert_eq(val("42"), 42)
assert_eq(stri$(42), "42", "stri$ is locale invariant")
assert_eq(stri$(3.5), "3.5")

test_case("str/padding")
assert_eq(space$(3), "   ")
assert_eq(len(space$(5)), 5)

test_case("str/replace")
assert_eq(replacestr$("aXbXc", "X", "-"), "a-b-c")
assert_eq(replacestr$("abc", "z", "-"), "abc", "no match leaves it alone")

test_case("str/search")
assert_eq(countstr("banana", "an"), 2)
assert_eq(countstr("abc", "z"), 0)

ok = 0
if containsstr("hello world", "lo wo") <> 0 then ok = 1
assert_eq(ok, 1, "containsstr finds a substring")

ok = 0
if startsstr("hello", "he") <> 0 then ok = 1
assert_eq(ok, 1, "startsstr takes the text first")

ok = 0
if endsstr("hello", "lo") <> 0 then ok = 1
assert_eq(ok, 1, "endsstr takes the text first")

ok = 0
if startsstr("he", "hello") <> 0 then ok = 1
assert_eq(ok, 0, "the old spelling no longer matches")

ok = 0
if startstext("HELLO", "he") <> 0 then ok = 1
assert_eq(ok, 1, "startstext ignores case, text first")

ok = 0
if endstext("HELLO", "LO") <> 0 then ok = 1
assert_eq(ok, 1, "endstext ignores case, text first")

test_case("str/predicates")
ok = 0
if isnumeric("123") <> 0 then ok = 1
assert_eq(ok, 1, "isnumeric on digits")

ok = 1
if isnumeric("12a") <> 0 then ok = 0
assert_eq(ok, 1, "isnumeric rejects letters")

ok = 0
if isalpha("abc") <> 0 then ok = 1
assert_eq(ok, 1, "isalpha")

test_case("str/mulstring")
assert_eq(mulstring$("ab", 3), "ababab")

test_case("str/char-index")
s$ = "abcdef"
assert_eq(s$[[1]], "a", "first character")
assert_eq(s$[[6]], "f", "last character")
assert_eq(s$[[3]], "c", "middle character")

test_case("str/line-index")
multi$ = "first\nsecond\nthird"
assert_eq(multi$[1], "first", "lines are 1-based")
assert_eq(multi$[2], "second")
assert_eq(multi$[3], "third")
assert_eq(count(multi$), 3, "line count")

test_case("str/word")
assert_eq(word$("alpha beta gamma", 2, " "), "beta")
assert_eq(wordcount("alpha beta gamma", " "), 3)

test_case("strings/repeat-and-replace")
assert_eq(string$(3, 65), "AAA", "string$ repeats a character by its code")
assert_eq(string$(0, 65), "", "zero repetitions is empty")
assert_eq(replacestr$("Hello", "l", "L"), "HeLLo", "replacestr$ is case sensitive")
assert_eq(replacestr$("Hello", "L", "X"), "Hello", "and so leaves the wrong case alone")
assert_eq(replacetext$("Hello", "L", "X"), "HeXXo", "replacetext$ ignores case")

test_case("strings/instr-family")
assert_eq(instr("Hello World", "World"), 7, "instr finds the 1-based position")
assert_eq(instr("Hello", "H"), 1, "1-based, so the first character is 1")
assert_eq(instr("Hello", "ll"), 3, "and not merely 'found'")
assert_eq(instr("Hello", "zz"), 0, "absent is 0")
assert_eq(instr("Hello World", "World", 1), 7, "the three-argument form agrees")
assert_eq(instr("abcabc", "b", 4), 5, "searching from an offset")
assert_eq(instrrev("abcabc", "b"), 5, "and so does instrrev")
assert_eq(instrrev("abcabc", "zz"), 0, "absent is 0 there too")

test_case("strings/ignoring case means the same thing at all five doors")
rem containstext said a needle OCCURRED in a string that startstext and endstext
rem said it did not BEGIN or END -- on strings of equal length, where those three
rem questions are the same question. The family was folded by two rules:
rem SysUtils' a-to-z byte table in the three predicates and strcmpi, and the
rem platform's AnsiUpperCase inside containstext and replacetext$. That second
rem half is a hook the operating system installs, so the same script did not even
rem have to answer the same on Windows and on Linux. One rule now, and it is
rem aucase$'s own table.
rem chr$(201) is E-acute and chr$(233) is e-acute: one real word, five doors.
u$ = chr$(201) + "COLE"
l$ = chr$(233) + "cole"
assert_true(containstext(u$, l$), "containstext folds the accent")
assert_true(startstext(u$, l$), "startstext agrees, and used to answer 0")
assert_true(endstext(u$, l$), "endstext agrees, and used to answer 0")
assert_eq(strcmpi(u$, l$), 0, "strcmpi calls them equal, and used to answer -1")
assert_eq(replacetext$(u$, l$, "X"), "X", "replacetext$ matches the same run")
rem the case-SENSITIVE twins must still see two different strings
assert_false(containsstr(u$, l$), "containsstr is unchanged")
assert_false(startsstr(u$, l$), "and so is startsstr")
assert_eq(replacestr$(u$, l$, "X"), u$, "and replacestr$ finds nothing to replace")
rem folding case is not folding accents: a different letter stays different
assert_false(startstext(u$, chr$(232) + "cole"), "e-grave is not e-acute")
rem and text outside the match keeps ITS OWN spelling, not the folded one
assert_eq(replacetext$("x" + u$ + "y", "COLE", "-"), "x" + chr$(201) + "-y", "only the match is replaced")

test_case("strings/isnumeric answers for the value, not for the parse")
rem TryStrToFloat succeeds on all of these and hands back a NON-FINITE Double,
rem which isnumeric used to throw away before reporting 1. But str.md's
rem documented idiom is to guard a val() with isnumeric, and val() cannot return
rem a non-finite Double -- the engine's finiteness gate turns one into "val has
rem no finite result for those arguments". So the guard said yes and the call it
rem guarded faulted; without an on-error handler the program exited 1 with no
rem output at all.
assert_false(isnumeric("1e999"), "an out-of-range exponent is not a number val can answer")
assert_false(isnumeric("1e309"), "nor is one just past the top")
assert_false(isnumeric("-1e999"), "nor its negative")
assert_false(isnumeric("inf"), "nor inf")
assert_false(isnumeric("nan"), "nor nan")
assert_false(isnumeric("INF"), "in any spelling")
assert_true(isnumeric("1e308"), "but the largest exponent that IS finite still passes")
assert_true(isnumeric("-2.5"), "and so does an ordinary number")
assert_true(isnumeric(" 42 "), "trimmed, as before")
rem the guard now holds: what isnumeric approves, val answers without faulting.
if isnumeric("1e308") <> 0 then
  bignum = val("1e308")
  assert_true(bignum, "val returns the guarded value")
  assert_eq(valcode(), 0, "and reports a clean parse")
endif
