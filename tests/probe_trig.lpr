{******************************************************************************
  probe_trig -- sin and cos, bit for bit against the round-11 definition

  Round 11 (2026-10-11) made sin/cos correctly rounded and the same on both
  OSes: an exact Payne-Hanek reduction for every argument and a double-double
  Taylor kernel. Each call cost about 1 us, 17x the old (ledger R1). The fast
  path that replaced it (2026-10-12) answers from a Cody-Waite reduction and a
  shorter kernel when it can PROVE the rounding, and falls back to that same
  definition when it cannot. Its claim is therefore exact: the same bits as
  round 11 for every Double. This probe holds it to that claim.

  THE ORACLE is a verbatim copy of the round-11 code -- RemPio2, the kernel and
  SinCosD from engine/libs/PhosphorNumLib.pas at commit 2e3f08d, renamed O* --
  so the comparison is against the definition as shipped, not against a value
  anyone chose. It is checked against four values the round-11 test pinned
  from Python's decimal module (tests/suite/104_trig_log_round11.bas), so a
  copy that drifted would be seen.

  WHAT IS COMPARED, for every x (bit patterns, so -0 and NaN count):
    sin and cos       SinCosD(x) = OSinCosD(x)
    the reduction     RemPio2Parts(x) = ORemPio2(x), n mod 4 and both words
                      of r, for every |x| > pi/4 (word-level now, it read 64
                      single bits a window)
    the error bound   |SinCosFast(x) - the oracle's double-double| / |result|,
                      its maximum printed against TRIG_EPS = 2^-62
  OVER (seeded, deterministic; the counts in brackets are --full's):
    every binade of the Double, 0 (subnormal) .. 2046, both signs, 40 [1280]
    random mantissas each, and 2000 [64000] in each binade the fast path
    serves, 2^-27 .. 2^22;
    the Doubles within 8 ulps of k*pi/4, every k to 2^12 [2^16] and 2000
    [64000] random k to 2^23 (past the Cody-Waite bound, k ~ 2^21);
    500 [2000] ulps either side of each threshold, 2^-27, pi/4 and 1.5 * 2^20,
    and 62 [250] of each (2j+1)/128, where the kernel's table index changes;
    the two Doubles closest to a multiple of pi/2 in each binade from 2^-1 to
    2^1023, 8 [32] ulps either side -- found by continued fractions of
    2^e * 2/pi in tests/probe_trig_hard.py, which writes
    tests/probe_trig_hard.inc; 6381956970095103 * 2^797, the hardest Double
    to reduce, is one of them;
    +-0, +-Inf, NaN, the smallest and largest subnormal and normal.

  Prints the sweep's size, "mismatches: N", "ok: N" / "fail: M"; exits 1 on
  any mismatch, and when the measured error is over a quarter of TRIG_EPS.
    probe_trig            the quick sweep, 0.66 million arguments (the suite)
    probe_trig --full     16.3 million arguments, about 45 s
    probe_trig --bench    ns per call: new, round 11, the RTL's Sin, and the
                          fast path alone
    probe_trig --fail     corrupts one expectation, to see the check fail

  Build and run, either OS, from the repository root:
    fpc -B -Mobjfpc -Scghi -O2 -vewn -Fuengine -Fuengine/libs
        -FU<units dir> -FE<bin dir> tests/probe_trig.lpr
    <bin dir>/probe_trig --full
******************************************************************************}
program probe_trig;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}
{$Q-}{$R-}

uses
  SysUtils, Math, PhosphorNumLib;

{ ---------------- the oracle: round 11, verbatim but for the names --------- }
type
  TDD = record Hi, Lo: Double; end;

procedure OTwoSum(a, b: Double; out s, e: Double);
var bb: Double;
begin s := a + b; bb := s - a; e := (a - (s - bb)) + (b - bb); end;

procedure OTwoProd(a, b: Double; out p, e: Double);
var t, ah, al, bh, bl: Double;
begin
  p := a * b;
  t := 134217729.0 * a; ah := t - (t - a); al := a - ah;
  t := 134217729.0 * b; bh := t - (t - b); bl := b - bh;
  e := ((ah * bh - p) + ah * bl + al * bh) + al * bl;
end;

function ODD(h, l: Double): TDD;
begin Result.Hi := h; Result.Lo := l; end;

function ODDMul(const a, b: TDD): TDD;
var p, e: Double;
begin
  OTwoProd(a.Hi, b.Hi, p, e);
  e := e + (a.Hi * b.Lo + a.Lo * b.Hi);
  OTwoSum(p, e, Result.Hi, Result.Lo);
end;

function ODDAdd(const a, b: TDD): TDD;
var s, e: Double;
begin
  OTwoSum(a.Hi, b.Hi, s, e);
  e := e + (a.Lo + b.Lo);
  OTwoSum(s, e, Result.Hi, Result.Lo);
end;

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

function ORemPio2(x: Double; out r: TDD): Integer;
var
  bits, mant, t, carry, a1, a2: QWord;
  e, i0, i, k, p0, h, sh: Integer;
  a: array[0..7] of QWord;
  pr: array[0..10] of QWord;
  neg: Boolean;
  hi53, mid11, lo53: Int64;
  fh, fl, fm: Double;
  frac: TDD;

  function Bit(idx: Integer): QWord;
  begin
    if (idx < 0) or (idx > 351) then Exit(0);
    Result := (pr[idx shr 5] shr (idx and 31)) and 1;
  end;
  function Bits64(top: Integer): QWord;
  var j: Integer;
  begin
    Result := 0;
    for j := 0 to 63 do Result := (Result shl 1) or Bit(top - j);
  end;

begin
  bits := PQWord(@x)^ and QWord($7FFFFFFFFFFFFFFF);
  mant := (bits and QWord($000FFFFFFFFFFFFF)) or QWord($0010000000000000);
  e := Integer(bits shr 52) - 1075;
  if e >= 34 then i0 := (e - 34) div 32 + 1 else i0 := 0;
  for k := 0 to 7 do a[k] := TWO_OVER_PI[i0 + 7 - k];
  for k := 0 to 10 do pr[k] := 0;
  for i := 0 to 1 do
  begin
    if i = 0 then t := mant and $FFFFFFFF else t := mant shr 32;
    carry := 0;
    for k := 0 to 7 do
    begin
      carry := t * a[k] + pr[i + k] + carry;
      pr[i + k] := carry and $FFFFFFFF;
      carry := carry shr 32;
    end;
    pr[i + 8] := carry;
  end;
  p0 := 32 * (i0 + 8) - e;
  Result := Integer(Bit(p0) + 2 * Bit(p0 + 1));
  for k := p0 to 351 do
    if Bit(k) <> 0 then pr[k shr 5] := pr[k shr 5] and not (QWord(1) shl (k and 31));
  neg := Bit(p0 - 1) <> 0;
  if neg then
  begin
    Result := (Result + 1) and 3;
    carry := 1;
    for k := 0 to 10 do
    begin
      carry := (not pr[k] and $FFFFFFFF) + carry;
      pr[k] := carry and $FFFFFFFF;
      carry := carry shr 32;
    end;
    for k := p0 to 351 do
      if Bit(k) <> 0 then pr[k shr 5] := pr[k shr 5] and not (QWord(1) shl (k and 31));
  end;
  h := -1;
  for k := 351 downto 0 do
    if (h < 0) and (k < p0) and (Bit(k) <> 0) then h := k;
  if h < 0 then begin r := ODD(0, 0); Exit; end;
  a1 := Bits64(h);
  a2 := Bits64(h - 64);
  sh := h - p0;
  hi53 := Int64(a1 shr 11);
  mid11 := Int64(a1 and $7FF);
  lo53 := Int64(a2 shr 11);
  fh := hi53;
  fl := mid11;
  fm := lo53;
  fl := fl * 9007199254740992.0 + fm;
  fh := ldexp(fh, sh - 52);
  fl := ldexp(fl, sh - 116);
  OTwoSum(fh, fl, frac.Hi, frac.Lo);
  r := ODDMul(frac, ODD(PIO2_HI, PIO2_LO));
  if neg then begin r.Hi := -r.Hi; r.Lo := -r.Lo; end;
  if x < 0 then
  begin
    Result := (4 - Result) and 3;
    r.Hi := -r.Hi; r.Lo := -r.Lo;
  end;
end;

function ODDDivI(const a: TDD; di: Integer): TDD;
var q1, p, e, rem, d: Double;
begin
  d := di;
  q1 := a.Hi / d;
  OTwoProd(q1, d, p, e);
  rem := ((a.Hi - p) - e + a.Lo) / d;
  OTwoSum(q1, rem, Result.Hi, Result.Lo);
end;

{ The round-11 kernel, answering the double-double it rounds (Hi is what
  round 11 returned) so the probe can measure the fast path's error. }
function OKernelDD(const r: TDD; wantCos: Boolean): TDD;
var z, poly: TDD; k, j: Integer;
begin
  z := ODDMul(r, r);
  poly := ODD(1, 0);
  for k := 15 downto 1 do
  begin
    if wantCos then j := 2 * k - 1 else j := 2 * k;
    poly := ODDDivI(ODDMul(z, poly), j * (j + 1));
    poly := ODDAdd(ODD(1, 0), ODD(-poly.Hi, -poly.Lo));
  end;
  if wantCos then Result := poly else Result := ODDMul(r, poly);
end;

{ OSinCosD, with the double-double behind its answer in dd (Hi = Result when
  the answer came from the kernel; dd.Hi = 0 for the non-kernel exits). }
function OSinCosDD(x: Double; wantCos: Boolean; out dd: TDD): Double;
var r: TDD; q: Integer;
begin
  dd := ODD(0, 0);
  if IsNan(x) or IsInfinite(x) then
  begin
    if wantCos then Exit(Cos(x)) else Exit(Sin(x));
  end;
  if Abs(x) <= PIO4_D then
  begin
    if Abs(x) < 7.450580596923828125e-9 then
    begin
      if wantCos then Exit(1.0) else Exit(x);
    end;
    r := ODD(x, 0); q := 0;
  end
  else q := ORemPio2(x, r);
  if wantCos then q := (q + 1) and 3;
  case q of
    0: dd := OKernelDD(r, False);
    1: dd := OKernelDD(r, True);
    2: begin dd := OKernelDD(r, False); dd.Hi := -dd.Hi; dd.Lo := -dd.Lo; end;
  else begin dd := OKernelDD(r, True); dd.Hi := -dd.Hi; dd.Lo := -dd.Lo; end;
  end;
  Result := dd.Hi;
end;

function OSinCosD(x: Double; wantCos: Boolean): Double;
var dd: TDD;
begin Result := OSinCosDD(x, wantCos, dd); end;

{ ---------------- the sweep ---------------- }
{$I probe_trig_hard.inc}

var
  Ok, Fails, Args, RedChecked, FastTried, FastDecided: Int64;
  MaxErr: Double;
  Corrupt: Boolean;
  Seed: QWord;
  Mode: String;

function Next64: QWord;                       // splitmix64
var z: QWord;
begin
  Seed := Seed + QWord($9E3779B97F4A7C15);
  z := Seed;
  z := (z xor (z shr 30)) * QWord($BF58476D1CE4E5B9);
  z := (z xor (z shr 27)) * QWord($94D049BB133111EB);
  Result := z xor (z shr 31);
end;

function BitsOf(d: Double): QWord; inline;
begin Result := PQWord(@d)^; end;
function FromBits(q: QWord): Double; inline;
begin Result := PDouble(@q)^; end;

procedure Fail(const What: String; x: Double; got, want: QWord);
begin
  Inc(Fails);
  if Fails <= 20 then
    WriteLn(StdErr, Format('FAIL: %s x=%s ($%.16x) got $%.16x want $%.16x',
      [What, FloatToStr(x), BitsOf(x), got, want]));
end;

procedure Check(x: Double);
var
  wc: Boolean; got, want: Double; dd: TDD;
  q1, q2: Integer; h1, l1: Double; r2: TDD;
  yh, yl, err: Double;
  g, w: String;
begin
  Inc(Args);
  if IsNan(x) or IsInfinite(x) then
  begin
    // the RTL path, both sides: same bits, or the same exception
    for wc := False to True do
    begin
      try got := SinCosD(x, wc); g := '$' + IntToHex(BitsOf(got), 16);
      except on ex: Exception do g := ex.ClassName; end;
      try want := OSinCosD(x, wc); w := '$' + IntToHex(BitsOf(want), 16);
      except on ex: Exception do w := ex.ClassName; end;
      if g <> w then
      begin
        Inc(Fails);
        WriteLn(StdErr, 'FAIL: non-finite x=', FloatToStr(x), ' got ', g, ' want ', w);
      end
      else Inc(Ok);
      if Mode = 'nonfinite' then WriteLn('  ', BoolToStr(wc, 'cos', 'sin'), '(', FloatToStr(x), '): ', g);
    end;
    Exit;
  end;
  for wc := False to True do
  begin
    got := SinCosD(x, wc);
    want := OSinCosDD(x, wc, dd);
    if Corrupt and (Args = 1000) and not wc then
      want := FromBits(BitsOf(want) xor 1);
    if BitsOf(got) <> BitsOf(want) then
    begin
      if wc then Fail('cos', x, BitsOf(got), BitsOf(want))
      else Fail('sin', x, BitsOf(got), BitsOf(want));
    end
    else Inc(Ok);
    // the error the fast path actually reaches, against the oracle's
    // double-double (about 2^-100 from the truth)
    if (not IsNan(x)) and (not IsInfinite(x)) and
       (Abs(x) >= 7.450580596923828125e-9) then
    begin
      Inc(FastTried);
      if SinCosFast(x, wc, yh, yl) then Inc(FastDecided);
      err := Abs((yh - dd.Hi) + (yl - dd.Lo)) / Abs(dd.Hi);
      if err > MaxErr then MaxErr := err;
    end;
  end;
  if (not IsNan(x)) and (not IsInfinite(x)) and (Abs(x) > PIO4_D) then
  begin
    Inc(RedChecked);
    q1 := RemPio2Parts(x, h1, l1);
    q2 := ORemPio2(x, r2);
    if (q1 <> q2) or (BitsOf(h1) <> BitsOf(r2.Hi)) or (BitsOf(l1) <> BitsOf(r2.Lo)) then
      Fail('reduction', x, BitsOf(h1), BitsOf(r2.Hi))
    else Inc(Ok);
  end;
end;

procedure Both(x: Double);
begin Check(x); Check(-x); end;

procedure Around(x: Double; ulps: Integer);   // x and its ulps neighbours, both signs
var b: QWord; j: Integer;
begin
  b := BitsOf(Abs(x));
  for j := -ulps to ulps do
    if (Int64(b) + j >= 0) and (Int64(b) + j < Int64($7FF0000000000000)) then
      Both(FromBits(QWord(Int64(b) + j)));
end;

procedure Pin(x, want: Double; wantCos: Boolean; const What: String);
begin
  if BitsOf(OSinCosD(x, wantCos)) <> BitsOf(want) then
    Fail('oracle copy ' + What, x, BitsOf(OSinCosD(x, wantCos)), BitsOf(want))
  else Inc(Ok);
end;

procedure Sweep(Mul: Integer);
var
  E, w: Integer; i, k, n: Int64; x: Double; b: QWord;
begin
  // every binade, random mantissas
  for E := 0 to 2046 do
    for i := 1 to 40 * Mul do
    begin
      b := (QWord(E) shl 52) or (Next64 and QWord($000FFFFFFFFFFFFF));
      Both(FromBits(b));
    end;
  // the binades the fast path serves: 2^-27 .. 2^21
  for E := 1023 - 27 to 1023 + 21 do
    for i := 1 to 2000 * Mul do
    begin
      b := (QWord(E) shl 52) or (Next64 and QWord($000FFFFFFFFFFFFF));
      Both(FromBits(b));
    end;
  // within 8 ulps of k*pi/4
  n := 4096 * Mul; if n > 65536 then n := 65536;
  for k := 1 to n do Around(k * PIO4_D, 8);
  for i := 1 to 2000 * Mul do
  begin
    k := 1 + Int64(Next64 mod QWord(1 shl 23));
    Around(k * PIO4_D, 8);
  end;
  // the thresholds
  if Mul > 1 then w := 2000 else w := 500;
  Around(7.450580596923828125e-9, w);
  Around(PIO4_D, w);
  Around(1572864.0, w);
  // where the kernel's table index changes, (2j+1)/128
  for k := 0 to 50 do Around((2 * k + 1) / 128.0, w div 8);
  // the hardest to reduce, per binade
  if Mul > 1 then w := 32 else w := 8;
  for i := 0 to HARD_N - 1 do Around(FromBits(HARD[i]), w);
  // the edges of the format
  x := 0.0; Both(x);
  WriteLn('non-finite arguments (the RTL answers, unchanged):');
  Mode := 'nonfinite';
  Both(Infinity); Both(NaN);
  Mode := '';
  Both(FromBits(1)); Both(FromBits($000FFFFFFFFFFFFF));
  Both(FromBits($0010000000000000)); Both(FromBits($7FEFFFFFFFFFFFFF));
end;

procedure Bench;
const
  NCALL = 40000000;
  NAMES: array[0..2] of String = ('small    (0.1 .. pi/4)', 'moderate (1 .. 1e6)   ',
    'huge     (1e10 .. 1e300)');
var
  xs: array of Double;
  cls, j: Integer;
  t0: QWord; acc: Double;

  procedure Fill(c: Integer);
  var k: Integer;
  begin
    for k := 0 to High(xs) do
      case c of
        0: xs[k] := 0.1 + (PIO4_D - 0.1) * ((Next64 shr 11) / 9007199254740992.0);
        1: xs[k] := Power(10, 6 * ((Next64 shr 11) / 9007199254740992.0));
      else xs[k] := Power(10, 10 + 290 * ((Next64 shr 11) / 9007199254740992.0));
      end;
  end;
  function Run(which, reps: Integer): Double;
  var r, k: Integer; yh, yl: Double;
  begin
    acc := 0;
    t0 := GetTickCount64;
    for r := 1 to reps do
      for k := 0 to High(xs) do
        case which of
          0: acc := acc + SinCosD(xs[k], False);
          1: acc := acc + OSinCosD(xs[k], False);
          3: begin SinCosFast(xs[k], False, yh, yl); acc := acc + yh; end;
        else acc := acc + Sin(xs[k]);
        end;
    Result := (GetTickCount64 - t0) * 1e6 / (reps * Length(xs));
  end;

begin
  SetLength(xs, 4096);
  WriteLn('ns per sin call             new   round 11   RTL Sin  SinCosFast alone');
  for cls := 0 to 2 do
  begin
    Fill(cls);
    j := NCALL div Length(xs);
    Write(NAMES[cls], Format('  %7.1f', [Run(0, j)]));
    Write(Format('  %8.1f', [Run(1, j div 20)]));
    WriteLn(Format('  %8.1f  %8.1f', [Run(2, j), Run(3, j)]));
  end;
  if acc = 12345 then WriteLn;               // keeps the sums alive
end;

var
  Mul, a: Integer;
begin
  DefaultFormatSettings.DecimalSeparator := '.';
  Mul := 1; Corrupt := False;
  for a := 1 to ParamCount do
    if ParamStr(a) = '--full' then Mul := 32
    else if ParamStr(a) = '--fail' then Corrupt := True
    else if ParamStr(a) = '--bench' then begin Seed := 7; Bench; Halt(0); end
    else begin WriteLn(StdErr, 'probe_trig: unknown argument ', ParamStr(a)); Halt(2); end;
  Seed := 20261012;
  Ok := 0; Fails := 0; Args := 0; RedChecked := 0; MaxErr := 0;
  FastTried := 0; FastDecided := 0;
  // the oracle copy is the code that pinned these (104_trig_log_round11.bas)
  // (by bit pattern: an FPC float literal is read as an Extended on Linux)
  Pin(1e22, FromBits(QWord($BFEB453AB76BF397)), False, 'sin(1e22)');
  Pin(FromBits($7506AC5B262CA1FF), FromBits(QWord($BC214AE72E6BA22F)), True,
    'cos(6381956970095103*2^797)');
  Pin(355, FromBits(QWord($BEFF9BD0307D1DE3)), False, 'sin(355)');
  Pin(0.5, FromBits($3FEC1528065B7D50), True, 'cos(0.5)');
  Sweep(Mul);
  WriteLn(Format('arguments: %d (each sin and cos); reductions compared: %d', [Args, RedChecked]));
  WriteLn(Format('fast path: decided %d of %d calls, fell back on %.4f%%; max error %.3g = 2^%.1f (it assumes 2^-64)',
    [FastDecided, FastTried, 100.0 * (FastTried - FastDecided) / Max(FastTried, 1), MaxErr,
     Log2(Max(MaxErr, 1e-300))]));
  if MaxErr * 4 > 2.168404344971008868e-19 then
  begin
    Inc(Fails);
    WriteLn(StdErr, 'FAIL: the measured error is not a quarter of the bound the fast path uses');
  end;
  WriteLn('mismatches: ', Fails);
  WriteLn('ok: ', Ok);
  WriteLn('fail: ', Fails);
  if Fails > 0 then Halt(1);
end.
