rem ---------------------------------------------------------------
rem CONST: a name for a number or a piece of text.
rem
rem The value is substituted where the name is used, so a constant
rem occupies no variable slot -- MAXVARS is 515 with three registers
rem reserved, and named numbers were spending that budget.
rem
rem The thing a reader actually gains is the second half: assigning
rem to a constant is a compile error. A name declared constant that
rem something later writes to is a bug the language can now catch.
rem The negative suite holds that case; this file holds the meaning.
rem
rem CONST is recognised contextually, like ELSEIF, so `const = 7`
rem goes on being an ordinary variable. That is checked here too,
rem because the day it stops being true, every program with a
rem variable or a function called const stops compiling.
rem ---------------------------------------------------------------

test_case("const/numeric")
const MAXLIVES = 3
assert_eq(MAXLIVES, 3, "a named number")
assert_eq(MAXLIVES * 2, 6, "used in arithmetic")
assert_eq(MAXLIVES + MAXLIVES, 6, "twice in one expression")

test_case("const/case-insensitive")
rem Names are case-insensitive in this language, and a constant is a
rem name.
assert_eq(maxlives, 3, "lower case")
assert_eq(MaxLives, 3, "mixed case")

test_case("const/negative-and-fractional")
const FREEZING = -40
const HALF = 0.5
assert_eq(FREEZING, -40, "a negative literal")
assert_eq(HALF * 4, 2, "a fractional one")
assert_eq(FREEZING + 40, 0, "arithmetic on a negative constant")

test_case("const/string")
const GREETING$ = "hello"
assert_eq(GREETING$, "hello", "a named string")
assert_eq(GREETING$ + " there", "hello there", "concatenated")
assert_eq(len(GREETING$), 5, "measured")
assert_eq(ucase$(GREETING$), "HELLO", "passed to a function")

test_case("const/in-a-condition")
lives = 3
r = 0
if lives = MAXLIVES then r = 1
assert_eq(r, 1, "a constant in a condition")

test_case("const/in-a-loop")
total = 0
for i = 1 to MAXLIVES
  total = total + i
next
assert_eq(total, 6, "a constant as a loop bound")

test_case("const/inside-a-function")
assert_eq(uses_const(), 30, "a global constant is visible in a function")

test_case("const/still-an-ordinary-variable-name")
rem The reason CONST is contextual and not a lexer keyword. If it
rem ever becomes one, this stops compiling -- and so does any user
rem function named const.
const = 7
assert_eq(const, 7, "const holds a number")
const = const + 1
assert_eq(const, 8, "and takes an assignment")
const += 2
assert_eq(const, 10, "including a compound one")

test_case("const/declaration-still-works-after-that")
const LATER = 99
assert_eq(LATER, 99, "a declaration after the variable use")
assert_eq(const + LATER, 109, "the variable and the constant coexist")

function uses_const() local t
  t = MAXLIVES * 10
  return t
endfunction
