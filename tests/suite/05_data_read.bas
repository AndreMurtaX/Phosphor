rem ---------------------------------------------------------------
rem DATA / READ / RESTORE
rem ---------------------------------------------------------------

data 11, 22, 33
data 44, 55

test_case("data/sequential-read")
read a
read b
read c
assert_eq(a, 11)
assert_eq(b, 22)
assert_eq(c, 33)

test_case("data/continues-across-statements")
read d
read e
assert_eq(d, 44)
assert_eq(e, 55)

test_case("data/restore")
restore
read f
assert_eq(f, 11, "restore rewinds to the first item")

test_case("data/read-in-loop")
restore
s = 0
for i = 1 to 5
  read v
  s = s + v
next
assert_eq(s, 165, "11+22+33+44+55")
