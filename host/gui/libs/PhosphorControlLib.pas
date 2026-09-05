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
  SysUtils, Classes, TypInfo, Controls, Graphics,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorGuiCore;

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
  // the generic property bridge
  Reg.Add('control_set@:@$n', @f_prop_set);
  Reg.Add('control_set@:@$$', @f_prop_set);
  Reg.Add('control_set@:@$?', @f_prop_set);
  Reg.Add('control_get:@$',   @f_prop_get);
  Reg.Add('control_get$:@$',  @f_prop_get_str);
end;

end.
