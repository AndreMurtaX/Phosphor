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
    form_showmodal(f@)        -- shows it MODALLY: waits, answers its result
    form_modalresult@(f@, n)  form_modalresult(f@)

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

type
  { THE MODAL SEAM, for a host that must not wait. ShowModal runs a message loop
    until the form's ModalResult is set -- by a button whose ModalResult is set,
    by form_modalresult@, or by closing it -- and a headless test run that let it
    would wait forever, exactly the reason PhosphorDialogLib's three hooks exist.
    nil (the default) shows the form for real. A hook stands in for the WHOLE
    modal session: it is handed the VM, the form and the form's handle, lets the
    program act inside the form (host/gui/phosphorguitest.lpr calls a BASIC
    function the test queued, which fills fields and clicks buttons), and answers
    the result ShowModal would have. The form's ModalResult is 0 when it is called.

    ROUND BY ROUND (round 5, 2026-10-10). The first hook stood in for the whole
    session and answered the result, so inside it the form was neither visible
    nor modal, onclosequery and onclose never ran, a vetoed OK answered 1, and
    form_close@ took the non-modal path. Now THIS unit runs the session and the
    hook only acts: it is called once per round (ARound counts from 1) and
    answers False when there is nobody left to act. Between rounds the session
    does what TCustomForm.ShowModal does (lcl/include/customform.inc): the form
    is visible and refuses a second modal, form_close@ answers mrCancel, a
    non-zero result goes through CloseModal -- CloseQuery, then DoClose -- and a
    veto sets it back to 0 so the NEXT round acts on a form still open. }
  TFormShowModalHook = function(AVM: TObject; AForm: TCustomForm;
    AHandle: Int64; ARound: Integer): Boolean;

var
  FormShowModalHook: TFormShowModalHook = nil;

implementation

var
  { The forms in a hook-run modal session: what fsModal says for a real one. }
  GHookModal: array of TCustomForm;

function InHookModal(AForm: TObject): Boolean;
var i: Integer;
begin
  for i := 0 to High(GHookModal) do
    if GHookModal[i] = AForm then Exit(True);
  Result := False;
end;

{ Is this form in a modal session, real or run by a hook? }
function InModalSession(AForm: TObject): Boolean;
begin
  Result := (AForm is TCustomForm) and
            ((fsModal in TCustomForm(AForm).FormState) or InHookModal(AForm));
end;

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

  { CLOSING A WINDOW ENDS THE LOOP ONLY WHEN IT WAS THE LAST WINDOW.

    Two things were wrong on one line, and both are documented the other way.

    It called Application.Terminate, which sets a flag the LCL gives no public
    way to clear -- so once ANY window had been closed, every later app_run() in
    that process returned instantly having dispatched nothing. The playbook's
    round 28 records this exact defect as fixed for app_quit, and it was: the fix
    landed in app_quit and this second caller kept doing it. gui-core.md says of
    app_quit "It leaves the application usable -- a later app_run() enters the
    loop normally", and that has to be true of closing a window too.

    And it fired for ANY form, not the last one. gui-core.md scopes termination
    to "closing the LAST window", so a program showing two windows lost its
    message loop when the user closed either of them -- with the other still open
    and, from the user's side, still expected to work.

    So: leave the loop through GuiLeaveLoop, which sets the flag the loop reads
    and does not touch Application.Terminated -- and only when nothing else is
    still shown. The form being closed is excluded from the count because
    CloseAction has only just been set and it is still Visible here. }
  { ANSWERING A MODAL IS NOT CLOSING A WINDOW (round 5). CloseModal runs DoClose
    on every answer -- OK as much as [X] -- and with no other form shown this
    ended app_run the moment a tray- or timer-driven program's dialog was
    answered. A modal session ends itself; the loop is not this form's to end. }
  if (not GuiOtherFormShown(Sender)) and (not InModalSession(Sender)) then
    GuiLeaveLoop;
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
  // A form is a TControl too, so form@(caption$, w, h) is held to the same
  // ceiling as control_width@ -- see GuiMaxExtent. Refused, the window keeps the
  // default size it was created with and gui_error() says so.
  if Length(Args) >= 3 then
    if GuiExtentOk(ArgI32(Args[1]), ArgI32(Args[2])) then
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

{ A form's size is held to GuiMaxExtent before the LCL sees it, and a resize the
  LCL still refuses -- the layout of the children it sets off can raise on a shown
  window -- is undone and recorded rather than left standing, the rule
  control_width@ follows (PhosphorControlLib.SafeSetBounds). }
procedure SafeFormSize(F: TForm; W, H: Integer);
var oW, oH: Integer;
begin
  oW := F.Width; oH := F.Height;
  try
    F.SetBounds(F.Left, F.Top, W, H);
  except
    on Exception do
    begin
      GGuiError := 1;
      try F.SetBounds(F.Left, F.Top, oW, oH); except on Exception do ; end;
    end;
  end;
end;

function f_form_width_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TForm, c) and GuiExtentOk(ArgI32(Args[1]), 0) then
    SafeFormSize(TForm(c), ArgI32(Args[1]), TForm(c).Height);
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
  if GuiResolve(Args[0].Hnd, TForm, c) and GuiExtentOk(0, ArgI32(Args[1])) then
    SafeFormSize(TForm(c), TForm(c).Width, ArgI32(Args[1]));
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
  if not GuiResolve(A[0].Hnd, TForm, c) then Exit;
  { A form in a hook-run modal session closes the way a modal one does:
    TCustomForm.Close sets mrCancel when fsModal is set, and nothing else. }
  if InHookModal(c) then
  begin
    TForm(c).ModalResult := mrCancel;
    Exit;
  end;
  // THE FORM BELONGS TO THE LCL FOR THE LENGTH OF Close. Close runs OnCloseQuery
  // and OnClose, then goes on writing CloseAction and hiding the window; any BASIC
  // routine reached from inside that -- the close handlers themselves, or an
  // onchange a hide happens to fire -- must not be able to destroy the object the
  // unwinding code is still standing on. The two close bridges mark the sender
  // themselves; marking it here as well covers every other callback the close
  // sequence can reach. GuiInUse only makes control_free ANSWER gui_error 1
  // instead of freeing, so the window still dies at ResetHandles as it always has.
  GuiEnterCallback(c);
  try
    TForm(c).Close;
  finally
    GuiLeaveCallback(c);
  end;
end;

{ SHOW IT MODALLY: the program waits here, inside this call, until the form is
  answered -- and the event handlers of the form's own controls run meanwhile, so
  a dialog built from a form behaves as one does anywhere else. Answers the
  ModalResult (the LCL's mr* values: 1 OK, 2 Cancel, 6 Yes, 7 No, ...); closing it
  with [X] or form_close@ answers 2, which is what TCustomForm.Close sets on a
  modal form. A form the LCL cannot make modal -- one already shown, disabled, or
  already modal -- is refused as every GUI refusal is: 0 and gui_error 1, never
  the EInvalidOperation ShowModal raises. The form stays alive while it is modal:
  marked in use, so a handler's control_free of it is refused, like a closing
  form's. It is not shown afterwards, and it can be shown modally again. }
type
  TFormAccess = class(TCustomForm);   // DoClose is protected

  { Between the messages of a real modal session: free what was queued inside
    it (GuiFlushFreesSince's reasoning). }
  TModalIdle = class
    Mark, Depth: Integer;
    procedure Idle(Sender: TObject; var Done: Boolean);
  end;

procedure TModalIdle.Idle(Sender: TObject; var Done: Boolean);
begin
  GuiFlushFreesSince(Mark, Depth);
end;

{ What TCustomForm.CloseModal does with a non-zero ModalResult: ask CloseQuery,
  then DoClose; a veto -- or an OnClose that answers caNone -- puts the result
  back to 0 and the session goes on. }
procedure EmulateCloseModal(F: TForm);
var ca: TCloseAction;
begin
  ca := caNone;
  if F.CloseQuery then
  begin
    ca := caHide;
    TFormAccess(F).DoClose(ca);
  end;
  if ca = caNone then F.ModalResult := mrNone;
end;

procedure AddHookModal(F: TCustomForm);
begin
  SetLength(GHookModal, Length(GHookModal) + 1);
  GHookModal[High(GHookModal)] := F;
end;

procedure RemoveHookModal(F: TCustomForm);
var i, j: Integer;
begin
  for i := High(GHookModal) downto 0 do
    if GHookModal[i] = F then
    begin
      for j := i to High(GHookModal) - 1 do GHookModal[j] := GHookModal[j + 1];
      SetLength(GHookModal, Length(GHookModal) - 1);
      Exit;
    end;
end;

function f_form_showmodal(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var
  c: TComponent; f: TForm; r, round, mark, depth: Integer;
  idle: TModalIdle;
begin
  E := NoError; Result := ValInt(0);
  if not GuiResolve(A[0].Hnd, TForm, c) then Exit;
  f := TForm(c);
  { A form parented inside another is refused too (round 5): its buttons answer
    the TOP form (TCustomButton.Click uses GetParentForm), so its session could
    never end by its own buttons, and GTK complains it is not a window. }
  if f.Visible or (not f.Enabled) or (fsModal in f.FormState) or
     (f.Parent <> nil) or InHookModal(f) then
  begin
    GGuiError := 1;
    Exit;
  end;
  r := 0;
  mark := GuiPendingMark();
  depth := GuiDispatchDepth();
  GuiEnterCallback(c);
  try
    try
      if Assigned(FormShowModalHook) then
      begin
        f.ModalResult := mrNone;
        AddHookModal(f);
        try
          f.Visible := True;
          round := 0;
          while f.ModalResult = mrNone do
          begin
            Inc(round);
            if not FormShowModalHook(AVM, f, A[0].Hnd, round) then
            begin
              f.ModalResult := mrCancel;   // nobody left to act: as if closed
              Break;
            end;
            GuiFlushFreesSince(mark, depth);
            if TPhosphorVM(AVM).Halted then
            begin
              if f.ModalResult = mrNone then f.ModalResult := mrCancel;
              Break;
            end;
            if f.ModalResult <> mrNone then EmulateCloseModal(f);
          end;
          r := f.ModalResult;
        finally
          RemoveHookModal(f);
          f.Visible := False;
        end;
      end
      else
      begin
        idle := TModalIdle.Create;
        idle.Mark := mark;
        idle.Depth := depth;
        Application.AddOnIdleHandler(@idle.Idle, False);
        try
          r := f.ShowModal;
        finally
          Application.RemoveOnIdleHandler(@idle.Idle);
          idle.Free;
        end;
      end;
    except
      on Ex: Exception do
      begin
        GGuiError := 1;
        r := 0;
      end;
    end;
  finally
    GuiLeaveCallback(c);
  end;
  Result := ValInt(r);
end;

{ Answer a modal form: setting a non-zero result ends its modal session with that
  value. On a form that is not modal it is only stored, which is what lets the
  same OK handler serve a form shown either way. }
function f_form_modalresult_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TForm, c) then TForm(c).ModalResult := ArgI32(A[1]);
end;
function f_form_modalresult_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent;
begin
  E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TForm, c) then Result := ValInt(TForm(c).ModalResult);
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
  Reg.AddHost('form_showmodal:@', @f_form_showmodal);
  Reg.Add('form_modalresult@:@n', @f_form_modalresult_set);
  Reg.Add('form_modalresult:@',   @f_form_modalresult_get);
end;

end.
