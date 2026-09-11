{******************************************************************************
  Phosphor BASIC -- numeric library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  Numeric functions: sign/abs/sqr (square root, decisions.md), rounding and
  truncation, logs, trig and inverse trig, angle conversion, min/max, random,
  and the isnan/isinfinite predicates. Thin wrappers over FPC's Math unit; all
  take the numeric family (int% widened to Double) and return a number.
******************************************************************************}
unit PhosphorNumLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Math, PhosphorValue, PhosphorErrors, PhosphorRegistry;

procedure RegisterNumFuncs(Reg: TPhosphorRegistry);

implementation

function N(const Args: array of TValue): Double;
begin Result := AsDouble(Args[0]); end;

function f_abs(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Abs(N(Args))); end;
function f_sqr(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if N(Args) < 0 then Err := MakeError(peRuntime, 'sqr of a negative number');
  Result := ValDouble(Sqrt(Abs(N(Args))));
end;
function f_sgn(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Sign(N(Args))); end;
function f_min(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Min(AsDouble(Args[0]), AsDouble(Args[1]))); end;
function f_max(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Max(AsDouble(Args[0]), AsDouble(Args[1]))); end;
// round/fix/cint/int convert a Double to an Int64. A magnitude past Int64 range
// (or NaN/Inf) would make Round/Trunc/Floor raise, so it is reported as a catchable
// overflow -- overflow is an error value here, never a crash.
function ToIntError(const V: String): TPhosphorError; inline;
begin Result := MakeError(peIntOverflow, 'number too large to convert to an integer (' + V + ')'); end;

{ AN int% IS ALREADY AN INTEGER, and all four of these used to widen it to a
  Double first. Two wrong answers came out of that, in opposite directions:

    round(9007199254740993)      -> 9007199254740992, silently, no error
    round(9223372036854775806)   -> error 1, "number too large", for a value one
                                    BELOW High(Int64) and squarely inside its range

  Above 2^53 a Double cannot hold every integer, so the widening loses the value;
  and near High(Int64) the nearest Double is ABOVE the range, so the InI64Range
  test refuses a number that was never out of range. docs/libraries/num.md says
  "all four answer an int%" and "a magnitude past Int64 range is error code 1",
  and both halves were false for an int% argument.

  Rounding, truncating and flooring an integer are all the identity, so the fast
  path is both the correct answer and the cheap one. This is ArgI64's rule, which
  has had it all along. }
function IntIdentity(const Args: array of TValue; out Err: TPhosphorError;
  out R: TValue): Boolean;
begin
  Result := (Length(Args) > 0) and (Args[0].Kind = vkInt);
  if Result then
  begin
    Err := NoError();
    R := ValInt(Args[0].Int);
  end;
end;
function f_round(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin if IntIdentity(Args, Err, Result) then Exit;
  d := N(Args); if InI64Range(d) then begin Err := NoError(); Result := ValInt(Round(d)); end
  else begin Err := ToIntError('round'); Result := ValInt(0); end; end;
function f_fix(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin if IntIdentity(Args, Err, Result) then Exit;
  d := N(Args); if InI64Range(d) then begin Err := NoError(); Result := ValInt(Trunc(d)); end   // toward zero
  else begin Err := ToIntError('fix'); Result := ValInt(0); end; end;
function f_cint(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin if IntIdentity(Args, Err, Result) then Exit;
  d := N(Args); if InI64Range(d) then begin Err := NoError(); Result := ValInt(Trunc(d)); end
  else begin Err := ToIntError('cint'); Result := ValInt(0); end; end;
function f_frac(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Frac(N(Args))); end;
{ A 64-BIT GUARD MUST NOT BE FOLLOWED BY A 32-BIT NARROWING.

  int() guarded with InI64Range -- an Int64 window -- and then narrowed with
  Math.Floor, whose result type is INTEGER (rtl/objpas/math.pp:410 declares
  `function Floor(x : float) : Integer` and :1107 implements it as
  `Trunc(x)-ord(Frac(x)<0)`, so the Int64 from Trunc is truncated to 32 bits on
  the way out). Everything between 2^31 and 2^63 therefore passed the guard and
  came back wrapped, silently and on both platforms:

      int(3e9)   -> -1294967296        int(4294967296) ->  0
      int(1e15)  -> -1530494976        int(-3e9)       ->  1294967296

  No crash, no error, an answer that is simply wrong -- which is worse. Floor64
  is the same function with the Int64 result the guard was written for, and its
  siblings round/fix/cint were already correct because Round and Trunc return
  Int64. This is the only place in engine/libs where a 64-bit guard met a 32-bit
  narrowing; scripts/check-budget.py --narrowing is the sweep that says so, and
  keeps saying so. }
function f_int(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin if IntIdentity(Args, Err, Result) then Exit;
  d := N(Args); if InI64Range(d) then begin Err := NoError(); Result := ValInt(Floor64(d)); end   // BASIC INT: floor
  else begin Err := ToIntError('int'); Result := ValInt(0); end; end;

{ A domain error, in the library's own words. ln(0), acos(2) and friends raised
  the RTL's own exception -- "Invalid floating point operation" -- which the VM's
  net turned into a generic runtime error naming neither the function nor the
  argument. A reader of the message could not tell which call went wrong.

  NumToInv, not FloatToStr: the argument is the whole point of the message, and a
  bare FloatToStr both rounded it to 15 digits and spelled it in the machine's
  locale -- so `ln(x)` on a value a comma-decimal machine formats as "0,5" said
  so in an error a program then read back with val(). A program can read this
  text with errmsg$, which makes it one of the engine's number-to-text paths. }
function DomainError(const AFn, ANeeds: String; V: Double): TPhosphorError;
begin
  Result := MakeError(peRuntime,
    AFn + ': ' + NumToInv(V) + ' is outside the domain (needs ' + ANeeds + ')');
end;

function f_log10(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin
  d := N(Args);
  if not (d > 0) then begin Err := DomainError('log10', 'a positive number', d); Result := ValDouble(0); Exit; end;
  Err := NoError(); Result := ValDouble(Log10(d));
end;
function f_log2(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin
  d := N(Args);
  if not (d > 0) then begin Err := DomainError('log2', 'a positive number', d); Result := ValDouble(0); Exit; end;
  Err := NoError(); Result := ValDouble(Log2(d));
end;
function f_ln(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin
  d := N(Args);
  if not (d > 0) then begin Err := DomainError('ln', 'a positive number', d); Result := ValDouble(0); Exit; end;
  Err := NoError(); Result := ValDouble(Ln(d));
end;
function f_exp(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Exp(N(Args))); end;

function f_sin(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Sin(N(Args))); end;
function f_cos(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Cos(N(Args))); end;
function f_tan(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Tan(N(Args))); end;
function f_asin(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin
  d := N(Args);
  if not ((d >= -1) and (d <= 1)) then begin Err := DomainError('asin', '-1 .. 1', d); Result := ValDouble(0); Exit; end;
  Err := NoError(); Result := ValDouble(ArcSin(d));
end;
function f_acos(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin
  d := N(Args);
  if not ((d >= -1) and (d <= 1)) then begin Err := DomainError('acos', '-1 .. 1', d); Result := ValDouble(0); Exit; end;
  Err := NoError(); Result := ValDouble(ArcCos(d));
end;
function f_atan(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(ArcTan(N(Args))); end;
function f_degtorad(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(DegToRad(N(Args))); end;
function f_radtodeg(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(RadToDeg(N(Args))); end;

function f_randomize(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Randomize; Result := ValInt(0); end;
function f_rnd_n(const Args: array of TValue; out Err: TPhosphorError): TValue;
var hi: Int64;
begin
  Err := NoError();
  // Int64 throughout. The bound used to be narrowed to a 32-bit Integer, so
  // rnd(3000000000) wrapped to a NEGATIVE bound, was clamped to 1, and returned 0
  // every single time -- a random generator that silently stopped being random.
  hi := ArgI64(Args[0]);
  if hi < 1 then hi := 1;
  Result := ValInt(Random(hi));    // 0 .. hi-1
end;
function f_rnd(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Random); end;   // [0,1)

function f_sinh(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Sinh(N(Args))); end;
function f_cosh(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Cosh(N(Args))); end;
function f_tanh(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Tanh(N(Args))); end;
function f_asinh(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(ArcSinh(N(Args))); end;
function f_acosh(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(ArcCosh(N(Args))); end;
function f_atanh(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(ArcTanh(N(Args))); end;
function f_atan2(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(ArcTan2(AsDouble(Args[0]), AsDouble(Args[1]))); end;
function f_cmpval(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a, b: Double;
begin
  Err := NoError(); a := AsDouble(Args[0]); b := AsDouble(Args[1]);
  if a < b then Result := ValInt(-1) else if a > b then Result := ValInt(1) else Result := ValInt(0);
end;

function f_isnan(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(IsNan(N(Args)))); end;
function f_isinfinite(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(IsInfinite(N(Args)))); end;

procedure RegisterNumFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('abs:n',  @f_abs);
  Reg.Add('sqr:n',  @f_sqr);
  Reg.Add('sgn:n',  @f_sgn);
  Reg.Add('min:nn', @f_min);
  Reg.Add('max:nn', @f_max);
  Reg.Add('round:n', @f_round);
  Reg.Add('fix:n',  @f_fix);
  Reg.Add('cint:n', @f_cint);
  Reg.Add('frac:n', @f_frac);
  Reg.Add('int:n',  @f_int);
  Reg.Add('log10:n', @f_log10);
  Reg.Add('log2:n', @f_log2);
  Reg.Add('ln:n',   @f_ln);
  Reg.Add('exp:n',  @f_exp);
  Reg.Add('sin:n',  @f_sin);
  Reg.Add('cos:n',  @f_cos);
  Reg.Add('tan:n',  @f_tan);
  Reg.Add('asin:n', @f_asin);
  Reg.Add('acos:n', @f_acos);
  Reg.Add('atan:n', @f_atan);
  Reg.Add('degtorad:n', @f_degtorad);
  Reg.Add('radtodeg:n', @f_radtodeg);
  Reg.Add('sinh:n',  @f_sinh);
  Reg.Add('cosh:n',  @f_cosh);
  Reg.Add('tanh:n',  @f_tanh);
  Reg.Add('asinh:n', @f_asinh);
  Reg.Add('acosh:n', @f_acosh);
  Reg.Add('atanh:n', @f_atanh);
  Reg.Add('atan2:nn', @f_atan2);
  Reg.Add('cmpval:nn', @f_cmpval);
  Reg.Add('randomize:', @f_randomize);
  Reg.Add('rnd:n',  @f_rnd_n);
  Reg.Add('rnd:',   @f_rnd);
  Reg.Add('isnan:n', @f_isnan);
  Reg.Add('isinfinite:n', @f_isinfinite);
end;

end.
