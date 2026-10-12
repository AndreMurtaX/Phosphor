rem ---------------------------------------------------------------
rem  SIN, COS, LOG2 AND LOG10, ROUND 11 (2026-10-11).
rem
rem  1. LINUX: sin and cos answered x ITSELF for |x| >= 2^63 --
rem     sin(1e22) printed 1E22 -- and lost digits below that: x87
rem     fsin/fcos leave an operand that large unchanged and reduce a
rem     smaller one with a 66-bit pi (sin(pi) wrong from the 5th digit).
rem     Windows ran FPC's Cephes code, one ulp off in about a quarter
rem     of a sweep. Both now reduce exactly (Payne-Hanek, 2/pi to
rem     1280 bits) and sum the series as double-doubles.
rem  2. WINDOWS: log2 and log10 were ln(x) times a constant, rounded
rem     twice in Double, so int(log2(8)) was 2 and int(log10(1e15))
rem     was 14: 38 of 166 exact powers came back one ulp off.
rem
rem  EXPECTED VALUES, independent of the engine:
rem   - Every pinned sin/cos/log value is the CORRECTLY ROUNDED
rem     result IEEE 754 clause 9.2 recommends, computed for the same
rem     Double argument in Python's decimal module at 800 digits --
rem     pi from the module's own series, sin and cos from their Taylor
rem     series, ln and log10 from the module -- with no libm involved.
rem     Python's math module (the C library) agrees on each one.
rem   - A sine and a cosine lie in -1 .. 1 by definition.
rem   - log2(2^k) = k exactly: 2^k is exact for k = -1074 .. 1023
rem     (doubling and halving 1 are exact), and so is its log.
rem   - log10(1e<k>) = k: for 0 <= k <= 22 the literal is exact. For
rem     every other k the literal is the nearest Double, within
rem     2^-53 of 10^k relative, so its log10 is within 0.4343 * 2^-53
rem     (4.9e-17) of k -- less than half an ulp of any k other than
rem     0, so the correctly rounded answer is k itself.
rem  Each comparison is exact (=), not assert_eq's four ulps: the
rem  defect on Windows was ONE ulp.
rem ---------------------------------------------------------------

test_case("trig/huge arguments answer a sine, not x")
assert_true(sin(1e22) = -0.8522008497671888, "sin(1e22): Linux answered 1E22")
assert_true(cos(1e22) = 0.523214785395139, "cos(1e22)")
assert_true(sin(1e19) = -0.9270631660486504, "sin(1e19), past 2^63")
assert_true(cos(1e300) = -0.5753861119575491, "cos(1e300)")
assert_true(sin(-1e300) = 0.8178819121159085, "sin(-1e300): odd, and past 2^63")
assert_true(sin(9223372036854775808.0) = 0.9999303766734422, "sin(2^63), the first x87 refuses")
assert_true(sin(1.7976931348623157e308) = 0.004961954789184062, "sin of the largest Double")
assert_true(cos(8.98846567431158e307) = -0.826369834614148, "cos(2^1023)")
x = 1e300 : bad = 0
for k = 1 to 8
  if abs(sin(x)) > 1 or abs(cos(x)) > 1 then bad = bad + 1
  x = x * 10
next
assert_eq(bad, 0, "sin and cos of 1e300 .. 1e307 lie in -1 .. 1")

test_case("trig/the reduction below 2^63")
assert_true(sin(3.141592653589793) = 1.2246467991473532e-16, "sin(pi): the Double pi's distance from pi")
assert_true(cos(1.5707963267948966) = 6.123233995736766e-17, "cos(pi/2)")
assert_true(sin(1000000) = -0.34999350217129294, "sin(1e6)")
assert_true(cos(1000000) = 0.9367521275331447, "cos(1e6)")
assert_true(sin(9.2e18) = 0.4468697073437947, "sin(9.2e18): Linux lost the leading digits")
assert_true(sin(10000000000.0) = -0.4875060250875107, "sin(1e10)")
assert_true(sin(10) = -0.5440211108893698, "sin(10)")
assert_true(sin(355) = -0.00003014435335948845, "sin(355): 355/113 is close to pi")
assert_true(cos(100) = 0.8623188722876839, "cos(100)")
rem The Double nearest a multiple of pi/2, 6381956970095103 * 2^797:
rem its remainder is about 4.7e-19, sixty-odd bits below the argument.
assert_true(cos(5.319372648326541e255) = -4.687165924254628e-19, "the hardest Double to reduce: cos")
assert_true(sin(5.319372648326541e255) = 1, "the hardest Double to reduce: sin")

test_case("trig/small arguments")
assert_true(sin(0.5) = 0.479425538604203, "sin(0.5)")
assert_true(cos(0.5) = 0.8775825618903728, "cos(0.5)")
assert_true(sin(4) = -0.7568024953079282, "sin(4)")
assert_true(cos(4) = -0.6536436208636119, "cos(4)")
assert_true(sin(1e-9) = 1e-9, "sin(1e-9) is 1e-9 to the last bit")
assert_true(cos(1e-9) = 1, "cos(1e-9) is 1 to the last bit")
assert_eq(str$(sin(val("-0"))), "-0", "sin(-0) keeps the sign of zero")

test_case("log/exact powers")
assert_true(log2(8) = 3, "log2(8)")
assert_eq(int(log2(8)), 3, "int(log2(8)): Windows said 2")
assert_true(log10(1e15) = 15, "log10(1e15)")
assert_eq(int(log10(1e15)), 15, "int(log10(1e15)): Windows said 14")
assert_true(log10(0.1) = -1, "log10(0.1): Windows said -0.99999999999999989")
x = 1.0 : bad = 0
for k = 0 to 1023
  if log2(x) <> k then bad = bad + 1
  if k < 1023 then x = x * 2
next
assert_eq(bad, 0, "log2(2^k) = k for k = 0 .. 1023")
x = 1.0 : bad = 0
for k = 0 to -1074 step -1
  if log2(x) <> k then bad = bad + 1
  if k > -1074 then x = x / 2
next
assert_eq(bad, 0, "log2(2^k) = k for k = 0 .. -1074, subnormals included")
bad = 0
for k = -307 to 308
  if log10(val("1e" + str$(k))) <> k then bad = bad + 1
next
assert_eq(bad, 0, "log10(1e<k>) = k for k = -307 .. 308")

test_case("log/correctly rounded in general")
assert_true(log2(10) = 3.321928094887362, "log2(10)")
assert_true(log2(3) = 1.584962500721156, "log2(3)")
assert_true(log2(0.1) = -3.321928094887362, "log2(0.1)")
assert_true(log2(1e300) = 996.5784284662087, "log2(1e300)")
assert_true(log10(2) = 0.3010299956639812, "log10(2)")
assert_true(log10(7) = 0.8450980400142568, "log10(7)")
assert_true(log10(0.3) = -0.5228787452803376, "log10(0.3)")
assert_true(log10(1.7976931348623157e308) = 308.25471555991675, "log10 of the largest Double")
assert_true(log10(5e-324) = -323.3062153431158, "log10 of the smallest subnormal")
