{******************************************************************************
  Phosphor BASIC -- canvas library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  The LCL-native answer to the reference's FMX shapes and path: immediate-mode
  drawing on a bitmap you can then show in an image, plus the simple TShape
  control. Drawing on an off-screen bitmap needs no window, so it is fully
  headless -- a test draws and reads a pixel back to prove it.

    bitmap@(w, h)                   an off-screen drawing surface
    bitmap_width/height(bm@)        bitmap_pixel(bm@, x, y)   -- the TColor at x,y
    canvas_pencolor@(bm@, c)   canvas_penwidth@(bm@, n)   canvas_brushcolor@(bm@, c)
    canvas_moveto@(bm@, x, y)  canvas_lineto@(bm@, x, y)
    canvas_rectangle@(bm@, x1,y1,x2,y2)   canvas_fillrect@(bm@, x1,y1,x2,y2)
    canvas_ellipse@(bm@, x1,y1,x2,y2)     canvas_textout@(bm@, x, y, s$)
    image_setbitmap@(img@, bm@)     show the bitmap in an image control

    shape@(parent@)   shape_kind@/()   shape_brushcolor@/()   shape_pencolor@/()
      (kind: 0 rectangle, 1 square, 2 roundrect, 3 roundsquare, 4 ellipse,
             5 circle, 6 squared-diamond, 7 diamond, 8 triangle)

  Colours are plain TColor numbers ($00BBGGRR); 255 is red, 65280 green, etc.
******************************************************************************}
unit PhosphorCanvasLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, ExtCtrls, Graphics,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterCanvasFuncs(Reg: TPhosphorRegistry);

implementation

function Bmp(AId: Int64; out B: TBitmap): Boolean;
var o: TObject;
begin
  Result := GuiResolveObj(AId, TBitmap, o);
  if Result then B := TBitmap(o) else B := nil;
end;

function I(const V: TValue): Integer;
begin Result := ArgI32(V); end;

// --- bitmap surface ---------------------------------------------------------
function f_bitmap(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TBitmap;
begin
  E := NoError;
  b := TBitmap.Create;
  b.SetSize(I(A[0]), I(A[1]));
  Result := ValHandle(GuiRegister(b, True));   // owned by its handle
end;
function f_bm_width(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TBitmap; begin E := NoError; if Bmp(A[0].Hnd, b) then Result := ValInt(b.Width) else Result := ValInt(0); end;
function f_bm_height(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TBitmap; begin E := NoError; if Bmp(A[0].Hnd, b) then Result := ValInt(b.Height) else Result := ValInt(0); end;
function f_bm_pixel(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TBitmap; begin E := NoError; if Bmp(A[0].Hnd, b) then Result := ValInt(b.Canvas.Pixels[I(A[1]), I(A[2])]) else Result := ValInt(0); end;

// --- canvas state -----------------------------------------------------------
function f_pencolor(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TBitmap; begin E := NoError; if Bmp(A[0].Hnd, b) then b.Canvas.Pen.Color := TColor(I(A[1])); Result := A[0]; end;
function f_penwidth(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TBitmap; begin E := NoError; if Bmp(A[0].Hnd, b) then b.Canvas.Pen.Width := I(A[1]); Result := A[0]; end;
function f_brushcolor(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TBitmap; begin E := NoError; if Bmp(A[0].Hnd, b) then b.Canvas.Brush.Color := TColor(I(A[1])); Result := A[0]; end;

// --- canvas drawing ---------------------------------------------------------
function f_moveto(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TBitmap; begin E := NoError; if Bmp(A[0].Hnd, b) then b.Canvas.MoveTo(I(A[1]), I(A[2])); Result := A[0]; end;
function f_lineto(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TBitmap; begin E := NoError; if Bmp(A[0].Hnd, b) then b.Canvas.LineTo(I(A[1]), I(A[2])); Result := A[0]; end;
function f_rectangle(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TBitmap; begin E := NoError; if Bmp(A[0].Hnd, b) then b.Canvas.Rectangle(I(A[1]), I(A[2]), I(A[3]), I(A[4])); Result := A[0]; end;
function f_fillrect(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TBitmap; begin E := NoError; if Bmp(A[0].Hnd, b) then b.Canvas.FillRect(I(A[1]), I(A[2]), I(A[3]), I(A[4])); Result := A[0]; end;
function f_ellipse(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TBitmap; begin E := NoError; if Bmp(A[0].Hnd, b) then b.Canvas.Ellipse(I(A[1]), I(A[2]), I(A[3]), I(A[4])); Result := A[0]; end;
function f_textout(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TBitmap; begin E := NoError; if Bmp(A[0].Hnd, b) then b.Canvas.TextOut(I(A[1]), I(A[2]), A[3].Str); Result := A[0]; end;

// --- show a bitmap in an image control --------------------------------------
function f_image_setbitmap(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; b: TBitmap;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TImage, c) and Bmp(A[1].Hnd, b) then
    TImage(c).Picture.Bitmap.Assign(b);
end;

// --- TShape control ---------------------------------------------------------
function f_shape(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; s: TShape;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  s := TShape.Create(pc);
  s.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(s, False));
end;
function f_shape_kind_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; n: Integer; begin
  E := NoError;
  if GuiResolve(A[0].Hnd, TShape, c) then begin n := I(A[1]); if (n >= Ord(Low(TShapeType))) and (n <= Ord(High(TShapeType))) then TShape(c).Shape := TShapeType(n); end;
  Result := A[0];
end;
function f_shape_kind_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TShape, c) then Result := ValInt(Ord(TShape(c).Shape)) else Result := ValInt(0); end;
function f_shape_brush_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TShape, c) then TShape(c).Brush.Color := TColor(I(A[1])); Result := A[0]; end;
function f_shape_brush_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TShape, c) then Result := ValInt(TShape(c).Brush.Color) else Result := ValInt(0); end;
function f_shape_pen_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TShape, c) then TShape(c).Pen.Color := TColor(I(A[1])); Result := A[0]; end;
function f_shape_pen_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TShape, c) then Result := ValInt(TShape(c).Pen.Color) else Result := ValInt(0); end;

procedure RegisterCanvasFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('bitmap@:nn', @f_bitmap);
  Reg.Add('bitmap_width:@', @f_bm_width);
  Reg.Add('bitmap_height:@', @f_bm_height);
  Reg.Add('bitmap_pixel:@nn', @f_bm_pixel);
  Reg.Add('canvas_pencolor@:@n', @f_pencolor);
  Reg.Add('canvas_penwidth@:@n', @f_penwidth);
  Reg.Add('canvas_brushcolor@:@n', @f_brushcolor);
  Reg.Add('canvas_moveto@:@nn', @f_moveto);
  Reg.Add('canvas_lineto@:@nn', @f_lineto);
  Reg.Add('canvas_rectangle@:@nnnn', @f_rectangle);
  Reg.Add('canvas_fillrect@:@nnnn', @f_fillrect);
  Reg.Add('canvas_ellipse@:@nnnn', @f_ellipse);
  Reg.Add('canvas_textout@:@nn$', @f_textout);
  Reg.Add('image_setbitmap@:@@', @f_image_setbitmap);
  Reg.Add('shape@:@', @f_shape);
  Reg.Add('shape_kind@:@n', @f_shape_kind_set); Reg.Add('shape_kind:@', @f_shape_kind_get);
  Reg.Add('shape_brushcolor@:@n', @f_shape_brush_set); Reg.Add('shape_brushcolor:@', @f_shape_brush_get);
  Reg.Add('shape_pencolor@:@n', @f_shape_pen_set); Reg.Add('shape_pencolor:@', @f_shape_pen_get);
end;

end.
