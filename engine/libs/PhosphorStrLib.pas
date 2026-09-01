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
  SysUtils, StrUtils, Types, PhosphorValue, PhosphorErrors, PhosphorRegistry;

procedure RegisterStrFuncs(Reg: TPhosphorRegistry);

implementation

var
  InvFS: TFormatSettings;

// --- UTF-8 codepoint helpers ------------------------------------------------
// Byte index (1-based) of the start of each codepoint, plus a sentinel at
// Length(S)+1, so codepoint k spans Starts[k] .. Starts[k+1]-1.
function CpStarts(const S: String): TInt64DynArray;
var i, n: Integer;
begin
  SetLength(Result, Length(S) + 1);
  n := 0;
  for i := 1 to Length(S) do
    if (Ord(S[i]) < $80) or (Ord(S[i]) >= $C0) then   // not a continuation byte
    begin
      Result[n] := i;
      Inc(n);
    end;
  Result[n] := Length(S) + 1;   // sentinel
  SetLength(Result, n + 1);
end;

function CpLen(const S: String): Integer;
begin
  Result := Length(CpStarts(S)) - 1;
end;

function CpAt(const S: String; AOneBased: Integer): String;
var st: TInt64DynArray;
begin
  Result := '';
  st := CpStarts(S);
  if (AOneBased >= 1) and (AOneBased <= Length(st) - 1) then
    Result := Copy(S, st[AOneBased - 1], st[AOneBased] - st[AOneBased - 1]);
end;

function CpLeft(const S: String; ACount: Integer): String;
var st: TInt64DynArray; n: Integer;
begin
  st := CpStarts(S);
  n := Length(st) - 1;
  if ACount < 0 then ACount := 0;
  if ACount >= n then Exit(S);
  Result := Copy(S, 1, st[ACount] - 1);
end;

function CpRight(const S: String; ACount: Integer): String;
var st: TInt64DynArray; n: Integer;
begin
  st := CpStarts(S);
  n := Length(st) - 1;
  if ACount < 0 then ACount := 0;
  if ACount >= n then Exit(S);
  Result := Copy(S, st[n - ACount], MaxInt);
end;

function CpReverse(const S: String): String;
var st: TInt64DynArray; i, n: Integer;
begin
  Result := '';
  st := CpStarts(S);
  n := Length(st) - 1;
  for i := n downto 1 do
    Result := Result + Copy(S, st[i - 1], st[i] - st[i - 1]);
end;

// --- string splitting -------------------------------------------------------
function SplitBy(const S, Sep: String): TStringArray;
var start, i, n: Integer;
begin
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
function s0(const Args: array of TValue): String; inline; begin Result := Args[0].Str; end;

function f_ucase(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(UpperCase(s0(A))); end;
function f_lcase(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(LowerCase(s0(A))); end;
function f_len(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(CpLen(s0(A))); end;
function f_left(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(CpLeft(s0(A), Round(AsDouble(A[1])))); end;
function f_right(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(CpRight(s0(A), Round(AsDouble(A[1])))); end;
function f_trim(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(Trim(s0(A))); end;
function f_ltrim(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(TrimLeft(s0(A))); end;
function f_rtrim(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(TrimRight(s0(A))); end;
function f_reverse(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(CpReverse(s0(A))); end;

// mid$(s, start[, len]) -- 1-based, by codepoint. Without len, to the end.
function f_mid(const A: array of TValue; out E: TPhosphorError): TValue;
var st: TInt64DynArray; startCp, cnt, lastEx, n: Integer;
begin
  E := NoError;
  st := CpStarts(s0(A));
  n := Length(st) - 1;
  startCp := Round(AsDouble(A[1]));
  if High(A) >= 2 then cnt := Round(AsDouble(A[2])) else cnt := n;
  if startCp < 1 then startCp := 1;
  if cnt < 0 then cnt := 0;
  if startCp > n then Exit(ValStr(''));
  lastEx := startCp + cnt;                 // one past the last codepoint
  if lastEx > n + 1 then lastEx := n + 1;
  Result := ValStr(Copy(s0(A), st[startCp - 1], st[lastEx - 1] - st[startCp - 1]));
end;

function f_asc(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String;
begin
  E := NoError;
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

function f_chr(const A: array of TValue; out E: TPhosphorError): TValue;
var c: Integer;
begin
  E := NoError;
  c := Round(AsDouble(A[0]));
  if c < $80 then Result := ValStr(Chr(c and $FF))
  else if c < $800 then
    Result := ValStr(Chr($C0 or (c shr 6)) + Chr($80 or (c and $3F)))
  else if c < $10000 then
    Result := ValStr(Chr($E0 or (c shr 12)) + Chr($80 or ((c shr 6) and $3F)) + Chr($80 or (c and $3F)))
  else
    Result := ValStr(Chr($F0 or (c shr 18)) + Chr($80 or ((c shr 12) and $3F)) + Chr($80 or ((c shr 6) and $3F)) + Chr($80 or (c and $3F)));
end;

function ToRadix(V: Int64; Base: Integer): String;
const digits = '0123456789ABCDEF';
var neg: Boolean;
begin
  if V = 0 then Exit('0');
  neg := V < 0;
  if neg then V := -V;
  Result := '';
  while V > 0 do
  begin
    Result := digits[(V mod Base) + 1] + Result;
    V := V div Base;
  end;
  if neg then Result := '-' + Result;
end;

function f_hex(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(ToRadix(Round(AsDouble(A[0])), 16)); end;
function f_bin(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(ToRadix(Round(AsDouble(A[0])), 2)); end;
function f_oct(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(ToRadix(Round(AsDouble(A[0])), 8)); end;

function f_val(const A: array of TValue; out E: TPhosphorError): TValue;
var d: Double;
begin
  E := NoError;
  if TryStrToFloat(Trim(s0(A)), d, InvFS) then Result := ValDouble(d) else Result := ValDouble(0);
end;
function f_stri(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(FloatToStr(AsDouble(A[0]), InvFS)); end;

function f_space(const A: array of TValue; out E: TPhosphorError): TValue;
var n: Integer;
begin E := NoError; n := Round(AsDouble(A[0])); if n < 0 then n := 0; Result := ValStr(StringOfChar(' ', n)); end;
function f_string(const A: array of TValue; out E: TPhosphorError): TValue;
var n: Integer;
begin E := NoError; n := Round(AsDouble(A[0])); if n < 0 then n := 0; Result := ValStr(StringOfChar(Chr(Round(AsDouble(A[1])) and $FF), n)); end;
function f_mulstring(const A: array of TValue; out E: TPhosphorError): TValue;
var n, i: Integer; r: String;
begin
  E := NoError; n := Round(AsDouble(A[1])); r := '';
  for i := 1 to n do r := r + s0(A);
  Result := ValStr(r);
end;

function f_replacestr(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(StringReplace(s0(A), A[1].Str, A[2].Str, [rfReplaceAll])); end;
function f_replacetext(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(StringReplace(s0(A), A[1].Str, A[2].Str, [rfReplaceAll, rfIgnoreCase])); end;

function f_countstr(const A: array of TValue; out E: TPhosphorError): TValue;
var sub: String; c, p: Integer;
begin
  E := NoError; sub := A[1].Str; c := 0;
  if sub <> '' then
  begin
    p := PosEx(sub, s0(A), 1);
    while p > 0 do begin Inc(c); p := PosEx(sub, s0(A), p + Length(sub)); end;
  end;
  Result := ValInt(c);
end;
function f_containsstr(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(Ord(Pos(A[1].Str, s0(A)) > 0)); end;

// startsstr/endsstr take the TEXT first (decisions.md); *text variants are
// case-insensitive.
function f_startsstr(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(Ord(Copy(s0(A), 1, Length(A[1].Str)) = A[1].Str)); end;
function f_endsstr(const A: array of TValue; out E: TPhosphorError): TValue;
var t, x: String;
begin E := NoError; t := s0(A); x := A[1].Str;
  Result := ValInt(Ord((Length(x) <= Length(t)) and (Copy(t, Length(t) - Length(x) + 1, Length(x)) = x))); end;
function f_startstext(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(Ord(SameText(Copy(s0(A), 1, Length(A[1].Str)), A[1].Str))); end;
function f_endstext(const A: array of TValue; out E: TPhosphorError): TValue;
var t, x: String;
begin E := NoError; t := s0(A); x := A[1].Str;
  Result := ValInt(Ord((Length(x) <= Length(t)) and SameText(Copy(t, Length(t) - Length(x) + 1, Length(x)), x))); end;

function f_isnumeric(const A: array of TValue; out E: TPhosphorError): TValue;
var d: Double;
begin E := NoError; Result := ValInt(Ord((s0(A) <> '') and TryStrToFloat(Trim(s0(A)), d, InvFS))); end;
function f_isalpha(const A: array of TValue; out E: TPhosphorError): TValue;
var s: String; i: Integer; ok: Boolean;
begin
  E := NoError; s := s0(A); ok := s <> '';
  for i := 1 to Length(s) do
    if not (((s[i] >= 'A') and (s[i] <= 'Z')) or ((s[i] >= 'a') and (s[i] <= 'z'))) then ok := False;
  Result := ValInt(Ord(ok));
end;

function f_count(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  E := NoError;
  if s0(A) = '' then Result := ValInt(0) else Result := ValInt(Length(SplitLines(s0(A))));
end;

function f_word(const A: array of TValue; out E: TPhosphorError): TValue;
var parts: TStringArray; idx: Integer;
begin
  E := NoError; Result := ValStr('');
  parts := SplitBy(s0(A), A[2].Str);
  idx := Round(AsDouble(A[1]));   // 1-based
  if (idx >= 1) and (idx <= Length(parts)) then Result := ValStr(parts[idx - 1]);
end;
function f_wordcount(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(Length(SplitBy(s0(A), A[1].Str))); end;

// instr family: 1-based position, 0 when absent.
function f_instr2(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(Pos(A[1].Str, s0(A))); end;
function f_instr3(const A: array of TValue; out E: TPhosphorError): TValue;
var start: Integer;
begin E := NoError; start := Round(AsDouble(A[2])); if start < 1 then start := 1;
  Result := ValInt(PosEx(A[1].Str, s0(A), start)); end;
function f_instrrev(const A: array of TValue; out E: TPhosphorError): TValue;
var t, sub: String; p, last: Integer;
begin
  E := NoError; t := s0(A); sub := A[1].Str; last := 0;
  if sub <> '' then
  begin
    p := PosEx(sub, t, 1);
    while p > 0 do begin last := p; p := PosEx(sub, t, p + 1); end;
  end;
  Result := ValInt(last);
end;

// helpers behind the s$[n] / s$[[n]] index sugar
function f_strchar(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(CpAt(s0(A), Round(AsDouble(A[1])))); end;
function f_strline(const A: array of TValue; out E: TPhosphorError): TValue;
var lines: TStringArray; idx: Integer;
begin
  E := NoError; Result := ValStr('');
  lines := SplitLines(s0(A));
  idx := Round(AsDouble(A[1]));   // 1-based
  if (idx >= 1) and (idx <= Length(lines)) then Result := ValStr(lines[idx - 1]);
end;

procedure RegisterStrFuncs(Reg: TPhosphorRegistry);
begin
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
end;

initialization
  InvFS := DefaultFormatSettings;
  InvFS.DecimalSeparator := '.';
  InvFS.ThousandSeparator := #0;

end.
