rem ---------------------------------------------------------------
rem A REFUSAL NAMES WHAT THE PROGRAM WROTE, AN EMPTY PATTERN IS THE
rem ISO DATE, AND A LENGTH IS NOT A 32-BIT NUMBER (2026-10-09, round 4
rem of the adversarial loop).
rem
rem docs/libraries/date-time.md says daysinamonth, daysinayear,
rem weeksinayear and encodedate raise a catchable error "naming the
rem value". The guards were handed the argument AFTER ArgI32 had
rem narrowed it, and ArgI32 SATURATES: daysinamonth(1e10, 2) said
rem "2147483647 is not a year in 1..9999" and daysinayear(-1e300)
rem "-2147483648 is not a year" -- numbers the program never wrote. The
rem guards now narrow the argument themselves and spell the argument.
rem The string library's refusals that name an index (byteat, bytestr$,
rem a s$[[n]] or s$[n] write) did the same, and its position arguments
rem were clamped at 2^31 - 1, which is a wrong answer for character
rem 2^31 + 1 of a string that has one; they are read whole now.
rem
rem The same page says "An empty pattern gives the ISO date"; the code
rem rendered the RTL's "c" instead, which adds the time unless the
rem moment is an exact midnight.
rem
rem formatdatetime$ kept its write cursor in a 32-bit Integer, and past
rem 2^31 bytes of answer it wrapped negative and wrote 2 GiB before its
rem buffer ("cf" doubled 26 times: an access violation); len() of a
rem string of 2^31 bytes answered 1 (an Integer for-loop bound is
rem truncated). Those need gigabytes and are proved by a scratch run,
rem not here; what is here pins that the counting pass formatdatetime$
rem now makes before it writes agrees with the write, and that a size
rem past the longest string is refused before anything is allocated.
rem
rem EXPECTED VALUES: a number is spelled by the general format the
rem language reference documents (15 significant digits, an exponent
rem from 1E15 on), so 1e10 is 10000000000 and -1e300 is -1E300, and
rem each spelling is also checked against str$, a second door to it.
rem Dates: 45351 days after 1899-12-30 is 2024-02-29 and 43997 is
rem 2020-06-15, a Monday (Python: date(1899,12,30) + timedelta(n)).
rem ---------------------------------------------------------------

test_case("datetime-r4/an empty pattern is the ISO date")
rem 45351.5 is noon on 2024-02-29: the ISO date is yyyy-mm-dd, no time.
assert_eq(formatdatetime$("", 45351.5), "2024-02-29", "noon renders as the date alone")
assert_eq(formatdatetime$("", 45351.5), datetostr$(45351.5), "the same text datetostr$ writes")
assert_eq(formatdatetime$("", 45351), "2024-02-29", "and so does the midnight")
assert_eq(formatdatetime$("c", 45351.5), "2024-02-29 12:00:00", "while c keeps the time it always had")

test_case("datetime-r4/the year, month and day refusals name the value passed")
rem Each spelling, written out from the documented general format, is
rem first checked against str$ so the expectation has two sources.
assert_eq(str$(1e10), "10000000000", "1e10 spells 10000000000")
assert_eq(str$(-1e300), "-1E300", "-1e300 spells -1E300")
assert_eq(str$(10000.5), "10000.5", "10000.5 spells itself")

fin$ = ""
on error goto caught
n = daysinamonth(1e10, 2)
on error goto 0
assert_true(instr(fin$, "daysinamonth: 10000000000 is not a year in 1..9999") > 0, "a year of 1e10: " + fin$)

fin$ = ""
on error goto caught
n = daysinamonth(2024, 1e10)
on error goto 0
assert_true(instr(fin$, "daysinamonth: 10000000000 is not a month in 1..12") > 0, "a month of 1e10: " + fin$)

fin$ = ""
on error goto caught
n = daysinayear(-1e300)
on error goto 0
assert_true(instr(fin$, "daysinayear: -1E300 is not a year in 1..9999") > 0, "a year of -1e300: " + fin$)

rem 4294967296 is 2^32: ArgI32 saturated it to 2147483647.
fin$ = ""
on error goto caught
n = weeksinayear(4294967296)
on error goto 0
assert_true(instr(fin$, "weeksinayear: 4294967296 is not a year in 1..9999") > 0, "a year of 2^32: " + fin$)

rem An int% reaches the guard exactly, without a Double in between.
y% = 4294967296
fin$ = ""
on error goto caught
n = weeksinayear(y%)
on error goto 0
assert_true(instr(fin$, "weeksinayear: 4294967296 is not a year in 1..9999") > 0, "an int% year of 2^32: " + fin$)

rem January 2024 has 31 days.
fin$ = ""
on error goto caught
n = encodedate(2024, 1, 1e10)
on error goto 0
assert_true(instr(fin$, "encodedate: 10000000000 is not a day in 2024-01, which has 31") > 0, "a day of 1e10: " + fin$)

rem A fraction rounds to 10000, outside 1..9999, and the message keeps
rem the fraction the program wrote.
fin$ = ""
on error goto caught
n = daysinayear(10000.5)
on error goto 0
assert_true(instr(fin$, "daysinayear: 10000.5 is not a year in 1..9999") > 0, "a year of 10000.5: " + fin$)

rem The refusal is unchanged where nothing was narrowed.
fin$ = ""
on error goto caught
n = daysinamonth(2024, 13)
on error goto 0
assert_true(instr(fin$, "daysinamonth: 13 is not a month in 1..12") > 0, "the documented example: " + fin$)
assert_eq(daysinamonth(2024, 2), 29, "and a real month still answers: 2024 is a leap year")

test_case("datetime-r4/the string library's index refusals name the value too")
fin$ = ""
on error goto caught
n = byteat("abc", 1e10)
on error goto 0
assert_true(instr(fin$, "byteat: byte 10000000000 is outside 1..3") > 0, "byteat: " + fin$)

fin$ = ""
on error goto caught
b$ = bytestr$(1e10)
on error goto 0
assert_true(instr(fin$, "bytestr$: 10000000000 is not a byte value (0..255)") > 0, "bytestr$: " + fin$)

rem A string index WRITE past the end raises (str.md); 5e9 is past
rem 2^31, where the index used to be clamped to 2147483647.
s$ = "abc"
fin$ = ""
on error goto caught
s$[[5000000000]] = "z"
on error goto 0
assert_true(instr(fin$, "character 5000000000 is outside 1..3") > 0, "a character write: " + fin$)
assert_eq(s$, "abc", "and the string is untouched")

fin$ = ""
on error goto caught
s$[5000000000] = "z"
on error goto 0
assert_true(instr(fin$, "line 5000000000 is outside 1..1") > 0, "a line write: " + fin$)

test_case("datetime-r4/positions and counts past 2^31 clamp like any other")
rem str.md: out-of-range arguments clamp. These held before as well;
rem they pin that reading the argument whole changed no small answer.
assert_eq(left$("abc", 5e9), "abc", "left$ past the end is the whole string")
assert_eq(right$("abc", 5e9), "abc", "right$ past the end is the whole string")
assert_eq(mid$("hello", 2, 5e9), "ello", "mid$ with a count past the end")
assert_eq(mid$("hello", 5e9), "", "mid$ from past the end")
assert_eq(mid$("hello", -5e9, 2), "he", "mid$ from before the start clamps to 1")
assert_eq(instr("abcabc", "c", 5e9), 0, "instr from past the end")
assert_eq(insert$("abc", "X", 5e9), "abcX", "insert$ past the end appends")
assert_eq(delete$("hello", 2, 5e9), "h", "delete$ of more than remains")
assert_eq(bytemid$("abc", 2, 5e9), "bc", "bytemid$ of more than remains")
assert_eq(s$[[5000000000]], "", "a character read past the end is empty")
rem The codepoint family on a two-byte character, walked rather than tabulated:
rem chr$(233) is C3 A9.
e$ = "caf" + chr$(233) + "!"
assert_eq(len(e$), 5, "five characters")
assert_eq(bytelen(e$), 6, "six bytes")
assert_eq(right$(e$, 2), chr$(233) + "!", "right$ keeps the whole character")
assert_eq(left$(e$, 4), "caf" + chr$(233), "left$ too")
assert_eq(mid$(e$, 4, 1), chr$(233), "mid$ one character")
assert_eq(e$[[4]], chr$(233), "s$[[4]]")
assert_eq(reverse$(e$), "!" + chr$(233) + "fac", "reverse$ keeps the character whole")
assert_eq(instr(e$, "!"), 5, "instr answers a character position")
rem A string that BEGINS with a continuation byte: byte 1 is its own
rem character (the Utf8Starts rule), and the walkers agree.
o$ = bytemid$(e$, 5, 1) + "a"
assert_eq(len(o$), 2, "an orphan continuation byte is one character")
assert_eq(left$(o$, 0), "", "left$(x, 0) is empty for every x")
assert_eq(bytelen(left$(o$, 1)), 1, "left$ 1 is the orphan")
assert_eq(right$(o$, 1), "a", "right$ 1 is the a")
assert_eq(bytelen(reverse$(o$)), 2, "reverse$ keeps both bytes")
assert_eq(byteat(reverse$(o$), 2), 169, "with the orphan last: 0xA9 is 169")

test_case("datetime-r4/a size past the longest string is refused before it is built")
rem 1e300 saturates to 2^63 - 1 copies, and a four-byte character makes
rem that 2^65 bytes: past High(SizeInt), refused rather than wrapped.
rem chr 128512 is U+1F600, four bytes in UTF-8.
fin$ = ""
on error goto caught
t$ = string$(1e300, 128512)
on error goto 0
assert_true(instr(fin$, "string$: the answer would be past the longest string") > 0, "string$: " + fin$)
fin$ = ""
on error goto caught
t$ = center$("x", 1e300, 128512)
on error goto 0
assert_true(instr(fin$, "center$: the answer would be past the longest string") > 0, "center$: " + fin$)
fin$ = ""
on error goto caught
t$ = lfill$("x", 1e300, 128512)
on error goto 0
assert_true(instr(fin$, "lfill$: the answer would be past the longest string") > 0, "lfill$: " + fin$)
fin$ = ""
on error goto caught
t$ = mulstring$("abcd", 1e300)
on error goto 0
assert_true(instr(fin$, "mulstring$: the answer would be past the longest string") > 0, "mulstring$: " + fin$)
assert_eq(string$(3, 128512), chr$(128512) + chr$(128512) + chr$(128512), "and a small one is built")
assert_eq(center$("x", 4, 42), "*x**", "center$ splits the pad, the smaller half first")

test_case("datetime-r4/the counted size and the written answer agree")
rem 2020-06-15 12:00:00 is 43997.5; "c" and "f" each render nineteen
rem bytes there, so 1024 pairs are 1024 * 38 = 38912 bytes.
d = 43997.5
p$ = "cf"
for i = 1 to 10
  p$ = p$ + p$
next
assert_eq(bytelen(p$), 2048, "1024 pairs")
r$ = formatdatetime$(p$, d)
assert_eq(bytelen(r$), 38912, "1024 * (19 + 19) bytes")
assert_eq(left$(r$, 38), "2020-06-15 12:00:002020-06-15 12:00:00", "and the first pair reads right")
assert_eq(right$(r$, 19), "2020-06-15 12:00:00", "and so does the last")
assert_eq(formatdatetime$("yyyy-mm-dd hh:nn:ss.zzz 'x' ampm dddd mmmm", d), "2020-06-15 12:00:00.000 x PM Monday June", "every kind of field in one pattern")
assert_eq(formatdatetime$("'unterminated", d), "unterminated", "an unterminated quote runs to the end")
end

caught:
fin$ = errmsg$()
resume next
