{******************************************************************************
  Phosphor BASIC -- form library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  The window. A form owns its control tree, so its handle is the OWNING one
  (GuiRegister(..., True)); freeing it at ResetHandles frees every control under
  it. Constructors answer a handle; a setter returns the same handle (so calls
  read left to right and could chain); a getter reads the property. A bad handle
  is recorded in gui_error(), never raised -- the phase-1 contract, and the
  reference's 02_handles behaviour.

    form@()  form@(caption$)  form@(caption$, w, h)
    form_caption@(f@, s$)   form_caption$(f@)
    form_width@(f@, n)      form_width(f@)
    form_height@(f@, n)     form_height(f@)
    form_show@(f@)          -- realizes the window (interactive host)
    form_close@(f@)         form_visible(f@)
    form_onclose@(f@, name$)  form_onclosequery@(f@, "name?")

  THE @ ON form_show@ IS PART OF THE NAME. This block advertised it as form_show
  for a while, from before the suffix rule settled that a built-in's return type is
  read off its own name: form_show@ and form_close@ both answer the form handle, so
  they chain, so both are spelled with @ -- and a reader who copied the unsuffixed
  spelling out of this comment got "unknown function", the one failure mode a header
  comment exists to prevent. The last three lines were missing here entirely.
  Checked against RegisterFormFuncs below, which is the only authority.
******************************************************************************}
unit PhosphorFormLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, Forms,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorVM, PhosphorGuiCore;

procedure RegisterFormFuncs(Reg: TPhosphorRegistry);

implementation

type
  { Terminates the message loop when a top-level form is closed, so closing the
    window (the X button) ends the program the way a main form would. Hides rather
    than frees, so the handle registry frees the form once, at the end. }
  TFormCloser = class(TComponent)
    { The program's own OnClose handler, when it bound one. The closer calls it
      before terminating, rather than being replaced by it: a form has one OnClose
      and two things must happen on it, and losing the terminator would leave a
      window that cannot close the program it belongs to. }
    UserBridge: TGuiEventBridge;
    procedure DoClose(Sender: TObject; var CloseAction: TCloseAction);
    function Handler: TCloseEvent;
  end;

procedure TFormCloser.DoClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  if UserBridge <> nil then
    UserBridge.FireClose(Sender, CloseAction);   // the program sees it first
  CloseAction := caHide;
  Application.Terminate;
end;

function TFormCloser.Handler: TCloseEvent;
begin
  Result := @DoClose;
end;

{ The closer serving AForm, created and installed on demand. Both form_show and
  form_onclose@ go through this, so whichever the program calls first wins the
  installation and the other finds it. }
function CloserOf(AForm: TForm): TFormCloser;
var i: Integer;
begin
  for i := 0 to AForm.ComponentCount - 1 do
    if AForm.Components[i] is TFormCloser then
      Exit(TFormCloser(AForm.Components[i]));
  Result := TFormCloser.Create(AForm);   // owned by the form, freed with it
  AForm.OnClose := Result.Handler;
end;

function f_form(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  frm: TForm;
begin
  Err := NoError;
  frm := TForm.CreateNew(nil);
  if Length(Args) >= 1 then frm.Caption := Args[0].Str;
  if Length(Args) >= 3 then
  begin
    frm.Width := ArgI32(Args[1]);
    frm.Height := ArgI32(Args[2]);
  end;
  Result := ValHandle(GuiRegister(frm, True));   // a form owns its tree
end;

function f_form_caption_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TForm, c) then TForm(c).Caption := Args[1].Str;
  Result := Args[0];
end;

function f_form_caption_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TForm, c) then Result := ValStr(TForm(c).Caption)
  else Result := ValStr('');
end;

function f_form_width_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TForm, c) then TForm(c).Width := ArgI32(Args[1]);
  Result := Args[0];
end;

function f_form_width_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TForm, c) then Result := ValInt(TForm(c).Width)
  else Result := ValInt(0);
end;

function f_form_height_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TForm, c) then TForm(c).Height := ArgI32(Args[1]);
  Result := Args[0];
end;

function f_form_height_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TForm, c) then Result := ValInt(TForm(c).Height)
  else Result := ValInt(0);
end;

function f_form_show(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TForm, c) then
  begin
    // Find-or-create: if the program already bound form_onclose@, the closer is
    // there and keeps that binding rather than being replaced.
    CloserOf(TForm(c));
    TForm(c).Show;
  end;
  Result := Args[0];
end;

// --- the two form-lifetime events ------------------------------------------
function f_form_onclose(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; br: TGuiEventBridge;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TForm, c) then Exit;
  if A[1].Str = '' then
    CloserOf(TForm(c)).UserBridge := nil          // unbind, keeping the terminator
  else
  begin
    br := GuiBridgeOf(c, 'onclose');
    br.Bind(TPhosphorVM(AVM), A[1].Str, A[0].Hnd);
    CloserOf(TForm(c)).UserBridge := br;
  end;
end;

function f_form_onclosequery(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TForm, c) then
    TForm(c).OnCloseQuery := GuiCloseQueryHandler(AVM, c, 'onclosequery', A[1].Str, A[0].Hnd);
end;

{ Ask the form to close, the way the X button does -- so a headless test can
  exercise OnCloseQuery and OnClose without a window manager. }
function f_form_close(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TForm, c) then TForm(c).Close;
end;

{ True while the form is still visible: what a program reads after asking it to
  close, to see whether an OnCloseQuery handler vetoed. }
function f_form_visible(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TForm, c) then Result := ValInt(Ord(TForm(c).Visible));
end;

procedure RegisterFormFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('form@:',   @f_form);
  Reg.Add('form@:$',  @f_form);
  Reg.Add('form@:$nn', @f_form);   // int w,h widen to n
  Reg.Add('form_caption@:@$', @f_form_caption_set);
  Reg.Add('form_caption$:@',  @f_form_caption_get);
  Reg.Add('form_width@:@n',   @f_form_width_set);
  Reg.Add('form_width:@',     @f_form_width_get);
  Reg.Add('form_height@:@n',  @f_form_height_set);
  Reg.Add('form_height:@',    @f_form_height_get);
  Reg.Add('form_show@:@',      @f_form_show);
  Reg.Add('form_close@:@',    @f_form_close);
  Reg.Add('form_visible:@',   @f_form_visible);
  Reg.AddHost('form_onclose@:@$',      @f_form_onclose);
  Reg.AddHost('form_onclosequery@:@$', @f_form_onclosequery);
end;

end.
