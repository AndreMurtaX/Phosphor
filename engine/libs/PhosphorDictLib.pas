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
  inherited Create();
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
  Err := NoError();
  Result := True;
end;

function MakeDict(AKind: TArrayKind): TValue;
begin
  Result := ValHandle(RegisterHandle(TPhosphorDict.Create(AKind)));
end;

function t_dict_new(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := MakeDict(akNumeric); end;
function t_sdict_new(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := MakeDict(akString); end;
function t_pdict_new(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := MakeDict(akPointer); end;

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

{ Read a key, answering AMissing when there is none. The stored value is handed
  back exactly as it was stored -- no conversion, ever -- so a mismatch surfaces
  where the value is finally used, with the language's own type error, and
  dict_typeof is how a program avoids reaching that point. }
function ReadKey(const Args: array of TValue; const AMissing: TValue;
                 out Err: TPhosphorError): TValue;
var d: TPhosphorDict; idx: Integer;
begin
  Result := AMissing;
  if not GetDict(Args[0], d, Err) then Exit;
  idx := d.IndexOf(Args[1].Str);
  if idx >= 0 then Result := d.Vals[idx];
end;

{ The legacy spelling: a missing key answers the CONTAINER's default, which is
  what dict@/sdict@/pdict@ were created for and what the oracle pins. }
function t_dict_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValInt(0);
  if not GetDict(Args[0], d, Err) then Exit;
  Result := ReadKey(Args, DefaultFor(d.Kind), Err);
end;

{ The typed spellings. Each answers ITS OWN empty value for a missing key --
  the shared reader could not, because it knew the container's kind and not the
  caller's question. }
function t_dict_get_num(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := ReadKey(Args, ValInt(0), Err); end;
function t_dict_get_str(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := ReadKey(Args, ValStr(''), Err); end;
function t_dict_get_hnd(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := ReadKey(Args, ValHandle(0), Err); end;
function t_dict_get_bool(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := ReadKey(Args, ValBool(False), Err); end;

{ dict_typeof(d@, k$) -- what does this key hold?

  The codes are the language's own five kinds in their declared order, and -1 for
  a key that is not there. A separate answer for "absent" matters: without it a
  program cannot tell an absent key from one holding a number, and dict_haskey
  would have to be asked first every single time. }
function t_dict_typeof(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict; idx: Integer;
begin
  Result := ValInt(-1);
  if not GetDict(Args[0], d, Err) then Exit;
  idx := d.IndexOf(Args[1].Str);
  if idx >= 0 then Result := ValInt(Ord(d.Vals[idx].Kind));
end;

function t_dict_typeof_name(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict; idx: Integer;
begin
  Result := ValStr('');
  if not GetDict(Args[0], d, Err) then Exit;
  idx := d.IndexOf(Args[1].Str);
  if idx < 0 then Exit;                 // absent answers "", never a kind name
  case d.Vals[idx].Kind of
    vkString: Result := ValStr('string');
    vkInt:    Result := ValStr('int');
    vkHandle: Result := ValStr('handle');
    vkBool:   Result := ValStr('bool');
  else
    Result := ValStr('number');
  end;
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
  // Answer whether anything was actually removed. It used to answer 1 for a key
  // that was never there, which is the one question this call exists to settle --
  // a mutator returns information, the rule arr_set and strings_add follow.
  if d.IndexOf(Args[1].Str) < 0 then Exit;   // absent: nothing removed, answer 0
  d.Remove(Args[1].Str);
  Result := ValInt(1);
end;

{ dict_clear@ answers the DICTIONARY, which is what the @ on its name has always
  promised and what its sibling dict_set@ has always done.

  It used to answer ValInt(1) -- both a lie about the type and a bare success
  flag, the two things this codebase treats as defects, in three characters. The
  cost was real rather than theoretical: `d@ = dict_clear@(d@)` aborted the
  program AT RUN TIME with "cannot store int into handle variable" -- the store
  is what checks the kind, so the line ran and the failure arrived only when it
  did. The one spelling a reader would guess from the name was the one that could
  not work, and the library page had to spend a paragraph apologising for it.

  Nothing is lost by dropping the 1. It was constant -- it never once said
  whether anything had been removed -- and how many entries there were is what
  dict_count answers, before the call. }
function t_dict_clear(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := Args[0];
  if not GetDict(Args[0], d, Err) then Exit;
  d.Clear();
end;

function t_dict_typename(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValStr('');
  if GetDict(Args[0], d, Err) then Result := ValStr(d.TypeName());
end;

// key at a 1-based position (insertion order)
function t_dict_key(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict; i: Integer;
begin
  Result := ValStr('');
  if not GetDict(Args[0], d, Err) then Exit;
  i := ArgI32(Args[1]) - 1;
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

  { ONE dictionary that holds anything. The storage always did -- Vals is an
    array of the engine's five-kind cell and the setter enforced nothing -- so
    these four shapes are the surface catching up with the container. An int
    needs no shape of its own: the registry widens % to n. }
  Reg.Add('dict_set@:@$n',  @t_dict_set);
  Reg.Add('dict_set@:@$$',  @t_dict_set);
  Reg.Add('dict_set@:@$@',  @t_dict_set);
  Reg.Add('dict_set@:@$?',  @t_dict_set);
  { The older spellings, kept: same container, same implementation. }
  Reg.Add('sdict_set@:@$$', @t_dict_set);
  Reg.Add('pdict_set@:@$@', @t_dict_set);

  { A function's return type comes from the suffix on its OWN name, so there can
    be no polymorphic getter -- typed getters are what the language allows, and
    each answers its own empty value for a key that is not there. }
  Reg.Add('dict_get:@$',   @t_dict_get);       // legacy: the container's default
  Reg.Add('dict_get$:@$',  @t_dict_get_str);
  Reg.Add('dict_get@:@$',  @t_dict_get_hnd);
  Reg.Add('dict_get?:@$',  @t_dict_get_bool);
  Reg.Add('dict_get%:@$',  @t_dict_get_num);
  Reg.Add('sdict_get$:@$', @t_dict_get_str);
  Reg.Add('pdict_get@:@$', @t_dict_get_hnd);
  { What a KEY holds -- the question that only exists once one dictionary can
    hold several kinds, and what makes dict_key$ useful for walking a mixed one. }
  Reg.Add('dict_typeof:@$',   @t_dict_typeof);
  Reg.Add('dict_typeof$:@$',  @t_dict_typeof_name);

  Reg.Add('dict_getdef:@$n',   @t_dict_getdef);
  Reg.Add('dict_getdef$:@$$',  @t_dict_getdef);
  Reg.Add('dict_getdef?:@$?',  @t_dict_getdef);
  Reg.Add('sdict_getdef$:@$$', @t_dict_getdef);

  Reg.Add('dict_getdef@:@$@',  @t_dict_getdef);
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
