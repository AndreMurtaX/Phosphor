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

test_case("harness/what assert_eq forgives")
rem Since 2026-10-06 (ledger d57) two INTEGRAL values compare exactly, and only
rem a fraction gets slack: four units in the last place, or 1e-12 near zero.
rem These pin the slack that must survive -- a tighter rule that refused them
rem would be a guard refusing something legitimate. The arithmetic: 0.1 + 0.2
rem is 0.30000000000000004, 5.6e-17 from 0.3, inside the 1e-12 floor; 1.1 * 3
rem is 3.3000000000000003, 4.4e-16 from 3.3, inside 4 * 2.2e-16 * 3.3 = 2.9e-15;
rem sin(pi) is 1.2e-16, a fraction, so it is forgiven against 0. The other half
rem -- a mutation of one in a big integral value FAILING -- cannot be asserted
rem from inside a passing file; it was watched by mutating 57_buffer and
rem 18_faults and recorded in the playbook.
assert_eq(0.1 + 0.2, 0.3, "a sum's last bit is forgiven")
assert_eq(1.1 * 3, 3.3, "and a product's, above one")
assert_eq(sin(3.141592653589793), 0, "and a result a rounding away from zero")

test_case("harness/messages")
assert_true(1, "message form works")
assert_eq(1, 1, "numeric message form works")
assert_eq("x", "x", "string message form works")
