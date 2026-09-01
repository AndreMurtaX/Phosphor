{******************************************************************************
  Phosphor BASIC -- array library (a function package)

  MIT License. Copyright (c) 2026 Andre Murta.

  Registers the array functions through the ':' registry. Arrays are handle
  objects (PhosphorHandles): dim@/sdim@/pdim@ mint one and return a handle;
  narr_*/sarr_*/parr_* and the bracket-sugar arr_get/arr_set read and write
  elements. Element get/set is kind-agnostic (one implementation each, registered
  under every typed name), because the array already knows its own element kind.
  All errors are RETURNED, never raised (decisions.md).
******************************************************************************}
unit PhosphorArrayLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles;

procedure RegisterArrayFuncs(Reg: TPhosphorRegistry);

implementation

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

  // numeric element access (1-3 dimensions)
  Reg.Add('narr_set@:@nn',   @t_arr_set);
  Reg.Add('narr_set@:@nnn',  @t_arr_set);
  Reg.Add('narr_set@:@nnnn', @t_arr_set);
  Reg.Add('narr_get:@n',     @t_arr_get);
  Reg.Add('narr_get:@nn',    @t_arr_get);
  Reg.Add('narr_get:@nnn',   @t_arr_get);

  // string / pointer element access (1 dimension)
  Reg.Add('sarr_set@:@n$',   @t_arr_set);
  Reg.Add('sarr_get$:@n',    @t_arr_get);
  Reg.Add('parr_set@:@n@',   @t_arr_set);
  Reg.Add('parr_get@:@n',    @t_arr_get);

  // bracket sugar a@[i] / a@[i] = v
  Reg.Add('arr_get:@n',  @t_arr_get);
  Reg.Add('arr_set:@nn', @t_arr_set);
  Reg.Add('arr_set:@n$', @t_arr_set);
  Reg.Add('arr_set:@n@', @t_arr_set);
end;

end.
