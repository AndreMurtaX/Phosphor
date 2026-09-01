rem ---------------------------------------------------------------
rem Compound assignment: += -= *= /= for numbers, += for strings.
rem
rem `a += 1` emits exactly what `a = a + 1` emits, so nothing
rem downstream has to know the feature exists. `s$ += x` goes
rem straight to APPEND$, which is what the peephole would have made
rem of the longhand anyway.
rem
rem The operator and the '=' must be ADJACENT in the source. Without
rem that, `x + = 1` -- an error today -- would quietly start meaning
rem something, which is the one thing this must not do. The negative
rem suite carries that case; here we check the meanings.
rem ---------------------------------------------------------------

test_case("compound/add")
a = 10
a += 1
assert_eq(a, 11, "plus equals")
a += 0
assert_eq(a, 11, "adding nothing")
a += -5
assert_eq(a, 6, "adding a negative")

test_case("compound/subtract")
a = 10
a -= 3
assert_eq(a, 7, "minus equals takes the right operand from the left")
a -= -2
assert_eq(a, 9, "subtracting a negative")

test_case("compound/multiply-and-divide")
a = 6
a *= 7
assert_eq(a, 42, "times equals")
a /= 2
assert_eq(a, 21, "divide equals: the variable divided by the operand")
a /= 21
assert_eq(a, 1, "and down to one")

test_case("compound/precedence")
rem The whole right-hand side is one expression, so this adds val*2
rem and not val, then multiplies by two.
score = 10
val = 5
score += val * 2
assert_eq(score, 20, "the multiply binds tighter than the compound add")
score -= val + 5
assert_eq(score, 10, "and the whole sum is subtracted, not just val")
score *= 1 + 1
assert_eq(score, 20, "times a computed operand")

test_case("compound/order-matters-for-minus-and-divide")
rem v -= e is v - e, not e - v. A mistake here would be silent.
v = 100
v -= 1
assert_eq(v, 99, "hundred minus one")
v = 100
v /= 4
assert_eq(v, 25, "hundred over four")

test_case("compound/locals")
assert_eq(accumulate(5), 15, "compound assignment on a local")
assert_eq(accumulate(0), 0, "with nothing to add")

test_case("compound/string-append")
s$ = "a"
s$ += "b"
assert_eq(s$, "ab", "string plus equals")
s$ += ""
assert_eq(s$, "ab", "appending nothing")
t$ = "c"
s$ += t$
assert_eq(s$, "abc", "appending a variable")
assert_eq(t$, "c", "which is left alone")

test_case("compound/string-append-expression")
s$ = ""
s$ += "x" + "y"
assert_eq(s$, "xy", "the whole right-hand side is appended")
s$ += ucase$("z")
assert_eq(s$, "xyZ", "including a function call")

test_case("compound/string-append-in-a-loop")
s$ = ""
for i = 1 to 100
  s$ += "-"
next
assert_eq(len(s$), 100, "a hundred appends")

test_case("compound/longhand-still-works")
rem Everything above has a longhand form that must be untouched.
a = 1
a = a + 1
assert_eq(a, 2, "the long way still works")
let b = 5
b = b * 2
assert_eq(b, 10, "with LET too")
u$ = "p"
u$ = u$ + "q"
assert_eq(u$, "pq", "and for strings")

function accumulate(n) local total, k
  total = 0
  for k = 1 to n
    total += k
  next
  return total
endfunction
