{******************************************************************************
  Phosphor BASIC -- string library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  Case, length, slicing, trimming, search, replace, radix, conversion, padding,
  words, predicates -- plus the helpers behind the string index sugar s$[n]
  (line, base-1) and s$[[n]] (character, base-1 by CODEPOINT). Character-level
  operations (len, left$/right$, reverse$, s$[[n]], asc) count Unicode
  codepoints, not bytes, honouring decisions.md. instr/pos are 1-based and 0
  when absent (base 1 everywhere). Errors are RETURNED, never raised.
******************************************************************************}
unit PhosphorStrLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, StrUtils, Types, Character,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorBudget;

procedure RegisterStrFuncs(Reg: TPhosphorRegistry);

implementation

var
  InvFS: TFormatSettings;
  GValCode: Integer;   // set by val(), read by valcode(): 0 clean, else stop position

// --- UTF-8 codepoint helpers ------------------------------------------------
{ THE TABLE ITSELF NOW LIVES IN PhosphorValue, and these four names are what
  this unit calls it. It moved because it was never only this unit's: the
  `string - n` operator (PhosphorValue) and PRINT USING's string fields
  (PhosphorVM) mean characters too, and each had grown its own byte-based
  version that split UTF-8 sequences. One table, one definition of where a
  character starts, three callers -- see the header over Utf8Starts. }
function CpStarts(const S: String): TInt64DynArray; inline;
begin
  Result := Utf8Starts(S);
end;

function CpLen(const S: String): Integer; inline;
begin
  Result := Utf8Len(S);
end;

function CpAt(const S: String; AOneBased: Integer): String;
var st: TInt64DynArray;
begin
  Result := '';
  st := CpStarts(S);
  if (AOneBased >= 1) and (AOneBased <= Length(st) - 1) then
    Result := Copy(S, st[AOneBased - 1], st[AOneBased] - st[AOneBased - 1]);
end;

function CpLeft(const S: String; ACount: Integer): String; inline;
begin
  Result := Utf8Left(S, ACount);
end;

function CpRight(const S: String; ACount: Integer): String; inline;
begin
  Result := Utf8Right(S, ACount);
end;

{ QUADRATIC APPEND, charged. `Result := Result + Copy(...)` in a loop is not an
  O(1) body, so Length(S) does not bound this the way it bounds a plain scan:
  unbudgeted, reverse$ of a 160 MB string took 50750 ms under a 2000 ms ceiling
  and reported success. The cost is fixed by Length(S) before the loop starts, so
  it is RULE 1 -- priced once, refused whole, never truncated half way. False here
  means the budget said no; the caller turns that into the peLimit. }
function CpReverse(const S: String; out AAllowed: Boolean): String;
var st: TInt64DynArray; i, n: Integer;
begin
  Result := '';
  AAllowed := BudgetAllows(Int64(Length(S)) * BudgetUnitsPerAppendedByte);
  if not AAllowed then Exit;
  st := CpStarts(S);
  n := Length(st) - 1;
  for i := n downto 1 do
    Result := Result + Copy(S, st[i - 1], st[i] - st[i - 1]);
end;

// --- string splitting -------------------------------------------------------
function SplitBy(const S, Sep: String): TStringArray;
var start, i, n: Integer;
begin
  Result := nil;
  SetLength(Result, 0);
  if Sep = '' then
  begin
    SetLength(Result, 1); Result[0] := S; Exit;
  end;
  n := 0;
  start := 1;
  i := PosEx(Sep, S, start);
  while i > 0 do
  begin
    SetLength(Result, n + 1);
    Result[n] := Copy(S, start, i - start);
    Inc(n);
    start := i + Length(Sep);
    i := PosEx(Sep, S, start);
  end;
  SetLength(Result, n + 1);
  Result[n] := Copy(S, start, MaxInt);
end;

function SplitLines(const S: String): TStringArray;
var i: Integer;
begin
  Result := SplitBy(S, #10);
  for i := 0 to High(Result) do
    if (Length(Result[i]) > 0) and (Result[i][Length(Result[i])] = #13) then
      SetLength(Result[i], Length(Result[i]) - 1);
end;

// --- library functions ------------------------------------------------------
function s0(const Args: array of TValue): String; begin Result := Args[0].Str; end;

function f_ucase(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(UpperCase(s0(A))); end;
function f_lcase(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(LowerCase(s0(A))); end;
function f_len(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(CpLen(s0(A))); end;
function f_left(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(CpLeft(s0(A), ArgI32(A[1]))); end;
function f_right(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(CpRight(s0(A), ArgI32(A[1]))); end;
function f_trim(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(Trim(s0(A))); end;
function f_ltrim(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(TrimLeft(s0(A))); end;
function f_rtrim(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(TrimRight(s0(A))); end;
function f_reverse(const A: array of TValue; out E: TPhosphorError): TValue;
var r: String; ok: Boolean;
begin
  E := NoError();
  r := CpReverse(s0(A), ok);
  if not ok then begin E := BudgetRefusal('reverse$'); Exit(ValStr('')); end;
  Result := ValStr(r);
end;

// mid$(s, start[, len]) -- 1-based, by codepoint. Without len, to the end.
function f_mid(const A: array of TValue; out E: TPhosphorError): TValue;
var st: TInt64DynArray; startCp, cnt, lastEx, n: Integer;
begin
  E := NoError();
  st := CpStarts(s0(A));
  n := Length(st) - 1;
  startCp := ArgI32(A[1]);
  if High(A) >= 2 then cnt := ArgI32(A[2]) else cnt := n;
  if startCp < 1 then startCp := 1;
  if cnt < 0 then cnt := 0;
  if startCp > n then Exit(ValStr(''));
  // Clamp the COUNT before adding it. Saturating arguments stop the conversion from
  // raising, but `startCp + cnt` is still Integer arithmetic: mid$("hello", 1,
  // 2147483647) wrapped the sum to -2147483648, sailed past the `> n + 1` guard
  // below, and indexed the codepoint table at a negative offset -- an access
  // violation. No count beyond the string's length can mean anything anyway.
  if cnt > n then cnt := n;
  lastEx := startCp + cnt;                 // one past the last codepoint
  if lastEx > n + 1 then lastEx := n + 1;
  Result := ValStr(Copy(s0(A), st[startCp - 1], st[lastEx - 1] - st[startCp - 1]));
end;

function f_asc(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String;
begin
  E := NoError();
  s := CpAt(s0(A), 1);
  if s = '' then Result := ValInt(0)
  else if Ord(s[1]) < $80 then Result := ValInt(Ord(s[1]))
  else
  begin
    // decode the leading UTF-8 codepoint
    if (Ord(s[1]) >= $F0) and (Length(s) >= 4) then
      Result := ValInt(((Ord(s[1]) and $07) shl 18) or ((Ord(s[2]) and $3F) shl 12) or ((Ord(s[3]) and $3F) shl 6) or (Ord(s[4]) and $3F))
    else if (Ord(s[1]) >= $E0) and (Length(s) >= 3) then
      Result := ValInt(((Ord(s[1]) and $0F) shl 12) or ((Ord(s[2]) and $3F) shl 6) or (Ord(s[3]) and $3F))
    else if (Ord(s[1]) >= $C0) and (Length(s) >= 2) then
      Result := ValInt(((Ord(s[1]) and $1F) shl 6) or (Ord(s[2]) and $3F))
    else
      Result := ValInt(Ord(s[1]));
  end;
end;

{ THE ENCODER IS PhosphorValue's Utf8Char, AND THERE IS NOW ONLY ONE OF IT.

  This unit used to carry two copies -- CpUtf8 here for chr$/string$, and
  Utf8Chr further down for the pad family and the case functions -- identical
  except that only this one clamped a negative code. So the two doors disagreed
  on the same argument:

    chr$(-1)                 -> byte 00        (clamped here)
    lfill$("x", 3, -1)       -> FF FF 78       (not clamped there)

  and 0xFF cannot occur in UTF-8. Neither copy clamped the TOP, which is the
  defect proper: see the header over Utf8Char. One encoder cannot disagree with
  itself. }
function f_chr(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  E := NoError();
  Result := ValStr(Utf8Char(ArgI32(A[0])));
end;

function ToRadix(V: Int64; Base: Integer): String;
const digits = '0123456789ABCDEF';
var neg: Boolean; m: QWord; buf: array[0..64] of Char; n: Integer;
begin
  if V = 0 then Exit('0');
  neg := V < 0;
  // The MAGNITUDE is taken in QWord. `V := -V` cannot represent the negation of
  // Low(Int64), so the loop below never ran for it and hex$ returned a bare "-"
  // -- a minus sign with no digits, reported as a clean success.
  if neg then m := QWord(-(V + 1)) + 1 else m := QWord(V);
  n := 0;
  while m > 0 do
  begin
    buf[n] := digits[(m mod QWord(Base)) + 1];
    Inc(n);
    m := m div QWord(Base);
  end;
  // Filled back to front into a sized string: no Char is concatenated (see
  // scripts/check-codepage.py) and no string is rebuilt once per digit.
  if neg then
  begin
    SetLength(Result, n + 1);
    Result[1] := '-';
    while n > 0 do begin Result[Length(Result) - n + 1] := buf[n - 1]; Dec(n); end;
  end
  else
  begin
    SetLength(Result, n);
    while n > 0 do begin Result[Length(Result) - n + 1] := buf[n - 1]; Dec(n); end;
  end;
end;

function f_hex(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(ToRadix(ArgI64(A[0]), 16)); end;
function f_bin(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(ToRadix(ArgI64(A[0]), 2)); end;
function f_oct(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(ToRadix(ArgI64(A[0]), 8)); end;

function f_val(const A: array of TValue; out E: TPhosphorError): TValue;
var d: Double; code: Integer; s: String;
begin
  E := NoError();
  s := Trim(s0(A));
  Val(s, d, code);      // Pascal Val: code = 0 on success, else 1-based stop position
  GValCode := code;
  if TryStrToFloat(s, d, InvFS) then Result := ValDouble(d) else Result := ValDouble(0);
end;
function f_stri(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(FloatToStr(AsDouble(A[0]), InvFS)); end;

{ AN int% KEEPS ITS DIGITS, and the registry is what makes that possible.

  str$/stri$ were registered as ':n' only, so an int% argument bound the numeric
  slot BY WIDENING and the value went through a Double before it was ever
  formatted. Two losses followed, both silent:

    id% = 1000000000000001 : println str$(id%)    ->  1E15
    row% = 1234567890123456789 : println str$(row%) -> 1.23456789012346E18

  FloatToStr's 15-significant-digit default switches to exponential notation at
  10^15, and above 2^53 the Double has already dropped the low digits. Meanwhile
  `println id%` printed all sixteen digits (ValToStr uses IntToStr for vkInt) and
  hex$ was exact too (ArgI64 short-circuits on vkInt) -- so the engine had the
  right primitive and the DOCUMENTED number-to-text idiom was the one path that
  did not use it. A row id or a nanosecond timestamp written through str$ into a
  CSV cannot be recovered from "1E15".

  This is not the documented widening trade-off of decisions.md:176: that says an
  int% MAY bind an 'n' slot, not that it must when an exact slot exists. Adding
  the ':%' overload is the mechanism the registry was built for -- Resolve
  prefers the fewest widenings, so a vkInt now lands here and a vkDouble still
  lands on ':n' unchanged. }
function f_striInt(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(IntToStr(A[0].Int)); end;

{ THE THREE STRING BUILDERS, and the two things that were wrong with them.

  (1) THE LOOP. space$ and string$ produce the same shape of answer and only
  space$ was fast: it calls StringOfChar once, while string$ and mulstring$
  appended one piece at a time. An append reallocates, so building n characters
  cost O(n^2) work -- string$(1e18) becomes string$(2147483647) under ArgI32's
  saturating clamp and then ran for HOURS, with no ceiling able to look at it,
  because the whole loop lives inside one opCall. Both now size the answer once
  and fill it, which is what StringOfChar was already doing for their sibling:
  the answer is identical and the cost is linear.

  (2) THE SIZE. The result's length is n * Length(piece) and both are in hand
  before a byte is allocated, so this is exactly the case RULE 1 of
  PhosphorBudget is for -- under a host's budget the operation is refused up
  front rather than started. With no budget installed BudgetAllows answers True
  on its first line and these behave as they always did, only faster. }
function f_space(const A: array of TValue; out E: TPhosphorError): TValue;
var n: Integer;
begin
  E := NoError();
  n := ArgI32(A[0]); if n < 0 then n := 0;
  if not BudgetAllows(n) then begin E := BudgetRefusal('space$'); Exit(ValStr('')); end;
  Result := ValStr(StringOfChar(' ', n));
end;
function f_string(const A: array of TValue; out E: TPhosphorError): TValue;
var n, i, cl: Integer; total: Int64; ch, r: String;
begin
  E := NoError();
  n := ArgI32(A[0]); if n < 0 then n := 0;
  ch := Utf8Char(ArgI32(A[1]));   // the character's full UTF-8 encoding
  cl := Length(ch);
  total := Int64(n) * cl;
  { SIZING ONCE MEANS THE SIZE HAS TO FIT. n saturates at High(Integer) and a
    codepoint is up to four bytes, so the product reaches 8.6e9 -- a perfectly
    good Int64 and NOT a good SizeInt on a 32-bit build, where SetLength would
    take the wrapped value and hand back a block the string header still claims
    is huge. That is the dim@ defect exactly, and it costs nothing to not have.

    Compiled only where it can be true: on 64-bit High(SizeInt) is High(Int64),
    the comparison is constant-false, and -vewn refuses the unreachable branch
    that results. There an over-large allocation still fails the honest way, with
    EOutOfMemory reported through the VM's net. }
  {$IFDEF CPU32}
  if total > High(SizeInt) then
  begin
    E := MakeError(peRuntime, 'string$: ' + IntToStr(total) +
                   ' bytes is past the longest string this build can hold');
    Exit(ValStr(''));
  end;
  {$ENDIF}
  if not BudgetAllows(total) then begin E := BudgetRefusal('string$'); Exit(ValStr('')); end;
  r := '';
  SetLength(r, total);
  if total > 0 then
    if cl = 1 then
      FillChar(r[1], total, Byte(ch[1]))
    else
      for i := 0 to n - 1 do Move(ch[1], r[Int64(i) * cl + 1], cl);
  Result := ValStr(r);
end;
function f_mulstring(const A: array of TValue; out E: TPhosphorError): TValue;
var n, i, sl: Integer; total: Int64; s, r: String;
begin
  E := NoError();
  n := ArgI32(A[1]); if n < 0 then n := 0;
  s := s0(A); sl := Length(s);
  total := Int64(n) * sl;
  {$IFDEF CPU32}                        // the same SizeInt ceiling as string$
  if total > High(SizeInt) then
  begin
    E := MakeError(peRuntime, 'mulstring$: ' + IntToStr(total) +
                   ' bytes is past the longest string this build can hold');
    Exit(ValStr(''));
  end;
  {$ENDIF}
  if not BudgetAllows(total) then begin E := BudgetRefusal('mulstring$'); Exit(ValStr('')); end;
  r := '';
  SetLength(r, total);
  if total > 0 then
    for i := 0 to n - 1 do Move(s[1], r[Int64(i) * sl + 1], sl);
  Result := ValStr(r);
end;

{ THE STRING PRODUCTS, and the reason the gate could not see them.

  scripts/check-budget.py deliberately does NOT taint a String argument: a string
  is already in memory, so its Length bounds a loop exactly as a container's
  Count does. That is sound for ONE string and wrong for the PRODUCT of two, and
  every routine below multiplies two of them:

    - a naive search compares the needle against the haystack at every offset,
      which is Length(hay) * Length(needle) byte comparisons. FPC's Pos/PosEx are
      naive (rtl/objpas/sysutils/syspch.inc and the generic sysstr.inc: a scan
      for the first byte and then a compare loop, no Boyer-Moore), so

          h$ = string$(1000000, 97) : nd$ = string$(20000, 97) + "b"
          println instr(h$, nd$)          ' 7250 ms, and it SUCCEEDED

      spent seven seconds inside one opCall under a two-second time limit.

    - a replace BUILDS a result whose length is Length(hay) + count * (new - old),
      and with a one-character needle count is Length(hay). So

          replacestr$(string$(1000000,97), "a", string$(2000,98))

      is two gigabytes from three arguments that are a megabyte between them --
      422 ms and rc=0 under the ceiling that refuses a one-gigabyte buffer.

  SearchCost prices the search, ReplaceCost prices the search AND the answer, and
  each is asked before the RTL is called.

  ROUND THREE -- WHY THE PRICE IS NO LONGER Length(hay) * Length(needle).

  Round two charged the true worst case, on the reasoning that a ceiling has to
  be priced against a worst case. That reasoning is right about the ANSWER's size
  and wrong about the SEARCH's time, and it broke a band of entirely ordinary
  work. My reviewer swept document size against needle length and measured:

      doc=100000   needle=4096   REFUSED       doc=1000000  needle=32  REFUSED
      doc=10000000 needle=8      REFUSED       ("319999008 units of work and
                                                 only 95358608 are left")
      ALL 27 SEARCHES, UNBUDGETED, TOGETHER:   62 ms

  19 of 27 refused for 62 ms of work. Concretely: finding a 300-character
  quotation in a 990 KB document was refused on instr, countstr AND replacestr$
  under exactly the ceilings docs/embedding.md prescribes.

  The worst case Length(hay)*Length(needle) needs a haystack whose EVERY position
  starts with the needle's first byte. Ordinary text never does, and the reason
  it never does is visible in the RTL. FPC's Pos/PosEx (rtl/inc/astrings.inc,
  read rather than assumed) is a first-byte scan with a CompareByte only where
  that first byte matches:

      while (i <= MaxLen) do begin
        inc(i);
        if (SubStr[1] = pc^) and (CompareByte(Substr[1], pc^, SubLen) = 0) then ...
        inc(pc);
      end;

  So the work is Length(hay) first-byte tests, plus at most one full needle
  comparison per position at which the needle's first byte actually occurs. That
  count is not a guess and not a sample: it is read off the haystack in one pass,
  the same order as the search's own floor. Hence

      cost = Length(hay) + hits(hay, needle[1]) * Length(needle)

  This is still an UPPER bound -- CompareByte stops at its first mismatch, so the
  real search is cheaper -- and it still refuses the amplifier round one found:
  instr(string$(1000000,97), string$(20000,97)+"b") has its first byte at every
  one of a million positions, prices at 1.96e10, and is refused, while the same
  shapes over ordinary text price at Length(hay) plus a few percent.

  TWO THINGS THIS COSTS, both deliberate:

    - The counting pass is itself a pass over the haystack, so it is CHARGED
      before it is made. A refusal charges nothing (BudgetAllows says why), so
      without that charge a loop of refused searches would buy an unbounded
      number of free scans of a large string -- a hole this change would have
      opened while closing another.

    - With NO budget installed the price is never consulted, so it is not
      computed either: SearchCost answers 0 and does not scan. An unbudgeted
      host is exactly as fast as it was before this unit existed. }

{ One naive search, priced by the measured model in PhosphorBudget -- shared
  with PhosphorBufferLib's hand-written search so the two doors cannot drift. }
function SearchCost(const AHay, ANeedle: String; ACaseless: Boolean = False): Int64;
begin
  Result := BudgetSearchCost(AHay, ANeedle, ACaseless);
end;

{ Worst-case work for replacing every ANeedle in AHay by ANew: the searches, plus
  the largest answer that can come out of it. }
function ReplaceCost(const AHay, ANeedle, ANew: String;
                     ACaseless: Boolean = False): Int64;
var hits, grow, outlen: Int64;
begin
  Result := SearchCost(AHay, ANeedle, ACaseless);
  if ANeedle = '' then Exit;                       // the RTL answers AHay unchanged
  hits := Int64(Length(AHay)) div Int64(Length(ANeedle));
  grow := Int64(Length(ANew)) - Int64(Length(ANeedle));
  if grow < 0 then grow := 0;
  if (grow > 0) and (hits > (High(Int64) - Int64(Length(AHay))) div grow) then
    outlen := High(Int64)
  else
    outlen := Int64(Length(AHay)) + hits * grow;
  if outlen > Result then Result := outlen;
end;

{ AND THE ANSWER HAS TO FIT A 32-BIT COUNTER. The RTL sizes the result with
  `SetLength(Result, Length(S) + aCount * (NewPatLength - PatLength))` where
  aCount and both lengths are Integer (rtl/objpas/sysutils/syssr.inc, read to be
  sure rather than assumed), so a product past High(Integer) wraps NEGATIVE and
  SetLength is handed a nonsense length. That is a size the budget must not be
  the only thing standing in front of, because an unbudgeted host has no budget:
  it is refused as a catchable overflow whether or not a ceiling is installed. }
function ReplaceFitsRtl(const AHay, ANeedle, ANew: String; out AOut: Int64): Boolean;
var hits, delta: Int64;
begin
  AOut := Length(AHay);
  Result := True;
  if ANeedle = '' then Exit;
  hits := Int64(Length(AHay)) div Int64(Length(ANeedle));
  delta := Int64(Length(ANew)) - Int64(Length(ANeedle));
  if delta <= 0 then Exit;
  if hits > High(Int64) div delta then begin AOut := High(Int64); Exit(False); end;
  AOut := Int64(Length(AHay)) + hits * delta;
  Result := (hits * delta <= High(Integer)) and (AOut <= High(Integer));
end;

{ THE ONE CASE RULE FOR THE "ignoring case" FAMILY -- containstext, startstext,
  endstext, strcmpi and replacetext$ -- written down here because it used to be
  two rules, and they disagreed.

  str.md defines all five by reference to a case-sensitive twin ("as containsstr,
  ignoring case", and so on) and puts no ASCII restriction on any of them, the way
  it deliberately does state one for ucase$/lcase$. They were nevertheless folded
  by two incompatible engines. startstext/endstext/strcmpi went through
  SysUtils.SameText and CompareText, whose table maps a..z and nothing else --
  rtl/objpas/sysutils/sysstr.inc reads, literally, `if Chr1 in [97..122] then
  dec(Chr1,32)`. containstext (StrUtils.ContainsText) and replacetext$
  (StringReplace with rfIgnoreCase) went through AnsiUpperCase, which is
  `widestringmanager.UpperAnsiStringProc` (sysstr.inc:552-555) -- a hook the HOST
  PLATFORM installs. So an E-acute word CONTAINED its own lower-case spelling and
  did not START with it: 313 of the 3152 cased codepoints in 128..66000 got
  opposite verdicts from the two halves, the first six of them a-grave through
  a-ring. And the folding half was not the same function on Windows as on Linux,
  where nothing installs a Unicode-capable manager unless a program asks for
  cwstring -- so the same script did not have to answer the same on the two
  operating systems this project ships on.

  ONE RULE NOW, AND IT IS THE ONE THIS UNIT ALREADY OWNS: Utf8CaseU, the
  aucase$/alcase$ engine, reached through FoldText below. There is no second
  implementation -- the family folds by calling the very function aucase$ calls.
  Its mapping is TCharacter.ToUpper, which reads GetProps out of the RTL's
  compiled-in `unicodedata` tables (rtl/objpas/character.pas:832-837): no
  widestring manager, no OS call, no locale. That is why the two operating
  systems answer identically, and a probe that folded all 65536 BMP codepoints
  and checksummed the result was run on both to confirm it rather than assume it.

  WHY THE BYTE TESTS BELOW ARE SOUND ON THE FOLDED FORMS. Utf8CaseU emits exactly
  one codepoint per input codepoint and its output is well-formed UTF-8; UTF-8 is
  self-synchronising, so a valid sequence can only be found at a character
  boundary. A prefix, suffix or substring test on the folded BYTES therefore says
  exactly what the same test on the folded CHARACTERS would say.

  WHAT IT COSTS. An uppercased copy of each operand -- which containstext and
  replacetext$ were already paying inside the RTL, on both operands, for every
  call. It is charged to the budget inside Utf8CaseU, and a refusal is the
  ordinary peLimit these functions already carry for their search cost. }
function FoldText(const S: String; out AAllowed: Boolean): String; forward;

{ One codepoint forward from a byte position in a well-formed UTF-8 string:
  step off the lead byte, then over its continuation bytes. Bounded by
  Length(S), which is already in memory. }
function NextCp(const S: String; APos: Integer): Integer;
begin
  Result := APos + 1;
  while (Result <= Length(S)) and ((Ord(S[Result]) and $C0) = $80) do Inc(Result);
end;

{ AND FOLD ONLY WHAT CAN DECIDE THE QUESTION. startstext, endstext and strcmpi
  used to answer in a handful of byte comparisons; folding both operands whole to
  give them one case rule measured 57 s where the old code took 0.055 s, on
  `startstext(32-MB string, "AAAAA")`, and 28 s for the matching strcmpi. That is
  not slowness, it is a refusal under any TimeoutMs a host installs -- the very
  class of damage this patch exists to remove.

  Only as much of the text as the NEEDLE is long can decide a prefix or a suffix
  test, and only as much as the SHORTER operand can decide an ordering, because
  the fold emits exactly one codepoint per input codepoint. These two walk to
  that boundary and no further. Neither allocates, and the pad family's CpLeft is
  not used for it: that one builds an Int64 per input BYTE, which is the wrong
  price for a needle-sized question.

  CpWalk: how many codepoints S holds, counted no further than ALimit, and in
  AEnd the byte position one past them. }
procedure CpWalk(const S: String; ALimit: Integer; out ACount, AEnd: Integer);
var p, n: Integer;
begin
  { The LOOP is bounded by the string, and the limit only cuts it shorter: that
    is why the limit is tested inside and not in the `while`. Written the other
    way round -- a condition naming a count that came from the program -- it
    reads to check-budget.py as a loop over a script-supplied quantity, which is
    exactly the shape that check exists to stop, and it could not tell the two
    apart from the outside. }
  p := 1;
  n := 0;
  while p <= Length(S) do
  begin
    if n >= ALimit then Break;
    p := NextCp(S, p);
    Inc(n);
  end;
  ACount := n;
  AEnd := p;
end;

{ CpSuffixStart: the byte position at which the last ACount codepoints of S
  begin -- the backward twin, so endstext costs the needle and not the text.
  Answers 1 when S is shorter than ACount characters. }
function CpSuffixStart(const S: String; ACount: Integer): Integer;
var n, p: Integer;
begin
  p := Length(S) + 1;
  n := 0;
  while p > 1 do                     // bounded by the string; see CpWalk
  begin
    if n >= ACount then Break;
    Dec(p);
    while (p > 1) and ((Ord(S[p]) and $C0) = $80) do Dec(p);
    Inc(n);
  end;
  Result := p;
end;

function DoReplace(const A: array of TValue; const AFn: String; AIgnoreCase: Boolean;
                   out E: TPhosphorError): TValue;
var
  outlen: Int64;
  hay, needle, fh, fn, r: String;
  ok, ok2: Boolean;
  fp, target, fcur, hcur, seg: Integer;
begin
  E := NoError();
  hay := s0(A); needle := A[1].Str;
  fh := hay; fn := needle;
  if AIgnoreCase then
  begin
    { replacetext$ cannot just hand rfIgnoreCase to StringReplace any more: that
      folds with AnsiUpperCase, the platform hook this family has been taken off.
      It folds both operands here instead and searches the FOLDED bytes, then
      copies the ORIGINAL bytes back out around each match -- the fold is one
      codepoint per codepoint, so the two strings advance in step, one character
      at a time, and every stretch that did not match keeps the text's own
      spelling. The size guard and the price are measured on the folded pair,
      because that is the search that is actually going to run. }
    fh := FoldText(hay, ok);
    fn := FoldText(needle, ok2);
    if not (ok and ok2) then begin E := BudgetRefusal(AFn); Exit(ValStr('')); end;
  end;
  if not ReplaceFitsRtl(fh, fn, A[2].Str, outlen) then
  begin
    E := MakeError(peIntOverflow, AFn + ': the result would be ' + IntToStr(outlen) +
         ' bytes, past the ' + IntToStr(High(Integer)) +
         ' this replace can address');
    Exit(ValStr(''));
  end;
  if not BudgetAllows(ReplaceCost(fh, fn, A[2].Str, AIgnoreCase)) then
  begin
    E := BudgetRefusal(AFn);
    Exit(ValStr(''));
  end;
  if not AIgnoreCase then
    Exit(ValStr(StringReplace(hay, needle, A[2].Str, [rfReplaceAll])));
  if fn = '' then Exit(ValStr(hay));       // an empty needle answers the text unchanged
  r := ''; fcur := 1; hcur := 1; seg := 1;
  fp := PosEx(fn, fh, 1);
  while fp > 0 do
  begin
    while fcur < fp do
    begin fcur := NextCp(fh, fcur); hcur := NextCp(hay, hcur); end;
    r := r + Copy(hay, seg, hcur - seg) + A[2].Str;
    target := fp + Length(fn);
    while fcur < target do
    begin fcur := NextCp(fh, fcur); hcur := NextCp(hay, hcur); end;
    seg := hcur;
    fp := PosEx(fn, fh, target);
  end;
  Result := ValStr(r + Copy(hay, seg, Length(hay) - seg + 1));
end;

function f_replacestr(const A: array of TValue; out E: TPhosphorError): TValue;
begin Result := DoReplace(A, 'replacestr$', False, E); end;
function f_replacetext(const A: array of TValue; out E: TPhosphorError): TValue;
begin Result := DoReplace(A, 'replacetext$', True, E); end;

function f_countstr(const A: array of TValue; out E: TPhosphorError): TValue;
var sub: String; c, p: Integer;
begin
  E := NoError(); sub := A[1].Str; c := 0;
  if not BudgetAllows(SearchCost(s0(A), sub)) then
  begin E := BudgetRefusal('countstr'); Exit(ValInt(0)); end;
  if sub <> '' then
  begin
    p := PosEx(sub, s0(A), 1);
    while p > 0 do begin Inc(c); p := PosEx(sub, s0(A), p + Length(sub)); end;
  end;
  Result := ValInt(c);
end;
function f_containsstr(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  E := NoError();
  if not BudgetAllows(SearchCost(s0(A), A[1].Str)) then
  begin E := BudgetRefusal('containsstr'); Exit(ValInt(0)); end;
  Result := ValInt(Ord(Pos(A[1].Str, s0(A)) > 0));
end;

// startsstr/endsstr take the TEXT first (decisions.md); *text variants are
// case-insensitive.
function f_startsstr(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(Ord(Copy(s0(A), 1, Length(A[1].Str)) = A[1].Str)); end;
function f_endsstr(const A: array of TValue; out E: TPhosphorError): TValue;
var t, x: String;
begin E := NoError(); t := s0(A); x := A[1].Str;
  Result := ValInt(Ord((Length(x) <= Length(t)) and (Copy(t, Length(t) - Length(x) + 1, Length(x)) = x))); end;
{ The *text predicates all fold through FoldText -- the one case rule, stated
  above DoReplace. SameText, which used to stand here, folds a..z only.

  Each folds the needle and only the stretch of the TEXT that can answer: the
  first k characters for a prefix, the last k for a suffix, where k is the
  needle's own length in characters. The fold preserves that count, so the two
  folded strings are compared WHOLE -- a text with fewer than k characters folds
  to fewer than k and simply is not equal. See CpWalk for the measurement that
  made the bound necessary. }
function f_startstext(const A: array of TValue; out E: TPhosphorError): TValue;
var t, ft, fx: String; k, n, e2: Integer; ok, ok2: Boolean;
begin
  E := NoError();
  t := s0(A);
  k := Utf8Len(A[1].Str);
  CpWalk(t, k, n, e2);
  ft := FoldText(Copy(t, 1, e2 - 1), ok);
  fx := FoldText(A[1].Str, ok2);
  if not (ok and ok2) then begin E := BudgetRefusal('startstext'); Exit(ValInt(0)); end;
  Result := ValInt(Ord(ft = fx));
end;
function f_endstext(const A: array of TValue; out E: TPhosphorError): TValue;
var t, ft, fx: String; k, st: Integer; ok, ok2: Boolean;
begin
  E := NoError();
  t := s0(A);
  k := Utf8Len(A[1].Str);
  st := CpSuffixStart(t, k);
  ft := FoldText(Copy(t, st, Length(t) - st + 1), ok);
  fx := FoldText(A[1].Str, ok2);
  if not (ok and ok2) then begin E := BudgetRefusal('endstext'); Exit(ValInt(0)); end;
  Result := ValInt(Ord(ft = fx));
end;

{ isnumeric ANSWERS FOR THE VALUE, NOT FOR THE PARSE. TryStrToFloat succeeds on
  "inf", "nan" and on an out-of-range exponent like "1e999", handing back a
  non-finite Double -- and this function used to throw that Double away and report
  1. But str.md's documented idiom is to guard a val() with isnumeric, and val()
  cannot return a non-finite Double: the engine's finiteness gate (PhosphorValue)
  turns one into `val has no finite result for those arguments`. So the guard said
  yes and the call it guarded faulted, and an unguarded program exited 1 with no
  output at all. A string isnumeric approves must be one val can hand back. }
function f_isnumeric(const A: array of TValue; out E: TPhosphorError): TValue;
var d: Double;
begin E := NoError();
  Result := ValInt(Ord((s0(A) <> '') and TryStrToFloat(Trim(s0(A)), d, InvFS) and IsFiniteD(d))); end;
function f_isalpha(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; i: Integer; ok: Boolean;
begin
  E := NoError(); s := s0(A); ok := s <> '';
  for i := 1 to Length(s) do
    if not (((s[i] >= 'A') and (s[i] <= 'Z')) or ((s[i] >= 'a') and (s[i] <= 'z'))) then ok := False;
  Result := ValInt(Ord(ok));
end;

function f_count(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  E := NoError();
  if s0(A) = '' then Result := ValInt(0) else Result := ValInt(Length(SplitLines(s0(A))));
end;

function f_word(const A: array of TValue; out E: TPhosphorError): TValue;
var parts: TStringArray; idx: Integer;
begin
  E := NoError(); Result := ValStr('');
  // SplitBy is a PosEx loop: the same naive product as instr, once per piece.
  if not BudgetAllows(SearchCost(s0(A), A[2].Str)) then
  begin E := BudgetRefusal('word$'); Exit(ValStr('')); end;
  parts := SplitBy(s0(A), A[2].Str);
  idx := ArgI32(A[1]);   // 1-based
  if (idx >= 1) and (idx <= Length(parts)) then Result := ValStr(parts[idx - 1]);
end;
function f_wordcount(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  E := NoError();
  if not BudgetAllows(SearchCost(s0(A), A[1].Str)) then
  begin E := BudgetRefusal('wordcount'); Exit(ValInt(0)); end;
  Result := ValInt(Length(SplitBy(s0(A), A[1].Str)));
end;

// instr family: 1-based position, 0 when absent.
{ Byte offset -> codepoint position, both 1-based. A byte inside a multi-byte
  character answers the position of the character containing it. 0 stays 0, which
  is how every search here says "absent". }
function ByteToCp(const S: String; AByte: Integer): Integer;
var st: TInt64DynArray; i: Integer;
begin
  if AByte <= 0 then Exit(0);
  st := CpStarts(S);
  for i := 0 to High(st) - 1 do
    if (st[i] <= AByte) and (AByte < st[i + 1]) then Exit(i + 1);
  Result := Length(st);   // past the end: the sentinel position
end;

{ Codepoint position -> byte offset, 1-based, clamped to the string. }
function CpToByte(const S: String; ACp: Integer): Integer;
var st: TInt64DynArray;
begin
  if ACp <= 1 then Exit(1);
  st := CpStarts(S);
  if ACp > Length(st) then Exit(Length(S) + 1);
  Result := st[ACp - 1];
end;

function f_instr2(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  E := NoError();
  if not BudgetAllows(SearchCost(s0(A), A[1].Str)) then
  begin E := BudgetRefusal('instr'); Exit(ValInt(0)); end;
  Result := ValInt(ByteToCp(s0(A), Pos(A[1].Str, s0(A))));
end;
function f_instr3(const A: array of TValue; out E: TPhosphorError): TValue;
var start: Integer;
begin
  E := NoError();
  if not BudgetAllows(SearchCost(s0(A), A[1].Str)) then
  begin E := BudgetRefusal('instr'); Exit(ValInt(0)); end;
  start := ArgI32(A[2]); if start < 1 then start := 1;
  // The start is a CODEPOINT position, like every other index in the language, so
  // it is translated into a byte offset for the search and the answer translated
  // back. Both halves have to move together or the two would disagree.
  Result := ValInt(ByteToCp(s0(A),
    PosEx(A[1].Str, s0(A), CpToByte(s0(A), start))));
end;
function f_instrrev(const A: array of TValue; out E: TPhosphorError): TValue;
var t, sub: String; p, last: Integer;
begin
  E := NoError(); t := s0(A); sub := A[1].Str; last := 0;
  if not BudgetAllows(SearchCost(t, sub)) then
  begin E := BudgetRefusal('instrrev'); Exit(ValInt(0)); end;
  if sub <> '' then
  begin
    p := PosEx(sub, t, 1);
    while p > 0 do begin last := p; p := PosEx(sub, t, p + 1); end;
  end;
  Result := ValInt(ByteToCp(t, last));
end;

// helpers behind the s$[n] / s$[[n]] index sugar
function f_strchar(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValStr(CpAt(s0(A), ArgI32(A[1]))); end;
function f_strline(const A: array of TValue; out E: TPhosphorError): TValue;
var lines: TStringArray; idx: Integer;
begin
  E := NoError(); Result := ValStr('');
  lines := SplitLines(s0(A));
  idx := ArgI32(A[1]);   // 1-based
  if (idx >= 1) and (idx <= Length(lines)) then Result := ValStr(lines[idx - 1]);
end;

// --- StrLib, the wider surface (30_strlib_full) -----------------------------
// The reference counts these positions from 0; Phosphor is base-1 everywhere,
// so insert$/delete$/line$ take 1-based positions here and stuffstring$ (already
// 1-based in Delphi) is unchanged.

// Unicode (locale-following) case, over the whole codepoint range -- the 'a'
// (Ansi) prefix, as opposed to ucase$/lcase$ which only know a-z. The result is
// re-emitted through Utf8Char rather than UTF8Encode ON PURPOSE: UTF8Encode tags
// its result CP_UTF8, while every other string in the engine (literals, chr$)
// carries DefaultSystemCodePage, and AnsiString '=' transcodes on a codepage
// mismatch -- so two byte-identical strings would compare UNEQUAL. Building the
// bytes with Chr() (as chr$ does) keeps the codepage tag consistent. See
// [[phosphor-project]] on the codepage-tag hazard.
{ AND THE WALK IS OVER CODEPOINTS, NOT UTF-16 CODE UNITS.

  `for i := 1 to Length(u)` over a UnicodeString steps CODE UNITS, so a
  character above the BMP -- which UTF-16 holds as a SURROGATE PAIR -- was split
  and each half re-encoded on its own:

    aucase$(chr$(128512))   F0 9F 98 80  ->  ED A0 BD ED B8 80   len 1 -> 2

  Those six bytes are CESU-8, not UTF-8. No consumer decodes them back to one
  character -- not a file, not a browser, not Phosphor's own len() -- and the
  round trip alcase$(aucase$(x)) = x came back false. U+1F600 has no case
  mapping at all, so the only correct answer was to leave it alone.

  A pair is now combined into its codepoint and re-emitted WHOLE, which is what
  the old code was already trying to say: TCharacter.ToUpper answers a surrogate
  half unchanged (a surrogate has no case mapping), so the intent was always the
  identity here -- it was the SPLIT, not the mapping, that corrupted the string.

  WHY NOT TCharacter.ToUpper(UnicodeString): that overload calls UnicodeToUpper
  and RAISES EArgumentException on an invalid sequence (rtl/objpas/character.pas,
  read rather than assumed). This unit's header promises errors are RETURNED,
  never raised, and an unpaired surrogate reaches here from any malformed input.

  Simple case mappings that DO exist above the BMP (Deseret, Adlam, Warang Citi)
  are still not applied -- TCharacter offers no codepoint-level entry point, and
  reaching into unicodedata.GetProps for them costs a note this build bars. That
  is the behaviour this code always had for those ranges, now without the
  corruption; it is a separate change and is written down as one.

  THE MIRROR. A BMP code unit takes the same TCharacter.ToUpper it always took,
  and an unpaired surrogate takes it too, so every string that was right stays
  byte-identical. Only a well-formed surrogate PAIR takes the new branch. }
{ QUADRATIC APPEND, charged -- the same shape and the same reason as CpReverse.
  Unbudgeted, aucase$/alcase$ of a 160 MB string took 48984 ms under a 2000 ms
  ceiling and reported success. Length(S) is an upper bound on the number of
  appends (UTF8Decode never produces more UTF-16 units than input bytes), so the
  price is fixed before the loop starts. }
function Utf8CaseU(const S: String; AUpper: Boolean; out AAllowed: Boolean): String;
var u: UnicodeString; i, n: Integer; hi, lo: Word;
begin
  Result := '';
  AAllowed := BudgetAllows(Int64(Length(S)) * BudgetUnitsPerAppendedByte);
  if not AAllowed then Exit;
  u := UTF8Decode(S);
  n := Length(u);
  i := 1;
  while i <= n do
  begin
    hi := Word(u[i]);
    if (hi >= $D800) and (hi <= $DBFF) and (i < n) then
    begin
      lo := Word(u[i + 1]);
      if (lo >= $DC00) and (lo <= $DFFF) then
      begin
        Result := Result + Utf8Char(
          $10000 + ((Integer(hi) - $D800) shl 10) + (Integer(lo) - $DC00));
        Inc(i, 2);
        Continue;
      end;
    end;
    // a BMP code unit, or an UNPAIRED surrogate: the single-unit path, unchanged
    if AUpper then Result := Result + Utf8Char(Ord(TCharacter.ToUpper(u[i])))
    else Result := Result + Utf8Char(Ord(TCharacter.ToLower(u[i])));
    Inc(i);
  end;
end;

function Utf8UpperU(const S: String; out AAllowed: Boolean): String;
begin
  Result := Utf8CaseU(S, True, AAllowed);
end;
function Utf8LowerU(const S: String; out AAllowed: Boolean): String;
begin
  Result := Utf8CaseU(S, False, AAllowed);
end;

{ THE FOLD THE "ignoring case" FAMILY USES, and the whole of it: it is aucase$'s
  own engine, not a second copy of the rule. The long note above DoReplace says
  why there is exactly one, why it is this one, and why Windows and Linux answer
  the same. AAllowed False means the budget refused the fold, and the caller turns
  that into the peLimit it would have raised for the search. }
function FoldText(const S: String; out AAllowed: Boolean): String;
begin
  Result := Utf8UpperU(S, AAllowed);
end;

function SignI(c: Integer): Integer; inline;
begin if c < 0 then Result := -1 else if c > 0 then Result := 1 else Result := 0; end;

{ proper$ and swapcase$ are BYTE-wise ASCII case operations -- alcase$/aucase$ are
  the Unicode-aware pair. Both used to build their answer with `r := r + c` where c
  is a Char, which under this unit's UTF8 codepage re-encodes every byte >= 128:
  proper$("cafe" with an e-acute) came back as "Caf??", two bytes destroyed per
  accented letter, silently, with no error anywhere.

  They now COPY the input and edit ASCII letters in place. Nothing else is touched,
  which is both the correct behaviour and, structurally, the reason the bug cannot
  come back here: there is no concatenation left to get wrong. }
function f_proper(const A: array of TValue; out E: TPhosphorError): TValue;
var r: String; i: Integer; atStart: Boolean; c: Char;
begin
  E := NoError(); r := s0(A); atStart := True;
  for i := 1 to Length(r) do
  begin
    c := r[i];
    if (c = ' ') or (c = #9) or (c = #10) or (c = #13) then
      atStart := True
    else
    begin
      if atStart then
      begin if (c >= 'a') and (c <= 'z') then r[i] := Chr(Ord(c) - 32); end
      else if (c >= 'A') and (c <= 'Z') then r[i] := Chr(Ord(c) + 32);
      atStart := False;
    end;
  end;
  Result := ValStr(r);
end;

function f_swapcase(const A: array of TValue; out E: TPhosphorError): TValue;
var r: String; i: Integer; c: Char;
begin
  E := NoError(); r := s0(A);
  for i := 1 to Length(r) do
  begin
    c := r[i];
    if (c >= 'a') and (c <= 'z') then r[i] := Chr(Ord(c) - 32)
    else if (c >= 'A') and (c <= 'Z') then r[i] := Chr(Ord(c) + 32);
  end;
  Result := ValStr(r);
end;

function f_alcase(const A: array of TValue; out E: TPhosphorError): TValue;
var r: String; ok: Boolean;
begin
  E := NoError();
  r := Utf8LowerU(s0(A), ok);
  if not ok then begin E := BudgetRefusal('alcase$'); Exit(ValStr('')); end;
  Result := ValStr(r);
end;
function f_aucase(const A: array of TValue; out E: TPhosphorError): TValue;
var r: String; ok: Boolean;
begin
  E := NoError();
  r := Utf8UpperU(s0(A), ok);
  if not ok then begin E := BudgetRefusal('aucase$'); Exit(ValStr('')); end;
  Result := ValStr(r);
end;

{ THE PAD FAMILY. Every one of these takes a WIDTH from the program and builds
  width-minus-length filler, so ltab$("x", 2000000000) is a two-gigabyte
  allocation asked for by eleven characters of BASIC -- the same derivable size
  as string$, and the same RULE 1 answer. The PAD is charged, not the whole
  result: the caller's own string was already in memory before the call. }
function f_ltab(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; w, n: Integer;
begin
  E := NoError(); s := Trim(s0(A)); w := ArgI32(A[1]); n := CpLen(s);
  if n >= w then Exit(ValStr(s));
  if not BudgetAllows(w - n) then begin E := BudgetRefusal('ltab$'); Exit(ValStr('')); end;
  Result := ValStr(StringOfChar(' ', w - n) + s);
end;
function f_rtab(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; w, n: Integer;
begin
  E := NoError(); s := Trim(s0(A)); w := ArgI32(A[1]); n := CpLen(s);
  if n >= w then Exit(ValStr(s));
  if not BudgetAllows(w - n) then begin E := BudgetRefusal('rtab$'); Exit(ValStr('')); end;
  Result := ValStr(s + StringOfChar(' ', w - n));
end;
function f_lfill(const A: array of TValue; out E: TPhosphorError): TValue;
var s, f: String; w, n: Integer;
begin
  E := NoError(); s := s0(A); w := ArgI32(A[1]); f := Utf8Char(ArgI32(A[2])); n := CpLen(s);
  if n >= w then Exit(ValStr(s));
  if not BudgetAllows(Int64(w - n) * Length(f)) then
  begin E := BudgetRefusal('lfill$'); Exit(ValStr('')); end;
  Result := ValStr(DupeString(f, w - n) + s);
end;
function f_rfill(const A: array of TValue; out E: TPhosphorError): TValue;
var s, f: String; w, n: Integer;
begin
  E := NoError(); s := s0(A); w := ArgI32(A[1]); f := Utf8Char(ArgI32(A[2])); n := CpLen(s);
  if n >= w then Exit(ValStr(s));
  if not BudgetAllows(Int64(w - n) * Length(f)) then
  begin E := BudgetRefusal('rfill$'); Exit(ValStr('')); end;
  Result := ValStr(s + DupeString(f, w - n));
end;
function f_center2(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; w, pad, l: Integer;
begin
  E := NoError(); s := s0(A); w := ArgI32(A[1]); pad := w - CpLen(s);
  if pad <= 0 then Exit(ValStr(s));
  if not BudgetAllows(pad) then begin E := BudgetRefusal('center$'); Exit(ValStr('')); end;
  l := pad div 2;
  Result := ValStr(StringOfChar(' ', l) + s + StringOfChar(' ', pad - l));
end;
function f_center3(const A: array of TValue; out E: TPhosphorError): TValue;
var s, f: String; w, pad, l: Integer;
begin
  E := NoError(); s := s0(A); w := ArgI32(A[1]); f := Utf8Char(ArgI32(A[2])); pad := w - CpLen(s);
  if pad <= 0 then Exit(ValStr(s));
  if not BudgetAllows(Int64(pad) * Length(f)) then
  begin E := BudgetRefusal('center$'); Exit(ValStr('')); end;
  l := pad div 2;
  Result := ValStr(DupeString(f, l) + s + DupeString(f, pad - l));
end;

function f_isdigits(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; i: Integer; ok: Boolean;
begin
  E := NoError(); s := s0(A); ok := s <> '';
  for i := 1 to Length(s) do if not ((s[i] >= '0') and (s[i] <= '9')) then ok := False;
  Result := ValInt(Ord(ok));
end;
function f_isalnum(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; i: Integer; ok: Boolean; c: Char;
begin
  E := NoError(); s := s0(A); ok := s <> '';
  for i := 1 to Length(s) do
  begin
    c := s[i];
    if not (((c >= '0') and (c <= '9')) or ((c >= 'A') and (c <= 'Z')) or ((c >= 'a') and (c <= 'z'))) then ok := False;
  end;
  Result := ValInt(Ord(ok));
end;
function f_isspace(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; i: Integer; ok: Boolean;
begin
  E := NoError(); s := s0(A); ok := s <> '';
  for i := 1 to Length(s) do if not (s[i] in [' ', #9, #10, #11, #12, #13]) then ok := False;
  Result := ValInt(Ord(ok));
end;
function f_islower(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; i: Integer; hasLow, hasUp: Boolean; c: Char;
begin
  E := NoError(); s := s0(A); hasLow := False; hasUp := False;
  for i := 1 to Length(s) do
  begin
    c := s[i];
    if (c >= 'a') and (c <= 'z') then hasLow := True
    else if (c >= 'A') and (c <= 'Z') then hasUp := True;
  end;
  Result := ValInt(Ord(hasLow and not hasUp));
end;
function f_isupper(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; i: Integer; hasLow, hasUp: Boolean; c: Char;
begin
  E := NoError(); s := s0(A); hasLow := False; hasUp := False;
  for i := 1 to Length(s) do
  begin
    c := s[i];
    if (c >= 'a') and (c <= 'z') then hasLow := True
    else if (c >= 'A') and (c <= 'Z') then hasUp := True;
  end;
  Result := ValInt(Ord(hasUp and not hasLow));
end;

function f_containstext(const A: array of TValue; out E: TPhosphorError): TValue;
var ft, fx: String; ok, ok2: Boolean;
begin
  E := NoError();
  // The fold upper-cases BOTH strings and then searches, so it is the naive
  // product plus two copies of the haystack. Same bound, same rule -- and the
  // same shape StrUtils.ContainsText had here before, only folding by this
  // unit's rule instead of by the platform's.
  if not BudgetAllows(SearchCost(s0(A), A[1].Str, True)) then
  begin E := BudgetRefusal('containstext'); Exit(ValInt(0)); end;
  ft := FoldText(s0(A), ok); fx := FoldText(A[1].Str, ok2);
  if not (ok and ok2) then begin E := BudgetRefusal('containstext'); Exit(ValInt(0)); end;
  Result := ValInt(Ord(Pos(fx, ft) > 0));
end;

function f_strcmp(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(SignI(CompareStr(s0(A), A[1].Str))); end;
{ strcmpi folds only as far as the comparison can reach. CompareStr is decided
  either at the first differing byte -- which lies inside the first min(length)
  CHARACTERS of both, the fold being one codepoint per codepoint -- or by the
  two character counts. So both counts are walked to a limit of one more than the
  shorter operand's BYTE length, which is an upper bound on the shorter
  character count and therefore leaves the shorter operand's count EXACT while
  capping only the longer one, and capping it above the other. Then only that
  many characters of each are folded.

  Without the bound, strcmpi(32-MB string, "x") folded 32 MB to answer a question
  the first character settles: 28 s against 0.057 s, measured. }
function f_strcmpi(const A: array of TValue; out E: TPhosphorError): TValue;
var sa, sb, fa, fb: String; lim, ka, kb, k, ea, eb, c: Integer; ok, ok2: Boolean;
begin
  E := NoError();
  sa := s0(A); sb := A[1].Str;
  if Length(sa) < Length(sb) then lim := Length(sa) + 1 else lim := Length(sb) + 1;
  CpWalk(sa, lim, ka, ea);
  CpWalk(sb, lim, kb, eb);
  if ka < kb then k := ka else k := kb;
  CpWalk(sa, k, c, ea);
  CpWalk(sb, k, c, eb);
  fa := FoldText(Copy(sa, 1, ea - 1), ok);
  fb := FoldText(Copy(sb, 1, eb - 1), ok2);
  if not (ok and ok2) then begin E := BudgetRefusal('strcmpi'); Exit(ValInt(0)); end;
  c := CompareStr(fa, fb);
  if c = 0 then c := ka - kb;
  Result := ValInt(SignI(c));
end;

function f_insert(const A: array of TValue; out E: TPhosphorError): TValue;
var s, ins: String; pos, n: Integer;
begin
  E := NoError(); s := s0(A); ins := A[1].Str; pos := ArgI32(A[2]); n := CpLen(s);
  if pos < 1 then pos := 1;
  if pos > n + 1 then pos := n + 1;
  Result := ValStr(CpLeft(s, pos - 1) + ins + CpRight(s, n - (pos - 1)));
end;
{ CLAMP BEFORE SUBTRACTING -- the fix f_mid already carries, applied to its two
  siblings. ArgI32 SATURATES, so delete$(s$, 2147483647, 2147483647) arrives with
  pos and cnt both at High(Integer); `n - (pos - 1) - cnt` is then Integer
  arithmetic whose true value, -4294967288 for a five-character string, wraps
  modulo 2^32 to +8. The `if rem < 0` guard below therefore never fired, and
  CpRight was asked for eight characters of a five-character string -- which
  answers the WHOLE string, so delete$ returned its input TWICE and stuffstring$
  returned it twice with the replacement in the middle. A delete cannot make a
  string longer. No position past the end and no count past the length can mean
  anything, so both are clamped to what the string can hold before they are used,
  and the subtraction that follows is then bounded by n on every term. }
function f_delete(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; pos, cnt, n, rem: Integer;
begin
  E := NoError(); s := s0(A); pos := ArgI32(A[1]); cnt := ArgI32(A[2]); n := CpLen(s);
  if pos < 1 then pos := 1;
  if pos > n + 1 then pos := n + 1;
  if cnt < 0 then cnt := 0;
  if cnt > n then cnt := n;
  rem := n - (pos - 1) - cnt; if rem < 0 then rem := 0;
  Result := ValStr(CpLeft(s, pos - 1) + CpRight(s, rem));
end;
function f_stuffstring(const A: array of TValue; out E: TPhosphorError): TValue;
var s, repl: String; start, len, n, rem: Integer;
begin
  E := NoError(); s := s0(A); start := ArgI32(A[1]); len := ArgI32(A[2]); repl := A[3].Str; n := CpLen(s);
  if start < 1 then start := 1;
  if start > n + 1 then start := n + 1;
  if len < 0 then len := 0;
  if len > n then len := n;
  rem := n - (start - 1) - len; if rem < 0 then rem := 0;
  Result := ValStr(CpLeft(s, start - 1) + repl + CpRight(s, rem));
end;

function f_line(const A: array of TValue; out E: TPhosphorError): TValue;
var lines: TStringArray; idx: Integer;
begin
  E := NoError(); Result := ValStr('');
  lines := SplitLines(s0(A));
  idx := ArgI32(A[1]);   // 1-based
  if (idx >= 1) and (idx <= Length(lines)) then Result := ValStr(lines[idx - 1]);
end;

function f_valcode(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError(); Result := ValInt(GValCode); end;

{ ---- BYTE primitives -------------------------------------------------------
  Everything else in this unit counts UTF-8 CODEPOINTS: len/mid$/left$/right$ and
  s$[[n]] address characters, and chr$ ENCODES a codepoint (chr$(255) is the two
  bytes C3 BF). That is right for text and wrong for binary -- and a string$ is in
  fact a length-counted BYTE container that carries all 256 values intact.

  These four are the byte-domain counterparts, so binary data can be addressed
  directly instead of through a hex codec in an opt-in package:

    bytelen(s$)          how many BYTES the string holds
    byteat(s$, i)        the value 0..255 of byte i (1-based)
    bytestr$(v)          a ONE-BYTE string holding v -- the byte constructor that
                         chr$ cannot be, because chr$ would UTF-8-encode it
    bytemid$(s$, i, n)   n bytes starting at byte i (clamped, never raises)

  They live in the ENGINE, not a package, so an embedding host has byte access too. }

{ A crash-proof Double -> Int32 for index/count arguments: NaN and out-of-range
  values never reach Round (which would raise); they clamp. }
function f_bytelen(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  E := NoError();
  Result := ValInt(Length(A[0].Str));
end;

function f_byteat(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; i: Integer;
begin
  E := NoError();
  Result := ValInt(0);
  s := A[0].Str;
  i := ArgI32(A[1]);
  if (i < 1) or (i > Length(s)) then
    E := MakeError(peRuntime, 'byteat: byte ' + IntToStr(i) +
         ' is outside 1..' + IntToStr(Length(s)))
  else
    Result := ValInt(Ord(s[i]));
end;

function f_bytestr(const A: array of TValue; out E: TPhosphorError): TValue;
var v: Integer; r: RawByteString;
begin
  E := NoError();
  Result := ValStr('');
  v := ArgI32(A[0]);
  if (v < 0) or (v > 255) then
  begin
    E := MakeError(peRuntime, 'bytestr$: ' + IntToStr(v) + ' is not a byte value (0..255)');
    Exit;
  end;
  // An indexed write into a RawByteString stores the raw byte; building it by
  // concatenation would re-encode a value >= 128 through the UTF-8 codepage.
  SetLength(r, 1);
  r[1] := Chr(v);
  Result := ValStr(r);
end;

function f_bytemid(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; i, n, avail: Integer;
begin
  E := NoError();
  s := A[0].Str;
  i := ArgI32(A[1]);
  n := ArgI32(A[2]);
  if i < 1 then i := 1;
  if (n <= 0) or (i > Length(s)) then begin Result := ValStr(''); Exit; end;
  avail := Length(s) - i + 1;
  if n > avail then n := avail;
  Result := ValStr(Copy(s, i, n));   // Copy is byte-indexed: the run comes over verbatim
end;

procedure RegisterStrFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('bytelen:$', @f_bytelen);
  Reg.Add('byteat:$n', @f_byteat);
  Reg.Add('bytestr$:n', @f_bytestr);
  Reg.Add('bytemid$:$nn', @f_bytemid);
  Reg.Add('ucase$:$', @f_ucase);
  Reg.Add('lcase$:$', @f_lcase);
  Reg.Add('len:$', @f_len);
  Reg.Add('left$:$n', @f_left);
  Reg.Add('right$:$n', @f_right);
  Reg.Add('trim$:$', @f_trim);
  Reg.Add('ltrim$:$', @f_ltrim);
  Reg.Add('rtrim$:$', @f_rtrim);
  Reg.Add('reverse$:$', @f_reverse);
  Reg.Add('asc:$', @f_asc);
  Reg.Add('chr$:n', @f_chr);
  Reg.Add('hex$:n', @f_hex);
  Reg.Add('bin$:n', @f_bin);
  Reg.Add('oct$:n', @f_oct);
  Reg.Add('val:$', @f_val);
  Reg.Add('stri$:n', @f_stri);
  Reg.Add('str$:n', @f_stri);       // alias: number -> string, locale-invariant
  // ...and the exact slots, so an int% is not laid out through a Double
  Reg.Add('stri$:%', @f_striInt);
  Reg.Add('str$:%', @f_striInt);
  Reg.Add('mid$:$n', @f_mid);
  Reg.Add('mid$:$nn', @f_mid);
  Reg.Add('space$:n', @f_space);
  Reg.Add('string$:nn', @f_string);
  Reg.Add('mulstring$:$n', @f_mulstring);
  Reg.Add('replacestr$:$$$', @f_replacestr);
  Reg.Add('replacetext$:$$$', @f_replacetext);
  Reg.Add('countstr:$$', @f_countstr);
  Reg.Add('containsstr:$$', @f_containsstr);
  Reg.Add('startsstr:$$', @f_startsstr);
  Reg.Add('endsstr:$$', @f_endsstr);
  Reg.Add('startstext:$$', @f_startstext);
  Reg.Add('endstext:$$', @f_endstext);
  Reg.Add('isnumeric:$', @f_isnumeric);
  Reg.Add('isalpha:$', @f_isalpha);
  Reg.Add('count:$', @f_count);
  Reg.Add('word$:$n$', @f_word);
  Reg.Add('wordcount:$$', @f_wordcount);
  Reg.Add('instr:$$', @f_instr2);
  Reg.Add('instr:$$n', @f_instr3);
  Reg.Add('instrrev:$$', @f_instrrev);
  // index sugar helpers
  Reg.Add('strchar$:$n', @f_strchar);
  Reg.Add('strline$:$n', @f_strline);
  // wider surface (30_strlib_full)
  Reg.Add('proper$:$', @f_proper);
  Reg.Add('swapcase$:$', @f_swapcase);
  Reg.Add('alcase$:$', @f_alcase);
  Reg.Add('aucase$:$', @f_aucase);
  Reg.Add('ltab$:$n', @f_ltab);
  Reg.Add('rtab$:$n', @f_rtab);
  Reg.Add('lfill$:$nn', @f_lfill);
  Reg.Add('rfill$:$nn', @f_rfill);
  Reg.Add('center$:$n', @f_center2);
  Reg.Add('center$:$nn', @f_center3);
  Reg.Add('isdigits:$', @f_isdigits);
  Reg.Add('isalnum:$', @f_isalnum);
  Reg.Add('isspace:$', @f_isspace);
  Reg.Add('islower:$', @f_islower);
  Reg.Add('isupper:$', @f_isupper);
  Reg.Add('containstext:$$', @f_containstext);
  Reg.Add('strcmp:$$', @f_strcmp);
  Reg.Add('strcmpi:$$', @f_strcmpi);
  Reg.Add('insert$:$$n', @f_insert);
  Reg.Add('delete$:$nn', @f_delete);
  Reg.Add('stuffstring$:$nn$', @f_stuffstring);
  Reg.Add('line$:$n', @f_line);
  Reg.Add('valcode:', @f_valcode);
end;

initialization
  InvFS := DefaultFormatSettings;
  InvFS.DecimalSeparator := '.';
  InvFS.ThousandSeparator := #0;

end.
