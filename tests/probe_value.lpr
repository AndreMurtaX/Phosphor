{******************************************************************************
  probe_value -- a Pascal unit-test of the five-kind value kernel

  Exercises PhosphorValue directly -- no lexer, no VM -- because the promotion
  matrix and overflow-as-error are the load-bearing, most-flagged part of the
  first increment.

  WITH ONE SECTION THAT DELIBERATELY DOES USE THE WHOLE ENGINE:
  CheckLibraryDoorOnNonFinite. Testing this unit in isolation is how a defect of
  exactly this shape shipped -- every operator answered a NaN correctly and fifty
  library doors still took one silently, because what a NaN meets first is a
  library ARGUMENT and not an operator. That claim can only be checked from the
  outside, so that one section calls in through Prepare + CallFunction.

  AND ONE SECTION THAT TESTS AGAINST AN ORACLE RATHER THAN AGAINST ITSELF:
  CheckFloatRemainder. Two of this probe's own expectations recorded a wrong
  `mod` answer for months, because a value chosen while reading the code agrees
  with the code. That section compares the Double branch against the int% branch,
  against C's fmod, and against the definition of a remainder swept over the
  whole exponent range.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure.
  Run with --fail to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_value;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, Math, PhosphorErrors, PhosphorValue, PhosphorEngine;

const
  { TYPED Double constants, because an untyped float literal in FPC source is an
    Extended -- 80 bits on Linux x86-64, 64 on Win64 -- and comparing a Double
    against one promotes both, so the comparison asks about the compiler's
    literal parser rather than about this engine. Three assertions were written
    the inline way, were green on Windows and red on Linux, and this is the fix. }
  MaxD: Double            = 1.7976931348623157e308;
  SmallestDenormD: Double = 4.9406564584124654e-324;
  SmallestNormalD: Double = 2.2250738585072014e-308;
  { The true values the three subnormal power checks approach. The answer differs
    in its last digits between the two platforms and both are correct to the
    precision a subnormal has; see the comment at those checks. }
  Ref10m310: Double  = 1e-310;
  Ref10m320: Double  = 1e-320;
  Ref15m1800: Double = 1.0857596514320163e-317;
  { The divisors the float-remainder cases compare against, TYPED for the same
    reason: `r.Num < 1e-308` promotes both sides to Extended on Linux and asks
    the compiler's literal parser a question this probe is not about. }
  Ref1em308: Double  = 1e-308;
  { 2^53, the point above which an integer stops having a Double of its own --
    exactly representable, so this one is safe either width, and it is typed for
    the same reason as its neighbours. }
  Pow2_53: Double    = 9007199254740992.0;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;
  { What is being exercised right now. A finiteness regression does not return a
    wrong answer -- it TRAPS, and a probe that dies mid-run prints no "ok:/fail:"
    line at all, so the suite can only report that the probe "did not run". That
    says nothing about which guard broke. The run is wrapped (see the main body)
    and this names the region the trap came from. }
  Stage: String = '';

{ A power that must land inside the subnormal band: no error, a Double, not zero,
  below the smallest NORMAL double, and within 1e-12 relative of the true value.
  The regression these guard against answered 0, whose relative error is 1. }
function SubnormalNear(const E: TPhosphorError; const V: TValue;
                       const ATrue: Double): Boolean;
begin
  Result := (not IsError(E)) and (V.Kind = vkDouble) and (V.Num <> 0.0) and
            (Abs(V.Num) < SmallestNormalD) and
            (Abs(V.Num - ATrue) <= 1e-12 * Abs(ATrue));
end;

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

{ ----------------------------------------------------------------------------
  THE FINITENESS INVARIANT, TESTED FROM BOTH ENDS.

  PhosphorValue promises that no TValue ever holds a non-finite Double, and
  TPhosphorVM.Run cites that promise as its reason for leaving the FPU's
  INVALID-OPERATION trap unmasked while a program runs. The promise is about
  PRODUCERS, and producers live all over the engine -- the lexer, INPUT, the
  .pbc reader, every library that returns a computed number, every host that
  calls in with arguments of its own. One of them will eventually be wrong.

  So the guarantee this section pins is not "it never gets in". It is: IF one
  gets in, every exported function of this unit still ANSWERS -- with the right
  value where there is one, and with a catchable error where there is not.
  Nothing traps. On 2026-09-06 twenty-one of these calls exited 217 with an
  unhandled EInvalidOp, including InI64Range, the guard the whole engine
  converts Doubles to Int64 through, whose own comment said NaN answers False.

  The three poisons are the whole space of non-finite Doubles: a NaN and the two
  infinities. Each is built from its BITS, because writing 0/0 to make one is
  itself the trap under test.
  ---------------------------------------------------------------------------- }
function PoisonD(k: Integer): Double;
var q: QWord;
begin
  case k of
    0: q := QWord($7FF8000000000000);   // a quiet NaN
    1: q := QWord($7FF0000000000000);   // +Infinity
  else q := QWord($FFF0000000000000);   // -Infinity
  end;
  Result := PDouble(@q)^;
end;

function PoisonName(k: Integer): String;
begin
  case k of 0: Result := 'NaN'; 1: Result := '+Inf'; else Result := '-Inf'; end;
end;

{ The error a non-finite OPERAND must produce: peRuntime for a NaN (there is no
  numeric answer), peIntOverflow for an infinity (the magnitude is the problem) --
  the same two codes FiniteD gives when an operation PRODUCES one, so an
  `on error goto` handler reads one vocabulary either way. }
function PoisonCode(k: Integer): TPhosphorErrorCode;
begin
  if k = 0 then Result := peRuntime else Result := peIntOverflow;
end;

procedure CheckNonFinite;
var
  k: Integer;
  d: Double;
  p, two, r: TValue;
  e: TPhosphorError;
  i: Int64;
  nm: String;

  procedure Err(const E2: TPhosphorError; const What: String);
  begin
    Report(E2.Code = PoisonCode(k), What + ' refuses ' + nm);
  end;

begin
  for k := 0 to 2 do
  begin
    d := PoisonD(k);
    p := ValDouble(d);
    two := ValDouble(2.0);
    nm := PoisonName(k);

    // --- the tests themselves, which must not need the thing they test ------
    Stage := 'the finiteness tests, on ' + nm;
    Report(not IsFiniteD(d), 'IsFiniteD says ' + nm + ' is not finite');
    Report(IsNanD(d) = (k = 0), 'IsNanD separates ' + nm + ' from the infinities');
    Report(not IsFiniteVal(p), 'IsFiniteVal sees through the cell for ' + nm);
    e := FiniteD('probe', d, r);
    Report(e.Code = PoisonCode(k), 'FiniteD refuses to build a cell from ' + nm);

    Stage := 'the Double->Int64 guards, on ' + nm;
    // --- the guards every Double->Int64 conversion in the engine goes through
    Report(not InI64Range(d), 'InI64Range answers False for ' + nm);
    i := 99;
    Report((not TryD2I(d, i)) and (i = 0), 'TryD2I answers False for ' + nm);

    Stage := 'the saturating narrowers, on ' + nm;
    // --- the SATURATING narrowers keep their documented answers -------------
    // ...AND RAISE THE FLAG FOR A NaN AND ONLY FOR A NaN. The answers below are
    // unchanged from the day they were written; what is new is the second half of
    // each pair. A NaN narrows to 0, which is an ordinary in-range count, so the
    // saturated value cannot carry the fault and something out of band has to.
    // An infinity narrows to High/Low, which every domain rejects, so it must NOT
    // raise the flag -- an infinity that reported here would refuse the +/-Inf
    // band this unit has always let through.
    SetNanNarrowed(False);
    if k = 0 then
    begin
      Report(ArgI64(p) = 0, 'ArgI64 answers 0 for NaN');
      Report(NanNarrowed, 'ArgI64 RAISES NanNarrowed for NaN');
      SetNanNarrowed(False);
      Report(ArgI32(p) = 0, 'ArgI32 answers 0 for NaN');
      Report(NanNarrowed, 'ArgI32 RAISES NanNarrowed for NaN');
    end
    else if k = 1 then
    begin
      Report(ArgI64(p) = High(Int64), 'ArgI64 saturates high for +Inf');
      Report(ArgI32(p) = High(Integer), 'ArgI32 saturates high for +Inf');
      Report(not NanNarrowed, 'neither narrower raises NanNarrowed for +Inf');
    end
    else
    begin
      Report(ArgI64(p) = Low(Int64), 'ArgI64 saturates low for -Inf');
      Report(ArgI32(p) = Low(Integer), 'ArgI32 saturates low for -Inf');
      Report(not NanNarrowed, 'neither narrower raises NanNarrowed for -Inf');
    end;
    SetNanNarrowed(False);

    Stage := 'the arithmetic operators, on ' + nm;
    // --- every arithmetic operator, in EVERY operand position ---------------
    e := Negate(p, r);                     Err(e, 'unary minus');
    e := ValAdd(p, two, r);                Err(e, '+ (left)');
    e := ValAdd(two, p, r);                Err(e, '+ (right)');
    e := ValSub(p, two, r);                Err(e, '- (left)');
    e := ValSub(two, p, r);                Err(e, '- (right)');
    e := ValSub(ValStr('abcd'), p, r);     Err(e, '- (string count)');
    e := ValMul(p, two, r);                Err(e, '* (left)');
    e := ValMul(two, p, r);                Err(e, '* (right)');
    e := ValDivReal(p, two, r);            Err(e, '/ (left)');
    e := ValDivReal(two, p, r);            Err(e, '/ (right)');
    e := ValDivInt(p, two, r);             Err(e, '\ (left)');
    e := ValDivInt(two, p, r);             Err(e, '\ (right)');
    e := ValMod(p, two, r);                Err(e, 'mod (left)');
    e := ValMod(two, p, r);                Err(e, 'mod (right)');
    e := ValPow(p, two, r);                Err(e, '^ (left)');
    e := ValPow(two, p, r);                Err(e, '^ (right)');

    { The COMPARISON is where this actually killed the process: `if x < 1` on a
      variable holding a NaN, not the arithmetic. All six operators, both sides. }
    Stage := 'the comparison operators, on ' + nm;
    e := ValCompare(coLT, p, ValInt(1), r);  Err(e, '< (left)');
    e := ValCompare(coLT, ValInt(1), p, r);  Err(e, '< (right)');
    e := ValCompare(coLE, p, two, r);        Err(e, '<= (left)');
    e := ValCompare(coGT, p, two, r);        Err(e, '> (left)');
    e := ValCompare(coGE, p, two, r);        Err(e, '>= (left)');
    e := ValCompare(coEQ, p, p, r);          Err(e, '= (both)');
    e := ValCompare(coNE, two, p, r);        Err(e, '<> (right)');

    { The STORE, for each target type that can hold a Double. A variable is where
      a value outlives the operation that made it, so this is the door that turns
      one bad value into a program full of them. }
    Stage := 'the store gate, on ' + nm;
    e := StoreCheck(vtNumber, p, r);       Err(e, 'a store into a number variable');
    e := StoreCheck(vtInt, p, r);          Err(e, 'a store into an int% variable');
    e := StoreCheck(vtAny, p, r);          Err(e, 'a store into a hidden temporary');

    { ...and the three that cannot hold a Double at all still say so, because a
      finiteness message would be less informative than the type error. }
    Report(StoreCheck(vtString, p, r).Code = peTypeMismatch,
           'a store of ' + nm + ' into a string$ is still a type error');
    Report(StoreCheck(vtBool, p, r).Code = peTypeMismatch,
           'a store of ' + nm + ' into a bool? is still a type error');
    Report(StoreCheck(vtHandle, p, r).Code = peTypeMismatch,
           'a store of ' + nm + ' into a handle@ is still a type error');

    { REPORTED, NOT CRASHED ON. Stringifying is the one operation deliberately
      left able to see a non-finite: naming a poisoned value is how an error
      message and a program describe it. It must never be empty and never trap. }
    Stage := 'stringifying ' + nm;
    Report(Length(ValToStr(p)) > 0, 'ValToStr names ' + nm);
    e := ValAdd(ValStr('x='), p, r);
    Report((not IsError(e)) and (r.Kind = vkString) and (Length(r.Str) > 2),
           'string + ' + nm + ' still concatenates its text');

    // A non-finite is a NUMBER as far as kind goes; only its value is refused.
    Report(IsNumeric(p), nm + ' is still numeric by kind');
  end;
end;

{ ----------------------------------------------------------------------------
  AND THE MIRROR: THE FINITE VALUES THE GUARDS MUST NOT REFUSE.

  A guard that answers "error" where a number was the right answer is as serious
  as the crash it replaced. These pin the values closest to every edge the guard
  tests -- both sides of the Int64 window, the largest and smallest magnitudes a
  Double has, negative zero -- and the answers are the ones the engine gave
  before any of this was added.
  ---------------------------------------------------------------------------- }
{ 2^E built from the BITS, exact for every E in [-1074, 1023] -- the subnormals
  included, where computing it would underflow to the wrong answer. This is the
  independent oracle the sweep below compares `^` against. }
function Pow2Bits(const E: Integer): Double;
var q: QWord;
begin
  if E >= -1022 then q := QWord(E + 1023) shl 52
  else q := QWord(1) shl (E + 1074);
  Result := PDouble(@q)^;
end;

function BitsOf(const D: Double): QWord;
begin
  Result := PQWord(@D)^;
end;

{ The inverse, and the reason the remainder sweep uses it: an untyped float
  literal in FPC source is an Extended, so `1e-300` written in this file reaches
  a Double through a second rounding on Linux and through none on Windows. An
  operand assembled from its IEEE pattern asks both platforms the same question. }
function FromBits(const Q: QWord): Double;
begin
  Result := PDouble(@Q)^;
end;

{ THE ENGINE'S TEXT FOR A DOUBLE, READ BACK THE WAY THE ENGINE READS IT. The
  property is IEEE's and not this engine's: a decimal string identifies exactly
  one Double, so the spelling of a value must produce that value again. ValToStr
  could not keep it while it formatted with FloatToStr's 15 significant digits --
  an IEEE double needs 17 -- and two different Doubles then shared one spelling.

  Read back with the DOUBLE overload of TryStrToFloat, because that is the
  converter val() and `input #` actually call (PhosphorStrLib f_val,
  PhosphorVM's field parser, both `Val(S, Double(...), E)` through
  sysstr.inc:1371-1375 and :1332). StrToFloatDef would reach the SAME converter
  -- every FPC Val on a real destination returns ValReal (compproc.inc:209-236),
  so the Extended flavour differs only in where the single narrowing happens --
  so this is the witness named for clarity, not a different arithmetic.

  WHAT THIS WITNESS CANNOT SEE, said here because a probe that cannot fail is
  measuring nothing: FPC's Val is not correctly rounded (sstrings.inc:1865-1888
  accumulates and then scales by a power of ten), so it is the engine's reader
  agreeing with the engine's writer. That is the promise the docs make, and it is
  the whole promise: 9 of the ladder's spellings, measured over 474393 Doubles
  against a correctly-rounded oracle outside this toolchain, are read as the
  neighbouring Double by such a reader -- all 9 byte-identical to what FloatToStr
  wrote before the ladder existed. }
function SpellingReadsBack(const D: Double): Boolean;
var
  fs: TFormatSettings;
  back: Double;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  fs.ThousandSeparator := #0;
  Result := TryStrToFloat(ValToStr(ValDouble(D)), back, fs) and
            (BitsOf(back) = BitsOf(D));
end;

{ ----------------------------------------------------------------------------
  `^` OVER A RANGE, NOT OVER A LIST -- and against an ORACLE, not a table.

  On 2026-09-06 ValPow was rewritten to compute a negative whole power as
  1.0/Power(base, -expo) instead of Power(base, expo), on the belief that FPC's
  intpower ends in `1.0/result`. It does not; it reciprocates the BASE
  (math.pp:1065). The two orderings agree everywhere except where the POSITIVE
  power overflows: there the reciprocal of +Inf is 0, so the whole subnormal
  result band silently became zero -- `2 ^ -1074`, `10 ^ -310`, `2 ^ -1030` and
  8961 other swept answers, with no error and nothing reported. Every pinned
  value in this probe passed, because every one of them sat outside the band.

  The fix for a list that misses a band is not a longer list. For base 2 the
  right answer is known exactly for every exponent in the Double's range, so
  this walks the WHOLE range one step at a time and compares bit for bit:

     -1100..-1075   underflows to exactly zero
     -1074..1023    exactly 2^E, subnormals included
      1024..1100    a catchable overflow, never a value

  2200 assertions collapsed into three Reports, each naming the first exponent
  that disagreed. It fails loudly against the rejected revision (checked: the
  first mismatch is -1074) and passes against the pristine engine.
  ---------------------------------------------------------------------------- }
function FirstWrong(AExp: Integer): String;
begin
  if AExp = 32767 then Result := ''
  else Result := ' (first wrong exponent: ' + IntToStr(AExp) + ')';
end;

procedure CheckPowOverTheWholeRange;
var
  r: TValue;
  e: TPhosphorError;
  ex, badZero, badExact, badOvf: Integer;
begin
  Stage := 'the ^ range sweep';
  badZero := 32767; badExact := 32767; badOvf := 32767;

  for ex := -1100 to -1075 do
  begin
    e := ValPow(ValDouble(2.0), ValDouble(ex), r);
    if IsError(e) or (r.Kind <> vkDouble) or (BitsOf(r.Num) <> 0) then
      if ex < badZero then badZero := ex;
  end;
  Report(badZero = 32767,
         'below the smallest subnormal, 2 ^ e is exactly zero' + FirstWrong(badZero));

  for ex := -1074 to 1023 do
  begin
    e := ValPow(ValDouble(2.0), ValDouble(ex), r);
    if IsError(e) or (r.Kind <> vkDouble) or
       (BitsOf(r.Num) <> BitsOf(Pow2Bits(ex))) then
      if ex < badExact then badExact := ex;
  end;
  Report(badExact = 32767,
         '2 ^ e is bit-exact for every representable e, subnormals included' +
         FirstWrong(badExact));

  for ex := 1024 to 1100 do
  begin
    e := ValPow(ValDouble(2.0), ValDouble(ex), r);
    if e.Code <> peIntOverflow then
      if ex < badOvf then badOvf := ex;
  end;
  Report(badOvf = 32767,
         'past MaxDouble, 2 ^ e is a catchable overflow' + FirstWrong(badOvf));

  { Three decimal bases from inside the band, spelled the way a program sees
    them. Base 2 is the one with an exact oracle; these prove the band is right
    for bases whose powers are not powers of two. The rejected revision answered
    0 for all three, and that is what these must keep catching.

    THEY ARE NOT PINNED TO AN EXACT DECIMAL STRING, and the first version of them
    was. `10 ^ -310` answers 1.00000000000005E-310 on Win64 and
    9.9999999999999694E-311 on Linux x86-64 -- both correct to the precision a
    subnormal has, and they differ because SizeOf(Extended) is 8 on Win64 and 10
    on Linux, so FPC's Power carries its intermediate in 80 bits there and in 64
    here. The exact-string form was green on Windows, red on Linux, and pinned a
    property of the FLOATING-POINT UNIT rather than of this engine. What the
    check is named for -- a subnormal, not zero -- is what it now asserts:
    non-zero, below the smallest NORMAL double, and within 1e-12 relative of the
    true value. Answering 0 is a relative error of 1, so the regression these
    exist for is still caught with room to spare. }
  Report(SubnormalNear(ValPow(ValDouble(10.0), ValDouble(-310.0), r), r, Ref10m310),
         '10 ^ -310 is a subnormal, not zero');
  Report(SubnormalNear(ValPow(ValDouble(10.0), ValDouble(-320.0), r), r, Ref10m320),
         '10 ^ -320 is a subnormal, not zero');
  Report(SubnormalNear(ValPow(ValDouble(1.5), ValDouble(-1800.0), r), r, Ref15m1800),
         '1.5 ^ -1800 is a subnormal, not zero');
end;

{ ----------------------------------------------------------------------------
  THE OPERATORS UNDER A HOSTILE FPU MASK.

  Everything else in this probe runs under the mask TPhosphorVM.Run installs,
  which is the only configuration the unit's answers were ever defined in. That
  is a promise made on somebody else's behalf: Run and RunFrom install the mask,
  and TPhosphorVM.CallUserFunc -- the documented embedding path, Prepare then
  CallFunction -- does not. Measured on 2026-09-07, before the operators carried
  a net: `x * 10`, `x ^ 400`, `x + x` and `x / 1e-10` with x = 1e308 each exited
  217 with an unhandled EOverflow through that door, with every operand finite.

  This runs the same operators with exOverflow REMOVED from the mask -- the FPC
  default, and what a host that never called Run has -- and requires the same
  catchable answers. Without TrappedInOperator it does not fail: it kills the
  probe, which is why the caller wraps it.
  ---------------------------------------------------------------------------- }
procedure CheckOperatorsWithOverflowUnmasked;
var
  r: TValue;
  e: TPhosphorError;
  saved: TFPUExceptionMask;
begin
  Stage := 'the operators with overflow UNMASKED';
  saved := GetExceptionMask();
  SetExceptionMask(saved - [exOverflow]);
  try
    e := ValMul(ValDouble(1e308), ValDouble(10.0), r);
    CheckErr(e, peIntOverflow, 'unmasked: 1e308 * 10 is reported, not raised');
    e := ValAdd(ValDouble(1.7976931348623157e308),
                ValDouble(1.7976931348623157e308), r);
    CheckErr(e, peIntOverflow, 'unmasked: max + max is reported, not raised');
    e := ValSub(ValDouble(-1.7976931348623157e308),
                ValDouble(1.7976931348623157e308), r);
    CheckErr(e, peIntOverflow, 'unmasked: -max - max is reported, not raised');
    e := ValDivReal(ValDouble(1e308), ValDouble(1e-10), r);
    CheckErr(e, peIntOverflow, 'unmasked: 1e308 / 1e-10 is reported, not raised');
    e := ValPow(ValDouble(1e308), ValDouble(400.0), r);
    CheckErr(e, peIntOverflow, 'unmasked: 1e308 ^ 400 is reported, not raised');
    { WAS `CheckErr(e, peIntOverflow, ...)` AND THAT PINNED A WRONG ANSWER.
      1e308 mod 1e-308 is an ordinary subnormal, 3.498445546245627e-309; only the
      QUOTIENT, 1e616, overflows, and `mod` no longer forms one. What this case
      is really here for -- that the operator REPORTS rather than raising with the
      overflow trap unmasked -- is now checked by the two above it, whose results
      really do overflow; this one checks that the same unmasked trap does not
      fire on the intermediate arithmetic of a remainder that is perfectly
      representable. }
    e := ValMod(ValDouble(1e308), ValDouble(1e-308), r);
    Report((not IsError(e)) and (r.Kind = vkDouble) and (r.Num > 0) and
           (r.Num < Ref1em308),
           'unmasked: 1e308 mod 1e-308 answers a subnormal without raising');
    // ...and an ordinary computation is untouched by the net.
    e := ValMul(ValDouble(3.0), ValDouble(4.0), r);
    CheckDouble(r, 12, 'unmasked: 3 * 4 is still 12');
    e := ValAdd(ValInt(2), ValInt(3), r);
    CheckInt(r, 5, 'unmasked: 2 + 3 is still 5');
  finally
    SetExceptionMask(saved);
  end;
end;

{ ----------------------------------------------------------------------------
  THE ARGUMENT GATE, THROUGH THE DOCUMENTED HOST DOOR.

  Everything above this point tests PhosphorValue in isolation, and that is
  exactly how the defect this section pins got shipped. The unit's header used to
  say a non-finite Double that gets into the value space "is REPORTED by the next
  operator that meets it" -- and every operator was measured, and the claim was
  still false, because THE NEXT THING A NaN MEETS IS USUALLY NOT AN OPERATOR. It
  is ArgI32/ArgI64, which saturate to 0 and report nothing, and 0 is a count that
  passes every bounds check. Measured 2026-09-07, one process per case, through
  Prepare + CallFunction: fifty (library function, numeric argument position)
  doors answered a WRONG VALUE with no error at all -- chr$ a NUL byte, hex$ the
  string "0", colortostr$ "Black", pointer@ a live handle, space$/left$/mid$ an
  empty or wrongly-cut string.

  So this section runs the same door. It is the only part of this probe that
  links the engine, and it is here rather than in a probe of its own because the
  contract it checks is this unit's: Arg* raises NanNarrowed, and the registry's
  dispatch is what turns that into a catchable error.

  IT PINS BOTH DIRECTIONS. A refusal that also refused the legitimate cases would
  be the same mistake in the other direction, so isnan/isinfinite/str$ -- the
  functions whose whole job is to look at a non-finite number -- are pinned to
  still see one, +/-Inf is pinned to still saturate, and ordinary arguments are
  pinned to still work.
  ---------------------------------------------------------------------------- }
const
  DoorSrc =
    // chr$ answers a RAW BYTE, so the probe reports it as ASCII text rather than
    // comparing the byte itself: this unit is {$codepage UTF8}, where a Char >= 128
    // in a literal is not one byte (check-codepage.py exists for that mistake).
    'function d_chr$(x)'          + LineEnding + '  s$ = chr$(x)'                 + LineEnding +
                                    '  return "len=" + str$(len(s$)) + " b1=" + str$(byteat(s$, 1))' + LineEnding + 'end function' + LineEnding +
    'function d_hex$(x)'          + LineEnding + '  return hex$(x)'               + LineEnding + 'end function' + LineEnding +
    'function d_space$(x)'        + LineEnding + '  return space$(x)'             + LineEnding + 'end function' + LineEnding +
    'function d_colour$(x)'       + LineEnding + '  return colortostr$(x)'        + LineEnding + 'end function' + LineEnding +
    'function d_ptr$(x)'          + LineEnding + '  h@ = pointer@(x)'             + LineEnding + '  return "handle"' + LineEnding + 'end function' + LineEnding +
    'function d_mid$(x)'          + LineEnding + '  return mid$("abcdef", x, 2)'  + LineEnding + 'end function' + LineEnding +
    'function d_instr$(x)'        + LineEnding + '  return str$(instr("abcdef", "c", x))' + LineEnding + 'end function' + LineEnding +
    'function d_left$(x)'         + LineEnding + '  return left$("abcdef", x)'    + LineEnding + 'end function' + LineEnding +
    'function d_isnan$(x)'        + LineEnding + '  return str$(isnan(x))'        + LineEnding + 'end function' + LineEnding +
    'function d_isinf$(x)'        + LineEnding + '  return str$(isinfinite(x))'   + LineEnding + 'end function' + LineEnding +
    'function d_str$(x)'          + LineEnding + '  return str$(x)'               + LineEnding + 'end function' + LineEnding +
    'function d_inner$(x)'        + LineEnding + '  return chr$(x)'               + LineEnding + 'end function' + LineEnding +
    'function d_clean$(x)'        + LineEnding + '  s$ = chr$(65)'                + LineEnding +
                                    '  return "len=" + str$(len(s$)) + " b1=" + str$(byteat(s$, 1))' + LineEnding + 'end function' + LineEnding +
    'function d_after$(x)'        + LineEnding + '  s$ = left$("abcdef", 3)'      + LineEnding + '  return s$ + left$("abcdef", 2)' + LineEnding + 'end function' + LineEnding +
    'function d_wrap$(x)'         + LineEnding + '  return callfunc$("d_clean$", x)' + LineEnding + 'end function' + LineEnding +
    'function d_wrapbad$(x)'      + LineEnding + '  return callfunc$("d_inner$", x)' + LineEnding + 'end function' + LineEnding;

procedure CheckLibraryDoorOnNonFinite;
var
  eng: TPhosphorEngine;
  v: TValue;

  { One call through the documented door. AWantErr says whether the engine must
    report; AWantText is the answer it must give when it must not. }
  procedure Door(const AFn: String; const X: Double; AWantErr: Boolean;
                 const AWantText, AName: String);
  begin
    v := eng.CallFunction(AFn, [ValDouble(X)]);
    if AWantErr then
      Report(IsError(eng.LastError) and (eng.LastError.Code = peRuntime),
             AName + ' reports catchably')
    else
      Report((not IsError(eng.LastError)) and (ValToStr(v) = AWantText),
             AName + ' still answers ' + AWantText);
  end;

var
  nan_, pinf, ninf: Double;
begin
  Stage := 'the library argument door';
  nan_ := PoisonD(0);
  pinf := PoisonD(1);
  ninf := PoisonD(2);

  eng := TPhosphorEngine.Create;
  try
    if eng.Prepare(DoorSrc) <> 0 then
    begin
      Report(False, 'the door probe compiles [' + eng.ErrorMessage + ']');
      Exit;
    end;
    Report(True, 'the door probe compiles');

    // The eight that answered a wrong value silently, plus the four found by
    // widening the sweep to every numeric argument POSITION rather than only
    // arity-1 functions. Every one of these was "OK" with no error before.
    Door('d_chr$',    nan_, True, '', 'chr$(NaN)');
    Door('d_hex$',    nan_, True, '', 'hex$(NaN)');
    Door('d_space$',  nan_, True, '', 'space$(NaN)');
    Door('d_colour$', nan_, True, '', 'colortostr$(NaN)');
    Door('d_ptr$',    nan_, True, '', 'pointer@(NaN)');
    Door('d_mid$',    nan_, True, '', 'mid$("abcdef",NaN,2)');
    Door('d_instr$',  nan_, True, '', 'instr("abcdef","c",NaN)');
    Door('d_left$',   nan_, True, '', 'left$("abcdef",NaN)');

    // THE OTHER DIRECTION. +/-Inf saturates to High/Low exactly as it always
    // did -- that band is documented and is NOT the defect -- and the functions
    // that exist to look at a non-finite number still see one.
    { b1 WAS 255, AND 255 IS WHY IT CHANGED. What this line pins is the
      SATURATION -- +Inf clamps to High(Integer) and chr$ answers one codepoint
      with no error -- and all three of those still hold. What moved is the byte
      the ENCODER made of 2147483647: it used to overflow `Chr($F0 or (c shr
      18))` and emit FF BF BF BF, and 0xFF cannot occur in a UTF-8 stream at any
      position, so chr$ was handing back a string nothing could decode (asc()
      answered 2097151 for the 2147483647 that went in). The encoder now clamps
      at U+10FFFF, the last encodable codepoint, mirroring the clamp it already
      had at 0 -- hence 244 ($F4), the lead byte of F4 8F BF BF.

      The -Inf line below is untouched and still answers b1=0: that clamp was
      always there, and this change did not widen it. }
    Door('d_chr$',   pinf, False, 'len=1 b1=244', 'chr$(+Inf)');
    // chr$(-Inf) splices a NUL byte, exactly as chr$(NaN) used to. It is the
    // SAME shape of defect one band over, it is in engine/libs (not this
    // lane's file), and it is pinned here as the behaviour of record so that
    // whoever fixes it has to come past this line.
    Door('d_chr$',   ninf, False, 'len=1 b1=0',   'chr$(-Inf)');
    Door('d_hex$',   pinf, False, '7FFFFFFFFFFFFFFF', 'hex$(+Inf)');
    Door('d_isnan$', nan_, False, '1', 'isnan(NaN)');
    Door('d_isnan$', pinf, False, '0', 'isnan(+Inf)');
    Door('d_isinf$', pinf, False, '1', 'isinfinite(+Inf)');
    Door('d_isinf$', nan_, False, '0', 'isinfinite(NaN)');
    Door('d_str$',   nan_, False, 'Nan', 'str$(NaN)');

    // An ordinary argument is untouched, and -- the pin the flag needs -- a call
    // that follows a reported one is clean. A flag left raised would report the
    // NEXT library call instead, which is worse than the defect it replaced.
    Door('d_chr$',   65.0, False, 'len=1 b1=65', 'chr$(65)');
    Door('d_left$',  3.0,  False, 'abc',    'left$("abcdef",3)');
    Door('d_chr$',   nan_, True,  '',       'chr$(NaN) again');
    Door('d_after$', 0.0,  False, 'abcab',  'the call after a reported one');

    // RE-ENTRANCY. callfunc is host-aware: it dispatches through the registry
    // from INSIDE a registry dispatch. The inner call must not consume or hide
    // the outer one's state, in either direction.
    Door('d_wrap$',    nan_, False, 'len=1 b1=65', 'callfunc to a clean function, NaN outside');
    Door('d_wrapbad$', nan_, True,  '',  'callfunc to a narrowing function');
    Door('d_after$',   0.0,  False, 'abcab', 'the call after a re-entrant report');
  finally
    eng.Free;
  end;
end;

procedure CheckFiniteStillWorks;
var
  r: TValue;
  e: TPhosphorError;
  i: Int64;

  procedure Rng(const AName: String; const X: Double; AWant: Boolean; AWantI: Int64);
  var got: Int64;
  begin
    got := 0;
    Report((InI64Range(X) = AWant) and (TryD2I(X, got) = AWant) and
           ((not AWant) or (got = AWantI)),
           'InI64Range/TryD2I ' + AName);
  end;

begin
  // The window is [-2^63, 2^63). Both ends, and the representable value nearest
  // each of them -- 2^63 itself is out, -2^63 exactly is in.
  Stage := 'the Int64 window, on finite values';
  Rng('0', 0.0, True, 0);
  Rng('-0.0', -0.0, True, 0);
  Rng('2^52', 4503599627370496.0, True, 4503599627370496);
  Rng('2^53', 9007199254740992.0, True, 9007199254740992);
  Rng('the largest Double below 2^63', 9223372036854774784.0, True, 9223372036854774784);
  Rng('2^63 exactly is outside', 9223372036854775808.0, False, 0);
  Rng('-2^63 exactly is inside', -9223372036854775808.0, True, Low(Int64));
  Rng('one Double below -2^63', -9223372036854777856.0, False, 0);
  Rng('MaxDouble', 1.7976931348623157e308, False, 0);
  Rng('the smallest denormal', 4.9406564584124654e-324, True, 0);
  Rng('0.5', 0.5, True, 0);
  Rng('3.7', 3.7, True, 4);
  Rng('-3.7', -3.7, True, -4);

  Report(IsFiniteD(1.7976931348623157e308), 'IsFiniteD accepts MaxDouble');
  Report(IsFiniteD(4.9406564584124654e-324), 'IsFiniteD accepts the smallest denormal');
  Report(IsFiniteD(-0.0), 'IsFiniteD accepts negative zero');
  Report(not IsNanD(1.7976931348623157e308), 'IsNanD does not cry wolf on MaxDouble');
  Report(IsFiniteVal(ValInt(High(Int64))) and IsFiniteVal(ValStr('s')) and
         IsFiniteVal(ValBool(True)) and IsFiniteVal(ValHandle(1)),
         'IsFiniteVal accepts every non-double kind');

  Stage := 'the narrowers, on finite values';
  SetNanNarrowed(False);
  Report(ArgI64(ValDouble(1e300)) = High(Int64), 'ArgI64 still saturates 1e300 high');
  Report(ArgI64(ValDouble(-1e300)) = Low(Int64), 'ArgI64 still saturates -1e300 low');
  Report(ArgI64(ValDouble(3.7)) = 4, 'ArgI64 still rounds 3.7 to 4');
  Report(ArgI32(ValDouble(7.2)) = 7, 'ArgI32 still rounds 7.2 to 7');
  Report(ArgI64(ValInt(High(Int64))) = High(Int64), 'ArgI64 still passes an int% through exactly');
  // The flag is what turns a narrowed NaN into a catchable error at the registry.
  // A narrowing that met no NaN must leave it down, or every library call after
  // the first big or fractional argument reports a fault that did not happen.
  Report(not NanNarrowed, 'no finite narrowing raises NanNarrowed');

  // MaxDouble is the finite value nearest the guard: it must still add (to an
  // overflow ERROR, not a refusal at the operand), compare, and store.
  Stage := 'the operators, on the finite values nearest the guard';
  e := ValAdd(ValDouble(1.7976931348623157e308), ValDouble(1.7976931348623157e308), r);
  CheckErr(e, peIntOverflow, 'max + max overflows at the RESULT');
  e := ValCompare(coLT, ValDouble(1e308), ValDouble(1.7976931348623157e308), r);
  Report((not IsError(e)) and (r.Kind = vkBool) and r.Bl, 'max still compares (bool)');
  e := ValCompare(coEQ, ValDouble(-0.0), ValDouble(0.0), r);
  Report((not IsError(e)) and r.Bl, 'negative zero still equals zero (bool)');
  { AGAINST A TYPED Double CONSTANT, NEVER AN INLINE LITERAL. An untyped float
    literal in FPC source is an Extended, which is 80 bits on Linux x86-64 and 64
    on Win64; comparing a Double against one promotes BOTH to Extended, and
    1.7976931348623157e308 in 80 bits is not the Double nearest it. The inline
    form was green on Windows and red on Linux for exactly that reason, and it
    was testing the compiler's literal parser, not this store. }
  e := StoreCheck(vtNumber, ValDouble(MaxD), r);
  Report((not IsError(e)) and (r.Kind = vkDouble) and
         (r.Num = MaxD), 'MaxDouble still stores unchanged');
  e := StoreCheck(vtNumber, ValDouble(SmallestDenormD), r);
  Report((not IsError(e)) and (r.Num = SmallestDenormD),
         'the smallest denormal still stores unchanged');
  e := StoreCheck(vtInt, ValDouble(3.7), r);
  Report((not IsError(e)) and (r.Kind = vkInt) and (r.Int = 4),
         'a Double still rounds into an int% slot');
  e := StoreCheck(vtInt, ValDouble(1e300), r);
  CheckErr(e, peIntOverflow, 'a Double too large for an int% still overflows');

  // The operations whose own overflow must still be REPORTED at the result.
  e := ValMul(ValDouble(1e308), ValDouble(10), r);
  CheckErr(e, peIntOverflow, '1e308 * 10 overflows');
  e := ValDivReal(ValDouble(1e308), ValDouble(1e-308), r);
  CheckErr(e, peIntOverflow, '1e308 / 1e-308 overflows');
  { THE MOD LINE HERE USED TO READ `CheckErr(e, peIntOverflow, ...)` TOO, and it
    was wrong for a reason the division above it makes plain: 1e308 / 1e-308 has
    no representable answer, and 1e308 mod 1e-308 has one -- the subnormal
    3.498445546245627e-309. The old `mod` computed the quotient anyway, met the
    same +Inf the division does, and reported the division's error for a question
    that was never asked. It sat one line under the division that justifies it,
    which is exactly how it read as right. }
  e := ValMod(ValDouble(1e308), ValDouble(1e-308), r);
  Report((not IsError(e)) and (r.Kind = vkDouble) and (r.Num > 0) and
         (r.Num < Ref1em308),
         '1e308 mod 1e-308 answers a subnormal, it does not overflow');
  e := ValPow(ValInt(10), ValInt(400), r);
  CheckErr(e, peIntOverflow, '10 ^ 400 overflows');
  e := ValPow(ValInt(0), ValInt(-1), r);
  CheckErr(e, peDivByZero, '0 ^ -1 is still division by zero');
  e := ValPow(ValInt(-8), ValDouble(0.5), r);
  CheckErr(e, peRuntime, '(-8) ^ 0.5 still has no numeric result');

  // ...and the ordinary answers around them, unchanged.
  e := ValMod(ValDouble(1e30), ValDouble(2.5), r);
  Report((not IsError(e)) and (r.Kind = vkDouble), '1e30 mod 2.5 still answers');
  e := ValMod(ValInt(Low(Int64)), ValInt(-1), r);
  CheckInt(r, 0, 'minint mod -1 is still 0');
  e := ValPow(ValInt(-2), ValInt(3), r);
  CheckDouble(r, -8, 'a negative base with a whole exponent still works');
  e := ValPow(ValInt(0), ValDouble(0.5), r);
  CheckDouble(r, 0, '0 ^ 0.5 is still zero');

  { NEGATIVE EXPONENTS. These pins are a LIST, and a list is what let a wrong
    `^` through once already: a revision that computed `1.0/Power(base,-expo)`
    instead of `Power(base,expo)` passed every one of them and still answered 0
    for the whole subnormal band, because none of these values lands in it. The
    range sweep in CheckPowOverTheWholeRange is the check that covers the band;
    these stay because they pin the OTHER shapes -- a negative base, a
    fractional exponent, the overflow edge -- with named answers. }
  e := ValPow(ValInt(2), ValInt(-3), r);
  CheckDouble(r, 0.125, '2 ^ -3 is still 0.125');
  e := ValPow(ValInt(-2), ValInt(-3), r);
  CheckDouble(r, -0.125, '(-2) ^ -3 is still -0.125');
  e := ValPow(ValDouble(0.5), ValInt(-2), r);
  CheckDouble(r, 4, '0.5 ^ -2 is still 4');
  e := ValPow(ValDouble(1e300), ValInt(-2), r);
  Report((not IsError(e)) and (r.Kind = vkDouble) and (r.Num = 0),
         'a reciprocal of an overflowed power is still zero');
  { 1e-300 is not exactly representable, so its reciprocal is NOT the Double the
    literal 1e300 parses to -- it is one ulp below it, $7E37E43C8800759B.

    TWO ASSERTIONS, BECAUSE THE LINE THEY REPLACE WAS DOING TWO JOBS AND ONE OF
    THEM BADLY. It read `ValToStr(r) = '1E300'`, and as a statement about the
    TEXT it was the fifth expectation in this tree to record a defect as
    correct: it was written by reading a run of a build whose ValToStr formatted
    with 15 significant digits, and at 15 digits those two Doubles share one
    spelling, so the engine printed the text of a value it does not hold and
    that text read back as the other one. But it was also the only thing here
    saying anything about the VALUE, and a round-trip property alone does not:
    every finite Double's spelling reads back, so ValPow could answer 42 and
    SpellingReadsBack would still be true. So the value is pinned as BITS, where
    it is unambiguous, and the spelling as the property -- which is strictly
    more than the old line covered, and measurably so: 36 distinct Doubles are
    spelled '1E300' by a 15-significant-digit formatter -- walked outwards from
    the literal until the text changed -- so that comparison would have accepted
    an answer up to 33 steps above the right one. Watched failing: perturbing
    ValPow's negative-exponent result by a single ulp fails this line and one
    other assertion, and nothing else in the probe.

    THE BITS ARE DERIVED, AND NOT FROM THIS TOOLCHAIN. The Double nearest 1e-300
    is $01A56E1FC2F8F359; one divided by it, rounded to nearest by exact
    rational arithmetic, is $7E37E43C8800759B. ValPow reaches it through
    Math.Power, whose intpower reciprocates the BASE (see ValPow's header) in
    `float` -- Extended on Linux, Double on Win64 -- so the same quotient is
    also formed at a 64-bit mantissa and narrowed afterwards. Rounding the exact
    quotient that way lands on the same Double, which is why this is safe to
    pin as bits on both systems. The BASE is assembled from its pattern for the
    reason FromBits exists above: an untyped literal in FPC source reaches a
    Double through one rounding here and two on Linux.

    Nothing about the reciprocal's TEXT is pinned here on purpose. That it reads
    back is the property below; WHICH rung spelled it is pinned for two other
    values in CheckNumberText, and a third witness would only repeat them. }
  e := ValPow(ValDouble(FromBits(QWord($01A56E1FC2F8F359))), ValInt(-1), r);
  Report((not IsError(e)) and (r.Kind = vkDouble) and
         (BitsOf(r.Num) = QWord($7E37E43C8800759B)),
         '1e-300 ^ -1 is the Double one ulp below the literal 1e300');
  Report((not IsError(e)) and (r.Kind = vkDouble) and SpellingReadsBack(r.Num),
         '1e-300 ^ -1 is spelled as the Double it actually is');
  e := ValPow(ValDouble(1e-300), ValInt(-2), r);
  CheckErr(e, peIntOverflow, '1e-300 ^ -2 has no finite magnitude');
  e := ValPow(ValDouble(2.0), ValDouble(-2147483647.0), r);
  Report((not IsError(e)) and (r.Num = 0), '2 ^ -maxint still underflows to zero');
  e := ValPow(ValDouble(2.0), ValDouble(-0.5), r);
  CheckDouble(r, 0.707106781186547, 'a fractional negative exponent still works');
  e := ValSub(ValStr('abcd'), ValDouble(1e30), r);
  CheckStr(r, '', 'a huge string-truncation count still clamps to empty');
  e := ValSub(ValStr('abcd'), ValDouble(-1e30), r);
  CheckStr(r, 'abcd', 'a hugely negative one still keeps the whole string');
  e := ValDivInt(ValDouble(1e300), ValInt(2), r);
  CheckErr(e, peIntOverflow, '1e300 \ 2 is still out of integer range');
  i := 0;
  if i <> 0 then ;
end;

{ A DOUBLE'S TEXT IS SWEPT, NOT LISTED. Every path that turns a number into text
  -- str$/stri$, print, println, print #, concatenation, an error message -- ends
  at ValToStr, and a list of hand-picked literals is not an assertion about it:
  the finiteness patch that turned a whole band of correct subnormal answers into
  0 passed a byte-identical diff of chosen values. So the range is swept, and the
  expectation is a property with an external definition -- IEEE-754: 17
  significant decimal digits distinguish every pair of Doubles, so a spelling
  that reads back as the value always exists.

  It used not to hold. ValToStr formatted with FloatToStr's 15 significant
  digits, and the work order's own recurrence, x = x * 1.0000001 + 0.000000123,
  came back changed for 196 of its first 200 values -- while the two numbers
  printed identically, so no golden and no amount of reading output could show
  it. The recurrence is reproduced below verbatim for that reason: it is the
  measurement, not an illustration.

  THE SHAPES THAT ALREADY ROUND-TRIPPED ARE PINNED TOO, and they are the other
  half of the change: a fix that simply emitted 17 digits always would pass every
  round-trip assertion here and turn `println 1.5` into 1.5000000000000000E+000.
  Those spellings come from the PRISTINE engine, not from a run of the new one --
  06_strings.bas:45 and 61_utf8_character_ops.bas:181-183 have pinned several of
  them in .bas since long before this. }
procedure CheckNumberText;
var
  seed: QWord;
  k, changed, bad: Integer;
  x: Double;

  function NextRaw: QWord;
  begin
    // xorshift64*, so the sweep is the same numbers on both platforms
    seed := seed xor (seed shr 12);
    seed := seed xor (seed shl 25);
    seed := seed xor (seed shr 27);
    Result := seed * QWord(2685821657736338717);
  end;

  procedure Spells(const AV: Double; const AWant: String);
  begin
    Report(ValToStr(ValDouble(AV)) = AWant,
           'still spelled ' + AWant + ' (got ' + ValToStr(ValDouble(AV)) + ')');
  end;

begin
  Stage := 'a number as text';

  { (1) THE SWEEP. Random IEEE patterns, so the exponent range and the subnormal
    band are covered rather than the decimal neighbourhood of 1. }
  seed := QWord(88172645463325252);
  bad := 0;
  k := 0;
  while k < 20000 do
  begin
    x := FromBits(NextRaw);
    if not IsFiniteD(x) then Continue;   // 'Nan'/'+Inf' are text, not a number
    Inc(k);
    if not SpellingReadsBack(x) then Inc(bad);
  end;
  Report(bad = 0, '20000 swept Doubles each read back from their own text (' +
                  IntToStr(bad) + ' did not)');

  { (2) THE RECURRENCE FROM THE WORK ORDER, which is where the defect was found. }
  changed := 0;
  x := 1.0;
  for k := 1 to 200 do
  begin
    x := x * 1.0000001 + 0.000000123;
    if not SpellingReadsBack(x) then Inc(changed);
  end;
  Report(changed = 0, 'the 200-step recurrence loses no value through its text (' +
                      IntToStr(changed) + ' changed)');

  { (3) The edges of the format, each one a value a sweep is unlikely to draw. }
  Report(SpellingReadsBack(FromBits(QWord($7FEFFFFFFFFFFFFF))),
         'MaxDouble reads back from its own text');
  Report(SpellingReadsBack(FromBits(QWord($0010000000000000))),
         'the smallest normal reads back from its own text');
  Report(SpellingReadsBack(FromBits(QWord($0000000000000001))),
         'the smallest subnormal reads back from its own text');
  Report(SpellingReadsBack(FromBits(QWord($8000000000000000))),
         'a negative zero reads back from its own text, sign and all');
  Spells(FromBits(QWord($8000000000000000)), '-0');
  Spells(FromBits(QWord($0000000000000000)), '0');

  { (4) THE OTHER HALF: what already round-tripped must not move. Every spelling
    here is the PRISTINE engine's, and five of them are pinned in .bas as well
    (06_strings.bas:45, 61_utf8_character_ops.bas:181-183). }
  Spells(1.5, '1.5');
  Spells(0.1, '0.1');
  Spells(3.5, '3.5');
  Spells(-7.0, '-7');
  Spells(1e15, '1E15');
  Spells(1e200, '1E200');
  Spells(1e-6, '1E-6');
  Spells(1e-5, '0.00001');

  { (5) WHICH RUNG WAS TAKEN, PINNED AS TEXT, because nothing else can see it.
    A round-trip assertion is satisfied by every ladder that works, so it cannot
    tell a two-rung ladder from a three-rung one -- nor tell Windows from Linux,
    where Val narrows an 80-bit ValReal (systemh.inc:183-194) and may therefore
    accept a rung Win64 rejects. These two pin the exact bytes of a value that
    FloatToStr cannot spell, so any of that says so out loud.

    The expectations are derived, not read off a run: each value's exact binary
    expansion rounded to 17 significant decimals, which is what the fallback rung
    emits by definition. pi is 3.141592653589793115997963468544185161590576171875
    exactly, so 17 digits is 3.1415926535897931; one third is
    0.333333333333333314829616256247390992939472198486328125, so 17 digits is
    0.33333333333333331. Both are ONE digit longer than the shortest text that
    would read back (3.141592653589793 and 0.3333333333333333) -- that is the
    measured price of not offering a 16-digit rung whose own checker cannot see
    when it is wrong. See PhosphorValue.NumToInv.

    FROM BITS, NOT FROM AN EXPRESSION: `4 * ArcTan(1.0)` is ValReal arithmetic,
    which is Extended on Linux and Double on Win64, so the two platforms would be
    handed different Doubles and this pin would fail for a reason that has
    nothing to do with text. }
  Spells(FromBits(QWord($400921FB54442D18)), '3.1415926535897931');
  Spells(FromBits(QWord($3FD5555555555555)), '0.33333333333333331');
end;

{ ----------------------------------------------------------------------------
  THE FLOAT REMAINDER, AGAINST AN ORACLE THAT IS NOT ITSELF.

  `mod` on a Double operand computed `a - b*Int(a/b)` and answered wrongly in
  three separate ways: 0 for almost any pair above 2^53 (1e16 mod 3), a NEGATIVE
  result vastly larger than the divisor on a wide exponent spread (1.5 mod
  1e-300), and a spurious catchable overflow when only the QUOTIENT overflows
  (1e200 mod 1e-200). Two of those wrong answers were PINNED -- one here, one in
  tests/suite/51_arith_faults.bas -- because a list of values chosen while
  looking at the code will agree with the code.

  So this section does not test against a list. It tests three ways:

    (1) NAMED CASES, BIT-EXACT, WITH THE OPERANDS BUILT FROM BITS. Every
        expected value below was produced by C/Python fmod, not by this engine.
        The operands are assembled from their IEEE patterns rather than written
        as decimal literals, because an untyped float literal in FPC source is an
        Extended -- 80 bits on Linux x86-64, 64 on Win64 -- and `1e-300` reaching
        a Double through an Extended is a double rounding this probe is not
        about. From bits, the two platforms are asked the same question.

    (2) AN INDEPENDENT ORACLE INSIDE THE ENGINE. For two integral Doubles inside
        Int64 range the answer must equal the int% path's answer -- `A.Int mod
        B.Int`, a different branch, a machine instruction, no floating point
        anywhere. The magnitudes are drawn up to 2^62, so most of the sweep sits
        above 2^53 where the old formula cancelled to 0. This is the check that
        cannot be satisfied by agreeing with the implementation.

    (3) THE DEFINITION, SWEPT OVER THE WHOLE EXPONENT RANGE. Random finite
        non-zero pairs, subnormals included: the result must exist, be finite,
        satisfy 0 <= |r| < |b|, and carry the sign of the dividend. A range, not
        a list -- the rule this project wrote after a finiteness patch passed its
        own chosen values while destroying a whole band of correct ones.
  ---------------------------------------------------------------------------- }
procedure CheckFloatRemainder;
var
  ra, rb: TValue;
  e: TPhosphorError;
  seed: QWord;
  k, bad, above53: Integer;
  a, b, oracle: Double;
  ia, ib: Int64;

  function NextRaw: QWord;
  begin
    // xorshift64*, so the sweep is the same numbers on both platforms
    seed := seed xor (seed shr 12);
    seed := seed xor (seed shl 25);
    seed := seed xor (seed shr 27);
    Result := seed * QWord(2685821657736338717);
  end;

  { One named case: both operands and the expected answer as IEEE patterns. }
  procedure ModBits(AA, AB, AWant: QWord; const AName: String);
  var v: TValue; er: TPhosphorError; got: String;
  begin
    er := ValMod(ValDouble(FromBits(AA)), ValDouble(FromBits(AB)), v);
    if IsError(er) then got := 'error ' + er.Message
    else if v.Kind <> vkDouble then got := 'not a double'
    else got := IntToHex(BitsOf(v.Num), 16) + ' = ' + ValToStr(v);
    Report((not IsError(er)) and (v.Kind = vkDouble) and (BitsOf(v.Num) = AWant),
           AName + ' (wanted ' + IntToHex(AWant, 16) + ', got ' + got + ')');
  end;

begin
  Stage := 'the float remainder';

  { (1) The four cases from the report, plus the boundaries of the format.
    Every expected pattern here is C/Python fmod's answer for the same two
    IEEE patterns; none of them was read off this engine. }
  ModBits(QWord($4341C37937E08000), QWord($4008000000000000),
          QWord($3FF0000000000000), '1e16 mod 3 = 1, not 0');
  ModBits(QWord($3FF8000000000000), QWord($01A56E1FC2F8F359),
          QWord($018D87654EA9F100), '1.5 mod 1e-300 = 3.4447797920595673e-301');
  ModBits(QWord($6974E718D7D7625A), QWord($16687E92154EF7AC),
          QWord($16547CB1E27E03C0), '1e200 mod 1e-200 = 4.18199169208316e-201');
  ModBits(QWord($4008000000000000), QWord($3FB999999999999A),
          QWord($3FB999999999998E), '3 mod 0.1 = 0.09999999999999984, not 0');
  ModBits(QWord($7FE1CCF385EBC8A0), QWord($000730D67819E8D2),
          QWord($00028401CF53D610), '1e308 mod 1e-308 = 3.498445546245627e-309');
  ModBits(QWord($4630000000000000), QWord($4008000000000000),
          QWord($3FF0000000000000), '2^100 mod 3 = 1');
  ModBits(QWord($401E000000000000), QWord($4000000000000000),
          QWord($3FF8000000000000), '7.5 mod 2 = 1.5 (the ordinary case)');
  { The sign of a zero remainder follows the dividend, as fmod's does. Pinned as
    BITS, which is where it is unambiguous. It was also the ONLY place it was
    visible while ValToStr spelled -0.0 as "0"; it now spells it "-0", because
    the byte comparison in NumToInv refuses to call a lost sign a round trip. }
  ModBits(QWord($C01E000000000000), QWord($4004000000000000),
          QWord($8000000000000000), '-7.5 mod 2.5 is a negative zero');
  { The widest and narrowest the format goes: MaxDouble against the smallest
    denormal is ~2098 halvings, the longest this can ever run. }
  ModBits(QWord($7FEFFFFFFFFFFFFF), QWord($0000000000000001),
          QWord($0000000000000000), 'MaxDouble mod the smallest denormal = 0');
  ModBits(QWord($7FEFFFFFFFFFFFFF), QWord($4008000000000000),
          QWord($4000000000000000), 'MaxDouble mod 3 = 2');
  ModBits(QWord($0000000000000001), QWord($7FEFFFFFFFFFFFFF),
          QWord($0000000000000001), 'the smallest denormal mod MaxDouble is itself');

  { (2) THE INT ORACLE. Two integral Doubles, answered by the Double branch, must
    agree with the same two numbers answered by the int% branch -- which is
    `A.Int mod B.Int`, a machine instruction with no rounding in it. }
  seed := QWord(88172645463325252);
  bad := 0;
  above53 := 0;
  for k := 1 to 4000 do
  begin
    { The magnitude is built and then signed by hand: FPC's `shr` is a LOGICAL
      shift even on a signed type, so shifting a negative Int64 would hand back a
      large positive one and the sweep would never see a negative dividend.

      THE DIVIDEND IS KEPT BIG ON PURPOSE -- shifted by at most 7, so it sits
      between 2^54 and 2^62 and every one of these pairs is in the band where
      the old formula cancelled to 0. A first draft drew both operands from the
      whole range and only 523 of 4000 landed above 2^53; the sweep still caught
      the defect, but most of it was measuring nothing, and the count assertion
      below is there so a future edit cannot quietly shrink it again. The DIVISOR
      spans the whole range, which is what varies the number of halvings. }
    ia := Int64(NextRaw and QWord($3FFFFFFFFFFFFFFF)) shr Integer(NextRaw mod 8);
    if (NextRaw and 1) <> 0 then ia := -ia;
    ib := Int64(NextRaw and QWord($3FFFFFFFFFFFFFFF)) shr Integer(NextRaw mod 62);
    if (NextRaw and 1) <> 0 then ib := -ib;
    if ib = 0 then ib := 3;
    a := ia;
    b := ib;
    { Re-read what the Doubles actually hold: above 2^53 the conversion rounds,
      and the oracle has to be asked about the number the Double IS. }
    if not TryD2I(a, ia) then Continue;
    if not TryD2I(b, ib) then Continue;
    if ib = 0 then Continue;
    if Abs(a) > Pow2_53 then Inc(above53);
    e := ValMod(ValDouble(a), ValDouble(b), ra);
    if IsError(e) then begin Inc(bad); Continue; end;
    e := ValMod(ValInt(ia), ValInt(ib), rb);
    if IsError(e) then begin Inc(bad); Continue; end;
    { ASSIGNED, NEVER `Double(rb.Int)`: a typecast between two 8-byte types
      reinterprets the bytes instead of converting the number, and the check
      would then be comparing a remainder against a bit pattern. }
    oracle := rb.Int;
    if (ra.Kind <> vkDouble) or (rb.Kind <> vkInt) or (ra.Num <> oracle) then
      Inc(bad);
  end;
  Report(bad = 0, 'the Double branch agrees with the int% branch on 4000 ' +
                  'integral pairs (' + IntToStr(bad) + ' disagreed)');
  { A sweep that never reached the interesting magnitudes would pass on the old
    code too, so the sweep states how far it went. }
  Report(above53 > 3500, 'and nearly all of that sweep was above 2^53 (' +
                         IntToStr(above53) + ' of 4000)');

  { (3) THE DEFINITION, over the whole exponent range including subnormals. }
  seed := QWord(1234567891234567);
  bad := 0;
  for k := 1 to 4000 do
  begin
    { Any finite, non-zero pattern: the exponent field is forced into 1..2045 so
      neither operand is zero, infinite or a NaN, and the sign and fraction are
      left as they fall. Subnormals are reached by the divisor sweep below. }
    a := FromBits((NextRaw and QWord($800FFFFFFFFFFFFF)) or
                  (QWord((NextRaw mod 2045) + 1) shl 52));
    b := FromBits((NextRaw and QWord($800FFFFFFFFFFFFF)) or
                  (QWord((NextRaw mod 2045) + 1) shl 52));
    e := ValMod(ValDouble(a), ValDouble(b), ra);
    if IsError(e) or (ra.Kind <> vkDouble) or (not IsFiniteD(ra.Num)) then
    begin
      Inc(bad);
      Continue;
    end;
    if Abs(ra.Num) >= Abs(b) then Inc(bad)
    else if (ra.Num <> 0) and ((ra.Num < 0) <> (a < 0)) then Inc(bad);
  end;
  Report(bad = 0, '0 <= |r| < |b| and sign(r) = sign(a) over 4000 pairs ' +
                  'spanning the exponent range (' + IntToStr(bad) + ' broke it)');

  { The same definition with a SUBNORMAL divisor, which is where the scaling has
    to stop halving. A separate sweep because the pattern generator above never
    produces one. }
  seed := QWord(99194853094755497);
  bad := 0;
  for k := 1 to 2000 do
  begin
    a := FromBits((NextRaw and QWord($800FFFFFFFFFFFFF)) or
                  (QWord((NextRaw mod 2045) + 1) shl 52));
    b := FromBits((NextRaw and QWord($800FFFFFFFFFFFFF)));   // exponent 0
    if b = 0 then Continue;
    e := ValMod(ValDouble(a), ValDouble(b), ra);
    if IsError(e) or (ra.Kind <> vkDouble) or (not IsFiniteD(ra.Num)) then
    begin
      Inc(bad);
      Continue;
    end;
    if Abs(ra.Num) >= Abs(b) then Inc(bad)
    else if (ra.Num <> 0) and ((ra.Num < 0) <> (a < 0)) then Inc(bad);
  end;
  Report(bad = 0, 'and with a SUBNORMAL divisor over 2000 pairs (' +
                  IntToStr(bad) + ' broke it)');

  { Zero is still division by zero, and the int% path is untouched. }
  e := ValMod(ValDouble(1.5), ValDouble(0.0), ra);
  CheckErr(e, peDivByZero, 'x mod 0.0 is still division by zero');
  e := ValMod(ValInt(17), ValInt(5), ra);
  CheckInt(ra, 2, 'the int% path still answers 17 mod 5');
end;

var
  r: TValue;
  e: TPhosphorError;
  i: Int64;
  savedMask: TFPUExceptionMask;
begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  { EXACTLY THE FPU MASK TPhosphorVM.Run INSTALLS, because this unit's answers
    are only defined under it. FiniteD reports `1e308 * 10` as a catchable
    overflow BECAUSE the multiplication is allowed to produce +Inf first; with
    the trap left unmasked -- FPC's default, and this probe's default until it
    was set here -- the same line raises EOverflow and kills the probe instead.
    INVALID-OPERATION and DIVIDE-BY-ZERO stay unmasked on purpose: they are the
    traps the finiteness invariant claims are unreachable, and a probe that
    masked them would prove nothing about the claim it exists to test. }
  savedMask := GetExceptionMask();
  SetExceptionMask(savedMask + [exOverflow, exUnderflow, exPrecision, exDenormalized]);

  // int + int -> int (checked)
  e := ValAdd(ValInt(3), ValInt(4), r);
  CheckErr(e, peNone, 'add int+int no error');
  if ProveFail then CheckInt(r, 8, 'add int+int stays int')   // deliberately wrong
  else CheckInt(r, 7, 'add int+int stays int');

  // int / int -> double (real division)
  e := ValDivReal(ValInt(10), ValInt(4), r);
  CheckDouble(r, 2.5, 'div 10/4 = 2.5 double');

  // int \ int -> int (integer division)
  e := ValDivInt(ValInt(7), ValInt(2), r);
  CheckInt(r, 3, 'idiv 7\2 = 3 int');

  // string + string -> concat
  e := ValAdd(ValStr('ab'), ValStr('cd'), r);
  CheckStr(r, 'abcd', 'concat ab+cd');

  // int + double -> double
  e := ValAdd(ValInt(2), ValDouble(0.5), r);
  CheckDouble(r, 2.5, 'mixed 2+0.5 = 2.5 double');

  // overflow is a CATCHABLE ERROR, not a silent double
  e := ValAdd(ValInt(High(Int64)), ValInt(1), r);
  CheckErr(e, peIntOverflow, 'add overflow -> error');
  e := ValMul(ValInt(High(Int64)), ValInt(2), r);
  CheckErr(e, peIntOverflow, 'mul overflow -> error');
  Report(not TryNegI64(Low(Int64), i), 'neg Low(Int64) overflows');

  // comparison produces a bool VALUE
  e := ValCompare(coGT, ValInt(2), ValInt(1), r);
  CheckBool(r, True, 'compare 2>1 = true');
  e := ValCompare(coGT, ValInt(3), ValInt(5), r);
  CheckBool(r, False, 'compare 3>5 = false');
  e := ValCompare(coEQ, ValStr('x'), ValStr('x'), r);
  CheckBool(r, True, 'compare "x"="x" = true');

  // ^ is always double
  e := ValPow(ValInt(2), ValInt(10), r);
  CheckDouble(r, 1024, 'pow 2^10 = 1024 double');

  // '+' concatenates when either side is a string: the other is coerced to its
  // text and the two are joined (a phase-1 decision; not a type error).
  e := ValAdd(ValStr('a'), ValInt(1), r);
  Report(not IsError(e), 'string + int -> no error');
  CheckStr(r, 'a1', 'string + int concatenates to "a1"');
  // div-by-zero and real type errors are still recorded, not raised
  e := ValDivReal(ValInt(1), ValInt(0), r);
  CheckErr(e, peDivByZero, 'div by zero -> error');

  { The finiteness invariant: every entry point total on a non-finite Double, and
    every finite answer unchanged.

    WRAPPED, because the failure mode here is a TRAP, not a wrong answer. Without
    this the probe simply dies -- exit 217, no summary line -- and the suite can
    only say it "did not run", which is exactly the report that says least about
    a crash. Catching turns it into a named FAILURE that points at the region.
    Verified by neutralising InI64Range's bit test and watching this fire. }
  try
    CheckNonFinite;
    CheckFiniteStillWorks;
    CheckPowOverTheWholeRange;
    CheckNumberText;
    CheckFloatRemainder;
    CheckOperatorsWithOverflowUnmasked;
    CheckLibraryDoorOnNonFinite;
  except
    on E: Exception do
      Report(False, 'the process trapped in ' + Stage + ' [' + E.ClassName +
                    ': ' + E.Message + ']');
  end;

  SetExceptionMask(savedMask);
  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed = 0 then Halt(0) else Halt(1);
end.
