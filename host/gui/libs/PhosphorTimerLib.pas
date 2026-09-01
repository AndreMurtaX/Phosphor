{******************************************************************************
  Phosphor BASIC -- timer library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

    timer@()                        a timer (no parent); starts disabled
    timer_interval@(t@, ms)  timer_interval(t@)
    timer_enabled@(t@, n)    timer_enabled(t@)
    timer_start@(t@)  timer_stop@(t@)
    timer_ontimer@(t@, "func")      run a BASIC routine on each tick

  A timer only ticks under a running message loop (app_run in the interactive
  host), so a headless test checks its configuration, not its firing -- the same
  boundary the reference draws for the timer.
******************************************************************************}
unit PhosphorTimerLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, ExtCtrls,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterTimerFuncs(Reg: TPhosphorRegistry);

implementation

function ArgOn(const V: TValue): Boolean;
begin
  case V.Kind of
    vkBool: Result := V.Bl;
    vkInt:  Result := V.Int <> 0;
    vkDouble: Result := V.Num <> 0;
  else Result := False;
  end;
end;

function f_timer(const A: array of TValue; out E: TPhosphorError): TValue;
var t: TTimer;
begin
  E := NoError;
  t := TTimer.Create(nil);   // no owner: the handle wrapper owns it
  t.Enabled := False;
  Result := ValHandle(GuiRegister(t, True));
end;

function f_interval_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTimer, c) then TTimer(c).Interval := Round(AsDouble(A[1])); Result := A[0]; end;
function f_interval_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTimer, c) then Result := ValInt(TTimer(c).Interval) else Result := ValInt(0); end;
function f_enabled_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTimer, c) then TTimer(c).Enabled := ArgOn(A[1]); Result := A[0]; end;
function f_enabled_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTimer, c) then Result := ValInt(Ord(TTimer(c).Enabled)) else Result := ValInt(0); end;
function f_start(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTimer, c) then TTimer(c).Enabled := True; Result := A[0]; end;
function f_stop(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTimer, c) then TTimer(c).Enabled := False; Result := A[0]; end;
function f_ontimer(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0]; if GuiResolve(A[0].Hnd, TTimer, c) then TTimer(c).OnTimer := GuiNotifyHandler(AVM, c, 'ontimer', A[1].Str, A[0].Hnd); end;

procedure RegisterTimerFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('timer@:', @f_timer);
  Reg.Add('timer_interval@:@n', @f_interval_set); Reg.Add('timer_interval:@', @f_interval_get);
  Reg.Add('timer_enabled@:@n', @f_enabled_set);   Reg.Add('timer_enabled:@', @f_enabled_get);
  Reg.Add('timer_start@:@', @f_start);
  Reg.Add('timer_stop@:@', @f_stop);
  Reg.AddHost('timer_ontimer@:@$', @f_ontimer);
end;

end.
