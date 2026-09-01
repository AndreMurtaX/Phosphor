{******************************************************************************
  Phosphor BASIC -- button library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

    button@(parent@)             a push button on a form (or container)
    button_caption@(b@, s$)      button_caption$(b@)
    button_onclick@(b@, name$)   bind the click to a BASIC routine by name;
                                 "" unwires it. The handler is
                                 function name(sender@) ... end function.
    button_click(b@)             fire the click programmatically -- the headless
                                 way to prove an event reaches its handler with
                                 no window shown and no message loop.

  button_onclick@ is the one host-aware function here: it is handed the executing
  VM and stores it in the event bridge, so the click can later run the handler
  through VM.CallUserFunc.
******************************************************************************}
unit PhosphorButtonLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, StdCtrls,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorVM, PhosphorGuiCore;

procedure RegisterButtonFuncs(Reg: TPhosphorRegistry);

implementation

function f_button(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  pc: TComponent;
  btn: TButton;
begin
  Err := NoError;
  if not GuiResolve(Args[0].Hnd, TWinControl, pc) then
  begin
    Result := ValHandle(0);   // bad parent: gui_error set, no control made
    Exit;
  end;
  btn := TButton.Create(pc);            // owned by the parent, freed with the tree
  btn.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(btn, False));   // non-owning wrapper
end;

function f_button_caption_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TButton, c) then TButton(c).Caption := Args[1].Str;
  Result := Args[0];
end;

function f_button_caption_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TButton, c) then Result := ValStr(TButton(c).Caption)
  else Result := ValStr('');
end;

function f_button_click(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TButton, c) then TButton(c).Click;
  Result := Args[0];
end;

function f_button_onclick(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  c: TComponent;
  btn: TButton;
  bridge: TGuiEventBridge;
begin
  Err := NoError;
  Result := Args[0];
  if not GuiResolve(Args[0].Hnd, TButton, c) then Exit;
  btn := TButton(c);
  if Args[1].Str = '' then
  begin
    btn.OnClick := nil;   // an empty name stops the event
    Exit;
  end;
  bridge := GuiBridgeOf(btn);
  bridge.Bind(TPhosphorVM(AVM), Args[1].Str, Args[0].Hnd);
  btn.OnClick := @bridge.Fire;
end;

procedure RegisterButtonFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('button@:@', @f_button);
  Reg.Add('button_caption@:@$', @f_button_caption_set);
  Reg.Add('button_caption$:@',  @f_button_caption_get);
  Reg.Add('button_click:@',     @f_button_click);
  Reg.AddHost('button_onclick@:@$', @f_button_onclick);
end;

end.
