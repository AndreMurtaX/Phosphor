{******************************************************************************
  Phosphor BASIC -- handle registry and the array object

  MIT License. Copyright (c) 2026 Andre Murta.

  A handle (`@`) is an Int64 id into this registry, not a raw pointer, so a
  fabricated or stale handle is detectable (IsHandle) instead of dereferencing
  arbitrary memory -- the property Plan9Basic's HandleRegistry existed to give.
  Ids are 1-based and never reused within a run; ResetHandles frees every live
  object and is called at the start of each Run so handles never leak between
  programs.

  TPhosphorArray is the first handle-managed object: a 1-based, N-dimensional
  array of TValue whose element kind is numeric, string, or pointer (a handle).
******************************************************************************}
unit PhosphorHandles;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors;

type
  TArrayKind = (akNumeric, akString, akPointer);

  TPhosphorArray = class
  public
    Kind: TArrayKind;
    Dims: array of Int64;      // size of each dimension (all lower bounds are 1)
    Data: array of TValue;     // row-major, flat
    constructor Create(AKind: TArrayKind; const ADims: array of Int64);
    function TotalSize: Int64;
    function TypeName: String;
    // Converts 1-based per-dimension indices to a flat 0-based index; returns
    // an error (never raises) on wrong rank or out-of-bounds.
    function FlatIndex(const AIdx: array of Int64; out AFlat: Int64): TPhosphorError;
  end;

function RegisterHandle(AObj: TObject): Int64;
function HandleObj(AId: Int64): TObject;
function IsHandle(AId: Int64): Boolean;
procedure ResetHandles;

implementation

constructor TPhosphorArray.Create(AKind: TArrayKind; const ADims: array of Int64);
var
  i: Integer;
  total: Int64;
  def: TValue;
begin
  inherited Create;
  Kind := AKind;
  SetLength(Dims, Length(ADims));
  total := 1;
  for i := 0 to High(ADims) do
  begin
    Dims[i] := ADims[i];
    total := total * ADims[i];
  end;
  case AKind of
    akString:  def := ValStr('');
    akPointer: def := ValHandle(0);
  else
    def := ValDouble(0);
  end;
  SetLength(Data, total);
  for i := 0 to High(Data) do
    Data[i] := def;
end;

function TPhosphorArray.TotalSize: Int64;
var i: Integer;
begin
  Result := 1;
  for i := 0 to High(Dims) do
    Result := Result * Dims[i];
end;

function TPhosphorArray.TypeName: String;
begin
  case Kind of
    akString:  Result := 'string';
    akPointer: Result := 'pointer';
  else
    Result := 'numeric';
  end;
end;

function TPhosphorArray.FlatIndex(const AIdx: array of Int64; out AFlat: Int64): TPhosphorError;
var
  d: Integer;
begin
  AFlat := 0;
  if Length(AIdx) <> Length(Dims) then
    Exit(MakeError(peRuntime, Format('array has %d dimensions, got %d indices',
      [Length(Dims), Length(AIdx)])));
  for d := 0 to High(Dims) do
  begin
    if (AIdx[d] < 1) or (AIdx[d] > Dims[d]) then
      Exit(MakeError(peRuntime, Format('index %d out of bounds 1..%d on dimension %d',
        [AIdx[d], Dims[d], d + 1])));
    AFlat := AFlat * Dims[d] + (AIdx[d] - 1);
  end;
  Result := NoError;
end;

// --- registry ---------------------------------------------------------------
var
  GObjs: array of TObject;
  GCount: Integer;

function RegisterHandle(AObj: TObject): Int64;
begin
  if GCount = Length(GObjs) then
    SetLength(GObjs, (GCount + 1) * 2);
  GObjs[GCount] := AObj;
  Inc(GCount);
  Result := GCount;   // ids are 1-based
end;

function IsHandle(AId: Int64): Boolean;
begin
  Result := (AId >= 1) and (AId <= GCount) and (GObjs[AId - 1] <> nil);
end;

function HandleObj(AId: Int64): TObject;
begin
  if IsHandle(AId) then
    Result := GObjs[AId - 1]
  else
    Result := nil;
end;

procedure ResetHandles;
var i: Integer;
begin
  for i := 0 to GCount - 1 do
    if GObjs[i] <> nil then
      GObjs[i].Free;
  GCount := 0;
  SetLength(GObjs, 0);
end;

initialization
  GCount := 0;

finalization
  ResetHandles;

end.
