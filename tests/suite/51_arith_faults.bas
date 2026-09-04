rem ---------------------------------------------------------------
rem Arithmetic must not be able to KILL the interpreter.
rem
rem Every case here aborted the process with exit 217 -- a hardware
rem trap, not an error value, so `on error` could not see it and the
rem host got no chance to report anything. They were found by an
rem adversarial hunt, not by these suites, which stayed green
rem throughout: byte-exact goldens prove no regression, not health.
rem
rem The rule they now share: no TValue ever holds a non-finite
rem Double, and no Double is ever narrowed to Int64 unchecked.
rem ---------------------------------------------------------------

test_case("arith/float overflow in an ordinary expression is catchable, not fatal")
caught% = 0
on error goto ovf
y = 10.0 ^ 200
z = y * y
goto after_ovf
ovf:
caught% = 1
resume next
after_ovf:
on error goto 0
assert_eq(caught%, 1, "y * y overflowing to Inf reports instead of aborting")
assert_eq(err(), 1, "and reports it as an overflow")

test_case("arith/a compounding loop reports at the step that overflows")
caught% = 0
steps% = 0
on error goto grow
x = 1.5
for i = 1 to 3000
  x = x * 1.5
  steps% = steps% + 1
next
goto after_grow
grow:
caught% = 1
resume next
after_grow:
on error goto 0
assert_eq(caught%, 1, "the loop stops with an error rather than killing the process")
assert_true(steps% > 1000, "and it got a long way in before overflowing")

test_case("arith/Low(Int64) mod -1 is 0, the answer, not a trap")
lo% = -9223372036854775807
lo% = lo% - 1
minus1% = -1
assert_eq(lo% mod minus1%, 0, "x86 computes mod with the idiv whose QUOTIENT overflows")
assert_eq(lo% \ 1, lo%, "integer division by 1 still works on the minimum")

test_case("arith/an out-of-range Double never reaches a bare Round")
caught% = 0
on error goto big1
n% = 10.0 ^ 300
goto after_big1
big1:
caught% = 1
resume next
after_big1:
on error goto 0
assert_eq(caught%, 1, "storing 1E300 into an int% is a catchable overflow")

caught% = 0
on error goto big2
big = 10.0 ^ 30
q = big \ 2
goto after_big2
big2:
caught% = 1
resume next
after_big2:
on error goto 0
assert_eq(caught%, 1, "integer division of a huge Double is a catchable overflow")

test_case("arith/mod with a Double operand stays in Double and answers")
assert_eq((10.0 ^ 30) mod 2.5, 0, "a quotient beyond Int64 range is no longer narrowed")
assert_eq(7.5 mod 2, 1.5, "and the ordinary case is unchanged")

test_case("arith/'string - n' clamps instead of narrowing a huge count")
assert_eq("abcdef" - (10.0 ^ 30), "", "removing more characters than there are leaves nothing")
assert_eq("abcdef" - 2, "abcd", "and the ordinary case is unchanged")

test_case("num/a library that overflows reports at the call, not later")
caught% = 0
on error goto lib1
v = exp(1000.0)
goto after_lib1
lib1:
caught% = 1
resume next
after_lib1:
on error goto 0
assert_eq(caught%, 1, "exp(1000) has no finite result and says so")

test_case("compare/two int% values above 2^53 compare as the integers they are")
a% = 9007199254740993
b% = 9007199254740992
assert_eq(a% - b%, 1, "their difference was always right")
assert_true(a% <> b%, "and now the comparison agrees with it")
assert_true(a% > b%, "widening both to Double made them equal")
c% = 9223372036854775807
d% = 9223372036854775806
assert_true(c% > d%, "the same at the very top of the range")

test_case("lexer/exponent notation reads back what the language prints")
assert_eq(str$(1E200), "1E200", "this is the form ValToStr emits")
assert_eq(val(str$(1E200)), 1E200, "so the language must be able to read it")
assert_eq(1e3, 1000, "lower case")
assert_eq(1.5e3, 1500, "with a fraction")
assert_eq(2E-3, 0.002, "with a negative exponent")
assert_eq(1e+3, 1000, "and an explicit plus")

test_case("lexer/an identifier butted against a number is still two tokens")
e30 = 5
assert_eq(1 + e30, 6, "'e' not followed by digits does not start an exponent")
