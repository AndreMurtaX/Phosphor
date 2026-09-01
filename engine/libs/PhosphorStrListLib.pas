{******************************************************************************
  Phosphor BASIC -- string-list library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  A growable list of strings as a handle object. Plan9Basic's stringlist wrapped
  a Delphi TStringList and was 0-based; Phosphor is base-1 EVERYWHERE
  (decisions.md), so every index here is 1-based and `strings_indexof` returns 0
  (not -1) when absent. Errors are RETURNED, never raised; a fabricated handle is
  rejected by GetList (IsHandle) rather than dereferenced.
******************************************************************************}
unit PhosphorStrListLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles;

type
  TPhosphorStringList = class
  public
    Items: array of String;
    Count: Integer;
    Sorted: Boolean;    // when set, AddIndexed keeps the list ordered
    procedure Add(const S: String);
    function AddIndexed(const S: String): Integer;       // 0-based index it landed at
    procedure Clear;
    procedure InsertAt(AZero: Integer; const S: String);
    procedure DeleteAt(AZero: Integer);
    procedure Exchange(A, B: Integer);
    procedure MoveItem(AFrom, ATo: Integer);
    procedure Sort;
    procedure SetText(const S: String);
    procedure SetCommaText(const S: String);
    function CommaTextStr: String;
    function IndexOf(const S: String): Integer;         // 0-based, -1 absent
    function Find(const S: String): Integer;            // binary search; needs a sorted list
    function IndexOfName(const AName: String): Integer;  // 0-based, -1 absent
    function ValueOf(const AName: String): String;
    function NameAt(AZero: Integer): String;
    function ValueAt(AZero: Integer): String;
  end;

procedure RegisterStrListFuncs(Reg: TPhosphorRegistry);

implementation

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
  Clear;
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

procedure TPhosphorStringList.SetCommaText(const S: String);
var start, i, len: Integer;
begin
  Clear;
  len := Length(S);
  start := 1;
  for i := 1 to len + 1 do
    if (i > len) or (S[i] = ',') then
    begin
      Add(Copy(S, start, i - start));
      start := i + 1;
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
    p := Pos('=', Items[i]);
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
  p := Pos('=', Items[idx]);
  Result := Copy(Items[idx], p + 1, MaxInt);
end;

function TPhosphorStringList.NameAt(AZero: Integer): String;
var p: Integer;
begin
  p := Pos('=', Items[AZero]);
  if p > 0 then Result := Copy(Items[AZero], 1, p - 1) else Result := '';
end;

function TPhosphorStringList.ValueAt(AZero: Integer): String;
var p: Integer;
begin
  p := Pos('=', Items[AZero]);
  if p > 0 then Result := Copy(Items[AZero], p + 1, MaxInt) else Result := '';
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
  Err := NoError;
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
  Err := NoError;
  Result := True;
end;

function t_strings_new(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValHandle(RegisterHandle(TPhosphorStringList.Create)); end;

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

function t_strings_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; z: Integer;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[1])), False, z, Err) then Exit;
  Result := ValStr(l.Items[z]);
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

function t_strings_sort(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.Sort;
  Result := ValInt(1);
end;

function t_strings_clear(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.Clear;
  Result := ValInt(1);
end;

function t_strings_text(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.SetText(Args[1].Str);
  Result := ValInt(l.Count);
end;

function t_strings_commatext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  l.SetCommaText(Args[1].Str);
  Result := ValInt(l.Count);
end;

function t_strings_values(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('');
  if GetList(Args[0], l, Err) then Result := ValStr(l.ValueOf(Args[1].Str));
end;

function t_strings_indexofname(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; i: Integer;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  i := l.IndexOfName(Args[1].Str);
  if i >= 0 then Result := ValInt(i + 1) else Result := ValInt(0);
end;

function t_strings_free(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  // Lenient by design: a stale/invalid handle is reported as 0, never an error,
  // so a program can free defensively and free-twice is answered rather than raised.
  Err := NoError;
  if (Args[0].Kind = vkHandle) and FreeHandle(Args[0].Hnd) then
    Result := ValInt(1)
  else
    Result := ValInt(0);
end;

function t_strings_find(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; i: Integer;
begin
  Result := ValInt(0);
  if not GetList(Args[0], l, Err) then Exit;
  i := l.Find(Args[1].Str);
  if i >= 0 then Result := ValInt(i + 1) else Result := ValInt(0);  // 1-based, 0 absent
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

function t_strings_names(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; z: Integer;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[1])), False, z, Err) then Exit;
  Result := ValStr(l.NameAt(z));
end;

function t_strings_valuefromindex(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList; z: Integer;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  if not CheckIndex(l, Round(AsDouble(Args[1])), False, z, Err) then Exit;
  Result := ValStr(l.ValueAt(z));
end;

function t_strings_namevalueseparator(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('=');
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValStr('=');   // '=' is the only separator in phase 1
end;

function t_strings_commatext_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var l: TPhosphorStringList;
begin
  Result := ValStr('');
  if not GetList(Args[0], l, Err) then Exit;
  Result := ValStr(l.CommaTextStr);
end;

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
  if l.Sorted then l.Sort;   // enabling it orders whatever is already there
  Result := ValInt(1);
end;

procedure RegisterStrListFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('strings@:',            @t_strings_new);
  Reg.Add('strings_count:@',      @t_strings_count);
  Reg.Add('strings_add:@$',       @t_strings_add);
  Reg.Add('strings_strings$:@n',  @t_strings_get);
  Reg.Add('strings_indexof:@$',   @t_strings_indexof);
  Reg.Add('strings_find:@$',      @t_strings_find);
  Reg.Add('strings_insert:@n$',   @t_strings_insert);
  Reg.Add('strings_delete:@n',    @t_strings_delete);
  Reg.Add('strings_exchange:@nn', @t_strings_exchange);
  Reg.Add('strings_move:@nn',     @t_strings_move);
  Reg.Add('strings_sort:@',       @t_strings_sort);
  Reg.Add('strings_sorted:@',     @t_strings_sorted_get);
  Reg.Add('strings_sorted:@n',    @t_strings_sorted_set);
  Reg.Add('strings_clear:@',      @t_strings_clear);
  Reg.Add('strings_free:@',       @t_strings_free);
  Reg.Add('strings_text:@$',      @t_strings_text);
  Reg.Add('strings_commatext:@$', @t_strings_commatext);
  Reg.Add('strings_commatext$:@', @t_strings_commatext_get);
  Reg.Add('strings_values$:@$',   @t_strings_values);
  Reg.Add('strings_valuefromindex$:@n', @t_strings_valuefromindex);
  Reg.Add('strings_names$:@n',    @t_strings_names);
  Reg.Add('strings_namevalueseparator$:@', @t_strings_namevalueseparator);
  Reg.Add('strings_indexofname:@$', @t_strings_indexofname);
end;

end.
