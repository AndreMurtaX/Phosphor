rem ---------------------------------------------------------------
rem  THE ANSWERS OF THE ROUTINES ROUND 7 REWROTE TO BE LINEAR
rem
rem  Adversarial round 7 found library work that grew with the size of
rem  what the script handed in, uncharged -- and five routines that were
rem  worse than linear. Those were rewritten, and a rewrite that is
rem  faster and answers differently is a new defect. This file pins the
rem  answers, each DERIVED FROM THE RULE THE ROUTINE STATES, not from a
rem  run:
rem
rem    count, line$, s$[n]  SplitLines' rule: a line ends at LF, ONE
rem                         trailing CR is not part of it, the empty text
rem                         is one empty line (count answers 0 for it),
rem                         and a text ending in LF has an empty last
rem                         line. They now scan instead of splitting.
rem    word$, wordcount     SplitBy: n separators make n + 1 pieces. Its
rem                         slot array grew by one per piece (quadratic).
rem    left$/right$/mid$,   a CHARACTER is a lead byte and every
rem    asc, s$[[n]]         continuation byte (10xxxxxx) after it --
rem                         PhosphorValue.Utf8Starts. They now charge the
rem                         walk they made, and must still walk the same.
rem    strings_delimitedtext  TStrings.DelimitedText: fields split at the
rem                         delimiter, a QuoteChar field may hold it and
rem                         doubles a quote, blanks around a field are
rem                         dropped unless StrictDelimiter. Its field
rem                         buffer was the size of the rest of the input,
rem                         once per field.
rem    rag_analyze$         keywords deduplicated in FIRST-SEEN order --
rem                         now through a hash set instead of a scan.
rem    funcexists?          a name is known when ANY signature has it,
rem                         case-insensitively -- now one hashed lookup
rem                         instead of a lowered copy of every key.
rem ---------------------------------------------------------------

lf$ = chr$(10)
cr$ = chr$(13)

test_case("count and line$ scan, by SplitLines' rule")
assert_eq(count(""), 0, "the empty text has no lines to count")
assert_eq(count("a"), 1, "no LF: one line")
assert_eq(count("a" + lf$ + "b"), 2, "one LF: two lines")
assert_eq(count("a" + lf$), 2, "a trailing LF makes an empty last line")
assert_eq(count(lf$ + lf$), 3, "two LFs alone: three empty lines")
t$ = "ab" + cr$ + lf$ + "c" + cr$ + "d" + lf$ + lf$ + "e"
assert_eq(count(t$), 4, "three LFs: four lines")
assert_eq(line$(t$, 1), "ab", "the CR before an LF is not part of the line")
assert_eq(line$(t$, 2), "c" + cr$ + "d", "a CR inside a line is kept")
assert_eq(line$(t$, 3), "", "an empty line between two LFs")
assert_eq(line$(t$, 4), "e", "the last line runs to the end")
assert_eq(line$(t$, 5), "", "past the last line: empty")
assert_eq(line$(t$, 0), "", "line 0 does not exist")
assert_eq(t$[1], "ab", "s$[n] reads the same line as line$")
assert_eq(t$[4], "e", "and the last one")
assert_eq(line$("", 1), "", "the empty text is one empty line")
assert_eq(line$("x" + cr$, 1), "x", "a trailing CR at the very end is dropped")

test_case("word$ and wordcount over many pieces")
w$ = mulstring$("a,", 1000)
assert_eq(wordcount(w$, ","), 1001, "1000 separators make 1001 pieces")
assert_eq(word$(w$, 1000, ","), "a", "piece 1000 is the last a")
assert_eq(word$(w$, 1001, ","), "", "piece 1001 is the empty one after the last comma")
assert_eq(word$("x--y--z", 2, "--"), "y", "a two-byte separator")

test_case("the codepoint slicers walk the same characters")
h$ = "h" + chr$(233) + "llo"
assert_eq(left$(h$, 2), "h" + chr$(233), "two characters, three bytes")
assert_eq(right$(h$, 4), chr$(233) + "llo", "four characters from the end")
assert_eq(mid$(h$, 2, 2), chr$(233) + "l", "from the second character, two")
assert_eq(mid$(h$, 3), "llo", "to the end")
assert_eq(asc(chr$(233) + "x"), 233, "the first character decoded")
assert_eq(h$[[2]], chr$(233), "s$[[n]] is a character")
m$ = "a" + bytestr$(128) + bytestr$(128) + "b"
assert_eq(bytelen(left$(m$, 1)), 3, "stray continuation bytes belong to the a before them")
assert_eq(left$(m$, 2), m$, "so the b is the second character")
assert_eq(bytelen(m$[[1]]), 3, "and s$[[1]] carries them too")
assert_eq(len(m$), 2, "two characters in all")

test_case("strings_delimitedtext reads TStrings' fields, linearly")
l@ = strings@()
n = strings_delimitedtext(l@, "a, " + chr$(34) + "b,c" + chr$(34) + " ,  d ")
assert_eq(n, 3, "three fields")
assert_eq(strings_strings$(l@, 1), "a", "a plain field")
assert_eq(strings_strings$(l@, 2), "b,c", "a quoted field holds the delimiter")
assert_eq(strings_strings$(l@, 3), "d", "blanks around a field are dropped")
n = strings_delimitedtext(l@, chr$(34) + "say " + chr$(34) + chr$(34) + "hi" + chr$(34) + chr$(34) + chr$(34))
assert_eq(strings_strings$(l@, 1), "say " + chr$(34) + "hi" + chr$(34), "a doubled quote is one quote")
n = strings_delimitedtext(l@, "x," + bytestr$(200) + bytestr$(201) + ",y")
assert_eq(byteat(strings_strings$(l@, 2), 2), 201, "a byte above 127 survives the field buffer")
n = strings_delimitedtext(l@, mulstring$("ab,", 50000) + "z")
assert_eq(n, 50001, "50000 delimiters make 50001 fields")
assert_eq(strings_strings$(l@, 50001), "z", "and the last is the tail")
assert_eq(strings_strings$(l@, 25000), "ab", "every other is ab")
n = strings_free(l@)

test_case("rag_analyze$ keeps the first-seen order of its keywords")
r@ = rag@("")
j@ = json_parse@(rag_analyze$(r@, "zeta alpha zeta beta alpha gamma beta"))
k@ = json_get@(j@, "keywords")
assert_eq(json_len(k@), 4, "four distinct words")
assert_eq(json_items$(k@, 1), "zeta", "first seen first")
assert_eq(json_items$(k@, 2), "alpha", "then alpha")
assert_eq(json_items$(k@, 3), "beta", "then beta, its second sighting dropped")
assert_eq(json_items$(k@, 4), "gamma", "and gamma")
n = json_free(j@)

test_case("funcexists? asks every signature, case-insensitively")
assert_true(funcexists?("ucase$"), "a built-in")
assert_true(funcexists?("UCASE$"), "in any case")
assert_true(funcexists?("mid$"), "a name registered under two signatures")
assert_false(funcexists?("ucase"), "the name is the whole name, suffix and all")
assert_false(funcexists?("ucase$:"), "a colon is not part of any name")
assert_false(funcexists?(""), "the empty name")
assert_true(funcexists?("Mine"), "a function of this program")

end

function mine()
  return 1
end function
