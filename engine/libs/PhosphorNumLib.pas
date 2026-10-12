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
  function Bits64(top: Integer): QWord;    // bits top .. top-63, zero below 0
  var j: Integer;
  begin
    Result := 0;
    for j := 0 to 63 do Result := (Result shl 1) or Bit(top - j);
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
  for k := p0 to 351 do                        // keep the fraction only
    if Bit(k) <> 0 then pr[k shr 5] := pr[k shr 5] and not (QWord(1) shl (k and 31));
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
    for k := p0 to 351 do
      if Bit(k) <> 0 then pr[k shr 5] := pr[k shr 5] and not (QWord(1) shl (k and 31));
  end;
  h := -1;                                     // the fraction's top set bit
  for k := 351 downto 0 do
    if (h < 0) and (k < p0) and (Bit(k) <> 0) then h := k;
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

function SinCosD(x: Double; wantCos: Boolean): Double;
var r: TDD; q: Integer;
begin
  if IsNan(x) or IsInfinite(x) then
  begin
    if wantCos then Exit(Cos(x)) else Exit(Sin(x));
  end;
  if Abs(x) <= PIO4_D then
  begin
    if Abs(x) < 7.450580596923828125e-9 then    // 2^-27: x and 1 are exact
    begin
      if wantCos then Exit(1.0) else Exit(x);   // keeps sin(-0) = -0
    end;
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
