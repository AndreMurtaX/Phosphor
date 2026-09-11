rem ---------------------------------------------------------------
rem NumLib
rem ---------------------------------------------------------------

test_case("num/basic")
assert_eq(abs(-42), 42)
assert_eq(abs(42), 42)
assert_eq(abs(0), 0)
assert_eq(sqr(16), 4)
assert_eq(sqr(0), 0)

test_case("num/sign")
assert_eq(sgn(-7), -1)
assert_eq(sgn(0), 0)
assert_eq(sgn(7), 1)

test_case("num/min-max")
assert_eq(min(5, 3), 3)
assert_eq(max(5, 3), 5)
assert_eq(min(-1, -5), -5)
assert_eq(max(-1, -5), -1)

test_case("num/rounding")
assert_eq(round(3.7), 4)
assert_eq(round(3.2), 3)
assert_eq(round(-3.7), -4)

test_case("num/truncation")
assert_eq(fix(3.9), 3, "fix truncates toward zero")
assert_eq(fix(-3.9), -3)
assert_eq(cint(3.9), 3, "cint truncates")
assert_near(frac(2.25), 0.25, 0.000000001)

test_case("num/logarithms")
assert_near(log10(100), 2, 0.000000001)
assert_near(log2(8), 3, 0.000000001)
assert_near(ln(1), 0, 0.000000001)
assert_near(exp(0), 1, 0.000000001)
assert_near(ln(exp(1)), 1, 0.000000001)

test_case("num/trigonometry")
assert_near(sin(0), 0, 0.000000001)
assert_near(cos(0), 1, 0.000000001)
assert_near(tan(0), 0, 0.000000001)
pi = 3.14159265358979
assert_near(sin(pi / 2), 1, 0.000000001)
assert_near(cos(pi), -1, 0.000000001)

test_case("num/angle-conversion")
assert_near(degtorad(180), pi, 0.000000001)
assert_near(radtodeg(pi), 180, 0.000000001)

test_case("num/inverse-trig")
assert_near(asin(0), 0, 0.000000001)
assert_near(acos(1), 0, 0.000000001)
assert_near(atan(0), 0, 0.000000001)

test_case("num/random-range")
randomize()
outofrange = 0
for i = 1 to 200
  r = rnd(10)
  if r < 0 then outofrange = 1
  if r > 9 then outofrange = 1
next
assert_eq(outofrange, 0, "rnd(10) stays within 0..9")

outofrange = 0
for i = 1 to 200
  r = rnd()
  if r < 0 then outofrange = 1
  if r >= 1 then outofrange = 1
next
assert_eq(outofrange, 0, "rnd() stays within [0,1)")

test_case("num/predicates")
rem Division by zero raises a runtime error rather than producing NaN, so a
rem NaN cannot be built here; only the negative case is checked.
ok = 1
if isnan(1) <> 0 then ok = 0
assert_eq(ok, 1, "a normal number is not NaN")

ok = 1
if isinfinite(1) <> 0 then ok = 0
assert_eq(ok, 1, "a normal number is not infinite")

rem ---------------------------------------------------------------
rem ROUNDING AN INTEGER IS THAT INTEGER.
rem
rem round/fix/cint/int widened an int% to a Double before converting,
rem and that is wrong in both directions at once. Above 2^53 a Double
rem cannot hold every integer, so the value was silently changed; and
rem near High(Int64) the nearest Double lies ABOVE the range, so the
rem in-range test refused a number that was never out of range.
rem docs/libraries/num.md promises "all four answer an int%" and
rem "a magnitude past Int64 range is error code 1". Both were false.
rem ---------------------------------------------------------------

test_case("num/an int% past 2^53 is not rounded away")
big% = 9007199254740993
assert_int(round(big%), 9007199254740993)
assert_int(fix(big%), 9007199254740993)
assert_int(cint(big%), 9007199254740993)
assert_int(int(big%), 9007199254740993)

test_case("num/and one near the top of the range is not refused")
rem 9223372036854775806 is one BELOW High(Int64). As a Double it rounds to
rem 9223372036854775808, which is one ABOVE the range -- so the widening made
rem the guard reject a number squarely inside it.
top% = 9223372036854775806
assert_int(round(top%), 9223372036854775806)
assert_int(int(top%), 9223372036854775806)
neg% = -9223372036854775806
assert_int(fix(neg%), -9223372036854775806)

test_case("num/and the four still differ on a fraction")
rem The identity is only for an int%. A Double still rounds, truncates and
rem floors by its own rule, and those rules are not the same one.
assert_eq(int(-3.5), -4, "int floors")
assert_eq(fix(-3.5), -3, "fix truncates toward zero")
assert_eq(int(3.5), 3, "int floors a positive too")
assert_eq(fix(3.5), 3, "and fix agrees there")
assert_eq(round(2.5), 2, "round is unchanged for a Double")
