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
function I0(const A: array of TValue): Integer; begin Result := Round(AsDouble(A[0])); end;
function I1(const A: array of TValue): Integer; begin Result := Round(AsDouble(A[1])); end;

// --- decomposition ----------------------------------------------------------
function t_yearof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(YearOf(D0(A))); end;
function t_monthof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(MonthOf(D0(A))); end;
function t_dayof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(DayOf(D0(A))); end;
function t_dayofthemonth(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(DayOfTheMonth(D0(A))); end;
function t_monthoftheyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(MonthOfTheYear(D0(A))); end;
function t_dayoftheyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(DayOfTheYear(D0(A))); end;

// --- week-day: two bases ----------------------------------------------------
function t_dayofweek(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(DayOfWeek(D0(A))); end;         // Sunday = 1
function t_dayoftheweek(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(DayOfTheWeek(D0(A))); end;      // ISO: Monday = 1

// --- leap years and month lengths -------------------------------------------
function t_isinleapyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(Ord(IsInLeapYear(D0(A)))); end;
function t_daysinayear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(DaysInAYear(I0(A))); end;
function t_daysinmonth(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(DaysInMonth(D0(A))); end;
function t_daysinamonth(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(DaysInAMonth(I0(A), I1(A))); end;

// --- time-of-day ------------------------------------------------------------
function t_hourof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(HourOf(D0(A))); end;
function t_minuteof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(MinuteOf(D0(A))); end;
function t_secondof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(SecondOf(D0(A))); end;
// FPC's DateUtils has no IsAM/IsPM; the clock half is decided by the hour.
function t_isam(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(Ord(HourOf(D0(A)) < 12)); end;
function t_ispm(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(Ord(HourOf(D0(A)) >= 12)); end;
function t_issameday(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(Ord(IsSameDay(D0(A), D1(A)))); end;

// --- weeks ------------------------------------------------------------------
function t_weekoftheyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(WeekOfTheYear(D0(A))); end;
function t_weekof(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(WeekOfTheYear(D0(A))); end;     // answers the same
function t_weekofthemonth(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(WeekOfTheMonth(D0(A))); end;
function t_weeksinayear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(WeeksInAYear(I0(A))); end;

// --- incrementing -----------------------------------------------------------
function t_incday(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValDouble(IncDay(D0(A), I1(A))); end;
function t_incweek(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValDouble(IncWeek(D0(A), I1(A))); end;
function t_incyear(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValDouble(IncYear(D0(A), I1(A))); end; // clamps a leap day to the 28th

// --- distances --------------------------------------------------------------
function t_daysbetween(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(DaysBetween(D0(A), D1(A))); end;
function t_dayspan(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValDouble(DaySpan(D0(A), D1(A))); end;
function t_hoursbetween(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(HoursBetween(D0(A), D1(A))); end;
function t_minutesbetween(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(MinutesBetween(D0(A), D1(A))); end;
function t_secondsbetween(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(SecondsBetween(D0(A), D1(A))); end;

// --- the clock (no arguments) -----------------------------------------------
function t_now(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValDouble(Now); end;
function t_today(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValDouble(Date); end;
function t_tomorrow(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValDouble(Tomorrow); end;
function t_yesterday(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValDouble(Yesterday); end;
function t_istoday(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(Ord(IsToday(D0(A)))); end;

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
end;

end.
