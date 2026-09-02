rem ---------------------------------------------------------------
rem Robustness: a library fault is a catchable error VALUE, never a
rem process crash, and byte/UTF-8 handling is exact. Every assertion
rem here pins a fix for a confirmed bug found in the library review.
rem ---------------------------------------------------------------

test_case("num/out-of-range Double->Int64 is a catchable overflow, not a crash")
caught% = 0
on error goto oflow
bad% = round(2 ^ 63)
goto after_round
oflow:
caught% = 1
resume next
after_round:
on error goto 0
assert_eq(caught%, 1, "round(2^63) raised a catchable overflow instead of killing the process")

test_case("str/string$ agrees with chr$ on non-ASCII (UTF-8, not a masked byte)")
assert_eq(string$(3, 233), chr$(233) + chr$(233) + chr$(233), "string$ repeats a 2-byte codepoint's UTF-8 encoding")
assert_eq(string$(2, 8364), chr$(8364) + chr$(8364), "and a 3-byte codepoint (the euro sign) too")

test_case("json/reading an off-type member returns a value, never crashes")
o@ = json_parse@("{\"txt\":\"hello\", \"numstr\":\"42\", \"n\":7}")
assert_eq(json_getn(o@, "numstr", -1), 42, "a numeric string coerces to its number")
assert_eq(json_getn(o@, "txt", -1), 0, "a non-numeric string reads as 0")
assert_eq(json_getn(o@, "absent", -1), -1, "a missing key still returns the default")
p@ = json_parse@("{\"nul\":null}")
assert_eq(json_gets$(p@, "nul"), "", "a null member reads as the empty string")

test_case("json/parsing empty input is an error, not a live nil handle")
badjson% = 0
on error goto onbad
q@ = json_parse@("")
goto after_json
onbad:
badjson% = 1
resume next
after_json:
on error goto 0
assert_eq(badjson%, 1, "json_parse of empty input reports an error")

test_case("strings/empty text is an empty list, not one empty line")
l@ = strings@()
assert_eq(strings_text(l@, ""), 0, "setting empty text yields count 0")
