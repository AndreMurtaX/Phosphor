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

{ The sine/cosine internals, exported for tests/probe_trig.lpr, which checks
  them bit for bit against a copy of the round-11 code. Nothing else calls them,
  and no host should: SinCosFast's answer is only valid when it returns True,
  and none of the three is a registered name. }
function SinCosD(x: Double; wantCos: Boolean): Double;
function SinCosFast(x: Double; wantCos: Boolean; out yh, yl: Double): Boolean;
function RemPio2Parts(x: Double; out rHi, rLo: Double): Integer;

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

{ DOUBLE-DOUBLE ARITHMETIC, for log2/log10 and the sin/cos argument reduction
  below (2026-10-11, round 11). A value is Hi + Lo, Lo below half an ulp of Hi,
  about 106 bits. Every operation is plain Double arithmetic, which x86_64
  does in SSE2 on both OSes -- no Extended anywhere -- so both answer the same
  bits. TwoSum and TwoProd (Dekker's split, no FMA) are exact. }
type
  TDD = record Hi, Lo: Double; end;

procedure TwoSum(a, b: Double; out s, e: Double);
var bb: Double;
begin s := a + b; bb := s - a; e := (a - (s - bb)) + (b - bb); end;

procedure TwoProd(a, b: Double; out p, e: Double);
var t, ah, al, bh, bl: Double;
begin
  p := a * b;
  t := 134217729.0 * a; ah := t - (t - a); al := a - ah;
  t := 134217729.0 * b; bh := t - (t - b); bl := b - bh;
  e := ((ah * bh - p) + ah * bl + al * bh) + al * bl;
end;

function DD(h, l: Double): TDD;
begin Result.Hi := h; Result.Lo := l; end;

function DDMul(const a, b: TDD): TDD;
var p, e: Double;
begin
  TwoProd(a.Hi, b.Hi, p, e);
  e := e + (a.Hi * b.Lo + a.Lo * b.Hi);
  TwoSum(p, e, Result.Hi, Result.Lo);
end;

function DDAdd(const a, b: TDD): TDD;
var s, e: Double;
begin
  TwoSum(a.Hi, b.Hi, s, e);
  e := e + (a.Lo + b.Lo);
  TwoSum(s, e, Result.Hi, Result.Lo);
end;

{ LOG2 AND LOG10 WERE NOT EXACT ON EXACT POWERS, ON WINDOWS ONLY. Math.Log2 and
  Math.Log10 are ln(x) times a constant; on Win64 `float` is Double, so that
  rounds twice, and 38 of 166 exact powers came back one ulp off:
  log2(8) = 2.9999999999999996, so int(log2(8)) = 2, and int(log10(1e15)) =
  14. Linux computes the same product in Extended and rounds once.

  Now both OSes compute the same thing: x = m * 2^e with m in
  [sqrt(1/2), sqrt(2)), ln(m) = 2 atanh(s), s = (m-1)/(m+1), summed as a
  double-double, then e + ln(m)/ln(2), or e*log10(2) + ln(m)*log10(e), rounded
  ONCE -- the correctly rounded result IEEE 754 (clause 9.2) recommends,
  except in a case closer to a rounding boundary than about 2^-100. At an exact
  power of two m is 1, ln(m) is 0 and log2 is the integer e itself; at an exact
  power of ten the double-double lies within 2^-100 of the integer and rounds
  to it. The constants are the double-double values of 1/ln 2, log10 2 and
  log10 e, each spelled with 26 digits of the Double's EXACT value: a compiler
  that reads a literal into Extended (Linux) and then rounds to Double cannot
  double-round a literal that close to the Double it names. }
const
  INV_LN2_HI: Double = 1.4426950408889633870046509e+00;
  INV_LN2_LO: Double = 2.0355273740931033111021090e-17;
  LOG10_2_HI: Double = 3.0102999566398119801746702e-01;
  LOG10_2_LO: Double = -2.8037281277851703937326014e-18;
  LOG10_E_HI: Double = 4.3429448190325181666793242e-01;
  LOG10_E_LO: Double = 1.0983196502167650727388598e-17;

{ x > 0 and finite: x = m * 2^e, m in [sqrt(1/2), sqrt(2)], answers ln(m). }
function LogSplit(x: Double; out e: Integer): TDD;
var
  bits: QWord;
  m, f, q1, q2, p, pe, r: Double;
  den, s, z, poly, c: TDD;
  k: Integer;
  dk: Double;
begin
  e := 0;
  if x < 2.2250738585072014e-308 then          // subnormal: scale by 2^54
  begin x := x * 18014398509481984.0; e := -54; end;
  bits := PQWord(@x)^;
  e := e + Integer((bits shr 52) and $7FF) - 1023;
  bits := (bits and QWord($000FFFFFFFFFFFFF)) or QWord($3FF0000000000000);
  m := PDouble(@bits)^;                         // [1, 2)
  if m > 1.4142135623730951 then begin m := m * 0.5; Inc(e); end;
  f := m - 1;                                   // exact (Sterbenz)
  TwoSum(2.0, f, den.Hi, den.Lo);               // 2 + f, exact
  q1 := f / den.Hi;                             // s = f / (2 + f)
  TwoProd(q1, den.Hi, p, pe);
  r := ((f - p) - pe) - q1 * den.Lo;
  q2 := r / den.Hi;
  TwoSum(q1, q2, s.Hi, s.Lo);
  z := DDMul(s, s);                             // |z| < 0.0295
  // atanh(s)/s = sum of z^k/(2k+1); 16 terms leave less than 2^-79
  poly := DD(0, 0);
  for k := 15 downto 0 do
  begin
    dk := 2 * k + 1;                            // 1/(2k+1) as a double-double
    c.Hi := 1 / dk;
    TwoProd(c.Hi, dk, p, pe);
    c.Lo := ((1 - p) - pe) / dk;
    poly := DDAdd(DDMul(poly, z), c);
  end;
  Result := DDMul(s, poly);
  Result.Hi := 2 * Result.Hi; Result.Lo := 2 * Result.Lo;
end;

function Log2Exact(x: Double): Double;
var e: Integer; l: TDD;
begin
  l := LogSplit(x, e);
  Result := DDAdd(DD(e, 0), DDMul(l, DD(INV_LN2_HI, INV_LN2_LO))).Hi;
end;

function Log10Exact(x: Double): Double;
var e: Integer; l: TDD;
begin
  l := LogSplit(x, e);
  Result := DDAdd(DDMul(DD(e, 0), DD(LOG10_2_HI, LOG10_2_LO)),
                  DDMul(l, DD(LOG10_E_HI, LOG10_E_LO))).Hi;
end;

function f_log10(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin
  d := N(Args);
  if not (d > 0) then begin Err := DomainError('log10', 'a positive number', d); Result := ValDouble(0); Exit; end;
  Err := NoError();
  if IsInfinite(d) then Result := ValDouble(Log10(d)) else Result := ValDouble(Log10Exact(d));
end;
function f_log2(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin
  d := N(Args);
  if not (d > 0) then begin Err := DomainError('log2', 'a positive number', d); Result := ValDouble(0); Exit; end;
  Err := NoError();
  if IsInfinite(d) then Result := ValDouble(Log2(d)) else Result := ValDouble(Log2Exact(d));
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

{ SIN AND COS ANSWERED x ITSELF ON LINUX FOR |x| >= 2^63 (2026-10-11, round
  11): sin(1e22) printed 1E22. On x86_64-linux System.Sin/Cos are the x87
  fsin/fcos instructions, which leave an operand that large unchanged, and
  below it reduce with a 66-bit pi -- sin(pi) was wrong from its 5th digit,
  sin(1000000) from its 15th. Windows runs FPC's own Cephes code, which
  reduces properly and was within an ulp (one ulp off in about a quarter of
  a sweep), so the same program printed different numbers on the two OSes.

  Now both OSes run this code. The argument is reduced EXACTLY: x = n*pi/2 + r,
  |r| <= pi/4, by multiplying x's 53-bit integer mantissa by the bits of 2/pi
  that matter (Payne and Hanek's method) in 32-bit limbs, keeping about 190
  bits below the binary point -- enough for the Double nearest a multiple of
  pi/2, whose r loses about 61 leading bits. r is then a double-double, and the
  sine and cosine of it are summed as double-doubles too.
  TWO_OVER_PI is 2/pi in hex, derived from pi and checked against the
  published table. Non-finite x keeps the RTL path (it answers NaN). }
const
  TWO_OVER_PI: array[0..39] of LongWord = (
    $A2F9836E, $4E441529, $FC2757D1, $F534DDC0, $DB629599, $3C439041,
    $FE5163AB, $DEBBC561, $B7246E3A, $424DD2E0, $06492EEA, $09D1921C,
    $FE1DEB1C, $B129A73E, $E88235F5, $2EBB4484, $E99C7026, $B45F7E41,
    $3991D639, $835339F4, $9C845F8B, $BDF9283B, $1FF897FF, $DE05980F,
    $EF2F118B, $5A0A6D1F, $6D367ECF, $27CB09B7, $4F463F66, $9E5FEA2D,
    $7527BAC7, $EBE5F17B, $3D0739F7, $8A5292EA, $6BFB5FB1, $1F8D5D08,
    $56033046, $FC7B6BAB, $F0CFBC20, $9AF4361D);
  PIO2_HI: Double = 1.5707963267948965579989817e+00;
  PIO2_LO: Double = 6.1232339957367660358688201e-17;
  PIO4_D:  Double = 7.8539816339744827899949087e-01;   // just below pi/4

{ |x| > pi/4, finite: x = n*pi/2 + r with |r| <= pi/4; answers n mod 4. }
function RemPio2(x: Double; out r: TDD): Integer;
var
  bits, mant, t, carry, a1, a2: QWord;
  e, i0, i, k, p0, h, sh: Integer;
  a: array[0..7] of QWord;
  pr: array[0..10] of QWord;      // product limbs, 32 bits each, little-endian
  neg: Boolean;
  hi53, mid11, lo53: Int64;
  fh, fl, fm: Double;
  frac: TDD;

  function Bit(idx: Integer): QWord;
  begin
    if (idx < 0) or (idx > 351) then Exit(0);
    Result := (pr[idx shr 5] shr (idx and 31)) and 1;
  end;
  function Limb(j: Integer): QWord;
  begin
    if (j < 0) or (j > 10) then Exit(0);
    Result := pr[j];
  end;
  { Bits top .. top-63, zero below 0 and above 351: a 64-bit window cut from
    three limbs by shifts. It was a loop of 64 single-bit reads, and with the
    two clears and the scan for the top bit, about 1500 calls a reduction
    (ledger R1). The integers are the same, so is every bit of r. }
  function Bits64(top: Integer): QWord;
  var lo, j, off: Integer;
  begin
    lo := top - 63;
    if lo <= -64 then Exit(0);
    if lo < 0 then Exit((Limb(0) or (Limb(1) shl 32)) shl (-lo));
    j := lo shr 5; off := lo and 31;
    if off = 0 then Exit(Limb(j) or (Limb(j + 1) shl 32));
    Result := (Limb(j) shr off) or (Limb(j + 1) shl (32 - off))
              or (Limb(j + 2) shl (64 - off));
  end;
  procedure ClearFrom(idx: Integer);       // zero every bit >= idx
  var j: Integer;
  begin
    if idx > 351 then Exit;
    pr[idx shr 5] := pr[idx shr 5] and ((QWord(1) shl (idx and 31)) - 1);
    for j := (idx shr 5) + 1 to 10 do pr[j] := 0;
  end;

begin
  bits := PQWord(@x)^ and QWord($7FFFFFFFFFFFFFFF);
  mant := (bits and QWord($000FFFFFFFFFFFFF)) or QWord($0010000000000000);
  e := Integer(bits shr 52) - 1075;          // |x| = mant * 2^e
  // 2/pi words whose product with mant is a multiple of 4 add nothing mod 4
  if e >= 34 then i0 := (e - 34) div 32 + 1 else i0 := 0;
  for k := 0 to 7 do a[k] := TWO_OVER_PI[i0 + 7 - k];
  for k := 0 to 10 do pr[k] := 0;
  for i := 0 to 1 do
  begin
    if i = 0 then t := mant and $FFFFFFFF else t := mant shr 32;
    carry := 0;
    for k := 0 to 7 do
    begin
      carry := t * a[k] + pr[i + k] + carry;   // < 2^64: (2^32-1)^2 + 2(2^32-1)
      pr[i + k] := carry and $FFFFFFFF;
      carry := carry shr 32;
    end;
    pr[i + 8] := carry;
  end;
  // |x| * 2/pi = pr * 2^(e - 32*(i0+8)); bit p0 is the units bit
  p0 := 32 * (i0 + 8) - e;
  Result := Integer(Bit(p0) + 2 * Bit(p0 + 1));
  ClearFrom(p0);                               // keep the fraction only
  neg := Bit(p0 - 1) <> 0;                     // fraction >= 1/2: r = frac - 1
  if neg then
  begin
    Result := (Result + 1) and 3;
    carry := 1;                                // pr := 2^p0 - pr, two's complement
    for k := 0 to 10 do
    begin
      carry := (not pr[k] and $FFFFFFFF) + carry;
      pr[k] := carry and $FFFFFFFF;
      carry := carry shr 32;
    end;
    ClearFrom(p0);
  end;
  h := -1;                                     // the fraction's top set bit
  for k := 10 downto 0 do                      // (every bit >= p0 is clear)
    if (h < 0) and (pr[k] <> 0) then h := 32 * k + BsrDWord(LongWord(pr[k]));
  if h < 0 then begin r := DD(0, 0); Exit; end;
  a1 := Bits64(h);
  a2 := Bits64(h - 64);
  sh := h - p0;
  hi53 := Int64(a1 shr 11);                    // each below 2^53: converts exactly
  mid11 := Int64(a1 and $7FF);
  lo53 := Int64(a2 shr 11);
  fh := hi53;
  fl := mid11;
  fm := lo53;
  fl := fl * 9007199254740992.0 + fm;          // one rounding, 2^-53 of a tail
  fh := ldexp(fh, sh - 52);
  fl := ldexp(fl, sh - 116);
  TwoSum(fh, fl, frac.Hi, frac.Lo);
  r := DDMul(frac, DD(PIO2_HI, PIO2_LO));
  if neg then begin r.Hi := -r.Hi; r.Lo := -r.Lo; end;
  if x < 0 then
  begin
    Result := (4 - Result) and 3;
    r.Hi := -r.Hi; r.Lo := -r.Lo;
  end;
end;

{ sin and cos of a double-double r, |r| <= pi/4, by their Taylor series summed
  as double-doubles in Horner form -- sin r = r(1 - z/(2*3)(1 - z/(4*5)(...))),
  cos r = 1 - z/(1*2)(1 - z/(3*4)(...)), z = r*r. Fifteen factors leave a
  term below 2^-110, so the one rounding at the end is the correct one but in
  a case within about 2^-100 of a rounding boundary. }
function DDDivI(const a: TDD; di: Integer): TDD;
var q1, p, e, rem, d: Double;
begin
  d := di;
  q1 := a.Hi / d;
  TwoProd(q1, d, p, e);
  rem := ((a.Hi - p) - e + a.Lo) / d;
  TwoSum(q1, rem, Result.Hi, Result.Lo);
end;

function SinCosKernel(const r: TDD; wantCos: Boolean): Double;
var z, poly: TDD; k, j: Integer;
begin
  z := DDMul(r, r);
  poly := DD(1, 0);
  for k := 15 downto 1 do
  begin
    if wantCos then j := 2 * k - 1 else j := 2 * k;
    poly := DDDivI(DDMul(z, poly), j * (j + 1));
    poly := DDAdd(DD(1, 0), DD(-poly.Hi, -poly.Lo));
  end;
  if wantCos then Result := poly.Hi else Result := DDMul(r, poly).Hi;
end;

{ THE FAST PATH (2026-10-12, ledger R1). The code above costs about 1 us a
  call -- 17x the old -- and it is the DEFINITION of the answer: every result
  it gives is the correctly rounded one but in a case within about 2^-100 of a
  rounding boundary. The fast path gives the SAME bits by proving, call by
  call, that it knows the rounding, and handing the call to the definition
  when it does not (Ziv's strategy):

  - reduction, for pi/4 < |x| < 1.5 * 2^20: Cody and Waite's, with pi/2 split
    as C1 + C2 + C3 + C4 -- three short parts (31, 32 and 28 significant bits)
    and a Double, 152 bits of pi/2 (fdlibm's constants, re-derived from pi).
    n = nearest(x * 2/pi) is below 2^20, so each n*Ci (i <= 3) is exact, x -
    n*C1 is exact (Sterbenz), the next two subtractions are carried by TwoSum,
    and what is left is the rounding of the low word: about 2^-107 absolute
    when |r| is near pi/4, and never worse than 2^-76 relative, even at the
    smallest |r| any Double reaches (about 2^-61). Above the bound the
    reduction is RemPio2,
    which is the definition's own (its r, bit for bit).
  - kernel: r = a + t, a = j/64 the nearest, |t| <= 1/128, and
      sin r = sin a + cos a * t + (sin a * ct + cos a * st)
      cos r = cos a - sin a * t + (cos a * ct - sin a * st)
    with ct = cos t - 1 and st = sin t - t by their Taylor series in Double
    (the first term left out is below 2^-71 of the result), sin a and cos a
    double-doubles from a table, the leading product as a double-double
    (Dekker), and r's low word through the derivative. At |r| <= pi/4 + 2^-30
    the result lies within 2^-64 of the true value, relative; the sweep in
    tests/probe_trig.lpr measures the error actually reached.
  - the test: yh + yl is that value. If the interval of half-width
    TRIG_EPS * |yh| around it lies inside the rounding interval of yh, the true
    value rounds to yh -- and so does the definition, whose own error is about
    2^-100 -- so yh is the answer. Otherwise (about 1 call in 350) the
    definition runs. TRIG_EPS = 2^-62 is four times the error bound; the
    largest error the probe's sweeps reach is about 2^-65.5.

  Measured on Windows (tests/probe_trig.lpr --bench), ns a call, round 11 ->
  now: 0.1 .. pi/4 650 -> 20, 1 .. 1e6 1200 -> 24, 1e10 .. 1e300 1550 -> 118.

  Plain Double arithmetic throughout (SSE2 on x86_64, no Extended, no FMA), so
  both OSes compute the same bits; every constant is spelled by its bit
  pattern, which no literal parser can round, and scripts/gen-sincos-table.py
  derives each one from pi in exact arithmetic. tests/probe_trig.lpr compares
  this against a copy of the round-11 code, bit for bit. }
const
  CW_MAX: Double = 1572864.0;                   // 1.5 * 2^20
  { 0: 2/pi; 1..3: C1..C3 (33 bits each); 4: C4; 5: TRIG_EPS = 2^-62 }
  CW_Q: array[0..5] of QWord = (
    QWord($3FE45F306DC9C883), QWord($3FF921FB54400000), QWord($3DD0B4611A600000),
    QWord($3BA3198A2E000000), QWord($397B839A252049C1), QWord($3C10000000000000));
  { -1/3!, 1/5!, -1/7! (st), 1/4!, -1/6! (ct) }
  POLY_Q: array[0..4] of QWord = (
    QWord($BFC5555555555555), QWord($3F81111111111111), QWord($BF2A01A01A01A01A),
    QWord($3FA5555555555555), QWord($BF56C16C16C16C17));
  SGN_Q: array[0..1] of QWord = (QWord($3FF0000000000000), QWord($BFF0000000000000));  // 1, -1
  { sin(j/64) hi, lo, cos(j/64) hi, lo, for j = 0 .. 50 }
  SC_TAB: array[0..203] of QWord = (
    QWord($0000000000000000), QWord($0000000000000000), QWord($3FF0000000000000), QWord($0000000000000000),   // 0/64
    QWord($3F8FFFAAAAEEEED5), QWord($BC02AB639A9F0776), QWord($3FEFFF000155549F), QWord($3C828A28A03A5EF3),   // 1/64
    QWord($3F9FFEAAAEEEE86F), QWord($BC3CD406FB224AE2), QWord($3FEFFC00155527D3), QWord($BC83B54492D89B5B),   // 2/64
    QWord($3FA7FDC01032FBA9), QWord($BC4599BDF46E997A), QWord($3FEFF7006BFDF99F), QWord($BC78B3B560648D5F),   // 3/64
    QWord($3FAFFAAAEEED4EDB), QWord($BC42D16D32684B69), QWord($3FEFF0015549F4D3), QWord($3C8328387B99426F),   // 4/64
    QWord($3FB3FACB12D1755B), QWord($BC5921915299468B), QWord($3FEFE7034129EF6F), QWord($BC6CBF4337C96F97),   // 5/64
    QWord($3FB7F701032550E4), QWord($3C3AFC2D1800501A), QWord($3FEFDC06BF7E6B9B), QWord($3C831902B535F8DB),   // 6/64
    QWord($3FBBF1B78568391D), QWord($3C5E91841DEA4CC8), QWord($3FEFCF0C800E99B1), QWord($3C6EA3D786D186AC),   // 7/64
    QWord($3FBFEAAEEE86EE36), QWord($BC4AFCB2BCC6F03B), QWord($3FEFC015527D5BD3), QWord($3C8B68F35094EFB8),   // 8/64
    QWord($3FC1F0D3D7AFCEAF), QWord($BC66EF95099769A5), QWord($3FEFAF22263C4BD3), QWord($BC552ACE133A2769),   // 9/64
    QWord($3FC3EB312C5D66CB), QWord($3C647D666B66CB91), QWord($3FEF9C340A7CC428), QWord($3C8C5B6B063B7462),   // 10/64
    QWord($3FC5E44FCFA126F3), QWord($BC66F443063F89B6), QWord($3FEF874C2E1EECF6), QWord($BC8C6514E1332B16),   // 11/64
    QWord($3FC7DC102FBAF2B5), QWord($3C45AB50E23C97C3), QWord($3FEF706BDF9ECE1C), QWord($BC8698C80C36DCB4),   // 12/64
    QWord($3FC9D252D0CEC312), QWord($3C59C43D80B1137D), QWord($3FEF57948CFF6797), QWord($3C6E3A0D3E03B1D4),   // 13/64
    QWord($3FCBC6F84EDC6199), QWord($3C69C1A56A7B0CAB), QWord($3FEF3CC7C3B3D16E), QWord($BC621A3AD28A3494),   // 14/64
    QWord($3FCDB9E15FB5A5D0), QWord($BC632E20D6CC6FC2), QWord($3FEF20073086649F), QWord($3C7B940416C1984B),   // 15/64
    QWord($3FCFAAEED4F31577), QWord($BC615D88508E32B8), QWord($3FEF01549F7DEEA1), QWord($3C8D3C1E99E5CAFD),   // 16/64
    QWord($3FD0CD00CEF36436), QWord($BC79FB0A0C93E2B4), QWord($3FEEE0B1FBC0F11C), QWord($BC4BFD2380BBC3B1),   // 17/64
    QWord($3FD1C37D64C6B876), QWord($3C746076FE0DCFF4), QWord($3FEEBE214F76EFA8), QWord($BC802F9F12BA543E),   // 18/64
    QWord($3FD2B8DDC43EB49F), QWord($3C61553899F2D807), QWord($3FEE99A4C3A7CD83), QWord($BC82264B1BC53CE8),   // 19/64
    QWord($3FD3AD129769D3D8), QWord($3C003D550487839A), QWord($3FEE733EA0193D40), QWord($BC86428B3546CE13),   // 20/64
    QWord($3FD4A00C9B0F3D20), QWord($3C7823BA6BB08EAD), QWord($3FEE4AF14B2A449C), QWord($BC868CA02E8A6833),   // 21/64
    QWord($3FD591BC9FA2F597), QWord($3C67C74BAC3FE0CB), QWord($3FEE20BF49ACD6C1), QWord($BC5660AEC7EF636B),   // 22/64
    QWord($3FD682138A38D7F7), QWord($BC7D889202444AAD), QWord($3FEDF4AB3EBD875E), QWord($BC8E2D8A7E6736C4),   // 23/64
    QWord($3FD7710255764214), QWord($BC66EAD7314BB6CE), QWord($3FEDC6B7EB995912), QWord($3C54B364776DCD35),   // 24/64
    QWord($3FD85E7A12826949), QWord($3C78A40E9B5FACE0), QWord($3FED96E82F71A9DC), QWord($3C8FF61BD5D2039D),   // 25/64
    QWord($3FD94A6BE9F546C5), QWord($BC769CE13E683F58), QWord($3FED653F073E4040), QWord($BC876236434BEC37),   // 26/64
    QWord($3FDA34C91CC50CCA), QWord($BC5A310E3B50CECD), QWord($3FED31BF8D8D7C06), QWord($3C7E60DD3089CBDD),   // 27/64
    QWord($3FDB1D8305321617), QWord($BC7AE242CB99F519), QWord($3FECFC6CFA52AD9F), QWord($3C88B5B5508F2A0D),   // 28/64
    QWord($3FDC048B17B140A3), QWord($3C619FE6757E9FA7), QWord($3FECC54AA2B2972E), QWord($3C64EE162BA83A98),   // 29/64
    QWord($3FDCE9D2E3D4A51F), QWord($BC62FC8A12DAE298), QWord($3FEC8C5BF8CE1A84), QWord($3C7AB3D1A1590123),   // 30/64
    QWord($3FDDCD4C15329C9A), QWord($3C70D4C6E171FD9A), QWord($3FEC51A48B8B175E), QWord($BC61BBB43B9AA880),   // 31/64
    QWord($3FDEAEE8744B05F0), QWord($BC5789B43C9B027D), QWord($3FEC1528065B7D50), QWord($BC8892111312E828),   // 32/64
    QWord($3FDF8E99E76ABC97), QWord($3C59D950AF2D00A3), QWord($3FEBD6EA310294F5), QWord($3C731BBCC88C109D),   // 33/64
    QWord($3FE0362939C69955), QWord($BC82D8CD78397B01), QWord($3FEB96EEEF58840E), QWord($3C545A3CC78FADE0),   // 34/64
    QWord($3FE0A4021E9E1001), QWord($BC86F643A13914F6), QWord($3FEB553A410C104E), QWord($3C58FF7947027A15),   // 35/64
    QWord($3FE110D0C4B69C3B), QWord($3C8D918998809981), QWord($3FEB11D04162A4C6), QWord($3C71DD561EFBC0C2),   // 36/64
    QWord($3FE17C8E5F2EEDB0), QWord($3C635E57102E2488), QWord($3FEACCB526F69DE5), QWord($3C88FB6A8DD6B6CC),   // 37/64
    QWord($3FE1E7343236574C), QWord($3C722A3FA4F41D5A), QWord($3FEA85ED4373E02D), QWord($3C69BE06385EC792),   // 38/64
    QWord($3FE250BB93788BBB), QWord($3C7EA3D02457BCCE), QWord($3FEA3D7D0352BDCF), QWord($BC868DBAECA19669),   // 39/64
    QWord($3FE2B91DEA88421E), QWord($BC8FA371DB216AB0), QWord($3FE9F368ED912F85), QWord($BC81D200C5791606),   // 40/64
    QWord($3FE32054B148BC4F), QWord($3C8F6B42095A135B), QWord($3FE9A7B5A36A6514), QWord($3C8722CFCC9FA7A9),   // 41/64
    QWord($3FE386597456282B), QWord($BC710FADA93B07A8), QWord($3FE95A67E00CB1FD), QWord($BC80BEFDA21F862D),   // 42/64
    QWord($3FE3EB25D36CD53A), QWord($BC5BE570E1570FC0), QWord($3FE90B84784DDAF7), QWord($BC70FEB10AB93B87),   // 43/64
    QWord($3FE44EB381CF386B), QWord($BC83ED6C1E6A5505), QWord($3FE8BB105A5DC900), QWord($3C8863E03E9474C1),   // 44/64
    QWord($3FE4B0FC46AAB761), QWord($3C20DA05738CC59C), QWord($3FE869108D77A6C6), QWord($3C7338FFE2BFE9DD),   // 45/64
    QWord($3FE511F9FD7B351C), QWord($BC85C0E861C48831), QWord($3FE8158A31916D5D), QWord($BC6DE8B90B8228DE),   // 46/64
    QWord($3FE571A6966D59B3), QWord($3C5C843B4D0FB197), QWord($3FE7C0827F09E54F), QWord($BC6C73D6D72AEE68),   // 47/64
    QWord($3FE5CFFC16BF8F0D), QWord($3C896CB370EB578A), QWord($3FE769FEC655211F), QWord($BC6827D5CF8C68C5),   // 48/64
    QWord($3FE62CF49921AC79), QWord($BC8EDD9855B6241A), QWord($3FE712046FA77678), QWord($3C8425B0A5029C81),   // 49/64
    QWord($3FE6888A4E134B2F), QWord($BC86B7D37644D5E6), QWord($3FE6B898FA9EFB5D), QWord($3C715AC786CCF4B2));   // 50/64

type
  TDArr = array[0..203] of Double;
  PDArr = ^TDArr;

{ x finite, 2^-27 <= |x|: the sine (or cosine) of x as yh + yl, and whether
  yh is provably the correctly rounded value. Exported for the probe.

  One routine with every helper written out: FPC keeps a variable whose
  address an out parameter takes in memory, and the inline Split and TwoSum
  this was first written with cost half its time in loads and stores.
  Dekker's split is m*a with m = 2^27 + 1: hi = m*a - (m*a - a), lo = a - hi.

  The kernel: r = a + t, j = nearest(|rh| * 64), found from the exact
  |rh| * 64 so that |t| <= 1/128; t = |rh| - j/64 is exact (both are
  multiples of ulp(rh), and t has fewer than 53 bits). Each FastTwoSum is
  valid: |cos a| >= 0.7 > |sin a * t|, and sin a = 0 or |sin a| > 1/128 >= |t|. }
function SinCosFast(x: Double; wantCos: Boolean; out yh, yl: Double): Boolean;
var
  q, j, k, o, nb: Integer;
  cw, tb, pq, sg: PDArr;
  rh, rl, fn, t, s, e, s2, e2, lo, hu, f, jf, z, ct, st, a, al, bh, bl,
  t1, t2, c1, c2, p, w, h, l, hr, lr: Double;
  b: QWord;
begin
  cw := PDArr(@CW_Q);
  if Abs(x) <= PIO4_D then
  begin
    rh := x; rl := 0; q := 0;
  end
  else if Abs(x) < CW_MAX then
  begin
    fn := x * cw^[0];
    fn := (fn + 6755399441055744.0) - 6755399441055744.0;   // nearest, 1.5*2^52
    t := x - fn * cw^[1];                                   // exact
    p := -(fn * cw^[2]);                                    // exact
    s := t + p; w := s - t; e := (t - (s - w)) + (p - w);   // TwoSum: s + e
    p := -(fn * cw^[3]);                                    // exact
    s2 := s + p; w := s2 - s; e2 := (s - (s2 - w)) + (p - w);
    lo := (e + e2) - fn * cw^[4];
    // r = s2 + lo, left unnormalized: the kernel needs rh early and rl only
    // at the end, through the derivative, where a larger rl/rh comes only
    // with a tiny r (heavy cancellation), and so a tiny t
    rh := s2; rl := lo;
    q := Integer(Trunc(fn) and 3);
  end
  else
  begin
    q := RemPio2Parts(x, hr, lr); rh := hr; rl := lr;
  end;
  if wantCos then q := (q + 1) and 3;
  // The kernel, without a branch a random argument could mispredict: on |r|
  // (sin(-r) = -sin r, cos(-r) = cos r), with A + B*t the leading terms --
  // sin a + cos a * t for an even q, cos a - sin a * t for an odd one.
  sg := PDArr(@SGN_Q);
  nb := Ord(rh < 0);
  rh := rh * sg^[nb]; rl := rl * sg^[nb];
  f := rh * 64.0;
  jf := (f + 6755399441055744.0) - 6755399441055744.0;      // nearest, exact
  j := Trunc(jf);
  t := rh - jf * 0.015625;                                  // exact
  z := t * t;
  pq := PDArr(@POLY_Q);
  ct := z * (-0.5 + z * (pq^[3] + z * pq^[4]));            // cos t - 1
  st := t * z * (pq^[0] + z * (pq^[1] + z * pq^[2]));      // sin t - t
  tb := PDArr(@SC_TAB);
  o := q and 1;
  k := 4 * j + 2 * o;
  a := tb^[k]; al := tb^[k + 1];                           // sin a, or cos a
  k := 4 * j + 2 - 2 * o;
  bh := tb^[k] * sg^[o]; bl := tb^[k + 1] * sg^[o];        // cos a, or -sin a
  t1 := 134217729.0 * t; t1 := t1 - (t1 - t); t2 := t - t1;
  c1 := 134217729.0 * bh; c1 := c1 - (c1 - bh); c2 := bh - c1;
  p := bh * t;
  e := ((c1 * t1 - p) + c1 * t2 + c2 * t1) + c2 * t2;      // bh*t = p + e
  s := a + p; w := p - (s - a);
  w := w + ((((e + al) + bl * t) + (a * ct + bh * st)) + rl * (bh - a * t));
  h := s + w; l := w - (h - s);
  k := (nb and (1 - o)) xor (q shr 1);                      // the sign
  yh := h * sg^[k]; yl := l * sg^[k];
  // the test: half an ulp of yh, or of the smaller gap below a power of two
  b := PQWord(@yh)^;
  if (b and QWord($000FFFFFFFFFFFFF)) = 0 then
    b := (b and QWord($7FF0000000000000)) - (QWord(54) shl 52)
  else b := (b and QWord($7FF0000000000000)) - (QWord(53) shl 52);
  hu := PDouble(@b)^;
  Result := Abs(l) + Abs(h) * cw^[5] < hu;
end;


function RemPio2Parts(x: Double; out rHi, rLo: Double): Integer;
var r: TDD;
begin
  Result := RemPio2(x, r); rHi := r.Hi; rLo := r.Lo;
end;

function SinCosD(x: Double; wantCos: Boolean): Double;
var r: TDD; q: Integer; yl: Double;
begin
  if (PQWord(@x)^ and QWord($7FF0000000000000)) = QWord($7FF0000000000000) then
  begin                                         // NaN or an infinity
    if wantCos then Exit(Cos(x)) else Exit(Sin(x));
  end;
  if Abs(x) < 7.450580596923828125e-9 then      // 2^-27: x and 1 are exact
  begin
    if wantCos then Exit(1.0) else Exit(x);     // keeps sin(-0) = -0
  end;
  if SinCosFast(x, wantCos, Result, yl) then Exit;
  // the definition, for the calls the fast path could not decide
  if Abs(x) <= PIO4_D then
  begin
    r := DD(x, 0); q := 0;
  end
  else q := RemPio2(x, r);
  if wantCos then q := (q + 1) and 3;           // cos x = sin(x + pi/2)
  case q of
    0: Result := SinCosKernel(r, False);
    1: Result := SinCosKernel(r, True);
    2: Result := -SinCosKernel(r, False);
  else Result := -SinCosKernel(r, True);
  end;
end;

function f_sin(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(SinCosD(N(Args), False)); end;
function f_cos(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(SinCosD(N(Args), True)); end;
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
