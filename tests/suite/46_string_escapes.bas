rem ---------------------------------------------------------------
rem String escapes. A quote is doubled ("" -> "), Pascal-style, and a
rem backslash introduces a C-style escape for the control characters:
rem \n \t \r \0 \a \b \f \v \\ and \" . Both spellings reach a quote.
rem A literal backslash is written \\ , so a Windows path is doubled.
rem ---------------------------------------------------------------

test_case("escape/newline tab return")
assert_eq("a\nb", "a" + chr$(10) + "b", "\n is a line feed")
assert_eq("a\tb", "a" + chr$(9) + "b", "\t is a tab")
assert_eq("a\rb", "a" + chr$(13) + "b", "\r is a carriage return")
assert_eq(len("a\nb"), 3, "an escape is one character")
assert_eq(len("\t\t\t"), 3, "three tabs are three characters")

test_case("escape/single codes")
assert_eq(asc("\n"), 10, "line feed is 10")
assert_eq(asc("\t"), 9, "tab is 9")
assert_eq(asc("\r"), 13, "carriage return is 13")
assert_eq(asc("\0"), 0, "nul is 0")
assert_eq(asc("\a"), 7, "bell is 7")
assert_eq(asc("\b"), 8, "backspace is 8")
assert_eq(asc("\f"), 12, "form feed is 12")
assert_eq(asc("\v"), 11, "vertical tab is 11")

test_case("escape/backslash and quote")
assert_eq(len("\\"), 1, "an escaped backslash is one character")
assert_eq(asc("\\"), 92, "and its code is 92")
assert_eq(asc("\""), 34, "an escaped quote is a quote")
assert_eq("a\\b", "a" + chr$(92) + "b", "a backslash in the middle")

test_case("escape/both quote spellings agree")
assert_eq("a\"b", "a""b", "the escape and the doubled quote reach the same quote")
assert_eq("say ""hi""", "say " + chr$(34) + "hi" + chr$(34), "doubling still works on its own")
assert_eq(len("\""), 1, "one quote, one character")

test_case("escape/a windows path is doubled")
assert_eq(len("C:\\temp\\a.txt"), 13, "each separator is one backslash")
assert_eq("C:\\temp", "C:" + chr$(92) + "temp", "and reads as the literal path")

test_case("escape/mixed in one string")
mixed$ = "tab\there\nline"
assert_eq(len(mixed$), 13, "tab(1) + here(4) + nl(1) + line... counted in codepoints")
assert_eq(instr(mixed$, chr$(9)), 4, "the tab lands where written")
assert_eq(instr(mixed$, chr$(10)), 9, "and the newline after it")
