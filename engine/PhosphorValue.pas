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

  { The engine's one INPUT seam -- the dual of OnOutput. The VM asks the host for
    the next line of console input (INPUT / LINE INPUT / INPUT$); the host fills
    ALine (UTF-8, newline stripped) and returns True, or returns False at end of
    input. Nil by default: a headless host installs none, and INPUT then reads as
    empty (each field takes its type's default). Declared here (a low-level unit)
    so the VM and the engine facade share it without a circular dependency. }
  TPhosphorInputProc = function(out ALine: String): Boolean of object;

  TValueKind = (vkDouble, vkString, vkInt, vkHandle, vkBool);

  { The element/value kind of a handle-based collection (array, dict). Shared by
    the library packages under engine/libs. }
  TArrayKind = (akNumeric, akString, akPointer);

  TValue = record
    Kind: TValueKind;
    Num: Double;    // vkDouble
    Int: Int64;     // vkInt
    Str: String;    // vkString
    Hnd: Int64;     // vkHandle (registry id)
    Bl: Boolean;    // vkBool
  end;

  { The BREAKPOINT seam, declared alongside OnOutput for the same reason (the VM
    and the engine facade share it without a circular dependency). A host that
    wants to pause installs one; the VM calls it (message, source line, and the
    operand values the breakpoint carried) ONLY when tracing is on. It is nil by
    default -- a headless host installs none -- so BREAKPOINT then reports nothing
    and simply continues. The seam MUST NOT block: the engine treats it as a
    report, never a wait, so no confirm-answer is returned. }
  TPhosphorBreakpointProc = procedure(const AMessage: String; ALine: Integer;
                                      const AOperands: array of TValue) of object;

  { The host-services seam: platform facilities the ENGINE asks the HOST for,
    instead of reaching into a windowing framework for them. Declared here (beside
    OnOutput/OnBreakpoint) so the VM and the engine facade share it without a
    circular dependency. Each field is a method a host installs; all are nil by
    default, so a headless runner leaves them empty and every function that
    consults them returns its EMPTY answer -- empty is a real answer, not a fault.
    The guard is always `if Assigned(seam) then seam(...) else <empty>`, so asking
    an absent service can never be an access violation on a nil call.

      ProcessMessages / HandleMessage  pump a host's event loop; each returns 1
                                       when a host actually pumped, 0 where there
                                       is no loop to pump.
      ClipboardCopy    stores AText on the host clipboard, returning whether it
                       could (False => no clipboard service).
      ClipboardPaste   reads the host clipboard back into AText, returning whether
                       a service answered (False => none). }
  TPhosphorPumpFunc = function: Integer of object;
  TPhosphorClipboardCopyFunc = function(const AText: String): Boolean of object;
  TPhosphorClipboardPasteFunc = function(out AText: String): Boolean of object;

  THostServices = record
    ProcessMessages: TPhosphorPumpFunc;
    HandleMessage: TPhosphorPumpFunc;
    ClipboardCopy: TPhosphorClipboardCopyFunc;
    ClipboardPaste: TPhosphorClipboardPasteFunc;
  end;

  TCmpOp = (coEQ, coNE, coLT, coLE, coGT, coGE);

  { A variable's declared type, fixed by its name suffix (the suffix is part of
    the name). vtNumber (no suffix) holds the numeric family: an int% or a
    Double. vtAny is internal only (compiler-generated hidden temporaries, e.g.
    a SELECT subject) -- no source suffix maps to it. }
  TVarType = (vtNumber, vtString, vtInt, vtHandle, vtBool, vtAny);

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
function ValAnd(const A, B: TValue; out R: TValue): TPhosphorError;   // bool operands
function ValOr(const A, B: TValue; out R: TValue): TPhosphorError;
function ValNot(const A: TValue; out R: TValue): TPhosphorError;

// Variable typing (from the name suffix) and its storage rules ---------------
function VarTypeOf(const AName: String): TVarType;
function VarTypeName(T: TVarType): String;
function DefaultValue(T: TVarType): TValue;
// NoError if V may be stored into a variable of type T; Coerced is what to store
// (e.g. a Double rounded into an int% slot). It returns the ERROR rather than a
// bare False because the two ways a store can fail need different words: a wrong
// kind is a type mismatch, and a Double too large for an int% is an overflow.
function StoreCheck(T: TVarType; const V: TValue; out Coerced: TValue): TPhosphorError;

// True if D can be rounded/truncated into an Int64 without FPC's Round/Trunc/Floor
// raising EInvalidOp. NaN and +/-Inf answer False (their comparisons are all False),
// so a caller guards a Double->Int64 conversion with this and reports overflow as a
// catchable error instead of crashing the process.
function InI64Range(const D: Double): Boolean;
// Round D into an Int64, answering False instead of raising when it does not fit.
// USE THIS, never a bare Round/Trunc, on any Double that came from a program: an
// out-of-range Round raises EInvalidOp, which is a hardware trap and not an error
// value, and it killed the interpreter from five separate sites before this existed.
function TryD2I(const D: Double; out I: Int64): Boolean;

// Narrow a value that came FROM A PROGRAM into an index, a count or a size.
// SATURATING, never wrapping and never raising: an argument too large clamps to the
// type's limit, so the bounds check that follows rejects it instead of being handed
// a wrapped-around value that looks valid. NaN answers 0.
// Use these, never `ArgI32(v)`, on anything a program supplied.
function ArgI32(const V: TValue): Integer;
function ArgI64(const V: TValue): Int64;

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

function TryD2I(const D: Double; out I: Int64): Boolean;
begin
  I := 0;
  Result := InI64Range(D);
  if Result then I := Round(D);
end;

function ArgI64(const V: TValue): Int64;
var d: Double;
begin
  if V.Kind = vkInt then Exit(V.Int);     // exact: no trip through Double
  d := AsDouble(V);
  if d <> d then Result := 0                                  // NaN
  else if d >= 9223372036854775808.0 then Result := High(Int64)
  else if d <= -9223372036854775808.0 then Result := Low(Int64)
  else Result := Round(d);
end;

function ArgI32(const V: TValue): Integer;
var i: Int64;
begin
  i := ArgI64(V);
  if i > High(Integer) then Result := High(Integer)
  else if i < Low(Integer) then Result := Low(Integer)
  else Result := Integer(i);
end;

{ THE FINITENESS GATE. Every double-producing operator returns through here.

  IEEE-754 answers an overflow with Infinity and an undefined form with NaN.
  Phosphor answers with a CATCHABLE ERROR instead, for the same reason integer
  overflow is an error rather than a silent promotion (decisions.md): a value the
  program cannot represent should stop the program, not travel through it. The
  consequence is an invariant the rest of the engine can rely on --

      no TValue ever holds a non-finite Double.

  which is what makes it safe to leave the invalid-operation trap unmasked while
  a program runs: Inf and NaN cannot enter the value space, so they cannot reach
  a later operation and raise there. }
function FiniteD(const AOp: String; const X: Double; out R: TValue): TPhosphorError;
begin
  if IsNan(X) then
  begin
    R := Default(TValue);
    Exit(MakeError(peRuntime, AOp + ' has no numeric result'));
  end;
  if IsInfinite(X) then
  begin
    R := Default(TValue);
    Exit(MakeError(peIntOverflow, 'floating point overflow in ' + AOp));
  end;
  R := ValDouble(X);
  Result := NoError();
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

function InI64Range(const D: Double): Boolean;
begin
  // 2^63 (= 9223372036854775808) and -2^63 are both exactly representable as a
  // Double; a value strictly inside [-2^63, 2^63) rounds to an Int64 safely. NaN
  // and Inf fail both comparisons, so they answer False.
  Result := (D >= -9223372036854775808.0) and (D < 9223372036854775808.0);
end;

// --- checked Int64 primitives ----------------------------------------------
function TryAddI64(const A, B: Int64; out R: Int64): Boolean;
begin
  if ((B > 0) and (A > High(Int64) - B)) or ((B < 0) and (A < Low(Int64) - B)) then
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
    Result := NoError()
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
      Exit(FiniteD('unary minus', -A.Num, R));
  else
    Exit(MakeError(peTypeMismatch, 'unary minus needs a number, got ' + KindName(A.Kind)));
  end;
  Result := NoError();
end;

function ValAdd(const A, B: TValue; out R: TValue): TPhosphorError;
var
  n: Int64;
begin
  R := Default(TValue);
  // The kind of a '+' is decided by its LEFT operand -- the same rule the parser
  // uses for the first token of an expression. A string on the left makes '+'
  // concatenation: the right side is coerced to its text (a number via its str$
  // form) and the two are joined. A number on the left makes '+' arithmetic, so
  // a string on the RIGHT is a type mismatch, not a silent concatenation -- the
  // reverse of a working `"text" + n` (see tests/suite/41_syntax_string_plus_number).
  if A.Kind = vkString then
  begin
    R := ValStr(ValToStr(A) + ValToStr(B));
    Exit(NoError());
  end;
  if B.Kind = vkString then
    Exit(MakeError(peTypeMismatch,
      'cannot add text to a number; a ''+'' that begins with a number is ' +
      'arithmetic -- put the text first, or convert with str$'));
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
    Exit(FiniteD('+', AsDouble(A) + AsDouble(B), R));
end;

function ValSub(const A, B: TValue; out R: TValue): TPhosphorError;
var
  n: Int64;
  k: Integer;
  d: Double;
begin
  R := Default(TValue);
  // 'string - n' truncates the last n characters (the string keeps the rest).
  if A.Kind = vkString then
  begin
    if not IsNumeric(B) then
      Exit(MakeError(peTypeMismatch, 'cannot subtract ' + KindName(B.Kind) + ' from a string'));
    // Compare BEFORE narrowing. Round(1e30) raises EInvalidOp, and "remove more
    // characters than the string has" is a clamp, not an error.
    d := AsDouble(B);
    if d >= Length(A.Str) then k := 0
    else if d <= 0 then k := Length(A.Str)
    else k := Length(A.Str) - Round(d);
    R := ValStr(Copy(A.Str, 1, k));
    Exit(NoError());
  end;
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
    Exit(FiniteD('-', AsDouble(A) - AsDouble(B), R));
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
    Exit(FiniteD('*', AsDouble(A) * AsDouble(B), R));
end;

function ValDivReal(const A, B: TValue; out R: TValue): TPhosphorError;
begin
  R := Default(TValue);
  Result := NumericPair(A, B, '/');
  if IsError(Result) then Exit;
  if AsDouble(B) = 0 then
    Exit(MakeError(peDivByZero, 'division by zero'));
  // The slash is ALWAYS real division: int / int is a double.
  Exit(FiniteD('/', AsDouble(A) / AsDouble(B), R));
end;

function ValDivInt(const A, B: TValue; out R: TValue): TPhosphorError;
var
  ai, bi, q: Int64;
begin
  R := Default(TValue);
  Result := NumericPair(A, B, '\');
  if IsError(Result) then Exit;
  if A.Kind = vkInt then ai := A.Int
  else if not TryD2I(A.Num, ai) then
    Exit(MakeError(peIntOverflow, ValToStr(A) + ' is out of integer range'));
  if B.Kind = vkInt then bi := B.Int
  else if not TryD2I(B.Num, bi) then
    Exit(MakeError(peIntOverflow, ValToStr(B) + ' is out of integer range'));
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
  q: Double;
begin
  R := Default(TValue);
  Result := NumericPair(A, B, 'mod');
  if IsError(Result) then Exit;
  if BothInt(A, B) then
  begin
    if B.Int = 0 then
      Exit(MakeError(peDivByZero, 'mod by zero'));
    // Low(Int64) mod -1 is mathematically 0, but x86 computes the remainder with
    // the same idiv as the quotient -- and THAT overflows and traps. ValDivInt has
    // guarded this since it was written; mod never did, so it killed the process.
    if (A.Int = Low(Int64)) and (B.Int = -1) then
      R := ValInt(0)
    else
      R := ValInt(A.Int mod B.Int);
  end
  else
  begin
    if AsDouble(B) = 0 then
      Exit(MakeError(peDivByZero, 'mod by zero'));
    // The quotient stays a DOUBLE. Trunc() narrowed it to Int64 and raised
    // EInvalidOp -- killing the process -- for any pair whose quotient exceeded
    // Int64 range, e.g. `1e30 mod 2.5`. Int() truncates within Double, so there is
    // no range to exceed and the remainder is simply computed.
    q := Int(AsDouble(A) / AsDouble(B));
    ai := 0; bi := 0; // silence "unused" on some paths
    if (ai <> 0) or (bi <> 0) then ;
    Exit(FiniteD('mod', AsDouble(A) - q * AsDouble(B), R));
  end;
end;

function ValPow(const A, B: TValue; out R: TValue): TPhosphorError;
begin
  R := Default(TValue);
  Result := NumericPair(A, B, '^');
  if IsError(Result) then Exit;
  // '^' is always a double (2 ^ 0.5 is meaningful).
  Exit(FiniteD('^', Power(AsDouble(A), AsDouble(B)), R));
end;

function ValCompare(Op: TCmpOp; const A, B: TValue; out R: TValue): TPhosphorError;
var
  c: Integer;
  eq: Boolean;
begin
  R := Default(TValue);
  if (A.Kind = vkInt) and (B.Kind = vkInt) then
  begin
    // Compare Int64s AS Int64s. Widening both to Double loses the low bits above
    // 2^53, which made two distinct int% values compare EQUAL while their
    // difference still correctly came out as 1.
    if A.Int < B.Int then c := -1
    else if A.Int > B.Int then c := 1
    else c := 0;
  end
  else if IsNumeric(A) and IsNumeric(B) then
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
  Result := NoError();
end;

function BothBool(const A, B: TValue): Boolean; inline;
begin
  Result := (A.Kind = vkBool) and (B.Kind = vkBool);
end;

function ValAnd(const A, B: TValue; out R: TValue): TPhosphorError;
begin
  R := Default(TValue);
  if not BothBool(A, B) then
    Exit(MakeError(peTypeMismatch, '''and'' needs booleans'));
  R := ValBool(A.Bl and B.Bl);
  Result := NoError();
end;

function ValOr(const A, B: TValue; out R: TValue): TPhosphorError;
begin
  R := Default(TValue);
  if not BothBool(A, B) then
    Exit(MakeError(peTypeMismatch, '''or'' needs booleans'));
  R := ValBool(A.Bl or B.Bl);
  Result := NoError();
end;

function ValNot(const A: TValue; out R: TValue): TPhosphorError;
begin
  R := Default(TValue);
  if A.Kind <> vkBool then
    Exit(MakeError(peTypeMismatch, '''not'' needs a boolean'));
  R := ValBool(not A.Bl);
  Result := NoError();
end;

function VarTypeOf(const AName: String): TVarType;
var
  last: Char;
begin
  Result := vtNumber;
  if AName = '' then Exit;
  last := AName[Length(AName)];
  case last of
    '$': Result := vtString;
    '%': Result := vtInt;
    '@': Result := vtHandle;
    '?': Result := vtBool;
  end;
end;

function VarTypeName(T: TVarType): String;
begin
  case T of
    vtNumber: Result := 'number';
    vtString: Result := 'string';
    vtInt:    Result := 'int';
    vtHandle: Result := 'handle';
    vtBool:   Result := 'bool';
    vtAny:    Result := 'any';
  else
    Result := '?';
  end;
end;

function DefaultValue(T: TVarType): TValue;
begin
  case T of
    vtString: Result := ValStr('');
    vtInt:    Result := ValInt(0);
    vtHandle: Result := ValHandle(0);
    vtBool:   Result := ValBool(False);
  else
    Result := ValInt(0);   // vtNumber and vtAny default to int% 0
  end;
end;

function StoreCheck(T: TVarType; const V: TValue; out Coerced: TValue): TPhosphorError;
var
  i: Int64;
  ok: Boolean;
begin
  Coerced := V;
  Result := NoError();
  case T of
    vtNumber: ok := (V.Kind = vkInt) or (V.Kind = vkDouble);
    vtInt:
      begin
        ok := True;
        if V.Kind = vkDouble then
        begin
          // A bare Round here raised EInvalidOp and killed the process for every
          // Double outside Int64 range: `n% = 10 ^ 300` was a hard abort, exit 217.
          if TryD2I(V.Num, i) then
            Coerced := ValInt(i)
          else
            Exit(MakeError(peIntOverflow,
              ValToStr(V) + ' is out of range for an int% variable'));
        end
        else
          ok := V.Kind = vkInt;
      end;
    vtString: ok := V.Kind = vkString;
    vtHandle: ok := V.Kind = vkHandle;
    vtBool:   ok := V.Kind = vkBool;
    vtAny:    ok := True;
  else
    ok := False;
  end;
  if not ok then
    Result := MakeError(peTypeMismatch, 'kind mismatch');   // the caller words it
end;

initialization
  InvariantFS := DefaultFormatSettings;
  InvariantFS.DecimalSeparator := '.';
  InvariantFS.ThousandSeparator := #0;

end.
