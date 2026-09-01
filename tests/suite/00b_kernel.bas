rem ---------------------------------------------------------------
rem Founding-divergence probe: what 00_harness.bas CANNOT prove.
rem 00_harness goes green on a single Double cell; these assertions
rem exercise the five-kind model directly. Dispatch to a '%' slot is
rem itself the proof that a value stayed an int%.
rem ---------------------------------------------------------------

test_case("kernel/real-vs-integer-division")
assert_eq(10 / 4, 2.5)
assert_int(7 \ 2, 3)
assert_int(9 \ 3, 3)

test_case("kernel/int-stays-int")
assert_int(3 + 4, 7)
assert_int(6 * 7, 42)

test_case("kernel/overflow-is-a-catchable-error")
assert_add_overflows(9223372036854775807, 1)

test_case("kernel/comparison-is-a-value")
assert_true(2 > 1)
assert_false(3 > 5)
