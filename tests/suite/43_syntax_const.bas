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

test_case("const/a parameter shadows a same-named constant")
rem A const is an OUTER binding, and the inner one wins -- the rule this
rem language already applied to globals, which EmitLoadVar has always resolved
rem through LocalIndex first. A const was the one outer name a parameter could
rem not shadow: ParsePrimary tested ConstIndex ahead of the only branch that
rem consults LocalIndex, so `const MAXLIVES = 3` was substituted for the
rem PARAMETER of `function area(maxlives)`: the argument was thrown away and the
rem parameter was dead code, with nothing reported. Note the arguments -- 3 would
rem answer 9 either way here, because the constant is 3, and a test that cannot
rem tell the two apart is not a test.
assert_eq(area(5), 25, "the parameter wins: 5 * 5, not 3 * 3")
assert_eq(area(7), 49, "and again with another argument, so it is not a constant")
assert_eq(MAXLIVES, 3, "the constant itself is untouched outside the function")

test_case("const/a shadowing parameter can be written to")
rem The other half of the same defect, and the one that was not silent: a body
rem that WROTE the parameter failed at compile time with `cannot assign to
rem constant maxlives`, pointing at a line the author wrote as an ordinary
rem parameter update. EmitStoreVar asked ConstIndex before LocalIndex. Before the
rem fix this file did not compile at all.
assert_eq(bump(4), 5, "an ordinary parameter update")
assert_eq(local_shadow(), 7, "and a `local` of the same name, not just a parameter")

test_case("const/a constant and a like-named local in DIFFERENT functions")
rem The mirror. This was always legal and is the common case: the two orders
rem differ only where the name IS a parameter or local of the function being
rem compiled. A function that does not shadow the name still sees the constant,
rem including one compiled AFTER a function that shadows it.
assert_eq(other_sees_const(), 6, "a later function still substitutes the constant")
assert_eq(uses_const(), 30, "and so does the one from before the shadowing pair")
assert_eq(area(5) + other_sees_const(), 31, "both in one expression")

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

test_case("const/the literal is checked against the name suffix")
rem A const is a BINDING, and it was the one binding nobody checked. The value
rem was built from the token kind alone -- tkInt, tkDouble, tkString -- and the
rem NAME was never consulted, so `const i% = 1.5` kept 1.5 under a `%` name and
rem `const s$ = 5` kept an Int64 under a `$` one. Every other binding asks
rem VarTypeOf: VarIndex for a global, AddLocal for a frame slot, which is why
rem `i% = 1.5` has always stored 2.
rem
rem A const now asks the same question through the same StoreCheck, so it takes
rem the same coercion. The refusals -- `const s$ = 5` and friends -- live in
rem tests/negative, because a compile error cannot be asserted from inside the
rem program it kills. This holds the half that still compiles.
rem
rem assert_int is `:%%` ONLY, so it takes no message argument -- a third one
rem raises `no function assert_int:%%$` and halts the file. It is used here
rem precisely because `%` accepts an int% and NOTHING ELSE: it asserts the KIND
rem the constant holds, not merely the number it prints. Before the fix
rem ROUNDED% held a Double and this line failed with `no function assert_int:n%`.
const ROUNDED% = 1.5
assert_int(ROUNDED%, 2)
assert_eq(ROUNDED% * 2, 4, "the rounded value is what arithmetic sees")
const WHOLE% = 7
assert_int(WHOLE%, 7)
rem And the unsuffixed and `$` forms are untouched: a plain name still takes
rem either kind of number, and a `$` name still takes text.
const EXACT = 2.5
assert_eq(EXACT * 4, 10, "an unsuffixed const keeps its fraction")
const TAG$ = "ok"
assert_eq(TAG$ + "!", "ok!", "a $ const still holds text")

function uses_const() local t
  t = MAXLIVES * 10
  return t
endfunction

rem The parameter is named exactly like the constant declared at the top of this
rem file. Inside these three the name is the frame slot; outside them it is still
rem the constant.
function area(maxlives)
  return maxlives * maxlives
endfunction

function bump(maxlives)
  maxlives = maxlives + 1
  return maxlives
endfunction

function local_shadow() local maxlives
  maxlives = 7
  return maxlives
endfunction

rem And this one does NOT shadow it, so it reads the constant -- the mirror.
function other_sees_const()
  return MAXLIVES * 2
endfunction
