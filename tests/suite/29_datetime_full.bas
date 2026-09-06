rem ---------------------------------------------------------------
rem DateTimeLib, second half. 20_datetime.bas covers the calendar
rem parts; check-coverage.py reported the arithmetic, the spans, the
rem differences and the clock still at 36/66.
rem
rem The map for this file came from Examples/, where the applets call
rem these in earnest and assert almost nothing. What is added here is
rem the assertion.
rem
rem Nothing asserts the wall clock. now(), date() and time() answer
rem whatever the machine says, so what is checked is the relationship
rem between them, which holds on any machine at any moment.
rem ---------------------------------------------------------------

test_case("datetime/clock")
rem A date is a whole number of days and a time is the fraction after
rem the point, so the two halves of now() have to add back up to it.
n = now()
assert_true(n, "now answers a moment")

d = date()
t = time()
assert_eq(d, int(d), "date is a whole number of days")
if t < 1 then frac_ok = 1
assert_true(frac_ok, "and time is the fraction under one day")

assert_true(len(date$()), "date$ renders the date")
assert_true(len(time$()), "time$ renders the time")
assert_true(len(datetime$()), "datetime$ renders both")

g = gettime()
assert_true(g, "gettime answers a moment too")

test_case("datetime/render-and-parse")
rem A fixed moment, so the round trip is about the functions and not
rem about the clock. 2020-06-15 is a Monday, which matters later.
fixed = strtodate("2020-06-15")
assert_true(fixed, "strtodate reads a date")
assert_eq(yearof(fixed), 2020, "the year survives")
assert_eq(monthof(fixed), 6, "the month")
assert_eq(dayof(fixed), 15, "and the day")

rendered$ = datetostr$(fixed)
assert_true(len(rendered$), "datetostr$ renders it")
assert_eq(strtodate(rendered$), fixed, "and strtodate reads back what was rendered")

full$ = datetimetostr$(fixed)
assert_true(len(full$), "datetimetostr$ renders date and time")
assert_near(strtodatetime(full$), fixed, 0.001, "and strtodatetime reads it back")

clock = strtotime("14:30:00")
assert_true(clock, "strtotime reads a time")
assert_eq(hourof(clock), 14, "with the hour")
assert_eq(minuteof(clock), 30, "and the minute")
assert_true(len(timetostr$(clock)), "timetostr$ renders it")

test_case("datetime/format")
rem formatdatetime$ takes the pattern first and the value second, which
rem is the opposite of what a reader of Delphi expects.
assert_eq(formatdatetime$("yyyy", fixed), "2020", "a year pattern")
assert_eq(formatdatetime$("yyyy-mm-dd", fixed), "2020-06-15", "a full date pattern")

test_case("datetime/increments")
rem Each inc* moves by its own unit and nothing else. A day is 1, an
rem hour is 1/24, and the smaller ones follow from there.
assert_eq(incday(fixed, 1) - fixed, 1, "incday moves a whole day")
assert_near(inchour(fixed, 24) - fixed, 1, 0.0001, "twenty-four hours make one")
assert_near(incminute(fixed, 60) - fixed, inchour(fixed, 1) - fixed, 0.0001, "sixty minutes make an hour")
assert_near(incsecond(fixed, 60) - fixed, incminute(fixed, 1) - fixed, 0.0001, "sixty seconds make a minute")
assert_near(incmillisecond(fixed, 1000) - fixed, incsecond(fixed, 1) - fixed, 0.0001, "a thousand milliseconds make a second")

assert_eq(incweek(fixed, 1) - fixed, 7, "incweek moves seven days")
assert_eq(yearof(incyear(fixed, 1)), 2021, "incyear moves the year")
assert_eq(monthof(incyear(fixed, 1)), 6, "and leaves the month alone")

rem Negative moves go backwards, which is the only way to subtract.
assert_eq(incday(fixed, -1), fixed - 1, "a negative increment goes back")

test_case("datetime/incmonth clamps onto a shorter month")
rem The one increment that is not arithmetic on the number. A day is 1 and a
rem week is 7; a month is 28, 29, 30 or 31, so the date is taken apart, the
rem month moved, and the DAY CLAMPED to the length of where it lands.
jan31 = encodedate(2026, 1, 31)
assert_eq(datetostr$(incmonth(jan31, 1)), "2026-02-28", "31 January plus a month is 28 February")
assert_eq(datetostr$(incmonth(encodedate(2024, 1, 31), 1)), "2024-02-29", "and the 29th in a leap year")
assert_eq(datetostr$(incmonth(encodedate(2026, 3, 31), -1)), "2026-02-28", "backwards clamps the same way")
assert_eq(datetostr$(incmonth(jan31, 0)), "2026-01-31", "a step of nothing changes nothing")

rem A month that needs no clamping keeps its day, and the step crosses years.
assert_eq(datetostr$(incmonth(encodedate(2026, 12, 15), 1)), "2027-01-15", "December plus one is January of the next year")
assert_eq(datetostr$(incmonth(encodedate(2026, 1, 15), -1)), "2025-12-15", "and January minus one is the December before")
assert_eq(datetostr$(incmonth(encodedate(2026, 5, 17), 25)), "2028-06-17", "twenty-five months is two years and one")

rem The time of day is carried through: only the date part moves.
noon = encodedate(2026, 1, 31) + 0.5
assert_eq(datetimetostr$(incmonth(noon, 1)), "2026-02-28 12:00:00", "the time of day survives the clamp")

test_case("datetime/encodedate builds a date from three numbers")
rem Until 2026-09-06 there was no constructor at all: a program holding a year,
rem a month and a day had to assemble ISO text and parse it, which asked a
rem parser a question about arithmetic.
assert_eq(datetostr$(encodedate(2020, 6, 15)), "2020-06-15", "three numbers make the date")
assert_eq(encodedate(2020, 6, 15), fixed, "and it is the same number strtodate answers")
assert_eq(datetostr$(encodedate(2024, 2, 29)), "2024-02-29", "a real leap day is accepted")
assert_eq(datetostr$(encodedate(1, 1, 1)), "0001-01-01", "the first representable day")
assert_eq(datetostr$(encodedate(9999, 12, 31)), "9999-12-31", "and the last")

rem The round trip that says the parts really are the parts.
built = encodedate(2026, 9, 6)
assert_eq(yearof(built), 2026, "yearof gives the year back")
assert_eq(monthof(built), 9, "monthof the month")
assert_eq(dayof(built), 6, "dayof the day")
assert_eq(hourof(built), 0, "and a date built from three numbers is midnight")

test_case("datetime/differences")
rem The *between family answers whole units elapsed, counting down.
later = incday(fixed, 400)
assert_eq(daysbetween(fixed, later), 400, "daysbetween counts days")
assert_eq(weeksbetween(fixed, later), 57, "weeksbetween counts whole weeks")
assert_eq(monthsbetween(fixed, later), 13, "monthsbetween counts whole months")
assert_eq(yearsbetween(fixed, later), 1, "yearsbetween counts whole years")

hourslater = inchour(fixed, 50)
assert_eq(hoursbetween(fixed, hourslater), 50, "hoursbetween counts hours")
assert_eq(minutesbetween(fixed, inchour(fixed, 2)), 120, "minutesbetween counts minutes")
assert_eq(secondsbetween(fixed, incminute(fixed, 3)), 180, "secondsbetween counts seconds")
assert_eq(millisecondsbetween(fixed, incsecond(fixed, 2)), 2000, "millisecondsbetween counts milliseconds")

test_case("datetime/spans")
rem A span is the same distance as a fraction rather than a whole
rem count, so half a day is 0.5 days and 12 hours, not 0 and 12.
half = inchour(fixed, 12)
assert_near(dayspan(fixed, half), 0.5, 0.0001, "dayspan answers a fraction of a day")
assert_near(hourspan(fixed, half), 12, 0.0001, "hourspan answers twelve hours")
assert_near(minutespan(fixed, half), 720, 0.01, "minutespan answers seven hundred and twenty minutes")
assert_near(secondspan(fixed, half), 43200, 1, "secondspan follows")
assert_near(millisecondspan(fixed, half), 43200000, 1000, "and millisecondspan")

assert_near(weekspan(fixed, incday(fixed, 7)), 1, 0.0001, "weekspan answers one week")
assert_near(monthspan(fixed, incyear(fixed, 1)), 12, 0.2, "monthspan answers twelve months in a year")
assert_near(yearspan(fixed, incyear(fixed, 1)), 1, 0.01, "and yearspan answers one")

test_case("datetime/parts")
rem millisecondof completes the of* family the other tests already use.
stamp = incmillisecond(strtotime("10:20:30"), 400)
assert_eq(millisecondof(stamp), 400, "millisecondof reads the milliseconds")
assert_eq(secondof(stamp), 30, "beside the seconds")

test_case("datetime/year-lengths")
rem 2020 is a leap year and 2021 is not, which is the whole difference
rem these two are for.
assert_eq(daysinyear(strtodate("2020-01-01")), 366, "a leap year has 366 days")
assert_eq(daysinyear(strtodate("2021-01-01")), 365, "and a common year 365")

rem A year spans 52 or 53 ISO weeks depending on where its days fall.
w2020 = weeksinyear(strtodate("2020-01-01"))
if w2020 >= 52 then weeks_ok = 1
assert_true(weeks_ok, "weeksinyear answers 52 or 53")
if w2020 <= 53 then weeks_ok2 = 1
assert_true(weeks_ok2, "and never more")
assert_eq(weekof(fixed), 25, "weekof answers the ISO week 2020-06-15 falls in")

test_case("datetime/a date before 1900 is the same day as itself")
rem A TDateTime before 1899-12-30 is negative, and FPC spells such a value
rem sign-and-magnitude: noon on 1850-06-15 is -18095.5 where midnight that day
rem is -18095, so the time of day moves the number DOWN. Two functions did
rem arithmetic on the number instead of reading its parts, and got it backwards:
rem issameday said a timestamp was not the same day as ITSELF (and answered
rem differently when the arguments were swapped), and dayoftheyear was one too
rem low for any pre-1900 time of day.
old_noon = strtodatetime("1850-06-15 12:00:00")
old_mid = strtodate("1850-06-15")
assert_eq(issameday(old_noon, old_noon), 1, "a moment is the same day as itself")
assert_eq(issameday(old_noon, old_mid), 1, "noon and midnight are one day")
assert_eq(issameday(old_mid, old_noon), 1, "and the answer does not depend on the order")
assert_eq(issameday(old_mid, strtodate("1850-06-16")), 0, "two days are not one")
assert_eq(dayoftheyear(old_mid), 166, "the 166th day of 1850")
assert_eq(dayoftheyear(old_noon), 166, "and the time of day does not change which day it is")

rem the modern side, which was always right and must stay right
new_noon = strtodatetime("2024-06-15 12:00:00")
assert_eq(issameday(new_noon, strtodate("2024-06-15")), 1, "the same holds after 1900")
assert_eq(dayoftheyear(new_noon), 167, "2024 is a leap year, so the 167th")
assert_eq(dayoftheyear(strtodate("2024-01-01")), 1, "the first day is 1")
assert_eq(dayoftheyear(strtodate("2024-12-31")), 366, "and a leap year ends at 366")
assert_eq(dayoftheyear(strtodate("2023-12-31")), 365, "a common year at 365")
