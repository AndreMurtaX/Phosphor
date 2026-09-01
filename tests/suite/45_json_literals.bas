rem ---------------------------------------------------------------
rem JSON literal syntax. A '[' or '{' at a value position builds a
rem JSON value directly and answers a handle, the ergonomic partner
rem of the json_* builder functions. Element values may be scalar
rem literals, true/false/null, nested [ ]/{ }, or any expression.
rem
rem Authored for Phosphor (the reference documents the feature but
rem ships no test): handles are '@', array access is 1-based, and a
rem quote inside a string is the language's doubled quote -- but none
rem is needed here because the strings hold no quotes.
rem ---------------------------------------------------------------

test_case("jsonlit/array of numbers")
a@ = [1, 2, 3, 4, 5]
assert_true(json_isarr(a@), "it is an array")
assert_eq(json_len(a@), 5, "five elements")
assert_eq(json_itemn(a@, 1), 1, "the first is 1 (base-1)")
assert_eq(json_itemn(a@, 5), 5, "and the last is 5")

test_case("jsonlit/array of strings")
names@ = ["Alice", "Bob", "Carol"]
assert_eq(json_len(names@), 3, "three names")
assert_eq(json_items$(names@, 1), "Alice", "the first")
assert_eq(json_items$(names@, 3), "Carol", "the last")

test_case("jsonlit/mixed types")
mixed@ = [10, "text", 3.14]
assert_eq(json_itemn(mixed@, 1), 10, "a number")
assert_eq(json_items$(mixed@, 2), "text", "a string")
assert_near(json_itemn(mixed@, 3), 3.14, 0.0001, "and a float")

test_case("jsonlit/values from variables")
name$ = "John"
age = 30
data@ = [name$, age]
assert_eq(json_items$(data@, 1), "John", "a string variable")
assert_eq(json_itemn(data@, 2), 30, "and a number variable")

test_case("jsonlit/expressions as values")
x = 5
calc@ = [x + 1, x * 2, "n=" + stri$(x)]
assert_eq(json_itemn(calc@, 1), 6, "an arithmetic expression")
assert_eq(json_itemn(calc@, 2), 10, "another")
assert_eq(json_items$(calc@, 3), "n=5", "and a string expression")

test_case("jsonlit/booleans and null")
flags@ = [true, false, null]
assert_eq(json_len(flags@), 3, "three flags")
assert_true(json_itemb(flags@, 1), "true reads back")
assert_false(json_itemb(flags@, 2), "false reads back")
assert_true(json_isnull(json_item@(flags@, 3)), "and null is a null")

test_case("jsonlit/nested arrays")
matrix@ = [[1, 2], [3, 4]]
assert_eq(json_len(matrix@), 2, "two rows")
row@ = json_item@(matrix@, 1)
assert_eq(json_itemn(row@, 1), 1, "first row, first element")
assert_eq(json_itemn(row@, 2), 2, "first row, second")
row2@ = json_item@(matrix@, 2)
assert_eq(json_itemn(row2@, 2), 4, "second row, second")

test_case("jsonlit/simple object")
person@ = {"name": "John", "age": 30}
assert_true(json_isobj(person@), "it is an object")
assert_eq(json_gets$(person@, "name"), "John", "the name")
assert_eq(json_getn(person@, "age"), 30, "the age")
assert_eq(json_count(person@), 2, "two keys")

test_case("jsonlit/object values from variables")
userName$ = "Alice"
userAge = 25
user@ = {"name": userName$, "age": userAge}
assert_eq(json_gets$(user@, "name"), "Alice", "a string variable")
assert_eq(json_getn(user@, "age"), 25, "and a number variable")

test_case("jsonlit/nested object walked by path")
d@ = {"user": {"name": "John", "email": "john@example.com"}}
assert_eq(json_paths$(d@, "user.name"), "John", "a path walks in")
assert_eq(json_paths$(d@, "user.email"), "john@example.com", "to the email too")

test_case("jsonlit/object holding an array")
record@ = {"name": "John", "scores": [95, 87, 92]}
scores@ = json_get@(record@, "scores")
assert_eq(json_len(scores@), 3, "three scores")
assert_eq(json_itemn(scores@, 1), 95, "the first score")
assert_eq(json_itemn(scores@, 3), 92, "and the last")

test_case("jsonlit/array of objects")
users@ = [{"name": "Alice"}, {"name": "Bob"}]
assert_eq(json_len(users@), 2, "two users")
u1@ = json_item@(users@, 1)
assert_eq(json_gets$(u1@, "name"), "Alice", "the first user")
u2@ = json_item@(users@, 2)
assert_eq(json_gets$(u2@, "name"), "Bob", "the second")

test_case("jsonlit/multi-line nested structure")
big@ = {
  "users": [
    {"name": "Alice", "score": 100},
    {"name": "Bob", "score": 85}
  ]
}
list@ = json_get@(big@, "users")
assert_eq(json_len(list@), 2, "two users in the list")
first@ = json_item@(list@, 1)
assert_eq(json_gets$(first@, "name"), "Alice", "the first user's name")
assert_eq(json_getn(first@, "score"), 100, "and the first user's score")
second@ = json_item@(list@, 2)
assert_eq(json_getn(second@, "score"), 85, "the second user's score")
