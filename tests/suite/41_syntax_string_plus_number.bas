rem ---------------------------------------------------------------
rem "text " + number
rem
rem A number on the right of + inside a string expression is
rem converted with str$ instead of being a syntax error. The kind of
rem an expression is still decided by its FIRST token, so the reverse
rem order -- number + text -- remains an error, and the message now
rem says what to do about it.
rem
rem Two things are worth more attention than the feature itself. A
rem parenthesised string after + must still be a string, because
rem `"a" + (b$ + c$)` compiles today. And the conversion is str$,
rem which is not what PRINT uses -- the two disagree in the last
rem digits of a long fraction, so this file pins which one applies.
rem ---------------------------------------------------------------

test_case("strnum/basic")
score = 42
assert_eq("SCORE: " + score, "SCORE: 42", "a variable")
assert_eq("n=" + 7, "n=7", "a literal")
assert_eq("" + 0, "0", "zero onto an empty string")

test_case("strnum/still-a-string-afterwards")
s$ = "SCORE: " + score
assert_eq(len(s$), 9, "the result is an ordinary string")
assert_eq(s$ + "!", "SCORE: 42!", "usable in another expression")

test_case("strnum/precedence")
rem The number's own operators bind tighter than the concatenation,
rem and a following + goes back to being concatenation.
n = 3
assert_eq("a" + n * 2 + "b", "a6b", "multiply binds tighter")
assert_eq("a" + n + 1, "a31", "and a second + is concatenation, not addition")
rem A '(' after + is NOT arithmetic. It opens a parenthesised STRING
rem expression, which it did before this feature existed and which
rem `"a" + (b$ + c$)` below depends on. Arithmetic in parentheses
rem needs str$, and that is a deliberate limit rather than an
rem oversight: deciding by what is inside the brackets would mean
rem the same two characters meaning different things.
assert_eq("x" + str$(n + 1), "x4", "arithmetic in parentheses needs str$")
assert_eq("v=" + n * n * n, "v=27", "a longer arithmetic run")

test_case("strnum/negatives-and-calls")
assert_eq("neg " + -5, "neg -5", "a negative literal")
assert_eq("abs " + abs(0 - 9), "abs 9", "a numeric function")
m = -2
assert_eq("m=" + m, "m=-2", "a negative variable")

test_case("strnum/parenthesised-string-still-a-string")
rem The case that would break if the parser asked ExpressionKind
rem instead of looking at the token: a '(' after + can begin a STRING
rem expression, and did so before this feature existed.
b$ = "b"
c$ = "c"
assert_eq("a" + (b$ + c$), "abc", "a parenthesised string expression")
assert_eq("a" + (b$), "ab", "a parenthesised string variable")

test_case("strnum/matches-str-and-not-print")
rem str$ formats to 15 digits and PRINT to 13, so a long fraction
rem differs between them. This is the documented choice, pinned here
rem so it cannot drift without something failing.
assert_eq("x" + 1/3, "x" + str$(1/3), "the conversion is str$")
assert_eq("" + 100, str$(100), "for whole numbers too")

test_case("strnum/in-a-loop")
out$ = ""
for i = 1 to 5
  out$ = out$ + "[" + i + "]"
next
assert_eq(out$, "[1][2][3][4][5]", "built up a piece at a time")

test_case("strnum/longhand-untouched")
assert_eq("SCORE: " + str$(score), "SCORE: 42", "writing str$ still works")
assert_eq("a" + "b", "ab", "and plain concatenation")
assert_eq("abcdef" - 3, "abc", "and minus still truncates rather than subtracting")
