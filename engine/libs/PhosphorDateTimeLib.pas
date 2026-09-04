{******************************************************************************
  Phosphor BASIC -- date/time library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  A date is a plain number: a TDateTime, days since 1899-12-30 with the time in
  the fraction (so 45351.5 is noon on 2024-02-29). Every function here is a thin
  wrapper over the RTL's DateUtils/SysUtils, which makes the arithmetic -- leap
  years, ISO weeks, month lengths, clamping IncYear across a leap day -- the
  RTL's job rather than ours. Nothing raises; a bad argument just flows through
  the RTL. now/today/tomorrow/yesterday read the clock and take no arguments.
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
function t_dayoftheyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(DayOfTheYear(D0(A))); end;

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
function t_issameday(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(Ord(IsSameDay(D0(A), D1(A)))); end;

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

// --- incrementing -----------------------------------------------------------
function t_incday(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(IncDay(D0(A), I1(A))); end;
function t_incweek(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(IncWeek(D0(A), I1(A))); end;
function t_incyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValDouble(IncYear(D0(A), I1(A))); end; // clamps a leap day to the 28th

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
  Reg.Add('incday:nn',         @t_incday);
  Reg.Add('incweek:nn',        @t_incweek);
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
