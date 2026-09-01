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

  { A host-aware function. It receives the executing VM in addition to its
    arguments, so it can call back INTO a BASIC routine -- the seam an event
    handler or an indirect call (callfunc) needs. The VM is passed as TObject to
    keep this unit free of a dependency on PhosphorVM (which itself uses the
    registry); the package casts it to TPhosphorVM. Registered through AddHost;
    everything else stays a plain TPhosphorFunc. }
  TPhosphorHostFunc = function(AVM: TObject; const Args: array of TValue;
                               out Err: TPhosphorError): TValue;

  { What Resolve found: a plain function, or a host-aware one (never both). The VM
    passes itself to the host-aware kind and only the arguments to the plain kind. }
  TResolvedFunc = record
    Found: Boolean;
    IsHost: Boolean;
    Func: TPhosphorFunc;
    HostFunc: TPhosphorHostFunc;
  end;

  { A small hand-rolled string->func map. The registry holds a few dozen entries
    and does not need Generics.Collections (whose enumerator instantiation emits
    library-internal warnings). Linear lookup is fine at this size; swap in a
    hash if the function count ever grows large. }
  TPhosphorRegistry = class
  private
    FKeys: array of String;
    FFuncs: array of TPhosphorFunc;
    FHostFuncs: array of TPhosphorHostFunc;
    FIsHost: array of Boolean;
    FCount: Integer;
    function IndexOfKey(const AKey: String): Integer;
    function EnsureSlot(const AKey: String): Integer;
  public
    { ASignature is 'name:codes', e.g. 'assert_eq:nn'. Name is case-insensitive. }
    procedure Add(const ASignature: String; AFunc: TPhosphorFunc);
    { Same, for a host-aware function (one that calls back into BASIC). }
    procedure AddHost(const ASignature: String; AFunc: TPhosphorHostFunc);
    { Resolve by name + the actual argument kinds, widening int% -> n as needed. }
    function Resolve(const AName: String;
                     const AKinds: array of TValueKind): TResolvedFunc;
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

{ Return the index of AKey (a lowercase signature), creating an empty slot if it
  is new. The three parallel arrays grow together. }
function TPhosphorRegistry.EnsureSlot(const AKey: String): Integer;
begin
  Result := IndexOfKey(AKey);
  if Result >= 0 then Exit;
  if FCount = Length(FKeys) then
  begin
    SetLength(FKeys, (FCount + 1) * 2);
    SetLength(FFuncs, (FCount + 1) * 2);
    SetLength(FHostFuncs, (FCount + 1) * 2);
    SetLength(FIsHost, (FCount + 1) * 2);
  end;
  FKeys[FCount] := AKey;
  Result := FCount;
  Inc(FCount);
end;

procedure TPhosphorRegistry.Add(const ASignature: String; AFunc: TPhosphorFunc);
var
  idx: Integer;
begin
  idx := EnsureSlot(LowerCase(ASignature));
  FFuncs[idx] := AFunc;
  FHostFuncs[idx] := nil;
  FIsHost[idx] := False;
end;

procedure TPhosphorRegistry.AddHost(const ASignature: String; AFunc: TPhosphorHostFunc);
var
  idx: Integer;
begin
  idx := EnsureSlot(LowerCase(ASignature));
  FFuncs[idx] := nil;
  FHostFuncs[idx] := AFunc;
  FIsHost[idx] := True;
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
  const AKinds: array of TValueKind): TResolvedFunc;
var
  n, k, i, j, mask, bestPop, pop, idx, bestIdx: Integer;
  intPos: array of Integer;
  codes: array of Char;
  key, lname: String;
begin
  Result := Default(TResolvedFunc);
  bestIdx := -1;
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
        bestIdx := idx;
      end;
    end;
  end;
  if bestIdx >= 0 then
  begin
    Result.Found := True;
    Result.IsHost := FIsHost[bestIdx];
    Result.Func := FFuncs[bestIdx];
    Result.HostFunc := FHostFuncs[bestIdx];
  end;
end;

end.
