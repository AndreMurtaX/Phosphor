rem ---------------------------------------------------------------
rem StrListLib: the procedural strings_* API, exercised.
rem
rem It was the largest gap left outside the GUI after DateTimeLib.
rem
rem A string list here indexes from ONE -- like arrays and every
rem other index in this dialect (Phosphor is base-1 everywhere). The
rem reference wrapped a 0-based TStringList; here every index below
rem is written out 1-based for that reason.
rem
rem The pair that earns its own case is find and indexof. They take
rem the same arguments, return the same thing -- an index, or 0 --
rem and one of them is a binary search that answers "not there"
rem about items that are, whenever the list is not sorted. The
rem reference page says so in a note. This says so in a run.
rem ---------------------------------------------------------------

test_case("strlist/it counts from one")
l@ = strings@()
assert_eq(strings_count(l@), 0, "a new list is empty")
assert_eq(strings_add(l@, "beta"), 1, "add returns the index it used")
assert_eq(strings_add(l@, "alpha"), 2, "and the next one")
assert_eq(strings_count(l@), 2, "two items")
assert_eq(strings_strings$(l@, 1), "beta", "index 1 is the first")
assert_eq(strings_strings$(l@, 2), "alpha", "index 2 the second")

test_case("strlist/indexof searches, and says 0 when it fails")
assert_eq(strings_indexof(l@, "alpha"), 2, "found at its index")
assert_eq(strings_indexof(l@, "zeta"), 0, "absent is 0, not -1")

test_case("strlist/find is a binary search and needs a sorted list")
rem Eight items in reverse order. indexof finds every one of them;
rem find reports 0 for every one of them, and reports it without
rem any error being raised. That is the trap: the two calls look
rem alike, take the same arguments, and disagree in silence.
r@ = strings@()
strings_add(r@, "h")
strings_add(r@, "g")
strings_add(r@, "f")
strings_add(r@, "e")
strings_add(r@, "d")
strings_add(r@, "c")
strings_add(r@, "b")
strings_add(r@, "a")
assert_eq(strings_indexof(r@, "a"), 8, "indexof finds a where it is")
assert_eq(strings_find(r@, "a"), 0, "find does not, because nothing is sorted")
assert_eq(strings_indexof(r@, "d"), 5, "indexof finds d")
assert_eq(strings_find(r@, "d"), 0, "find does not")

rem Sort it and find agrees with indexof on every one.
strings_sort(r@)
assert_eq(strings_strings$(r@, 1), "a", "sorting put a first")
assert_eq(strings_strings$(r@, 8), "h", "and h last")
assert_eq(strings_find(r@, "a"), 1, "now find agrees")
assert_eq(strings_find(r@, "d"), 4, "on d as well")
assert_eq(strings_indexof(r@, "d"), 4, "and indexof answers the same")

test_case("strlist/insert, delete, exchange and move")
m@ = strings@()
strings_add(m@, "one")
strings_add(m@, "two")
strings_insert(m@, 1, "zero")
assert_eq(strings_count(m@), 3, "insert grew the list")
assert_eq(strings_strings$(m@, 1), "zero", "and put it at the front")
assert_eq(strings_strings$(m@, 2), "one", "pushing the rest along")
strings_exchange(m@, 1, 3)
assert_eq(strings_strings$(m@, 1), "two", "exchange swapped the ends")
assert_eq(strings_strings$(m@, 3), "zero", "both ways")
strings_move(m@, 1, 2)
assert_eq(strings_strings$(m@, 2), "two", "move put it where it was asked")
strings_delete(m@, 1)
assert_eq(strings_count(m@), 2, "delete shrank it")
strings_clear(m@)
assert_eq(strings_count(m@), 0, "and clear emptied it")

test_case("strlist/text and comma text")
t@ = strings@()
strings_add(t@, "one")
strings_add(t@, "two")
assert_eq(strings_commatext$(t@), "one,two", "commatext joins with commas")
c@ = strings@()
strings_commatext(c@, "a,b,c")
assert_eq(strings_count(c@), 3, "and splits on them coming back")
assert_eq(strings_strings$(c@, 2), "b", "in order")

test_case("strlist/name=value pairs")
n@ = strings@()
strings_add(n@, "host=localhost")
strings_add(n@, "port=8080")
assert_eq(strings_namevalueseparator$(n@), "=", "= is the separator by default")
assert_eq(strings_values$(n@, "port"), "8080", "values takes the name")
assert_eq(strings_valuefromindex$(n@, 2), "8080", "valuefromindex takes the index")
assert_eq(strings_names$(n@, 1), "host", "names takes the index too")
assert_eq(strings_indexofname(n@, "port"), 2, "indexofname finds the row")
assert_eq(strings_indexofname(n@, "nothing"), 0, "and says 0 when it cannot")

test_case("strlist/sorted lists reject nothing and keep order")
s@ = strings@()
strings_sorted(s@, 1)
assert_eq(strings_sorted(s@), 1, "the list says it is sorted")
strings_add(s@, "gamma")
strings_add(s@, "alpha")
strings_add(s@, "beta")
assert_eq(strings_strings$(s@, 1), "alpha", "insertion keeps the order")
assert_eq(strings_strings$(s@, 3), "gamma", "throughout")
assert_eq(strings_find(s@, "beta"), 2, "and find works, the list being sorted")

test_case("strlist/free reports success and the handle stops working")
k = strings_free(l@)
assert_eq(k, 1, "free answers 1")
k = strings_free(l@)
assert_eq(k, 0, "a second free is refused")
