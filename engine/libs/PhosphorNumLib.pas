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
function f_round(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin d := N(Args); if InI64Range(d) then begin Err := NoError(); Result := ValInt(Round(d)); end
  else begin Err := ToIntError('round'); Result := ValInt(0); end; end;
function f_fix(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin d := N(Args); if InI64Range(d) then begin Err := NoError(); Result := ValInt(Trunc(d)); end   // toward zero
  else begin Err := ToIntError('fix'); Result := ValInt(0); end; end;
function f_cint(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin d := N(Args); if InI64Range(d) then begin Err := NoError(); Result := ValInt(Trunc(d)); end
  else begin Err := ToIntError('cint'); Result := ValInt(0); end; end;
function f_frac(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Frac(N(Args))); end;
function f_int(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin d := N(Args); if InI64Range(d) then begin Err := NoError(); Result := ValInt(Floor(d)); end   // BASIC INT: floor
  else begin Err := ToIntError('int'); Result := ValInt(0); end; end;

function f_log10(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Log10(N(Args))); end;
function f_log2(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Log2(N(Args))); end;
function f_ln(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Ln(N(Args))); end;
function f_exp(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Exp(N(Args))); end;

function f_sin(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Sin(N(Args))); end;
function f_cos(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Cos(N(Args))); end;
function f_tan(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(Tan(N(Args))); end;
function f_asin(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(ArcSin(N(Args))); end;
function f_acos(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(ArcCos(N(Args))); end;
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
