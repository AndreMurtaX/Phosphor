rem ---------------------------------------------------------------
rem  strings_delimitedtext LOSES NOTHING (adversarial round 8)
rem
rem  After a field and the blanks behind it, anything that was not the
rem  delimiter used to end the WHOLE parse: "ab,c d,e,f" answered 2 --
rem  [ab] [c] -- and d, e and f vanished with no error. A line like
rem  "John Smith,42,NY" came back one field long with a plausible count.
rem
rem  The rule every expectation below is derived from is TStrings'
rem  DelimitedText as FPC 3.2.2 implements it (rtl/objpas/classes/
rem  stringl.inc, DoSetDelimitedText, quoting the Delphi help): "Strings
rem  must be separated by Delimiter characters or spaces. They may be
rem  enclosed in QuoteChars. QuoteChars in the string must be repeated
rem  to distinguish them from the QuoteChars enclosing the string."
rem  Unless StrictDelimiter:
rem
rem    - a run of blanks (any byte up to the space) SEPARATES two fields
rem      and is part of neither; blanks beside a delimiter are dropped;
rem    - a quoted field ends at its closing quote, and whatever follows
rem      it that is not a delimiter begins the next field;
rem    - nothing after a delimiter is one empty field; whitespace alone
rem      is no field at all; the empty text is no field.
rem
rem  With StrictDelimiter only the delimiter separates, and a blank is
rem  an ordinary byte of its field.
rem
rem  TWO PLACES THIS DIFFERS FROM THE RTL, BOTH TO LOSE NOTHING: a
rem  delimiter that is itself a blank (a tab, a space) is not swallowed
rem  as one -- two tabs in a row still hold an empty field between them
rem  -- and a quote character of NUL quotes nothing, as in the RTL.
rem ---------------------------------------------------------------

q$ = chr$(34)
tab$ = chr$(9)
l@ = strings@()

test_case("a blank separates two fields, and nothing is dropped")
n = strings_delimitedtext(l@, "ab,c d,e,f")
assert_eq(n, 5, "ab / c / d / e / f: the blank between c and d separates them")
assert_eq(strings_strings$(l@, 1), "ab", "field 1")
assert_eq(strings_strings$(l@, 2), "c", "field 2 ends at the blank")
assert_eq(strings_strings$(l@, 3), "d", "field 3 begins after it")
assert_eq(strings_strings$(l@, 4), "e", "field 4")
assert_eq(strings_strings$(l@, 5), "f", "field 5 -- it used to be lost")

n = strings_delimitedtext(l@, "John Smith,42,NY")
assert_eq(n, 4, "John / Smith / 42 / NY")
assert_eq(strings_strings$(l@, 4), "NY", "the last field survives")

test_case("what follows a closing quote begins the next field")
n = strings_delimitedtext(l@, q$ + "x" + q$ + "y,z")
assert_eq(n, 3, "x / y / z")
assert_eq(strings_strings$(l@, 1), "x", "the quoted field")
assert_eq(strings_strings$(l@, 2), "y", "the byte after the quote")
assert_eq(strings_strings$(l@, 3), "z", "and the field after the delimiter")

test_case("blanks beside a delimiter belong to no field")
n = strings_delimitedtext(l@, "a , b")
assert_eq(n, 2, "a / b")
assert_eq(strings_strings$(l@, 1), "a", "no trailing blank")
assert_eq(strings_strings$(l@, 2), "b", "no leading blank")
n = strings_delimitedtext(l@, "  a  ")
assert_eq(n, 1, "blanks around one field")
assert_eq(strings_strings$(l@, 1), "a", "are not part of it")

test_case("empty fields are fields")
n = strings_delimitedtext(l@, "a,,b")
assert_eq(n, 3, "a / (empty) / b")
assert_eq(strings_strings$(l@, 2), "", "the empty middle field")
assert_eq(strings_delimitedtext(l@, "a,"), 2, "nothing after a delimiter is one empty field")
assert_eq(strings_delimitedtext(l@, ","), 2, "a lone delimiter is two empty fields")
assert_eq(strings_delimitedtext(l@, ""), 0, "the empty text is no field")
assert_eq(strings_delimitedtext(l@, "   "), 0, "whitespace alone is no field")

test_case("quotes: a doubled quote is one, a delimiter or blank inside is kept")
n = strings_delimitedtext(l@, q$ + "say " + q$ + q$ + "hi" + q$ + q$ + q$ + ",x")
assert_eq(n, 2, "the quoted field and x")
assert_eq(strings_strings$(l@, 1), "say " + q$ + "hi" + q$, "doubled quotes are one quote each")
n = strings_delimitedtext(l@, q$ + "a, b" + q$ + ",c")
assert_eq(n, 2, "the delimiter inside quotes does not split")
assert_eq(strings_strings$(l@, 1), "a, b", "and its blank is kept")
n = strings_delimitedtext(l@, q$ + "abc")
assert_eq(n, 1, "an unclosed quote runs to the end")
assert_eq(strings_strings$(l@, 1), "abc", "and is the field")

test_case("a blank delimiter is not swallowed as a blank")
t@ = strings@()
n = strings_delimiter(t@, tab$)
n = strings_delimitedtext(t@, "a" + tab$ + tab$ + "b")
assert_eq(n, 3, "two tabs hold an empty field between them")
assert_eq(strings_strings$(t@, 2), "", "the empty field")
assert_eq(strings_strings$(t@, 3), "b", "and the field after")
n = strings_delimiter(t@, " ")
n = strings_delimitedtext(t@, "a  b")
assert_eq(n, 3, "the same with a space for the delimiter")

test_case("StrictDelimiter: only the delimiter separates")
s@ = strings@()
n = strings_strictdelimiter(s@, 1)
n = strings_delimitedtext(s@, "c d,e")
assert_eq(n, 2, "c d / e")
assert_eq(strings_strings$(s@, 1), "c d", "the blank is part of the field")
n = strings_delimitedtext(s@, " a ")
assert_eq(n, 1, "one field")
assert_eq(strings_strings$(s@, 1), " a ", "with its blanks")

test_case("what delimitedtext$ writes, delimitedtext reads back whole")
w@ = strings@()
n = strings_add(w@, "John Smith")
n = strings_add(w@, "42")
n = strings_add(w@, "")
n = strings_add(w@, "a,b")
n = strings_add(w@, "say " + q$ + "x" + q$)
r@ = strings@()
n = strings_delimitedtext(r@, strings_delimitedtext$(w@))
assert_eq(n, 5, "five fields out, five back")
assert_eq(strings_strings$(r@, 1), "John Smith", "a field with a blank")
assert_eq(strings_strings$(r@, 3), "", "an empty field")
assert_eq(strings_strings$(r@, 4), "a,b", "a field with the delimiter")
assert_eq(strings_strings$(r@, 5), "say " + q$ + "x" + q$, "a field with quotes")
