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
  SysUtils, Classes, ExtCtrls, CustomTimer,
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

{ TIdleTimer fires when the application goes idle rather than on a clock, which
  is the shape a background task wants: it yields to the user instead of competing
  with them. Same helpers as timer@ -- both descend from TCustomTimer, so interval,
  enabled, start, stop and ontimer all resolve against that. }
function f_idletimer(const A: array of TValue; out E: TPhosphorError): TValue;
var t: TIdleTimer;
begin
  E := NoError;
  t := TIdleTimer.Create(nil);   // no owner: the handle wrapper owns it
  t.Enabled := False;
  t.AutoEnabled := False;        // explicit, like timer@: a program starts it
  Result := ValHandle(GuiRegister(t, True));
end;

{ AN INTERVAL IS A Cardinal (TCustomTimer.SetInterval, lcl/customtimer.pas), and a
  negative 32-bit count handed to one wraps: timer_interval@(t@, -1) read back
  4294967295 -- a tick every 49.7 days, from a number that meant "as soon as you
  can" or "never" (2026-10-09, round 4). A negative interval is 0 now, the one
  Cardinal value it can honestly mean; a positive one is taken as before. }
function f_interval_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; n: Integer; begin E := NoError;
  if GuiResolve(A[0].Hnd, TCustomTimer, c) then
  begin
    n := ArgI32(A[1]);
    if n < 0 then n := 0;
    TCustomTimer(c).Interval := Cardinal(n);
  end;
  Result := A[0]; end;
function f_interval_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCustomTimer, c) then Result := ValInt(TCustomTimer(c).Interval) else Result := ValInt(0); end;
function f_enabled_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCustomTimer, c) then TCustomTimer(c).Enabled := ArgOn(A[1]); Result := A[0]; end;
function f_enabled_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCustomTimer, c) then Result := ValInt(Ord(TCustomTimer(c).Enabled)) else Result := ValInt(0); end;
function f_start(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCustomTimer, c) then TCustomTimer(c).Enabled := True; Result := A[0]; end;
function f_stop(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCustomTimer, c) then TCustomTimer(c).Enabled := False; Result := A[0]; end;
{ A TICK DOES NOT RE-ENTER ITS OWN HANDLER (round 5, 2026-10-10). A handler that
  waits -- in form_showmodal, a message box, app_processmessages -- runs a message
  loop, and on Windows the timer's WM_TIMER is dispatched inside it, so the same
  handler started again while its first run was suspended: a "reminder" timer that
  opens a modal each tick stacked modals without bound. GTK's timeout source does
  not recurse, so on Linux the same program saw no tick at all until the handler
  returned. The guard makes Windows answer as Linux does: a tick that arrives while
  this timer's handler is running is dropped. Other timers still fire. }
type
  TTimerGuard = class(TComponent)
  public
    Notify: TNotifyEvent;
    Busy: Boolean;
    procedure Fire(Sender: TObject);
  end;

procedure TTimerGuard.Fire(Sender: TObject);
begin
  if Busy or not Assigned(Notify) then Exit;
  Busy := True;
  try
    Notify(Sender);
  finally
    Busy := False;
  end;
end;

function TimerGuardOf(ATimer: TComponent): TTimerGuard;
var i: Integer;
begin
  for i := 0 to ATimer.ComponentCount - 1 do
    if ATimer.Components[i] is TTimerGuard then Exit(TTimerGuard(ATimer.Components[i]));
  Result := TTimerGuard.Create(ATimer);
end;

function f_ontimer(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; ev: TNotifyEvent; g: TTimerGuard;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TCustomTimer, c) then Exit;
  ev := GuiNotifyHandler(AVM, c, 'ontimer', A[1].Str, A[0].Hnd);
  if ev = nil then
  begin
    TCustomTimer(c).OnTimer := nil;   // an empty name unwires, as everywhere else
    Exit;
  end;
  g := TimerGuardOf(c);
  g.Notify := ev;
  TCustomTimer(c).OnTimer := @g.Fire;
end;

procedure RegisterTimerFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('timer@:', @f_timer);
  Reg.Add('idletimer@:', @f_idletimer);
  Reg.Add('timer_interval@:@n', @f_interval_set); Reg.Add('timer_interval:@', @f_interval_get);
  Reg.Add('timer_enabled@:@n', @f_enabled_set);   Reg.Add('timer_enabled:@', @f_enabled_get);
  Reg.Add('timer_start@:@', @f_start);
  Reg.Add('timer_stop@:@', @f_stop);
  Reg.AddHost('timer_ontimer@:@$', @f_ontimer);
end;

end.
