{******************************************************************************
  Phosphor BASIC -- handle registry (core infrastructure)

  MIT License. Copyright (c) 2026 Andre Murta.

  A handle (`@`) is an Int64 id into this registry, not a raw pointer, so a
  fabricated or stale handle is detectable (IsHandle) instead of dereferencing
  arbitrary memory -- the property Plan9Basic's HandleRegistry existed to give.
  Ids are 1-based and never reused within a run; ResetHandles frees every live
  object and is called at the start of each Run so handles never leak between
  programs.

  This unit knows nothing about what the objects ARE -- the handle-based
  collections (arrays, dicts, ...) live in the library packages under
  engine/libs and only store/retrieve their objects here as plain TObjects.
******************************************************************************}
unit PhosphorHandles;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

function RegisterHandle(AObj: TObject): Int64;
function HandleObj(AId: Int64): TObject;
function IsHandle(AId: Int64): Boolean;
function FreeHandle(AId: Int64): Boolean;   // free one object, invalidate its id
procedure ResetHandles;

implementation

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

function FreeHandle(AId: Int64): Boolean;
begin
  if not IsHandle(AId) then
    Exit(False);
  GObjs[AId - 1].Free;
  GObjs[AId - 1] := nil;   // id stays used but now invalid (IsHandle is false)
  Result := True;
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
  ResetHandles();

end.
