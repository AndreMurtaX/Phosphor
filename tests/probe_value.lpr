{******************************************************************************
  probe_value -- a Pascal unit-test of the five-kind value kernel

  Exercises PhosphorValue directly (no lexer, no VM), because the promotion
  matrix and overflow-as-error are the load-bearing, most-flagged part of the
  first increment. Prints "ok: N" / "fail: M" and exits non-zero on any failure.
  Run with --fail to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_value;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, PhosphorErrors, PhosphorValue;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

procedure CheckInt(const V: TValue; Expected: Int64; const Name: String);
begin
  Report((V.Kind = vkInt) and (V.Int = Expected), Name + ' (int ' + IntToStr(Expected) + ')');
end;

procedure CheckDouble(const V: TValue; Expected: Double; const Name: String);
begin
  Report((V.Kind = vkDouble) and (Abs(V.Num - Expected) < 1E-9), Name + ' (double)');
end;

procedure CheckStr(const V: TValue; const Expected, Name: String);
begin
  Report((V.Kind = vkString) and (V.Str = Expected), Name + ' (string)');
end;

procedure CheckBool(const V: TValue; Expected: Boolean; const Name: String);
begin
  Report((V.Kind = vkBool) and (V.Bl = Expected), Name + ' (bool)');
end;

procedure CheckErr(const E: TPhosphorError; Code: TPhosphorErrorCode; const Name: String);
begin
  Report(E.Code = Code, Name + ' (error)');
end;

var
  r: TValue;
  e: TPhosphorError;
  i: Int64;
begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  // int + int -> int (checked)
  e := OpAdd(ValInt(3), ValInt(4), r);
  CheckErr(e, peNone, 'add int+int no error');
  if ProveFail then CheckInt(r, 8, 'add int+int stays int')   // deliberately wrong
  else CheckInt(r, 7, 'add int+int stays int');

  // int / int -> double (real division)
  e := OpDivReal(ValInt(10), ValInt(4), r);
  CheckDouble(r, 2.5, 'div 10/4 = 2.5 double');

  // int \ int -> int (integer division)
  e := OpDivInt(ValInt(7), ValInt(2), r);
  CheckInt(r, 3, 'idiv 7\2 = 3 int');

  // string + string -> concat
  e := OpAdd(ValStr('ab'), ValStr('cd'), r);
  CheckStr(r, 'abcd', 'concat ab+cd');

  // int + double -> double
  e := OpAdd(ValInt(2), ValDouble(0.5), r);
  CheckDouble(r, 2.5, 'mixed 2+0.5 = 2.5 double');

  // overflow is a CATCHABLE ERROR, not a silent double
  e := OpAdd(ValInt(High(Int64)), ValInt(1), r);
  CheckErr(e, peIntOverflow, 'add overflow -> error');
  e := OpMul(ValInt(High(Int64)), ValInt(2), r);
  CheckErr(e, peIntOverflow, 'mul overflow -> error');
  Report(not TryNegI64(Low(Int64), i), 'neg Low(Int64) overflows');

  // comparison produces a bool VALUE
  e := OpCompare(coGT, ValInt(2), ValInt(1), r);
  CheckBool(r, True, 'compare 2>1 = true');
  e := OpCompare(coGT, ValInt(3), ValInt(5), r);
  CheckBool(r, False, 'compare 3>5 = false');
  e := OpCompare(coEQ, ValStr('x'), ValStr('x'), r);
  CheckBool(r, True, 'compare "x"="x" = true');

  // ^ is always double
  e := OpPow(ValInt(2), ValInt(10), r);
  CheckDouble(r, 1024, 'pow 2^10 = 1024 double');

  // type errors and div-by-zero are recorded, not raised
  e := OpAdd(ValStr('a'), ValInt(1), r);
  CheckErr(e, peTypeMismatch, 'string + int -> type mismatch');
  e := OpDivReal(ValInt(1), ValInt(0), r);
  CheckErr(e, peDivByZero, 'div by zero -> error');

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed = 0 then Halt(0) else Halt(1);
end.
