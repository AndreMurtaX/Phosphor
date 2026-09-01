{******************************************************************************
  Phosphor BASIC -- the function registry and overload resolution

  MIT License. Copyright (c) 2026 Andre Murta.

  Every function package integrates through Lib.Add('name:signature') (the ':'
  separator, decisions.md). The type-code alphabet:

    n  numeric family   -- accepts vkDouble and (by widening) vkInt
    %  integer          -- vkInt only, no widening (an exact int64)
    $  string
    @  handle
    ?  bool             -- distinct; does NOT widen to numeric
    #  is NEVER a type code (it is a file number in classic I/O)

  Overload resolution is the crux the convergence judge flagged. A call is
  resolved from the ACTUAL runtime kinds of its arguments. An int argument may
  bind to a '%' slot (exact) or an 'n' slot (widened to Double); resolution
  prefers the fewest widenings. So assert_eq(2+3,5) [int,int] -> assert_eq:nn by
  widening, while assert_int(3+4,7) [int,int] -> assert_int:%% exactly -- and the
  successful dispatch to :%% is itself the proof that 3+4 stayed an int.
******************************************************************************}
unit PhosphorRegistry;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors;

type
  TPhosphorFunc = function(const Args: array of TValue; out Err: TPhosphorError): TValue;

  { A small hand-rolled string->func map. The registry holds a few dozen entries
    and does not need Generics.Collections (whose enumerator instantiation emits
    library-internal warnings). Linear lookup is fine at this size; swap in a
    hash if the function count ever grows large. }
  TPhosphorRegistry = class
  private
    FKeys: array of String;
    FFuncs: array of TPhosphorFunc;
    FCount: Integer;
    function IndexOfKey(const AKey: String): Integer;
  public
    { ASignature is 'name:codes', e.g. 'assert_eq:nn'. Name is case-insensitive. }
    procedure Add(const ASignature: String; AFunc: TPhosphorFunc);
    { Resolve by name + the actual argument kinds, widening int% -> n as needed. }
    function Resolve(const AName: String; const AKinds: array of TValueKind;
                     out AFunc: TPhosphorFunc): Boolean;
    class function CodeOf(K: TValueKind): Char;
  end;

implementation

function TPhosphorRegistry.IndexOfKey(const AKey: String): Integer;
var
  i: Integer;
begin
  for i := 0 to FCount - 1 do
    if FKeys[i] = AKey then
      Exit(i);
  Result := -1;
end;

procedure TPhosphorRegistry.Add(const ASignature: String; AFunc: TPhosphorFunc);
var
  key: String;
  idx: Integer;
begin
  key := LowerCase(ASignature);
  idx := IndexOfKey(key);
  if idx >= 0 then
  begin
    FFuncs[idx] := AFunc;
    Exit;
  end;
  if FCount = Length(FKeys) then
  begin
    SetLength(FKeys, (FCount + 1) * 2);
    SetLength(FFuncs, (FCount + 1) * 2);
  end;
  FKeys[FCount] := key;
  FFuncs[FCount] := AFunc;
  Inc(FCount);
end;

class function TPhosphorRegistry.CodeOf(K: TValueKind): Char;
begin
  case K of
    vkInt:    Result := '%';
    vkDouble: Result := 'n';
    vkString: Result := '$';
    vkHandle: Result := '@';
    vkBool:   Result := '?';
  else
    Result := '?';
  end;
end;

function PopCount(Mask: Cardinal): Integer;
begin
  Result := 0;
  while Mask <> 0 do
  begin
    Inc(Result, Ord(Mask and 1));
    Mask := Mask shr 1;
  end;
end;

function TPhosphorRegistry.Resolve(const AName: String;
  const AKinds: array of TValueKind; out AFunc: TPhosphorFunc): Boolean;
var
  n, k, i, j, mask, bestPop, pop, idx: Integer;
  intPos: array of Integer;
  codes: array of Char;
  key, lname: String;
begin
  Result := False;
  AFunc := nil;
  intPos := nil;
  codes := nil;
  lname := LowerCase(AName);
  n := Length(AKinds);

  // Positions of int arguments (the only ones that may widen).
  SetLength(intPos, 0);
  SetLength(codes, n);
  for i := 0 to n - 1 do
  begin
    codes[i] := CodeOf(AKinds[i]);
    if AKinds[i] = vkInt then
    begin
      SetLength(intPos, Length(intPos) + 1);
      intPos[High(intPos)] := i;
    end;
  end;
  k := Length(intPos);

  bestPop := MaxInt;
  // Each mask bit widens one int position ('%' -> 'n'); prefer the fewest.
  for mask := 0 to (1 shl k) - 1 do
  begin
    for j := 0 to k - 1 do
      if (mask and (1 shl j)) <> 0 then
        codes[intPos[j]] := 'n'
      else
        codes[intPos[j]] := '%';
    key := lname + ':';
    for i := 0 to n - 1 do
      key := key + codes[i];
    idx := IndexOfKey(key);
    if idx >= 0 then
    begin
      pop := PopCount(mask);
      if pop < bestPop then
      begin
        bestPop := pop;
        AFunc := FFuncs[idx];
        Result := True;
      end;
    end;
  end;
end;

end.
