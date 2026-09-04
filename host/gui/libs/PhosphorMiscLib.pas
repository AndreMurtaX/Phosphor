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
  SysUtils, Classes, Controls, Calendar, Dialogs, Graphics,
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

procedure RegisterMiscFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('calendar@:@', @f_calendar);
  Reg.Add('calendar_date@:@n', @f_cal_date_set); Reg.Add('calendar_date:@', @f_cal_date_get);
  Reg.Add('colorbutton@:@', @f_colorbutton);
  Reg.Add('colorbutton_color@:@n', @f_cbtn_color_set); Reg.Add('colorbutton_color:@', @f_cbtn_color_get);
end;

end.
