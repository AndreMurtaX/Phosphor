{******************************************************************************
  Phosphor BASIC -- the five-kind value cell and the arithmetic/comparison kernel

  MIT License. Copyright (c) 2026 Andre Murta.

  The founding divergence from Plan9Basic's three-type VM. A value is one of five
  kinds (decisions.md, "Types"):

    vkDouble  numeric        -- Double (not Extended)
    vkString  string$
    vkInt     integer%       -- Int64
    vkHandle  handle@        -- an id into the handle registry (a later step)
    vkBool    boolean?

  The kernel implements the promotion matrix exactly (decisions.md, "Arithmetic
  and promotion"):

    int + - * int -> int        (checked; overflow is a CATCHABLE ERROR here,
                                 never a silent promotion to double)
    int / int     -> double     (the slash is real division: 7 / 2 = 3.5)
    int \ int     -> int        (backslash is integer division: 7 \ 2 = 3)
    ^             -> always double
    any numeric with a double operand -> double
    comparison    -> bool VALUE (usable everywhere; a bare value is still not a
                                 condition -- that rule lives in the parser)

  Errors are RETURNED (PhosphorErrors), never raised.
******************************************************************************}
unit PhosphorValue;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Math, PhosphorErrors;

type
  { The engine's one output seam. Declared here (a low-level unit) so the VM and
    the engine facade share it without a circular dependency. PRINTLN puts the
    trailing LF into the text; PRINT does not. }
  TPhosphorOutputProc = procedure(const AText: String) of object;

  TValueKind = (vkDouble, vkString, vkInt, vkHandle, vkBool);

  TValue = record
    Kind: TValueKind;
    Num: Double;    // vkDouble
    Int: Int64;     // vkInt
    Str: String;    // vkString
    Hnd: Int64;     // vkHandle (registry id)
    Bl: Boolean;    // vkBool
  end;

  TCmpOp = (coEQ, coNE, coLT, coLE, coGT, coGE);

// Constructors ---------------------------------------------------------------
function ValDouble(const X: Double): TValue;
function ValInt(const X: Int64): TValue;
function ValStr(const S: String): TValue;
function ValBool(const B: Boolean): TValue;
function ValHandle(const H: Int64): TValue;

// Predicates / coercions -----------------------------------------------------
function IsNumeric(const V: TValue): Boolean; inline;      // vkInt or vkDouble
function AsDouble(const V: TValue): Double;                // widen int -> double
function KindName(K: TValueKind): String;
function ValToStr(const V: TValue): String;                // locale-independent

// Arithmetic kernel (each returns an error; on success Result = NoError) ------
function Negate(const A: TValue; out R: TValue): TPhosphorError;
function ValAdd(const A, B: TValue; out R: TValue): TPhosphorError;
function ValSub(const A, B: TValue; out R: TValue): TPhosphorError;
function ValMul(const A, B: TValue; out R: TValue): TPhosphorError;
function ValDivReal(const A, B: TValue; out R: TValue): TPhosphorError;  // /
function ValDivInt(const A, B: TValue; out R: TValue): TPhosphorError;   // \
function ValMod(const A, B: TValue; out R: TValue): TPhosphorError;
function ValPow(const A, B: TValue; out R: TValue): TPhosphorError;      // ^ -> double
function ValCompare(Op: TCmpOp; const A, B: TValue; out R: TValue): TPhosphorError; // -> bool

// Checked Int64 primitives (exposed so libraries can test overflow-as-error) -
function TryAddI64(const A, B: Int64; out R: Int64): Boolean;
function TrySubI64(const A, B: Int64; out R: Int64): Boolean;
function TryMulI64(const A, B: Int64; out R: Int64): Boolean;
function TryNegI64(const A: Int64; out R: Int64): Boolean;

implementation

var
  InvariantFS: TFormatSettings;

function ValDouble(const X: Double): TValue;
begin
  Result := Default(TValue);
  Result.Kind := vkDouble;
  Result.Num := X;
end;

function ValInt(const X: Int64): TValue;
begin
  Result := Default(TValue);
  Result.Kind := vkInt;
  Result.Int := X;
end;

function ValStr(const S: String): TValue;
begin
  Result := Default(TValue);
  Result.Kind := vkString;
  Result.Str := S;
end;

function ValBool(const B: Boolean): TValue;
begin
  Result := Default(TValue);
  Result.Kind := vkBool;
  Result.Bl := B;
end;

function ValHandle(const H: Int64): TValue;
begin
  Result := Default(TValue);
  Result.Kind := vkHandle;
  Result.Hnd := H;
end;

function IsNumeric(const V: TValue): Boolean; inline;
begin
  Result := (V.Kind = vkInt) or (V.Kind = vkDouble);
end;

function AsDouble(const V: TValue): Double;
begin
  if V.Kind = vkInt then
    Result := V.Int
  else
    Result := V.Num;
end;

function KindName(K: TValueKind): String;
begin
  case K of
    vkDouble: Result := 'number';
    vkString: Result := 'string';
    vkInt:    Result := 'int';
    vkHandle: Result := 'handle';
    vkBool:   Result := 'bool';
  else
    Result := '?';
  end;
end;

function ValToStr(const V: TValue): String;
begin
  case V.Kind of
    vkInt:    Result := IntToStr(V.Int);
    vkDouble: Result := FloatToStr(V.Num, InvariantFS);
    vkString: Result := V.Str;
    vkBool:   if V.Bl then Result := 'true' else Result := 'false';
    vkHandle: Result := '@' + IntToStr(V.Hnd);
  else
    Result := '';
  end;
end;

// --- checked Int64 primitives ----------------------------------------------
function TryAddI64(const A, B: Int64; out R: Int64): Boolean;
begin
  if ((B > 0) and (A > High(Int64) - B)) or
     ((B < 0) and (A < Low(Int64) - B)) then
    Exit(False);
  R := A + B;
  Result := True;
end;

function TrySubI64(const A, B: Int64; out R: Int64): Boolean;
begin
  // A - B overflows when B is the value that A + (-B) would overflow on, but
  // -Low(Int64) is itself unrepresentable, so test directly against the bounds.
  if ((B < 0) and (A > High(Int64) + B)) or
     ((B > 0) and (A < Low(Int64) + B)) then
    Exit(False);
  R := A - B;
  Result := True;
end;

function TryMulI64(const A, B: Int64; out R: Int64): Boolean;
begin
  if (A = 0) or (B = 0) then
  begin
    R := 0;
    Exit(True);
  end;
  R := A * B;
  // Recover the operand; a mismatch (or a sign flip on the MinInt edge) means
  // the product did not fit.
  if (R div B <> A) or ((A = Low(Int64)) and (B = -1)) or
     ((B = Low(Int64)) and (A = -1)) then
    Exit(False);
  Result := True;
end;

function TryNegI64(const A: Int64; out R: Int64): Boolean;
begin
  if A = Low(Int64) then
    Exit(False);
  R := -A;
  Result := True;
end;

// --- helpers ----------------------------------------------------------------
function BothInt(const A, B: TValue): Boolean; inline;
begin
  Result := (A.Kind = vkInt) and (B.Kind = vkInt);
end;

function NumericPair(const A, B: TValue; const Op: String): TPhosphorError; inline;
begin
  if IsNumeric(A) and IsNumeric(B) then
    Result := NoError
  else
    Result := MakeError(peTypeMismatch,
      Op + ' needs numbers, got ' + KindName(A.Kind) + ' and ' + KindName(B.Kind));
end;

// --- arithmetic -------------------------------------------------------------
function Negate(const A: TValue; out R: TValue): TPhosphorError;
var
  n: Int64;
begin
  R := Default(TValue);
  case A.Kind of
    vkInt:
      if TryNegI64(A.Int, n) then
        R := ValInt(n)
      else
        Exit(MakeError(peIntOverflow, 'integer overflow negating ' + IntToStr(A.Int)));
    vkDouble:
      R := ValDouble(-A.Num);
  else
    Exit(MakeError(peTypeMismatch, 'unary minus needs a number, got ' + KindName(A.Kind)));
  end;
  Result := NoError;
end;

function ValAdd(const A, B: TValue; out R: TValue): TPhosphorError;
var
  n: Int64;
begin
  R := Default(TValue);
  // '+' is the one operator that is also string concatenation.
  if (A.Kind = vkString) and (B.Kind = vkString) then
  begin
    R := ValStr(A.Str + B.Str);
    Exit(NoError);
  end;
  Result := NumericPair(A, B, '+');
  if IsError(Result) then Exit;
  if BothInt(A, B) then
  begin
    if TryAddI64(A.Int, B.Int, n) then
      R := ValInt(n)
    else
      Exit(MakeError(peIntOverflow,
        'integer overflow: ' + IntToStr(A.Int) + ' + ' + IntToStr(B.Int)));
  end
  else
    R := ValDouble(AsDouble(A) + AsDouble(B));
end;

function ValSub(const A, B: TValue; out R: TValue): TPhosphorError;
var
  n: Int64;
begin
  R := Default(TValue);
  Result := NumericPair(A, B, '-');
  if IsError(Result) then Exit;
  if BothInt(A, B) then
  begin
    if TrySubI64(A.Int, B.Int, n) then
      R := ValInt(n)
    else
      Exit(MakeError(peIntOverflow,
        'integer overflow: ' + IntToStr(A.Int) + ' - ' + IntToStr(B.Int)));
  end
  else
    R := ValDouble(AsDouble(A) - AsDouble(B));
end;

function ValMul(const A, B: TValue; out R: TValue): TPhosphorError;
var
  n: Int64;
begin
  R := Default(TValue);
  Result := NumericPair(A, B, '*');
  if IsError(Result) then Exit;
  if BothInt(A, B) then
  begin
    if TryMulI64(A.Int, B.Int, n) then
      R := ValInt(n)
    else
      Exit(MakeError(peIntOverflow,
        'integer overflow: ' + IntToStr(A.Int) + ' * ' + IntToStr(B.Int)));
  end
  else
    R := ValDouble(AsDouble(A) * AsDouble(B));
end;

function ValDivReal(const A, B: TValue; out R: TValue): TPhosphorError;
begin
  R := Default(TValue);
  Result := NumericPair(A, B, '/');
  if IsError(Result) then Exit;
  if AsDouble(B) = 0 then
    Exit(MakeError(peDivByZero, 'division by zero'));
  // The slash is ALWAYS real division: int / int is a double.
  R := ValDouble(AsDouble(A) / AsDouble(B));
end;

function ValDivInt(const A, B: TValue; out R: TValue): TPhosphorError;
var
  ai, bi, q: Int64;
begin
  R := Default(TValue);
  Result := NumericPair(A, B, '\');
  if IsError(Result) then Exit;
  if A.Kind = vkInt then ai := A.Int else ai := Round(A.Num);
  if B.Kind = vkInt then bi := B.Int else bi := Round(B.Num);
  if bi = 0 then
    Exit(MakeError(peDivByZero, 'integer division by zero'));
  if (ai = Low(Int64)) and (bi = -1) then
    Exit(MakeError(peIntOverflow, 'integer overflow in \'));
  q := ai div bi;
  R := ValInt(q);
end;

function ValMod(const A, B: TValue; out R: TValue): TPhosphorError;
var
  ai, bi: Int64;
begin
  R := Default(TValue);
  Result := NumericPair(A, B, 'mod');
  if IsError(Result) then Exit;
  if BothInt(A, B) then
  begin
    if B.Int = 0 then
      Exit(MakeError(peDivByZero, 'mod by zero'));
    R := ValInt(A.Int mod B.Int);
  end
  else
  begin
    if AsDouble(B) = 0 then
      Exit(MakeError(peDivByZero, 'mod by zero'));
    ai := Trunc(AsDouble(A) / AsDouble(B));
    R := ValDouble(AsDouble(A) - ai * AsDouble(B));
    bi := 0; // silence "unused" on some paths
    if bi <> 0 then ;
  end;
end;

function ValPow(const A, B: TValue; out R: TValue): TPhosphorError;
begin
  R := Default(TValue);
  Result := NumericPair(A, B, '^');
  if IsError(Result) then Exit;
  // '^' is always a double (2 ^ 0.5 is meaningful).
  R := ValDouble(Power(AsDouble(A), AsDouble(B)));
end;

function ValCompare(Op: TCmpOp; const A, B: TValue; out R: TValue): TPhosphorError;
var
  c: Integer;
  eq: Boolean;
begin
  R := Default(TValue);
  if IsNumeric(A) and IsNumeric(B) then
  begin
    if AsDouble(A) < AsDouble(B) then c := -1
    else if AsDouble(A) > AsDouble(B) then c := 1
    else c := 0;
  end
  else if (A.Kind = vkString) and (B.Kind = vkString) then
    c := CompareStr(A.Str, B.Str)
  else if (A.Kind = vkBool) and (B.Kind = vkBool) then
  begin
    if (Op <> coEQ) and (Op <> coNE) then
      Exit(MakeError(peTypeMismatch, 'booleans compare only with = or <>'));
    c := Ord(A.Bl) - Ord(B.Bl);
  end
  else
    Exit(MakeError(peTypeMismatch,
      'cannot compare ' + KindName(A.Kind) + ' with ' + KindName(B.Kind)));

  if c < 0 then c := -1 else if c > 0 then c := 1;
  case Op of
    coEQ: eq := c = 0;
    coNE: eq := c <> 0;
    coLT: eq := c < 0;
    coLE: eq := c <= 0;
    coGT: eq := c > 0;
    coGE: eq := c >= 0;
  else
    eq := False;
  end;
  R := ValBool(eq);
  Result := NoError;
end;

initialization
  InvariantFS := DefaultFormatSettings;
  InvariantFS.DecimalSeparator := '.';
  InvariantFS.ThousandSeparator := #0;

end.
