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
  SysUtils, Classes, Types, Controls, Forms,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorVM;

type
  { A registry entry for an LCL object. Control is a TObject so a handle can also
    wrap a non-TComponent (a TTreeNode, a TListItem), not only a control. Owns is
    true only for a top-level form (or a timer): its wrapper frees it. A child
    control, a node or an item is non-owning -- its container frees it.

    It is a TComponent for one reason: so it can receive Notification. A form owns
    its tree, so freeing the form frees its children, and a handle pointing at one
    of those children used to be left holding a dangling pointer that GuiResolveObj
    then dereferenced to ask its class -- an access violation reachable from
    ordinary BASIC, and a breach of this unit's own rule that a freed handle is
    ANSWERED, never raised. Watch() asks the control to say when it dies; the
    reference is dropped and every later use resolves to gui_error 1.

    A handle wrapping a NON-component (a TBitmap, a TTreeNode, a TListItem) cannot
    be watched: FreeNotification is a TComponent service. Those keep the older,
    weaker guarantee -- do not free a tree while holding handles to its nodes. }
  TGuiHandle = class(TComponent)
  public
    // EXPLICIT visibility: TComponent is compiled {$M+}, so members with no section
    // default to PUBLISHED, and a plain TObject field cannot be published.
    Control: TObject;
    Owns: Boolean;
    { True only when Control WAS a TComponent at registration time, so the
      destructor never has to ask again. `c is TComponent` reads the object's VMT,
      which is a DEREFERENCE -- on a TTreeNode already destroyed with its tree that
      is the very access violation this class exists to prevent. Remembering the
      answer costs a byte and asks nothing of a dead pointer. }
    Watched: Boolean;
    { Arm the death notice, when the wrapped object is able to send one. }
    procedure Watch;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    destructor Destroy; override;
  end;

  { Carries one bound event back into BASIC. Owned by the control it serves; one
    bridge per event name, so a control can wire onclick AND onchange at once. }
  TGuiEventBridge = class(TComponent)
  private
    FVM: TPhosphorVM;
    FHandler: String;
    FSenderId: Int64;
    FEventName: String;   // which event this bridge serves (e.g. 'onclick')
    { Every variant funnels through this: build the argument list, call into
      BASIC, record a failing handler as error 2, and honour END. Returns what the
      handler answered so the two var-parameter events can read it. }
    function Call(const AArgs: array of TValue): TValue;
  public
    procedure Bind(AVM: TPhosphorVM; const AHandler: String; ASenderId: Int64);
    { One method per LCL event signature. The name after Fire is the signature, not
      the event: OnKeyDown and OnKeyUp are both TKeyEvent and share FireKey. }
    procedure Fire(Sender: TObject);                                        // TNotifyEvent
    procedure FireKey(Sender: TObject; var Key: Word; Shift: TShiftState);  // TKeyEvent
    procedure FireKeyPress(Sender: TObject; var Key: char);                 // TKeyPressEvent
    procedure FireMouse(Sender: TObject; Button: TMouseButton;
                        Shift: TShiftState; X, Y: Integer);                 // TMouseEvent
    procedure FireMouseMove(Sender: TObject; Shift: TShiftState;
                            X, Y: Integer);                                 // TMouseMoveEvent
    procedure FireMouseWheel(Sender: TObject; Shift: TShiftState;
                             WheelDelta: Integer; MousePos: TPoint;
                             var Handled: Boolean);                         // TMouseWheelEvent
    procedure FireClose(Sender: TObject; var CloseAction: TCloseAction);     // TCloseEvent
    procedure FireCloseQuery(Sender: TObject; var CanClose: Boolean);        // TCloseQueryEvent
    property Handler: String read FHandler;
    property EventName: String read FEventName write FEventName;
  end;

var
  { Last GUI error, in the phase-1 spirit: recorded, never raised. 0 = ok. A bad
    handle is 1; a handler that failed at run time is 2. }
  GGuiError: Integer;

{ Register AObj under a fresh '@' handle; AOwns ties its lifetime here. }
function GuiRegister(AObj: TObject; AOwns: Boolean): Int64;
{ Resolve a handle to an object of (at least) AClass. Records GGuiError and
  returns False on a fabricated, freed or wrong-class handle. }
function GuiResolveObj(AId: Int64; AClass: TClass; out AObj: TObject): Boolean;
{ The common case: AClass is a TComponent subclass, so the object is a TComponent. }
function GuiResolve(AId: Int64; AClass: TClass; out AComp: TComponent): Boolean;
{ The bridge serving AControl's AEventName, created on demand (one per event). }
function GuiBridgeOf(AControl: TComponent; const AEventName: String): TGuiEventBridge;
{ Wire a TNotifyEvent by BASIC function name: find/create the bridge for AEvent,
  bind it, and return the method to assign to the control's event property -- or
  nil when AHandler is '' (which unwires). One line per event in a control lib. }
function GuiNotifyHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TNotifyEvent;
{ The same one line per event, for the other seven signatures. Each returns nil for
  an empty handler name, which unwires. }
function GuiKeyHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TKeyEvent;
function GuiKeyPressHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TKeyPressEvent;
function GuiMouseHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TMouseEvent;
function GuiMouseMoveHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TMouseMoveEvent;
function GuiMouseWheelHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TMouseWheelEvent;
function GuiCloseHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TCloseEvent;
function GuiCloseQueryHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TCloseQueryEvent;

{ Call a BASIC routine the way an event bridge does: record a failing handler as
  error 2, honour END, and answer what the routine returned. Exposed because a
  package may own an event signature GuiCore must not know about -- Grids'
  TDrawCellEvent is the first -- and duplicating this would duplicate the two rules
  that matter. }
function GuiCallBack(AVM: TPhosphorVM; const AHandler: String;
  const AArgs: array of TValue): TValue;

{ The modifier keys as the short string the handler receives: "S", "C", "A", joined
  by spaces in that order, so all three read "S C A" exactly as the plan specified.
  A program tests one with instr(mods$, "C") > 0. }
function GuiModsStr(Shift: TShiftState): String;

procedure RegisterGuiCoreFuncs(Reg: TPhosphorRegistry);

implementation

procedure TGuiHandle.Watch;
begin
  Watched := Control is TComponent;   // asked ONCE, while the pointer is certainly live
  if Watched then
    TComponent(Control).FreeNotification(Self);
end;

procedure TGuiHandle.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  // The control this handle names is going away. Drop the reference NOW, while the
  // pointer is still valid to compare -- after this the handle is stale, which is a
  // state the resolver already knows how to refuse.
  if (Operation = opRemove) and (AComponent = Control) then
    Control := nil;
end;

destructor TGuiHandle.Destroy;
var
  c: TObject;
begin
  // Take the reference away from the field FIRST. Freeing the control re-enters
  // Notification, and finding Control already nil there is what keeps that path
  // from mattering.
  c := Control;
  Control := nil;
  // Watched, not `c is TComponent`: a non-component handle (a TTreeNode, a
  // TListItem) may already have died with its container, and testing its class
  // would dereference it. Where Watched is true and the control has died, the
  // notification already set Control to nil, so c is nil here and nothing is asked.
  if Watched and (c <> nil) then
    TComponent(c).RemoveFreeNotification(Self);
  if Owns and (c <> nil) then
    c.Free;
  inherited Destroy;
end;

procedure TGuiEventBridge.Bind(AVM: TPhosphorVM; const AHandler: String; ASenderId: Int64);
begin
  FVM := AVM;
  FHandler := AHandler;
  FSenderId := ASenderId;
end;

function GuiCallBack(AVM: TPhosphorVM; const AHandler: String;
  const AArgs: array of TValue): TValue;
var
  err: TPhosphorError;
begin
  Result := ValInt(0);
  if (AVM = nil) or (AHandler = '') then Exit;
  Result := AVM.CallUserFunc(AHandler, AArgs, err);
  if IsError(err) then
    GGuiError := 2;   // a handler that failed is recorded, not raised
  // A handler that says END means the program is over. The engine records that
  // instead of quietly ending only the handler's own activation, so the window it
  // was clicked in has to go too -- otherwise `end` in a click handler is a
  // statement that does nothing, which is a worse answer than the bug it replaced.
  if AVM.Halted then
    Application.Terminate;
end;

function TGuiEventBridge.Call(const AArgs: array of TValue): TValue;
begin
  Result := GuiCallBack(FVM, FHandler, AArgs);
end;

procedure TGuiEventBridge.Fire(Sender: TObject);
begin
  Call([ValHandle(FSenderId)]);
end;

procedure TGuiEventBridge.FireKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  // Key stays a var parameter in the LCL signature, but the handler's answer does
  // NOT write to it: a routine that falls off its end would swallow the keystroke.
  Call([ValHandle(FSenderId), ValInt(Key), ValStr(GuiModsStr(Shift))]);
end;

procedure TGuiEventBridge.FireKeyPress(Sender: TObject; var Key: char);
begin
  Call([ValHandle(FSenderId), ValStr(Key)]);
end;

procedure TGuiEventBridge.FireMouse(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  // mbLeft/mbRight/mbMiddle are 0/1/2 by declaration order, which is the encoding
  // the plan specified.
  Call([ValHandle(FSenderId), ValInt(Ord(Button)), ValInt(X), ValInt(Y),
        ValStr(GuiModsStr(Shift))]);
end;

procedure TGuiEventBridge.FireMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
begin
  Call([ValHandle(FSenderId), ValInt(X), ValInt(Y), ValStr(GuiModsStr(Shift))]);
end;

procedure TGuiEventBridge.FireMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  v: TValue;
begin
  v := Call([ValHandle(FSenderId), ValInt(WheelDelta), ValInt(MousePos.X),
             ValInt(MousePos.Y), ValStr(GuiModsStr(Shift))]);
  // Only an explicit boolean true claims the wheel. A number, or no return at all,
  // leaves LCL's default handling in place.
  if (v.Kind = vkBool) and v.Bl then
    Handled := True;
end;

procedure TGuiEventBridge.FireClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  // Notification only. Rewriting CloseAction from a return value would turn a
  // handler that forgets to answer into one that changes what closing means.
  Call([ValHandle(FSenderId)]);
end;

procedure TGuiEventBridge.FireCloseQuery(Sender: TObject; var CanClose: Boolean);
var
  v: TValue;
begin
  v := Call([ValHandle(FSenderId)]);
  // Only an explicit boolean false vetoes. A handler that falls off its end must
  // not be able to make a window impossible to close -- that is the one failure
  // here a program cannot recover from.
  if (v.Kind = vkBool) and (not v.Bl) then
    CanClose := False;
end;

function GuiModsStr(Shift: TShiftState): String;
const
  NAMES: array[0..2] of String = ('S', 'C', 'A');
var
  i: Integer;
  present: array[0..2] of Boolean;
begin
  present[0] := ssShift in Shift;
  present[1] := ssCtrl in Shift;
  present[2] := ssAlt in Shift;
  Result := '';
  for i := 0 to 2 do
    if present[i] then
    begin
      if Result <> '' then Result := Result + ' ';
      Result := Result + NAMES[i];
    end;
end;

function GuiRegister(AObj: TObject; AOwns: Boolean): Int64;
var
  h: TGuiHandle;
begin
  h := TGuiHandle.Create(nil);   // owned by the phosphor handle registry, not the LCL
  h.Control := AObj;
  h.Owns := AOwns;
  h.Watch;                       // tell me when you die
  Result := RegisterHandle(h);
end;

function GuiResolveObj(AId: Int64; AClass: TClass; out AObj: TObject): Boolean;
var
  o: TObject;
  h: TGuiHandle;
begin
  AObj := nil;
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
  AObj := h.Control;
  Result := True;
end;

function GuiResolve(AId: Int64; AClass: TClass; out AComp: TComponent): Boolean;
var
  o: TObject;
begin
  AComp := nil;
  Result := GuiResolveObj(AId, AClass, o);
  if Result then AComp := TComponent(o);   // AClass is a TComponent subclass here
end;

function GuiBridgeOf(AControl: TComponent; const AEventName: String): TGuiEventBridge;
var
  i: Integer;
begin
  for i := 0 to AControl.ComponentCount - 1 do
    if (AControl.Components[i] is TGuiEventBridge) and
       (TGuiEventBridge(AControl.Components[i]).EventName = AEventName) then
      Exit(TGuiEventBridge(AControl.Components[i]));
  Result := TGuiEventBridge.Create(AControl);   // owned by the control
  Result.EventName := AEventName;
end;

{ Find-or-create the bridge for this event and bind it, or nil for an empty name.
  Every factory below is the same three lines with a different method taken. }
function BoundBridge(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TGuiEventBridge;
begin
  if AHandler = '' then Exit(nil);   // an empty name unwires the event
  Result := GuiBridgeOf(AControl, AEvent);
  Result.Bind(TPhosphorVM(AVM), AHandler, ASenderId);
end;

function GuiNotifyHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TNotifyEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.Fire;
end;

function GuiKeyHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TKeyEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireKey;
end;

function GuiKeyPressHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TKeyPressEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireKeyPress;
end;

function GuiMouseHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TMouseEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireMouse;
end;

function GuiMouseMoveHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TMouseMoveEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireMouseMove;
end;

function GuiMouseWheelHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TMouseWheelEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireMouseWheel;
end;

function GuiCloseHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TCloseEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireClose;
end;

function GuiCloseQueryHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TCloseQueryEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireCloseQuery;
end;

// --- app_* : the message loop, for the interactive host ---------------------
var
  GAppQuit: Boolean = False;   // set by app_quit, read by the loop below

function f_app_run(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  // OUR OWN LOOP, not Application.Run. app_quit used to call
  // Application.Terminate, which sets a flag the LCL gives no public way to
  // clear -- so once a program had left the loop, every later app_run() in that
  // process returned instantly, having dispatched nothing. A host that runs one
  // script after another, or an embedder driving the engine between loops, got a
  // GUI that silently stopped being a GUI. This loop is left by app_quit AND by
  // the application terminating (which is what closing the last window does), and
  // leaves the application usable either way.
  GAppQuit := False;
  while (not GAppQuit) and (not Application.Terminated) do
    Application.HandleMessage;
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
  // Leave the loop; do NOT terminate the application. "Stop showing this window
  // and give me back control" is what a script means here, and terminating made
  // that a one-way door for the whole process.
  GAppQuit := True;
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
