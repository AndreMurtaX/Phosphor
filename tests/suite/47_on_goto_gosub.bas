rem ---------------------------------------------------------------
rem ON GOTO / ON GOSUB -- computed jumps. A 1-based selector picks the
rem Nth label in the list; a selector outside 1..N matches nothing and
rem falls through to the next statement. ON GOSUB returns to the
rem statement after the ON, like an ordinary GOSUB.
rem ---------------------------------------------------------------

test_case("ongoto/picks the second of three")
hit = 0
k = 2
on k goto g1, g2, g3
hit = -1
g1:
  hit = 1
  goto gdone
g2:
  hit = 2
  goto gdone
g3:
  hit = 3
gdone:
assert_eq(hit, 2, "on k goto took the second branch")

test_case("ongoto/first and last")
sel = 1
on sel goto a1, a2
first = -1
a1:
  first = 10
  goto adone
a2:
  first = 20
adone:
assert_eq(first, 10, "selector 1 takes the first")

sel = 2
on sel goto b1, b2
last = -1
b1:
  last = 10
  goto bdone
b2:
  last = 20
bdone:
assert_eq(last, 20, "selector 2 takes the last")

test_case("ongoto/out of range falls through")
fell = 0
big = 9
on big goto c1, c2
fell = 1
goto cdone
c1:
  fell = 100
  goto cdone
c2:
  fell = 200
cdone:
assert_eq(fell, 1, "a selector past the end runs the next statement")

zero = 0
on zero goto d1, d2
zero = 1
goto ddone
d1:
d2:
ddone:
assert_eq(zero, 1, "selector zero also falls through")

test_case("ongosub/calls the nth routine and returns")
acc = 0
j = 3
on j gosub subA, subB, subC
assert_eq(acc, 30, "on j gosub called the third routine and came back")
goto afterSubs
subA:
  acc = 10
  return
subB:
  acc = 20
  return
subC:
  acc = 30
  return
afterSubs:

test_case("ongosub/out of range does nothing")
acc2 = 7
on 99 gosub subA, subB, subC
assert_eq(acc2, 7, "an out-of-range on gosub calls no routine and continues")

test_case("ongosub/still an ordinary variable name")
rem `on` is contextual: it opens a computed jump only before goto/gosub.
on = 5
assert_eq(on, 5, "on holds a number")
on = on + 2
assert_eq(on, 7, "and takes an assignment")
