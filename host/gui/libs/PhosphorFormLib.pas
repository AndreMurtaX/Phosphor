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
    form_show(f@)           -- realizes the window (interactive host)
******************************************************************************}
unit PhosphorFormLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, Forms,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterFormFuncs(Reg: TPhosphorRegistry);

implementation

type
  { Terminates the message loop when a top-level form is closed, so closing the
    window (the X button) ends the program the way a main form would. Hides rather
    than frees, so the handle registry frees the form once, at the end. }
  TFormCloser = class(TComponent)
    procedure DoClose(Sender: TObject; var CloseAction: TCloseAction);
    function Handler: TCloseEvent;
  end;

procedure TFormCloser.DoClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caHide;
  Application.Terminate;
end;

function TFormCloser.Handler: TCloseEvent;
begin
  Result := @DoClose;
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
    if not Assigned(TForm(c).OnClose) then
      // The closer is owned by the form (freed with it) and reached only through
      // the assigned method pointer, so no local reference is kept.
      TForm(c).OnClose := TFormCloser.Create(c).Handler;
    TForm(c).Show;
  end;
  Result := Args[0];
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
  Reg.Add('form_show:@',      @f_form_show);
end;

end.
