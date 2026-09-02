rem ---------------------------------------------------------------
rem Compound assignment on array elements.
rem
rem `a@[i] += v` needs the array handle and the index TWICE -- once
rem to read the element and once to write it back -- and the obvious
rem implementation emits the index expression a second time. That is
rem wrong, and silently: `a@[nextslot()] += 1` would call nextslot
rem twice and update a different element from the one it read.
rem
rem The internal registers cannot hold the indices either. There are
rem three and dim@ takes up to ten dimensions, so a register-based
rem version works for a@[i] and runs out at a@[i,j,k,l] -- which is
rem the kind of rule that makes a feature not worth having.
rem
rem So the values are computed once and copied on the stack by DUPN.
rem The section named "index-evaluated-once" is the one that would
rem fail on any other implementation.
rem ---------------------------------------------------------------

test_case("array-compound/numeric")
arr@ = dim@(10)
arr@[1] = 10
arr@[2] = 20
arr@[1] += 10
assert_eq(arr@[1], 20, "read, added and written back")
assert_eq(arr@[2], 20, "the neighbour is untouched")

test_case("array-compound/all-four-operators")
a@ = dim@(4)
a@[1] = 100
a@[1] -= 25
assert_eq(a@[1], 75, "minus equals")
a@[1] *= 2
assert_eq(a@[1], 150, "times equals")
a@[1] /= 3
assert_eq(a@[1], 50, "divide equals")
a@[1] += 0
assert_eq(a@[1], 50, "adding nothing")

test_case("array-compound/order-for-minus-and-divide")
rem v -= e is v - e, not e - v. A mistake here would be silent.
b@ = dim@(2)
b@[1] = 100
b@[1] -= 1
assert_eq(b@[1], 99, "hundred minus one")
b@[1] = 100
b@[1] /= 4
assert_eq(b@[1], 25, "hundred over four")

test_case("array-compound/precedence")
c@ = dim@(2)
c@[1] = 10
val = 5
c@[1] += val * 2
assert_eq(c@[1], 20, "the whole right-hand side is added")
c@[1] -= val + 5
assert_eq(c@[1], 10, "and subtracted")

test_case("array-compound/computed-index")
d@ = dim@(5)
for i = 1 to 5
  d@[i] = i
next
for i = 1 to 5
  d@[i] += 100
next
assert_eq(d@[1], 101, "first")
assert_eq(d@[3], 103, "middle")
assert_eq(d@[5], 105, "last")

k = 2
d@[k + 1] += 1000
assert_eq(d@[3], 1103, "an index that is itself an expression")
assert_eq(d@[2], 102, "and its neighbours are untouched")
assert_eq(d@[4], 104, "on both sides")

test_case("array-compound/index-evaluated-once")
rem The whole reason this needed a stack instruction. calls counts
rem how many times the index expression was evaluated: if the parser
rem emitted it twice, this reads 2 and the element updated would not
rem be the element read.
e@ = dim@(4)
e@[1] = 1
e@[2] = 2
calls = 0
e@[nextslot()] += 50
assert_eq(calls, 1, "the index expression ran once, not twice")
assert_eq(e@[1], 51, "and the element it named is the one that changed")
assert_eq(e@[2], 2, "the other one did not")

test_case("array-compound/multi-dimensional")
rem Two indices, which a register-based implementation could just
rem about manage, and three, which it could not.
m@ = dim@(3, 3)
m@[2, 2] = 7
m@[2, 2] += 3
assert_eq(m@[2, 2], 10, "two indices")
m@[1, 1] = 1
assert_eq(m@[1, 1], 1, "a neighbour in two dimensions")

t@ = dim@(2, 2, 2)
t@[2, 2, 2] = 5
t@[2, 2, 2] *= 4
assert_eq(t@[2, 2, 2], 20, "three indices")
t@[1, 1, 1] = 9
t@[1, 1, 1] -= 4
assert_eq(t@[1, 1, 1], 5, "and another corner")
assert_eq(t@[2, 2, 2], 20, "which left the first alone")

test_case("array-compound/string-elements")
s@ = sdim@(3)
s@[1] = "a"
s@[2] = "b"
s@[1] += "c"
assert_eq(s@[1], "ac", "string element append")
assert_eq(s@[2], "b", "the neighbour is untouched")
s@[1] += ""
assert_eq(s@[1], "ac", "appending nothing")
w$ = "d"
s@[1] += w$
assert_eq(s@[1], "acd", "appending a variable")

test_case("array-compound/string-in-a-loop")
u@ = sdim@(3)
u@[1] = ""
for i = 1 to 20
  u@[1] += "-"
next
assert_eq(len(u@[1]), 20, "twenty appends to one element")

test_case("array-compound/longhand-untouched")
z@ = dim@(3)
z@[1] = 5
z@[1] = z@[1] + 5
assert_eq(z@[1], 10, "the long way still works")
z@[2] = z@[1] * 2
assert_eq(z@[2], 20, "and reading one element to set another")

function nextslot()
  calls = calls + 1
  return 1
endfunction
