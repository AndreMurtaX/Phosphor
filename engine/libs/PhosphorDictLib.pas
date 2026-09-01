{******************************************************************************
  Phosphor BASIC -- dictionary library (a function package)

  MIT License. Copyright (c) 2026 Andre Murta.

  String-keyed maps as handle objects: dict@ (numeric values), sdict@ (string),
  pdict@ (handle/pointer). Element get/set is kind-agnostic (one implementation,
  registered under every typed name); the dict knows its own value kind. All
  errors are RETURNED, never raised, and a fabricated handle is rejected by
  GetDict (IsHandle) rather than dereferenced.
******************************************************************************}
unit PhosphorDictLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles;

type
  TPhosphorDict = class
  public
    Kind: TArrayKind;
    Keys: array of String;
    Vals: array of TValue;
    Count: Integer;
    constructor Create(AKind: TArrayKind);
    function IndexOf(const AKey: String): Integer;
    procedure SetVal(const AKey: String; const AVal: TValue);
    procedure Remove(const AKey: String);
    procedure Clear;
    function TypeName: String;
  end;

procedure RegisterDictFuncs(Reg: TPhosphorRegistry);

implementation

constructor TPhosphorDict.Create(AKind: TArrayKind);
begin
  inherited Create;
  Kind := AKind;
  Count := 0;
end;

function TPhosphorDict.IndexOf(const AKey: String): Integer;
var i: Integer;
begin
  for i := 0 to Count - 1 do
    if Keys[i] = AKey then Exit(i);
  Result := -1;
end;

procedure TPhosphorDict.SetVal(const AKey: String; const AVal: TValue);
var idx: Integer;
begin
  idx := IndexOf(AKey);
  if idx >= 0 then
  begin
    Vals[idx] := AVal;
    Exit;
  end;
  if Count = Length(Keys) then
  begin
    SetLength(Keys, (Count + 1) * 2);
    SetLength(Vals, (Count + 1) * 2);
  end;
  Keys[Count] := AKey;
  Vals[Count] := AVal;
  Inc(Count);
end;

procedure TPhosphorDict.Remove(const AKey: String);
var idx, i: Integer;
begin
  idx := IndexOf(AKey);
  if idx < 0 then Exit;
  for i := idx to Count - 2 do
  begin
    Keys[i] := Keys[i + 1];
    Vals[i] := Vals[i + 1];
  end;
  Dec(Count);
end;

procedure TPhosphorDict.Clear;
begin
  Count := 0;
end;

function TPhosphorDict.TypeName: String;
begin
  case Kind of
    akString:  Result := 'string';
    akPointer: Result := 'pointer';
  else
    Result := 'numeric';
  end;
end;

// --- library functions ------------------------------------------------------
function GetDict(const V: TValue; out D: TPhosphorDict; out Err: TPhosphorError): Boolean;
begin
  D := nil;
  if (V.Kind <> vkHandle) or (not IsHandle(V.Hnd)) or (not (HandleObj(V.Hnd) is TPhosphorDict)) then
  begin
    Err := MakeError(peRuntime, 'not a valid dictionary handle');
    Exit(False);
  end;
  D := TPhosphorDict(HandleObj(V.Hnd));
  Err := NoError;
  Result := True;
end;

function MakeDict(AKind: TArrayKind): TValue;
begin
  Result := ValHandle(RegisterHandle(TPhosphorDict.Create(AKind)));
end;

function t_dict_new(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := MakeDict(akNumeric); end;
function t_sdict_new(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := MakeDict(akString); end;
function t_pdict_new(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := MakeDict(akPointer); end;

// (handle, key$, value) -> value; returns the dict handle so it reads as a
// constructor-style call site too.
function t_dict_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := Args[0];
  if not GetDict(Args[0], d, Err) then Exit;
  d.SetVal(Args[1].Str, Args[2]);
end;

function DefaultFor(K: TArrayKind): TValue;
begin
  case K of
    akString:  Result := ValStr('');
    akPointer: Result := ValHandle(0);
  else
    Result := ValInt(0);
  end;
end;

function t_dict_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict; idx: Integer;
begin
  Result := ValInt(0);
  if not GetDict(Args[0], d, Err) then Exit;
  idx := d.IndexOf(Args[1].Str);
  if idx >= 0 then Result := d.Vals[idx] else Result := DefaultFor(d.Kind);
end;

function t_dict_getdef(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict; idx: Integer;
begin
  Result := Args[2];
  if not GetDict(Args[0], d, Err) then Exit;
  idx := d.IndexOf(Args[1].Str);
  if idx >= 0 then Result := d.Vals[idx] else Result := Args[2];
end;

function t_dict_count(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValInt(0);
  if GetDict(Args[0], d, Err) then Result := ValInt(d.Count);
end;

function t_dict_haskey(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValInt(0);
  if GetDict(Args[0], d, Err) then Result := ValInt(Ord(d.IndexOf(Args[1].Str) >= 0));
end;

function t_dict_remove(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValInt(0);
  if not GetDict(Args[0], d, Err) then Exit;
  d.Remove(Args[1].Str);
  Result := ValInt(1);
end;

function t_dict_clear(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValInt(0);
  if not GetDict(Args[0], d, Err) then Exit;
  d.Clear;
  Result := ValInt(1);
end;

function t_dict_typename(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValStr('');
  if GetDict(Args[0], d, Err) then Result := ValStr(d.TypeName);
end;

// key at a 1-based position (insertion order)
function t_dict_key(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict; i: Integer;
begin
  Result := ValStr('');
  if not GetDict(Args[0], d, Err) then Exit;
  i := Round(AsDouble(Args[1])) - 1;
  if (i < 0) or (i >= d.Count) then
  begin
    Err := MakeError(peRuntime, Format('dict index %d out of bounds 1..%d', [i + 1, d.Count]));
    Exit;
  end;
  Result := ValStr(d.Keys[i]);
end;

// value-kind code: 0 numeric, 1 string, 2 pointer
function t_dict_type(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValInt(0);
  if not GetDict(Args[0], d, Err) then Exit;
  case d.Kind of
    akString:  Result := ValInt(1);
    akPointer: Result := ValInt(2);
  else
    Result := ValInt(0);
  end;
end;

procedure RegisterDictFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('dict@:',  @t_dict_new);
  Reg.Add('sdict@:', @t_sdict_new);
  Reg.Add('pdict@:', @t_pdict_new);

  Reg.Add('dict_set@:@$n',  @t_dict_set);
  Reg.Add('sdict_set@:@$$', @t_dict_set);
  Reg.Add('pdict_set@:@$@', @t_dict_set);

  Reg.Add('dict_get:@$',   @t_dict_get);
  Reg.Add('sdict_get$:@$', @t_dict_get);
  Reg.Add('pdict_get@:@$', @t_dict_get);

  Reg.Add('dict_getdef:@$n',   @t_dict_getdef);
  Reg.Add('sdict_getdef$:@$$', @t_dict_getdef);

  Reg.Add('pdict_getdef@:@$@', @t_dict_getdef);

  Reg.Add('dict_count:@',      @t_dict_count);
  Reg.Add('dict_haskey:@$',    @t_dict_haskey);
  Reg.Add('dict_exists:@$',    @t_dict_haskey);   // alias: asks without reading
  Reg.Add('dict_remove:@$',    @t_dict_remove);
  Reg.Add('dict_clear@:@',     @t_dict_clear);
  Reg.Add('dict_typename$:@',  @t_dict_typename);
  Reg.Add('dict_key$:@n',      @t_dict_key);
  Reg.Add('dict_type:@',       @t_dict_type);
end;

end.
