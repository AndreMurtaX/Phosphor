rem ---------------------------------------------------------------
rem  JSON, ROUND 11 (2026-10-11): AN int% HANDED TO A NUMBER WRITER
rem  WAS WIDENED TO A DOUBLE FIRST.
rem
rem  json_setn@, json_pushn@, json_number@, json_setval@,
rem  json_pushval@ and the {..} / [..] literals all built the node
rem  from AsDouble of the value, so an int% id past 2^53 lost its last
rem  digits -- 9007199254740993 was written 9007199254740992 -- and
rem  High(Int64), whose nearest Double 2^63 is outside the range,
rem  became a FLOAT node, 9.2233720368547758E+018. json_parse@ of the
rem  same digits keeps them all. Every writer now goes through one
rem  door that builds the integer node a parse builds.
rem
rem  EXPECTED VALUES, independent of the engine: an int% is exact, so
rem  the text of each document is the int%'s own decimal digits,
rem  written out below by hand; and the same text through json_parse@
rem  -- a second path, the reader -- must stringify identically.
rem  9007199254740993 is 2^53 + 1, the first integer a Double cannot
rem  hold; 9223372036854775807 is 2^63 - 1 and -9223372036854775808
rem  is -2^63, the two ends of int%.
rem ---------------------------------------------------------------

id% = 9007199254740993
mx% = 9223372036854775807
mn% = -9223372036854775807 - 1

test_case("json int%/every writer keeps every digit")
o@ = json_object@()
json_setn@(o@, "id", id%)
assert_eq(json_stringify$(o@), "{""id"":9007199254740993}", "json_setn@")
o@ = json_object@()
json_setval@(o@, "id", id%)
assert_eq(json_stringify$(o@), "{""id"":9007199254740993}", "json_setval@")
assert_eq(json_stringify$({"id": id%}), "{""id"":9007199254740993}", "an object literal")
a@ = json_array@()
json_pushn@(a@, id%)
json_pushval@(a@, id%)
assert_eq(json_stringify$(a@), "[9007199254740993, 9007199254740993]", "json_pushn@ and json_pushval@")
assert_eq(json_stringify$([id%]), "[9007199254740993]", "an array literal")
assert_eq(json_stringify$(json_number@(id%)), "9007199254740993", "json_number@")

test_case("json int%/the ends of the range stay integers")
o@ = json_object@()
json_setn@(o@, "max", mx%)
json_setn@(o@, "min", mn%)
assert_eq(json_stringify$(o@), "{""max"":9223372036854775807,""min"":-9223372036854775808}", "High and Low of int%")
assert_eq(json_stringify$({"max": mx%, "min": mn%}), json_stringify$(json_parse@("{""max"":9223372036854775807, ""min"":-9223372036854775808}")), "a literal stringifies as the parse of its digits")

test_case("json int%/built and parsed agree")
o@ = json_object@()
json_setn@(o@, "id", id%)
p@ = json_parse@("{""id"":9007199254740993}")
assert_eq(json_stringify$(o@), json_stringify$(p@), "the same text")
assert_eq(json_stringify$(json_parse@(json_stringify$(o@))), "{""id"":9007199254740993}", "and it reads back")
assert_true(json_getn(o@, "id") = json_getn(p@, "id"), "json_getn answers the same for both")

test_case("json int%/a Double is unchanged")
o@ = json_object@()
json_setn@(o@, "d", 2.5)
json_setn@(o@, "w", 3000000000.0)
json_setn@(o@, "z", val("-0"))
assert_eq(json_stringify$(o@), json_stringify$(json_parse@("{""d"":2.5, ""w"":3000000000, ""z"":-0}")), "a fraction, a whole Double and -0 as before")
