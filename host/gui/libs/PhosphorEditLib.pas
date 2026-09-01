{******************************************************************************
  Phosphor BASIC -- edit library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  The text-entry controls: a single-line edit and a multi-line memo. Geometry,
  colour, font, enabled/visible come from PhosphorControlLib; this package adds
  their text, the memo's line access, and the onchange event.

    edit@(parent@)
    edit_text@(e@, s$)   edit_text$(e@)
    edit_readonly@(e@, n)  edit_readonly(e@)
    edit_maxlength@(e@, n) edit_maxlength(e@)
    edit_selectall@(e@)    edit_clear@(e@)
    edit_onchange@(e@, "func")

    memo@(parent@)
    memo_text@(m@, s$)   memo_text$(m@)
    memo_addline@(m@, s$)  memo_linecount(m@)  memo_line$(m@, n)   (n is 1-based)
    memo_clear@(m@)        memo_wordwrap@(m@, n)  memo_wordwrap(m@)
    memo_readonly@(m@, n)  memo_readonly(m@)
    memo_onchange@(m@, "func")
******************************************************************************}
unit PhosphorEditLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, StdCtrls,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterEditFuncs(Reg: TPhosphorRegistry);

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

// --- edit -------------------------------------------------------------------
function f_edit(const Args: array of TValue; out Err: TPhosphorError): TValue;
var pc: TComponent; e: TEdit;
begin
  Err := NoError;
  if not GuiResolve(Args[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  e := TEdit.Create(pc);
  e.Parent := TWinControl(pc);
  e.Text := '';
  Result := ValHandle(GuiRegister(e, False));
end;

function f_edit_text_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TEdit, c) then TEdit(c).Text := Args[1].Str; Result := Args[0]; end;
function f_edit_text_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TEdit, c) then Result := ValStr(TEdit(c).Text) else Result := ValStr(''); end;
function f_edit_readonly_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TEdit, c) then TEdit(c).ReadOnly := ArgOn(Args[1]); Result := Args[0]; end;
function f_edit_readonly_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TEdit, c) then Result := ValInt(Ord(TEdit(c).ReadOnly)) else Result := ValInt(0); end;
function f_edit_maxlength_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TEdit, c) then TEdit(c).MaxLength := Round(AsDouble(Args[1])); Result := Args[0]; end;
function f_edit_maxlength_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TEdit, c) then Result := ValInt(TEdit(c).MaxLength) else Result := ValInt(0); end;
function f_edit_selectall(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TEdit, c) then TEdit(c).SelectAll; Result := Args[0]; end;
function f_edit_clear(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TEdit, c) then TEdit(c).Clear; Result := Args[0]; end;
function f_edit_onchange(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin
  Err := NoError; Result := Args[0];
  if GuiResolve(Args[0].Hnd, TEdit, c) then
    TEdit(c).OnChange := GuiNotifyHandler(AVM, c, 'onchange', Args[1].Str, Args[0].Hnd);
end;

// --- memo -------------------------------------------------------------------
function f_memo(const Args: array of TValue; out Err: TPhosphorError): TValue;
var pc: TComponent; m: TMemo;
begin
  Err := NoError;
  if not GuiResolve(Args[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  m := TMemo.Create(pc);
  m.Parent := TWinControl(pc);
  m.Lines.Clear;
  Result := ValHandle(GuiRegister(m, False));
end;

function f_memo_text_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TMemo, c) then TMemo(c).Text := Args[1].Str; Result := Args[0]; end;
function f_memo_text_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TMemo, c) then Result := ValStr(TMemo(c).Text) else Result := ValStr(''); end;
function f_memo_addline(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TMemo, c) then TMemo(c).Lines.Add(Args[1].Str); Result := Args[0]; end;
function f_memo_linecount(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TMemo, c) then Result := ValInt(TMemo(c).Lines.Count) else Result := ValInt(0); end;
function f_memo_line_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; n: Integer;
begin
  Err := NoError; Result := ValStr('');
  if GuiResolve(Args[0].Hnd, TMemo, c) then
  begin
    n := Round(AsDouble(Args[1]));   // 1-based
    if (n >= 1) and (n <= TMemo(c).Lines.Count) then Result := ValStr(TMemo(c).Lines[n - 1]);
  end;
end;
function f_memo_clear(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TMemo, c) then TMemo(c).Lines.Clear; Result := Args[0]; end;
function f_memo_wordwrap_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TMemo, c) then TMemo(c).WordWrap := ArgOn(Args[1]); Result := Args[0]; end;
function f_memo_wordwrap_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TMemo, c) then Result := ValInt(Ord(TMemo(c).WordWrap)) else Result := ValInt(0); end;
function f_memo_readonly_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TMemo, c) then TMemo(c).ReadOnly := ArgOn(Args[1]); Result := Args[0]; end;
function f_memo_readonly_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TMemo, c) then Result := ValInt(Ord(TMemo(c).ReadOnly)) else Result := ValInt(0); end;
function f_memo_onchange(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin
  Err := NoError; Result := Args[0];
  if GuiResolve(Args[0].Hnd, TMemo, c) then
    TMemo(c).OnChange := GuiNotifyHandler(AVM, c, 'onchange', Args[1].Str, Args[0].Hnd);
end;

procedure RegisterEditFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('edit@:@', @f_edit);
  Reg.Add('edit_text@:@$', @f_edit_text_set);
  Reg.Add('edit_text$:@',  @f_edit_text_get);
  Reg.Add('edit_readonly@:@n', @f_edit_readonly_set);
  Reg.Add('edit_readonly:@',   @f_edit_readonly_get);
  Reg.Add('edit_maxlength@:@n', @f_edit_maxlength_set);
  Reg.Add('edit_maxlength:@',   @f_edit_maxlength_get);
  Reg.Add('edit_selectall@:@',  @f_edit_selectall);
  Reg.Add('edit_clear@:@',      @f_edit_clear);
  Reg.AddHost('edit_onchange@:@$', @f_edit_onchange);

  Reg.Add('memo@:@', @f_memo);
  Reg.Add('memo_text@:@$', @f_memo_text_set);
  Reg.Add('memo_text$:@',  @f_memo_text_get);
  Reg.Add('memo_addline@:@$', @f_memo_addline);
  Reg.Add('memo_linecount:@', @f_memo_linecount);
  Reg.Add('memo_line$:@n',    @f_memo_line_get);
  Reg.Add('memo_clear@:@',    @f_memo_clear);
  Reg.Add('memo_wordwrap@:@n', @f_memo_wordwrap_set);
  Reg.Add('memo_wordwrap:@',   @f_memo_wordwrap_get);
  Reg.Add('memo_readonly@:@n', @f_memo_readonly_set);
  Reg.Add('memo_readonly:@',   @f_memo_readonly_get);
  Reg.AddHost('memo_onchange@:@$', @f_memo_onchange);
end;

end.
