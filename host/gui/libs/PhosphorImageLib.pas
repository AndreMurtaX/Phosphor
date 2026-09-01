{******************************************************************************
  Phosphor BASIC -- image library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

    image@(parent@)
    image_load@(img@, path$)     load a picture; a missing file sets gui_error 6
    image_stretch@/()  image_center@/()  image_proportional@/()
    image_picwidth(img@)  image_picheight(img@)  image_empty(img@)

  Geometry/visibility come from PhosphorControlLib; this adds loading and the
  picture's own size. A load failure is recorded in gui_error(), never raised.
******************************************************************************}
unit PhosphorImageLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, ExtCtrls, Graphics,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterImageFuncs(Reg: TPhosphorRegistry);

implementation

const
  ERR_FILE_NOT_FOUND = 6;
  ERR_LOAD_FAILED    = 7;

function ArgOn(const V: TValue): Boolean;
begin
  case V.Kind of
    vkBool: Result := V.Bl;
    vkInt:  Result := V.Int <> 0;
    vkDouble: Result := V.Num <> 0;
  else Result := False;
  end;
end;

function f_image(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; img: TImage;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  img := TImage.Create(pc);
  img.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(img, False));
end;

function f_load(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError;
  Result := A[0];
  if not GuiResolve(A[0].Hnd, TImage, c) then Exit;
  if not FileExists(A[1].Str) then begin GGuiError := ERR_FILE_NOT_FOUND; Exit; end;
  try
    TImage(c).Picture.LoadFromFile(A[1].Str);
  except
    GGuiError := ERR_LOAD_FAILED;   // a present but unreadable/undecodable file
  end;
end;

function f_stretch_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then TImage(c).Stretch := ArgOn(A[1]); Result := A[0]; end;
function f_stretch_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then Result := ValInt(Ord(TImage(c).Stretch)) else Result := ValInt(0); end;
function f_center_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then TImage(c).Center := ArgOn(A[1]); Result := A[0]; end;
function f_center_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then Result := ValInt(Ord(TImage(c).Center)) else Result := ValInt(0); end;
function f_proportional_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then TImage(c).Proportional := ArgOn(A[1]); Result := A[0]; end;
function f_proportional_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then Result := ValInt(Ord(TImage(c).Proportional)) else Result := ValInt(0); end;

function f_picwidth(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then Result := ValInt(TImage(c).Picture.Width) else Result := ValInt(0); end;
function f_picheight(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then Result := ValInt(TImage(c).Picture.Height) else Result := ValInt(0); end;
function f_empty(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin
  E := NoError; Result := ValInt(1);
  if GuiResolve(A[0].Hnd, TImage, c) then
    if TImage(c).Picture.Graphic <> nil then Result := ValInt(Ord(TImage(c).Picture.Graphic.Empty));
end;

procedure RegisterImageFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('image@:@', @f_image);
  Reg.Add('image_load@:@$', @f_load);
  Reg.Add('image_stretch@:@n', @f_stretch_set); Reg.Add('image_stretch:@', @f_stretch_get);
  Reg.Add('image_center@:@n', @f_center_set);   Reg.Add('image_center:@', @f_center_get);
  Reg.Add('image_proportional@:@n', @f_proportional_set); Reg.Add('image_proportional:@', @f_proportional_get);
  Reg.Add('image_picwidth:@', @f_picwidth);
  Reg.Add('image_picheight:@', @f_picheight);
  Reg.Add('image_empty:@', @f_empty);
end;

end.
