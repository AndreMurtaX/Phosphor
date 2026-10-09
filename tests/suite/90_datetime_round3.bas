rem ---------------------------------------------------------------
rem A DATE FAR OUTSIDE THE CALENDAR IS STILL A NUMBER, AND TEXT IS
rem THE SAME ON EVERY MACHINE (2026-10-09, round 3 of the adversarial
rem loop).
rem
rem docs/libraries/date-time.md promises that incday and the finer
rem increments answer "the plain sum, however large the step", and that
rem every function outside its named list of refusals ALWAYS answers.
rem Past about 1.07e11 days that was false: hourof, minuteof, secondof,
rem millisecondof, isam, ispm, timetostr$ and formatdatetime$ raised the
rem RTL's own "Invalid floating point operation" (DateTimeToTimeStamp
rem multiplies the whole number by 86400000 into an integer), past 1e12
rem days secondsbetween did too, and past 2^63 days dayofweek,
rem dayoftheweek and the *between distances (Trunc into an Int64).
rem daysbetween, weeksbetween, monthsbetween and yearsbetween narrowed to
rem a 32-bit Integer, so three billion days answered -1294967296 -- a
rem NEGATIVE distance from functions the page says never answer one.
rem
rem The time of day is now read off the number itself (its fraction,
rem rounded half up to the millisecond, as Canon reads it), the weekday off
rem the day number by exact arithmetic mod 7, and a whole count that no
rem Int64 holds answers the Double it is. formatdatetime$ renders a DATE,
rem so it now refuses a number outside 0001-01-01..9999-12-31 as
rem datetostr$ and datetimetostr$ do -- below the range it read the RTL's
rem month-name table at index 0 ("mmm" printed "hh:nn:ss").
rem
rem And formatdatetime$ is this library's own now, so its text no longer
rem follows the machine: "ampm" printed the locale's designators, which a
rem pt-BR Windows leaves EMPTY ("6:00 " for both 06:00 and 18:00);
rem "e" and "g" were Windows-only era specifiers that SKIPPED a run of
rem letters ("week" printed "WeK" on Windows, "WEEK" on Linux); a lone
rem "a" raised the RTL's "Illegal character in format string"; and the
rem answer was cut at 255 bytes. datetimetostr$ dropped the time for any
rem instant in the first SECOND of a day, where the page says only an
rem exact midnight renders as the date alone.
rem
rem EVERY EXPECTED VALUE IS DERIVED BESIDE ITS ASSERTION: weekdays from
rem dayofweek = 1 + ((N - 1) mod 7) on the integer day N (1899-12-30, day
rem 0, was a Saturday: 7), ISO weekday = ((dow + 5) mod 7) + 1, times
rem from the fraction times 86400000, and distances from the arithmetic
rem written out. Python's float arithmetic is IEEE double, so where a
rem value is a rounded quotient the Python expression is given.
rem ---------------------------------------------------------------

test_case("datetime-r3/the time of day of a number far past the calendar")
rem incday keeps the time of day: 0.75 is 18:00, and 2e11 + 0.75 is
rem exactly representable (2e11 < 2^38, so the grid is 2^-15 of a day).
d = incday(0.75, 2e11)
assert_eq(d, 200000000000.75, "incday answers the plain sum")
assert_eq(hourof(d), 18, "hourof reads the fraction: 0.75 * 24")
assert_eq(minuteof(d), 0, "minuteof")
assert_eq(secondof(d), 0, "secondof")
assert_eq(millisecondof(d), 0, "millisecondof")
assert_eq(isam(d), 0, "isam: 18 is not under 12")
assert_eq(ispm(d), 1, "ispm")
assert_eq(timetostr$(d), "18:00:00", "timetostr$")
rem Before the epoch the time of day is the absolute value of the fraction.
d = incday(0.75, -2e11)
assert_eq(d, -200000000000.75, "the negative plain sum")
assert_eq(hourof(d), 18, "hourof, below the calendar")
assert_eq(timetostr$(d), "18:00:00", "timetostr$, below the calendar")
rem 2^-15 of a day = 86400000 / 32768 ms = 2636.71875 ms, half up 2637:
rem 00:00:02.637.
d = incday(1 / 32768, 2e11)
assert_eq(secondof(d), 2, "a fraction on the 2^-15 grid: second 2")
assert_eq(millisecondof(d), 637, "and millisecond 637 (2636.71875 rounded half up)")
rem 1e15 + 0.5 is exact (the grid at 1e15 is 1/8 of a day): noon.
assert_eq(hourof(incday(0.5, 1e15)), 12, "1e15 days and a half: noon")
rem Past 2^52 a Double holds no fraction: every such number is a midnight.
assert_eq(hourof(incday(0, 1e300)), 0, "1e300 has no fraction: hour 0")
assert_eq(timetostr$(incday(0, -1e300)), "00:00:00", "nor has -1e300")

test_case("datetime-r3/the weekday of a day number no Int64 holds")
rem dow(N) = 1 + ((N - 1) mod 7), with mod taken into 0..6:
rem   10^19 mod 7 = 3, so dow = 1 + 2 = 3, ISO ((3+5) mod 7)+1 = 2;
rem   -10^19 mod 7 = 4, dow = 1 + 3 = 4, ISO 3.
rem 1e300 as a Double is one exact integer N; Python: 1 + ((int(1e300)-1) % 7)
rem = 1, ISO 7; and for -1e300, 6 and ISO 5.
assert_eq(dayofweek(0), 7, "the epoch, 1899-12-30, was a Saturday")
assert_eq(dayofweek(incday(0, 1e19)), 3, "day 1e19")
assert_eq(dayoftheweek(incday(0, 1e19)), 2, "day 1e19, ISO")
assert_eq(dayofweek(incday(0, -1e19)), 4, "day -1e19")
assert_eq(dayoftheweek(incday(0, -1e19)), 3, "day -1e19, ISO")
assert_eq(dayofweek(incday(0, 1e300)), 1, "day 1e300")
assert_eq(dayoftheweek(incday(0, 1e300)), 7, "day 1e300, ISO")
assert_eq(dayofweek(incday(0, -1e300)), 6, "day -1e300")
assert_eq(dayoftheweek(incday(0, -1e300)), 5, "day -1e300, ISO")
rem 2^52 + 1 days: Python 1 + ((4503599627370497 - 1) % 7) = 3.
assert_eq(dayofweek(incday(0, 4503599627370497)), 3, "just past 2^52, where the fraction ends")

test_case("datetime-r3/a distance is a non-negative whole count, however large")
rem Three billion days: 3e9 div 7 = 428571428; 3e9 / 30.4375 = 98562628.33;
rem 3e9 / 365.25 = 8213552.36.
d = incday(0, 3e9)
assert_eq(daysbetween(d, 0), 3000000000, "three billion days, not -1294967296")
assert_eq(weeksbetween(d, 0), 428571428, "weeks")
assert_eq(monthsbetween(d, 0), 98562628, "approximate months")
assert_eq(yearsbetween(d, 0), 8213552, "approximate years")
assert_eq(daysbetween(0, d), 3000000000, "and the order of the arguments does not matter")
rem 1e15 days: 2.4e16 hours (an Int64); 8.64e19 seconds is past 2^63
rem (9.22e18), so it is the Double 8.64e19.
d = incday(0, 1e15)
assert_eq(hoursbetween(d, 0), 24000000000000000, "1e15 days in hours")
assert_eq(secondsbetween(d, 0), 86400000000000000000, "and in seconds, past 2^63")
rem 2e11 days * 86400000 = 1.728e19 ms = 27 * 5^16 * 2^22, exact.
assert_eq(millisecondsbetween(incday(0, 2e11), 0), 17280000000000000000, "2e11 days in milliseconds")
rem 1e19 days: past 2^63 itself. Weeks: Python math.trunc(1e19 / 7) =
rem 1428571428571428608, the double nearest 1e19 / 7.
d = incday(0, 1e19)
assert_eq(daysbetween(d, 0), 1e19, "1e19 days")
assert_eq(weeksbetween(d, 0), 1428571428571428608, "1e19 days in weeks")
assert_eq(hoursbetween(d, 0), 2.4e20, "1e19 days in hours")

test_case("datetime-r3/every function outside the refusal list answers")
rem The page's promise, crossed with numbers at every scale where a
rem conversion inside the RTL used to overflow: around 1.07e11 days
rem (milliseconds past 2^63), 1e12 (seconds), 2^63, and the ends of the
rem Double range. Each call is made under a trap, the trap is disarmed,
rem and only then is the count of raised errors asserted.
vals$ = "2e11|-2e11|1e12|-1e12|1e15|-1e15|1e19|-1e19|1e300|-1e300|9223372036854775807|4503599627370496.5"
nerr = 0
calls = 0
firsterr$ = ""
for i = 1 to 12
  v = incday(0.75, val(word$(vals$, i, "|")))
  on error goto raised
  calls = calls + 1
  r = yearof(v) + monthof(v) + dayof(v) + dayofthemonth(v) + monthoftheyear(v)
  calls = calls + 1
  r = dayofweek(v) + dayoftheweek(v) + isinleapyear(v) + issameday(v, v) + istoday(v)
  calls = calls + 1
  r = hourof(v) + minuteof(v) + secondof(v) + millisecondof(v) + isam(v) + ispm(v)
  calls = calls + 1
  t$ = timetostr$(v)
  calls = calls + 1
  r = incday(v, 1) + incweek(v, 1) + inchour(v, 1) + incminute(v, 1) + incsecond(v, 1) + incmillisecond(v, 1)
  calls = calls + 1
  r = daysbetween(v, 0) + weeksbetween(v, 0) + monthsbetween(v, 0) + yearsbetween(v, 0)
  calls = calls + 1
  r = hoursbetween(v, 0) + minutesbetween(v, 0) + secondsbetween(v, 0) + millisecondsbetween(v, 0)
  calls = calls + 1
  r = dayspan(v, 0) + weekspan(v, 0) + monthspan(v, 0) + yearspan(v, 0) + hourspan(v, 0) + minutespan(v, 0) + secondspan(v, 0) + millisecondspan(v, 0)
  on error goto 0
next
assert_eq(calls, 96, "every group was reached")
assert_eq(nerr, 0, "and none raised: " + firsterr$)
rem A distance too large to be a number at all is refused by the engine's
rem finiteness gate, as incweek(d, 1e308) is: 2e308 days is no Double.
fin$ = ""
on error goto caught
x = hourspan(incday(0, 1e308), incday(0, -1e308))
on error goto 0
assert_true(instr(fin$, "finite") > 0, "a span past the largest Double is the engine's refusal")

test_case("datetime-r3/formatdatetime$ renders a date, and refuses a number that is none")
rem Below the calendar DecodeDate answered month 0, and "mmm" read the
rem RTL's name table one element before its start; above it, the date was
rem clamped to 9999-12-31 and reported as real -- or, past 1.07e11 days,
rem the RTL raised. datetostr$ and datetimetostr$ already refused both.
fin$ = ""
on error goto caught
f$ = formatdatetime$("mmm", -700000)
on error goto 0
assert_true(instr(fin$, "not a date in 0001-01-01..9999-12-31") > 0, "below the range: " + fin$)
fin$ = ""
on error goto caught
f$ = formatdatetime$("yyyy-mm-dd", incday(encodedate(9999, 12, 31), 1))
on error goto 0
assert_true(instr(fin$, "not a date in 0001-01-01..9999-12-31") > 0, "the day after 9999-12-31: " + fin$)
fin$ = ""
on error goto caught
f$ = formatdatetime$("hh:nn", incday(0.75, 2e11))
on error goto 0
assert_true(instr(fin$, "formatdatetime$") > 0, "and the refusal names the function: " + fin$)
rem The two ends of the range themselves still render.
assert_eq(formatdatetime$("yyyy-mm-dd hh:nn", encodedate(1, 1, 1)), "0001-01-01 00:00", "0001-01-01")
assert_eq(formatdatetime$("yyyy-mm-dd hh:nn", strtodatetime("9999-12-31 23:59")), "9999-12-31 23:59", "9999-12-31")

test_case("datetime-r3/formatdatetime$ text does not follow the machine")
rem 0.25 is 06:00 and 0.75 is 18:00. "ampm" prints AM or PM -- the RTL's
rem own built-in designators (rtl/objpas/sysutils/sysinth.inc), pinned as
rem the month and day names are.
assert_eq(formatdatetime$("h:nn ampm", 0.25), "6:00 AM", "06:00 is AM")
assert_eq(formatdatetime$("h:nn ampm", 0.75), "6:00 PM", "18:00 is PM")
assert_eq(formatdatetime$("hh:nn AMPM", 0.5), "12:00 PM", "noon is 12 PM")
assert_eq(formatdatetime$("hh:nn ampm", 0), "12:00 AM", "midnight is 12 AM")
rem am/pm and a/p print their own letters, case kept, as before.
assert_eq(formatdatetime$("h am/pm", 0.75), "6 pm", "am/pm")
assert_eq(formatdatetime$("h A/P", 0.25), "6 A", "A/P")
rem A letter that is no specifier prints as itself, upper-cased -- "e" and
rem "g" too, which on Windows were era specifiers that skipped the run.
assert_eq(formatdatetime$("week ww", 0), "WEEK WW", "e is a letter, not an era")
assert_eq(formatdatetime$("gg e", 0), "GG E", "and so is g")
assert_eq(formatdatetime$("a", 0.25), "A", "a lone a is a letter, not the RTL's error")
rem The answer is not cut at 255 bytes: "dd-" two hundred times is 600.
p$ = ""
for i = 1 to 200
  p$ = p$ + "dd-"
next
assert_eq(len(formatdatetime$(p$, encodedate(2020, 6, 15))), 600, "a long pattern renders whole")
assert_eq(left$(formatdatetime$(p$, encodedate(2020, 6, 15)), 6), "15-15-", "and renders what it says")

test_case("datetime-r3/only an exact midnight renders as the date alone")
m = strtodatetime("2020-06-15 00:00:00")
assert_eq(datetimetostr$(m), "2020-06-15", "an exact midnight is the date alone")
assert_eq(datetimetostr$(incmillisecond(m, 500)), "2020-06-15 00:00:00", "00:00:00.500 is not midnight")
assert_eq(datetimetostr$(incmillisecond(m, 1)), "2020-06-15 00:00:00", "nor is 00:00:00.001")
assert_eq(formatdatetime$("c", incmillisecond(m, 999)), "2020-06-15 00:00:00", "formatdatetime$ c is the same rule")
assert_eq(formatdatetime$("c", m), "2020-06-15", "and its midnight is the date alone")
assert_eq(datetimetostr$(incsecond(m, 1)), "2020-06-15 00:00:01", "a whole second on, as before")
end

raised:
nerr = nerr + 1
if firsterr$ = "" then firsterr$ = word$(vals$, i, "|") + " group " + str$(calls) + ": " + errmsg$()
resume next

caught:
fin$ = errmsg$()
resume next
