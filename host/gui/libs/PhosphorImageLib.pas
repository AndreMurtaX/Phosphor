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
  SysUtils, Classes, Controls, ExtCtrls, ComCtrls, Graphics,
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

// --- a shared strip of icons ------------------------------------------------
{ TImageList is a TComponent, not a TControl: nothing shows it, and the controls
  that use it hold a reference. It is owned by its handle, so freeing the handle
  frees the list -- which means a program must outlive the controls pointing at it,
  the same rule any shared resource has. }
function f_imagelist(const A: array of TValue; out E: TPhosphorError): TValue;
var il: TImageList;
begin
  E := NoError;
  il := TImageList.Create(nil);
  if Length(A) >= 2 then
  begin
    il.Width := ArgI32(A[0]);
    il.Height := ArgI32(A[1]);
  end;
  Result := ValHandle(GuiRegister(il, True));
end;

function f_il_count(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TImageList, c) then Result := ValInt(TImageList(c).Count); end;

function f_il_clear(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TImageList, c) then TImageList(c).Clear; end;

{ Add a picture from a file. Answers the 1-based index it took, the shape
  strings_add settled on -- a mutator returns information, not a flag. 0 means the
  file could not be read, with gui_error set. }
function f_il_addfile(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; bm: TBitmap; pic: TPicture;
begin
  E := NoError; Result := ValInt(0);
  if not GuiResolve(A[0].Hnd, TImageList, c) then Exit;
  if not FileExists(A[1].Str) then begin GGuiError := 1; Exit; end;
  pic := TPicture.Create;
  try
    try
      pic.LoadFromFile(A[1].Str);
    except
      // A file that is not an image is an ANSWER, not an exception crossing into
      // BASIC -- the phase-1 contract, which this package honours like the rest.
      on E2: Exception do begin GGuiError := 1; Exit; end;
    end;
    bm := TBitmap.Create;
    try
      bm.Assign(pic.Graphic);
      TImageList(c).Add(bm, nil);
      Result := ValInt(TImageList(c).Count);   // the index it took, base-1
    finally bm.Free; end;
  finally pic.Free; end;
end;

{ Add an existing bitmap@ instead of a file. }
function f_il_addbitmap(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; o: TObject;
begin
  E := NoError; Result := ValInt(0);
  if not GuiResolve(A[0].Hnd, TImageList, c) then Exit;
  if not GuiResolveObj(A[1].Hnd, TBitmap, o) then Exit;
  TImageList(c).Add(TBitmap(o), nil);
  Result := ValInt(TImageList(c).Count);
end;

{ Point a control at the list. Images is object-typed, so control_set@ cannot do
  it; the three LCL controls that have such a property are handled by name. }
function f_il_attach(const A: array of TValue; out E: TPhosphorError): TValue;
var lc, c: TComponent;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TImageList, lc) then Exit;
  if not GuiResolve(A[1].Hnd, TComponent, c) then Exit;
  if c is TToolBar then TToolBar(c).Images := TImageList(lc)
  else if c is TTreeView then TTreeView(c).Images := TImageList(lc)
  else if c is TListView then TListView(c).SmallImages := TImageList(lc)
  else GGuiError := 1;   // nothing else here takes an image list
end;

procedure RegisterImageFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('imagelist@:',           @f_imagelist);
  Reg.Add('imagelist@:nn',         @f_imagelist);
  Reg.Add('imagelist_count:@',     @f_il_count);
  Reg.Add('imagelist_clear@:@',    @f_il_clear);
  Reg.Add('imagelist_addfile:@$',  @f_il_addfile);
  Reg.Add('imagelist_addbitmap:@@', @f_il_addbitmap);
  Reg.Add('imagelist_attach@:@@',  @f_il_attach);
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
