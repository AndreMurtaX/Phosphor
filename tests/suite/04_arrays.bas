rem ---------------------------------------------------------------
rem ArrayLib: creation, 1-based indexing, bracket sugar, bounds,
rem multi-dimensional access and the three element kinds.
rem ---------------------------------------------------------------

test_case("array/numeric-create")
a@ = dim@(5)
assert_eq(ndims(a@), 1, "ndims")
assert_eq(lbound(a@, 1), 1, "arrays are 1-based")
assert_eq(ubound(a@, 1), 5, "ubound")
assert_eq(arraysize(a@), 5, "arraysize")
assert_eq(arraytype(a@), 0, "numeric type id")
assert_eq(arraytypename$(a@), "numeric", "type name")

test_case("array/numeric-access")
narr_set@(a@, 1, 10)
narr_set@(a@, 5, 50)
assert_eq(narr_get(a@, 1), 10)
assert_eq(narr_get(a@, 5), 50)

test_case("array/bracket-sugar")
b@ = dim@(3)
b@[1] = 100
b@[2] = 200
b@[3] = 300
assert_eq(b@[1], 100)
assert_eq(b@[2], 200)
assert_eq(b@[3], 300)
assert_eq(narr_get(b@, 2), 200, "sugar and narr_get agree")

test_case("array/default-value")
c@ = dim@(3)
assert_eq(c@[1], 0, "numeric elements start at zero")

test_case("array/loop-fill")
d@ = dim@(10)
for i = 1 to 10
  d@[i] = i * i
next
s = 0
for i = 1 to 10
  s = s + d@[i]
next
assert_eq(s, 385, "sum of squares 1..10")

test_case("array/multidim")
m@ = dim@(3, 4)
assert_eq(ndims(m@), 2, "ndims")
assert_eq(ubound(m@, 1), 3, "ubound dim 1")
assert_eq(ubound(m@, 2), 4, "ubound dim 2")
assert_eq(arraysize(m@), 12, "total elements")
narr_set@(m@, 2, 3, 77)
assert_eq(narr_get(m@, 2, 3), 77)

test_case("array/three-dim")
t@ = dim@(2, 3, 4)
assert_eq(ndims(t@), 3)
assert_eq(arraysize(t@), 24)
narr_set@(t@, 1, 2, 3, 5)
assert_eq(narr_get(t@, 1, 2, 3), 5)

test_case("array/string-array")
s@ = sdim@(3)
assert_eq(arraytypename$(s@), "string", "type name")
sarr_set@(s@, 1, "alpha")
sarr_set@(s@, 2, "beta")
assert_eq(sarr_get$(s@, 1), "alpha")
assert_eq(sarr_get$(s@, 2), "beta")
assert_eq(sarr_get$(s@, 3), "", "unset elements are empty")

test_case("array/pointer-array")
p@ = pdim@(2)
assert_eq(arraytypename$(p@), "pointer", "type name")
inner@ = dim@(2)
inner@[1] = 123
parr_set@(p@, 1, inner@)
got@ = parr_get@(p@, 1)
assert_eq(narr_get(got@, 1), 123, "round trip through a pointer array")
