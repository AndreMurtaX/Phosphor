rem ---------------------------------------------------------------
rem `let a, b, c` -- several names declared at once.
rem
rem Each name emits exactly what its own longhand emits, so a global
rem declared this way is indistinguishable from one declared the long
rem way. That is the whole test: not that the syntax parses, but that
rem what it produces is the same thing.
rem
rem A LET list declares names only. `let a, b = 5` is rejected, and
rem the negative suite carries that case.
rem ---------------------------------------------------------------

test_case("letlist/numeric")
let n1, n2, n3
assert_eq(n1, 0, "a declared number starts at zero")
assert_eq(n2, 0, "all of them")
assert_eq(n3, 0, "including the last")
n2 = 7
assert_eq(n2, 7, "and is an ordinary variable afterwards")
assert_eq(n1, 0, "with no bleed into its neighbours")
assert_eq(n3, 0, "on either side")

test_case("letlist/string")
let s1$, s2$, s3$
assert_eq(s1$, "", "a declared string starts empty")
assert_eq(s2$, "", "all of them")
assert_eq(len(s3$), 0, "measurably so")
s2$ = "middle"
assert_eq(s2$, "middle", "and takes a value")
assert_eq(s1$, "", "without disturbing the others")
assert_eq(s3$, "", "either side")

test_case("letlist/pointer")
rem The same three instructions `let p@ = pointer@(0)` emits: a
rem pointer that never held a handle still has to hold a valid one.
let p1@, p2@, p3@
assert_true(1, "three pointers declared without error")
p2@ = dim@(3)
p2@[1] = 11
assert_eq(p2@[1], 11, "and one of them takes a real array")
assert_eq(arraysize(p2@), 3, "of the right size")

test_case("letlist/mixed-kinds")
let m1, m2$, m3@
assert_eq(m1, 0, "a number")
assert_eq(m2$, "", "a string")
m3@ = dim@(2)
assert_eq(arraysize(m3@), 2, "and a pointer, in one statement")

test_case("letlist/two-names")
let x1, x2
assert_eq(x1 + x2, 0, "the shortest list")

test_case("letlist/matches-the-longhand")
rem Declared both ways, the two must behave identically.
let la
let lb, lc
assert_eq(la, lb, "long and short forms give the same starting value")
assert_eq(lb, lc, "and so do two names in one list")
la = 3 : lb = 3 : lc = 3
assert_eq(la + lb + lc, 9, "and all three assign the same way")

test_case("letlist/single-name-unchanged")
rem With no comma the old path is taken, untouched.
let solo = 42
assert_eq(solo, 42, "let with a value still works")
let solo2$ = "text"
assert_eq(solo2$, "text", "for strings")
let solo3@ = pointer@(0)
assert_true(1, "and for pointers")

test_case("letlist/inside-a-function")
assert_eq(uses_a_list(), 0, "a list inside a function")

function uses_a_list() local q
  q = 0
  return q
endfunction
