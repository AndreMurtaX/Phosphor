{******************************************************************************
  PhosphorNameIndex -- a name -> index map for the tables that hold a program's
  names: its globals, a function's locals, its labels, its user functions.

  EVERY ONE OF THOSE TABLES WAS A LINEAR SCAN, and each is consulted once per
  name the compiler meets -- so a program with N globals cost N^2/2 string
  compares to compile. Measured 2026-10-07 on the console host: 16 000 globals
  0.70 s, 32 000 globals 2.67 s; labels, locals and user functions doubled the
  same way (x3 to x4 per doubling of N). "Phosphor has no global cap" (docs/
  decisions.md, "No fixed global-variable cap") was true of the count and false
  of the cost. A lookup here is one hash and a short probe, whatever N is.

  The scheme is the one PhosphorRegistry already uses for signatures, and the
  same two rules hold it up: FNV-1a over the bytes (nothing interprets a byte,
  so no code page reaches it), and a power-of-two table never more than half
  full, so linear probing always reaches an empty bucket.

  It maps a key to the FIRST value put under it. Every table it replaced
  answered the first match of a front-to-back scan, and a duplicate local (a
  parameter and a `local` of one name) still resolves to the slot it always did.
******************************************************************************}
unit PhosphorNameIndex;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

type
  TNameIndex = class
  private
    FKeys: array of String;      // entry -> key
    FVals: array of Integer;     // entry -> value
    FCount: Integer;
    FSlots: array of Integer;    // bucket -> entry + 1; 0 is an empty bucket
    FMask: Integer;
    procedure Place(AEntry: Integer);
    procedure Grow;
  public
    { -1 when AKey was never put. }
    function Find(const AKey: String): Integer;
    { Map AKey to AValue unless AKey is already mapped, in which case the first
      value stands -- see the header. }
    procedure Put(const AKey: String; AValue: Integer);
    procedure Clear;
    property Count: Integer read FCount;
  end;

implementation

{$push}{$Q-}{$R-}
function NameHash(const S: String): Cardinal;
var i: Integer;
begin
  Result := 2166136261;
  for i := 1 to Length(S) do
  begin
    Result := Result xor Cardinal(Ord(S[i]));
    Result := Result * 16777619;
  end;
end;
{$pop}

procedure TNameIndex.Place(AEntry: Integer);
var b: Integer;
begin
  b := Integer(NameHash(FKeys[AEntry]) and Cardinal(FMask));
  while FSlots[b] <> 0 do b := (b + 1) and FMask;
  FSlots[b] := AEntry + 1;
end;

{ Double the bucket table and re-place every entry. Called before an insert that
  would take it past half full, so Place always finds an empty bucket. }
procedure TNameIndex.Grow;
var n, i: Integer;
begin
  n := Length(FSlots) * 2;
  if n < 16 then n := 16;
  SetLength(FSlots, 0);
  SetLength(FSlots, n);       // a fresh dynamic array arrives zero-filled
  FMask := n - 1;
  for i := 0 to FCount - 1 do Place(i);
end;

function TNameIndex.Find(const AKey: String): Integer;
var b, e: Integer;
begin
  Result := -1;
  if FCount = 0 then Exit;
  b := Integer(NameHash(AKey) and Cardinal(FMask));
  while FSlots[b] <> 0 do
  begin
    e := FSlots[b] - 1;
    if FKeys[e] = AKey then Exit(FVals[e]);
    b := (b + 1) and FMask;
  end;
end;

procedure TNameIndex.Put(const AKey: String; AValue: Integer);
begin
  if Find(AKey) >= 0 then Exit;
  if (FCount + 1) * 2 > Length(FSlots) then Grow();
  if FCount = Length(FKeys) then
  begin
    SetLength(FKeys, (FCount + 1) * 2);
    SetLength(FVals, (FCount + 1) * 2);
  end;
  FKeys[FCount] := AKey;
  FVals[FCount] := AValue;
  Place(FCount);
  Inc(FCount);
end;

procedure TNameIndex.Clear;
begin
  FKeys := nil;
  FVals := nil;
  FSlots := nil;
  FCount := 0;
  FMask := 0;
end;

end.
