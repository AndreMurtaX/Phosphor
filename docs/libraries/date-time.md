# date-time — a date is a number, and this is the arithmetic around it

`engine/libs/PhosphorDateTimeLib.pas` · 68 functions · always available

## What it is for

There is no date *type* in Phosphor. A date is a plain number — a TDateTime,
days since 1899-12-30 with the time of day in the fraction — so `45351.5` is noon
on 2024-02-29, `d + 1` is the next day and `d + 0.5` is twelve hours on. Every
function on this page either takes such a number apart, moves it, measures
between two of them, or converts one to and from text. Nothing is allocated and
nothing is handed back as a handle: a date can be stored in an array, compared
with `<`, or printed as a number without asking this library's permission.

The consequence a caller has to hold in mind is that **there is no empty date**.
`0` is not "no value", it is 1899-12-30 — so `yearof(0)` answers `1899` rather
than complaining, and no function here has a "not a date" answer to give. A
number that came from somewhere untrustworthy is not validated by asking a
question about it; it is validated before it becomes a date.

The implementation is a thin layer over the RTL's `DateUtils`, deliberately: leap
years, ISO week numbering, month lengths and the clamp that turns "a year after
29 February" into the 28th are the RTL's rules rather than ones reinvented here.
Three places break that pass-through on purpose, because the RTL's answer was
worse than an error: the three parsers (`strtodate`, `strtotime`,
`strtodatetime`) and the three functions that take a **year or month as a
number** (`daysinayear`, `daysinamonth`, `weeksinayear`). `daysinamonth(2024, 13)`
used to index the RTL's month table out of bounds and return `65450` as a clean
success; it now raises a catchable runtime error naming the value. Everything
else on this page always answers.

Text is ISO 8601 and **pinned**, not locale-following: `yyyy-mm-dd`, `hh:nn:ss`,
`.` for decimals, and English month and day names, on every machine. So a
hard-coded `"2020-06-15"` is read the same everywhere, rendering and parsing are
exact inverses, and `formatdatetime$("dddd", d)` answers `Monday` under a
Portuguese locale too. The price is that `strtodate("15/06/2020")` is an error
rather than a guess, which is the intended trade.

Two naming families read alike and are not. `dayofweek` counts from Sunday while
`dayoftheweek` is ISO and counts from Monday. And the extra `a` in the middle
means "named by number instead of read off a date": `daysinmonth(d)` takes a
date, `daysinamonth(year, month)` takes two numbers — likewise
`daysinyear`/`daysinayear` and `weeksinyear`/`weeksinayear`.

## Functions

Predicates answer the numbers `1` and `0`, not a `?` bool, so they are written
`if isam(d) = 1 then` and not `if isam(d) then`.

### Reading the clock

| function | what it answers |
| --- | --- |
| `now() → num` | the machine's current local date and time, read afresh on each call. No argument, and no UTC variant — this library is entirely local time |
| `gettime() → num` | the same value as `now()`; a second spelling, not a finer clock |
| `today() → num` | the current date with the time fraction exactly `0` (midnight) |
| `date() → num` | the same value as `today()` |
| `time() → num` | the time of day alone: a fraction below `1`, whose date part is therefore 1899-12-30 if you ever render it as one |
| `tomorrow() → num` | `today() + 1`, at midnight |
| `yesterday() → num` | `today() - 1`, at midnight |
| `istoday(d) → num` | `1` when `d` falls on the current date, `0` otherwise. The time inside `d` is ignored, so a timestamp from this morning is still today |
| `date$() → str` | the current date as `2026-09-06` |
| `time$() → str` | the current time as `09:19:48` |
| `datetime$() → str` | both, as `2026-09-06 09:19:48` |

### Decomposing a date

None of these can fail. Every finite number is *some* date, so a nonsense value
is taken apart into the nonsense date it names rather than reported as bad.

| function | what it answers |
| --- | --- |
| `yearof(d) → num` | the calendar year |
| `monthof(d) → num` | the month, 1–12 |
| `monthoftheyear(d) → num` | the same answer as `monthof` |
| `dayof(d) → num` | the day of the month, 1–31 |
| `dayofthemonth(d) → num` | the same answer as `dayof` |
| `dayoftheyear(d) → num` | the day within the year, 1–366 |
| `dayofweek(d) → num` | the weekday counting **Sunday = 1** … Saturday = 7 |
| `dayoftheweek(d) → num` | the weekday counting **ISO Monday = 1** … Sunday = 7. Three letters from the row above, one from its answer |
| `hourof(d) → num` | the hour, 0–23 (never 1–12; there is no clock half in this number) |
| `minuteof(d) → num` | the minute, 0–59 |
| `secondof(d) → num` | the second, 0–59 |
| `millisecondof(d) → num` | the millisecond, 0–999. A date carried through arithmetic can land a millisecond off what you expect — the fraction is binary |
| `isam(d) → num` | `1` when the hour is under 12. A plain date carries no time, i.e. midnight, so `isam` of a bare date is `1` |
| `ispm(d) → num` | `1` when the hour is 12 or more; always exactly `1 - isam(d)` — never both, never neither |
| `issameday(a, b) → num` | `1` when the two land on the same calendar day, whatever their times |

### The calendar: leap years, lengths, weeks

| function | what it answers |
| --- | --- |
| `isinleapyear(d) → num` | `1` when `d`'s year is a leap year — 2000 is, by the 400 rule; 1900 is not, by the 100 rule |
| `daysinmonth(d) → num` | 28–31, for the month `d` falls in. Takes a **date** |
| `daysinamonth(year, month) → num` | 28–31 for a month named by two numbers. A month outside 1–12 or a year outside 1–9999 raises a catchable runtime error (`daysinamonth: 13 is not a month in 1..12`) instead of answering a number |
| `daysinyear(d) → num` | 365 or 366, for the year `d` falls in |
| `daysinayear(year) → num` | the same, for a year named by number; a year outside 1–9999 is an error, not an answer |
| `weeksinyear(d) → num` | 52 or 53 ISO weeks, for the year `d` falls in |
| `weeksinayear(year) → num` | the same by year number, with the same 1–9999 guard — `weeksinayear(0)` used to raise the RTL's own `EConvertError`, and now raises this library's message |
| `weekoftheyear(d) → num` | the ISO week number, 1–53. An ISO week belongs to the year that owns most of it, so 2021-01-01 is week **53**, not week 1 — `yearof` and `weekoftheyear` can disagree about which year you are in |
| `weekof(d) → num` | the same function under a shorter name |
| `weekofthemonth(d) → num` | which week of its own month the date falls in, counting from 1 — a month reaches 5 whenever its days straddle five week boundaries, as February 2024 does |

### Building a date from numbers

The other direction from *Decomposing*: three numbers in, one date out. It is the
only function here that constructs a date without reading the clock or moving
another one.

| function | what it answers |
| --- | --- |
| `encodedate(y, m, d) → num` | the date those numbers name, at midnight — so `encodedate(2020, 6, 15)` is exactly what `strtodate("2020-06-15")` answers. A date that does not exist is **refused**, naming the value and the reason: `29 is not a day in 2023-02, which has 28` |

The three parts are checked against each other, which is the whole point of taking
them as numbers: `2023-02-29` is refused because that February has 28 days, while
`2024-02-29` is accepted because that one has 29. The range is `0001-01-01` to
`9999-12-31`.

```basic
rem the last day of any month, without a table of month lengths
function month_end(y, m)
  return encodedate(y, m, daysinamonth(y, m))
endfunction

println datetostr$(month_end(2024, 2))
println datetostr$(month_end(2023, 2))
println datetostr$(incmonth(encodedate(2026, 1, 31), 1))
```

```
2024-02-29
2023-02-28
2026-02-28
```

### Moving a date

Each `inc*` moves by its own unit and touches nothing else. A negative count goes
backwards, which is how you subtract.

| function | what it answers |
| --- | --- |
| `incday(d, n) → num` | `d` moved `n` days — which is exactly `d + n`, since a day is 1 |
| `incweek(d, n) → num` | `d` moved `n` × 7 days |
| `incmonth(d, n) → num` | the same day-of-month `n` months away, **clamping onto a shorter month**: 31 January plus one month is 28 February, or the 29th in a leap year. The time of day is carried through |
| `incyear(d, n) → num` | the same date `n` years away, **clamping 29 February to the 28th** when the target year has no 29th, rather than rolling into March |
| `inchour(d, n) → num` | `d` moved `n` hours |
| `incminute(d, n) → num` | `d` moved `n` minutes |
| `incsecond(d, n) → num` | `d` moved `n` seconds |
| `incmillisecond(d, n) → num` | `d` moved `n` milliseconds |

**A clamp does not undo.** `incmonth(incmonth(d, 1), -1)` answers 28 January when
`d` was 31 January, not the 31st it started from: the day was lost on the way out
and there is nothing left to restore it. This is how month arithmetic works
everywhere and it is not a defect, but it is the one thing about `incmonth` that
surprises people. If you need the last day of a month, ask for it —
`encodedate(y, m, daysinamonth(y, m))` — rather than stepping onto it.

### Distance between two dates

Two families over the same measurement. `*between` truncates to whole units
elapsed; `*span` keeps the fraction. Both are **non-negative**: the order of the
arguments does not matter and no sign comes back, so compare the two dates with
`<` when you need to know which way round they are. Months and years in either
family are computed from the day count (30.4375 days to a month, 365.25 to a
year) rather than walked over the calendar — which is why 31 January to 1 March
is `0` whole months.

| function | what it answers |
| --- | --- |
| `daysbetween(a, b) → num` | whole days elapsed; twelve hours is `0` |
| `dayspan(a, b) → num` | the same distance in days as a fraction; twelve hours is `0.5` |
| `weeksbetween(a, b) → num` | whole 7-day weeks; six days is `0` |
| `weekspan(a, b) → num` | the distance in weeks as a fraction |
| `monthsbetween(a, b) → num` | whole approximate months (see above) |
| `monthspan(a, b) → num` | the same as a fraction; a calendar year is about `11.99`, not exactly 12 |
| `yearsbetween(a, b) → num` | whole approximate years; 364 days is `0` |
| `yearspan(a, b) → num` | the same as a fraction |
| `hoursbetween(a, b) → num` | whole hours |
| `hourspan(a, b) → num` | hours as a fraction |
| `minutesbetween(a, b) → num` | whole minutes |
| `minutespan(a, b) → num` | minutes as a fraction |
| `secondsbetween(a, b) → num` | whole seconds |
| `secondspan(a, b) → num` | seconds as a fraction |
| `millisecondsbetween(a, b) → num` | whole milliseconds |
| `millisecondspan(a, b) → num` | milliseconds as a fraction |

### Text: rendering and parsing

| function | what it answers |
| --- | --- |
| `datetostr$(d) → str` | the date part as `2024-02-29`; the time is dropped |
| `timetostr$(d) → str` | the time part as `12:00:00`; the date is dropped |
| `datetimetostr$(d) → str` | both, as `2024-02-29 12:00:00` — **except** that a value whose time is exactly midnight renders as the date alone, `2020-06-15`. It still parses back to the identical number, but the string is shorter than a fixed-width reader expects |
| `formatdatetime$(pattern$, d) → str` | `d` rendered through `pattern$` — note the **pattern comes first**, the opposite of the Delphi call it wraps. `yyyy mm dd hh nn ss zzz` for numbers, `ddd/dddd/mmm/mmmm` for pinned-English names. Literal words must be quoted inside the pattern: `formatdatetime$("'week' ww", d)` answers `week WW`, while an unquoted `"week ww"` answers `WeK WW` — every letter is a candidate specifier. An empty pattern gives the ISO date |
| `strtodate(s$) → num` | the date `s$` names. Must be ISO `yyyy-mm-dd` (the parts may be unpadded); anything else — a `15/06/2020`, an impossible 2020-13-45 — raises a catchable runtime error whose message begins `invalid date:` rather than answering a plausible number |
| `strtotime(s$) → num` | the time `s$` names, as a fraction below 1. `hh:nn` or `hh:nn:ss`; a bad string is an error, message beginning `invalid time:` |
| `strtodatetime(s$) → num` | date and time together, `yyyy-mm-dd hh:nn:ss`; a bad string is an error, message beginning `invalid datetime:` |

## A worked example

A ticket opened at a known moment, due thirty days later, never landing on a
weekend. Every date here starts as ISO text so the program reads the same on any
machine, and the only helper is defined in the program itself.

```basic
rem A ticket opened at a known moment, due 30 days later, never on a weekend.

function next_workday(d)
  wd = dayoftheweek(d)
  if wd = 6 then return incday(d, 2)
  if wd = 7 then return incday(d, 1)
  return d
endfunction

opened = strtodatetime("2024-02-29 14:30:00")
due = next_workday(incday(opened, 30))

println "opened " + datetimetostr$(opened) + " (" + formatdatetime$("dddd", opened) + ", ISO week " + str$(weekof(opened)) + ")"
println "due    " + datetimetostr$(due) + " (" + formatdatetime$("dddd", due) + ")"
println "gap    " + str$(daysbetween(opened, due)) + " whole days, " + str$(hourspan(opened, due)) + " hours"

rem February's length is a fact about a year, not about a date.
println "February " + str$(yearof(opened)) + " has " + str$(daysinamonth(yearof(opened), monthof(opened))) + " days"
if isinleapyear(opened) = 1 then println "because " + str$(yearof(opened)) + " is a leap year"

age = dayspan(opened, now())
println "the ticket is " + str$(int(age)) + " days old today (" + date$() + ")"
```

```
opened 2024-02-29 14:30:00 (Thursday, ISO week 9)
due    2024-04-01 14:30:00 (Monday)
gap    32 whole days, 768 hours
February 2024 has 29 days
because 2024 is a leap year
```

Two things worth noticing:

- **The gap is 32, not 30.** `incday` moved thirty days to a Saturday and
  `next_workday` pushed it to the Monday; `daysbetween` then reported the real
  distance rather than the one that was asked for. A measurement and an intention
  are different questions here, and the library only answers the first.
- **`daysinamonth(yearof(opened), monthof(opened))`** is the round trip that the
  `a`-in-the-middle naming exists for: take a date apart into numbers, ask a
  question about the numbers. Had `monthof` answered 13, this call would have
  raised rather than invented a length.

## Notes

**Building a date from three numbers** is `encodedate(y, m, d)`, added
2026-09-06. Before it, a program holding a year, a month and a day had to
assemble ISO text and hand it to `strtodate` — which asked a *parser* a question
about arithmetic, and got back "bad text" where the honest answer was "that month
has 28 days". `strtodate` is still there and still accepts unpadded parts, so
`"2024-2-9"` works; it is the right tool when the date arrives as text.

**A step off the end of the calendar is refused, not invented.** The
representable range is `0001-01-01` to `9999-12-31`. `incmonth` and `incyear`
check **both ends of the step** — the number they start from, and the year they
would land in — before moving. They used to fail in two different and worse ways:
`incyear` aborted the program with the RTL's own words
(`Invalid date/timestamp : "10000/06/15 00:00:00,000"`), and `incmonth` — when it
was added — would have answered `1899-12-30` without a word, a plausible date
that is silently wrong.

Checking only the landing year was not enough, which is worth knowing because the
reason is not obvious: the RTL's own `DecodeDate` answers *year 0* for a number
below the range rather than refusing it, so the month arithmetic started from a
year that does not exist and landed back inside `1..9999`. A step of 12 was
refused while a step of 13 was not.

`incday` and `incweek` do **not** have this check, because they are additions on
the number and cannot raise. Stepping past the end with them answers a number
outside the range, which `datetostr$` and `yearof` then clamp back to
`9999-12-31` and report as though it were real. Worth knowing before you add a
large number of days to a date near the year 9999.

**The nine that can fail** are `strtodate`, `strtotime`, `strtodatetime`,
`daysinayear`, `daysinamonth`, `weeksinayear`, `encodedate`, `incmonth` and
`incyear`. They fail as ordinary runtime errors — code `6`, catchable with
`on error goto` and readable through `err()` and `errmsg$()` — never by answering
a wrong number. See [err.md](err.md) for the handler side.

**Where the rest lives.** The one-line catalogue of every name is in
[function-reference.md](../function-reference.md); the assertions that pin the
behaviour described here are `tests/suite/20_datetime.bas` (calendar),
`tests/suite/29_datetime_full.bas` (clock, text, arithmetic, spans) and the
out-of-range cases in `tests/suite/50_robustness.bas`.
