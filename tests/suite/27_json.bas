rem ---------------------------------------------------------------
rem JsonLib. check-coverage.py reported 25/50: the scalar
rem constructors, the type predicates, arrays, paths and cloning had
rem never been run.
rem
rem Two conventions worth stating, because both are already documented
rem and neither is what a reader guesses:
rem
rem   * json_count is object keys ONLY. An array is counted by json_len,
rem     which handles both. json_count on an array answers zero, which
rem     reads exactly like an empty array.
rem   * item and path indices are 1-based, like the rest of this
rem     library's positional arguments.
rem ---------------------------------------------------------------

test_case("json/scalars")
rem Every JSON value is a handle, including the ones that hold a single
rem thing. That is what lets them be pushed into arrays and set into
rem objects without a second set of functions.
n@ = json_null@()
assert_true(json_isnull(n@), "json_null@ answers a null")
assert_eq(json_typename$(n@), "null", "and names itself")

b@ = json_bool@(1)
assert_true(json_isbool(b@), "json_bool@ answers a boolean")
assert_eq(json_value(b@), 1, "json_value reads it as a number")

num@ = json_number@(42.5)
assert_true(json_isnum(num@), "json_number@ answers a number")
assert_near(json_value(num@), 42.5, 0.0001, "json_value reads it")

s@ = json_string@("text")
assert_true(json_isstr(s@), "json_string@ answers a string")
assert_eq(json_value$(s@), "text", "json_value$ reads it")

test_case("json/type-codes")
rem json_type answers a code and json_typename$ the name for the same
rem value, so the two have to agree on every kind.
o@ = json_object@()
a@ = json_array@()
differ = 0
if json_type(o@) <> json_type(a@) then differ = 1
assert_true(differ, "an object and an array are different types")
assert_eq(json_typename$(o@), "object", "and each names itself")
assert_eq(json_typename$(a@), "array", "both of them")

test_case("json/object-writes")
json_sets@(o@, "name", "Alice")
json_setn@(o@, "age", 30)
json_setb@(o@, "member", 1)
json_setnull@(o@, "middle")

assert_eq(json_gets$(o@, "name"), "Alice", "a string reads back")
assert_eq(json_getn(o@, "age"), 30, "a number reads back")
assert_true(json_getb(o@, "member"), "a boolean reads back")
assert_true(json_has(o@, "middle"), "a null key is still a key")
assert_true(json_isnull(json_get@(o@, "middle")), "and what is under it is null")
assert_eq(json_count(o@), 4, "json_count counts the object's keys")

rem json_set@ takes a handle, which is how a nested object is built.
inner@ = json_object@()
json_sets@(inner@, "city", "Lisbon")
json_set@(o@, "address", inner@)
assert_eq(json_gets$(json_get@(o@, "address"), "city"), "Lisbon", "a nested object reads through")

test_case("json/defaults")
rem The two-argument getters answer a default rather than zero when the
rem key is absent, which is the difference between missing and empty.
assert_eq(json_getn(o@, "absent", 99), 99, "a missing number answers the default")
assert_eq(json_gets$(o@, "absent", "none"), "none", "and a missing string")

test_case("json/keys-and-removal")
k@ = json_keys@(o@)
assert_true(json_isarr(k@), "json_keys@ answers an array")
assert_eq(json_len(k@), 5, "with one entry per key")

json_remove@(o@, "middle")
assert_false(json_has(o@, "middle"), "json_remove@ takes a key out")
assert_eq(json_count(o@), 4, "and the count follows")

test_case("json/arrays")
json_pushs@(a@, "first")
json_pushn@(a@, 2)
json_pushb@(a@, 1)
json_pushnull@(a@)
assert_eq(json_len(a@), 4, "json_len counts an array")
assert_eq(json_count(a@), 0, "json_count, which is object keys, says nothing about one")

assert_eq(json_items$(a@, 1), "first", "json_items$ reads by position")
assert_eq(json_itemn(a@, 2), 2, "json_itemn too")
assert_true(json_itemb(a@, 3), "and json_itemb")
assert_true(json_isnull(json_item@(a@, 4)), "json_item@ answers the handle itself")

assert_eq(json_itemn(a@, 10, 77), 77, "an index past the end answers the default")
assert_eq(json_items$(a@, 10, "none"), "none", "for strings as well")

rem json_push@ takes a handle, so an object goes into an array whole.
row@ = json_object@()
json_sets@(row@, "k", "v")
json_push@(a@, row@)
assert_eq(json_len(a@), 5, "json_push@ appends a handle")
assert_eq(json_gets$(json_item@(a@, 5), "k"), "v", "which reads back as what it was")

json_removeat@(a@, 1)
assert_eq(json_len(a@), 4, "json_removeat@ takes one out by position")
assert_eq(json_itemn(a@, 1), 2, "and the rest shift down")

json_pop@(a@)
assert_eq(json_len(a@), 3, "json_pop@ takes the last one off")

test_case("json/paths")
rem A path walks nested objects with dots, which is the whole reason it
rem exists: json_get@ would need one call per level.
deep@ = json_parse@("{\"a\":{\"b\":{\"n\":7,\"s\":\"x\",\"f\":true}}}")
assert_true(pnttonum(deep@), "json_parse@ answers a handle")
assert_eq(json_pathn(deep@, "a.b.n"), 7, "json_pathn walks to a number")
assert_eq(json_paths$(deep@, "a.b.s"), "x", "json_paths$ to a string")
assert_true(json_pathb(deep@, "a.b.f"), "json_pathb to a boolean")
assert_true(json_isobj(json_path@(deep@, "a.b")), "json_path@ to the value itself")

assert_eq(json_pathn(deep@, "a.b.missing", 5), 5, "a path that is not there answers the default")
assert_eq(json_paths$(deep@, "nowhere.at.all", "gone"), "gone", "for strings too")

test_case("json/clone-and-merge")
rem A clone is deep: changing the copy must not reach the original.
orig@ = json_object@()
json_sets@(orig@, "k", "before")
copy@ = json_clone@(orig@)
json_sets@(copy@, "k", "after")
assert_eq(json_gets$(orig@, "k"), "before", "the original is untouched")
assert_eq(json_gets$(copy@, "k"), "after", "and the clone carries the change")

target@ = json_object@()
json_sets@(target@, "keep", "mine")
source@ = json_object@()
json_sets@(source@, "added", "theirs")
json_merge@(target@, source@)
assert_eq(json_gets$(target@, "keep"), "mine", "json_merge@ keeps what was there")
assert_eq(json_gets$(target@, "added"), "theirs", "and takes what was given")

test_case("json/rendering")
r@ = json_object@()
json_sets@(r@, "k", "v")
flat$ = json_stringify$(r@)
assert_true(len(flat$), "json_stringify$ renders")
assert_eq(instr(flat$, "\n"), 0, "on one line")

pretty$ = json_pretty$(r@)
atleast = 0
if len(pretty$) >= len(flat$) then atleast = 1
assert_true(atleast, "json_pretty$ renders at least as much")
wide$ = json_pretty$(r@, 4)
assert_true(len(wide$), "and its indent form answers too")

rem What was rendered parses back to the same thing, which is the only
rem claim about the text that matters.
back@ = json_parse@(flat$)
assert_eq(json_gets$(back@, "k"), "v", "and what comes back is what went out")
