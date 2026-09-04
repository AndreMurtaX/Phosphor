{******************************************************************************
  Phosphor BASIC -- range library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  Controls that hold a value within a range: a slider, a progress bar, a scroll
  bar. Geometry/colour come from PhosphorControlLib; this adds min/max/position
  and the trackbar's onchange.

    trackbar@(parent@)     trackbar_min@/()  trackbar_max@/()  trackbar_position@/()
                           trackbar_onchange@
    progressbar@(parent@)  progressbar_min@/()  progressbar_max@/()  progressbar_position@/()
    scrollbar@(parent@)    scrollbar_min@/()  scrollbar_max@/()  scrollbar_position@/()
******************************************************************************}
unit PhosphorRangeLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, StdCtrls, ComCtrls,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterRangeFuncs(Reg: TPhosphorRegistry);

implementation

function MakeChild(AParentId: Int64; AClass: TControlClass; out Ctrl: TControl): Boolean;
var pc: TComponent;
begin
  Result := GuiResolve(AParentId, TWinControl, pc);
  if not Result then begin Ctrl := nil; Exit; end;
  Ctrl := AClass.Create(pc);
  Ctrl.Parent := TWinControl(pc);
end;

// --- trackbar ---------------------------------------------------------------
function f_trackbar(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TTrackBar, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_tb_min_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTrackBar, c) then TTrackBar(c).Min := ArgI32(A[1]); Result := A[0]; end;
function f_tb_min_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTrackBar, c) then Result := ValInt(TTrackBar(c).Min) else Result := ValInt(0); end;
function f_tb_max_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTrackBar, c) then TTrackBar(c).Max := ArgI32(A[1]); Result := A[0]; end;
function f_tb_max_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTrackBar, c) then Result := ValInt(TTrackBar(c).Max) else Result := ValInt(0); end;
function f_tb_pos_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTrackBar, c) then TTrackBar(c).Position := ArgI32(A[1]); Result := A[0]; end;
function f_tb_pos_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTrackBar, c) then Result := ValInt(TTrackBar(c).Position) else Result := ValInt(0); end;
function f_tb_onchange(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0]; if GuiResolve(A[0].Hnd, TTrackBar, c) then TTrackBar(c).OnChange := GuiNotifyHandler(AVM, c, 'onchange', A[1].Str, A[0].Hnd); end;

// --- progress bar -----------------------------------------------------------
function f_progressbar(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TProgressBar, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_pb_min_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TProgressBar, c) then TProgressBar(c).Min := ArgI32(A[1]); Result := A[0]; end;
function f_pb_min_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TProgressBar, c) then Result := ValInt(TProgressBar(c).Min) else Result := ValInt(0); end;
function f_pb_max_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TProgressBar, c) then TProgressBar(c).Max := ArgI32(A[1]); Result := A[0]; end;
function f_pb_max_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TProgressBar, c) then Result := ValInt(TProgressBar(c).Max) else Result := ValInt(0); end;
function f_pb_pos_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TProgressBar, c) then TProgressBar(c).Position := ArgI32(A[1]); Result := A[0]; end;
function f_pb_pos_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TProgressBar, c) then Result := ValInt(TProgressBar(c).Position) else Result := ValInt(0); end;

// --- scroll bar -------------------------------------------------------------
function f_scrollbar(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TScrollBar, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_sb_min_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TScrollBar, c) then TScrollBar(c).Min := ArgI32(A[1]); Result := A[0]; end;
function f_sb_min_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TScrollBar, c) then Result := ValInt(TScrollBar(c).Min) else Result := ValInt(0); end;
function f_sb_max_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TScrollBar, c) then TScrollBar(c).Max := ArgI32(A[1]); Result := A[0]; end;
function f_sb_max_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TScrollBar, c) then Result := ValInt(TScrollBar(c).Max) else Result := ValInt(0); end;
function f_sb_pos_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TScrollBar, c) then TScrollBar(c).Position := ArgI32(A[1]); Result := A[0]; end;
function f_sb_pos_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TScrollBar, c) then Result := ValInt(TScrollBar(c).Position) else Result := ValInt(0); end;

// --- up/down (a small pair of increment/decrement arrows) -------------------
function f_updown(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TUpDown, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_ud_min_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TUpDown, c) then TUpDown(c).Min := ArgI32(A[1]); Result := A[0]; end;
function f_ud_min_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TUpDown, c) then Result := ValInt(TUpDown(c).Min) else Result := ValInt(0); end;
function f_ud_max_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TUpDown, c) then TUpDown(c).Max := ArgI32(A[1]); Result := A[0]; end;
function f_ud_max_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TUpDown, c) then Result := ValInt(TUpDown(c).Max) else Result := ValInt(0); end;
function f_ud_pos_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TUpDown, c) then TUpDown(c).Position := ArgI32(A[1]); Result := A[0]; end;
function f_ud_pos_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TUpDown, c) then Result := ValInt(TUpDown(c).Position) else Result := ValInt(0); end;

procedure RegisterRangeFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('updown@:@', @f_updown);
  Reg.Add('updown_min@:@n', @f_ud_min_set); Reg.Add('updown_min:@', @f_ud_min_get);
  Reg.Add('updown_max@:@n', @f_ud_max_set); Reg.Add('updown_max:@', @f_ud_max_get);
  Reg.Add('updown_position@:@n', @f_ud_pos_set); Reg.Add('updown_position:@', @f_ud_pos_get);
  Reg.Add('trackbar@:@', @f_trackbar);
  Reg.Add('trackbar_min@:@n', @f_tb_min_set);  Reg.Add('trackbar_min:@', @f_tb_min_get);
  Reg.Add('trackbar_max@:@n', @f_tb_max_set);  Reg.Add('trackbar_max:@', @f_tb_max_get);
  Reg.Add('trackbar_position@:@n', @f_tb_pos_set); Reg.Add('trackbar_position:@', @f_tb_pos_get);
  Reg.AddHost('trackbar_onchange@:@$', @f_tb_onchange);
  Reg.Add('progressbar@:@', @f_progressbar);
  Reg.Add('progressbar_min@:@n', @f_pb_min_set);  Reg.Add('progressbar_min:@', @f_pb_min_get);
  Reg.Add('progressbar_max@:@n', @f_pb_max_set);  Reg.Add('progressbar_max:@', @f_pb_max_get);
  Reg.Add('progressbar_position@:@n', @f_pb_pos_set); Reg.Add('progressbar_position:@', @f_pb_pos_get);
  Reg.Add('scrollbar@:@', @f_scrollbar);
  Reg.Add('scrollbar_min@:@n', @f_sb_min_set);  Reg.Add('scrollbar_min:@', @f_sb_min_get);
  Reg.Add('scrollbar_max@:@n', @f_sb_max_set);  Reg.Add('scrollbar_max:@', @f_sb_max_get);
  Reg.Add('scrollbar_position@:@n', @f_sb_pos_set); Reg.Add('scrollbar_position:@', @f_sb_pos_get);
end;

end.
