{******************************************************************************
  Phosphor BASIC -- control library (the shared GUI backbone)

  MIT License. Copyright (c) 2026 Andre Murta.

  Every visual LCL control descends from TControl, so one package exposes the
  members they all share -- geometry, visibility, colour, font, focus -- for ANY
  control handle, plus the generic property bridge. A per-family package
  (PhosphorButtonLib, ...) then only writes what is specific to its control.

  The bridge is the multiplier. LCL controls carry full published-property RTTI,
  so control_set@(h, "PropName", value) and control_get / control_get$ reach every
  published property by name through the TypInfo unit -- no hand-written helper
  per property. The named helpers below cover the hot path and read well; the
  bridge covers the long tail with no extra code. This is Phosphor's answer to the
  reference's 08_property_roundtrip.

  A property that does not exist on the control, or a bad handle, is recorded in
  gui_error() and answered with a benign value -- never raised.
******************************************************************************}
unit PhosphorControlLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Types, TypInfo, Controls, Graphics,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorGuiCore;

type
  { The mouse and key events are declared PROTECTED on TControl/TWinControl and
    published only by descendants, so a plain cast cannot assign them. Deriving a
    type that is never instantiated is the standard Pascal way to reach a protected
    member of an instance you already hold. }
  TControlAccess = class(TControl);
  TWinControlAccess = class(TWinControl);

procedure RegisterControlFuncs(Reg: TPhosphorRegistry);

implementation

const
  ERR_NO_PROPERTY = 3;   // gui_error code: the named property is not published

// --- small helpers ----------------------------------------------------------
function Ctl(AId: Int64; out C: TControl): Boolean;
var comp: TComponent;
begin
  Result := GuiResolve(AId, TControl, comp);
  if Result then C := TControl(comp) else C := nil;
end;

function ArgNum(const V: TValue): Double;
begin
  case V.Kind of
    vkInt:    Result := V.Int;
    vkDouble: Result := V.Num;
    vkBool:   Result := Ord(V.Bl);
  else        Result := 0;
  end;
end;

function ArgOrd(const V: TValue): Int64;
begin
  Result := Round(ArgNum(V));
end;

// --- named geometry helpers -------------------------------------------------
function f_left_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Left) else Result := ValInt(0); end;
function f_left_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Left := ArgOrd(A[1]); Result := A[0]; end;
function f_top_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Top) else Result := ValInt(0); end;
function f_top_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Top := ArgOrd(A[1]); Result := A[0]; end;
function f_width_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Width) else Result := ValInt(0); end;
function f_width_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Width := ArgOrd(A[1]); Result := A[0]; end;
function f_height_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Height) else Result := ValInt(0); end;
function f_height_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Height := ArgOrd(A[1]); Result := A[0]; end;

function f_align_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(Ord(c.Align)) else Result := ValInt(0); end;
function f_align_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; n: Int64; begin
  E := NoError;
  if Ctl(A[0].Hnd, c) then begin n := ArgOrd(A[1]); if (n >= Ord(Low(TAlign))) and (n <= Ord(High(TAlign))) then c.Align := TAlign(n); end;
  Result := A[0];
end;

// --- state helpers ----------------------------------------------------------
function f_visible_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(Ord(c.Visible)) else Result := ValInt(0); end;
function f_visible_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Visible := ArgOrd(A[1]) <> 0; Result := A[0]; end;
function f_enabled_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(Ord(c.Enabled)) else Result := ValInt(0); end;
function f_enabled_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Enabled := ArgOrd(A[1]) <> 0; Result := A[0]; end;
function f_color_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Color) else Result := ValInt(0); end;
function f_color_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Color := TColor(ArgOrd(A[1])); Result := A[0]; end;
function f_hint_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValStr(c.Hint) else Result := ValStr(''); end;
function f_hint_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Hint := A[1].Str; Result := A[0]; end;
function f_cursor_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Cursor) else Result := ValInt(0); end;
function f_cursor_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Cursor := TCursor(ArgOrd(A[1])); Result := A[0]; end;
function f_tag_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Tag) else Result := ValInt(0); end;
function f_tag_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Tag := ArgOrd(A[1]); Result := A[0]; end;

// --- font helpers -----------------------------------------------------------
function f_fontname_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValStr(c.Font.Name) else Result := ValStr(''); end;
function f_fontname_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Font.Name := A[1].Str; Result := A[0]; end;
function f_fontsize_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Font.Size) else Result := ValInt(0); end;
function f_fontsize_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Font.Size := ArgOrd(A[1]); Result := A[0]; end;
function f_fontcolor_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Font.Color) else Result := ValInt(0); end;
function f_fontcolor_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Font.Color := TColor(ArgOrd(A[1])); Result := A[0]; end;

function StyleGet(const A: array of TValue; St: TFontStyle): TValue;
var c: TControl; begin if Ctl(A[0].Hnd, c) and (St in c.Font.Style) then Result := ValInt(1) else Result := ValInt(0); end;
procedure StyleSet(const A: array of TValue; St: TFontStyle);
var c: TControl; begin
  if not Ctl(A[0].Hnd, c) then Exit;
  if ArgOrd(A[1]) <> 0 then c.Font.Style := c.Font.Style + [St]
  else c.Font.Style := c.Font.Style - [St];
end;
function f_bold_get(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := StyleGet(A, fsBold); end;
function f_bold_set(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; StyleSet(A, fsBold); Result := A[0]; end;
function f_italic_get(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := StyleGet(A, fsItalic); end;
function f_italic_set(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; StyleSet(A, fsItalic); Result := A[0]; end;
function f_underline_get(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := StyleGet(A, fsUnderline); end;
function f_underline_set(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; StyleSet(A, fsUnderline); Result := A[0]; end;

// --- geometry verbs ---------------------------------------------------------
function f_move(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then begin c.Left := ArgOrd(A[1]); c.Top := ArgOrd(A[2]); end; Result := A[0]; end;
function f_size(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then begin c.Width := ArgOrd(A[1]); c.Height := ArgOrd(A[2]); end; Result := A[0]; end;
function f_bounds(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.SetBounds(ArgOrd(A[1]), ArgOrd(A[2]), ArgOrd(A[3]), ArgOrd(A[4])); Result := A[0]; end;
function f_bringtofront(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.BringToFront; Result := A[0]; end;
function f_sendtoback(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.SendToBack; Result := A[0]; end;
function f_invalidate(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Invalidate; Result := A[0]; end;
function f_setfocus(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin
  E := NoError;
  // HandleAllocated is checked FIRST and never realizes the window; without it,
  // CanFocus/SetFocus on an unshown control would force handle creation and block
  // headless. So this focuses a real window (the interactive host after form_show)
  // and is a harmless no-op otherwise.
  if Ctl(A[0].Hnd, c) and (c is TWinControl) and TWinControl(c).HandleAllocated
     and TWinControl(c).CanFocus then
    TWinControl(c).SetFocus;
  Result := A[0];
end;
function f_focused(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin
  E := NoError;
  if Ctl(A[0].Hnd, c) and (c is TWinControl) and TWinControl(c).HandleAllocated
     and TWinControl(c).Focused then Result := ValInt(1) else Result := ValInt(0);
end;

function f_free(const A: array of TValue; out E: TPhosphorError): TValue;
var o: TObject; h: TGuiHandle;
begin
  E := NoError;
  o := HandleObj(A[0].Hnd);
  if not (o is TGuiHandle) then begin GGuiError := 1; Exit(ValInt(0)); end;
  h := TGuiHandle(o);
  if (not h.Owns) and (h.Control <> nil) then
  begin
    h.Control.Free;   // a non-owned control is freed here; the owning form frees its own
    h.Control := nil;
  end;
  if FreeHandle(A[0].Hnd) then Result := ValInt(1) else begin GGuiError := 1; Result := ValInt(0); end;
end;

// --- the events every control has ------------------------------------------
// Key events live on TWinControl (a control must be able to focus to receive one);
// mouse events live on TControl, so a TLabel or a TShape can carry them too.
function f_on_keydown(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TWinControl, c) then
    TWinControlAccess(c).OnKeyDown := GuiKeyHandler(AVM, c, 'onkeydown', A[1].Str, A[0].Hnd);
end;
function f_on_keyup(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TWinControl, c) then
    TWinControlAccess(c).OnKeyUp := GuiKeyHandler(AVM, c, 'onkeyup', A[1].Str, A[0].Hnd);
end;
function f_on_keypress(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TWinControl, c) then
    TWinControlAccess(c).OnKeyPress := GuiKeyPressHandler(AVM, c, 'onkeypress', A[1].Str, A[0].Hnd);
end;
function f_on_mousedown(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TControl, c) then
    TControlAccess(c).OnMouseDown := GuiMouseHandler(AVM, c, 'onmousedown', A[1].Str, A[0].Hnd);
end;
function f_on_mouseup(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TControl, c) then
    TControlAccess(c).OnMouseUp := GuiMouseHandler(AVM, c, 'onmouseup', A[1].Str, A[0].Hnd);
end;
function f_on_mousemove(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TControl, c) then
    TControlAccess(c).OnMouseMove := GuiMouseMoveHandler(AVM, c, 'onmousemove', A[1].Str, A[0].Hnd);
end;
function f_on_mousewheel(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TControl, c) then
    TControlAccess(c).OnMouseWheel := GuiMouseWheelHandler(AVM, c, 'onmousewheel', A[1].Str, A[0].Hnd);
end;

// --- synthesising an event -------------------------------------------------
// The modifier string a handler receives, read back the other way: "S C A" (in any
// order, and any subset) becomes the TShiftState the LCL methods take.
function ModsOf(const S: String): TShiftState;
begin
  Result := [];
  if Pos('S', S) > 0 then Include(Result, ssShift);
  if Pos('C', S) > 0 then Include(Result, ssCtrl);
  if Pos('A', S) > 0 then Include(Result, ssAlt);
end;

function MouseBtn(AOrd: Int64): TMouseButton;
begin
  // 0/1/2 = left/right/middle, the encoding the handler receives.
  case AOrd of
    1: Result := mbRight;
    2: Result := mbMiddle;
  else Result := mbLeft;
  end;
end;

function f_do_keydown(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; k: Word;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TWinControl, c) then Exit;
  k := Word(ArgOrd(A[1]));
  TWinControlAccess(c).KeyDown(k, ModsOf(A[2].Str));
end;
function f_do_keyup(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; k: Word;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TWinControl, c) then Exit;
  k := Word(ArgOrd(A[1]));
  TWinControlAccess(c).KeyUp(k, ModsOf(A[2].Str));
end;
function f_do_keypress(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; ch: Char;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TWinControl, c) then Exit;
  if A[1].Str = '' then Exit;      // nothing to press
  ch := A[1].Str[1];               // the first BYTE, so this stays byte-exact
  TWinControlAccess(c).KeyPress(ch);
end;
function f_do_mousedown(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  TControlAccess(c).MouseDown(MouseBtn(ArgOrd(A[1])), ModsOf(A[4].Str),
                              ArgOrd(A[2]), ArgOrd(A[3]));
end;
function f_do_mouseup(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  TControlAccess(c).MouseUp(MouseBtn(ArgOrd(A[1])), ModsOf(A[4].Str),
                            ArgOrd(A[2]), ArgOrd(A[3]));
end;
function f_do_mousemove(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  TControlAccess(c).MouseMove(ModsOf(A[3].Str), ArgOrd(A[1]), ArgOrd(A[2]));
end;
function f_do_mousewheel(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; pt: TPoint;
begin
  E := NoError; Result := ValInt(0);
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  pt.X := ArgOrd(A[2]); pt.Y := ArgOrd(A[3]);
  // ONE call. DoMouseWheel already answers whether the event was consumed, which is
  // what the handler's Handled var parameter decided -- so the program reads back
  // its own answer, and the wheel is not spun twice to find out.
  Result := ValInt(Ord(TControlAccess(c).DoMouseWheel(ModsOf(A[4].Str), ArgOrd(A[1]), pt)));
end;

// --- the backbone helpers the plan named and never had ----------------------
// A control's parent, which the property bridge cannot reach: TControl.Parent is
// public, not published, so RTTI does not see it.
function f_parent_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c, pc: TComponent;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  if not GuiResolve(A[1].Hnd, TWinControl, pc) then Exit;
  TControl(c).Parent := TWinControl(pc);
end;

// Anchors is a SET, so it reads and writes as the identifier list the bridge also
// accepts: "akLeft,akRight". Same text in and out, so the pair round-trips.
function f_anchors_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; pi: PPropInfo;
begin
  E := NoError; Result := ValStr('');
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  pi := GetPropInfo(c, 'Anchors');
  if pi = nil then begin GGuiError := ERR_NO_PROPERTY; Exit; end;
  Result := ValStr(GetSetProp(c, pi, False));
end;
function f_anchors_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; pi: PPropInfo;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  pi := GetPropInfo(c, 'Anchors');
  if pi = nil then begin GGuiError := ERR_NO_PROPERTY; Exit; end;
  SetSetProp(c, pi, A[1].Str);
end;

function f_tabstop_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TWinControl, c) then Result := ValInt(Ord(TWinControl(c).TabStop)); end;
function f_tabstop_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TWinControl, c) then TWinControl(c).TabStop := ArgOrd(A[1]) <> 0; end;
function f_taborder_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TWinControl, c) then Result := ValInt(TWinControl(c).TabOrder); end;
function f_taborder_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TWinControl, c) then TWinControl(c).TabOrder := ArgOrd(A[1]); end;

// BorderSpacing and Constraints are class-typed sub-objects, which is exactly why
// the property bridge refuses them. The plan claimed both were exposed; these are
// the named helpers that make that true.
function f_spacing_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TControl, c) then Result := ValInt(TControl(c).BorderSpacing.Around); end;
function f_spacing_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TControl, c) then TControl(c).BorderSpacing.Around := ArgOrd(A[1]); end;
function f_minwidth_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TControl, c) then Result := ValInt(TControl(c).Constraints.MinWidth); end;
function f_minwidth_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TControl, c) then TControl(c).Constraints.MinWidth := ArgOrd(A[1]); end;
function f_maxwidth_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TControl, c) then Result := ValInt(TControl(c).Constraints.MaxWidth); end;
function f_maxwidth_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TControl, c) then TControl(c).Constraints.MaxWidth := ArgOrd(A[1]); end;
function f_minheight_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TControl, c) then Result := ValInt(TControl(c).Constraints.MinHeight); end;
function f_minheight_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TControl, c) then TControl(c).Constraints.MinHeight := ArgOrd(A[1]); end;
function f_maxheight_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TControl, c) then Result := ValInt(TControl(c).Constraints.MaxHeight); end;
function f_maxheight_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TControl, c) then TControl(c).Constraints.MaxHeight := ArgOrd(A[1]); end;

// --- the generic TypInfo property bridge ------------------------------------
function IsStrKind(K: TTypeKind): Boolean;
begin
  Result := K in [tkSString, tkLString, tkAString, tkWString, tkUString];
end;
function IsOrdKind(K: TTypeKind): Boolean;
begin
  Result := K in [tkInteger, tkChar, tkWChar, tkEnumeration, tkBool, tkInt64, tkQWord, tkSet];
end;

function f_prop_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; pi: PPropInfo; k: TTypeKind;
begin
  E := NoError;
  Result := A[0];   // A[0]=handle, A[1]=name$, A[2]=value
  if not Ctl(A[0].Hnd, c) then Exit;
  pi := GetPropInfo(c, A[1].Str);
  if pi = nil then begin GGuiError := ERR_NO_PROPERTY; Exit; end;
  k := pi^.PropType^.Kind;
  if IsStrKind(k) then
    SetStrProp(c, pi, A[2].Str)
  else if k = tkFloat then
    SetFloatProp(c, pi, ArgNum(A[2]))
  else if (k = tkEnumeration) and (A[2].Kind = vkString) then
    SetEnumProp(c, pi, A[2].Str)              // an enum may be set by its identifier
  else if (k = tkSet) and (A[2].Kind = vkString) then
    SetSetProp(c, pi, A[2].Str)               // and a SET by its identifiers: "akLeft,akRight"
  else if A[2].Kind = vkString then
    // A string reaching a plain ordinal is not a value to coerce, it is a mistake to
    // report. It used to become Round(ArgNum(s)) = 0 and be written silently.
    GGuiError := ERR_NO_PROPERTY
  else if IsOrdKind(k) then
    SetOrdProp(c, pi, ArgOrd(A[2]))
  else
    GGuiError := ERR_NO_PROPERTY;             // an unsupported property kind
end;

function f_prop_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; pi: PPropInfo; k: TTypeKind;
begin
  E := NoError;
  Result := ValInt(0);
  if not Ctl(A[0].Hnd, c) then Exit;
  pi := GetPropInfo(c, A[1].Str);
  if pi = nil then begin GGuiError := ERR_NO_PROPERTY; Exit; end;
  k := pi^.PropType^.Kind;
  if k = tkFloat then
    Result := ValDouble(GetFloatProp(c, pi))
  else if IsOrdKind(k) then
    Result := ValInt(GetOrdProp(c, pi))
  else
    // The setter has always recorded this; the getter used to answer 0 in silence,
    // which a program cannot tell from a property whose value really is 0. A string
    // property lands here too -- it reads through control_get$, and saying so is
    // better than handing back a zero it never had.
    GGuiError := ERR_NO_PROPERTY;
end;

function f_prop_get_str(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; pi: PPropInfo; k: TTypeKind;
begin
  E := NoError;
  Result := ValStr('');
  if not Ctl(A[0].Hnd, c) then Exit;
  pi := GetPropInfo(c, A[1].Str);
  if pi = nil then begin GGuiError := ERR_NO_PROPERTY; Exit; end;
  k := pi^.PropType^.Kind;
  if IsStrKind(k) then
    Result := ValStr(GetStrProp(c, pi))
  else if k = tkEnumeration then
    Result := ValStr(GetEnumProp(c, pi))      // the enum identifier, e.g. "alClient"
  else if k = tkSet then
    // Without brackets, so what comes out is exactly what control_set@ takes in and
    // the pair round-trips: "akLeft,akRight" -> the set -> "akLeft,akRight".
    Result := ValStr(GetSetProp(c, pi, False))
  else
    GGuiError := ERR_NO_PROPERTY;             // same rule as the numeric getter above
end;

procedure RegisterControlFuncs(Reg: TPhosphorRegistry);
begin
  // geometry
  Reg.Add('control_left:@',    @f_left_get);   Reg.Add('control_left@:@n',   @f_left_set);
  Reg.Add('control_top:@',     @f_top_get);    Reg.Add('control_top@:@n',    @f_top_set);
  Reg.Add('control_width:@',   @f_width_get);  Reg.Add('control_width@:@n',  @f_width_set);
  Reg.Add('control_height:@',  @f_height_get); Reg.Add('control_height@:@n', @f_height_set);
  Reg.Add('control_align:@',   @f_align_get);  Reg.Add('control_align@:@n',  @f_align_set);
  // state
  Reg.Add('control_visible:@', @f_visible_get); Reg.Add('control_visible@:@n', @f_visible_set);
  Reg.Add('control_enabled:@', @f_enabled_get); Reg.Add('control_enabled@:@n', @f_enabled_set);
  Reg.Add('control_color:@',   @f_color_get);   Reg.Add('control_color@:@n',   @f_color_set);
  Reg.Add('control_hint$:@',   @f_hint_get);    Reg.Add('control_hint@:@$',    @f_hint_set);
  Reg.Add('control_cursor:@',  @f_cursor_get);  Reg.Add('control_cursor@:@n',  @f_cursor_set);
  Reg.Add('control_tag:@',     @f_tag_get);     Reg.Add('control_tag@:@n',     @f_tag_set);
  // font
  Reg.Add('control_fontname$:@',  @f_fontname_get);  Reg.Add('control_fontname@:@$',  @f_fontname_set);
  Reg.Add('control_fontsize:@',   @f_fontsize_get);  Reg.Add('control_fontsize@:@n',  @f_fontsize_set);
  Reg.Add('control_fontcolor:@',  @f_fontcolor_get); Reg.Add('control_fontcolor@:@n', @f_fontcolor_set);
  Reg.Add('control_bold:@',       @f_bold_get);      Reg.Add('control_bold@:@n',      @f_bold_set);
  Reg.Add('control_italic:@',     @f_italic_get);    Reg.Add('control_italic@:@n',    @f_italic_set);
  Reg.Add('control_underline:@',  @f_underline_get); Reg.Add('control_underline@:@n', @f_underline_set);
  // verbs
  Reg.Add('control_move@:@nn',   @f_move);
  Reg.Add('control_size@:@nn',   @f_size);
  Reg.Add('control_bounds@:@nnnn', @f_bounds);
  Reg.Add('control_bringtofront@:@', @f_bringtofront);
  Reg.Add('control_sendtoback@:@',   @f_sendtoback);
  Reg.Add('control_invalidate@:@',   @f_invalidate);
  Reg.Add('control_setfocus@:@',     @f_setfocus);
  Reg.Add('control_focused:@',       @f_focused);
  Reg.Add('control_free:@',          @f_free);
  // anchors, tab chain, spacing and constraints -- the plan's backbone, completed
  Reg.Add('control_anchors$:@',    @f_anchors_get);   Reg.Add('control_anchors@:@$',   @f_anchors_set);
  Reg.Add('control_tabstop:@',     @f_tabstop_get);   Reg.Add('control_tabstop@:@n',   @f_tabstop_set);
  Reg.Add('control_taborder:@',    @f_taborder_get);  Reg.Add('control_taborder@:@n',  @f_taborder_set);
  Reg.Add('control_spacing:@',     @f_spacing_get);   Reg.Add('control_spacing@:@n',   @f_spacing_set);
  Reg.Add('control_minwidth:@',    @f_minwidth_get);  Reg.Add('control_minwidth@:@n',  @f_minwidth_set);
  Reg.Add('control_maxwidth:@',    @f_maxwidth_get);  Reg.Add('control_maxwidth@:@n',  @f_maxwidth_set);
  Reg.Add('control_minheight:@',   @f_minheight_get); Reg.Add('control_minheight@:@n', @f_minheight_set);
  Reg.Add('control_maxheight:@',   @f_maxheight_get); Reg.Add('control_maxheight@:@n', @f_maxheight_set);
  Reg.Add('control_parent@:@@',    @f_parent_set);
  // synthesising one, the way button_click already synthesises a click
  Reg.Add('control_keydown@:@n$',        @f_do_keydown);
  Reg.Add('control_keyup@:@n$',          @f_do_keyup);
  Reg.Add('control_keypress@:@$',        @f_do_keypress);
  Reg.Add('control_mousedown@:@nnn$',    @f_do_mousedown);
  Reg.Add('control_mouseup@:@nnn$',      @f_do_mouseup);
  Reg.Add('control_mousemove@:@nn$',     @f_do_mousemove);
  Reg.Add('control_mousewheel:@nnn$',    @f_do_mousewheel);
  // the key and mouse events, on any control that can carry them
  Reg.AddHost('control_onkeydown@:@$',    @f_on_keydown);
  Reg.AddHost('control_onkeyup@:@$',      @f_on_keyup);
  Reg.AddHost('control_onkeypress@:@$',   @f_on_keypress);
  Reg.AddHost('control_onmousedown@:@$',  @f_on_mousedown);
  Reg.AddHost('control_onmouseup@:@$',    @f_on_mouseup);
  Reg.AddHost('control_onmousemove@:@$',  @f_on_mousemove);
  Reg.AddHost('control_onmousewheel@:@$', @f_on_mousewheel);
  // the generic property bridge
  Reg.Add('control_set@:@$n', @f_prop_set);
  Reg.Add('control_set@:@$$', @f_prop_set);
  Reg.Add('control_set@:@$?', @f_prop_set);
  Reg.Add('control_get:@$',   @f_prop_get);
  Reg.Add('control_get$:@$',  @f_prop_get_str);
end;

end.
