{******************************************************************************
  Phosphor BASIC -- GUI core (shared by the GUI control packages)

  MIT License. Copyright (c) 2026 Andre Murta.

  This unit and its siblings under host/gui/libs are the SECOND consumer of the
  engine, exactly as host/console is the first. They may use the LCL; the engine
  may not, and the boundary check (which scans only engine/) keeps that true. A
  GUI package integrates through the same registry the engine libraries use --
  Reg.Add for plain functions, Reg.AddHost for the one kind that must call back
  into BASIC (an event handler).

  Two mechanisms live here:

  * Control handles. An LCL control is held in the ENGINE's handle registry (the
    same 1-based '@' ids arrays and dicts use), wrapped in a TGuiHandle so the
    registry can free every handle uniformly without double-freeing the LCL tree:
    the wrapper frees its control only when it OWNS it. A form owns its control
    tree (LCL frees children with their parent), so only the form's wrapper owns;
    a child control's wrapper does not. ResetHandles then frees each wrapper, the
    form wrapper frees the form (and LCL cascades to the children), and the child
    wrappers free nothing. This mirrors PhosphorJsonLib's owning/non-owning nodes.

  * Event delivery. An event binds to a BASIC routine by name. TGuiEventBridge
    holds the executing VM, the handler name and the sender's handle id; its Fire
    method (an LCL method pointer) runs the routine through the engine's
    host-callback seam (VM.CallUserFunc) -- the very path 48_callback proved. The
    bridge is owned by its control, so it dies with it. The reference walked a
    control's parent chain up to the form to find the engine; Phosphor hands the
    bridge the VM directly at bind time.
******************************************************************************}
unit PhosphorGuiCore;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, Forms,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorVM;

type
  { A registry entry for an LCL object. Owns is true only for a top-level form;
    a child control's wrapper leaves the LCL parent/owner chain to free it. }
  TGuiHandle = class
    Control: TComponent;
    Owns: Boolean;
    destructor Destroy; override;
  end;

  { Carries one bound event back into BASIC. Owned by the control it serves. }
  TGuiEventBridge = class(TComponent)
  private
    FVM: TPhosphorVM;
    FHandler: String;
    FSenderId: Int64;
  public
    procedure Bind(AVM: TPhosphorVM; const AHandler: String; ASenderId: Int64);
    procedure Fire(Sender: TObject);   // matches TNotifyEvent
    property Handler: String read FHandler;
  end;

var
  { Last GUI error, in the phase-1 spirit: recorded, never raised. 0 = ok. A bad
    handle is 1; a handler that failed at run time is 2. }
  GGuiError: Integer;

{ Register AControl under a fresh '@' handle; AOwns ties its lifetime here. }
function GuiRegister(AControl: TComponent; AOwns: Boolean): Int64;
{ Resolve a handle to an object of (at least) AClass. Records GGuiError and
  returns False on a fabricated, freed or wrong-class handle. }
function GuiResolve(AId: Int64; AClass: TClass; out AComp: TComponent): Boolean;
{ The bridge bound to AControl for its single event, created on demand. }
function GuiBridgeOf(AControl: TComponent): TGuiEventBridge;

procedure RegisterGuiCoreFuncs(Reg: TPhosphorRegistry);

implementation

destructor TGuiHandle.Destroy;
begin
  if Owns and (Control <> nil) then
    Control.Free;
  inherited Destroy;
end;

procedure TGuiEventBridge.Bind(AVM: TPhosphorVM; const AHandler: String; ASenderId: Int64);
begin
  FVM := AVM;
  FHandler := AHandler;
  FSenderId := ASenderId;
end;

procedure TGuiEventBridge.Fire(Sender: TObject);
var
  err: TPhosphorError;
begin
  if (FVM = nil) or (FHandler = '') then Exit;
  FVM.CallUserFunc(FHandler, [ValHandle(FSenderId)], err);
  if IsError(err) then
    GGuiError := 2;   // a handler that failed is recorded, not raised
end;

function GuiRegister(AControl: TComponent; AOwns: Boolean): Int64;
var
  h: TGuiHandle;
begin
  h := TGuiHandle.Create;
  h.Control := AControl;
  h.Owns := AOwns;
  Result := RegisterHandle(h);
end;

function GuiResolve(AId: Int64; AClass: TClass; out AComp: TComponent): Boolean;
var
  o: TObject;
  h: TGuiHandle;
begin
  AComp := nil;
  o := HandleObj(AId);
  if not (o is TGuiHandle) then
  begin
    GGuiError := 1;   // fabricated, freed, or not a GUI handle at all
    Exit(False);
  end;
  h := TGuiHandle(o);
  if (h.Control = nil) or not h.Control.InheritsFrom(AClass) then
  begin
    GGuiError := 1;   // a valid handle, but of the wrong class
    Exit(False);
  end;
  AComp := h.Control;
  Result := True;
end;

function GuiBridgeOf(AControl: TComponent): TGuiEventBridge;
var
  i: Integer;
begin
  for i := 0 to AControl.ComponentCount - 1 do
    if AControl.Components[i] is TGuiEventBridge then
      Exit(TGuiEventBridge(AControl.Components[i]));
  Result := TGuiEventBridge.Create(AControl);   // owned by the control
end;

// --- app_* : the message loop, for the interactive host ---------------------
function f_app_run(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Application.Run;
  Result := ValInt(0);
end;
function f_app_processmessages(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Application.ProcessMessages;
  Result := ValInt(0);
end;
function f_app_quit(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Application.Terminate;
  Result := ValInt(0);
end;

// --- the shared GUI error state ---------------------------------------------
function f_gui_error(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(GGuiError); end;
function f_gui_clearerror(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; GGuiError := 0; Result := ValInt(0); end;

procedure RegisterGuiCoreFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('app_run:', @f_app_run);
  Reg.Add('app_processmessages:', @f_app_processmessages);
  Reg.Add('app_quit:', @f_app_quit);
  Reg.Add('gui_error:', @f_gui_error);
  Reg.Add('gui_clearerror:', @f_gui_clearerror);
end;

initialization
  GGuiError := 0;

end.
