{******************************************************************************
  Phosphor BASIC -- container library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  The controls that hold other controls. Each is a TWinControl, so any child
  constructor (button@, edit@, ...) accepts its handle as the parent, and the
  shared PhosphorControlLib helpers apply. This package adds construction and the
  container-specific bits (a caption, a page's tabs).

    panel@(parent@)        panel_caption@/$
    groupbox@(parent@)     groupbox_caption@/$
    scrollbox@(parent@)
    pagecontrol@(parent@)  pagecontrol_pagecount   pagecontrol_pageindex@/()
    tabsheet@(pagecontrol@, caption$)    tabsheet_caption@/$
******************************************************************************}
unit PhosphorContainerLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, Forms, ExtCtrls, ComCtrls, StdCtrls,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterContainerFuncs(Reg: TPhosphorRegistry);

implementation

function MakeChild(AParentId: Int64; AClass: TControlClass; out Ctrl: TControl): Boolean;
var pc: TComponent;
begin
  Result := GuiResolve(AParentId, TWinControl, pc);
  if not Result then begin Ctrl := nil; Exit; end;
  Ctrl := AClass.Create(pc);
  Ctrl.Parent := TWinControl(pc);
end;

// --- panel ------------------------------------------------------------------
function f_panel(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TPanel, c) then begin TPanel(c).Caption := ''; Result := ValHandle(GuiRegister(c, False)); end else Result := ValHandle(0); end;
function f_panel_caption_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TPanel, c) then TPanel(c).Caption := A[1].Str; Result := A[0]; end;
function f_panel_caption_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TPanel, c) then Result := ValStr(TPanel(c).Caption) else Result := ValStr(''); end;

// --- group box --------------------------------------------------------------
function f_groupbox(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TGroupBox, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_groupbox_caption_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TGroupBox, c) then TGroupBox(c).Caption := A[1].Str; Result := A[0]; end;
function f_groupbox_caption_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TGroupBox, c) then Result := ValStr(TGroupBox(c).Caption) else Result := ValStr(''); end;

// --- scroll box -------------------------------------------------------------
function f_scrollbox(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TScrollBox, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;

// --- page control + tab sheets ----------------------------------------------
function f_pagecontrol(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TPageControl, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_pagecount(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TPageControl, c) then Result := ValInt(TPageControl(c).PageCount) else Result := ValInt(0); end;
function f_pageindex_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TPageControl, c) then TPageControl(c).ActivePageIndex := Round(AsDouble(A[1])) - 1; Result := A[0]; end;
function f_pageindex_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TPageControl, c) then Result := ValInt(TPageControl(c).ActivePageIndex + 1) else Result := ValInt(0); end;

function f_tabsheet(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; ts: TTabSheet;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TPageControl, c) then begin Result := ValHandle(0); Exit; end;
  ts := TTabSheet.Create(c);
  ts.PageControl := TPageControl(c);   // adds it as a page
  if Length(A) >= 2 then ts.Caption := A[1].Str;
  Result := ValHandle(GuiRegister(ts, False));
end;
function f_tabsheet_caption_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTabSheet, c) then TTabSheet(c).Caption := A[1].Str; Result := A[0]; end;
function f_tabsheet_caption_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTabSheet, c) then Result := ValStr(TTabSheet(c).Caption) else Result := ValStr(''); end;

// --- splitter (a draggable divider between aligned controls) ----------------
function f_splitter(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TSplitter, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;

// --- bevel (a decorative line or frame) -------------------------------------
function f_bevel(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TBevel, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_bevel_shape_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; n: Integer; begin E := NoError; if GuiResolve(A[0].Hnd, TBevel, c) then begin n := Round(AsDouble(A[1])); if (n >= Ord(Low(TBevelShape))) and (n <= Ord(High(TBevelShape))) then TBevel(c).Shape := TBevelShape(n); end; Result := A[0]; end;
function f_bevel_shape_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TBevel, c) then Result := ValInt(Ord(TBevel(c).Shape)) else Result := ValInt(0); end;
function f_bevel_style_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; n: Integer; begin E := NoError; if GuiResolve(A[0].Hnd, TBevel, c) then begin n := Round(AsDouble(A[1])); if (n >= Ord(Low(TBevelStyle))) and (n <= Ord(High(TBevelStyle))) then TBevel(c).Style := TBevelStyle(n); end; Result := A[0]; end;
function f_bevel_style_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TBevel, c) then Result := ValInt(Ord(TBevel(c).Style)) else Result := ValInt(0); end;

procedure RegisterContainerFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('splitter@:@', @f_splitter);
  Reg.Add('bevel@:@', @f_bevel);
  Reg.Add('bevel_shape@:@n', @f_bevel_shape_set); Reg.Add('bevel_shape:@', @f_bevel_shape_get);
  Reg.Add('bevel_style@:@n', @f_bevel_style_set); Reg.Add('bevel_style:@', @f_bevel_style_get);
  Reg.Add('panel@:@', @f_panel);
  Reg.Add('panel_caption@:@$', @f_panel_caption_set); Reg.Add('panel_caption$:@', @f_panel_caption_get);
  Reg.Add('groupbox@:@', @f_groupbox);
  Reg.Add('groupbox_caption@:@$', @f_groupbox_caption_set); Reg.Add('groupbox_caption$:@', @f_groupbox_caption_get);
  Reg.Add('scrollbox@:@', @f_scrollbox);
  Reg.Add('pagecontrol@:@', @f_pagecontrol);
  Reg.Add('pagecontrol_pagecount:@', @f_pagecount);
  Reg.Add('pagecontrol_pageindex@:@n', @f_pageindex_set); Reg.Add('pagecontrol_pageindex:@', @f_pageindex_get);
  Reg.Add('tabsheet@:@$', @f_tabsheet);
  Reg.Add('tabsheet_caption@:@$', @f_tabsheet_caption_set); Reg.Add('tabsheet_caption$:@', @f_tabsheet_caption_get);
end;

end.
