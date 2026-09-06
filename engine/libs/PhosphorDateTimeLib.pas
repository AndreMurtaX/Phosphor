{******************************************************************************
  Phosphor BASIC -- date/time library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  A date is a plain number: a TDateTime, days since 1899-12-30 with the time in
  the fraction (so 45351.5 is noon on 2024-02-29). Every function here is a thin
  wrapper over the RTL's DateUtils/SysUtils, which makes the arithmetic -- leap
  years, ISO weeks, month lengths, clamping IncMonth and IncYear onto a shorter
  month -- the RTL's job rather than ours. now/today/tomorrow/yesterday read the
  clock and take no arguments.

  Most functions cannot fail: a date is a number and almost any number is some
  date. The NINE that can are of two kinds. Six take a year, a month or a day as
  SEPARATE numbers, where the RTL either indexed its month table out of bounds or
  raised with its own words: daysinayear, daysinamonth, weeksinayear, encodedate
  and the three strto* parsers -- that is seven, because strto* is three. And
  incmonth and incyear refuse a step that would leave 0001-01-01..9999-12-31, or
  that starts from a number outside it. Each answers this library's own runtime
  error with the offending value in it, never a wrong number.
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

{ The representable span as plain numbers, derived in the initialization section
  rather than written down here, so it cannot disagree with TryEncodeDate.
  FirstDay is 0001-01-01; LastMoment is the first instant AFTER 9999-12-31, so a
  date on the last day with a time on it still counts as inside. }
var
  FirstDay, LastMoment: TDateTime;

// --- decomposition ----------------------------------------------------------
function t_yearof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(YearOf(D0(A))); end;
function t_monthof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(MonthOf(D0(A))); end;
function t_dayof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(DayOf(D0(A))); end;
function t_dayofthemonth(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(DayOfTheMonth(D0(A))); end;
function t_monthoftheyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(MonthOfTheYear(D0(A))); end;
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
  E := NoError();
  DecodeDate(D0(A), y, m, d);
  n := d;
  for i := 1 to Integer(m) - 1 do
    n := n + DaysInAMonth(y, i);
  Result := ValInt(n);
end;

// --- week-day: two bases ----------------------------------------------------
function t_dayofweek(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(DayOfWeek(D0(A))); end;         // Sunday = 1
function t_dayoftheweek(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(DayOfTheWeek(D0(A))); end;      // ISO: Monday = 1

// --- leap years and month lengths -------------------------------------------
function t_isinleapyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(Ord(IsInLeapYear(D0(A)))); end;
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
begin E := NoError(); Result := ValInt(DaysInMonth(D0(A))); end;
function t_daysinamonth(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  if not YearOk('daysinamonth', I0(A), E) then Exit;
  if not MonthOk('daysinamonth', I1(A), E) then Exit;
  Result := ValInt(DaysInAMonth(I0(A), I1(A)));
end;

// --- time-of-day ------------------------------------------------------------
function t_hourof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(HourOf(D0(A))); end;
function t_minuteof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(MinuteOf(D0(A))); end;
function t_secondof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(SecondOf(D0(A))); end;
// FPC's DateUtils has no IsAM/IsPM; the clock half is decided by the hour.
function t_isam(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(Ord(HourOf(D0(A)) < 12)); end;
function t_ispm(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(Ord(HourOf(D0(A)) >= 12)); end;
{ THE SAME DAY IS THE SAME YEAR, MONTH AND DAY -- compared as numbers, so the
  answer cannot depend on which argument came first.

  DateUtils.IsSameDay asks whether B falls in the interval [DateOf(A), DateOf(A)+1),
  and on a negative TDateTime the next day is one LESS, not one more. The result
  was both wrong and asymmetric: a pre-1900 timestamp was not the same day as
  ITSELF, while swapping the arguments answered 1. }
function t_issameday(const A: array of TValue; out E: TPhosphorError): TValue;
{ Named ya/ma/da, not y1/m1/d1: Pascal is case-insensitive, so a local `d1`
  SHADOWS the D1 helper two dozen lines up and `D1(A)` stops parsing. }
var ya, ma, da, yb, mb, db: Word;
begin
  E := NoError();
  DecodeDate(D0(A), ya, ma, da);
  DecodeDate(D1(A), yb, mb, db);
  Result := ValInt(Ord((ya = yb) and (ma = mb) and (da = db)));
end;

// --- weeks ------------------------------------------------------------------
function t_weekoftheyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(WeekOfTheYear(D0(A))); end;
function t_weekof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(WeekOfTheYear(D0(A))); end;     // answers the same
function t_weekofthemonth(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(WeekOfTheMonth(D0(A))); end;
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
function t_incday(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(IncDay(D0(A), I1(A))); end;
function t_incweek(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(IncWeek(D0(A), I1(A))); end;

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
  -- they answer a number outside the representable range, which datetostr$ and
  yearof then silently clamp back to 9999-12-31 and report as if it were real.
  That is a different defect and a wider one; it belongs to the whole library
  rather than to these two functions.

  AND THE TWO FAIL DIFFERENTLY, which is why neither can be guarded by catching.
  incyear raises. incmonth does NOT: its re-encode answers 0 on failure without a
  word, so incmonth(9999-06-15, 12) came back as 1899-12-30 -- a plausible date,
  silently wrong, the worst of the three outcomes. The step is therefore REFUSED
  in advance, by computing the year it lands in. }
function SteppedOff(const AFn: String; ABy: Integer; const AUnit: String;
                    out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  E := MakeError(peRuntime, AFn + ': ' + IntToStr(ABy) + ' ' + AUnit +
                 ' from that date leaves 0001-01-01..9999-12-31');
end;

{ THE STEP IS ONLY HALF THE QUESTION: the date it starts from has to be a date.

  Checking the target year alone was not enough, and failed in the exact way it
  was written to prevent. DecodeDate answers Year=0, Month=0, Day=0 for ANY number
  at or below -693594 -- the day before 0001-01-01 -- rather than refusing it. The
  accumulator below then starts from that fictitious year 0 and lands inside
  1..9999 for every step of 13 or more, so the guard APPROVED them; the RTL went
  on to re-encode with Day=0, which cannot succeed, and answered 1899-12-30. The
  result was non-monotonic and absurd: incmonth(x, 12) was refused while
  incmonth(x, 13) came back as a silently wrong date.

  Such a number is easy to hold. incday and incweek are additions with no range
  check of their own -- this file says so a few lines up -- so
  `incday(encodedate(1,1,1), -1)` produces one, and a date is a plain number, so
  any literal below the range does too. }
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

{ The year a month step lands in, computed the way the RTL's own IncAMonth
  computes it, so the answer can be judged before the RTL is asked. Int64
  throughout: a year near 9999 times twelve, plus an Integer step, overflows a
  32-bit total -- and an overflow here would approve exactly the call this
  function exists to refuse. `div` truncates toward zero, so a negative remainder
  means the year below. Only meaningful once SourceOk has passed. }
function MonthStepYear(const D: TDateTime; ABy: Integer): Int64;
var y, m, dd: Word; tot: Int64;
begin
  DecodeDate(D, y, m, dd);
  tot := Int64(y) * 12 + (Int64(m) - 1) + ABy;
  Result := tot div 12;
  if (tot mod 12) < 0 then Dec(Result);
end;

{ 31 January plus one month is 28 February -- the day is CLAMPED to the length of
  the month it lands in, 29 February in a leap year -- and the time of day is
  carried through untouched. Backwards clamps identically. }
function t_incmonth(const A: array of TValue; out E: TPhosphorError): TValue;
var ty: Int64;
begin
  Result := ValInt(0);
  if not SourceOk('incmonth', D0(A), E) then Exit;
  ty := MonthStepYear(D0(A), I1(A));
  if (ty < 1) or (ty > 9999) then
  begin
    Result := SteppedOff('incmonth', I1(A), 'months', E);
    Exit;
  end;
  E := NoError();
  Result := ValDouble(IncMonth(D0(A), I1(A)));
end;
function t_incyear(const A: array of TValue; out E: TPhosphorError): TValue;
var ty: Int64;
begin
  Result := ValInt(0);
  if not SourceOk('incyear', D0(A), E) then Exit;
  ty := Int64(YearOf(D0(A))) + I1(A);
  if (ty < 1) or (ty > 9999) then
  begin
    Result := SteppedOff('incyear', I1(A), 'years', E);
    Exit;
  end;
  E := NoError();
  Result := ValDouble(IncYear(D0(A), I1(A)));  // clamps a leap day to the 28th
end;

// --- distances --------------------------------------------------------------
function t_daysbetween(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(DaysBetween(D0(A), D1(A))); end;
function t_dayspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(DaySpan(D0(A), D1(A))); end;
function t_hoursbetween(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(HoursBetween(D0(A), D1(A))); end;
function t_minutesbetween(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(MinutesBetween(D0(A), D1(A))); end;
function t_secondsbetween(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(SecondsBetween(D0(A), D1(A))); end;

// --- the clock (no arguments) -----------------------------------------------
function t_now(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Now); end;
function t_today(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Date); end;
function t_tomorrow(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Tomorrow); end;
function t_yesterday(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Yesterday); end;
function t_istoday(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(Ord(IsToday(D0(A)))); end;

// --- ISO 8601 rendering and parsing -----------------------------------------
// Phosphor's date strings are ISO 8601 (yyyy-mm-dd, hh:nn:ss), fixed rather than
// locale-following, so the same text parses and renders the same on any machine
// -- render/parse are exact inverses and a hard-coded "2020-06-15" is read the
// same everywhere. (The reference used the machine's locale format.)
var
  ISOFS: TFormatSettings;

function t_datetostr(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(DateToStr(D0(A), ISOFS)); end;
function t_timetostr(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(TimeToStr(D0(A), ISOFS)); end;
function t_datetimetostr(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(DateTimeToStr(D0(A), ISOFS)); end;
function t_date_s(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(DateToStr(Date, ISOFS)); end;
function t_time_s(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(TimeToStr(Time, ISOFS)); end;
function t_datetime_s(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(DateTimeToStr(Now, ISOFS)); end;
function t_formatdatetime(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(FormatDateTime(A[0].Str, AsDouble(A[1]), ISOFS)); end;

function t_strtodate(const A: array of TValue; out E: TPhosphorError): TValue;
var d: TDateTime;
begin
  Result := ValInt(0);
  try d := StrToDate(A[0].Str, ISOFS);
  except on Ex: Exception do begin E := MakeError(peRuntime, 'invalid date: ' + Ex.Message); Exit; end; end;
  E := NoError(); Result := ValDouble(d);
end;
function t_strtotime(const A: array of TValue; out E: TPhosphorError): TValue;
var d: TDateTime;
begin
  Result := ValInt(0);
  try d := StrToTime(A[0].Str, ISOFS);
  except on Ex: Exception do begin E := MakeError(peRuntime, 'invalid time: ' + Ex.Message); Exit; end; end;
  E := NoError(); Result := ValDouble(d);
end;
function t_strtodatetime(const A: array of TValue; out E: TPhosphorError): TValue;
var d: TDateTime;
begin
  Result := ValInt(0);
  try d := StrToDateTime(A[0].Str, ISOFS);
  except on Ex: Exception do begin E := MakeError(peRuntime, 'invalid datetime: ' + Ex.Message); Exit; end; end;
  E := NoError(); Result := ValDouble(d);
end;

// --- the clock (no arguments) -----------------------------------------------
function t_date(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Date); end;
function t_time(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Time); end;
function t_gettime(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(Now); end;

// --- finer increments -------------------------------------------------------
function t_inchour(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(IncHour(D0(A), I1(A))); end;
function t_incminute(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(IncMinute(D0(A), I1(A))); end;
function t_incsecond(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(IncSecond(D0(A), I1(A))); end;
function t_incmillisecond(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(IncMilliSecond(D0(A), I1(A))); end;

// --- year lengths taking a date ---------------------------------------------
function t_daysinyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(DaysInYear(D0(A))); end;
function t_weeksinyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(WeeksInYear(D0(A))); end;

// --- more distances ---------------------------------------------------------
function t_weeksbetween(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(WeeksBetween(D0(A), D1(A))); end;
function t_monthsbetween(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(MonthsBetween(D0(A), D1(A))); end;
function t_yearsbetween(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(YearsBetween(D0(A), D1(A))); end;
function t_millisecondsbetween(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(MilliSecondsBetween(D0(A), D1(A))); end;

// --- spans (fractional distances) -------------------------------------------
function t_hourspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(HourSpan(D0(A), D1(A))); end;
function t_minutespan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(MinuteSpan(D0(A), D1(A))); end;
function t_secondspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(SecondSpan(D0(A), D1(A))); end;
function t_millisecondspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(MilliSecondSpan(D0(A), D1(A))); end;
function t_weekspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(WeekSpan(D0(A), D1(A))); end;
function t_monthspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(MonthSpan(D0(A), D1(A))); end;
function t_yearspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(YearSpan(D0(A), D1(A))); end;

function t_millisecondof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(MilliSecondOf(D0(A))); end;

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
