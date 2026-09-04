rem ---------------------------------------------------------------
rem Language semantics that were quietly wrong.
rem
rem None of these failed loudly. Each produced a plausible answer, or
rem ran a statement it should not have, and every suite stayed green:
rem the corpus is written in ASCII and never happened to write
rem `-2 ^ 2` or a two-statement inline IF.
rem ---------------------------------------------------------------

test_case("expr/unary minus applies to the POWER, not to the base")
assert_eq(-2 ^ 2, -4, "every other BASIC and all of mathematics read it this way")
x = 3
assert_eq(-x ^ 2, -9, "with a variable too")
assert_eq(2 ^ -1, 0.5, "and a negative EXPONENT still parses")
assert_eq(-2 ^ 2 + 1, -3, "the sign belongs to the power, then the sum")
assert_eq(3 * -2, -6, "an ordinary negated factor is unchanged")
assert_eq((-2) ^ 2, 4, "and parentheses still say what they say")

test_case("expr/a power chain is still read left to right")
rem The fix moved unary minus above '^'. Recursing all the way back into the unary
rem rule would ALSO have made '^' right-associative and turned this from 64 into
rem 512 -- an unasked-for change riding along with an asked-for one.
assert_eq(2 ^ 3 ^ 2, 64, "(2^3)^2, the BASIC reading")
assert_eq(2 ^ -1 ^ 2, 0.25, "(2^-1)^2")

test_case("if/an inline IF guards the whole line, not just the first statement")
x = 0
y = 0
if 1 = 2 then x = 99 : y = 99
assert_eq(x, 0, "the guard was always honoured for the first statement")
assert_eq(y, 0, "and now for the second, which used to run every time")

x = 0
y = 0
if 1 = 1 then x = 5 : y = 6
assert_eq(x, 5, "a true guard still runs them")
assert_eq(y, 6, "both of them")

z = 0
if 1 = 2 then z = 1 : z = 2 else z = 7 : z = z + 1
assert_eq(z, 8, "and ELSE takes a list too")

test_case("str/instr counts what mid$ counts")
rem instr answered in BYTES while len/mid$/left$ count CODEPOINTS, so the most
rem natural line in the language -- mid$(s$, instr(s$, x), 1) -- was wrong for any
rem string with a non-ASCII character before the match. Silently: it returned the
rem wrong character rather than failing.
s$ = "caf" + chr$(233) + " x"
assert_eq(len(s$), 6, "six characters")
assert_eq(bytelen(s$), 7, "seven bytes")
p = instr(s$, "x")
assert_eq(p, 6, "the sixth CHARACTER, not the seventh byte")
assert_eq(mid$(s$, p, 1), "x", "so the two compose")
assert_eq(instr(s$, "z"), 0, "absent is still 0")

test_case("str/instr on ASCII is exactly as it was")
assert_eq(instr("hello", "l"), 3, "first match")
assert_eq(instr("hello", "l", 4), 4, "from a start position")
assert_eq(instr("hello", "z"), 0, "no match")
assert_eq(instrrev("hello", "l"), 4, "and the reverse search agrees")

test_case("str/the optional start is a character position too")
t$ = "caf" + chr$(233) + "xax"
assert_eq(instr(t$, "x"), 5, "the fifth character")
assert_eq(instr(t$, "x", 6), 7, "searching on from the sixth")
