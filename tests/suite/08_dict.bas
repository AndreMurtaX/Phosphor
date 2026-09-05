rem ---------------------------------------------------------------
rem DictLib: numeric, string and pointer dictionaries.
rem ---------------------------------------------------------------

test_case("dict/numeric")
d@ = dict@()
dict_set@(d@, "age", 25)
dict_set@(d@, "score", 100.5)
dict_set@(d@, "zero", 0)
assert_eq(dict_get(d@, "age"), 25)
assert_eq(dict_get(d@, "score"), 100.5)
assert_eq(dict_get(d@, "zero"), 0)
assert_eq(dict_count(d@), 3, "count")

test_case("dict/overwrite")
dict_set@(d@, "age", 30)
assert_eq(dict_get(d@, "age"), 30, "value replaced")
assert_eq(dict_count(d@), 3, "count unchanged")

test_case("dict/haskey")
ok = 0
if dict_haskey(d@, "age") <> 0 then ok = 1
assert_eq(ok, 1, "existing key")

ok = 1
if dict_haskey(d@, "missing") <> 0 then ok = 0
assert_eq(ok, 1, "absent key")

test_case("dict/default")
assert_eq(dict_getdef(d@, "missing", -1), -1, "default for absent key")
assert_eq(dict_getdef(d@, "age", -1), 30, "default ignored when present")

test_case("dict/remove")
dict_remove(d@, "zero")
assert_eq(dict_count(d@), 2)
ok = 1
if dict_haskey(d@, "zero") <> 0 then ok = 0
assert_eq(ok, 1, "removed key is gone")

test_case("dict/clear")
dict_clear@(d@)
assert_eq(dict_count(d@), 0)

test_case("dict/string")
sd@ = sdict@()
sdict_set@(sd@, "name", "John Doe")
sdict_set@(sd@, "city", "Sao Paulo")
sdict_set@(sd@, "empty", "")
assert_eq(sdict_get$(sd@, "name"), "John Doe")
assert_eq(sdict_get$(sd@, "city"), "Sao Paulo")
assert_eq(sdict_get$(sd@, "empty"), "")
assert_eq(dict_count(sd@), 3)
assert_eq(sdict_getdef$(sd@, "nope", "fallback"), "fallback")

test_case("dict/pointer")
pd@ = pdict@()
inner@ = dict@()
dict_set@(inner@, "value", 42)
pdict_set@(pd@, "nested", inner@)
got@ = pdict_get@(pd@, "nested")
assert_eq(dict_get(got@, "value"), 42, "round trip through a pointer dict")

test_case("dict/typename")
assert_eq(dict_typename$(d@), "numeric")
assert_eq(dict_typename$(sd@), "string")
assert_eq(dict_typename$(pd@), "pointer")

test_case("dict/constructor-name")
rem Pinned because both the user guide and the website documented the
rem constructor as dict_new@(0), which does not exist and never did.
d@ = dict@()
p@ = dict_set@(d@, "answer", 42)
assert_eq(dict_get(d@, "answer"), 42, "dict@() is the constructor")
assert_eq(dict_count(d@), 1, "and it starts empty")

test_case("dict/remove says whether it removed anything")
rem It used to answer 1 for a key that was never there, which is the one question
rem this call exists to settle. A mutator returns INFORMATION -- the rule dict_set@
rem (answers the dict), arr_set (the value) and strings_add (the index) all follow.
rd@ = dict@()
dict_set@(rd@, "here", 1)
assert_eq(dict_remove(rd@, "here"), 1, "a key that was present")
assert_eq(dict_remove(rd@, "here"), 0, "the same key a second time")
assert_eq(dict_remove(rd@, "never"), 0, "a key that was never there")
assert_eq(dict_count(rd@), 0, "and the dict is empty either way")
