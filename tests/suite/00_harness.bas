rem ---------------------------------------------------------------
rem Self-check of the test harness itself.
rem If this file fails, nothing else in the suite can be trusted.
rem ---------------------------------------------------------------

test_case("harness/boolean")
assert_true(1)
assert_true(-1)
assert_false(0)

test_case("harness/numeric")
assert_eq(2 + 3, 5)
assert_eq(10 / 4, 2.5)
assert_eq(-7, -7)

test_case("harness/string")
assert_eq("ab" + "cd", "abcd")
assert_eq("", "")

test_case("harness/tolerance")
assert_near(1 / 3, 0.333333, 0.000001)
assert_near(100.0000001, 100, 0.001)

test_case("harness/messages")
assert_true(1, "message form works")
assert_eq(1, 1, "numeric message form works")
assert_eq("x", "x", "string message form works")
