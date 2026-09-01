rem ---------------------------------------------------------------
rem Core language: literals, operators, precedence, assignment.
rem Note: boolean expressions are only valid inside IF/WHILE/UNTIL
rem conditions, so comparisons are checked through a flag variable.
rem ---------------------------------------------------------------

test_case("core/arithmetic")
assert_eq(2 + 3, 5)
assert_eq(10 - 4, 6)
assert_eq(6 * 7, 42)
assert_eq(10 / 4, 2.5)
assert_eq(7 mod 3, 1)
assert_eq(2 ^ 10, 1024)

test_case("core/precedence")
assert_eq(2 + 3 * 4, 14)
assert_eq((2 + 3) * 4, 20)
assert_eq(10 - 2 - 3, 5)
assert_eq(2 * 3 + 4 * 5, 26)
assert_eq(100 / 10 / 2, 5)

test_case("core/unary")
assert_eq(-5 + 8, 3)
assert_eq(-(3 + 4), -7)
x = 9
assert_eq(-x, -9)

test_case("core/assignment")
let a = 5
b = a * 2
assert_eq(b, 10)
a = a + 1
assert_eq(a, 6)

test_case("core/string-concat")
s$ = "Plan9"
t$ = s$ + "Basic"
assert_eq(t$, "Plan9Basic")
assert_eq("" + "x", "x")

test_case("core/comparison")
ok = 0
if 2 > 1 then ok = 1
assert_eq(ok, 1, "2 > 1")

ok = 0
if 1 < 2 then ok = 1
assert_eq(ok, 1, "1 < 2")

ok = 0
if 2 >= 2 then ok = 1
assert_eq(ok, 1, "2 >= 2")

ok = 0
if 2 <= 2 then ok = 1
assert_eq(ok, 1, "2 <= 2")

ok = 0
if 1 <> 2 then ok = 1
assert_eq(ok, 1, "1 <> 2")

ok = 0
if 2 = 2 then ok = 1
assert_eq(ok, 1, "2 = 2")

test_case("core/string-comparison")
ok = 0
if "abc" = "abc" then ok = 1
assert_eq(ok, 1, "equal strings")

ok = 0
if "abc" <> "abd" then ok = 1
assert_eq(ok, 1, "different strings")

test_case("core/logic")
ok = 0
if (2 > 1) and (3 > 2) then ok = 1
assert_eq(ok, 1, "and")

ok = 0
if (1 > 2) or (3 > 2) then ok = 1
assert_eq(ok, 1, "or")

ok = 0
if not (1 > 2) then ok = 1
assert_eq(ok, 1, "not")

ok = 1
if (1 > 2) and (3 > 2) then ok = 0
assert_eq(ok, 1, "and is false when one side is false")

test_case("core/float-precision")
assert_near(0.1 + 0.2, 0.3, 0.000000001)
assert_near(1 / 3, 0.3333333333333, 0.0000000001)
