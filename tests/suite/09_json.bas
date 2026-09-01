rem ---------------------------------------------------------------
rem JsonLib: build, parse, read back, arrays and paths.
rem ---------------------------------------------------------------

test_case("json/build-object")
o@ = json_object@()
json_setn@(o@, "n", 42)
json_sets@(o@, "s", "text")
json_setb@(o@, "b", 1)
assert_eq(json_getn(o@, "n"), 42)
assert_eq(json_gets$(o@, "s"), "text")
assert_eq(json_getb(o@, "b"), 1)
assert_eq(json_count(o@), 3, "member count")

test_case("json/has")
ok = 0
if json_has(o@, "n") <> 0 then ok = 1
assert_eq(ok, 1, "existing member")

ok = 1
if json_has(o@, "missing") <> 0 then ok = 0
assert_eq(ok, 1, "absent member")

test_case("json/types")
ok = 0
if json_isobj(o@) <> 0 then ok = 1
assert_eq(ok, 1, "object is an object")
assert_eq(json_typename$(o@), "object")

test_case("json/parse")
rem a quote inside a string is escaped \" (or doubled ""); backslash escapes are back
p@ = json_parse@("{\"a\":1,\"b\":\"two\",\"c\":[1,2,3]}")
assert_eq(json_getn(p@, "a"), 1)
assert_eq(json_gets$(p@, "b"), "two")

test_case("json/array")
arr@ = json_get@(p@, "c")
assert_eq(json_len(arr@), 3, "array length")
assert_eq(json_itemn(arr@, 1), 1, "arrays are 1-based")
assert_eq(json_itemn(arr@, 3), 3)

ok = 0
if json_isarr(arr@) <> 0 then ok = 1
assert_eq(ok, 1, "array is an array")

test_case("json/build-array")
a@ = json_array@()
json_pushn@(a@, 10)
json_pushn@(a@, 20)
json_pushs@(a@, "thirty")
assert_eq(json_len(a@), 3)
assert_eq(json_itemn(a@, 1), 10)
assert_eq(json_itemn(a@, 2), 20)
assert_eq(json_items$(a@, 3), "thirty")

test_case("json/path")
deep@ = json_parse@("{\"user\":{\"name\":\"ana\",\"age\":30}}")
assert_eq(json_paths$(deep@, "user.name"), "ana")
assert_eq(json_pathn(deep@, "user.age"), 30)

test_case("json/roundtrip")
src$ = "{\"k\":7}"
r@ = json_parse@(src$)
out$ = json_stringify$(r@)
back@ = json_parse@(out$)
assert_eq(json_getn(back@, "k"), 7, "stringify then parse preserves the value")

test_case("json/remove")
d@ = json_parse@("{\"x\":1,\"y\":2}")
assert_eq(json_count(d@), 2)
json_remove@(d@, "x")
assert_eq(json_count(d@), 1)
ok = 1
if json_has(d@, "x") <> 0 then ok = 0
assert_eq(ok, 1, "removed member is gone")

test_case("json/defaults")
e@ = json_parse@("{}")
assert_eq(json_getn(e@, "nope", -1), -1, "numeric default")
assert_eq(json_gets$(e@, "nope", "fallback"), "fallback", "string default")
