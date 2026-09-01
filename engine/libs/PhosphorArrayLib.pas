{******************************************************************************
  Phosphor BASIC -- array library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  Registers the array functions through the ':' registry. Arrays are handle
  objects (TPhosphorArray, minted into the core PhosphorHandles registry):
  dim@/sdim@/pdim@ create one and return a handle; narr_*/sarr_*/parr_* and the
  bracket-sugar arr_get/arr_set read and write elements. Element get/set is
  kind-agnostic (one implementation each, registered under every typed name),
  because the array already knows its own element kind. All errors are RETURNED,
  never raised (decisions.md).

  Like Plan9Basic's engine/Libs packages, this integrates with the engine only
  through the registry; the engine registers it in TPhosphorEngine.Create.
******************************************************************************}
unit PhosphorArrayLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles;

type
  { An N-dimensional, 1-based array of TValue whose element kind is numeric,
    string, or pointer (a handle). }
  TPhosphorArray = class
  public
    Kind: TArrayKind;
    Dims: array of Int64;
    Data: array of TValue;     // row-major, flat
    constructor Create(AKind: TArrayKind; const ADims: array of Int64);
    function TotalSize: Int64;
    function TypeName: String;
    function FlatIndex(const AIdx: array of Int64; out AFlat: Int64): TPhosphorError;
  end;

procedure RegisterArrayFuncs(Reg: TPhosphorRegistry);

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

// --- library functions ------------------------------------------------------
function GetArr(const V: TValue; out A: TPhosphorArray; out Err: TPhosphorError): Boolean;
begin
  A := nil;
  if (V.Kind <> vkHandle) or (not IsHandle(V.Hnd)) or (not (HandleObj(V.Hnd) is TPhosphorArray)) then
  begin
    Err := MakeError(peRuntime, 'not a valid array handle');
    Exit(False);
  end;
  A := TPhosphorArray(HandleObj(V.Hnd));
  Err := NoError;
  Result := True;
end;

function DoDim(AKind: TArrayKind; const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  dims: array of Int64;
  i: Integer;
begin
  Err := NoError;
  Result := ValHandle(0);
  SetLength(dims, Length(Args));
  for i := 0 to High(Args) do
  begin
    dims[i] := Round(AsDouble(Args[i]));
    if dims[i] < 1 then
    begin
      Err := MakeError(peRuntime, 'array dimension must be >= 1');
      Exit;
    end;
  end;
  Result := ValHandle(RegisterHandle(TPhosphorArray.Create(AKind, dims)));
end;

function t_dim_num(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := DoDim(akNumeric, Args, Err); end;
function t_dim_str(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := DoDim(akString, Args, Err); end;
function t_dim_ptr(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := DoDim(akPointer, Args, Err); end;

// Generic element write: (handle, index..., value). The value is the last arg.
function t_arr_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  a: TPhosphorArray;
  idx: array of Int64;
  i: Integer;
  flat: Int64;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  SetLength(idx, Length(Args) - 2);
  for i := 1 to High(Args) - 1 do
    idx[i - 1] := Round(AsDouble(Args[i]));
  Err := a.FlatIndex(idx, flat);
  if IsError(Err) then Exit;
  a.Data[flat] := Args[High(Args)];
  Result := Args[High(Args)];
end;

// Generic element read: (handle, index...).
function t_arr_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  a: TPhosphorArray;
  idx: array of Int64;
  i: Integer;
  flat: Int64;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  SetLength(idx, Length(Args) - 1);
  for i := 1 to High(Args) do
    idx[i - 1] := Round(AsDouble(Args[i]));
  Err := a.FlatIndex(idx, flat);
  if IsError(Err) then Exit;
  Result := a.Data[flat];
end;

function t_ndims(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TPhosphorArray;
begin
  Result := ValInt(0);
  if GetArr(Args[0], a, Err) then Result := ValInt(Length(a.Dims));
end;

function t_lbound(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TPhosphorArray;
begin
  Result := ValInt(0);
  if GetArr(Args[0], a, Err) then Result := ValInt(1);   // arrays are 1-based
end;

function t_ubound(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TPhosphorArray; d: Integer;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  d := Round(AsDouble(Args[1]));
  if (d < 1) or (d > Length(a.Dims)) then
  begin
    Err := MakeError(peRuntime, 'ubound: no such dimension');
    Exit;
  end;
  Result := ValInt(a.Dims[d - 1]);
end;

function t_arraysize(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TPhosphorArray;
begin
  Result := ValInt(0);
  if GetArr(Args[0], a, Err) then Result := ValInt(a.TotalSize);
end;

function t_arraytype(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TPhosphorArray;
begin
  Result := ValInt(0);
  if GetArr(Args[0], a, Err) then Result := ValInt(Ord(a.Kind));  // 0 num, 1 str, 2 ptr
end;

function t_arraytypename(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TPhosphorArray;
begin
  Result := ValStr('');
  if GetArr(Args[0], a, Err) then Result := ValStr(a.TypeName);
end;

// Fabricates a raw handle value from an integer id. Used to test that libraries
// validate handles: such a handle is not in the registry, so any array/dict/etc.
// function rejects it (IsHandle is false) instead of dereferencing it.
function t_pointer(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValHandle(Round(AsDouble(Args[0])));
end;

function t_arr_free(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TPhosphorArray;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;   // rejects a fabricated handle
  FreeHandle(Args[0].Hnd);
  Result := ValInt(1);
end;

procedure RegisterArrayFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('dim@:n',    @t_dim_num);
  Reg.Add('dim@:nn',   @t_dim_num);
  Reg.Add('dim@:nnn',  @t_dim_num);
  Reg.Add('sdim@:n',   @t_dim_str);
  Reg.Add('pdim@:n',   @t_dim_ptr);

  Reg.Add('ndims:@',            @t_ndims);
  Reg.Add('lbound:@n',          @t_lbound);
  Reg.Add('ubound:@n',          @t_ubound);
  Reg.Add('arraysize:@',        @t_arraysize);
  Reg.Add('arraytype:@',        @t_arraytype);
  Reg.Add('arraytypename$:@',   @t_arraytypename);

  Reg.Add('narr_set@:@nn',   @t_arr_set);
  Reg.Add('narr_set@:@nnn',  @t_arr_set);
  Reg.Add('narr_set@:@nnnn', @t_arr_set);
  Reg.Add('narr_get:@n',     @t_arr_get);
  Reg.Add('narr_get:@nn',    @t_arr_get);
  Reg.Add('narr_get:@nnn',   @t_arr_get);

  Reg.Add('sarr_set@:@n$',   @t_arr_set);
  Reg.Add('sarr_get$:@n',    @t_arr_get);
  Reg.Add('parr_set@:@n@',   @t_arr_set);
  Reg.Add('parr_get@:@n',    @t_arr_get);

  Reg.Add('arr_get:@n',  @t_arr_get);
  Reg.Add('arr_set:@nn', @t_arr_set);
  Reg.Add('arr_set:@n$', @t_arr_set);
  Reg.Add('arr_set:@n@', @t_arr_set);

  Reg.Add('pointer@:n', @t_pointer);   // fabricate a handle (for negative tests)
  Reg.Add('arr_free:@', @t_arr_free);
end;

end.
