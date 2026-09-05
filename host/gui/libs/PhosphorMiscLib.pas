{******************************************************************************
  Phosphor BASIC -- miscellaneous controls (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  Controls that do not belong to a larger family.

    calendar@(parent@)      calendar_date@(cal@, d)   calendar_date(cal@)
      -- d is a date number (a TDateTime), matching the engine's date model
    colorbutton@(parent@)   colorbutton_color@(cb@, c)   colorbutton_color(cb@)
      -- c is a TColor number; clicking the button opens a colour dialog
******************************************************************************}
unit PhosphorMiscLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, Calendar, Dialogs, ExtCtrls, Graphics,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterMiscFuncs(Reg: TPhosphorRegistry);

implementation

function MakeChild(AParentId: Int64; AClass: TControlClass; out Ctrl: TControl): Boolean;
var pc: TComponent;
begin
  Result := GuiResolve(AParentId, TWinControl, pc);
  if not Result then begin Ctrl := nil; Exit; end;
  Ctrl := AClass.Create(pc);
  Ctrl.Parent := TWinControl(pc);
end;

// --- calendar ---------------------------------------------------------------
function f_calendar(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TCalendar, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_cal_date_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCalendar, c) then TCalendar(c).DateTime := AsDouble(A[1]); Result := A[0]; end;
function f_cal_date_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCalendar, c) then Result := ValDouble(TCalendar(c).DateTime) else Result := ValDouble(0); end;

// --- colour button ----------------------------------------------------------
function f_colorbutton(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TColorButton, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_cbtn_color_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TColorButton, c) then TColorButton(c).ButtonColor := TColor(ArgI32(A[1])); Result := A[0]; end;
function f_cbtn_color_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TColorButton, c) then Result := ValInt(TColorButton(c).ButtonColor) else Result := ValInt(0); end;

// --- the notification area --------------------------------------------------
{ A tray icon has no parent and is not shown by a form: it lives in the desktop's
  notification area for as long as its handle does. It needs a running message loop
  to be clicked, so the headless suite pins its CONFIGURATION -- the same line the
  dialog package draws for its modal Execute. }
function f_trayicon(const A: array of TValue; out E: TPhosphorError): TValue;
var t: TTrayIcon;
begin
  E := NoError;
  t := TTrayIcon.Create(nil);   // no owner: the handle wrapper owns it
  t.Visible := False;
  Result := ValHandle(GuiRegister(t, True));
end;
function f_ti_hint_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValStr('');
  if GuiResolve(A[0].Hnd, TTrayIcon, c) then Result := ValStr(TTrayIcon(c).Hint); end;
function f_ti_hint_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TTrayIcon, c) then TTrayIcon(c).Hint := A[1].Str; end;
function f_ti_visible_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TTrayIcon, c) then Result := ValInt(Ord(TTrayIcon(c).Visible)); end;
function f_ti_show(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TTrayIcon, c) then TTrayIcon(c).Visible := True; end;
function f_ti_hide(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TTrayIcon, c) then TTrayIcon(c).Visible := False; end;
function f_ti_onclick(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TTrayIcon, c) then
    TTrayIcon(c).OnClick := GuiNotifyHandler(AVM, c, 'onclick', A[1].Str, A[0].Hnd); end;

procedure RegisterMiscFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('trayicon@:',          @f_trayicon);
  Reg.Add('trayicon_hint$:@',    @f_ti_hint_get);  Reg.Add('trayicon_hint@:@$', @f_ti_hint_set);
  Reg.Add('trayicon_visible:@',  @f_ti_visible_get);
  Reg.Add('trayicon_show@:@',    @f_ti_show);
  Reg.Add('trayicon_hide@:@',    @f_ti_hide);
  Reg.AddHost('trayicon_onclick@:@$', @f_ti_onclick);
  Reg.Add('calendar@:@', @f_calendar);
  Reg.Add('calendar_date@:@n', @f_cal_date_set); Reg.Add('calendar_date:@', @f_cal_date_get);
  Reg.Add('colorbutton@:@', @f_colorbutton);
  Reg.Add('colorbutton_color@:@n', @f_cbtn_color_set); Reg.Add('colorbutton_color:@', @f_cbtn_color_get);
end;

end.
