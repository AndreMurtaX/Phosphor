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
  SysUtils, Math, Types, PhosphorErrors;

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
// ValDouble is the RAW cell constructor: it stores what it is given and checks
// NOTHING, because FiniteD is built on it and something has to be able to make
// the cell before the gate can judge it. Anything that computes or reads a
// Double from outside the engine -- a deserialiser, a host API, a library that
// returns a computed number -- must go through FiniteD (below) instead, or the
// value space stops meeting the invariant the whole unit rests on.
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

// The UTF-8 codepoint layer --------------------------------------------------
{ ONE PLACE THAT KNOWS WHERE A CHARACTER STARTS, AND WHY IT LIVES HERE.

  docs/language-reference.md:372 -- "Strings are 1-based and Unicode-aware
  (character operations count codepoints)" -- is a promise made by the whole
  engine, not by one library. Three units have to keep it:

    PhosphorStrLib   len/left$/right$/mid$/reverse$/insert$/delete$/...
    PhosphorValue    the `string - n` operator, three lines below
    PhosphorVM       PRINT USING's '!' and '\...\' string fields

  Each of them used to measure and cut with Length() and Copy(), which are BYTE
  operations, and each produced a string that was not valid UTF-8: `"cafe"-1`
  with an accented e dropped one byte of a two-byte character and left the lead
  byte behind, so len() did not fall at all; PRINT USING's '!' wrote half a
  character to stdout. Only StrLib had a codepoint family, and it was private.

  So the family moves to the unit all three already depend on and nothing is
  duplicated. This is the ONLY place in the engine that decides where a
  character begins; a fourth caller reuses it rather than writing a fourth way
  to walk UTF-8. }

{ Byte index (1-based) of the start of each codepoint, plus a sentinel at
  Length(S)+1, so codepoint k spans Result[k] .. Result[k+1]-1. Every byte of S
  belongs to exactly one span, which is the invariant the slicers rely on:
  Utf8Left(S,k) + Utf8Right(S, Utf8Len(S)-k) is S for every k. }
function Utf8Starts(const S: String): TInt64DynArray;
function Utf8Len(const S: String): Integer;
function Utf8Left(const S: String; ACount: Integer): String;
function Utf8Right(const S: String; ACount: Integer): String;
{ The UTF-8 encoding of one codepoint, CLAMPED TO THE ENCODABLE RANGE at both
  ends. Used by chr$, string$ and the pad family, so a character above U+007F is
  emitted as its real multi-byte sequence and no argument can make it emit a
  byte that UTF-8 does not have. }
function Utf8Char(ACode: Integer): String;

// Finiteness: the invariant, its tests, and its gate --------------------------
{ THE TESTS ARE BIT TESTS, AND THAT IS THE WHOLE POINT.

  A Double's exponent field is all ones for exactly two things: Infinity (zero
  fraction) and NaN (any other). Reading those bits is an integer operation, so
  it cannot signal. Asking the same question with a COMPARISON can, and did --
  see InI64Range below for the crash that taught it.

  IsFiniteD says "an ordinary number": neither NaN nor +/-Infinity. IsNanD
  separates the two cases when a caller needs different words for them. Neither
  ever raises, for any of the 2^64 bit patterns a Double can hold. }
function IsFiniteD(const D: Double): Boolean;
function IsNanD(const D: Double): Boolean;
{ True unless V is a vkDouble holding a non-finite Double. Every other kind --
  int, string, handle, bool -- is finite by construction and answers True. }
function IsFiniteVal(const V: TValue): Boolean;
{ THE FINITENESS GATE, and the ONE supported way to put a computed or a read
  Double into a TValue. On a finite X it fills R and answers NoError; on Inf or
  NaN it leaves R empty and answers the catchable error the engine reports for
  that condition. Public so that every producer outside this unit -- the
  deserialiser, a host API, a library returning a computed Double -- can be one
  call away from meeting the invariant. }
function FiniteD(const AOp: String; const X: Double; out R: TValue): TPhosphorError;

// Arithmetic kernel (each returns an error; on success Result = NoError) ------
{ R MUST NOT ALIAS A OR B. `const` passes a TValue by reference and every
  operator begins by clearing R, so `ValAdd(x, y, x)` zeroes the operand it is
  about to read and answers for 0 instead. The VM never does this (it pops into
  separate locals), and this is written down because a probe written while
  reviewing these functions did, and quietly reported half its cases as safe. }
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
// raising EInvalidOp. NaN and +/-Inf answer False -- BY THE BIT TEST, which is
// checked first and cannot signal, NOT by "their comparisons are all False". That
// reasoning was written here, is wrong, and is what this whole guard layer exists
// to correct: the comparison's VALUE would indeed be False, but on a NaN the
// INSTRUCTION signals invalid-operation before there is a value, and that trap is
// unmasked while a program runs. A caller guards a Double->Int64 conversion with
// this and reports overflow as a catchable error instead of crashing the process.
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
//
// NaN STILL ANSWERS 0, AND THAT IS WHY THESE ALSO RAISE A FLAG. The saturation
// above is justified by "the bounds check that follows rejects it", and nobody had
// ever checked that such a check exists. For +/-Inf it does and the justification
// holds: High/Low sit outside every domain a library accepts, and a sweep of 81
// single-numeric-argument library functions with +/-Inf, one process per case
// through the documented host door, found not one silent answer. For a NaN the
// justification is FALSE. 0 is an ordinary in-range count, and the same sweep
// measured eight functions taking it and answering:
//
//   chr$ -> a byte 0 (a NUL spliced into a string)   bytestr$ -> a byte 0
//   hex$ / bin$ / oct$ -> "0"                        colortostr$ -> "Black"
//   pointer@ -> a live handle                        space$ -> ""
//
// where every one of them used to report a catchable error. NONE of the eight has
// a domain to bound -- every Int64 is a legal argument to them -- so no return
// value of this function can ever carry the fault. It has to be reported OUT OF
// BAND, and that is what NanNarrowed below is for.
//
// A FLAG AND NOT AN EXCEPTION, deliberately. Making these raise would report at
// every library call, because opCall wraps those in a net -- but the VM also calls
// ArgI64 directly at opSeekFile, outside any net. Measured: `seek #1, x` with a
// NaN x reports "seek: position must be 1 or more" catchably today (it was exit
// 217 before this unit's bit test replaced `d <> d`), and a raise would put it
// straight back to exit 217. A flag costs that site nothing.
function ArgI32(const V: TValue): Integer;
function ArgI64(const V: TValue): Int64;

// THE FLAG ArgI32/ArgI64 RAISE, and its contract: it means "an Arg* narrowing has
// met a NaN since this was last cleared", nothing more. It is per-thread, it is
// never cleared by the narrowers themselves, and reading it does not clear it.
// The consumer is TPhosphorRegistry's dispatch, which clears it before every
// library call and turns a raised flag into a catchable error naming that
// function -- so the report lands on the call that narrowed, and a narrowing with
// no consumer (opSeekFile) simply keeps its old, total behaviour.
function NanNarrowed: Boolean;
procedure SetNanNarrowed(AValue: Boolean);

// Checked Int64 primitives (exposed so libraries can test overflow-as-error) -
function TryAddI64(const A, B: Int64; out R: Int64): Boolean;
function TrySubI64(const A, B: Int64; out R: Int64): Boolean;
function TryMulI64(const A, B: Int64; out R: Int64): Boolean;
function TryNegI64(const A: Int64; out R: Int64): Boolean;

implementation

type
  { The same eight bytes seen as a number and as bits. Assigning a Double into
    it is a MOVE, not an arithmetic operation, so it never signals -- which is
    what lets the tests below look at a NaN without touching it. }
  TDoubleBits = packed record
    case Boolean of
      False: (D: Double);
      True:  (Q: QWord);
  end;

const
  ExpMask   = QWord($7FF0000000000000);   // the exponent field, all ones
  FracMask  = QWord($000FFFFFFFFFFFFF);   // the fraction field

var
  InvariantFS: TFormatSettings;

threadvar
  { See NanNarrowed in the interface. Per-thread because two engines on two
    threads must not read each other's narrowings, and because this unit was
    thread-safe before this flag existed (its only other global, InvariantFS, is
    written once at initialization and read-only afterwards) and has to stay so. }
  FNanNarrowed: Boolean;

function NanNarrowed: Boolean;
begin
  Result := FNanNarrowed;
end;

procedure SetNanNarrowed(AValue: Boolean);
begin
  FNanNarrowed := AValue;
end;

function IsFiniteD(const D: Double): Boolean;
var b: TDoubleBits;
begin
  b.D := D;
  Result := (b.Q and ExpMask) <> ExpMask;
end;

function IsNanD(const D: Double): Boolean;
var b: TDoubleBits;
begin
  b.D := D;
  Result := ((b.Q and ExpMask) = ExpMask) and ((b.Q and FracMask) <> 0);
end;

function IsFiniteVal(const V: TValue): Boolean;
begin
  Result := (V.Kind <> vkDouble) or IsFiniteD(V.Num);
end;

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
  { `d <> d` WAS THE NaN TEST HERE, and it is the bug this whole guard layer is
    about: the VALUE compares unequal to itself, but the INSTRUCTION that asks
    signals invalid-operation first, and that trap is unmasked while a program
    runs. So the line documented as "NaN answers 0" killed the process instead.
    The bit test cannot signal, and answers the same 0.

    AND THE 0 IS RECORDED, because it is a value the caller's bounds check
    accepts. Removing the trap removed the only report eight library functions
    ever had; the flag is that report, and it costs this function one store on a
    path a correct program never takes. See NanNarrowed in the interface. }
  if IsNanD(d) then
  begin
    FNanNarrowed := True;
    Exit(0);
  end;
  // Past the NaN, ordered comparison is safe again: an infinity compares
  // cleanly, and saturates to the limit it is on the far side of.
  if d >= 9223372036854775808.0 then Result := High(Int64)
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
  a later operation and raise there.

  THAT INVARIANT IS A CLAIM ABOUT PRODUCERS, AND IT WAS BEING MADE ON TRUST. It
  holds only if every route into the value space passes through here, and the
  routes are not all in this file: the lexer (a literal), the .pbc reader (eight
  bytes from a file), INPUT (text from a user), a library's computed result, and
  a host calling into the engine with arguments of its own. Each has to gate its
  own door -- and one of them, the constant pool, was not gating it, so a single
  flipped bit in a shipped .pbc put a NaN into a program and the first `if x < 1`
  killed the process.

  A door left open must therefore not be fatal. The invariant is defended from
  BOTH ends: this gate keeps a non-finite Double out of every result, and
  FiniteOperand (below) keeps one out of every operand, so a value that gets in
  anyway is reported by the next OPERATOR that meets it instead of trapping in
  it. The unmasked trap stays unmasked, and stays unreachable.

  AN OPERATOR IS NOT THE ONLY THING A NaN CAN MEET, AND SAYING OTHERWISE WAS
  THIS UNIT'S OWN WORST CLAIM. What it usually meets first is a LIBRARY
  ARGUMENT -- ArgI32/ArgI64 -- and those are total by contract: they saturate and
  report nothing. Measured 2026-09-07 through the documented host door, one
  process per case: of 81 single-numeric-argument library functions given a NaN,
  eight answered a wrong value with no error at all, because the NaN reached a
  narrower and not an operator. That third defence is now written down where it
  belongs (see ArgI32/ArgI64 and NanNarrowed), and this paragraph exists so the
  claim above is never again read as covering doors it does not cover. }
function FiniteD(const AOp: String; const X: Double; out R: TValue): TPhosphorError;
begin
  if IsFiniteD(X) then
  begin
    R := ValDouble(X);
    Exit(NoError());
  end;
  R := Default(TValue);
  if IsNanD(X) then
    Result := MakeError(peRuntime, AOp + ' has no numeric result')
  else
    Result := MakeError(peIntOverflow, 'floating point overflow in ' + AOp);
end;

{ THE OPERAND GATE -- the other half of the invariant, and the half that was
  missing.

  FiniteD keeps a non-finite Double out of the RESULT of an operation. Nothing
  kept one out of an OPERAND, and the gate is worthless without it: a value that
  entered the space some other way -- a .pbc constant pool, a host handing the
  engine an argument -- reaches an operator that then executes `Inf - Inf` or
  `NaN < 1` and takes the whole process down before FiniteD is ever called. The
  crash is not in the arithmetic; it is in the COMPARISON, and no result check
  can be reached from behind one.

  So every operator below asks this first, and answers a catchable error with
  the same code FiniteD would have used for the same condition: peRuntime for a
  NaN, peIntOverflow for an infinity. `on error goto` sees one vocabulary either
  way.

  THE GATE IS THE PRIMARY DEFENCE AND THE NET BELOW IS THE SECOND ONE, and they
  are not alternatives. The gate is what gives a good message -- "^ was given a
  value that is not a number" instead of "invalid floating point operation" --
  and it is what removes the poison instead of postponing it. The net exists for
  the case the gate cannot see: an FPU trap raised by an operation on two
  perfectly finite operands. See TrappedInOperator. }
function FiniteOperand(const AOp: String; const V: TValue): TPhosphorError;
begin
  Result := NoError();
  if V.Kind <> vkDouble then Exit;
  if IsFiniteD(V.Num) then Exit;
  if IsNanD(V.Num) then
    Result := MakeError(peRuntime, AOp + ' was given a value that is not a number')
  else
    Result := MakeError(peIntOverflow, AOp + ' was given an infinite value');
end;

function FiniteOperands(const AOp: String; const A, B: TValue): TPhosphorError;
begin
  Result := FiniteOperand(AOp, A);
  if IsError(Result) then Exit;
  Result := FiniteOperand(AOp, B);
end;

{ THE NET, AND WHY THIS UNIT NEEDS ONE EVEN THOUGH ITS OPERATORS ARE TOTAL.

  The unit header promises that errors are RETURNED, never raised. Until this
  function existed that promise was CONDITIONAL on an FPU mask installed by a
  different unit: TPhosphorVM.Run and RunFrom add exOverflow to the mask, which
  is what turns `1e308 * 10` into +Inf for FiniteD to report. TPhosphorVM's
  callback entry point does not install it, so the DOCUMENTED EMBEDDING PATTERN
  (docs/embedding.md: Prepare, then CallFunction) runs the very same operators
  with overflow UNMASKED. Measured on 2026-09-07, one case per process:

    x * 10        EOverflow, exit 217, unhandled
    x ^ 400       EOverflow, exit 217, unhandled
    x + x         EOverflow, exit 217, unhandled
    x / 1e-10     EOverflow, exit 217, unhandled

  all with x = 1e308 and every operand finite -- so the operand gate is not
  even reached, and there is no NaN anywhere in the story. The same expressions
  inside Run report `floating point overflow in *` catchably. One engine, two
  behaviours, decided by which door the host came in.

  A unit cannot promise "never raises" and then rely on a mask its caller
  happened to install. So the arithmetic operators carry a net, and the net
  answers the SAME error the masked path answers -- peIntOverflow with FiniteD's
  own wording -- so the two doors agree instead of differing.

  WHAT IT DOES NOT DO. It does not replace the operand gate: a net cannot say
  which operand was bad, and it would leave the poison in the value space for
  the next operator to trap on. Every message a program actually sees still
  comes from the gate; this only ever fires where the gate has nothing to look
  at. Nor does it recover the VALUE an unmasked underflow or inexact would have
  produced -- the trap fires before the result exists, so there is nothing to
  return but an error.

  ITS SCOPE IS exOverflow, and that is a deliberate limit rather than an
  oversight. Overflow is the one FPU trap FPC leaves unmasked by default, so it
  is the one a host actually meets. UNDERFLOW, DENORMAL and INEXACT are masked
  both by FPC's startup default and by Run, and a host that unmasks them has a
  process in which FPC's own FloatToStr cannot format a Double -- measured
  2026-09-07: with exPrecision unmasked, a bare `AsDouble(ValInt(High(Int64)))`
  exits 217, before any operator is entered. The net turns the operators' share
  of that into a catchable error (with EInvalidOp's wording, which is what FPC
  reports an inexact trap as); it does not and cannot make the configuration
  work. ValCompare, AsDouble and TryD2I stay outside the net for the same
  reason -- see the comment on ValCompare.

  COST, MEASURED RATHER THAN ASSUMED. 3,000,000 iterations of a loop that does
  nothing but arithmetic (`x = x * c`, `s = s + x`, `n = n + 1`), best of eleven
  runs of bin\phosphor.exe:

    no net                                     4.771 s
    net in a wrapper around each operator      5.139 s   (+7.7%)
    net inside each operator's own body        4.892 s   (+2.5%)

  Which is why it is written the third way. The first way is the tidier diff and
  costs three times as much: the extra CALL is most of the price, not the try
  block -- FPC 3.2.2 on x86_64-win64 uses table-driven SEH, so entering a try
  emits no instructions. 2.5% on a loop that is 100% arithmetic is the ceiling,
  not the typical cost; a program that also touches strings, files or the
  registry pays proportionally less. }
{ IT CATCHES ARITHMETIC FAULTS AND NOTHING ELSE. Each operator's handler names
  EMathError (EInvalidOp, EZeroDivide, EOverflow, EUnderflow) and EIntError
  (EDivByZero, ERangeError, EIntOverflow) -- sysutilh.inc:143-153 -- and not
  their common ancestor and not Exception.

  A net that caught Exception would also swallow EOutOfMemory from a string
  concatenation, EAccessViolation, and EStackOverflow, and report each of them
  as "+ could not be computed". Those are not arithmetic faults, they are not
  this unit's to answer for, and turning them into a catchable BASIC error would
  let a program carry on inside a process that is already broken. They propagate
  exactly as they did before the net existed: to opCall's net if a library call
  is on the stack, and to the host otherwise. }
function TrappedInOperator(const AOp: String; E: Exception;
                           out R: TValue): TPhosphorError;
begin
  R := Default(TValue);
  if E is EOverflow then
    // FiniteD's exact wording for the same condition, so `on error goto` reads
    // one vocabulary whether the mask was installed or not.
    Result := MakeError(peIntOverflow, 'floating point overflow in ' + AOp)
  else if E is EZeroDivide then
    Result := MakeError(peDivByZero, 'division by zero in ' + AOp)
  else if E is EInvalidOp then
    Result := MakeError(peRuntime, AOp + ' has no numeric result')
  else
    Result := MakeError(peRuntime, AOp + ' could not be computed: ' + E.Message);
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

{ TOTAL BY DESIGN, INCLUDING ON A VALUE THE INVARIANT FORBIDS. FloatToStr reads
  the exponent bits rather than comparing, so it answers 'Nan' / '+Inf' / '-Inf'
  instead of signalling, and this is the ONE operation deliberately left able to
  see a non-finite Double: reporting a poisoned value is how a program and an
  error message name it. Every arithmetic operator refuses it instead. }
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

// --- the UTF-8 codepoint layer ----------------------------------------------
{ BYTE 1 ALWAYS BEGINS THE FIRST CHARACTER, and that single line is the whole
  fix for a family of wrong answers.

  This table used to record a start only for a byte that is NOT a continuation
  byte ($80..$BF). An INTERIOR continuation byte therefore attaches to the
  character in front of it, which is right -- but a string that BEGINS with one
  has no character in front, so its leading bytes fell outside every span. The
  invariant "every byte belongs to exactly one codepoint" quietly failed, and
  with it everything built on this table:

    s$ = bytemid$("cafe", 5, 1) + "a"   ' a lone 0xA9, then 'a'
    left$(s$, 0)      -> 0xA9           ' left$(x,0) must be "" for EVERY x
    insert$(s$,"Z",1) -> A9 5A A9 61    ' 2 bytes in, 4 out: 0xA9 INVENTED
    reverse$(s$)      -> 61             ' 0xA9 silently dropped

  because Utf8Left(S,0) sliced up to Result[0], which was 2 rather than 1, while
  Utf8Right returned the whole string -- so the orphan was emitted twice by one
  and never by the other.

  A string like that is malformed UTF-8, and the language HANDS IT TO YOU: it is
  what bytemid$ or buffer_slice$ on a chunk boundary returns, and what
  docs/libraries/regex.md says regex_find$(".", ...) returns for one byte of a
  multi-byte character. The slicers must stay total on it.

  THE MIRROR. A valid UTF-8 string never starts with a continuation byte, so for
  every such string byte 1 was already recorded and this produces the identical
  table it always did. The change is reachable ONLY from a string whose first
  byte is $80..$BF. }
function Utf8Starts(const S: String): TInt64DynArray;
var i, n: Integer;
begin
  Result := nil;
  SetLength(Result, Length(S) + 2);
  n := 0;
  if Length(S) > 0 then
  begin
    Result[0] := 1;     // whatever byte 1 is, it starts the first character
    n := 1;
  end;
  for i := 2 to Length(S) do
    if (Ord(S[i]) < $80) or (Ord(S[i]) >= $C0) then   // not a continuation byte
    begin
      Result[n] := i;
      Inc(n);
    end;
  Result[n] := Length(S) + 1;   // sentinel
  SetLength(Result, n + 1);
end;

{ COUNTS IN PLACE. This was `Length(Utf8Starts(S)) - 1`, which built a table of
  one Int64 per input BYTE only to ask how many entries it had -- eight bytes of
  heap for every byte of string, transiently, on every len(), asc(), left$(),
  right$(), mid$() and pad.

  Under all four documented ceilings including a 32 MB memory one, three lines --
  `s$ = string$(200000000, 65)`, `n% = len(s$)`, `println n%` -- reached a peak of
  1716 MB and answered rc 0, and it scaled linearly: 500 MB of string reached
  4291 MB. Counting instead of tabulating is the same rule, one byte at a time,
  and the same measurement is 190 MB and three times faster. Verified byte for
  byte across all 138 .bas files under tests/.

  Utf8Left and Utf8Right still build the table, because they need the offsets. }
function Utf8Len(const S: String): Integer;
var
  i: Integer;
begin
  Result := 0;
  if Length(S) = 0 then Exit;
  Result := 1;                  // whatever byte 1 is, it starts the first character
  for i := 2 to Length(S) do
    if (Ord(S[i]) < $80) or (Ord(S[i]) >= $C0) then   // not a continuation byte
      Inc(Result);
end;

function Utf8Left(const S: String; ACount: Integer): String;
var st: TInt64DynArray; n: Integer;
begin
  st := Utf8Starts(S);
  n := Length(st) - 1;
  if ACount < 0 then ACount := 0;
  if ACount >= n then Exit(S);
  Result := Copy(S, 1, st[ACount] - 1);
end;

function Utf8Right(const S: String; ACount: Integer): String;
var st: TInt64DynArray; n: Integer;
begin
  st := Utf8Starts(S);
  n := Length(st) - 1;
  if ACount < 0 then ACount := 0;
  if ACount >= n then Exit(S);
  Result := Copy(S, st[n - ACount], MaxInt);
end;

{ THE TOP GUARD IS THE MIRROR OF THE BOTTOM ONE, and it was missing.

  `Chr($F0 or (c shr 18))` overflows a byte once c reaches 2^21, and Chr takes
  the low 8 bits of the result: chr$(2147483647) emitted FF BF BF BF. 0xFF
  CANNOT OCCUR IN UTF-8 at all, at any position, so that is not a wrong
  character -- it is a string no reader can decode, produced with no error and
  no round trip (asc() answered 2097151 for the 2147483647 that went in).

  U+10FFFF is the last encodable codepoint, so the range clamps there exactly as
  it already clamped at 0 below. string$, lfill$, rfill$ and center$ all build
  runs of padding through this, so an unclamped code produced whole runs of
  impossible bytes. }
function Utf8Char(ACode: Integer): String;
begin
  if ACode < 0 then ACode := 0;
  if ACode > $10FFFF then ACode := $10FFFF;
  if ACode < $80 then Result := Chr(ACode and $FF)
  else if ACode < $800 then
    Result := Chr($C0 or (ACode shr 6)) + Chr($80 or (ACode and $3F))
  else if ACode < $10000 then
    Result := Chr($E0 or (ACode shr 12)) + Chr($80 or ((ACode shr 6) and $3F)) +
              Chr($80 or (ACode and $3F))
  else
    Result := Chr($F0 or (ACode shr 18)) + Chr($80 or ((ACode shr 12) and $3F)) +
              Chr($80 or ((ACode shr 6) and $3F)) + Chr($80 or (ACode and $3F));
end;

{ THE GUARD THAT WAS NOT A GUARD.

  The comment here used to say NaN answers False "because their comparisons are
  all False". That is true of the VALUE and false of the INSTRUCTION. An ordered
  compare against a NaN raises INVALID-OPERATION, and the VM leaves that trap
  unmasked precisely BECAUSE this function is supposed to be safe -- so the one
  routine every Double->Int64 conversion in the engine is guarded by was itself
  the crash: InI64Range(NaN) exited 217 with an unhandled EInvalidOp, and every
  caller written to be safe because it calls TryD2I inherited it.

  The fix is to answer the non-finite cases from the BITS, before any comparison
  runs. The answer is unchanged -- NaN and both infinities are still False, and
  every finite Double still gets exactly the comparison it got before. }
function InI64Range(const D: Double): Boolean;
begin
  if not IsFiniteD(D) then Exit(False);
  // 2^63 (= 9223372036854775808) and -2^63 are both exactly representable as a
  // Double; a value strictly inside [-2^63, 2^63) rounds to an Int64 safely.
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
  { THE MinInt EDGES ARE TESTED FIRST, and the order is the whole fix.

    Pascal short-circuits `or` left to right, so these two tests written AFTER
    `R div B` never ran when it mattered: for A = Low(Int64), B = -1 the wrapped
    product is Low(Int64) again, so `R div B` is `Low(Int64) div -1` -- the x86
    idiv whose quotient does not fit -- and it TRAPPED, killing the process with
    an uncatchable EIntOverflow.

    The proof it was an ordering bug and not a policy is that the SAME
    multiplication survived with the operands swapped: for A = -1, B = Low(Int64),
    `R div B` is 1 <> -1, so the first term answered False cleanly. No rule about
    multiplication depends on which factor is written first. }
  if ((A = Low(Int64)) and (B = -1)) or ((B = Low(Int64)) and (A = -1)) then
    Exit(False);
  // Recover the operand; a mismatch means the product did not fit.
  if R div B <> A then
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
{ EVERY ARITHMETIC OPERATOR FROM HERE TO ValPow HAS THE SAME SHAPE: its whole
  body sits inside `try ... except on E: EMathError ... on E: EIntError ... end`,
  each arm calling TrappedInOperator. Those two classes and NOT their common
  ancestor and NOT Exception -- an earlier draft of this sentence said
  `on E: Exception`, which would have told a reader that an EAccessViolation
  raised under an operator is swallowed and reported as "+ could not be computed".
  It is not; see TrappedInOperator's second comment for why that matters.
  The frame is around the WHOLE body on purpose -- that is what makes the claim
  checkable by reading rather than by enumerating: there is no instruction in
  the operator that is outside it, so no future edit can add an FP operation
  that escapes the net. Each `Exit(...)` inside still returns exactly the error
  it returned before; Exit from a try block is ordinary control flow, not an
  exception. See TrappedInOperator for why the net exists and what it costs. }
function Negate(const A: TValue; out R: TValue): TPhosphorError;
var
  n: Int64;
begin
  try
    R := Default(TValue);
    Result := FiniteOperand('unary minus', A);
    if IsError(Result) then Exit;
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
  except
    on E: EMathError do Result := TrappedInOperator('unary minus', E, R);
    on E: EIntError  do Result := TrappedInOperator('unary minus', E, R);
  end;
end;

function ValAdd(const A, B: TValue; out R: TValue): TPhosphorError;
var
  n: Int64;
begin
  try
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
    Result := FiniteOperands('+', A, B);
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
  except
    on E: EMathError do Result := TrappedInOperator('+', E, R);
    on E: EIntError  do Result := TrappedInOperator('+', E, R);
  end;
end;

function ValSub(const A, B: TValue; out R: TValue): TPhosphorError;
var
  n: Int64;
  k, cn: Integer;
  d: Double;
begin
  try
    R := Default(TValue);
    // 'string - n' truncates the last n characters (the string keeps the rest).
    if A.Kind = vkString then
    begin
      if not IsNumeric(B) then
        Exit(MakeError(peTypeMismatch, 'cannot subtract ' + KindName(B.Kind) + ' from a string'));
      // The right operand is a COUNT, so it is arithmetic and gets the same gate
      // as any other: the comparisons two lines down are ordered, and an ordered
      // comparison against a NaN signals before it can answer.
      Result := FiniteOperand('-', B);
      if IsError(Result) then Exit;
      // Compare BEFORE narrowing. Round(1e30) raises EInvalidOp, and "remove more
      // characters than the string has" is a clamp, not an error.
      { AND THE COUNT IS IN CHARACTERS, which is what the line above has always
        claimed and what the operator did not do. Length() and Copy() are BYTE
        operations: `"cafe" - 1` with an accented e cut one byte off a two-byte
        character, so the result ended in a lone $C3 -- invalid UTF-8, len()
        unchanged at 4, and `t$ = "caf"` false while left$(s$,3) = "caf" was
        true. Two characters off the same string gave "caf", not "ca".
        Counting codepoints makes `s$ - n` agree with left$(s$, len(s$) - n),
        which is the only thing it can honestly mean. }
      d := AsDouble(B);
      cn := Utf8Len(A.Str);
      if d >= cn then k := 0
      else if d <= 0 then k := cn
      else k := cn - Round(d);
      R := ValStr(Utf8Left(A.Str, k));
      Exit(NoError());
    end;
    Result := NumericPair(A, B, '-');
    if IsError(Result) then Exit;
    Result := FiniteOperands('-', A, B);
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
  except
    on E: EMathError do Result := TrappedInOperator('-', E, R);
    on E: EIntError  do Result := TrappedInOperator('-', E, R);
  end;
end;

function ValMul(const A, B: TValue; out R: TValue): TPhosphorError;
var
  n: Int64;
begin
  try
    R := Default(TValue);
    Result := NumericPair(A, B, '*');
    if IsError(Result) then Exit;
    Result := FiniteOperands('*', A, B);
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
  except
    on E: EMathError do Result := TrappedInOperator('*', E, R);
    on E: EIntError  do Result := TrappedInOperator('*', E, R);
  end;
end;

function ValDivReal(const A, B: TValue; out R: TValue): TPhosphorError;
begin
  try
    R := Default(TValue);
    Result := NumericPair(A, B, '/');
    if IsError(Result) then Exit;
    // Before the `= 0` below: that is an ordered compare too, and a NaN divisor
    // signalled there rather than reaching the division at all.
    Result := FiniteOperands('/', A, B);
    if IsError(Result) then Exit;
    if AsDouble(B) = 0 then
      Exit(MakeError(peDivByZero, 'division by zero'));
    // The slash is ALWAYS real division: int / int is a double.
    Exit(FiniteD('/', AsDouble(A) / AsDouble(B), R));
  except
    on E: EMathError do Result := TrappedInOperator('/', E, R);
    on E: EIntError  do Result := TrappedInOperator('/', E, R);
  end;
end;

function ValDivInt(const A, B: TValue; out R: TValue): TPhosphorError;
var
  ai, bi, q: Int64;
begin
  try
    R := Default(TValue);
    Result := NumericPair(A, B, '\');
    if IsError(Result) then Exit;
    Result := FiniteOperands('\', A, B);
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
  except
    on E: EMathError do Result := TrappedInOperator('\', E, R);
    on E: EIntError  do Result := TrappedInOperator('\', E, R);
  end;
end;

function ValMod(const A, B: TValue; out R: TValue): TPhosphorError;
var
  ai, bi: Int64;
  q: Double;
begin
  try
    R := Default(TValue);
    Result := NumericPair(A, B, 'mod');
    if IsError(Result) then Exit;
    Result := FiniteOperands('mod', A, B);
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
  except
    on E: EMathError do Result := TrappedInOperator('mod', E, R);
    on E: EIntError  do Result := TrappedInOperator('mod', E, R);
  end;
end;

{ THE DOMAIN IS CHECKED BEFORE Power IS CALLED, because Power does not check it
  and the traps it raises are not the ones the VM masks.

  The VM masks overflow, underflow, precision and denormal, and deliberately
  leaves INVALID-OPERATION and DIVIDE-BY-ZERO unmasked, on the premise that
  neither can arise from a finite value space. Power breaks that premise from
  inside, and WHERE it breaks it was read out of the RTL rather than guessed --
  C:\lazarus\fpc\3.2.2\source\rtl\objpas\math.pp, `power` at line 1044 and
  `intpower` at 1057:

      power:    if (abs(exponent)<=maxint) and (frac(exponent)=0.0) then
                  result:=intpower(base,trunc(exponent))
                else
                  result:=exp(exponent * ln (base));
      intpower: if exponent<0 then
                  base:=1.0/base;          // the BASE, not the result

  So a whole negative exponent divides by the BASE, once, up front: `0 ^ -1` is
  literally 1.0/0.0 and raises EZeroDivide. Any non-whole exponent goes to
  exp(e*ln(b)), and ln of a negative base raises EInvalidOp. Neither result ever
  reaches FiniteD, so the finiteness gate downstream cannot help -- the process
  was already dead. `0 ^ -1` and `(-8) ^ 0.5` each killed it, and the two guards
  below are what stop them.

  THERE IS NO `1.0/result` IN THIS RTL, and an earlier revision of this function
  was rejected for assuming there was: it replaced Power(base, negative) with
  1.0/Power(base, positive), which is a DIFFERENT computation -- the positive
  power overflows to +Inf where the reciprocated base does not, and 1.0/+Inf is
  0. It silently answered 0 for the entire subnormal result band, 8964 swept
  values including `2 ^ -1074` and `10 ^ -310`. The branch is gone; a negative
  whole exponent is handed to Power exactly as it always was. If this ever needs
  revisiting, OPEN math.pp FIRST -- the comment above quotes what is there.

  The third case is subtler and was found by probing rather than reported: Power
  takes its intpower path only for an exponent that fits an Integer, so a NEGATIVE
  base with a whole exponent past MaxInt fell into the ln path too. The magnitude
  there is the same as for the positive base; only the sign has to be decided, and
  above 2^53 every representable Double is even. }
function ValPow(const A, B: TValue; out R: TValue): TPhosphorError;
var
  { base/expo, not b/e: Pascal is case-insensitive and the parameters are
    named A and B, so a local `b` collides with the operand it is read from. }
  base, expo, mag: Double;
  negative: Boolean;
begin
  try
    R := Default(TValue);
    Result := NumericPair(A, B, '^');
    if IsError(Result) then Exit;
    // Every domain test below is an ordered comparison, so the operands have to be
    // finite before the FIRST of them runs -- the checks that make this operator
    // safe were themselves the unsafe part on a non-finite input.
    Result := FiniteOperands('^', A, B);
    if IsError(Result) then Exit;
    base := AsDouble(A);
    expo := AsDouble(B);

    if (base = 0) and (expo < 0) then
      Exit(MakeError(peDivByZero,
        'division by zero: ' + ValToStr(A) + ' ^ ' + ValToStr(B)));

    if (base < 0) and (expo <> Int(expo)) then
      Exit(MakeError(peRuntime,
        '^ has no numeric result: ' + ValToStr(A) + ' ^ ' + ValToStr(B) +
        ' (a negative base needs a whole-number exponent)'));

    if (base < 0) and (Abs(expo) > MaxInt) then
    begin
      mag := Power(-base, expo);
      // Above 2^53 consecutive integers are no longer representable, so every
      // Double that large is even and the result is positive.
      negative := (Abs(expo) <= 9007199254740992.0) and Odd(Trunc(expo));
      if negative then mag := -mag;
      Exit(FiniteD('^', mag, R));
    end;

    // '^' is always a double (2 ^ 0.5 is meaningful).
    // A NEGATIVE EXPONENT IS PASSED STRAIGHT THROUGH -- see the header comment:
    // intpower reciprocates the base before it multiplies, which is the ordering
    // that keeps `2 ^ -1074` at the smallest subnormal instead of underflowing an
    // intermediate to zero. Rewriting this as a reciprocal of the positive power
    // is the one change this function must never take again.
    Exit(FiniteD('^', Power(base, expo), R));
  except
    on E: EMathError do Result := TrappedInOperator('^', E, R);
    on E: EIntError  do Result := TrappedInOperator('^', E, R);
  end;
end;

{ ValCompare is deliberately left WITHOUT a net, and the reason is narrower than
  "a comparison cannot signal" -- which is true of the compare instruction and
  not of this function.

  With both operands finite (the gate below sees to that), the FP instructions
  this function can execute are an ordered compare of two Doubles, which signals
  nothing, and -- on the mixed int/double path -- an Int64-to-Double widening,
  whose only possible exception is INEXACT. Inexact is masked by FPC's own
  startup default and again by TPhosphorVM.Run, so under every mask this engine
  or its compiler installs, ValCompare cannot raise.

  MEASURED, not assumed: with exPrecision deliberately UNMASKED,
  `ValCompare(coLT, ValInt(High(Int64)), ValDouble(1.5))` exits 217 with
  EInvalidOp (FPC reports the inexact trap under that class). So does a bare
  `AsDouble(ValInt(High(Int64)))`, and so does `TryD2I(3.7)`. That configuration
  is out of scope on purpose: in it, FPC's own FloatToStr cannot format a
  Double, so nothing in this unit -- netted or not -- would be usable anyway.
  The net exists for exOVERFLOW, which FPC leaves UNMASKED by default and which
  a host reaches through TPhosphorVM.CallUserFunc; see TrappedInOperator. }
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
    { A COMPARISON IS WHERE THIS CLASS ACTUALLY KILLED THE PROCESS -- not the
      arithmetic, the compare. `if x < 1`, on a variable holding a NaN that
      arrived in a .pbc constant pool, was exit 217 with an unhandled EInvalidOp,
      past `on error goto`, in the two lines below.

      A comparison also has no honest answer to give here: the -1/0/1 collapse
      cannot express "unordered", so quietly answering False for every operator
      would leave a poisoned value inside a program that believes it tested it.
      The refusal IS the report. The gate sits in this branch only, so comparing
      a number with a string still says what it always said -- that is a type
      error whatever the number is. }
    Result := FiniteOperands('comparison', A, B);
    if IsError(Result) then Exit;
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
  { THE STORE IS THE OTHER DOOR INTO THE VALUE SPACE. A variable is where a value
    OUTLIVES the operation that made it, so a non-finite Double stored into one is
    a poisoned cell any later expression can pick up -- and the fault would then
    be reported at some unrelated line that merely reads the variable. Rejecting
    it here names the value at the assignment that tried it.

    Only the three types that CAN hold a Double are asked. Storing one into a
    string$, a bool? or a handle@ is a type error whatever the number is, and
    that message says more than this one would. }
  if (V.Kind = vkDouble) and (T in [vtNumber, vtInt, vtAny]) and
     (not IsFiniteD(V.Num)) then
  begin
    // The same two codes FiniteOperand and FiniteD use for the same two
    // conditions, so a handler reads one vocabulary wherever the fault surfaces.
    if IsNanD(V.Num) then
      Exit(MakeError(peRuntime,
        ValToStr(V) + ' is not a number and cannot be stored'));
    Exit(MakeError(peIntOverflow,
      ValToStr(V) + ' is not a finite number and cannot be stored'));
  end;
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
