rem ---------------------------------------------------------------
rem The three small remainders: RegexLib 10/16, DictLib 16/20 and
rem NumLib 23/32. All three had the same shape of gap -- the parts
rem the applets in Examples/ call and never check.
rem
rem Note the argument order throughout RegexLib: the PATTERN comes
rem first and the text second, which is the opposite of instr and of
rem most of StrLib.
rem ---------------------------------------------------------------

test_case("regex/positions")
rem regex_findpos and regex_findlen describe the first match without
rem extracting it, which is what a caller needs to cut the string up
rem itself.
rem
rem POSITIONS HERE ARE 1-BASED, and absence is 0 -- the same as instr
rem in this engine (Phosphor is base-1 everywhere), so regex_findpos
rem and instr AGREE on the same match, unlike the reference where the
rem two differed.
text$ = "order 12345 shipped"
assert_eq(regex_find$("[0-9]+", text$), "12345", "regex_find$ extracts the match")
assert_eq(regex_findpos("[0-9]+", text$), 7, "regex_findpos counts from one")
assert_eq(instr(text$, "12345"), 7, "and instr agrees -- both are 1-based here")
assert_eq(regex_findlen("[0-9]+", text$), 5, "regex_findlen answers how long it is")

assert_eq(regex_findpos("[0-9]+", "no digits here"), 0, "absence is zero here")
assert_eq(instr("no digits here", "12345"), 0, "and zero there too")

test_case("regex/findall")
rem regex_findall@ answers a string list, so StrListLib reads it back.
all@ = regex_findall@("[0-9]+", "1 then 22 then 333")
assert_true(pnttonum(all@), "regex_findall@ answers a handle")
assert_eq(strings_count(all@), 3, "with one entry per match")
assert_eq(strings_strings$(all@, 1), "1", "in the order they were found")
assert_eq(strings_strings$(all@, 3), "333", "all the way to the last")

none@ = regex_findall@("[0-9]+", "nothing")
assert_eq(strings_count(none@), 0, "and an empty list when there is nothing to find")

test_case("regex/groups")
rem A group is a bracketed part of the pattern, and group ZERO is the
rem whole match -- so three brackets make four groups, and the list
rem starts with the match itself rather than with the first bracket.
date$ = "2020-06-15"
assert_eq(regex_groupcount("([0-9]{4})-([0-9]{2})-([0-9]{2})", date$), 4, "three brackets and the whole match make four")

g@ = regex_groups@("([0-9]{4})-([0-9]{2})-([0-9]{2})", date$)
assert_true(pnttonum(g@), "regex_groups@ answers a handle")
assert_eq(strings_count(g@), 4, "holding one entry per group, zero included")
assert_eq(strings_strings$(g@, 1), "2020-06-15", "entry zero is the whole match")
assert_eq(strings_strings$(g@, 2), "2020", "and the first bracket comes after it")
assert_eq(strings_strings$(g@, 4), "15", "through to the last")

assert_eq(regex_group$("([0-9]{4})-([0-9]{2})", date$, 1), "2020", "regex_group$ reads one by number")

test_case("regex/split")
p@ = regex_split@("[,;]", "a,b;c")
assert_true(pnttonum(p@), "regex_split@ answers a handle")
assert_eq(strings_count(p@), 3, "with one entry per piece")
assert_eq(strings_strings$(p@, 2), "b", "in order")

test_case("dict/queries")
rem dict_exists asks without reading, which is the difference between
rem "absent" and "present but zero".
d@ = dict@()
dict_set@(d@, "zero", 0)
assert_true(dict_exists(d@, "zero"), "a key holding zero still exists")
assert_false(dict_exists(d@, "absent"), "and one that was never set does not")
assert_eq(dict_get(d@, "zero"), 0, "and reading it answers the zero")

test_case("dict/keys-and-type")
dict_set@(d@, "another", 1)
assert_eq(dict_count(d@), 2, "two keys were set")
assert_true(len(dict_key$(d@, 1)), "dict_key$ names one by position")
rem dict_type answers a code: 0 numeric, 1 string, 2 pointer. Numeric
rem being zero means the obvious truth test reads an ordinary numeric
rem dictionary as "no type".
assert_eq(dict_type(d@), 0, "a numeric dictionary is type zero")
assert_eq(dict_type(sdict@()), 1, "a string dictionary is one")
assert_eq(dict_type(pdict@()), 2, "and a pointer dictionary is two")

test_case("dict/pointer-default")
rem pdict_getdef@ answers the default handle rather than nil when the
rem key is absent, which is what stops a caller dereferencing nothing.
p@ = pdict@()
fallback@ = pointer@(4242)
pdict_set@(p@, "here", fallback@)
assert_eq(pnttonum(pdict_getdef@(p@, "here", pointer@(0))), 4242, "a key that is there answers its own value")
assert_eq(pnttonum(pdict_getdef@(p@, "absent", fallback@)), 4242, "and one that is not answers the default")

test_case("num/hyperbolic")
rem The identities hold whatever the platform's precision: cosh squared
rem minus sinh squared is one, and each inverse undoes its own function.
assert_near(sinh(0), 0, 0.0001, "sinh of zero")
assert_near(cosh(0), 1, 0.0001, "cosh of zero")
assert_near(tanh(0), 0, 0.0001, "tanh of zero")
assert_near(cosh(1) * cosh(1) - sinh(1) * sinh(1), 1, 0.0001, "cosh squared less sinh squared is one")

assert_near(asinh(sinh(0.5)), 0.5, 0.0001, "asinh undoes sinh")
assert_near(acosh(cosh(1.5)), 1.5, 0.0001, "acosh undoes cosh")
assert_near(atanh(tanh(0.3)), 0.3, 0.0001, "atanh undoes tanh")

test_case("num/atan2")
rem atan2 knows which quadrant it is in, which is the whole reason it
rem takes two arguments instead of their ratio.
rem
rem This engine has no pi: NumLib registers acos, asin, atan and
rem degtorad but no constant for it, and Examples/03_numlib_test.bas
rem opens by assigning one by hand. degtorad(180) is that number
rem exactly, and costs a function call rather than fourteen digits.
p = degtorad(180)
assert_near(atan2(0, 1), 0, 0.0001, "along the positive x axis")
assert_near(atan2(1, 0), p / 2, 0.0001, "a quarter turn up")
assert_near(atan2(0, -1), p, 0.0001, "half a turn round")
assert_near(atan2(-1, 0), -p / 2, 0.0001, "and a quarter turn down")

test_case("num/int-and-compare")
rem int and fix are the classic BASIC pair and they part on negatives:
rem int goes DOWN and fix goes TOWARDS ZERO. On positives they agree,
rem which is why a program can use either for years and then meet the
rem difference the first time a number goes below zero.
assert_eq(int(3.7), 3, "int drops the fraction")
assert_eq(fix(3.7), 3, "and so does fix")
assert_eq(int(-3.7), -4, "int goes down")
assert_eq(fix(-3.7), -3, "and fix goes towards zero")
assert_eq(int(5), 5, "a whole number is left alone")

assert_eq(cmpval(1, 2), -1, "cmpval: less")
assert_eq(cmpval(2, 1), 1, "greater")
assert_eq(cmpval(2, 2), 0, "and equal")
