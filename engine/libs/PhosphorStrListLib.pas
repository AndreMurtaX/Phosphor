{******************************************************************************
  Phosphor BASIC -- string-list library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  A growable list of strings as a handle object. Plan9Basic's stringlist wrapped
  a Delphi TStringList and was 0-based; Phosphor is base-1 EVERYWHERE
  (decisions.md), so every index here is 1-based and `strings_indexof` returns 0
  (not -1) when absent. Errors are RETURNED, never raised; a fabricated handle is
  rejected by GetList (IsHandle) rather than dereferenced.

  Beyond the list operations themselves this package carries the TStrings
  PROPERTY surface Plan9Basic leaned on TStringList for: the delimiters
  (delimiter/quotechar/strictdelimiter/delimitedtext), the name/value machinery
  (namevalueseparator/values/valuefromindex/keynames), case sensitivity,
  duplicates policy, the line-break controls (linebreak/trailinglinebreak/
  writebom), the encoding names, the change-handler NAMES, batched updates, and
  the file and stream round trips. The stream pair moves a list through the same
  TPhosphorBytes handle PhosphorIoLib hands out for a file's bytes, so it stays
  host-agnostic: no console, window or socket, only pure RTL file/byte work.

  The change handlers (onchange/onchanging) store a HANDLER NAME and read it
  back; the firing itself belongs to a host with an event loop (phase 2), so this
  package only pins the name in and out -- exactly what oracle 28 asserts.
******************************************************************************}
unit PhosphorStrListLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorIoLib;

type
  TPhosphorStringList = class
  public
    Items: array of String;
    Count: Integer;
    Sorted: Boolean;    // when set, AddIndexed keeps the list ordered
    // --- TStrings-style properties (stored; the ones a list carries) ---------
    Delimiter: Char;
    QuoteChar: Char;
    StrictDelimiter: Boolean;
    CaseSensitive: Boolean;
    Duplicates: String;         // 'ignore' | 'accept' | 'error' (named, not numbered)
    LineBreak: String;
    TrailingLineBreak: Boolean;
    WriteBOM: Boolean;
    DefaultEncoding: String;    // the encoding a save would use
    Encoding: String;          // '' until a load/save establishes one
    NameValueSeparator: Char;
    OnChangeName: String;       // the BASIC handler NAME (fires in a host, phase 2)
    OnChangingName: String;
    UpdateCount: Integer;       // beginupdate/endupdate nesting
    constructor Create;
    procedure Add(const S: String);
    function AddIndexed(const S: String): Integer;       // 0-based index it landed at
    procedure Clear;
    procedure InsertAt(AZero: Integer; const S: String);
    procedure DeleteAt(AZero: Integer);
    procedure Exchange(A, B: Integer);
    procedure MoveItem(AFrom, ATo: Integer);
    procedure Sort;
    procedure SetText(const S: String);
    function TextStr: String;                            // honours LineBreak/TrailingLineBreak
    procedure SetCommaText(const S: String);
    function CommaTextStr: String;
    function GetDelimitedText: String;                   // honours Delimiter/QuoteChar
    procedure SetDelimitedText(const S: String);
    function IndexOf(const S: String): Integer;          // 0-based, -1 absent
    function Find(const S: String): Integer;             // binary search; needs a sorted list
    function IndexOfName(const AName: String): Integer;  // 0-based, -1 absent
    function ValueOf(const AName: String): String;
    procedure SetValue(const AName, AValue: String);
    function NameAt(AZero: Integer): String;
    function ValueAt(AZero: Integer): String;
    procedure SetValueAt(AZero: Integer; const AValue: String);
    function EqualsList(AOther: TPhosphorStringList): Boolean;
    function CapacityGet: Integer;
    procedure CapacitySet(N: Integer);
  end;

procedure RegisterStrListFuncs(Reg: TPhosphorRegistry);

implementation

const
  Utf8Bom = #$EF#$BB#$BF;

constructor TPhosphorStringList.Create;
begin
  inherited Create();
  Delimiter := ',';
  QuoteChar := '"';
  StrictDelimiter := False;
  CaseSensitive := False;
  Duplicates := 'ignore';
  LineBreak := sLineBreak;
  TrailingLineBreak := True;
  WriteBOM := False;
  DefaultEncoding := 'utf-8';    // Phosphor speaks raw UTF-8 -- the honest default
  Encoding := '';                // none established until a load or save
  NameValueSeparator := '=';
  OnChangeName := '';
  OnChangingName := '';
  UpdateCount := 0;
end;

procedure TPhosphorStringList.Add(const S: String);
begin
  if Count = Length(Items) then SetLength(Items, (Count + 1) * 2);
  Items[Count] := S;
  Inc(Count);
end;

{ Append, or -- when the list is Sorted -- insert at the ordered position. Returns
  the 0-based index the item landed at. }
function TPhosphorStringList.AddIndexed(const S: String): Integer;
var i: Integer;
begin
  if Sorted then
  begin
    i := 0;
    while (i < Count) and (CompareStr(Items[i], S) <= 0) do Inc(i);
    InsertAt(i, S);
    Result := i;
  end
  else
  begin
    Add(S);
    Result := Count - 1;
  end;
end;

procedure TPhosphorStringList.Clear;
begin
  Count := 0;
end;

procedure TPhosphorStringList.InsertAt(AZero: Integer; const S: String);
var i: Integer;
begin
  if Count = Length(Items) then SetLength(Items, (Count + 1) * 2);
  for i := Count downto AZero + 1 do
    Items[i] := Items[i - 1];
  Items[AZero] := S;
  Inc(Count);
end;

procedure TPhosphorStringList.DeleteAt(AZero: Integer);
var i: Integer;
begin
  for i := AZero to Count - 2 do
    Items[i] := Items[i + 1];
  Dec(Count);
end;

procedure TPhosphorStringList.Exchange(A, B: Integer);
var t: String;
begin
  t := Items[A]; Items[A] := Items[B]; Items[B] := t;
end;

procedure TPhosphorStringList.MoveItem(AFrom, ATo: Integer);
var t: String; i: Integer;
begin
  if AFrom = ATo then Exit;
  t := Items[AFrom];
  if AFrom < ATo then
    for i := AFrom to ATo - 1 do Items[i] := Items[i + 1]
  else
    for i := AFrom downto ATo + 1 do Items[i] := Items[i - 1];
  Items[ATo] := t;
end;

procedure TPhosphorStringList.Sort;
var i, j: Integer; t: String;
begin
  // small lists; a simple insertion sort keeps it stable and dependency-free
  for i := 1 to Count - 1 do
  begin
    t := Items[i];
    j := i - 1;
    while (j >= 0) and (CompareStr(Items[j], t) > 0) do
    begin
      Items[j + 1] := Items[j];
      Dec(j);
    end;
    Items[j + 1] := t;
  end;
end;

procedure TPhosphorStringList.SetText(const S: String);
var
  start, i, len: Integer;
  line: String;
begin
  Clear();
  if S = '' then Exit;   // empty text is an empty list, not one empty line
  len := Length(S);
  start := 1;
  for i := 1 to len + 1 do
    if (i > len) or (S[i] = #10) then
    begin
      line := Copy(S, start, i - start);
      if (Length(line) > 0) and (line[Length(line)] = #13) then
        SetLength(line, Length(line) - 1);
      // a trailing newline does not create an empty final item
      if (i > len) and (line = '') and (Count > 0) and (start > len) then
        // nothing
      else
        Add(line);
      start := i + 1;
    end;
end;

{ Render every line, joined by LineBreak, with a trailing LineBreak when
  TrailingLineBreak is set -- exactly TStrings.Text. }
function TPhosphorStringList.TextStr: String;
var i: Integer;
begin
  Result := '';
  for i := 0 to Count - 1 do
  begin
    Result := Result + Items[i];
    if i < Count - 1 then Result := Result + LineBreak
    else if TrailingLineBreak then Result := Result + LineBreak;
  end;
end;

procedure TPhosphorStringList.SetCommaText(const S: String);
var start, i, len: Integer;
begin
  Clear();
  if S = '' then Exit;   // empty text is an empty list (matches delimited/Delphi)
  len := Length(S);
  start := 1;
  for i := 1 to len + 1 do
    if (i > len) or (S[i] = ',') then
    begin
      Add(Copy(S, start, i - start));
      start := i + 1;
    end;
end;

function TPhosphorStringList.CommaTextStr: String;
var i: Integer;
begin
  Result := '';
  for i := 0 to Count - 1 do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + Items[i];
  end;
end;

{ Join with Delimiter, quoting a field (with QuoteChar, doubling embedded quotes)
  when it is empty, holds the delimiter or a quote, or -- unless StrictDelimiter
  -- holds whitespace. This is the render half of TStrings.DelimitedText. }
function TPhosphorStringList.GetDelimitedText: String;
var i: Integer; f: String;

  function NeedsQuote(const s: String): Boolean;
  var j: Integer;
  begin
    if s = '' then Exit(True);
    for j := 1 to Length(s) do
      if (s[j] = Delimiter) or (s[j] = QuoteChar) or
         ((not StrictDelimiter) and (s[j] <= ' ')) then
        Exit(True);
    Result := False;
  end;

begin
  Result := '';
  for i := 0 to Count - 1 do
  begin
    if i > 0 then Result := Result + Delimiter;
    f := Items[i];
    if NeedsQuote(f) then
      Result := Result + QuoteChar +
                StringReplace(f, QuoteChar, QuoteChar + QuoteChar, [rfReplaceAll]) +
                QuoteChar
    else
      Result := Result + f;
  end;
end;

{ Parse S into fields on Delimiter, honouring QuoteChar (with doubled quotes as an
  escape). When not StrictDelimiter, whitespace around a field is skipped. The
  read half of TStrings.DelimitedText. }
procedure TPhosphorStringList.SetDelimitedText(const S: String);
var i, n, fk: Integer; field: String; fb: RawByteString;
begin
  Clear();
  n := Length(S);
  i := 1;
  if n = 0 then Exit;
  while True do
  begin
    if not StrictDelimiter then
      while (i <= n) and (S[i] <> Delimiter) and (S[i] <= ' ') do Inc(i);
    // Build each field by INDEXED writes into a RawByteString (it can never be
    // longer than the rest of the input). Appending byte by byte re-encodes any
    // byte >= 128 through the UTF-8 codepage and lands it as '?' -- this splitter
    // corrupted high bytes while its commatext sibling, which uses Copy, did not.
    if n - i + 1 > 0 then SetLength(fb, n - i + 1) else SetLength(fb, 0);
    fk := 0;
    if (i <= n) and (S[i] = QuoteChar) then
    begin
      Inc(i);
      while i <= n do
      begin
        if S[i] = QuoteChar then
        begin
          if (i < n) and (S[i + 1] = QuoteChar) then
          begin Inc(fk); fb[fk] := QuoteChar; Inc(i, 2); end
          else begin Inc(i); Break; end;
        end
        else begin Inc(fk); fb[fk] := S[i]; Inc(i); end;
      end;
    end
    else
      while (i <= n) and (S[i] <> Delimiter) and
            (StrictDelimiter or (S[i] > ' ')) do
      begin Inc(fk); fb[fk] := S[i]; Inc(i); end;
    SetLength(fb, fk);
    field := fb;
    if not StrictDelimiter then
      while (i <= n) and (S[i] <> Delimiter) and (S[i] <= ' ') do Inc(i);
    Add(field);
    if (i <= n) and (S[i] = Delimiter) then Inc(i) else Break;
  end;
end;

function TPhosphorStringList.IndexOf(const S: String): Integer;
var i: Integer;
begin
  for i := 0 to Count - 1 do
    if Items[i] = S then Exit(i);
  Result := -1;
end;

{ Binary search -- correct only on a sorted list. On an unsorted one it may miss
  items that are present (that is the documented trap that separates it from
  IndexOf); it never raises. }
function TPhosphorStringList.Find(const S: String): Integer;
var lo, hi, mid, c: Integer;
begin
  lo := 0; hi := Count - 1;
  while lo <= hi do
  begin
    mid := (lo + hi) div 2;
    c := CompareStr(Items[mid], S);
    if c = 0 then Exit(mid)
    else if c < 0 then lo := mid + 1
    else hi := mid - 1;
  end;
  Result := -1;
end;

function TPhosphorStringList.IndexOfName(const AName: String): Integer;
var i, p: Integer;
begin
  for i := 0 to Count - 1 do
  begin
    p := Pos(NameValueSeparator, Items[i]);
    if (p > 0) and (Copy(Items[i], 1, p - 1) = AName) then Exit(i);
  end;
  Result := -1;
end;

function TPhosphorStringList.ValueOf(const AName: String): String;
var idx, p: Integer;
begin
  Result := '';
  idx := IndexOfName(AName);
  if idx < 0 then Exit;
  p := Pos(NameValueSeparator, Items[idx]);
  Result := Copy(Items[idx], p + 1, MaxInt);
end;

procedure TPhosphorStringList.SetValue(const AName, AValue: String);
var idx: Integer;
begin
  idx := IndexOfName(AName);
  if idx >= 0 then Items[idx] := AName + NameValueSeparator + AValue
  else Add(AName + NameValueSeparator + AValue);
end;

function TPhosphorStringList.NameAt(AZero: Integer): String;
var p: Integer;
begin
  p := Pos(NameValueSeparator, Items[AZero]);
  if p > 0 then Result := Copy(Items[AZero], 1, p - 1) else Result := '';
end;

function TPhosphorStringList.ValueAt(AZero: Integer): String;
var p: Integer;
begin
  p := Pos(NameValueSeparator, Items[AZero]);
  if p > 0 then Result := Copy(Items[AZero], p + 1, MaxInt) else Result := '';
end;

{ Replace the value half of a name=value line, keeping its name. }
procedure TPhosphorStringList.SetValueAt(AZero: Integer; const AValue: String);
begin
  Items[AZero] := NameAt(AZero) + NameValueSeparator + AValue;
end;

function TPhosphorStringList.EqualsList(AOther: TPhosphorStringList): Boolean;
var i: Integer;
begin
  if AOther = nil then Exit(False);
  if Count <> AOther.Count then Exit(False);
  for i := 0 to Count - 1 do
    if Items[i] <> AOther.Items[i] then Exit(False);
  Result := True;
end;

{ Capacity is the allocated slack, so it is exactly the backing array's length --
  a real allocation hint, not a bookkeeping integer. Setting it grows the array
  (never below the live Count, which would discard items). }
function TPhosphorStringList.CapacityGet: Integer;
begin
  Result := Length(Items);
end;

procedure TPhosphorStringList.CapacitySet(N: Integer);
begin
  if N < Count then N := Count;
  SetLength(Items, N);
end;

// --- library functions ------------------------------------------------------
function GetList(const V: TValue; out L: TPhosphorStringList; out Err: TPhosphorError): Boolean;
begin
  L := nil;
  if (V.Kind <> vkHandle) or (not IsHandle(V.Hnd)) or (not (HandleObj(V.Hnd) is TPhosphorStringList)) then
  begin
    Err := MakeError(peRuntime, 'not a valid string list handle');
    Exit(False);
  end;
  L := TPhosphorStringList(HandleObj(V.Hnd));
  Err := NoError();
  Result := True;
end;

function GetBytes(const V: TValue; out B: TPhosphorBytes; out Err: TPhosphorError): Boolean;
begin
  B := nil;
  if (V.Kind <> vkHandle) or (not IsHandle(V.Hnd)) or (not (HandleObj(V.Hnd) is TPhosphorBytes)) then
  begin
    Err := MakeError(peRuntime, 'not a valid byte-buffer handle');
    Exit(False);
  end;
  B := TPhosphorBytes(HandleObj(V.Hnd));
  Err := NoError();
  Result := True;
end;

function CheckIndex(L: TPhosphorStringList; AOneBased: Int64; AAllowAppend: Boolean;
                    out AZero: Integer; out Err: TPhosphorError): Boolean;
var hi: Int64;
begin
  AZero := AOneBased - 1;
  if AAllowAppend then hi := L.Count + 1 else hi := L.Count;
  if (AOneBased < 1) or (AOneBased > hi) then
  begin
    Err := MakeError(peRuntime, Format('string list index %d out of bounds 1..%d',
      [AOneBased, hi]));
    Exit(False);
  end;
  Err := NoError();
  Result := True;
end;

function FirstCharOr(const S: String; ADefault: Char): Char;
begin
  if Length(S) > 0 then Result := S[1] else Result := ADefault;
end;

{ Bytes a save would write: an optional UTF-8 BOM before the rendered text. }
function RenderForSave(L: TPhosphorStringList): String;
begin
  Result := L.TextStr();
  if L.WriteBOM then Result := Utf8Bom + Result;
end;

{ Set a list from a text blob, dropping a leading UTF-8 BOM a save may have put
  there. Returns the line count. }
function LoadFromText(L: TPhosphorStringList; const AText: String): Integer;
var s: String;
begin
  s := AText;
  if (Length(s) >= 3) and (Copy(s, 1, 3) = Utf8Bom) then Delete(s, 1, 3);
  L.SetText(s);
  Result := L.Count;
end;

// --- raw file text (own, so the library reaches no host unit) ---------------
function SaveTextToFile(const APath, AText: String): Boolean;
var fs: TFileStream;
begin
  Result := False;
  try
    fs := TFileStream.Create(APath, fmCreate);
    try
      if Length(AText) > 0 then fs.WriteBuffer(AText[1], Length(AText));
    finally fs.Free; end;
    Result := True;
  except Result := False; end;
end;

function LoadTextFromFile(const APath: String; out AText: String): Boolean;
var fs: TFileStream; len: Int64;
begin
  AText := ''; Result := False;
  if not FileExists(APath) then Exit;
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      len := fs.Size;
      SetLength(AText, len);
      if len > 0 then fs.ReadBuffer(AText[1], len);
    finally fs.Free; end;
    Result := True;
  except Result := False; end;
end;

// --- construction / basic list ops ------------------------------------------
function t_strings_new(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValHandle(RegisterHandle(TPhosphorStringList.Create())); end;

function t_strings_count(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if GetList(Args[0], l, Err) then Result := ValInt(l.Count);
end;

function t_strings_add(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValInt(l.AddIndexed(Args[1].Str) + 1);   // 1-based index the item took
end;

function t_strings_append(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.AddIndexed(Args[1].Str);
  Result := ValInt(l.Count);
end;

function t_strings_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; z: Integer;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[1])), False, z, Err) then Exit;
  Result := ValStr(l.Items[z]);
end;

function t_strings_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; z: Integer;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[1])), False, z, Err) then Exit;
  l.Items[z] := Args[2].Str;
  Result := ValInt(1);
end;

function t_strings_indexof(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; i: Integer;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  i := l.IndexOf(Args[1].Str);
  if i >= 0 then Result := ValInt(i + 1) else Result := ValInt(0);  // 1-based, 0 absent
end;

function t_strings_insert(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; z: Integer;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[1])), True, z, Err) then Exit;
  l.InsertAt(z, Args[2].Str);
  Result := ValInt(l.Count);
end;

function t_strings_delete(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; z: Integer;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[1])), False, z, Err) then Exit;
  l.DeleteAt(z);
  Result := ValInt(l.Count);
end;

function t_strings_exchange(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; za, zb: Integer;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[1])), False, za, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[2])), False, zb, Err) then Exit;
  l.Exchange(za, zb);
  Result := ValInt(1);
end;

function t_strings_move(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; zf, zt: Integer;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[1])), False, zf, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[2])), False, zt, Err) then Exit;
  l.MoveItem(zf, zt);
  Result := ValInt(1);
end;

function t_strings_sort(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.Sort();
  Result := ValInt(1);
end;

function t_strings_clear(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.Clear();
  Result := ValInt(1);
end;

function t_strings_find(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; i: Integer;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  i := l.Find(Args[1].Str);
  if i >= 0 then Result := ValInt(i + 1) else Result := ValInt(0);  // 1-based, 0 absent
end;

function t_strings_equals(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a, b: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], a, Err) then Exit;
  if not GetList(Args[1], b, Err) then Exit;
  Result := ValInt(Ord(a.EqualsList(b)));
end;

function t_strings_free(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TObject;
begin
  // Lenient by design: a stale/invalid handle is reported as 0, never an error,
  // so a program can free defensively and free-twice is answered rather than raised.
  // But it frees only what it owns -- a string list, or the byte buffer it can load
  // from and save to. It used to free ANY handle, so a mistyped strings_free(a@)
  // silently destroyed an array, dict or index (arr_free type-checks; this did not).
  Err := NoError();
  Result := ValInt(0);
  if (Args[0].Kind <> vkHandle) or (not IsHandle(Args[0].Hnd)) then Exit;
  o := HandleObj(Args[0].Hnd);
  if not ((o is TPhosphorStringList) or (o is TPhosphorBytes)) then Exit;
  if FreeHandle(Args[0].Hnd) then Result := ValInt(1);
end;

// --- capacity ---------------------------------------------------------------
function t_strings_capacity_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValInt(l.CapacityGet());
end;

function t_strings_capacity_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.CapacitySet(Round(AsDouble(Args[1])));
  Result := ValInt(l.CapacityGet());
end;

// --- text (get/set) ---------------------------------------------------------
function t_strings_text(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.SetText(Args[1].Str);
  Result := ValInt(l.Count);
end;

function t_strings_text_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValStr(l.TextStr());
end;

// --- comma text (get/set) ---------------------------------------------------
function t_strings_commatext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.SetCommaText(Args[1].Str);
  Result := ValInt(l.Count);
end;

function t_strings_commatext_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValStr(l.CommaTextStr());
end;

// --- delimited text and its characters --------------------------------------
function t_strings_delimitedtext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.SetDelimitedText(Args[1].Str);
  Result := ValInt(l.Count);
end;

function t_strings_delimitedtext_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValStr(l.GetDelimitedText());
end;

function t_strings_delimiter_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.Delimiter := FirstCharOr(Args[1].Str, ',');
  Result := ValInt(1);
end;

function t_strings_delimiter_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValStr(l.Delimiter);
end;

function t_strings_quotechar_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.QuoteChar := FirstCharOr(Args[1].Str, '"');
  Result := ValInt(1);
end;

function t_strings_quotechar_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValStr(l.QuoteChar);
end;

function t_strings_strictdelimiter_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.StrictDelimiter := AsDouble(Args[1]) <> 0;
  Result := ValInt(1);
end;

function t_strings_strictdelimiter_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValInt(Ord(l.StrictDelimiter));
end;

// --- name/value machinery ---------------------------------------------------
function t_strings_values_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('');
  if GetList(Args[0], l, Err) then Result := ValStr(l.ValueOf(Args[1].Str));
end;

function t_strings_values_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.SetValue(Args[1].Str, Args[2].Str);
  Result := ValInt(1);
end;

function t_strings_valuefromindex_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; z: Integer;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[1])), False, z, Err) then Exit;
  Result := ValStr(l.ValueAt(z));
end;

function t_strings_valuefromindex_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; z: Integer;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[1])), False, z, Err) then Exit;
  l.SetValueAt(z, Args[2].Str);
  Result := ValInt(1);
end;

function t_strings_names(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; z: Integer;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[1])), False, z, Err) then Exit;
  Result := ValStr(l.NameAt(z));
end;

// keynames$ is the name half of the pair at an index -- the same reading as
// names$, kept as its own spelling because the reference exposes both.
function t_strings_keynames(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; z: Integer;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[1])), False, z, Err) then Exit;
  Result := ValStr(l.NameAt(z));
end;

function t_strings_indexofname(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; i: Integer;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  i := l.IndexOfName(Args[1].Str);
  if i >= 0 then Result := ValInt(i + 1) else Result := ValInt(0);
end;

function t_strings_namevalueseparator_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('=');
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValStr(l.NameValueSeparator);
end;

function t_strings_namevalueseparator_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.NameValueSeparator := FirstCharOr(Args[1].Str, '=');
  Result := ValInt(1);
end;

// --- case sensitivity and duplicates policy ---------------------------------
function t_strings_casesensitive_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.CaseSensitive := AsDouble(Args[1]) <> 0;
  Result := ValInt(1);
end;

function t_strings_casesensitive_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValInt(Ord(l.CaseSensitive));
end;

function t_strings_duplicates_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.Duplicates := LowerCase(Args[1].Str);
  Result := ValInt(1);
end;

function t_strings_duplicates_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('ignore');
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValStr(l.Duplicates);
end;

// --- sorted (already existed) -----------------------------------------------
function t_strings_sorted_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  if l.Sorted then Result := ValInt(1) else Result := ValInt(0);
end;

function t_strings_sorted_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.Sorted := AsDouble(Args[1]) <> 0;
  if l.Sorted then l.Sort();   // enabling it orders whatever is already there
  Result := ValInt(1);
end;

// --- line breaks and BOM ----------------------------------------------------
function t_strings_linebreak_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.LineBreak := Args[1].Str;
  Result := ValInt(1);
end;

function t_strings_linebreak_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValStr(l.LineBreak);
end;

function t_strings_trailinglinebreak_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.TrailingLineBreak := AsDouble(Args[1]) <> 0;
  Result := ValInt(1);
end;

function t_strings_trailinglinebreak_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValInt(Ord(l.TrailingLineBreak));
end;

function t_strings_writebom_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.WriteBOM := AsDouble(Args[1]) <> 0;
  Result := ValInt(1);
end;

function t_strings_writebom_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValInt(Ord(l.WriteBOM));
end;

// --- encodings --------------------------------------------------------------
// A fresh list answers an encoding (the default one a save would use) WITHOUT
// dereferencing a nil TEncoding -- the reference's access-violation trap.
function t_strings_encoding_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  if l.Encoding <> '' then Result := ValStr(l.Encoding)
  else Result := ValStr(l.DefaultEncoding);
end;

function t_strings_defaultencoding_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValStr(l.DefaultEncoding);
end;

function t_strings_defaultencoding_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.DefaultEncoding := Args[1].Str;
  Result := ValInt(1);
end;

// --- change handlers (NAMES only; firing is a host concern, phase 2) ---------
function t_strings_onchange_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.OnChangeName := Args[1].Str;
  Result := ValInt(1);
end;

function t_strings_onchange_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValStr(l.OnChangeName);
end;

function t_strings_onchanging_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.OnChangingName := Args[1].Str;
  Result := ValInt(1);
end;

function t_strings_onchanging_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValStr(l.OnChangingName);
end;

// --- batched updates --------------------------------------------------------
function t_strings_beginupdate(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  Inc(l.UpdateCount);
  Result := ValInt(l.UpdateCount);
end;

function t_strings_endupdate(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  if l.UpdateCount > 0 then Dec(l.UpdateCount);
  Result := ValInt(l.UpdateCount);
end;

// --- files (return the LINE COUNT, per the reference pages) ------------------
function t_strings_savetofile(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  if Length(Args) >= 3 then l.Encoding := Args[2].Str else l.Encoding := l.DefaultEncoding;
  SaveTextToFile(Args[1].Str, RenderForSave(l));
  Result := ValInt(l.Count);
end;

function t_strings_loadfromfile(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; s: String;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  if Length(Args) >= 3 then l.Encoding := Args[2].Str else l.Encoding := l.DefaultEncoding;
  LoadTextFromFile(Args[1].Str, s);
  Result := ValInt(LoadFromText(l, s));
end;

// --- streams (through the byte-buffer handle IoLib hands out) ----------------
function t_strings_loadfromstream(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; b: TPhosphorBytes;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  if not GetBytes(Args[1], b, Err) then Exit;
  if Length(Args) >= 3 then l.Encoding := Args[2].Str else l.Encoding := l.DefaultEncoding;
  Result := ValInt(LoadFromText(l, b.Data));
end;

function t_strings_savetostream(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; b: TPhosphorBytes;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  if not GetBytes(Args[1], b, Err) then Exit;
  if Length(Args) >= 3 then l.Encoding := Args[2].Str else l.Encoding := l.DefaultEncoding;
  b.Data := RenderForSave(l);
  Result := ValInt(l.Count);
end;

procedure RegisterStrListFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('strings@:',            @t_strings_new);
  Reg.Add('strings_count:@',      @t_strings_count);
  Reg.Add('strings_add:@$',       @t_strings_add);
  Reg.Add('strings_append:@$',    @t_strings_append);
  Reg.Add('strings_strings$:@n',  @t_strings_get);
  Reg.Add('strings_strings:@n$',  @t_strings_set);
  Reg.Add('strings_indexof:@$',   @t_strings_indexof);
  Reg.Add('strings_find:@$',      @t_strings_find);
  Reg.Add('strings_equals:@@',    @t_strings_equals);
  Reg.Add('strings_insert:@n$',   @t_strings_insert);
  Reg.Add('strings_delete:@n',    @t_strings_delete);
  Reg.Add('strings_exchange:@nn', @t_strings_exchange);
  Reg.Add('strings_move:@nn',     @t_strings_move);
  Reg.Add('strings_sort:@',       @t_strings_sort);
  Reg.Add('strings_sorted:@',     @t_strings_sorted_get);
  Reg.Add('strings_sorted:@n',    @t_strings_sorted_set);
  Reg.Add('strings_clear:@',      @t_strings_clear);
  Reg.Add('strings_free:@',       @t_strings_free);

  Reg.Add('strings_capacity:@',   @t_strings_capacity_get);
  Reg.Add('strings_capacity:@n',  @t_strings_capacity_set);

  Reg.Add('strings_text:@$',      @t_strings_text);
  Reg.Add('strings_text$:@',      @t_strings_text_get);
  Reg.Add('strings_commatext:@$', @t_strings_commatext);
  Reg.Add('strings_commatext$:@', @t_strings_commatext_get);

  Reg.Add('strings_delimitedtext:@$',  @t_strings_delimitedtext);
  Reg.Add('strings_delimitedtext$:@',  @t_strings_delimitedtext_get);
  Reg.Add('strings_delimiter:@$',      @t_strings_delimiter_set);
  Reg.Add('strings_delimiter$:@',      @t_strings_delimiter_get);
  Reg.Add('strings_quotechar:@$',      @t_strings_quotechar_set);
  Reg.Add('strings_quotechar$:@',      @t_strings_quotechar_get);
  Reg.Add('strings_strictdelimiter:@n', @t_strings_strictdelimiter_set);
  Reg.Add('strings_strictdelimiter:@',  @t_strings_strictdelimiter_get);

  Reg.Add('strings_values$:@$',          @t_strings_values_get);
  Reg.Add('strings_values:@$$',          @t_strings_values_set);
  Reg.Add('strings_valuefromindex$:@n',  @t_strings_valuefromindex_get);
  Reg.Add('strings_valuefromindex:@n$',  @t_strings_valuefromindex_set);
  Reg.Add('strings_names$:@n',           @t_strings_names);
  Reg.Add('strings_keynames$:@n',        @t_strings_keynames);
  Reg.Add('strings_indexofname:@$',      @t_strings_indexofname);
  Reg.Add('strings_namevalueseparator$:@',  @t_strings_namevalueseparator_get);
  Reg.Add('strings_namevalueseparator:@$',  @t_strings_namevalueseparator_set);

  Reg.Add('strings_casesensitive:@n', @t_strings_casesensitive_set);
  Reg.Add('strings_casesensitive:@',  @t_strings_casesensitive_get);
  Reg.Add('strings_duplicates:@$',    @t_strings_duplicates_set);
  Reg.Add('strings_duplicates$:@',    @t_strings_duplicates_get);

  Reg.Add('strings_linebreak:@$',        @t_strings_linebreak_set);
  Reg.Add('strings_linebreak$:@',        @t_strings_linebreak_get);
  Reg.Add('strings_trailinglinebreak:@n', @t_strings_trailinglinebreak_set);
  Reg.Add('strings_trailinglinebreak:@',  @t_strings_trailinglinebreak_get);
  Reg.Add('strings_writebom:@n',         @t_strings_writebom_set);
  Reg.Add('strings_writebom:@',          @t_strings_writebom_get);

  Reg.Add('strings_encoding$:@',            @t_strings_encoding_get);
  Reg.Add('strings_defaultencoding$:@',     @t_strings_defaultencoding_get);
  Reg.Add('strings_defaultencoding:@$',     @t_strings_defaultencoding_set);

  Reg.Add('strings_onchange:@$',    @t_strings_onchange_set);
  Reg.Add('strings_onchange$:@',    @t_strings_onchange_get);
  Reg.Add('strings_onchanging:@$',  @t_strings_onchanging_set);
  Reg.Add('strings_onchanging$:@',  @t_strings_onchanging_get);

  Reg.Add('strings_beginupdate:@',  @t_strings_beginupdate);
  Reg.Add('strings_endupdate:@',    @t_strings_endupdate);

  Reg.Add('strings_savetofile:@$$', @t_strings_savetofile);
  Reg.Add('strings_savetofile:@$',  @t_strings_savetofile);
  Reg.Add('strings_save:@$',        @t_strings_savetofile);
  Reg.Add('strings_loadfromfile:@$$', @t_strings_loadfromfile);
  Reg.Add('strings_loadfromfile:@$',  @t_strings_loadfromfile);
  Reg.Add('strings_load:@$',          @t_strings_loadfromfile);
  Reg.Add('strings_loadfromstream:@@$', @t_strings_loadfromstream);
  Reg.Add('strings_loadfromstream:@@',  @t_strings_loadfromstream);
  Reg.Add('strings_savetostream:@@$',   @t_strings_savetostream);
  Reg.Add('strings_savetostream:@@',    @t_strings_savetostream);
end;

end.
