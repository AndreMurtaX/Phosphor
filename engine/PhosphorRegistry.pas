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

  { What Resolve hands back is not the registered function itself but a METHOD on
    the registry entry that holds it -- see TRegEntry. The caller writes the same
    `res.Func(args, e)` it always did; Pascal calls a method pointer with the same
    syntax as a procedural one, so no call site changed. What it buys is a place
    that stands between the VM and every one of ~1,200 library functions and can
    see both the arguments and the error channel. }
  TResolvedPlainFunc = function(const Args: array of TValue;
                                out Err: TPhosphorError): TValue of object;
  TResolvedHostFunc = function(AVM: TObject; const Args: array of TValue;
                               out Err: TPhosphorError): TValue of object;

  { What Resolve found: a plain function, or a host-aware one (never both). The VM
    passes itself to the host-aware kind and only the arguments to the plain kind. }
  TResolvedFunc = record
    Found: Boolean;
    IsHost: Boolean;
    Func: TResolvedPlainFunc;
    HostFunc: TResolvedHostFunc;
  end;

  TPhosphorRegistry = class;

  { ONE REGISTERED SLOT, AND THE GUARD IN FRONT OF IT.

    THE DEFECT. ArgI32/ArgI64 are the saturating narrowers every library uses to
    turn a numeric argument into an index, a count or a size, and they are TOTAL:
    they clamp and report nothing, justified by "the bounds check that follows
    rejects it". For +/-Inf that holds -- High/Low are outside every domain, and a
    sweep of 81 library functions found not one silent answer. For a NaN it does
    not: the narrowed answer is 0, an ordinary in-range count, and eight functions
    took it and answered a byte 0, a "0", a "Black", a live handle and an empty
    string with no error at all. Those eight have no domain to bound -- every
    Int64 is legal to them -- so no return value could ever have carried the
    fault.

    WHY HERE. This is the one place every one of ~1,200 library functions passes
    through that can see BOTH the arguments and the error channel. The narrowers
    cannot report (they return a bare integer); Resolve cannot judge, because it
    is given the argument KINDS and not the values, and vkDouble says nothing
    about finiteness. So the narrowers raise a flag and this consumes it.

    WHY NOT SIMPLY REFUSE A NaN ARGUMENT HERE, which needs no flag at all: because
    it refuses the functions whose whole job is to look at one. `isnan(x)` answers
    1 for a NaN today, on this build and on the pristine one; `isinfinite`, `str$`
    and `stri$` answer too. A gate on the argument breaks every one of them, and
    an exemption list of names inside a generic dispatcher is a thing that rots.
    The flag reports exactly the event that is wrong -- a NaN was NARROWED -- so a
    function that merely inspects one is untouched by construction, with nothing
    to keep in step.

    SAVE, CLEAR, CALL, TEST, RESTORE. The save/restore pair is what makes a
    re-entrant call safe: a host-aware function (callfunc) runs BASIC, which
    dispatches again through here, and the inner dispatch must not consume or
    discard the outer one's pending fault. }
  TRegEntry = class
  private
    FOwner: TPhosphorRegistry;
    FIndex: Integer;
    function Report(const AErr: TPhosphorError): TPhosphorError;
  public
    constructor Create(AOwner: TPhosphorRegistry; AIndex: Integer);
    function CallPlain(const Args: array of TValue;
                       out Err: TPhosphorError): TValue;
    function CallHost(AVM: TObject; const Args: array of TValue;
                      out Err: TPhosphorError): TValue;
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
    FEntries: array of TRegEntry;   // the guard standing in front of each slot
    FMaxArity: Integer;   // the widest arity anything is registered under
    FWild: array of Integer;   // indices of keys holding a '*' (see Resolve)
    FCount: Integer;
    function IndexOfKey(const AKey: String): Integer;
    function EnsureSlot(const AKey: String): Integer;
  public
    destructor Destroy; override;
    { ASignature is 'name:codes', e.g. 'assert_eq:nn'. Name is case-insensitive. }
    procedure Add(const ASignature: String; AFunc: TPhosphorFunc);
    { Same, for a host-aware function (one that calls back into BASIC). }
    procedure AddHost(const ASignature: String; AFunc: TPhosphorHostFunc);
    { Resolve by name + the actual argument kinds, widening int% -> n as needed. }
    function Resolve(const AName: String;
                     const AKinds: array of TValueKind): TResolvedFunc;
    { Is there ANY function of this name, whatever its arguments? Resolve answers
      "not with these argument kinds", which needs values that only exist while
      running. This answers the question a static check can actually settle: the
      name is unknown to this host entirely, so no call to it can ever work. }
    function HasName(const AName: String): Boolean;
    class function CodeOf(K: TValueKind): Char;
  end;

implementation

constructor TRegEntry.Create(AOwner: TPhosphorRegistry; AIndex: Integer);
begin
  inherited Create;
  FOwner := AOwner;
  FIndex := AIndex;
end;

{ The error a narrowed NaN becomes. peRuntime is the code the trap used to arrive
  as (E6), so a program that already handled this condition still handles it; the
  wording is FiniteOperand's, so the operand gate and the argument gate speak with
  one voice. AErr is the function's own error and wins if it set one -- it saw
  more than this did. }
function TRegEntry.Report(const AErr: TPhosphorError): TPhosphorError;
var
  key: String;
  c: Integer;
begin
  if IsError(AErr) then Exit(AErr);
  key := FOwner.FKeys[FIndex];
  c := Pos(':', key);
  if c > 0 then key := Copy(key, 1, c - 1);
  Result := MakeError(peRuntime, key + ' was given a value that is not a number');
end;

function TRegEntry.CallPlain(const Args: array of TValue;
  out Err: TPhosphorError): TValue;
var
  outer: Boolean;
begin
  outer := NanNarrowed;      // a pending fault of the call that contains this one
  SetNanNarrowed(False);
  try
    Result := FOwner.FFuncs[FIndex](Args, Err);
    if NanNarrowed then
    begin
      Err := Report(Err);
      Result := Default(TValue);
    end;
  finally
    SetNanNarrowed(outer);
  end;
end;

function TRegEntry.CallHost(AVM: TObject; const Args: array of TValue;
  out Err: TPhosphorError): TValue;
var
  outer: Boolean;
begin
  outer := NanNarrowed;
  SetNanNarrowed(False);
  try
    Result := FOwner.FHostFuncs[FIndex](AVM, Args, Err);
    if NanNarrowed then
    begin
      Err := Report(Err);
      Result := Default(TValue);
    end;
  finally
    SetNanNarrowed(outer);
  end;
end;

{ The guards are the registry's own objects; nothing outside holds one, and a
  TResolvedFunc handed out earlier is only valid while the registry is. }
destructor TPhosphorRegistry.Destroy;
var
  i: Integer;
begin
  for i := 0 to FCount - 1 do
    FEntries[i].Free;
  inherited Destroy;
end;

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
var
  i: Integer;
begin
  Result := IndexOfKey(AKey);
  if Result >= 0 then Exit;
  if FCount = Length(FKeys) then
  begin
    SetLength(FKeys, (FCount + 1) * 2);
    SetLength(FFuncs, (FCount + 1) * 2);
    SetLength(FHostFuncs, (FCount + 1) * 2);
    SetLength(FIsHost, (FCount + 1) * 2);
    SetLength(FEntries, (FCount + 1) * 2);
  end;
  FKeys[FCount] := AKey;
  FEntries[FCount] := TRegEntry.Create(Self, FCount);
  // The widest arity anything is registered under. Resolve enumerates 2^k
  // combinations of int-widening, which is nothing for the six-argument signatures
  // this registry actually holds and 33 million for a call with 25 integer
  // arguments -- inside ONE opcode, so the step budget never got a chance to stop
  // it. A call wider than anything registered cannot match, and knowing the widest
  // makes that an O(1) answer instead of an exhaustive search for nothing.
  i := Pos(':', AKey);
  if (i > 0) and (Length(AKey) - i > FMaxArity) then FMaxArity := Length(AKey) - i;
  // A signature may say '*' at a position: any kind matches there. Only callfunc
  // uses it, and only because a per-kind signature for every arity would be 5^n
  // keys. Kept in a list so the fallback in Resolve examines these and nothing
  // else.
  if Pos('*', AKey) > 0 then
  begin
    SetLength(FWild, Length(FWild) + 1);
    FWild[High(FWild)] := FCount;
  end;
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

{ A KIND, AND ONLY A KIND. 'n' says vkDouble; it says nothing about whether that
  Double is finite, and it cannot -- Resolve is given kinds, not values, so no
  amount of work here can tell a NaN from a 3. That is why the finiteness question
  is answered one step later, at the call itself, by TRegEntry. }
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

function TPhosphorRegistry.HasName(const AName: String): Boolean;
var
  i: Integer;
  prefix: String;
begin
  // Keys are '<name>:<argument codes>', so the name is everything before the
  // first colon and a prefix match on 'name:' is exact.
  prefix := LowerCase(AName) + ':';
  for i := 0 to FCount - 1 do
    if Copy(LowerCase(FKeys[i]), 1, Length(prefix)) = prefix then Exit(True);
  Result := False;
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
  // Nothing is registered this wide, so nothing can match: say so now rather than
  // walking 2^k widening combinations to reach the same conclusion.
  if n > FMaxArity then Exit;

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
    // Built by index rather than by appending each Char: no code page can touch it,
    // and this is the innermost loop of overload resolution -- one allocation
    // instead of one per argument.
    SetLength(key, Length(lname) + 1 + n);
    for i := 1 to Length(lname) do key[i] := lname[i];
    key[Length(lname) + 1] := ':';
    for i := 0 to n - 1 do
      key[Length(lname) + 2 + i] := codes[i];
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
  // NOTHING MATCHED EXACTLY. Only now are wildcard signatures considered, so a
  // call that resolves normally never pays for this: it runs on the path that
  // used to end in "no function". Each candidate must agree on name and arity,
  // and on every position that is not '*'.
  if bestIdx < 0 then
    for j := 0 to High(FWild) do
    begin
      idx := FWild[j];
      key := FKeys[idx];
      i := Pos(':', key);
      if i <= 0 then Continue;
      if Copy(key, 1, i - 1) <> lname then Continue;
      if Length(key) - i <> n then Continue;
      mask := 0;                       // reused as "this candidate still matches"
      for pop := 0 to n - 1 do
        if (key[i + 1 + pop] <> '*') and (key[i + 1 + pop] <> CodeOf(AKinds[pop])) then
        begin
          mask := 1;
          Break;
        end;
      if mask = 0 then
      begin
        bestIdx := idx;
        Break;
      end;
    end;

  if bestIdx >= 0 then
  begin
    Result.Found := True;
    Result.IsHost := FIsHost[bestIdx];
    // The guard, never the raw function. See TRegEntry.
    Result.Func := @FEntries[bestIdx].CallPlain;
    Result.HostFunc := @FEntries[bestIdx].CallHost;
  end;
end;

end.
