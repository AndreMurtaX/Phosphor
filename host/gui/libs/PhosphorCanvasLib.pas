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

{ ANY surface that has a canvas: an off-screen bitmap@, or a live paintbox@. The
  drawing primitives used to resolve a TBitmap and nothing else, which is why
  paintbox@ could not exist -- the whole immediate-mode API was tied to a buffer.
  One resolver, two kinds of target, the same calls for both. }
function Cnv(AId: Int64; out C: TCanvas): Boolean;
var o: TObject;
begin
  C := nil;
  Result := False;
  o := nil;
  if GuiResolveObj(AId, TBitmap, o) then
  begin
    C := TBitmap(o).Canvas;
    Exit(True);
  end;
  // GuiResolveObj recorded a wrong-class error for the bitmap attempt; the handle
  // may still be a perfectly good paint box, so clear it and try again.
  GGuiError := 0;
  if GuiResolveObj(AId, TPaintBox, o) then
  begin
    C := TPaintBox(o).Canvas;
    Exit(True);
  end;
  // Any windowed control that paints itself: a drawgrid@ handed to its own
  // OnDrawCell handler, a stringgrid@, anything else with a surface. TCustomControl
  // publishes Canvas, which is exactly the property this resolver is looking for.
  GGuiError := 0;
  if GuiResolveObj(AId, TCustomControl, o) then
  begin
    C := TCustomControl(o).Canvas;
    Exit(True);
  end;
end;

{ The points of a polygon or polyline, written "x,y x,y x,y". Whitespace between
  pairs, a comma inside one. Anything malformed is a recorded error and no drawing,
  rather than a shape with a stray vertex at the origin. }
function ParsePoints(const S: String; out P: array of TPoint; out N: Integer): Boolean;
var
  i, start, comma: Integer;
  tok: String;
begin
  N := 0;
  Result := False;
  i := 1;
  while i <= Length(S) do
  begin
    while (i <= Length(S)) and (S[i] = ' ') do Inc(i);
    if i > Length(S) then Break;
    start := i;
    while (i <= Length(S)) and (S[i] <> ' ') do Inc(i);
    tok := Copy(S, start, i - start);
    comma := Pos(',', tok);
    if comma < 2 then Exit;                       // no x, or no comma at all
    if N > High(P) then Exit;                     // more points than we can hold
    P[N].X := StrToIntDef(Copy(tok, 1, comma - 1), MaxInt);
    P[N].Y := StrToIntDef(Copy(tok, comma + 1, Length(tok)), MaxInt);
    if (P[N].X = MaxInt) or (P[N].Y = MaxInt) then Exit;   // not a number
    Inc(N);
  end;
  Result := N >= 2;                               // a line needs two ends
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
var c: TCanvas; begin E := NoError; if Cnv(A[0].Hnd, c) then c.Pen.Color := TColor(I(A[1])); Result := A[0]; end;
function f_penwidth(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; if Cnv(A[0].Hnd, c) then c.Pen.Width := I(A[1]); Result := A[0]; end;
function f_brushcolor(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; if Cnv(A[0].Hnd, c) then c.Brush.Color := TColor(I(A[1])); Result := A[0]; end;

// --- canvas drawing ---------------------------------------------------------
function f_moveto(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; if Cnv(A[0].Hnd, c) then c.MoveTo(I(A[1]), I(A[2])); Result := A[0]; end;
function f_lineto(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; if Cnv(A[0].Hnd, c) then c.LineTo(I(A[1]), I(A[2])); Result := A[0]; end;
function f_rectangle(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; if Cnv(A[0].Hnd, c) then c.Rectangle(I(A[1]), I(A[2]), I(A[3]), I(A[4])); Result := A[0]; end;
function f_fillrect(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; if Cnv(A[0].Hnd, c) then c.FillRect(I(A[1]), I(A[2]), I(A[3]), I(A[4])); Result := A[0]; end;
function f_ellipse(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; if Cnv(A[0].Hnd, c) then c.Ellipse(I(A[1]), I(A[2]), I(A[3]), I(A[4])); Result := A[0]; end;
function f_textout(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; if Cnv(A[0].Hnd, c) then c.TextOut(I(A[1]), I(A[2]), A[3].Str); Result := A[0]; end;

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

// --- a live drawing surface -------------------------------------------------
function f_paintbox(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; pb: TPaintBox;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  pb := TPaintBox.Create(pc); pb.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(pb, False));
end;
function f_pb_onpaint(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TPaintBox, c) then
    TPaintBox(c).OnPaint := GuiNotifyHandler(AVM, c, 'onpaint', A[1].Str, A[0].Hnd);
end;

// --- the primitives the plan named and the canvas did not have --------------
function f_line(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; Result := A[0];
  if Cnv(A[0].Hnd, c) then c.Line(I(A[1]), I(A[2]), I(A[3]), I(A[4])); end;
function f_roundrect(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; Result := A[0];
  if Cnv(A[0].Hnd, c) then c.RoundRect(I(A[1]), I(A[2]), I(A[3]), I(A[4]), I(A[5]), I(A[6])); end;
// Angles in DEGREES, converted to the 1/16ths the LCL takes -- a program should not
// have to know that unit to draw a quarter circle.
function f_arc(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; Result := A[0];
  if Cnv(A[0].Hnd, c) then
    c.Arc(I(A[1]), I(A[2]), I(A[3]), I(A[4]), I(A[5]) * 16, I(A[6]) * 16); end;
function f_pie(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; Result := A[0];
  if Cnv(A[0].Hnd, c) then
    c.RadialPie(I(A[1]), I(A[2]), I(A[3]), I(A[4]), I(A[5]) * 16, I(A[6]) * 16); end;
function f_polygon(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; pts: array[0..255] of TPoint; n: Integer;
begin
  E := NoError; Result := A[0];
  if not Cnv(A[0].Hnd, c) then Exit;
  if not ParsePoints(A[1].Str, pts, n) then begin GGuiError := 1; Exit; end;
  c.Polygon(@pts[0], n - 1, False);
end;
function f_polyline(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; pts: array[0..255] of TPoint; n: Integer;
begin
  E := NoError; Result := A[0];
  if not Cnv(A[0].Hnd, c) then Exit;
  if not ParsePoints(A[1].Str, pts, n) then begin GGuiError := 1; Exit; end;
  c.Polyline(@pts[0], n - 1);
end;
function f_canvas_clear(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; Result := A[0];
  if Cnv(A[0].Hnd, c) then c.FillRect(c.ClipRect); end;
function f_textwidth(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; Result := ValInt(0);
  if Cnv(A[0].Hnd, c) then Result := ValInt(c.TextWidth(A[1].Str)); end;
function f_textheight(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; Result := ValInt(0);
  if Cnv(A[0].Hnd, c) then Result := ValInt(c.TextHeight(A[1].Str)); end;
function f_fontsize(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; Result := A[0];
  if Cnv(A[0].Hnd, c) then c.Font.Size := I(A[1]); end;
function f_fontcolor(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TCanvas; begin E := NoError; Result := A[0];
  if Cnv(A[0].Hnd, c) then c.Font.Color := TColor(I(A[1])); end;

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
  Reg.Add('canvas_line@:@nnnn',      @f_line);
  Reg.Add('canvas_roundrect@:@nnnnnn', @f_roundrect);
  Reg.Add('canvas_arc@:@nnnnnn',     @f_arc);
  Reg.Add('canvas_pie@:@nnnnnn',     @f_pie);
  Reg.Add('canvas_polygon@:@$',      @f_polygon);
  Reg.Add('canvas_polyline@:@$',     @f_polyline);
  Reg.Add('canvas_clear@:@',         @f_canvas_clear);
  Reg.Add('canvas_textwidth:@$',     @f_textwidth);
  Reg.Add('canvas_textheight:@$',    @f_textheight);
  Reg.Add('canvas_fontsize@:@n',     @f_fontsize);
  Reg.Add('canvas_fontcolor@:@n',    @f_fontcolor);
  Reg.Add('paintbox@:@',             @f_paintbox);
  Reg.AddHost('paintbox_onpaint@:@$', @f_pb_onpaint);
  Reg.Add('image_setbitmap@:@@', @f_image_setbitmap);
  Reg.Add('shape@:@', @f_shape);
  Reg.Add('shape_kind@:@n', @f_shape_kind_set); Reg.Add('shape_kind:@', @f_shape_kind_get);
  Reg.Add('shape_brushcolor@:@n', @f_shape_brush_set); Reg.Add('shape_brushcolor:@', @f_shape_brush_get);
  Reg.Add('shape_pencolor@:@n', @f_shape_pen_set); Reg.Add('shape_pencolor:@', @f_shape_pen_get);
end;

end.
