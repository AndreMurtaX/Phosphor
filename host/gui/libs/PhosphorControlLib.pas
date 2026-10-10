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
  SysUtils, Classes, Types, TypInfo, Controls, Graphics, Forms,
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

{ NARROWING A PROGRAM'S NUMBER TO AN ORDINAL -- through the ENGINE's saturating
  helpers, never through Round.

  This used to be `Round(ArgNum(V))`, the only Round( in host/gui/libs, and it had
  both halves of the bug that PhosphorValue.ArgI64/ArgI32 exist to prevent.
  Round traps on a double outside Int64 (the x87/SSE invalid-operation exception),
  so control_left@(b@, 9223372036854775807) -- the largest Int64 the LANGUAGE has,
  a value a program can simply write down -- killed the program with "Invalid
  floating point operation" from every one of the thirty-odd control_* setters and
  from control_set@ as well. PhosphorValue's finiteness gate makes leaving that trap
  unmasked safe by keeping Inf and NaN out of the value space, but 9.3e18 is FINITE:
  it enters legally and traps here anyway.

  And below the trap it wrapped, in silence, which is worse: control_left@(b@, 3e9)
  answered -1294967296. Every other GUI package already narrows with ArgI32 and
  saturates; this one file did not. So:

    ArgOrd    for an Int64-wide target (Tag, and SetOrdProp's Int64 parameter)
    ArgOrd32  for the Integer-typed LCL properties -- Left, Width, Font.Size, ...
    ArgOrdIn  for a property whose own type is narrower than Integer, saturating
              into that declared range (Cursor is -32768..32767, TabOrder -1..32767)

  All three answer a value; none of them can raise.

  AND A BOOLEAN IS AN ORDINAL, which is the half of `ArgNum` the move to ArgI64
  dropped. TValue is a plain record, not a variant one: ValBool(True) fills .Bl and
  leaves .Num at its default 0.0, and PhosphorValue.ArgI64 reads .Int for a vkInt
  and .Num for everything else -- so every true the LANGUAGE has arrived here as
  zero. The old `Round(ArgNum(V))` had `vkBool: Ord(V.Bl)` inside ArgNum and did
  not; the replacement kept the trap fix and lost the kind, and control_set@'s
  documented @$? overload -- the ONE registered GUI signature that takes a '?', so
  the whole of the boolean surface -- wrote False for both answers. Both of the
  bridge's ordinal branches were hit: `Visible` through ArgOrd32 and `Tag`, which
  is 64 bits wide, through ArgOrd.

  So the kind is answered here, before the engine's helper is asked, and it is
  answered in all three -- ArgOrdIn saturates whatever ArgOrd hands it, so it is
  fixed by delegating rather than by repeating the test. The Int64 edge stays
  exactly where the trap fix put it: a vkBool never reaches ArgI64, and every other
  kind still does, so 9223372036854775807 still saturates and still does not trap. }
function ArgOrd(const V: TValue): Int64;
begin
  if V.Kind = vkBool then Exit(Ord(V.Bl));
  Result := ArgI64(V);
end;

function ArgOrd32(const V: TValue): Integer;
begin
  if V.Kind = vkBool then Exit(Ord(V.Bl));
  Result := ArgI32(V);
end;

function ArgOrdIn(const V: TValue; ALo, AHi: Int64): Int64;
begin
  Result := ArgOrd(V);
  if Result < ALo then Result := ALo
  else if Result > AHi then Result := AHi;
end;

{ EVERY GEOMETRY WRITE GOES THROUGH HERE, and a write the LCL refuses is UNDONE.
  The range checks in the setters below keep the program's own numbers inside
  what a window can hold (GuiPosOk, GuiExtentOk). What they cannot see is the
  layout the write sets off: an anchored or aligned sibling, a parent's
  constraint, an autosize. When any of that raises -- SendMoveSizeMessages'
  "Position range overflow" is the one a shown form produces -- the LCL has
  ALREADY stored the new bounds, so every later realign of that form raised
  again: one refused move poisoned the window for the rest of the run
  (2026-10-09, round 4). So the old bounds are put back, the refusal is
  gui_error 1, and nothing crosses into BASIC. }
function SafeSetBounds(c: TControl; L, T, W, H: Integer): Boolean;
var oL, oT, oW, oH: Integer;
begin
  oL := c.Left; oT := c.Top; oW := c.Width; oH := c.Height;
  try
    c.SetBounds(L, T, W, H);
    Result := True;
  except
    on Exception do
    begin
      GGuiError := 1;
      Result := False;
      try
        c.SetBounds(oL, oT, oW, oH);
      except
        on Exception do ;   // the old bounds were legal once; nothing more to try
      end;
    end;
  end;
end;

// --- named geometry helpers -------------------------------------------------
{ A POSITION IS A SmallInt AND A SIZE AT MOST GuiMaxExtent, refused past either
  with gui_error 1 and the control left where it was -- on a hidden form and a
  shown one alike, so a program does not pass its tests headless and raise when a
  person runs it (see GuiMaxExtent in PhosphorGuiCore for the measurements). }
function f_left_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Left) else Result := ValInt(0); end;
function f_left_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; n: Integer; begin E := NoError;
  if Ctl(A[0].Hnd, c) then begin n := ArgOrd32(A[1]); if GuiPosOk(n, 0) then SafeSetBounds(c, n, c.Top, c.Width, c.Height); end;
  Result := A[0]; end;
function f_top_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Top) else Result := ValInt(0); end;
function f_top_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; n: Integer; begin E := NoError;
  if Ctl(A[0].Hnd, c) then begin n := ArgOrd32(A[1]); if GuiPosOk(0, n) then SafeSetBounds(c, c.Left, n, c.Width, c.Height); end;
  Result := A[0]; end;
function f_width_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Width) else Result := ValInt(0); end;
function f_width_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; n: Integer; begin E := NoError;
  // GuiExtentOk, not a bare assignment: past the ceiling the LCL traps or raises
  // rather than refusing -- see the constant's note in PhosphorGuiCore.
  if Ctl(A[0].Hnd, c) then begin n := ArgOrd32(A[1]); if GuiExtentOk(n, 0) then SafeSetBounds(c, c.Left, c.Top, n, c.Height); end;
  Result := A[0]; end;
function f_height_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Height) else Result := ValInt(0); end;
function f_height_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; n: Integer; begin E := NoError;
  if Ctl(A[0].Hnd, c) then begin n := ArgOrd32(A[1]); if GuiExtentOk(0, n) then SafeSetBounds(c, c.Left, c.Top, c.Width, n); end;
  Result := A[0]; end;

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
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Color := TColor(ArgOrd32(A[1])); Result := A[0]; end;
function f_hint_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValStr(c.Hint) else Result := ValStr(''); end;
function f_hint_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Hint := A[1].Str; Result := A[0]; end;
function f_cursor_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Cursor) else Result := ValInt(0); end;
function f_cursor_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Cursor := TCursor(ArgOrdIn(A[1], Low(TCursor), High(TCursor))); Result := A[0]; end;
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
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Font.Size := ArgOrd32(A[1]); Result := A[0]; end;
function f_fontcolor_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then Result := ValInt(c.Font.Color) else Result := ValInt(0); end;
function f_fontcolor_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if Ctl(A[0].Hnd, c) then c.Font.Color := TColor(ArgOrd32(A[1])); Result := A[0]; end;

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
var c: TControl; x, y: Integer; begin E := NoError;
  if Ctl(A[0].Hnd, c) then
  begin
    x := ArgOrd32(A[1]); y := ArgOrd32(A[2]);
    // Both or neither, the rule control_size@ already had: half a move is not a
    // place anybody asked for.
    if GuiPosOk(x, y) then SafeSetBounds(c, x, y, c.Width, c.Height);
  end;
  Result := A[0]; end;
function f_size(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; w, h: Integer; begin E := NoError;
  if Ctl(A[0].Hnd, c) then
  begin
    w := ArgOrd32(A[1]); h := ArgOrd32(A[2]);
    // Both together, and BOTH refused if either is too big: half a resize is not a
    // size anybody asked for.
    if GuiExtentOk(w, h) then SafeSetBounds(c, c.Left, c.Top, w, h);
  end;
  Result := A[0]; end;
function f_bounds(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; x, y, w, h: Integer; begin E := NoError;
  if Ctl(A[0].Hnd, c) then
  begin
    x := ArgOrd32(A[1]); y := ArgOrd32(A[2]);
    w := ArgOrd32(A[3]); h := ArgOrd32(A[4]);
    if GuiPosOk(x, y) and GuiExtentOk(w, h) then SafeSetBounds(c, x, y, w, h);
  end;
  Result := A[0]; end;
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
var o, obj: TObject; h: TGuiHandle;
begin
  E := NoError;
  GuiFlushFrees();   // at depth 0, what an earlier handler deferred goes first
  o := HandleObj(A[0].Hnd);
  if not (o is TGuiHandle) then begin GGuiError := 1; Exit(ValInt(0)); end;
  h := TGuiHandle(o);
  // THE ONE CONTROL THAT IS REFUSED IS A FORM BEING CLOSED.
  // "Dispose of the window when it closes" -- form_onclose@ plus control_free, both
  // documented, the obvious pairing -- destroyed the form from inside
  // TCustomForm.Close, which then went on writing CloseAction and hiding an object
  // that no longer existed: an access violation, 3 runs out of 3. Refused, not
  // raised -- gui_error 1 is the answer this package gives every operation a
  // control will not accept, and tests/gui/18_faults.bas pins it. The window is
  // still freed at ResetHandles. Every OTHER free inside a handler is deferred
  // below, which is what made "freeing a button in its own click is fine" true:
  // it was said here, and it held for a click only by luck of the LCL's order.
  if GuiInUse(h.Control) then begin GGuiError := 1; Exit(ValInt(0)); end;
  // A HANDLE WHOSE CONTROL IS ALREADY GONE NAMES NOTHING TO DESTROY. Freeing a form
  // frees the tree it owns; TGuiHandle.Notification then nils every child handle's
  // reference, which is the state every other reader of that handle already refuses
  // -- panel_caption$ answers "" with gui_error 1. control_free alone answered 1
  // with gui_error 0, because it reported FreeHandle's success and FreeHandle
  // succeeds on the still-registered WRAPPER whether or not there was a control
  // under it. So a program that freed a form and then looped over its children was
  // told it had destroyed every one. The documented answer is the same one the
  // doubly-freed case already gives: "0 with gui_error() = 1 for a stale, doubly
  // freed or fabricated handle" (docs/libraries/gui-control.md). The dead wrapper is
  // still released, exactly as before -- that is housekeeping, not the answer.
  if h.Control = nil then
  begin
    GGuiError := 1;
    FreeHandle(A[0].Hnd);
    Exit(ValInt(0));
  end;
  // INSIDE A HANDLER, THE LCL MAY BE STANDING ON IT -- or on the form that owns
  // it, or on anything else it touches on the way out of the event; which one
  // depends on each control's internals (TButtonControl.Click calls
  // `inherited Click` on the sender AFTER the change event; a radio group's
  // change arrives from inside one of its own buttons). So the free is deferred
  // until no handler is running: dead to the program now, freed after. A
  // bitmap is not deferred -- no LCL frame stands on one, and it is the object a
  // handler is likeliest to make and free in a loop, which deferral would let
  // pile up past the GUI budget. See GuiFreeLater (PhosphorGuiCore).
  if GuiInDispatch() and (h.Watched or (h.Holder <> nil)) then
  begin
    GuiFreeLater(h);
    FreeHandle(A[0].Hnd);
    Exit(ValInt(1));
  end;
  if (not h.Owns) and (h.Control <> nil) then
  begin
    obj := h.Control;
    // A TREE NODE OR A LIST ITEM (a handle with a Holder) takes a subtree with it
    // that nothing will report: every handle into it is dropped FIRST, while the
    // nodes are still alive to be compared. This one's own handle included.
    if h.Holder <> nil then GuiForgetNodes(obj);
    h.Control := nil;
    obj.Free;   // a non-owned control is freed here; the owning form frees its own
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

{ A SYNTHESISED EVENT IS THE CONTROL'S OWN METHOD, AND SOME OF THOSE FOCUS.
  TCustomGrid.MouseDown calls SetFocus after the handler and TCustomTreeView's
  BEFORE it; on a form that was never shown that reaches TCustomForm.SetFocus,
  which raises EInvalidOperation "Can not focus" -- so control_mousedown@ on a
  grid or a tree view of a hidden form ended the program (2026-10-09, round 4),
  and for the tree its handler never ran. Focus before form_show@ is documented
  as a deliberate no-op (control_setfocus@), so that refusal is ANSWERED here,
  not reported: the call goes on as the LCL itself goes on when a grid finds it
  cannot focus. Anything else the LCL raises is recorded as gui_error 1.

  FocusRefused tells the one refusal from the rest: an EInvalidOperation while
  the control's form is not showing. }
function FocusRefused(c: TComponent; Ex: Exception): Boolean;
var f: TCustomForm;
begin
  Result := False;
  if not (Ex is EInvalidOperation) or not (c is TControl) then Exit;
  f := GetParentForm(TControl(c));
  Result := (f = nil) or not (f.Visible and f.Enabled);
end;

procedure SynthFault(c: TComponent; Ex: Exception);
begin
  if not FocusRefused(c, Ex) then GGuiError := 1;
end;

type
  { And the handler must still run when the refusal came BEFORE it. The probe
    stands in for the bound handler for the length of one synthesised call,
    passes the event through, and remembers whether it did -- so a mouse-down
    the LCL abandoned at SetFocus can be delivered to the handler afterwards, the
    way a grid delivers it before it tries to focus. }
  TMouseProbe = class
    Saved: TMouseEvent;
    Ran: Boolean;
    procedure Fire(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
                   X, Y: Integer);
  end;

procedure TMouseProbe.Fire(Sender: TObject; Button: TMouseButton;
                           Shift: TShiftState; X, Y: Integer);
begin
  Ran := True;
  if Assigned(Saved) then Saved(Sender, Button, Shift, X, Y);
end;

function SameEvent(const A, B: TMouseEvent): Boolean;
begin
  Result := (TMethod(A).Code = TMethod(B).Code) and (TMethod(A).Data = TMethod(B).Data);
end;

procedure SynthMouse(c: TComponent; AUp: Boolean; Btn: TMouseButton;
                     Shift: TShiftState; X, Y: Integer);
var
  probe: TMouseProbe;
  mine: TMouseEvent;
begin
  probe := TMouseProbe.Create;
  try
    mine := @probe.Fire;
    if AUp then probe.Saved := TControlAccess(c).OnMouseUp
    else probe.Saved := TControlAccess(c).OnMouseDown;
    if AUp then TControlAccess(c).OnMouseUp := mine
    else TControlAccess(c).OnMouseDown := mine;
    try
      try
        if AUp then TControlAccess(c).MouseUp(Btn, Shift, X, Y)
        else TControlAccess(c).MouseDown(Btn, Shift, X, Y);
      except
        on Ex: Exception do
        begin
          SynthFault(c, Ex);
          if FocusRefused(c, Ex) and not probe.Ran and Assigned(probe.Saved) then
            probe.Saved(c, Btn, Shift, X, Y);
        end;
      end;
    finally
      // Put the binding back -- unless the handler bound a new one, which is the
      // program's to keep. (A free requested inside the handler is deferred, so
      // the control is still alive here.)
      if AUp then
      begin
        if SameEvent(TControlAccess(c).OnMouseUp, mine) then
          TControlAccess(c).OnMouseUp := probe.Saved;
      end
      else if SameEvent(TControlAccess(c).OnMouseDown, mine) then
        TControlAccess(c).OnMouseDown := probe.Saved;
    end;
  finally
    probe.Free;
  end;
end;

function f_do_keydown(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; k: Word;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TWinControl, c) then Exit;
  k := Word(ArgOrdIn(A[1], Low(Word), High(Word)));
  try
    TWinControlAccess(c).KeyDown(k, ModsOf(A[2].Str));
  except
    on Ex: Exception do SynthFault(c, Ex);
  end;
end;
function f_do_keyup(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; k: Word;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TWinControl, c) then Exit;
  k := Word(ArgOrdIn(A[1], Low(Word), High(Word)));
  try
    TWinControlAccess(c).KeyUp(k, ModsOf(A[2].Str));
  except
    on Ex: Exception do SynthFault(c, Ex);
  end;
end;
function f_do_keypress(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; ch: Char;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TWinControl, c) then Exit;
  if A[1].Str = '' then Exit;      // nothing to press
  ch := A[1].Str[1];               // the first BYTE, so this stays byte-exact
  try
    TWinControlAccess(c).KeyPress(ch);
  except
    on Ex: Exception do SynthFault(c, Ex);
  end;
end;
function f_do_mousedown(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  SynthMouse(c, False, MouseBtn(ArgOrd(A[1])), ModsOf(A[4].Str),
             ArgOrd32(A[2]), ArgOrd32(A[3]));
end;
function f_do_mouseup(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  SynthMouse(c, True, MouseBtn(ArgOrd(A[1])), ModsOf(A[4].Str),
             ArgOrd32(A[2]), ArgOrd32(A[3]));
end;
{ A double click, delivered the way the LCL delivers one: TControl.DblClick is the
  method a real double click ends in, and it fires OnDblClick. A grid overrides it
  (and may open its in-place editor first), which is why this calls the method
  rather than the handler. }
function f_do_dblclick(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  try
    TControlAccess(c).DblClick;
  except
    on Ex: Exception do SynthFault(c, Ex);
  end;
end;
function f_on_dblclick(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TControl, c) then
    TControlAccess(c).OnDblClick := GuiNotifyHandler(AVM, c, 'ondblclick', A[1].Str, A[0].Hnd);
end;
function f_do_mousemove(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  try
    TControlAccess(c).MouseMove(ModsOf(A[3].Str), ArgOrd32(A[1]), ArgOrd32(A[2]));
  except
    on Ex: Exception do SynthFault(c, Ex);
  end;
end;
function f_do_mousewheel(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; pt: TPoint;
begin
  E := NoError; Result := ValInt(0);
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  pt.X := ArgOrd32(A[2]); pt.Y := ArgOrd32(A[3]);
  // ONE call. DoMouseWheel already answers whether the event was consumed, which is
  // what the handler's Handled var parameter decided -- so the program reads back
  // its own answer, and the wheel is not spun twice to find out.
  try
    Result := ValInt(Ord(TControlAccess(c).DoMouseWheel(ModsOf(A[4].Str), ArgOrd32(A[1]), pt)));
  except
    on Ex: Exception do SynthFault(c, Ex);
  end;
end;

// --- the backbone helpers the plan named and never had ----------------------
// A control's parent, which the property bridge cannot reach: TControl.Parent is
// public, not published, so RTTI does not see it.
function f_parent_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c, pc: TComponent; w: TWinControl;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  if not GuiResolve(A[1].Hnd, TWinControl, pc) then Exit;
  // A CONTROL CANNOT BE ITS OWN ANCESTOR. Handing a control one of its own
  // descendants makes a cycle, and the LCL then recurses until the stack is gone --
  // reported as a BASIC stack overflow, but only after the process has spun for
  // minutes. Walk the proposed parent's chain first: if this control is anywhere on
  // it, the request is a bug in the program, not a layout.
  w := TWinControl(pc);
  while w <> nil do
  begin
    if w = c then begin GGuiError := 1; Exit; end;
    w := w.Parent;
  end;
  try
    TControl(c).Parent := TWinControl(pc);
  except
    // The LCL refuses some pairings itself (EInvalidOperation). The package's rule
    // is that a bad request is RECORDED, never raised into the program.
    on Exception do GGuiError := 1;
  end;
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
  // A MISSPELLED ANCHOR IS A TYPO, NOT A CRASH. SetSetProp raises
  // EPropertyConvertError ('Unknown enumeration value: "akNope"') on any identifier
  // it does not know, and that message named nothing in the program that caused it.
  // The property EXISTS -- it is the value the control refuses -- so this is
  // gui_error 1, "an operation the control refused", not ERR_NO_PROPERTY.
  try
    SetSetProp(c, pi, A[1].Str);
  except
    on Exception do GGuiError := 1;
  end;
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
  if GuiResolve(A[0].Hnd, TWinControl, c) then TWinControl(c).TabOrder := ArgOrdIn(A[1], Low(TTabOrder), High(TTabOrder)); end;

// BorderSpacing and Constraints are class-typed sub-objects, which is exactly why
// the property bridge refuses them. The plan claimed both were exposed; these are
// the named helpers that make that true.
function f_spacing_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TControl, c) then Result := ValInt(TControl(c).BorderSpacing.Around); end;
{ A GAP AND A CONSTRAINT ARE SIZES TOO. Each moves or resizes the control (and its
  aligned siblings) the moment it is written, so each is held to the same ceiling
  as control_width@ -- refused past it with gui_error 1 -- and each write is undone
  if the layout it sets off raises, the way SafeSetBounds undoes a move. Measured
  on a shown form before this: control_spacing@ on an aligned control raised
  "Position range overflow", and control_minwidth@ of 65536..2^31 raised "Size
  range overflow" or "Division by zero" from nearly every control kind. }
function SpacingOk(N: Integer): Boolean;
begin
  Result := (N >= -GuiMaxExtent) and (N <= GuiMaxExtent);
  if not Result then GGuiError := 1;
end;

procedure SafeSpacing(c: TControl; N: Integer);
var old: Integer;
begin
  old := c.BorderSpacing.Around;
  try
    c.BorderSpacing.Around := N;
  except
    on Exception do
    begin
      GGuiError := 1;
      try c.BorderSpacing.Around := old; except on Exception do ; end;
    end;
  end;
end;

type TConstraintKind = (ckMinW, ckMaxW, ckMinH, ckMaxH);

function ConstraintOf(c: TControl; K: TConstraintKind): Integer;
begin
  case K of
    ckMinW: Result := c.Constraints.MinWidth;
    ckMaxW: Result := c.Constraints.MaxWidth;
    ckMinH: Result := c.Constraints.MinHeight;
  else      Result := c.Constraints.MaxHeight;
  end;
end;

procedure PutConstraint(c: TControl; K: TConstraintKind; N: Integer);
begin
  case K of
    ckMinW: c.Constraints.MinWidth := N;
    ckMaxW: c.Constraints.MaxWidth := N;
    ckMinH: c.Constraints.MinHeight := N;
  else      c.Constraints.MaxHeight := N;
  end;
end;

procedure SetConstraint(const A: array of TValue; K: TConstraintKind);
var c: TComponent; n: Int64; old: Integer;
begin
  if not GuiResolve(A[0].Hnd, TControl, c) then Exit;
  // A negative still saturates to 0, the LCL's "no constraint", as it always did.
  n := ArgOrdIn(A[1], Low(TConstraintSize), High(TConstraintSize));
  if n > GuiMaxExtent then begin GGuiError := 1; Exit; end;
  old := ConstraintOf(TControl(c), K);
  try
    PutConstraint(TControl(c), K, n);
  except
    on Exception do
    begin
      GGuiError := 1;
      try PutConstraint(TControl(c), K, old); except on Exception do ; end;
    end;
  end;
end;

function f_spacing_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; n: Integer; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TControl, c) then
  begin
    n := ArgOrd32(A[1]);
    if SpacingOk(n) then SafeSpacing(TControl(c), n);
  end; end;
function f_minwidth_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TControl, c) then Result := ValInt(TControl(c).Constraints.MinWidth); end;
function f_minwidth_set(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := A[0]; SetConstraint(A, ckMinW); end;
function f_maxwidth_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TControl, c) then Result := ValInt(TControl(c).Constraints.MaxWidth); end;
function f_maxwidth_set(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := A[0]; SetConstraint(A, ckMaxW); end;
function f_minheight_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TControl, c) then Result := ValInt(TControl(c).Constraints.MinHeight); end;
function f_minheight_set(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := A[0]; SetConstraint(A, ckMinH); end;
function f_maxheight_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TControl, c) then Result := ValInt(TControl(c).Constraints.MaxHeight); end;
function f_maxheight_set(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := A[0]; SetConstraint(A, ckMaxH); end;

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
var c: TControl; pi: PPropInfo; k: TTypeKind; n: Int64;
    oldStr: String; oldNum: Extended; oldOrd: Int64; haveOld: Boolean;
begin
  E := NoError;
  Result := A[0];   // A[0]=handle, A[1]=name$, A[2]=value
  if not Ctl(A[0].Hnd, c) then Exit;
  pi := GetPropInfo(c, A[1].Str);
  if pi = nil then begin GGuiError := ERR_NO_PROPERTY; Exit; end;
  k := pi^.PropType^.Kind;
  // THE VALUE IS THE PROGRAM'S, SO EVERY WAY IT CAN BE WRONG IS THE PROGRAM'S BUG
  // TO SEE -- and each of these four RTTI writers raises rather than returning:
  //   SetStrProp  on Name   -- '"not a name" is not a valid component name', and a
  //                            duplicate name is EComponentError as well
  //   SetEnumProp           -- 'Unknown enumeration value: "taCentre"'  (a typo)
  //   SetSetProp            -- the same, per identifier in "akLeft,akNope"
  //   SetOrdProp  on an index property -- the CONTROL's own bounds check fires
  //                            inside the write: 'TListBox Index 500 out of bounds'
  // Every one of those killed the program from a single control_set@ call, with an
  // LCL-internal message that named nothing the programmer had written. There is no
  // pre-check available here -- the bounds belong to a property this code is
  // deliberately generic about -- so the refusal is caught, exactly the way
  // control_parent@ above catches the LCL's own refusals, and recorded as
  // gui_error 1: the property exists, the VALUE was refused. (ERR_NO_PROPERTY stays
  // what it has always meant: no such published property.)
  //
  // THE GEOMETRY PROPERTIES ARE HELD TO THE NAMED SETTERS' RANGE, before the write:
  // a position outside GuiMinPos..GuiMaxPos, a size past GuiMaxExtent. Caught
  // afterwards was not enough -- on a shown form the LCL raises only AFTER storing
  // the value, and "Width" past 32767 on a spin edit never reached this except at
  // all: it raised inside the window procedure and ended the process.
  if (A[2].Kind <> vkString) and IsOrdKind(k) and (k <> tkInt64) and (k <> tkQWord) then
  begin
    n := ArgOrd32(A[2]);
    if (SameText(pi^.Name, 'Left') or SameText(pi^.Name, 'Top')) and
       not GuiPosOk(n, 0) then Exit;
    if (SameText(pi^.Name, 'Width') or SameText(pi^.Name, 'Height') or
        SameText(pi^.Name, 'ClientWidth') or SameText(pi^.Name, 'ClientHeight')) and
       not GuiExtentOk(n, 0) then Exit;
  end;
  // AND A WRITE THE LCL REFUSES IS UNDONE. It used to be caught and recorded with
  // the refused value left standing -- control_set@(b@, "Left", 100000) on a shown
  // form read back 100000 and poisoned every later realign of the window. So the
  // old value is read first and put back when the write raises.
  oldStr := ''; oldNum := 0; oldOrd := 0;
  try
    if IsStrKind(k) then oldStr := GetStrProp(c, pi)
    else if k = tkFloat then oldNum := GetFloatProp(c, pi)
    else if IsOrdKind(k) then oldOrd := GetOrdProp(c, pi);
    haveOld := True;
  except
    on Exception do haveOld := False;   // unreadable: then there is nothing to restore
  end;
  try
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
    else if (k = tkInt64) or (k = tkQWord) then
    begin
      // Only these two properties are 64 bits wide (Tag is one, PtrInt on win64),
      // so only these take the Int64 unnarrowed.
      n := ArgOrd(A[2]);
      // AND THE GATE, on both ordinal branches, because a bound a named setter
      // carries is not a bound until the bridge honours it too. pi^.Name and not
      // A[1].Str: the CANONICAL property name out of the RTTI record, so "rowcount"
      // and "RowCount" reach the gate as the one name it tests. See GuiAddPropGate.
      if not GuiPropGatesAllow(c, pi^.Name, n, E) then Exit;
      SetOrdProp(c, pi, n);
      // ... and told afterwards, so a package that CHARGED for this write records
      // what the object became rather than what was asked for. Inside the try, so
      // a raising SetOrdProp above skips it -- which is right: nothing changed.
      GuiPropWasWritten(c, pi^.Name);
    end
    else if IsOrdKind(k) then
    begin
      // EVERY OTHER ordinal property is at most 32 bits, and SetOrdProp TRUNCATES
      // rather than clamping: passing it High(Int64) for an Integer property wrote
      // -1. That is the same silent wrap ArgOrd32 exists to stop -- it just reached
      // the property through the bridge instead of through control_left@, and
      // control_set@(h, "Left", 1e19) is one of the calls the report named.
      n := ArgOrd32(A[2]);
      if not GuiPropGatesAllow(c, pi^.Name, n, E) then Exit;
      SetOrdProp(c, pi, n);
      GuiPropWasWritten(c, pi^.Name);
    end
    else
      GGuiError := ERR_NO_PROPERTY;             // an unsupported property kind
  except
    on Exception do
    begin
      GGuiError := 1;
      if haveOld then
      try
        if IsStrKind(k) then SetStrProp(c, pi, oldStr)
        else if k = tkFloat then SetFloatProp(c, pi, oldNum)
        else if IsOrdKind(k) then SetOrdProp(c, pi, oldOrd);
      except
        on Exception do ;   // it held this value before; nothing more to try
      end;
    end;
  end;
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
  Reg.Add('control_dblclick@:@',         @f_do_dblclick);
  // the key and mouse events, on any control that can carry them
  Reg.AddHost('control_onkeydown@:@$',    @f_on_keydown);
  Reg.AddHost('control_onkeyup@:@$',      @f_on_keyup);
  Reg.AddHost('control_onkeypress@:@$',   @f_on_keypress);
  Reg.AddHost('control_onmousedown@:@$',  @f_on_mousedown);
  Reg.AddHost('control_onmouseup@:@$',    @f_on_mouseup);
  Reg.AddHost('control_onmousemove@:@$',  @f_on_mousemove);
  Reg.AddHost('control_onmousewheel@:@$', @f_on_mousewheel);
  Reg.AddHost('control_ondblclick@:@$',   @f_on_dblclick);
  // the generic property bridge
  Reg.Add('control_set@:@$n', @f_prop_set);
  Reg.Add('control_set@:@$$', @f_prop_set);
  Reg.Add('control_set@:@$?', @f_prop_set);
  Reg.Add('control_get:@$',   @f_prop_get);
  Reg.Add('control_get$:@$',  @f_prop_get_str);
end;

end.
