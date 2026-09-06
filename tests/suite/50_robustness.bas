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

test_case("num/an out-of-domain argument is the LIBRARY's error, not the RTL's")
rem acos(2) used to escape as FPC's own "Invalid floating point operation", which
rem the VM's net reported without naming the function or the value. A caller could
rem not tell which call in a line had gone wrong.
caught% = 0
on error goto dom1
x = acos(2)
goto after_dom1
dom1:
caught% = 1
resume next
after_dom1:
on error goto 0
assert_eq(caught%, 1, "acos(2) is an error")
assert_true(instr(errmsg$(), "acos") > 0, "and the message names the function")
assert_true(instr(errmsg$(), "domain") > 0, "and says what is wrong")

caught% = 0
on error goto dom2
y = ln(0)
goto after_dom2
dom2:
caught% = 1
resume next
after_dom2:
on error goto 0
assert_eq(caught%, 1, "ln(0) too")
assert_near(asin(0.5), 0.5235987756, 0.000001, "and the in-domain cases are unchanged")
assert_near(ln(1), 0, 0.000001, "ln(1) is still 0")

test_case("datetime/a month or year outside its range is refused, not guessed")
rem daysinamonth(2024, 13) indexed the RTL's month table out of bounds and answered
rem 65450 as a clean success -- err() was 0 and the program carried on with it.
caught% = 0
on error goto dt1
d% = daysinamonth(2024, 13)
goto after_dt1
dt1:
caught% = 1
resume next
after_dt1:
on error goto 0
assert_eq(caught%, 1, "month 13 is an error rather than a number")
assert_eq(daysinamonth(2024, 2), 29, "and February 2024 still has 29 days")
assert_eq(daysinamonth(2023, 2), 28, "and 2023 has 28")

caught% = 0
on error goto dt2
w% = weeksinayear(0)
goto after_dt2
dt2:
caught% = 1
resume next
after_dt2:
on error goto 0
assert_eq(caught%, 1, "year 0 is refused")
assert_eq(weeksinayear(2024), 52, "and a real year answers")

test_case("datetime/a date that does not exist is refused, not invented")
rem encodedate takes three separate numbers, so it is in the same family as
rem daysinamonth above: the parts are checked against each other before the RTL
rem sees them. TryEncodeDate takes Word, so the year is checked as an INTEGER
rem first -- 65537 would otherwise arrive as 1 and encode a real date in year 1.
caught% = 0
on error goto ed1
b1 = encodedate(2023, 2, 29)
goto after_ed1
ed1:
caught% = 1
resume next
after_ed1:
on error goto 0
assert_eq(caught%, 1, "29 February of a common year is an error")
assert_true(instr(errmsg$(), "encodedate") > 0, "and the message names the function")
assert_true(instr(errmsg$(), "28") > 0, "and says how long that month really is")

caught% = 0
on error goto ed2
b2 = encodedate(65537, 1, 1)
goto after_ed2
ed2:
caught% = 1
resume next
after_ed2:
on error goto 0
assert_eq(caught%, 1, "a year past 65535 is refused rather than wrapping into Word")
assert_eq(datetostr$(encodedate(2023, 2, 28)), "2023-02-28", "and the day before is fine")

test_case("datetime/a step off the end of the calendar is refused")
rem incyear RAISED here, aborting the program with the RTL's own words --
rem `Invalid date/timestamp : "10000/06/15 00:00:00,000"`. incmonth was worse:
rem its re-encode answers 0 without a word, so the step came back as 1899-12-30,
rem a plausible date that is silently wrong. Both are now refused in advance.
caught% = 0
on error goto st1
s1 = incyear(encodedate(9999, 6, 15), 1)
goto after_st1
st1:
caught% = 1
resume next
after_st1:
on error goto 0
assert_eq(caught%, 1, "a year past 9999 is an error, not an abort")

caught% = 0
on error goto st2
s2 = incmonth(encodedate(9999, 6, 15), 12)
goto after_st2
st2:
caught% = 1
resume next
after_st2:
on error goto 0
assert_eq(caught%, 1, "and neither is it 1899-12-30")
assert_eq(datetostr$(incmonth(encodedate(9999, 6, 15), 6)), "9999-12-15", "six months still fits")

caught% = 0
on error goto st3
s3 = incmonth(encodedate(1, 6, 15), -6)
goto after_st3
st3:
caught% = 1
resume next
after_st3:
on error goto 0
assert_eq(caught%, 1, "stepping back off the front is refused too")
assert_eq(datetostr$(incmonth(encodedate(1, 6, 15), -5)), "0001-01-15", "and five months back still fits")

test_case("datetime/a step FROM a number that is not a date is refused")
rem Checking only the target year was not enough, and failed in the exact way it
rem was written to prevent. DecodeDate answers year 0 / month 0 / day 0 for any
rem number at or below -693594 instead of refusing it, so the month accumulator
rem started from a fictitious year 0 and landed inside 1..9999 for every step of
rem 13 or more. incmonth(x, 12) was refused while incmonth(x, 13) came back as
rem 1899-12-30 -- non-monotonic, and silently wrong. incyear had the same hole and
rem aborted with the RTL's own words, `Invalid date/timestamp : "0001/00/00"`.
rem Such a number is easy to hold: incday has no range check, so one step back
rem from the first representable day produces it.
below = incday(encodedate(1, 1, 1), -1)
caught% = 0
on error goto sf1
f1 = incmonth(below, 13)
goto after_sf1
sf1:
caught% = 1
resume next
after_sf1:
on error goto 0
assert_eq(caught%, 1, "thirteen months from a non-date is refused, not answered")
assert_true(instr(errmsg$(), "incmonth") > 0, "and the message names the function")

caught% = 0
on error goto sf2
f2 = incyear(below, 1)
goto after_sf2
sf2:
caught% = 1
resume next
after_sf2:
on error goto 0
assert_eq(caught%, 1, "and so is a year from one")
assert_true(instr(errmsg$(), "incyear") > 0, "with this library's words, not the RTL's")
assert_true(instr(errmsg$(), "Invalid date") = 0, "the RTL message never reaches the program")

rem The exact boundaries still work, including a time of day on the last day.
assert_eq(datetostr$(incmonth(encodedate(1, 1, 1), 0)), "0001-01-01", "the first day is inside")
assert_eq(datetostr$(incmonth(encodedate(9999, 12, 31), 0)), "9999-12-31", "and the last")
assert_eq(datetimetostr$(incmonth(encodedate(9999, 12, 31) + 0.5, 0)), "9999-12-31 12:00:00", "noon on the last day is still a date")

test_case("registry/an absurdly wide call is refused at once, not searched for")
rem Overload resolution enumerates 2^k combinations of int-widening, which is
rem nothing for the six-argument signatures this registry holds and 33 million for a
rem call with 25 integer arguments -- inside ONE opcode, so the step budget never
rem got a chance to stop it. Nothing is registered that wide, so nothing can match:
rem the widest registered arity turns that into an O(1) answer.
wide% = 0
on error goto hw
z = no_such_function_at_all(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25)
goto after_wide
hw:
wide% = 1
resume next
after_wide:
on error goto 0
assert_eq(wide%, 1, "reported as an unknown function")
assert_eq(err(), 4, "with the unknown-function code")
assert_eq(max(3, 7), 7, "and ordinary resolution still works")
assert_eq(instr("hello", "l", 2), 3, "including the widened-int overloads")
