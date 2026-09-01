rem ---------------------------------------------------------------
rem DateTimeLib, which had 66 registered functions and no test.
rem
rem The non-GUI libraries were at 29% coverage while the GUI ones
rem reached 87%, and this was the largest single gap in the tree.
rem
rem A TDateTime is a number -- days since 1899-12-30, with the time
rem in the fraction -- so every date here is written as its literal
rem rather than parsed from text. Parsing would make the test depend
rem on the machine's date format, and a suite that passes in one
rem locale and fails in another says nothing about the library.
rem
rem   45351 = 2024-02-29, a Thursday and a leap day
rem   45352 = 2024-03-01
rem   45358 = 2024-03-07
rem   45716 = 2025-02-28
rem   36526 = 2000-01-01, a Saturday
rem
rem The pairs worth their own assertions are the ones whose names do
rem not distinguish them: dayofweek counts from Sunday and
rem dayoftheweek from Monday, and daysinmonth takes a date while
rem daysinamonth takes a year and a month. Nothing in the tree said
rem so before this file.
rem ---------------------------------------------------------------

test_case("datetime/decomposing a leap day")
let leap = 45351
assert_eq(yearof(leap), 2024, "yearof")
assert_eq(monthof(leap), 2, "monthof")
assert_eq(dayof(leap), 29, "dayof")
assert_eq(dayofthemonth(leap), 29, "dayofthemonth agrees with dayof")
assert_eq(monthoftheyear(leap), 2, "monthoftheyear agrees with monthof")
assert_eq(dayoftheyear(leap), 60, "the 60th day of a leap year")

test_case("datetime/the two week-day bases")
rem 2024-02-29 was a Thursday. dayofweek is Delphi's, counting Sunday
rem as 1; dayoftheweek is ISO 8601, counting Monday as 1. The names
rem differ by three letters and the answers by one.
assert_eq(dayofweek(leap), 5, "dayofweek counts Sunday as 1")
assert_eq(dayoftheweek(leap), 4, "dayoftheweek counts Monday as 1")

test_case("datetime/leap years")
assert_eq(isinleapyear(leap), 1, "2024 is a leap year")
assert_eq(isinleapyear(36526), 1, "2000 is one too, by the 400 rule")
assert_eq(daysinayear(2024), 366, "and has 366 days")
assert_eq(daysinayear(2023), 365, "2023 does not")
assert_eq(daysinayear(1900), 365, "nor 1900, which the 100 rule excludes")

test_case("datetime/days in a month, two ways of asking")
assert_eq(daysinmonth(leap), 29, "daysinmonth takes a date")
assert_eq(daysinamonth(2024, 2), 29, "daysinamonth takes a year and a month")
assert_eq(daysinamonth(2023, 2), 28, "February 2023 is shorter")
assert_eq(daysinamonth(2024, 12), 31, "December is 31 either way")

test_case("datetime/the time lives in the fraction")
let noon = 45351.5
assert_eq(hourof(noon), 12, "half a day is noon")
assert_eq(minuteof(noon), 0, "on the hour")
assert_eq(secondof(noon), 0, "and the second")
assert_eq(isam(noon), 0, "noon is not morning")
assert_eq(ispm(noon), 1, "it is afternoon")
assert_eq(issameday(leap, 45351.75), 1, "the fraction does not change the day")

test_case("datetime/weeks")
assert_eq(weekoftheyear(leap), 9, "ISO week 9 of 2024")
assert_eq(weekof(leap), 9, "weekof answers the same")
assert_eq(weekofthemonth(leap), 5, "and it falls in the fifth week of February")
assert_eq(weeksinayear(2024), 52, "2024 has 52 ISO weeks")

test_case("datetime/incrementing across a boundary")
assert_eq(incday(leap, 1), 45352, "the day after 29 February is 1 March")
assert_eq(incweek(leap, 1), 45358, "a week later is 7 March")
rem A year after 29 February is 28 February: there is no 29th to land
rem on, and the library clamps rather than rolling into March.
assert_eq(incyear(leap, 1), 45716, "a year after a leap day clamps to the 28th")

test_case("datetime/distances")
assert_eq(daysbetween(leap, leap + 10), 10, "daysbetween counts whole days")
assert_eq(dayspan(leap, leap + 10), 10, "dayspan agrees for a whole number")
assert_eq(hoursbetween(leap, noon), 12, "half a day is twelve hours")
assert_eq(minutesbetween(leap, noon), 720, "and 720 minutes")
assert_eq(secondsbetween(leap, noon), 43200, "and 43200 seconds")

test_case("datetime/the clock answers, without saying what time it is")
rem now, today, time and date cannot be asserted against a value, so
rem what is claimed is the relation between them: today is now with
rem the fraction removed, and tomorrow is the day after.
let n = now()
let t = today()
assert_eq(issameday(n, t), 1, "today is the same day as now")
assert_eq(daysbetween(t, tomorrow()), 1, "tomorrow is one day on")
assert_eq(daysbetween(yesterday(), t), 1, "yesterday is one day back")
assert_eq(istoday(t), 1, "and today is today")
