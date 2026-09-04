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
  SysUtils, Classes, Controls, StdCtrls, Spin, MaskEdit,
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
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TEdit, c) then TEdit(c).MaxLength := ArgI32(Args[1]); Result := Args[0]; end;
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
    n := ArgI32(Args[1]);   // 1-based
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

// --- spin edit (integer) ----------------------------------------------------
function f_spinedit(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; s: TSpinEdit;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  s := TSpinEdit.Create(pc); s.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(s, False));
end;
function f_spin_value_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TSpinEdit, c) then TSpinEdit(c).Value := ArgI32(A[1]); Result := A[0]; end;
function f_spin_value_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TSpinEdit, c) then Result := ValInt(TSpinEdit(c).Value) else Result := ValInt(0); end;
function f_spin_min_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TSpinEdit, c) then TSpinEdit(c).MinValue := ArgI32(A[1]); Result := A[0]; end;
function f_spin_max_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TSpinEdit, c) then TSpinEdit(c).MaxValue := ArgI32(A[1]); Result := A[0]; end;
function f_spin_onchange(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0]; if GuiResolve(A[0].Hnd, TSpinEdit, c) then TSpinEdit(c).OnChange := GuiNotifyHandler(AVM, c, 'onchange', A[1].Str, A[0].Hnd); end;

// --- float spin edit --------------------------------------------------------
function f_floatspin(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; s: TFloatSpinEdit;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  s := TFloatSpinEdit.Create(pc); s.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(s, False));
end;
function f_fspin_value_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TFloatSpinEdit, c) then TFloatSpinEdit(c).Value := AsDouble(A[1]); Result := A[0]; end;
function f_fspin_value_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TFloatSpinEdit, c) then Result := ValDouble(TFloatSpinEdit(c).Value) else Result := ValDouble(0); end;
function f_fspin_decimals_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TFloatSpinEdit, c) then TFloatSpinEdit(c).DecimalPlaces := ArgI32(A[1]); Result := A[0]; end;

// --- mask edit --------------------------------------------------------------
function f_maskedit(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; m: TMaskEdit;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  m := TMaskEdit.Create(pc); m.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(m, False));
end;
function f_mask_text_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TMaskEdit, c) then TMaskEdit(c).Text := A[1].Str; Result := A[0]; end;
function f_mask_text_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TMaskEdit, c) then Result := ValStr(TMaskEdit(c).Text) else Result := ValStr(''); end;
function f_mask_mask_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TMaskEdit, c) then TMaskEdit(c).EditMask := A[1].Str; Result := A[0]; end;
function f_mask_mask_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TMaskEdit, c) then Result := ValStr(TMaskEdit(c).EditMask) else Result := ValStr(''); end;

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

  Reg.Add('spinedit@:@', @f_spinedit);
  Reg.Add('spinedit_value@:@n', @f_spin_value_set); Reg.Add('spinedit_value:@', @f_spin_value_get);
  Reg.Add('spinedit_min@:@n', @f_spin_min_set);     Reg.Add('spinedit_max@:@n', @f_spin_max_set);
  Reg.AddHost('spinedit_onchange@:@$', @f_spin_onchange);

  Reg.Add('floatspinedit@:@', @f_floatspin);
  Reg.Add('floatspinedit_value@:@n', @f_fspin_value_set); Reg.Add('floatspinedit_value:@', @f_fspin_value_get);
  Reg.Add('floatspinedit_decimals@:@n', @f_fspin_decimals_set);

  Reg.Add('maskedit@:@', @f_maskedit);
  Reg.Add('maskedit_text@:@$', @f_mask_text_set); Reg.Add('maskedit_text$:@', @f_mask_text_get);
  Reg.Add('maskedit_mask@:@$', @f_mask_mask_set); Reg.Add('maskedit_mask$:@', @f_mask_mask_get);
end;

end.
