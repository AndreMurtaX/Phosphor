# date-time — a date is a number, and this is the arithmetic around it

`engine/libs/PhosphorDateTimeLib.pas` · 68 functions · always available

## What it is for

There is no date *type* in Phosphor. A date is a plain number — a TDateTime,
days since 1899-12-30 with the time of day in the fraction — so `45351.5` is noon
on 2024-02-29. Every function on this page either takes such a number apart,
moves it, measures between two of them, or converts one to and from text.
Nothing is allocated and nothing is handed back as a handle: a date can be
stored in an array, compared with `=`, or printed as a number without asking
this library's permission.

**Before 1899-12-30 the number is not a line**, and that is the one fact about
the representation a program has to hold. A date before the epoch is negative,
and it is spelled *sign-and-magnitude*: the day is the integer part and the time
of day is the absolute value of the fraction, so noon on 1850-06-15 is
`-18095.5` while midnight that day is `-18095` — the time of day moves the number
**down**. So plain arithmetic on the number is right only when every value
involved is on or after 1899-12-30: there, `d + 1` is the next day and
`d + 0.5` is twelve hours on. Before it, `d + 0.5` is twelve hours *earlier*
within the day, `<` does not order two moments of the same day, and a sum that
crosses the epoch lands on the wrong day. **Use the library to move and
compare**: `incday`, `inchour` and the rest move a date correctly on both sides,
`*between`/`*span` measure, and `issameday` compares days.

The consequence a caller has to hold in mind is that **there is no empty date**.
`0` is not "no value", it is 1899-12-30 — so `yearof(0)` answers `1899` rather
than complaining, and for any number inside `0001-01-01`..`9999-12-31` no
function here has a "not a date" answer to give. A number that came from
somewhere untrustworthy is not validated by asking a question about it; it is
validated before it becomes a date.

The **calendar** is the RTL's `DateUtils`, deliberately: leap years, month
lengths, and encoding and decoding a day are the RTL's rules rather than ones
reinvented here. The **arithmetic** is not. The RTL's was written for the
positive half of the number and patched at the epoch, and the patch was wrong in
five places this library has met — `issameday`, `dayoftheyear`, the sixteen
distances, the increments, and the ISO week. So every function that moves a date
or measures between two works on the *line*: the day and the time of day as two
separate parts, written back as the sign-and-magnitude number once, at the end.
The parsers are this library's own too, because the RTL's fill in whatever the
text leaves out (see *Text*). And the three functions that take a **year or
month as a number** (`daysinayear`, `daysinamonth`, `weeksinayear`) check it
first: `daysinamonth(2024, 13)` used to index the RTL's month table out of bounds
and return `65450` as a clean success; it now raises a catchable runtime error
naming the value — the value **as the program wrote it**, so
`daysinamonth(1e10, 2)` says `daysinamonth: 10000000000 is not a year in
1..9999`. (Until 2026-10-09, round 4, the guards saw the argument after it had
been narrowed to 32 bits, which saturates, and named `2147483647` instead; the
same held for `encodedate`'s day.)

**Every function that reads a date reads it to the millisecond**, rounding half
up on the line: a moment within half a millisecond of midnight is the next day's
midnight, on both sides of the epoch, for `yearof`, `dayofweek`, `hourof`,
`datetimetostr$` and the rest alike. (The RTL rounded in the spelling, so before
1900 such a moment was read as the day *before* — two days from the midnight it
is closest to — while `dayofweek`, which did not round at all, named a third
day.)

A further family breaks the pass-through the same way and for the same reason, at
the other end. Ten functions that take a **date** cannot survive the number
being outside `0001-01-01`..`9999-12-31`, because the RTL's `DecodeDate` answers
year 0 below that range instead of refusing, and clamps above it. They ask the
same guard `incmonth` and `incyear` ask, and answer `that number is not a date in
0001-01-01..9999-12-31`: `daysinmonth`, `daysinyear`, `weeksinyear`,
`weekoftheyear`, `weekof`, `weekofthemonth`, `dayoftheyear`, `datetostr$`,
`datetimetostr$` and `formatdatetime$`. Everything else on this page always
answers, **for every number a program can hold**, however far outside the
calendar: the time of day is read off the number's fraction (past 2^52 a Double
has none, so every such number is a midnight), the weekday off its day number by
exact arithmetic, and a whole distance is the count however large. Until
2026-10-09 (round 3) the RTL did those three readings by converting the whole
number to an integer, and `hourof`, `isam`, `timetostr$`, `formatdatetime$` and
the rest raised its `Invalid floating point operation` from about 1.07e11 days
on — numbers `incday` had just answered as the plain sum.

Text is ISO 8601 and **pinned**, not locale-following: `yyyy-mm-dd`, `hh:nn:ss`,
`.` for decimals, English month and day names, and `AM`/`PM`, on every machine.
So a hard-coded `"2020-06-15"` is read the same everywhere, rendering and parsing
are exact inverses, and `formatdatetime$("dddd", d)` answers `Monday` under a
Portuguese locale too. The price is that `strtodate("15/06/2020")` is an error
rather than a guess — and so are `"20-06-15"`, `"2020-6-5"` and `"06-15"`, which
the parsers used to complete with a century, a zero or the current year — which
is the intended trade. The renderer is this library's own since 2026-10-09
(round 3): it was the RTL's, under settings copied from the machine and pinned
field by field, and the fields nobody pinned still followed it — `ampm` printed
the locale's designators, which a pt-BR Windows leaves *empty*, so 06:00 and
18:00 both rendered `6:00 `; `e` and `g` were era specifiers on Windows alone;
and every answer was cut at 255 bytes.

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

Only `dayoftheyear` can fail here, and only for a number outside
`0001-01-01`..`9999-12-31`. Every number inside the range is *some* date, so a
nonsense value in it is taken apart into the nonsense date it names rather than
reported as bad.

| function | what it answers |
| --- | --- |
| `yearof(d) → num` | the calendar year |
| `monthof(d) → num` | the month, 1–12 |
| `monthoftheyear(d) → num` | the same answer as `monthof` |
| `dayof(d) → num` | the day of the month, 1–31 |
| `dayofthemonth(d) → num` | the same answer as `dayof` |
| `dayoftheyear(d) → num` | the day within the year, 1–366. Refuses a number outside `0001-01-01`..`9999-12-31` rather than answering for a date that does not exist; it used to count day `0` of year `0` |
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
| `daysinmonth(d) → num` | 28–31, for the month `d` falls in. Takes a **date**, and refuses a number outside `0001-01-01`..`9999-12-31` rather than answering for a date that does not exist — below the range it used to read one element before the RTL's 1–12 month table and answer a fabricated `31` |
| `daysinamonth(year, month) → num` | 28–31 for a month named by two numbers. A month outside 1–12 or a year outside 1–9999 raises a catchable runtime error (`daysinamonth: 13 is not a month in 1..12`) instead of answering a number |
| `daysinyear(d) → num` | 365 or 366, for the year `d` falls in. Refuses a number outside `0001-01-01`..`9999-12-31` |
| `daysinayear(year) → num` | the same, for a year named by number; a year outside 1–9999 is an error, not an answer |
| `weeksinyear(d) → num` | 52 or 53 ISO weeks, for the year `d` falls in. Refuses a number outside `0001-01-01`..`9999-12-31` |
| `weeksinayear(year) → num` | the same by year number, with the same 1–9999 guard — `weeksinayear(0)` used to raise the RTL's own `EConvertError`, and now raises this library's message |
| `weekoftheyear(d) → num` | the ISO week number, 1–53. An ISO week belongs to the year that owns most of it, so 2021-01-01 is week **53**, not week 1 — `yearof` and `weekoftheyear` can disagree about which year you are in. Refuses a number outside `0001-01-01`..`9999-12-31` |
| `weekof(d) → num` | the same function under a shorter name, with the same refusal |
| `weekofthemonth(d) → num` | which week of its own month the date falls in, counting from 1 — a month reaches 5 whenever its days straddle five week boundaries, as February 2024 does. The ISO rule applied to a month: a week runs Monday to Sunday and belongs to the month that holds its Thursday, so the first days of a month that starts on a Friday answer the previous month's last week. Refuses a number outside `0001-01-01`..`9999-12-31` |

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
backwards, which is how you subtract. The count is a **quantity**, read whole: a
fraction is rounded to a whole number as before, but nothing is clipped, so
`incminute(d, 2147483648)` is 2^31 minutes on (until 2026-10-09 every count went
through a 32-bit narrowing, and that call moved 2^31 − 1 minutes without a word).
Every move is made on the line, so it is right on both sides of 1899-12-30 and
across it.

| function | what it answers |
| --- | --- |
| `incday(d, n) → num` | `d` moved `n` days, keeping its time of day. That is `d + n` only when `d` and the answer are both on or after 1899-12-30 — see *What it is for*. Until 2026-10-09 a midnight moved across the epoch landed one day too far: `incday(encodedate(1899, 12, 29), 6)` answered 1900-01-05 |
| `incweek(d, n) → num` | `d` moved `n` × 7 days, keeping its time of day |
| `incmonth(d, n) → num` | the same day-of-month `n` months away, **clamping onto a shorter month**: 31 January plus one month is 28 February, or the 29th in a leap year. The time of day is carried through, to the millisecond |
| `incyear(d, n) → num` | the same date `n` years away, **clamping 29 February to the 28th** when the target year has no 29th, rather than rolling into March. The time of day is carried as `incmonth` carries it |
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

A whole count is the count **however large**: past 2^63 units it is the number
it is rather than an integer that no longer holds it, so
`secondsbetween(incday(0, 1e15), 0)` is `8.64e19`. Until 2026-10-09 (round 3)
`daysbetween`, `weeksbetween`, `monthsbetween` and `yearsbetween` narrowed to a
32-bit integer — three billion days answered `-1294967296`, a negative distance —
and past 2^63 units every `*between` raised the RTL's `Invalid floating point
operation`. A distance too large to be a number at all, as between `1e308` and
`-1e308`, is refused by the engine, `has no finite result for those arguments`,
as every library result that is not a number is.

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
| `datetostr$(d) → str` | the date part as `2024-02-29`; the time is dropped. Refuses a number outside `0001-01-01`..`9999-12-31` rather than rendering text `strtodate` would then refuse — below the range it used to answer `0000-00-00`, and above it a clamped `9999-12-31` reported as though it were real |
| `timetostr$(d) → str` | the time part as `12:00:00`; the date is dropped. Answers for any number: it reads only the fraction |
| `datetimetostr$(d) → str` | both, as `2024-02-29 12:00:00` — **except** that a value whose time is exactly midnight renders as the date alone, `2020-06-15`. It still parses back to the identical number, but the string is shorter than a fixed-width reader expects. *Exactly*: until 2026-10-09 (round 3) any instant in the first second of a day — `00:00:00.500` — rendered as the bare date too, because the RTL's rule looked at hour, minute and second and not at the milliseconds. Refuses a number outside `0001-01-01`..`9999-12-31`, as `datetostr$` does |
| `formatdatetime$(pattern$, d) → str` | `d` rendered through `pattern$` — note the **pattern comes first**, the opposite of the Delphi call it mirrors. `yyyy mm dd hh nn ss zzz` for numbers, `ddd/dddd/mmm/mmmm` for pinned-English names, `ampm` for `AM`/`PM` (and `am/pm`, `a/p` for those letters, case kept), `c` for what `datetimetostr$` writes. Literal words must be quoted inside the pattern: `formatdatetime$("'week' ww", d)` answers `week WW`, while an unquoted `"week ww"` answers `WEEK WW` — every letter is a candidate specifier, and a letter that is none prints upper-cased (on Windows `e` and `g` were era specifiers until round 3, and `"week ww"` printed `WeK WW` there and `WEEK WW` on Linux; a lone `a` raised the RTL's `Illegal character in format string`). An empty pattern gives the ISO date, `yyyy-mm-dd`, exactly what `datetostr$` writes (until 2026-10-09, round 4, it was the `c` rendering, which adds the time unless the moment is an exact midnight). Nothing is cut at any size: an answer past 2 GiB is built whole — "cf" doubled 26 times answers 2550136832 bytes, where a 32-bit write cursor used to wrap and write before its buffer — and its size is counted, and charged to the host's budget, before a byte of it is allocated. Refuses a number outside `0001-01-01`..`9999-12-31`, as `datetostr$` does — above the range it used to render a clamped `9999-12-31` as though it were real, below it month 0 (`mmm` read the name table one element before its start), and past about 1.07e11 days it raised |
| `strtodate(s$) → num` | the date `s$` names. Must be exactly ISO `yyyy-mm-dd` — four digits, two, two, in `0001-01-01`..`9999-12-31`, a day the month has. Anything else — a `15/06/2020`, an impossible 2020-13-45, a two-digit year, an unpadded `2020-6-5`, a blank at either end — raises a catchable runtime error whose message begins `invalid date:` rather than answering a plausible number |
| `strtotime(s$) → num` | the time `s$` names, as a fraction below 1. Exactly `hh:nn` or `hh:nn:ss`, two digits each, `00:00`..`23:59:59` — no `AM`/`PM`, no fraction of a second. Anything else is an error, message beginning `invalid time:` |
| `strtodatetime(s$) → num` | date and time together: `yyyy-mm-dd hh:nn:ss`, `yyyy-mm-dd hh:nn`, or the date alone (which is how `datetimetostr$` renders a midnight), with exactly one blank between — not a `T`. A time alone is not a date-time. Anything else is an error, message beginning `invalid datetime:` |

**The parsers read exactly the forms above, and complete nothing.** Until
2026-10-09 they were the RTL's lenient readers: `"0-6-15"` was 2000-06-15,
`"20-06-15"` 2020-06-15, `"06-15"` June 15 of the *current* year, `"10"` the 10th
of the current month, `"1:2"` 01:02, `"10:20:30 PM"` 22:20:30, and
`strtodatetime("10:20")` a time on 1899-12-30. Text that arrives from somewhere
else is data, and a parser that invents the parts it was not given turns a
malformed record into a plausible wrong one. Every text `datetostr$`,
`timetostr$` and `datetimetostr$` write is accepted, so render and parse remain
inverses.

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

The last line reads the clock, so it is dated rather than fixed. Real output from
a run on 2026-09-06; every other line is the same on any day.

```
opened 2024-02-29 14:30:00 (Thursday, ISO week 9)
due    2024-04-01 14:30:00 (Monday)
gap    32 whole days, 768 hours
February 2024 has 29 days
because 2024 is a leap year
the ticket is 920 days old today (2026-09-06)
```

Three things worth noticing:

- **The gap is 32, not 30.** `incday` moved thirty days to a Saturday and
  `next_workday` pushed it to the Monday; `daysbetween` then reported the real
  distance rather than the one that was asked for. A measurement and an intention
  are different questions here, and the library only answers the first.
- **`daysinamonth(yearof(opened), monthof(opened))`** is the round trip that the
  `a`-in-the-middle naming exists for: take a date apart into numbers, ask a
  question about the numbers. Had `monthof` answered 13, this call would have
  raised rather than invented a length.
- **Only the last line moves.** Every other line is arithmetic on a date fixed in
  the source, so it is the same on any machine on any day; the sixth reads the
  clock through `now()` and `date$()`, and the run above happened on 2026-09-06.
  That line was missing from this block until 2026-09-06 — the program printed six
  lines and the page showed five, which no gate could catch, because
  `check-examples.py` compiles an example and does not run it.

## Notes

**Building a date from three numbers** is `encodedate(y, m, d)`, added
2026-09-06. Before it, a program holding a year, a month and a day had to
assemble ISO text and hand it to `strtodate` — which asked a *parser* a question
about arithmetic, and got back "bad text" where the honest answer was "that month
has 28 days". `strtodate` is still the right tool when the date arrives as text
— as ISO `yyyy-mm-dd`; since 2026-10-09 it no longer accepts unpadded parts, so
`"2024-2-9"` is refused where it used to be read.

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

`incday`, `incweek`, `inchour`, `incminute`, `incsecond` and `incmillisecond`
do **not** have this check, because they are additions and need no calendar to
make them. Stepping past the end with them answers a number outside the range —
the plain sum, however large the step, never a clipped one — and what happens
next depends on which door that number reaches. The ten date-taking functions
above refuse it by name. `yearof`, `monthof`, `dayof` (and `monthoftheyear`,
`dayofthemonth`) do not: they hand it to the RTL, which clamps the top end back
to `9999-12-31` and reports it as though it were real, and answers year 0 below
the range. Every reader of the time of day, the weekday and the distances
answers for it exactly (see *What it is for*). Worth knowing before you add a
large number of days to a date near the year 9999. A sum too large to be a
number at all — `incweek(d, 1e308)` — is refused by the engine as every library
result is, `has no finite result for those arguments`.

**The nineteen that can fail** are `strtodate`, `strtotime`, `strtodatetime`,
`daysinayear`, `daysinamonth`, `weeksinayear`, `encodedate`, `incmonth`,
`incyear`, and the ten that take a date outside the representable range:
`daysinmonth`, `daysinyear`, `weeksinyear`, `weekoftheyear`, `weekof`,
`weekofthemonth`, `dayoftheyear`, `datetostr$`, `datetimetostr$` and
`formatdatetime$` (since 2026-10-09, round 3) — `weeksinyear` in its own right,
beside its year-taking twin `weeksinayear`. They fail as ordinary runtime
errors — code `6`, catchable with `on error goto` and readable through `err()`
and `errmsg$()` — never by answering a wrong number. See [err.md](err.md) for the
handler side. (Like every function that builds a string, the renderers can also
be refused by the run's budget, and any function by the engine's finiteness
gate; those are the engine's limits, not this library's.)

**Where the rest lives.** The one-line catalogue of every name is in
[function-reference.md](../function-reference.md); the assertions that pin the
behaviour described here are `tests/suite/20_datetime.bas` (calendar),
`tests/suite/29_datetime_full.bas` (clock, text, arithmetic, spans), the
out-of-range cases in `tests/suite/50_robustness.bas`, and
`tests/suite/85_datetime_round2.bas` — the strict parsers, and a sweep generated
by `tests/datetime_round2_sweep.py` from Python's proleptic Gregorian calendar
of every decomposition, increment and distance over thousands of instants, dense
around 1899-12-30 and at both ends of the range; and
`tests/suite/90_datetime_round3.bas` — numbers far outside the calendar, the
pinned `AM`/`PM` and letters, long patterns, and the exact-midnight rule.
