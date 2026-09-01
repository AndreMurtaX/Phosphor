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
begin Err := NoError; Result := ValDouble(Abs(N(Args))); end;
function f_sqr(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  if N(Args) < 0 then Err := MakeError(peRuntime, 'sqr of a negative number');
  Result := ValDouble(Sqrt(Abs(N(Args))));
end;
function f_sgn(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(Sign(N(Args))); end;
function f_min(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(Min(AsDouble(Args[0]), AsDouble(Args[1]))); end;
function f_max(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(Max(AsDouble(Args[0]), AsDouble(Args[1]))); end;
function f_round(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(Round(N(Args))); end;
function f_fix(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(Trunc(N(Args))); end;   // toward zero
function f_cint(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(Trunc(N(Args))); end;
function f_frac(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(Frac(N(Args))); end;
function f_int(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(Floor(N(Args))); end;   // BASIC INT: floor

function f_log10(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(Log10(N(Args))); end;
function f_log2(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(Log2(N(Args))); end;
function f_ln(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(Ln(N(Args))); end;
function f_exp(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(Exp(N(Args))); end;

function f_sin(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(Sin(N(Args))); end;
function f_cos(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(Cos(N(Args))); end;
function f_tan(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(Tan(N(Args))); end;
function f_asin(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(ArcSin(N(Args))); end;
function f_acos(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(ArcCos(N(Args))); end;
function f_atan(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(ArcTan(N(Args))); end;
function f_degtorad(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(DegToRad(N(Args))); end;
function f_radtodeg(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(RadToDeg(N(Args))); end;

function f_randomize(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Randomize; Result := ValInt(0); end;
function f_rnd_n(const Args: array of TValue; out Err: TPhosphorError): TValue;
var hi: Integer;
begin
  Err := NoError;
  hi := Round(N(Args));
  if hi < 1 then hi := 1;
  Result := ValInt(Random(hi));    // 0 .. hi-1
end;
function f_rnd(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValDouble(Random); end;   // [0,1)

function f_isnan(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(Ord(IsNan(N(Args)))); end;
function f_isinfinite(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(Ord(IsInfinite(N(Args)))); end;

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
  Reg.Add('randomize:', @f_randomize);
  Reg.Add('rnd:n',  @f_rnd_n);
  Reg.Add('rnd:',   @f_rnd);
  Reg.Add('isnan:n', @f_isnan);
  Reg.Add('isinfinite:n', @f_isinfinite);
end;

end.
