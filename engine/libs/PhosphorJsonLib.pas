{******************************************************************************
  Phosphor BASIC -- JSON library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  A JSON value is a handle over an fpjson node. json_object@/json_array@/
  json_parse@ own their tree; json_get@ hands back a NON-owning handle onto a
  child of an already-owned tree, so ResetHandles (which frees every handle)
  frees each tree exactly once -- the owning wrapper frees the fpjson node, the
  borrowed wrapper frees nothing. Errors are RETURNED; a fabricated handle is
  rejected by GetNode (IsHandle). Array access is 1-based, like everything in
  Phosphor (the reference's JSON arrays were 0-based).
******************************************************************************}
unit PhosphorJsonLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, fpjson, jsonparser,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles;

procedure RegisterJsonFuncs(Reg: TPhosphorRegistry);

implementation

type
  { Wraps one fpjson node. Owns=True for a root built or parsed here; Owns=False
    for a child handed out by json_get@ (its node belongs to the parent tree). }
  TPhosphorJson = class
    Node: TJSONData;
    Owns: Boolean;
    destructor Destroy; override;
  end;

destructor TPhosphorJson.Destroy;
begin
  if Owns and (Node <> nil) then Node.Free;
  inherited Destroy;
end;

function RegJson(N: TJSONData; AOwns: Boolean): TValue;
var w: TPhosphorJson;
begin
  w := TPhosphorJson.Create;
  w.Node := N;
  w.Owns := AOwns;
  Result := ValHandle(RegisterHandle(w));
end;

function GetNode(const V: TValue; out N: TJSONData; out Err: TPhosphorError): Boolean;
begin
  N := nil;
  if (V.Kind <> vkHandle) or (not IsHandle(V.Hnd)) or (not (HandleObj(V.Hnd) is TPhosphorJson)) then
  begin
    Err := MakeError(peRuntime, 'not a valid json handle');
    Exit(False);
  end;
  N := TPhosphorJson(HandleObj(V.Hnd)).Node;
  Err := NoError;
  Result := True;
end;

function GetObj(const V: TValue; out O: TJSONObject; out Err: TPhosphorError): Boolean;
var n: TJSONData;
begin
  O := nil;
  if not GetNode(V, n, Err) then Exit(False);
  if not (n is TJSONObject) then
  begin
    Err := MakeError(peRuntime, 'json value is not an object');
    Exit(False);
  end;
  O := TJSONObject(n);
  Result := True;
end;

function GetArr(const V: TValue; out A: TJSONArray; out Err: TPhosphorError): Boolean;
var n: TJSONData;
begin
  A := nil;
  if not GetNode(V, n, Err) then Exit(False);
  if not (n is TJSONArray) then
  begin
    Err := MakeError(peRuntime, 'json value is not an array');
    Exit(False);
  end;
  A := TJSONArray(n);
  Result := True;
end;

function NumNode(d: Double): TJSONData;
begin
  if (Frac(d) = 0) and (Abs(d) < 9.2e18) then Result := TJSONIntegerNumber.Create(Round(d))
  else Result := TJSONFloatNumber.Create(d);
end;

procedure SetMember(O: TJSONObject; const K: String; V: TJSONData);
var idx: Integer;
begin
  idx := O.IndexOfName(K);
  if idx >= 0 then O.Delete(idx);
  O.Add(K, V);
end;

function NumVal(N: TJSONData): TValue;
begin
  if N.JSONType = jtNumber then
  begin
    if TJSONNumber(N).NumberType = ntInteger then Result := ValInt(N.AsInt64)
    else Result := ValDouble(N.AsFloat);
  end
  else
    Result := ValDouble(N.AsFloat);
end;

// --- constructors -----------------------------------------------------------
function t_json_object(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := RegJson(TJSONObject.Create, True); end;

function t_json_array(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := RegJson(TJSONArray.Create, True); end;

function t_json_parse(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TJSONData;
begin
  Result := ValInt(0);
  d := nil;
  try
    d := GetJSON(Args[0].Str);
  except
    on E: Exception do
    begin
      Err := MakeError(peRuntime, 'invalid json: ' + E.Message);
      Exit;
    end;
  end;
  Err := NoError;
  Result := RegJson(d, True);
end;

// --- object mutation --------------------------------------------------------
function t_json_setn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  SetMember(o, Args[1].Str, NumNode(AsDouble(Args[2])));
  Result := Args[0];
end;
function t_json_sets(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  SetMember(o, Args[1].Str, TJSONString.Create(Args[2].Str));
  Result := Args[0];
end;
function t_json_setb(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  SetMember(o, Args[1].Str, TJSONBoolean.Create(AsDouble(Args[2]) <> 0));
  Result := Args[0];
end;
function t_json_remove(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; idx: Integer;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  idx := o.IndexOfName(Args[1].Str);
  if idx >= 0 then o.Delete(idx);
  Result := Args[0];
end;

// --- object read ------------------------------------------------------------
function t_json_getn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; m: TJSONData;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  m := o.Find(Args[1].Str);
  if m <> nil then Result := NumVal(m)
  else if Length(Args) >= 3 then Result := Args[2];
end;
function t_json_gets(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; m: TJSONData;
begin
  Result := ValStr('');
  if not GetObj(Args[0], o, Err) then Exit;
  m := o.Find(Args[1].Str);
  if m <> nil then Result := ValStr(m.AsString)
  else if Length(Args) >= 3 then Result := Args[2];
end;
function t_json_getb(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; m: TJSONData;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  m := o.Find(Args[1].Str);
  if (m <> nil) and (m.JSONType = jtBoolean) then Result := ValInt(Ord(m.AsBoolean));
end;
function t_json_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; m: TJSONData;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  m := o.Find(Args[1].Str);
  if m = nil then
  begin
    Err := MakeError(peRuntime, 'no such json member');
    Exit;
  end;
  Result := RegJson(m, False);   // borrowed: belongs to the parent tree
end;
function t_json_has(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  Result := ValInt(Ord(o.IndexOfName(Args[1].Str) >= 0));
end;
function t_json_count(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  Result := ValInt(o.Count);
end;

// --- array mutation and read ------------------------------------------------
function t_json_pushn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  a.Add(NumNode(AsDouble(Args[1])));
  Result := Args[0];
end;
function t_json_pushs(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  a.Add(Args[1].Str);
  Result := Args[0];
end;
function t_json_len(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  Result := ValInt(a.Count);
end;
function ArrItem(const Args: array of TValue; out A: TJSONArray; out Z: Integer; out Err: TPhosphorError): Boolean;
begin
  Z := 0;
  if not GetArr(Args[0], A, Err) then Exit(False);
  Z := Round(AsDouble(Args[1])) - 1;   // 1-based -> 0-based
  if (Z < 0) or (Z >= A.Count) then
  begin
    Err := MakeError(peRuntime, Format('json array index %d out of bounds 1..%d',
      [Z + 1, A.Count]));
    Exit(False);
  end;
  Result := True;
end;
function t_json_itemn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray; z: Integer;
begin
  Result := ValInt(0);
  if not ArrItem(Args, a, z, Err) then Exit;
  Result := NumVal(a.Items[z]);
end;
function t_json_items(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray; z: Integer;
begin
  Result := ValStr('');
  if not ArrItem(Args, a, z, Err) then Exit;
  Result := ValStr(a.Items[z].AsString);
end;

// --- type introspection -----------------------------------------------------
function t_json_isobj(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData;
begin
  Result := ValInt(0);
  if not GetNode(Args[0], n, Err) then Exit;
  Result := ValInt(Ord(n.JSONType = jtObject));
end;
function t_json_isarr(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData;
begin
  Result := ValInt(0);
  if not GetNode(Args[0], n, Err) then Exit;
  Result := ValInt(Ord(n.JSONType = jtArray));
end;
function t_json_typename(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData; s: String;
begin
  Result := ValStr('');
  if not GetNode(Args[0], n, Err) then Exit;
  case n.JSONType of
    jtObject:  s := 'object';
    jtArray:   s := 'array';
    jtNumber:  s := 'number';
    jtString:  s := 'string';
    jtBoolean: s := 'boolean';
    jtNull:    s := 'null';
  else
    s := 'unknown';
  end;
  Result := ValStr(s);
end;

// --- dotted path ------------------------------------------------------------
function NavPath(Root: TJSONData; const Path: String; out Node: TJSONData): Boolean;
var start, i, plen: Integer; part: String; cur: TJSONData;
begin
  cur := Root;
  plen := Length(Path);
  start := 1;
  for i := 1 to plen + 1 do
    if (i > plen) or (Path[i] = '.') then
    begin
      part := Copy(Path, start, i - start);
      if not (cur is TJSONObject) then Exit(False);
      cur := TJSONObject(cur).Find(part);
      if cur = nil then Exit(False);
      start := i + 1;
    end;
  Node := cur;
  Result := True;
end;
function t_json_paths(const Args: array of TValue; out Err: TPhosphorError): TValue;
var root, n: TJSONData;
begin
  Result := ValStr('');
  if not GetNode(Args[0], root, Err) then Exit;
  if NavPath(root, Args[1].Str, n) then Result := ValStr(n.AsString);
end;
function t_json_pathn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var root, n: TJSONData;
begin
  Result := ValInt(0);
  if not GetNode(Args[0], root, Err) then Exit;
  if NavPath(root, Args[1].Str, n) then Result := NumVal(n);
end;

// --- serialize --------------------------------------------------------------
function t_json_stringify(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData;
begin
  Result := ValStr('');
  if not GetNode(Args[0], n, Err) then Exit;
  Result := ValStr(n.AsJSON);
end;

procedure RegisterJsonFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('json_object@:',     @t_json_object);
  Reg.Add('json_array@:',      @t_json_array);
  Reg.Add('json_parse@:$',     @t_json_parse);
  Reg.Add('json_setn@:@$n',    @t_json_setn);
  Reg.Add('json_sets@:@$$',    @t_json_sets);
  Reg.Add('json_setb@:@$n',    @t_json_setb);
  Reg.Add('json_remove@:@$',   @t_json_remove);
  Reg.Add('json_getn:@$',      @t_json_getn);
  Reg.Add('json_getn:@$n',     @t_json_getn);
  Reg.Add('json_gets$:@$',     @t_json_gets);
  Reg.Add('json_gets$:@$$',    @t_json_gets);
  Reg.Add('json_getb:@$',      @t_json_getb);
  Reg.Add('json_get@:@$',      @t_json_get);
  Reg.Add('json_has:@$',       @t_json_has);
  Reg.Add('json_count:@',      @t_json_count);
  Reg.Add('json_pushn@:@n',    @t_json_pushn);
  Reg.Add('json_pushs@:@$',    @t_json_pushs);
  Reg.Add('json_len:@',        @t_json_len);
  Reg.Add('json_itemn:@n',     @t_json_itemn);
  Reg.Add('json_items$:@n',    @t_json_items);
  Reg.Add('json_isobj:@',      @t_json_isobj);
  Reg.Add('json_isarr:@',      @t_json_isarr);
  Reg.Add('json_typename$:@',  @t_json_typename);
  Reg.Add('json_paths$:@$',    @t_json_paths);
  Reg.Add('json_pathn:@$',     @t_json_pathn);
  Reg.Add('json_stringify$:@', @t_json_stringify);
end;

end.
