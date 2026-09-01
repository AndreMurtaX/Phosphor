rem ---------------------------------------------------------------
rem String list (base-1, per decisions.md). The reference 10_strlist
rem is 0-based; indices are +1 here and indexof returns 0 when absent.
rem ---------------------------------------------------------------

test_case("strings/add-count")
l@ = strings@()
assert_eq(strings_count(l@), 0, "starts empty")
strings_add(l@, "banana")
strings_add(l@, "apple")
strings_add(l@, "cherry")
assert_eq(strings_count(l@), 3)

test_case("strings/index-access")
assert_eq(strings_strings$(l@, 1), "banana", "1-based")
assert_eq(strings_strings$(l@, 2), "apple")
assert_eq(strings_strings$(l@, 3), "cherry")

test_case("strings/indexof")
assert_eq(strings_indexof(l@, "apple"), 2)
assert_eq(strings_indexof(l@, "missing"), 0, "absent returns 0")

test_case("strings/insert-delete")
strings_insert(l@, 1, "first")
assert_eq(strings_count(l@), 4)
assert_eq(strings_strings$(l@, 1), "first")
strings_delete(l@, 1)
assert_eq(strings_count(l@), 3)
assert_eq(strings_strings$(l@, 1), "banana")

test_case("strings/sort")
strings_sort(l@)
assert_eq(strings_strings$(l@, 1), "apple")
assert_eq(strings_strings$(l@, 2), "banana")
assert_eq(strings_strings$(l@, 3), "cherry")

test_case("strings/exchange")
strings_exchange(l@, 1, 3)
assert_eq(strings_strings$(l@, 1), "cherry")
assert_eq(strings_strings$(l@, 3), "apple")

test_case("strings/clear")
strings_clear(l@)
assert_eq(strings_count(l@), 0)

test_case("strings/text")
t@ = strings@()
strings_add(t@, "one")
strings_add(t@, "two")
assert_eq(strings_count(t@), 2)
strings_clear(t@)
strings_text(t@, "alpha\nbeta")
assert_eq(strings_count(t@), 2, "text assignment splits on line breaks")
assert_eq(strings_strings$(t@, 1), "alpha")
assert_eq(strings_strings$(t@, 2), "beta")

test_case("strings/namevalue")
nv@ = strings@()
strings_add(nv@, "host=localhost")
strings_add(nv@, "port=8080")
assert_eq(strings_values$(nv@, "host"), "localhost")
assert_eq(strings_values$(nv@, "port"), "8080")
assert_eq(strings_indexofname(nv@, "port"), 2)

test_case("strings/commatext")
ct@ = strings@()
strings_commatext(ct@, "a,b,c")
assert_eq(strings_count(ct@), 3)
assert_eq(strings_strings$(ct@, 1), "a")
assert_eq(strings_strings$(ct@, 3), "c")
