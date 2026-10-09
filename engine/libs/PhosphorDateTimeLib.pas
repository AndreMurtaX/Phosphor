{******************************************************************************
  Phosphor BASIC -- date/time library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  A date is a plain number: a TDateTime, days since 1899-12-30 with the time in
  the fraction (so 45351.5 is noon on 2024-02-29). The CALENDAR is the RTL's --
  leap years, month lengths, encoding and decoding a day -- but the ARITHMETIC is
  not. Before 1899-12-30 a TDateTime is negative and spelled sign-and-magnitude
  (the time of day moves the number DOWN), and DateUtils' arithmetic was written
  for the positive half and patched at the epoch, wrongly, in six places this
  file has met so far: issameday, dayoftheyear, the sixteen distances, the
  increments, the ISO week, and the rounding of a date to the millisecond.
  Every function that moves a date or measures between two therefore works on
  the LINE -- the day and the time of day as two separate parts (Split, Linear)
  -- and writes the sign-and-magnitude spelling once, at the end (Join); every
  function that reads one reads it rounded on the line (Canon). The text
  parsers are this file's own too: the RTL's invent what the text leaves out.
  now/today/tomorrow/yesterday read the clock and take no arguments.

  Most functions cannot fail: a date is a number and almost any number is some
  date. The EIGHTEEN that can are of three kinds.

  Seven take a year, a month or a day as SEPARATE numbers, where the RTL either
  indexed its month table out of bounds or raised with its own words: daysinayear,
  daysinamonth, weeksinayear, encodedate and the three strto* parsers.

  Two, incmonth and incyear, refuse a step that would leave
  0001-01-01..9999-12-31, or that starts from a number outside it.

  And nine TAKE A DATE that the RTL cannot decompose. At or below -693594 -- the
  day before 0001-01-01 -- DecodeDate answers Year=0, Month=0, Day=0 instead of
  refusing, and the functions built on that answer read a month table out of
  bounds, raise, count no day at all, or render text no parser accepts:
  daysinmonth, daysinyear, weeksinyear, weekoftheyear, weekof, weekofthemonth,
  dayoftheyear, datetostr$ and datetimetostr$. They ask SourceOk, the same guard
  incmonth and incyear ask about their starting date.

  Each answers this library's own runtime error with the offending value or the
  range in it, never a wrong number.
******************************************************************************}
unit PhosphorDateTimeLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, DateUtils,
  PhosphorValue, PhosphorErrors, PhosphorRegistry;

procedure RegisterDateTimeFuncs(Reg: TPhosphorRegistry);

implementation

function D0(const A: array of TValue): TDateTime; begin Result := AsDouble(A[0]); end;
function D1(const A: array of TValue): TDateTime; begin Result := AsDouble(A[1]); end;
function I0(const A: array of TValue): Integer; begin Result := ArgI32(A[0]); end;
function I1(const A: array of TValue): Integer; begin Result := ArgI32(A[1]); end;

const
  TwoTo52 = 4503599627370496.0;
  TwoTo62 = 4611686018427387904.0;

{ The day of an instant and its time of day, as the two halves of a line. For
  a number in (-1, 0) the day is 0 (Int answers -0.0, which compares equal),
  which is what DecodeDate says that number is. Int and Frac guard at 2^52 and
  hand back the argument, so no Double can make them signal. }
procedure Split(const D: TDateTime; out ADay, ATime: Double);
begin
  ADay := Int(D);
  ATime := Abs(Frac(D));
end;

{ The spelling of (day, time of day): the inverse of Split for every day the
  calendar holds, and the inverse of Linear at the distances.

  ONE ROUNDING IS ITSELF A SIGN-AND-MAGNITUDE TRAP. A time of day within an ulp
  of 1 rounds the sum to the next integer: on the positive side that is the next
  day's midnight, which is the instant it is closest to; on the negative side
  ADay - ATime rounds to ADay - 1, which SPELLS the midnight of the day BEFORE --
  two days from the right one. Measured by the generated sweep: 2699255 days
  and 72468509 ms after the epoch, moved back by exactly the milliseconds that
  reach 0001-01-01 00:00, answered -693595 -- a day below the calendar, which
  rendered as 0000-00-00. The instant is the next midnight, so that is what is
  written. }
function Join(const ADay, ATime: Double): TDateTime;
begin
  if ADay >= 0 then Exit(ADay + ATime);
  Result := ADay - ATime;
  if Result <= ADay - 1 then Result := ADay + 1;
end;

{ A DATE IS READ TO THE MILLISECOND, AND THE ROUNDING IS DONE ON THE LINE
  (2026-10-09, round 2).

  Every renderer and every decomposition reads a TDateTime to the millisecond,
  and the RTL rounds to it in the SPELLING: DecodeDate nudges the number half a
  millisecond away from zero, DateTimeToTimeStamp likewise, and DayOfWeek does
  not round at all. On the positive side "away from zero" is "later", so
  23:59:59.9997 reads as the next day's midnight and every function agrees. On
  the negative side away from zero is "an earlier DAY": 1899-12-29 23:59:59.9997
  is -1.9999999965, the nudge makes it -2.0000000023, and DecodeDate read it as
  1899-12-28 -- two days from the 1899-12-30 midnight it rounds to -- while
  dayofweek, which truncates, said 1899-12-29. Such a number is what the
  arithmetic hands back whenever the true answer is a midnight and the inputs
  were not exactly on the millisecond grid.

  So the functions that read a date are handed this canonical form: the time of
  day rounded half up to a whole millisecond on the line, a 1000th of a second
  that reaches the next midnight carried into the next day, and the spelling
  rebuilt. Its time of day is at most 86399999 ms, so the RTL's half-millisecond
  nudge can no longer cross a midnight in either direction, and DecodeDate,
  DecodeTime and DayOfWeek agree on every number. On the positive side this is
  the RTL's own rounding, so no answer there moves -- except DayOfWeek's for the
  last half millisecond of a day, which now agrees with the date it is on. }
function Canon(const D: TDateTime): TDateTime;
var dd, tt, ms: Double;
begin
  if Abs(D) >= TwoTo52 then Exit(D);
  Split(D, dd, tt);
  ms := Int(tt * MSecsPerDay + 0.5);
  if ms >= MSecsPerDay then
  begin
    ms := 0;
    dd := dd + 1;
  end;
  Result := Join(dd, ms / MSecsPerDay);
end;

function C0(const A: array of TValue): TDateTime; begin Result := Canon(AsDouble(A[0])); end;
function C1(const A: array of TValue): TDateTime; begin Result := Canon(AsDouble(A[1])); end;

{ The representable span as plain numbers, derived in the initialization section
  rather than written down here, so it cannot disagree with TryEncodeDate.
  FirstDay is 0001-01-01; LastMoment is the first instant AFTER 9999-12-31, so a
  date on the last day with a time on it still counts as inside. }
var
  FirstDay, LastMoment: TDateTime;

{ A NUMBER IS NOT A DATE JUST BECAUSE IT IS A NUMBER, and the low end is where
  that bites.

  DecodeDate answers Year=0, Month=0, Day=0 for ANY number at or below -693594 --
  the day before 0001-01-01 -- rather than refusing it (the RTL's own
  rtl/objpas/sysutils/dati.inc:155, `if Date <= -datedelta`). The TOP end of the
  same routine CLAMPS instead, at dati.inc:167, so every function here that takes
  a date already had a defined answer above the range and none at all below it.

  Such a number is easy to hold. incday and incweek are additions with no range
  check of their own -- the long note at incmonth below says why -- so
  `incday(encodedate(1,1,1), -1)` produces one, and a date is a plain number, so
  any literal below the range does too.

  Year 0 is not merely unusual, it is a value the RTL cannot then be asked about.
  DaysInMonth indexes MonthDays with the Month it decoded, and MonthDays is an
  array of TDayTable where TDayTable is indexed 1..12, so Month=0 reads ONE
  ELEMENT BEFORE the table -- the same out-of-bounds read date-time.md records as
  fixed for daysinamonth(2024, 13), reached through the date-TAKING spelling of
  the question, and it lands on the adjacent constant 31, which is why the wrong
  answer looked plausible. WeekOfTheYear, WeekOfTheMonth and WeeksInYear hand
  Year=0 to DateUtils, which raises EConvertError in the RTL's own words about a
  date the program never wrote. DayOfTheYear answers 0, which is no day of any
  year, and DateToStr renders 0000-00-00, which strtodate then refuses -- so
  render and parse stop being inverses.

  Hence ONE guard, called by every function that takes a date and cannot survive
  Year=0, answering this library's own error with the range in it rather than a
  fabricated number, an RTL message or unparseable text. }
function SourceOk(const AFn: String; const D: TDateTime; out E: TPhosphorError): Boolean;
begin
  { THE FIRST DAY IS AN OPEN INTERVAL BELOW ITS OWN MIDNIGHT, because a negative
    TDateTime carries its time of day as a NEGATIVE fraction. Midnight on
    0001-01-01 is -693593, and noon that same day is -693593.5 -- a SMALLER
    number. `D >= FirstDay` therefore refused every instant of the first day
    except midnight, while datetimetostr$, yearof and hourof all agreed it was
    0001-01-01 12:00:00. The library called a value it had just built through its
    own strtodatetime "not a date".

    The high end was written correctly and the low end was not, which is the whole
    lesson: LastMoment is the first instant AFTER the last day precisely so that a
    time on that day counts as inside, and the mirror image at the front needs the
    same widening in the other direction -- to just above -693594, the threshold
    this file's own comment names as where DecodeDate stops answering a real year. }
  Result := (D > FirstDay - 1) and (D < LastMoment);
  if not Result then
    E := MakeError(peRuntime, AFn +
                   ': that number is not a date in 0001-01-01..9999-12-31')
  else
    E := NoError();
end;

// --- decomposition ----------------------------------------------------------
function t_yearof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(YearOf(C0(A))); end;
function t_monthof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(MonthOf(C0(A))); end;
function t_dayof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(DayOf(C0(A))); end;
function t_dayofthemonth(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(DayOfTheMonth(C0(A))); end;
function t_monthoftheyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(MonthOfTheYear(C0(A))); end;
{ COUNTED FROM THE DECOMPOSED DATE, not from arithmetic on the number.

  A TDateTime before 1899-12-30 is negative, and FPC stores such a value as
  sign-and-magnitude: noon on 1850-06-15 is -18095.5 where midnight that day is
  -18095, so the time of day moves the number DOWN. DecodeDate knows this --
  yearof, monthof, dayof and datetostr$ all give the same answer for both -- but
  DateUtils.DayOfTheYear subtracts one TDateTime from another, and the subtraction
  moves the wrong way: it answered 166 at midnight and 165 at noon on the same
  day. Adding up the months is exact and does not care how the number is spelled. }
function t_dayoftheyear(const A: array of TValue; out E: TPhosphorError): TValue;
var y, m, d: Word; i, n: Integer;
begin
  { SourceOk first, or the accumulator runs over a Year=0/Month=0 decomposition
    and answers 0 -- which is no day of any year -- as a clean success. }
  Result := ValInt(0);
  if not SourceOk('dayoftheyear', C0(A), E) then Exit;
  DecodeDate(C0(A), y, m, d);
  n := d;
  for i := 1 to Integer(m) - 1 do
    n := n + DaysInAMonth(y, i);
  Result := ValInt(n);
end;

// --- week-day: two bases ----------------------------------------------------
function t_dayofweek(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(DayOfWeek(C0(A))); end;         // Sunday = 1
function t_dayoftheweek(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(DayOfTheWeek(C0(A))); end;      // ISO: Monday = 1

// --- leap years and month lengths -------------------------------------------
function t_isinleapyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(Ord(IsInLeapYear(C0(A)))); end;
{ A year or a month that came from the program, checked before it reaches
  DateUtils. DaysInAMonth(2024, 13) indexed the RTL's month table OUT OF BOUNDS and
  returned 65450 as a clean success; WeeksInAYear(0) raised EConvertError with the
  RTL's own words. Both are now the library's error, with the value in it. }
function YearOk(const AFn: String; Y: Integer; out E: TPhosphorError): Boolean;
begin
  Result := (Y >= 1) and (Y <= 9999);
  if not Result then
    E := MakeError(peRuntime, AFn + ': ' + IntToStr(Y) + ' is not a year in 1..9999')
  else
    E := NoError();
end;

function MonthOk(const AFn: String; M: Integer; out E: TPhosphorError): Boolean;
begin
  Result := (M >= 1) and (M <= 12);
  if not Result then
    E := MakeError(peRuntime, AFn + ': ' + IntToStr(M) + ' is not a month in 1..12')
  else
    E := NoError();
end;

{ The day, checked against the length of THAT month in THAT year, so 2023-02-29 is
  refused and 2024-02-29 is not. Call it only after YearOk and MonthOk have passed:
  DaysInAMonth is the same RTL table that answered 65450 for month 13. }
function DayOk(const AFn: String; Y, M, D: Integer; out E: TPhosphorError): Boolean;
var last: Integer;
begin
  last := DaysInAMonth(Y, M);
  Result := (D >= 1) and (D <= last);
  if not Result then
    E := MakeError(peRuntime, AFn + ': ' + IntToStr(D) + ' is not a day in ' +
                   IntToStr(Y) + '-' + Format('%.2d', [M]) + ', which has ' +
                   IntToStr(last))
  else
    E := NoError();
end;

function t_daysinayear(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  if not YearOk('daysinayear', I0(A), E) then Exit;
  Result := ValInt(DaysInAYear(I0(A)));
end;
function t_daysinmonth(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  if not SourceOk('daysinmonth', C0(A), E) then Exit;
  Result := ValInt(DaysInMonth(C0(A)));
end;
function t_daysinamonth(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  if not YearOk('daysinamonth', I0(A), E) then Exit;
  if not MonthOk('daysinamonth', I1(A), E) then Exit;
  Result := ValInt(DaysInAMonth(I0(A), I1(A)));
end;

// --- time-of-day ------------------------------------------------------------
function t_hourof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(HourOf(C0(A))); end;
function t_minuteof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(MinuteOf(C0(A))); end;
function t_secondof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(SecondOf(C0(A))); end;
// FPC's DateUtils has no IsAM/IsPM; the clock half is decided by the hour.
function t_isam(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(Ord(HourOf(C0(A)) < 12)); end;
function t_ispm(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(Ord(HourOf(C0(A)) >= 12)); end;
{ THE SAME DAY IS THE SAME YEAR, MONTH AND DAY -- compared as numbers, so the
  answer cannot depend on which argument came first.

  DateUtils.IsSameDay asks whether B falls in the interval [DateOf(A), DateOf(A)+1),
  and on a negative TDateTime the next day is one LESS, not one more. The result
  was both wrong and asymmetric: a pre-1900 timestamp was not the same day as
  ITSELF, while swapping the arguments answered 1. }
function t_issameday(const A: array of TValue; out E: TPhosphorError): TValue;
{ Named ya/ma/da, not y1/m1/d1: Pascal is case-insensitive, so a local `d1`
  SHADOWS the D1 helper at the top of this unit and `D1(A)` stops parsing --
  and a `c1` would shadow C1, which is what this function reads now. }
var ya, ma, da, yb, mb, db: Word;
begin
  E := NoError();
  DecodeDate(C0(A), ya, ma, da);
  DecodeDate(C1(A), yb, mb, db);
  Result := ValInt(Ord((ya = yb) and (ma = mb) and (da = db)));
end;

// --- weeks ------------------------------------------------------------------
{ All three RAISED for a below-range number, in the RTL's words about a date the
  program never wrote ("0-1-1 is not a valid date specification"). SourceOk turns
  that into this library's own refusal, naming the function the script called.

  THE ISO WEEK IS COUNTED ON DAY NUMBERS, never by subtracting two spelled
  dates -- the lesson dayoftheyear and issameday already carry (2026-10-09,
  round 2).
  DateUtils.DecodeDateWeek counts the day of the year as Trunc(AValue - YS) + 1,
  a subtraction of two sign-and-magnitude numbers: before 1899-12-30 a time of
  day moved the answer one day EARLY, so a Monday carrying one fell back to the
  Sunday and answered the PREVIOUS week -- 1850-06-17 was week 25 at midnight
  and week 24 at noon, and 1600-01-03 00:00:00.001 week 52 of the year before.

  ISO 8601's own rule, on DAY NUMBERS -- integers, which are a line on both
  sides of the epoch: a week runs Monday to Sunday and belongs to the year that
  holds its Thursday, and is that Thursday's (day of that year - 1) div 7 + 1.
  The day is Trunc(D), the day DecodeDate reads once D is read to the
  millisecond (C0), and the weekday is DayOfTheWeek, which reads the same
  Trunc. Neither end of the calendar sends the Thursday outside it: 0001-01-01
  is a Monday, 9999-12-31 a Friday. }
function IsoWeek(const D: TDateTime): Integer;
var day, thu, jan1: Int64; ty, tm, td: Word; first: TDateTime;
begin
  day := Trunc(D);
  thu := day + 4 - DayOfTheWeek(D);
  DecodeDate(thu, ty, tm, td);
  if not TryEncodeDate(ty, 1, 1, first) then Exit(0);   // unreachable: see above
  jan1 := Trunc(first);
  Result := (thu - jan1) div 7 + 1;
end;

function t_weekoftheyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  if not SourceOk('weekoftheyear', C0(A), E) then Exit;
  Result := ValInt(IsoWeek(C0(A)));
end;
function t_weekof(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  if not SourceOk('weekof', C0(A), E) then Exit;
  Result := ValInt(IsoWeek(C0(A)));    // answers the same
end;
function t_weekofthemonth(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  if not SourceOk('weekofthemonth', C0(A), E) then Exit;
  Result := ValInt(WeekOfTheMonth(C0(A)));
end;
function t_weeksinayear(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  if not YearOk('weeksinayear', I0(A), E) then Exit;
  Result := ValInt(WeeksInAYear(I0(A)));
end;

// --- construction -----------------------------------------------------------
{ encodedate(y, m, d) -- the constructor the library did not have.

  Everything else here takes a date APART. To build one from three numbers a
  program had to assemble ISO text and hand it to strtodate, which turns an
  arithmetic question into a string question: the day range is then checked by a
  PARSER, and a wrong day comes back described as bad text rather than as a day
  that does not exist in that month.

  TryEncodeDate, not EncodeDate: it answers False where EncodeDate raises, so the
  refusal becomes this library's own error carrying the value that was wrong --
  the shape daysinamonth and weeksinayear already use.

  The parts are checked as INTEGERS before they are narrowed. TryEncodeDate takes
  Word, so year 65537 would arrive as 1 and encode a real date in the year 1; the
  cast is safe only once YearOk, MonthOk and DayOk have run. }
function t_encodedate(const A: array of TValue; out E: TPhosphorError): TValue;
var y, m, d: Integer; r: TDateTime;
begin
  Result := ValInt(0);
  y := I0(A); m := I1(A); d := ArgI32(A[2]);
  if not YearOk('encodedate', y, E) then Exit;
  if not MonthOk('encodedate', m, E) then Exit;
  if not DayOk('encodedate', y, m, d, E) then Exit;
  { Cannot fail once the three checks above pass -- but a guard that depends on
    that reasoning staying true is worth its two lines. }
  if not TryEncodeDate(Word(y), Word(m), Word(d), r) then
  begin
    E := MakeError(peRuntime, 'encodedate: ' + IntToStr(y) + '-' +
                   Format('%.2d-%.2d', [m, d]) + ' is not a date');
    Exit;
  end;
  E := NoError();
  Result := ValDouble(r);
end;

// --- incrementing -----------------------------------------------------------
{ EVERY STEP IS TAKEN ON A LINE, and the sign-and-magnitude spelling is written
  once, at the end (2026-10-09, round 2).

  This is the fourth appearance of the class the distance functions below were
  fixed for. A TDateTime before 1899-12-30 carries its time of day as a
  NEGATIVE fraction, so the number is not a line, and DateUtils' increments
  are additions on it, patched at the epoch by MaybeSkipTimeWarp
  (fpc/3.2.2/packages/rtl-objpas/src/inc/dateutil.inc, MaybeSkipTimeWarp).
  The patch nudges by TDateTimeEpsilon, 2.2e-16, which is LOST in any sum of
  magnitude 2 or more -- so incday(1899-12-29, 6) answered 1900-01-05 and
  incweek(1899-12-20, 2) 1900-01-04, a midnight one day too far, whenever the
  step crossed the epoch. And the step itself was an Integer: ArgI32 is right
  for an index and wrong for a quantity, so 2^31 minutes from 2000-01-01 came
  back as 2^31 - 1 minutes, and 1e300 weeks as 2^31 - 1 weeks, without a word.

  So an instant is taken apart into the two things it means -- the DAY, an
  integer, and the TIME OF DAY, a fraction in [0, 1) -- which is the
  decomposition DecodeDate and DecodeTime themselves use, so it agrees with
  yearof, hourof and datetimetostr$ by construction. A step of whole days moves
  the day and leaves the time alone; a step of hours, minutes, seconds or
  milliseconds is split into whole days and a remainder (Int64 div and mod,
  both exact) and the remainder is added to the time of day with one carry.
  Only then is the spelling rebuilt: day + time at or after the epoch, day -
  time before it.

  THE STEP IS A QUANTITY. Below 2^62 it is the Int64 every other count is
  (ArgI64: an integer exactly, a fraction rounded as before); at or above, it
  is the Double the program wrote, added as it is -- far outside the calendar
  either way, and the answer is the plain sum rather than a clipped step. A sum
  past the largest Double is not answered at all: the engine's finiteness gate
  refuses every library result that is not a number, this one included.

  What the result may then be is unchanged and documented: incday and incweek
  -- and now the four finer steps, which are the same kind of addition -- do
  not refuse a sum outside 0001-01-01..9999-12-31; the nine date-taking
  functions do. }
{ A point on the line (see Linear, at the distances) back to the spelling.
  Past 2^52 a Double holds no fraction, and the number is its own spelling --
  an infinity included, which is then the finiteness gate's to refuse; the
  guard also keeps `L - day` from ever meeting Inf - Inf. }
function FromLinear(const L: Double): TDateTime;
var dd, tt: Double;
begin
  if Abs(L) >= TwoTo52 then Exit(L);
  dd := Int(L);
  tt := L - dd;
  if tt < 0 then
  begin
    tt := tt + 1;
    dd := dd - 1;
  end;
  Result := Join(dd, tt);
end;

{ A step as a quantity: AExact with the Int64 in N below 2^62, otherwise the
  Double in S. }
procedure StepOf(const V: TValue; out AExact: Boolean; out N: Int64; out S: Double);
begin
  N := 0;
  S := AsDouble(V);
  AExact := (V.Kind = vkInt) or (Abs(S) < TwoTo62);
  if AExact then N := ArgI64(V);
end;

function Linear(const D: TDateTime): Double; forward;

{ D moved by a step of ADays whole days each (1 for incday, 7 for incweek). }
function MoveDays(const D: TDateTime; const V: TValue; ADays: Integer): TDateTime;
var dd, tt, s: Double; exact: Boolean; n: Int64;
begin
  StepOf(V, exact, n, s);
  if exact then s := n;
  Split(D, dd, tt);
  dd := dd + s * ADays;
  if Abs(dd) >= TwoTo52 then Exit(dd);
  Result := Join(dd, tt);
end;

{ D moved by a step of units, APerDay of which make a day (24, 1440, 86400 or
  86400000). The whole days and the remainder are separated in Int64 before any
  Double sees them, so the time of day only ever receives less than one day. }
function MoveUnits(const D: TDateTime; const V: TValue; APerDay: Int64): TDateTime;
var dd, tt, s: Double; exact: Boolean; n, q, r: Int64;
begin
  StepOf(V, exact, n, s);
  if not exact then
    Exit(FromLinear(Linear(D) + s / APerDay));
  q := n div APerDay;              // both truncate toward zero, so r has n's sign
  r := n mod APerDay;
  Split(D, dd, tt);
  dd := dd + q;
  tt := tt + r / APerDay;
  if tt >= 1 then
  begin
    tt := tt - 1;
    dd := dd + 1;
  end
  else if tt < 0 then
  begin
    tt := tt + 1;
    dd := dd - 1;
    { -1e-20 + 1 rounds to exactly 1: a moment a hair before midnight is
      midnight, and midnight belongs to the next day. }
    if tt >= 1 then
    begin
      tt := 0;
      dd := dd + 1;
    end;
  end;
  if Abs(dd) >= TwoTo52 then Exit(dd);
  Result := Join(dd, tt);
end;

function t_incday(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(MoveDays(D0(A), A[1], 1)); end;
function t_incweek(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(MoveDays(D0(A), A[1], 7)); end;

{ Off-the-end, restated.

  incmonth and incyear are the two increments that are NOT arithmetic on the
  number: a day is 1 and a week is 7, so incday and incweek are additions, but a
  month is 28, 29, 30 or 31, so the RTL takes the date apart, moves the field and
  re-encodes. A step past either end therefore does not answer a wrong date -- it
  RAISES, in the RTL's own words: incyear on 9999-06-15 aborted a program with
  `Invalid date/timestamp : "10000/06/15 00:00:00,000"`. That is the one thing the
  header of this file promises never reaches a program, so it is caught and
  restated with the step that went off the end.

  incday and incweek are NOT given the same treatment, because they do not raise
  -- they answer a number outside the representable range. What that number then
  means depends on which door it reaches. The nine date-taking functions listed
  in this file's header ask SourceOk and refuse it by name. yearof, monthof,
  dayof and formatdatetime$ do not: they still hand it to DecodeDate, which
  clamps the top end back to 9999-12-31 and reports it as if it were real, and
  answers year 0 below the range. That remaining half is a wider defect and
  belongs to the whole library rather than to these two functions.

  AND THE TWO FAIL DIFFERENTLY, which is why neither can be guarded by catching.
  incyear raises. incmonth does NOT: its re-encode answers 0 on failure without a
  word, so incmonth(9999-06-15, 12) came back as 1899-12-30 -- a plausible date,
  silently wrong, the worst of the three outcomes. The step is therefore REFUSED
  in advance, by computing the year it lands in. }
function SteppedOff(const AFn: String; const ABy: TValue; const AUnit: String;
                    out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  E := MakeError(peRuntime, AFn + ': ' + ValToStr(ABy) + ' ' + AUnit +
                 ' from that date leaves 0001-01-01..9999-12-31');
end;

{ The month count a step names, judged before anything is computed from it. A
  step is a QUANTITY (see the note at incday), so it is read whole rather than
  narrowed to an Integer; but the whole calendar is 9999 * 12 = 119988 months
  long, so a step of more than that from any date inside it leaves it, and
  refusing those here keeps every later sum far from Int64's edge. }
function MonthCount(const V: TValue; AMonthsPerUnit: Integer; out AMonths: Int64): Boolean;
var exact: Boolean; n: Int64; s: Double;
begin
  StepOf(V, exact, n, s);
  AMonths := 0;
  Result := exact and (Abs(n) <= 119988 div AMonthsPerUnit);
  if Result then AMonths := n * AMonthsPerUnit;
end;

{ incmonth and incyear: the date moved by a number of months, the day CLAMPED
  to the length of the month it lands in -- 31 January plus one month is 28
  February, or the 29th in a leap year, and 29 February plus a year is the
  28th -- and the time of day carried through EXACTLY, as the second half of
  the line. Both used to go to the RTL: IncMonth composed correctly, but
  IncYear decoded the time to the millisecond and rebuilt it (a fraction of a
  millisecond was lost), and on a pre-1900 moment a hair before midnight its
  rounding fallback, DecodeDate(Round(AValue)), rounded the sign-and-magnitude
  number to the PREVIOUS day. One routine now does both.

  The year a step lands in is computed first, so a step that leaves the
  calendar is refused by name and nothing is encoded: the RTL's IncMonth
  answers 1899-12-30 for a date it cannot encode, without a word, and its
  IncYear raised. }
function MoveMonths(const AFn, AUnit: String; const D: TDateTime; const V: TValue;
                    AMonthsPerUnit: Integer; out E: TPhosphorError): TValue;
var y, m, dd: Word; months, tot, ty, tm, last: Int64; day: TDateTime;
begin
  Result := ValInt(0);
  if not SourceOk(AFn, D, E) then Exit;
  if not MonthCount(V, AMonthsPerUnit, months) then
    Exit(SteppedOff(AFn, V, AUnit, E));
  DecodeDate(D, y, m, dd);
  tot := Int64(y) * 12 + (Int64(m) - 1) + months;
  ty := tot div 12;
  tm := tot mod 12;
  if tm < 0 then begin Inc(tm, 12); Dec(ty); end;   // div and mod truncate
  if (ty < 1) or (ty > 9999) then
    Exit(SteppedOff(AFn, V, AUnit, E));
  last := DaysInAMonth(Word(ty), Word(tm + 1));
  if dd > last then dd := Word(last);
  if not TryEncodeDate(Word(ty), Word(tm + 1), dd, day) then
    Exit(SteppedOff(AFn, V, AUnit, E));
  E := NoError();
  Result := ValDouble(Join(day, Abs(Frac(D))));
end;

function t_incmonth(const A: array of TValue; out E: TPhosphorError): TValue;
begin Result := MoveMonths('incmonth', 'months', C0(A), A[1], 1, E); end;
function t_incyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin Result := MoveMonths('incyear', 'years', C0(A), A[1], 12, E); end;

// --- distances --------------------------------------------------------------
{ MEASURED ON A CONTINUUM, because a TDateTime is not one.

  This is the third appearance of the defect class this file already documents
  twice -- at dayoftheyear and at issameday. A TDateTime before 1899-12-30 is
  negative and FPC stores it SIGN-AND-MAGNITUDE: the date is Trunc(D) and the
  time of day is Abs(Frac(D)), so noon on 1850-06-15 is -18095.5 where midnight
  that day is -18095. The time of day moves the number DOWN. Subtract two such
  numbers and the answer is wrong by twice the time of day:

      a = strtodatetime("1850-06-15 12:00:00")
      b = strtodatetime("1850-06-16 00:00:00")
      inchour(a, 12) = b         -> TRUE, bit for bit: the gap is twelve hours
      hoursbetween(a, b)         -> 36        (this library, before)
      dayspan(a, b)              -> 1.5

  and for a pair that STRADDLES the epoch it was also asymmetric, which
  docs/libraries/date-time.md says cannot happen ("Both are non-negative: the
  order of the arguments does not matter"): hoursbetween(q, p) answered 12 where
  hoursbetween(p, q) answered 24 for the same two moments.

  The cause is in the RTL and it is not fixable pair by pair. DateUtils.
  DateTimeDiff (fpc/3.2.2/packages/rtl-objpas/src/inc/dateutil.inc:1354) is a raw
  `ANow - AThen` plus a blanket half-day fudge applied only when the pair
  straddles the epoch -- and applied not at all when both dates are negative. The
  fudge happens to be exactly right when the time of day is 06:00 and wrong
  everywhere else. (DaysBetween alone escapes the asymmetry half, because it
  normalises the argument order first -- dateutil.inc:1407, marked "bug 37361".
  The other fifteen were never given that patch.)

  So the fix has the shape the two earlier ones have: do not subtract the
  sign-and-magnitude numbers. Linear maps a TDateTime onto a scale where the time
  of day always moves the number UP -- Int(D) + Abs(Frac(D)) -- which is the same
  decomposition DecodeDate and DecodeTime use, so it agrees with yearof, dayof,
  datetimetostr$ and inchour by construction. Both halves are exact: for a
  TDateTime (|D| < 2^22) the sum needs 53 bits at most, and for D >= 0 it is
  bit-for-bit D, which is why every distance between two dates at or after the
  epoch answers exactly what it answered before.

  Int and Frac, not Trunc: both guard at 2^52 and return the argument above it
  (rtl/x86_64/math.inc:361 and :392), so neither can be handed a Double too big
  for the cvttsd2si they wrap. Trunc would signal on a program that passed 1e30
  as a date.

  The sixteen formulas below are then the RTL's own, unchanged and reading from
  the same constants, so the truncation and the half-millisecond rounding are
  what they always were. The only thing replaced is the distance they measure. }
function Linear(const D: TDateTime): Double;   // declared forward at incday
begin
  Result := Int(D) + Abs(Frac(D));
end;

function DistDays(const A, B: TDateTime): Double;
begin
  Result := Abs(Linear(A) - Linear(B));
end;

const
  // dateutil.inc's own private constant, spelled the same way it spells it.
  HalfMilliSecond = OneMillisecond / 2;

function t_daysbetween(const A: array of TValue; out E: TPhosphorError): TValue;
var r: Integer;    // DaysBetween's own return type, so it narrows where it did
begin
  E := NoError();
  r := Trunc(DistDays(D0(A), D1(A)) + HalfMilliSecond);
  Result := ValInt(r);
end;
function t_dayspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(DistDays(D0(A), D1(A))); end;
function t_hoursbetween(const A: array of TValue; out E: TPhosphorError): TValue;
var r: Int64;
begin
  E := NoError();
  r := Trunc((DistDays(D0(A), D1(A)) + HalfMilliSecond) * HoursPerDay);
  Result := ValInt(r);
end;
function t_minutesbetween(const A: array of TValue; out E: TPhosphorError): TValue;
var r: Int64;
begin
  E := NoError();
  r := Trunc((DistDays(D0(A), D1(A)) + HalfMilliSecond) * MinsPerDay);
  Result := ValInt(r);
end;
function t_secondsbetween(const A: array of TValue; out E: TPhosphorError): TValue;
var r: Int64;
begin
  E := NoError();
  r := Trunc((DistDays(D0(A), D1(A)) + HalfMilliSecond) * SecsPerDay);
  Result := ValInt(r);
end;

// --- the clock (no arguments) -----------------------------------------------
function t_now(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Now); end;
function t_today(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Date); end;
function t_tomorrow(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Tomorrow); end;
function t_yesterday(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Yesterday); end;
{ Through the decomposition, as issameday is: DateUtils.IsToday is IsSameDay,
  the subtraction whose pre-1900 asymmetry issameday's note records. Today is
  never before 1900, so the old answer was right -- by that accident only. }
function t_istoday(const A: array of TValue; out E: TPhosphorError): TValue;
var ya, ma, da, yb, mb, db: Word;
begin
  E := NoError();
  DecodeDate(C0(A), ya, ma, da);
  DecodeDate(Date, yb, mb, db);
  Result := ValInt(Ord((ya = yb) and (ma = mb) and (da = db)));
end;

// --- ISO 8601 rendering and parsing -----------------------------------------
// Phosphor's date strings are ISO 8601 (yyyy-mm-dd, hh:nn:ss), fixed rather than
// locale-following, so the same text parses and renders the same on any machine
// -- render/parse are exact inverses and a hard-coded "2020-06-15" is read the
// same everywhere. (The reference used the machine's locale format.)
var
  ISOFS: TFormatSettings;

{ RENDER AND PARSE ARE EXACT INVERSES, and below the range they were not: a
  number at or under -693594 decomposes to Year=0, Month=0, Day=0 and rendered as
  "0000-00-00", which strtodate then refuses as invalid text. The two renderers
  that carry a DATE therefore ask SourceOk; timetostr$ does not, because it reads
  only the fraction and every number has one. }
function t_datetostr(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValStr('');
  if not SourceOk('datetostr$', C0(A), E) then Exit;
  Result := ValStr(DateToStr(C0(A), ISOFS));
end;
function t_timetostr(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(TimeToStr(C0(A), ISOFS)); end;
function t_datetimetostr(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValStr('');
  if not SourceOk('datetimetostr$', C0(A), E) then Exit;
  Result := ValStr(DateTimeToStr(C0(A), ISOFS));
end;
function t_date_s(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(DateToStr(Date, ISOFS)); end;
function t_time_s(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(TimeToStr(Time, ISOFS)); end;
function t_datetime_s(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(DateTimeToStr(Now, ISOFS)); end;
function t_formatdatetime(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(FormatDateTime(A[0].Str, C1(A), ISOFS)); end;

{ THE PARSERS READ EXACTLY THE ISO 8601 FORMS date-time.md LISTS, and nothing
  is completed by a guess (2026-10-09, round 2).

  They used to be the RTL's StrToDate/StrToTime/StrToDateTime under pinned ISO
  separators, and the RTL is a LENIENT reader that fills in what is missing:
  "0-6-15" was 2000-06-15 and "20-06-15" 2020-06-15 (a two-digit year is
  pivoted into a century), "06-15" was June 15 of the CURRENT year and "10" the
  10th of the current month -- the same text a different number on a different
  day -- "1:2" was 01:02, "10:20:30 PM" 22:20:30, and strtodatetime took a time
  alone as a time on 1899-12-30. A date that arrives as text is data from
  somewhere, and a parser that invents its missing parts turns a malformed
  record into a plausible wrong one.

  So the grammar is written here, and it is the one the renderers write:
    date      yyyy-mm-dd            four digits, two, two; 0001-01-01..9999-12-31
    time      hh:nn  or  hh:nn:ss   two digits each; 00:00..23:59:59
    datetime  date, or date + one blank + time
  -- the date alone because datetimetostr$ renders a midnight that way, and
  render and parse are inverses. No blank at either end, no 'T', no fraction of
  a second, no sign. The day is checked against the month it is in.

  The numbers are built by the RTL's own TryEncodeDate/TryEncodeTime and joined
  as the sign-and-magnitude spelling, so every accepted text answers exactly
  what it answered before. }
{ Two decimal digits at S[P], S[P+1]; four are two pairs. Every field of the
  grammar is two or four digits wide, so there is no loop to bound. }
function TwoDigits(const S: String; P: Integer; out V: Integer): Boolean;
begin
  V := 0;
  Result := (P >= 1) and (P + 1 <= Length(S)) and
            (S[P] in ['0'..'9']) and (S[P + 1] in ['0'..'9']);
  if Result then V := (Ord(S[P]) - Ord('0')) * 10 + (Ord(S[P + 1]) - Ord('0'));
end;

function DigitsAt(const S: String; P, N: Integer; out V: Integer): Boolean;
var hi, lo: Integer;
begin
  if N = 2 then Exit(TwoDigits(S, P, V));
  V := 0;
  Result := (N = 4) and TwoDigits(S, P, hi) and TwoDigits(S, P + 2, lo);
  if Result then V := hi * 100 + lo;
end;

{ yyyy-mm-dd at S[P..P+9]. The caller has checked the length. }
function DateAt(const S: String; P: Integer; out D: TDateTime): Boolean;
var y, m, dd: Integer;
begin
  Result := False;
  D := 0;
  if not DigitsAt(S, P, 4, y) or (S[P + 4] <> '-') then Exit;
  if not DigitsAt(S, P + 5, 2, m) or (S[P + 7] <> '-') then Exit;
  if not DigitsAt(S, P + 8, 2, dd) then Exit;
  if (y < 1) or (m < 1) or (m > 12) or (dd < 1) then Exit;
  if dd > DaysInAMonth(Word(y), Word(m)) then Exit;
  Result := TryEncodeDate(Word(y), Word(m), Word(dd), D);
end;

{ hh:nn or hh:nn:ss, and nothing else, from S[P] to the end. }
function TimeFrom(const S: String; P: Integer; out T: TDateTime): Boolean;
var len, h, n, sec: Integer;
begin
  Result := False;
  T := 0;
  len := Length(S) - P + 1;
  if (len <> 5) and (len <> 8) then Exit;
  if not DigitsAt(S, P, 2, h) or (S[P + 2] <> ':') then Exit;
  if not DigitsAt(S, P + 3, 2, n) then Exit;
  sec := 0;
  if len = 8 then
    if (S[P + 5] <> ':') or not DigitsAt(S, P + 6, 2, sec) then Exit;
  if (h > 23) or (n > 59) or (sec > 59) then Exit;
  Result := TryEncodeTime(Word(h), Word(n), Word(sec), 0, T);
end;

{ The text, quoted, when it is short printable ASCII -- anything else could
  carry a control byte or a cut UTF-8 sequence into an error message -- and
  otherwise just "that text". }
function Cited(const S: String): String;
var i: Integer;
begin
  Result := 'that text';
  if Length(S) > 40 then Exit;
  for i := 1 to Length(S) do
    if (S[i] < ' ') or (S[i] > '~') then Exit;
  Result := '"' + S + '"';
end;

function t_strtodate(const A: array of TValue; out E: TPhosphorError): TValue;
var d: TDateTime;
begin
  Result := ValInt(0);
  if (Length(A[0].Str) <> 10) or not DateAt(A[0].Str, 1, d) then
  begin
    E := MakeError(peRuntime, 'invalid date: ' + Cited(A[0].Str) +
                   ' is not a yyyy-mm-dd date in 0001-01-01..9999-12-31');
    Exit;
  end;
  E := NoError(); Result := ValDouble(d);
end;
function t_strtotime(const A: array of TValue; out E: TPhosphorError): TValue;
var t: TDateTime;
begin
  Result := ValInt(0);
  if not TimeFrom(A[0].Str, 1, t) then
  begin
    E := MakeError(peRuntime, 'invalid time: ' + Cited(A[0].Str) +
                   ' is not an hh:nn or hh:nn:ss time in 00:00..23:59:59');
    Exit;
  end;
  E := NoError(); Result := ValDouble(t);
end;
function t_strtodatetime(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; d, t: TDateTime; ok: Boolean;
begin
  Result := ValInt(0);
  s := A[0].Str;
  t := 0;
  ok := (Length(s) >= 10) and DateAt(s, 1, d);
  if ok and (Length(s) > 10) then
    ok := (s[11] = ' ') and TimeFrom(s, 12, t);
  if not ok then
  begin
    E := MakeError(peRuntime, 'invalid datetime: ' + Cited(s) +
                   ' is not yyyy-mm-dd, yyyy-mm-dd hh:nn or yyyy-mm-dd hh:nn:ss');
    Exit;
  end;
  E := NoError(); Result := ValDouble(Join(d, t));
end;

// --- the clock (no arguments) -----------------------------------------------
function t_date(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Date); end;
function t_time(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Time); end;
function t_gettime(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Now); end;

// --- finer increments -------------------------------------------------------
// On the line, like incday: see the note there. The RTL's four took an Int64
// step but were handed ArgI32's, and their negative-date path
// (IncNegativeTime) is followed by the same MaybeSkipTimeWarp.
function t_inchour(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(MoveUnits(D0(A), A[1], 24)); end;
function t_incminute(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(MoveUnits(D0(A), A[1], 1440)); end;
function t_incsecond(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(MoveUnits(D0(A), A[1], 86400)); end;
function t_incmillisecond(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(MoveUnits(D0(A), A[1], 86400000)); end;

// --- year lengths taking a date ---------------------------------------------
{ The date-TAKING half of the pair whose year-taking half daysinayear/weeksinayear
  has been guarded since the 65450 defect. Below the range daysinyear answered 366
  for the fictitious year 0 and weeksinyear raised. }
function t_daysinyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  if not SourceOk('daysinyear', C0(A), E) then Exit;
  Result := ValInt(DaysInYear(C0(A)));
end;
function t_weeksinyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  if not SourceOk('weeksinyear', C0(A), E) then Exit;
  Result := ValInt(WeeksInYear(C0(A)));
end;

// --- more distances ---------------------------------------------------------
// The same substitution as the five above: the RTL's formula, over Linear's
// distance instead of DateTimeDiff's. See the long note at t_daysbetween.
function t_weeksbetween(const A: array of TValue; out E: TPhosphorError): TValue;
var r: Integer;
begin
  E := NoError();
  r := Trunc(DistDays(D0(A), D1(A)) + HalfMilliSecond) div 7;
  Result := ValInt(r);
end;
function t_monthsbetween(const A: array of TValue; out E: TPhosphorError): TValue;
var r: Integer;
begin
  // AExact is False here, as it is in the call this replaces, so it is the
  // approximate branch -- 30.4375 days to a month, the RTL's own constant.
  E := NoError();
  r := Trunc((DistDays(D0(A), D1(A)) + HalfMilliSecond) / ApproxDaysPerMonth);
  Result := ValInt(r);
end;
function t_yearsbetween(const A: array of TValue; out E: TPhosphorError): TValue;
var r: Integer;
begin
  E := NoError();
  r := Trunc((DistDays(D0(A), D1(A)) + HalfMilliSecond) / ApproxDaysPerYear);
  Result := ValInt(r);
end;
function t_millisecondsbetween(const A: array of TValue; out E: TPhosphorError): TValue;
var r: Int64;
begin
  E := NoError();
  r := Trunc((DistDays(D0(A), D1(A)) + HalfMilliSecond) * MSecsPerDay);
  Result := ValInt(r);
end;

// --- spans (fractional distances) -------------------------------------------
function t_hourspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(DistDays(D0(A), D1(A)) * HoursPerDay); end;
function t_minutespan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(DistDays(D0(A), D1(A)) * MinsPerDay); end;
function t_secondspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(DistDays(D0(A), D1(A)) * SecsPerDay); end;
function t_millisecondspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(DistDays(D0(A), D1(A)) * MSecsPerDay); end;
function t_weekspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(DistDays(D0(A), D1(A)) / 7); end;
function t_monthspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(DistDays(D0(A), D1(A)) / ApproxDaysPerMonth); end;
function t_yearspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(DistDays(D0(A), D1(A)) / ApproxDaysPerYear); end;

function t_millisecondof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(MilliSecondOf(C0(A))); end;

procedure RegisterDateTimeFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('yearof:n',          @t_yearof);
  Reg.Add('monthof:n',         @t_monthof);
  Reg.Add('dayof:n',           @t_dayof);
  Reg.Add('dayofthemonth:n',   @t_dayofthemonth);
  Reg.Add('monthoftheyear:n',  @t_monthoftheyear);
  Reg.Add('dayoftheyear:n',    @t_dayoftheyear);
  Reg.Add('dayofweek:n',       @t_dayofweek);
  Reg.Add('dayoftheweek:n',    @t_dayoftheweek);
  Reg.Add('isinleapyear:n',    @t_isinleapyear);
  Reg.Add('daysinayear:n',     @t_daysinayear);
  Reg.Add('daysinmonth:n',     @t_daysinmonth);
  Reg.Add('daysinamonth:nn',   @t_daysinamonth);
  Reg.Add('hourof:n',          @t_hourof);
  Reg.Add('minuteof:n',        @t_minuteof);
  Reg.Add('secondof:n',        @t_secondof);
  Reg.Add('isam:n',            @t_isam);
  Reg.Add('ispm:n',            @t_ispm);
  Reg.Add('issameday:nn',      @t_issameday);
  Reg.Add('weekoftheyear:n',   @t_weekoftheyear);
  Reg.Add('weekof:n',          @t_weekof);
  Reg.Add('weekofthemonth:n',  @t_weekofthemonth);
  Reg.Add('weeksinayear:n',    @t_weeksinayear);
  Reg.Add('encodedate:nnn',    @t_encodedate);
  Reg.Add('incday:nn',         @t_incday);
  Reg.Add('incweek:nn',        @t_incweek);
  Reg.Add('incmonth:nn',       @t_incmonth);
  Reg.Add('incyear:nn',        @t_incyear);
  Reg.Add('daysbetween:nn',    @t_daysbetween);
  Reg.Add('dayspan:nn',        @t_dayspan);
  Reg.Add('hoursbetween:nn',   @t_hoursbetween);
  Reg.Add('minutesbetween:nn', @t_minutesbetween);
  Reg.Add('secondsbetween:nn', @t_secondsbetween);
  Reg.Add('now:',              @t_now);
  Reg.Add('today:',            @t_today);
  Reg.Add('tomorrow:',         @t_tomorrow);
  Reg.Add('yesterday:',        @t_yesterday);
  Reg.Add('istoday:n',         @t_istoday);
  // string rendering and parsing (ISO 8601)
  Reg.Add('datetostr$:n',      @t_datetostr);
  Reg.Add('timetostr$:n',      @t_timetostr);
  Reg.Add('datetimetostr$:n',  @t_datetimetostr);
  Reg.Add('date$:',            @t_date_s);
  Reg.Add('time$:',            @t_time_s);
  Reg.Add('datetime$:',        @t_datetime_s);
  Reg.Add('formatdatetime$:$n',@t_formatdatetime);
  Reg.Add('strtodate:$',       @t_strtodate);
  Reg.Add('strtotime:$',       @t_strtotime);
  Reg.Add('strtodatetime:$',   @t_strtodatetime);
  // the clock
  Reg.Add('date:',             @t_date);
  Reg.Add('time:',             @t_time);
  Reg.Add('gettime:',          @t_gettime);
  // finer increments
  Reg.Add('inchour:nn',        @t_inchour);
  Reg.Add('incminute:nn',      @t_incminute);
  Reg.Add('incsecond:nn',      @t_incsecond);
  Reg.Add('incmillisecond:nn', @t_incmillisecond);
  // year lengths taking a date
  Reg.Add('daysinyear:n',      @t_daysinyear);
  Reg.Add('weeksinyear:n',     @t_weeksinyear);
  // more distances
  Reg.Add('weeksbetween:nn',   @t_weeksbetween);
  Reg.Add('monthsbetween:nn',  @t_monthsbetween);
  Reg.Add('yearsbetween:nn',   @t_yearsbetween);
  Reg.Add('millisecondsbetween:nn', @t_millisecondsbetween);
  // spans
  Reg.Add('hourspan:nn',       @t_hourspan);
  Reg.Add('minutespan:nn',     @t_minutespan);
  Reg.Add('secondspan:nn',     @t_secondspan);
  Reg.Add('millisecondspan:nn',@t_millisecondspan);
  Reg.Add('weekspan:nn',       @t_weekspan);
  Reg.Add('monthspan:nn',      @t_monthspan);
  Reg.Add('yearspan:nn',       @t_yearspan);
  Reg.Add('millisecondof:n',   @t_millisecondof);
end;

initialization
  { Derived, never written down: whatever TryEncodeDate accepts is the range. }
  TryEncodeDate(1, 1, 1, FirstDay);
  TryEncodeDate(9999, 12, 31, LastMoment);
  LastMoment := LastMoment + 1;      // the first instant AFTER the last day
  ISOFS := DefaultFormatSettings;
  ISOFS.DateSeparator := '-';
  ISOFS.TimeSeparator := ':';
  ISOFS.ShortDateFormat := 'yyyy-mm-dd';
  ISOFS.LongDateFormat := 'yyyy-mm-dd';
  ISOFS.ShortTimeFormat := 'hh:nn:ss';
  ISOFS.LongTimeFormat := 'hh:nn:ss';
  // The separators and patterns were pinned; the NAME ARRAYS were not, so they
  // still came from DefaultFormatSettings -- the machine's locale. formatdatetime$
  // with mmm/mmmm/ddd/dddd answered "junho" here, "June" on an en-US box and "Jun"
  // under a C locale, for the same date. Pinned to English, which is what the ISO
  // formats around them already assume.
  ISOFS.ShortMonthNames[1] := 'Jan';  ISOFS.LongMonthNames[1] := 'January';
  ISOFS.ShortMonthNames[2] := 'Feb';  ISOFS.LongMonthNames[2] := 'February';
  ISOFS.ShortMonthNames[3] := 'Mar';  ISOFS.LongMonthNames[3] := 'March';
  ISOFS.ShortMonthNames[4] := 'Apr';  ISOFS.LongMonthNames[4] := 'April';
  ISOFS.ShortMonthNames[5] := 'May';  ISOFS.LongMonthNames[5] := 'May';
  ISOFS.ShortMonthNames[6] := 'Jun';  ISOFS.LongMonthNames[6] := 'June';
  ISOFS.ShortMonthNames[7] := 'Jul';  ISOFS.LongMonthNames[7] := 'July';
  ISOFS.ShortMonthNames[8] := 'Aug';  ISOFS.LongMonthNames[8] := 'August';
  ISOFS.ShortMonthNames[9] := 'Sep';  ISOFS.LongMonthNames[9] := 'September';
  ISOFS.ShortMonthNames[10] := 'Oct'; ISOFS.LongMonthNames[10] := 'October';
  ISOFS.ShortMonthNames[11] := 'Nov'; ISOFS.LongMonthNames[11] := 'November';
  ISOFS.ShortMonthNames[12] := 'Dec'; ISOFS.LongMonthNames[12] := 'December';
  ISOFS.ShortDayNames[1] := 'Sun'; ISOFS.LongDayNames[1] := 'Sunday';
  ISOFS.ShortDayNames[2] := 'Mon'; ISOFS.LongDayNames[2] := 'Monday';
  ISOFS.ShortDayNames[3] := 'Tue'; ISOFS.LongDayNames[3] := 'Tuesday';
  ISOFS.ShortDayNames[4] := 'Wed'; ISOFS.LongDayNames[4] := 'Wednesday';
  ISOFS.ShortDayNames[5] := 'Thu'; ISOFS.LongDayNames[5] := 'Thursday';
  ISOFS.ShortDayNames[6] := 'Fri'; ISOFS.LongDayNames[6] := 'Friday';
  ISOFS.ShortDayNames[7] := 'Sat'; ISOFS.LongDayNames[7] := 'Saturday';
  ISOFS.DecimalSeparator := '.';
  ISOFS.ThousandSeparator := #0;

end.
