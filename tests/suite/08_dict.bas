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

test_case("dict/one dictionary holds every kind")

rem The storage always did: Vals is an array of the engine's five-kind cell and
rem the setter never enforced anything. What used to be three dictionaries was
rem three registration surfaces over one container, so a program wanting a number
rem and a string under the same keys needed two dictionaries with the same keys.
u@ = dict@()
dict_set@(u@, "nome", "Ana")
dict_set@(u@, "idade", 41)
dict_set@(u@, "altura", 1.62)
dict_set@(u@, "ativo", true)
dict_set@(u@, "conf", sdict@())
assert_eq(dict_count(u@), 5, "five keys of five different kinds in one dictionary")

test_case("dict/what a key holds")

rem The question that only becomes askable once one dictionary can hold several
rem kinds -- and what makes dict_key$ useful for walking a mixed one.
assert_eq(dict_typeof$(u@, "nome"), "string", "a string key")
assert_eq(dict_typeof$(u@, "idade"), "int", "an int key")
assert_eq(dict_typeof$(u@, "altura"), "number", "a number key")
assert_eq(dict_typeof$(u@, "ativo"), "bool", "a bool key -- the kind that had no dictionary at all")
assert_eq(dict_typeof$(u@, "conf"), "handle", "a handle key")

rem An ABSENT key answers its own thing. Without that a program cannot tell an
rem absent key from one holding a number, and would have to ask dict_haskey first
rem every single time.
assert_eq(dict_typeof(u@, "nao_existe"), -1, "an absent key is -1, not a kind")
assert_eq(dict_typeof$(u@, "nao_existe"), "", "and has no kind name")
assert_eq(dict_typeof(u@, "nome"), 1, "the codes are the language's five kinds in order")

test_case("dict/typed getters answer their own empty value")

rem The one shared reader answered the CONTAINER's default for a missing key, so
rem dict_get$ on a dict@() would have handed back a number. Each typed spelling
rem answers its own empty value instead.
assert_eq(dict_get$(u@, "nome"), "Ana", "reading a string")
assert_eq(dict_get%(u@, "idade"), 41, "reading an int")
assert_eq(dict_get(u@, "altura"), 1.62, "reading a number")
assert_true(dict_get?(u@, "ativo") = true, "reading a bool")
assert_eq(dict_get$(u@, "nao_existe"), "", "a missing string key is empty, not zero")
assert_eq(dict_get%(u@, "nao_existe"), 0, "a missing number key is zero")
assert_true(dict_get?(u@, "nao_existe") = false, "a missing bool key is false")
assert_eq(dict_getdef$(u@, "nao_existe", "padrao"), "padrao", "or whatever default you name")

rem A handle read back is the LIVE object, not a copy: writing through what came
rem out changes what the dictionary still refers to.
inner@ = dict_get@(u@, "conf")
dict_set@(inner@, "dentro", "escrito pelo lado de fora")
assert_eq(dict_get$(dict_get@(u@, "conf"), "dentro"), "escrito pelo lado de fora", "dict_get@ hands back the live handle")
rem An absent handle key answers handle ZERO, and handle zero is not a handle:
rem passing it anywhere is rejected as a fabricated handle, which is the library's
rem documented behaviour and not something to assert around here.
rem
rem That is exactly why a default matters more here than anywhere: the answer for
rem "not there" looks like a value. The default handle is proved to be the one
rem passed in by writing through what came back.
outro@ = sdict@()
volta@ = dict_getdef@(u@, "nao_existe", outro@)
dict_set@(volta@, "marca", "veio de outro@")
assert_eq(dict_get$(outro@, "marca"), "veio de outro@", "dict_getdef@ answers the default handle itself")
assert_true(dict_getdef?(u@, "nao_existe", true) = true, "and dict_getdef? the default bool")
assert_true(dict_getdef?(u@, "ativo", false) = true, "while a present bool key wins over the default")

test_case("dict/the older constructors still say what they were made for")

rem dict_type/dict_typename$ answer what a dictionary was CREATED as. That is now
rem a statement of intent rather than a constraint -- nothing stops any of them
rem holding anything -- and every program written before this keeps working.
assert_eq(dict_typename$(u@), "numeric", "dict@() still calls itself numeric")
assert_eq(dict_typeof$(u@, "nome"), "string", "while a key of it holds a string")

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
