{******************************************************************************
  Phosphor BASIC -- choice library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  The controls that pick a value: check box, radio button, combo box and list
  box. Geometry/colour/font come from PhosphorControlLib; this adds their state
  and item lists.

    checkbox@(parent@)     checkbox_caption@/$   checkbox_checked@/()   checkbox_onchange@
    radiobutton@(parent@)  radio_caption@/$      radio_checked@/()      radio_onchange@
    combobox@(parent@)     combo_add@  combo_count  combo_item$(c,n)  combo_clear@
                           combo_itemindex@/()   combo_text$   combo_onchange@
    listbox@(parent@)      list_add@   list_count   list_item$(l,n)   list_clear@
                           list_itemindex@/()    list_selected$   list_onclick@

  Item and selection indices are 1-BASED (Phosphor's convention): item n is
  Items[n-1], and itemindex answers the 1-based position, 0 when nothing is
  selected. Setting itemindex 0 selects nothing.
******************************************************************************}
unit PhosphorChoiceLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, StdCtrls,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterChoiceFuncs(Reg: TPhosphorRegistry);

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

function MakeChild(AParentId: Int64; AClass: TControlClass; out Ctrl: TControl): Boolean;
var pc: TComponent;
begin
  Result := GuiResolve(AParentId, TWinControl, pc);
  if not Result then begin Ctrl := nil; Exit; end;
  Ctrl := AClass.Create(pc);
  Ctrl.Parent := TWinControl(pc);
end;

// --- a shared items helper for combo and list -------------------------------
function ItemsOf(AId: Int64; AClass: TClass): TStrings;
var c: TComponent;
begin
  Result := nil;
  if not GuiResolve(AId, AClass, c) then Exit;
  if c is TComboBox then Result := TComboBox(c).Items
  else if c is TListBox then Result := TListBox(c).Items;
end;

function IndexGet(AId: Int64; AClass: TClass): Integer;   // 1-based, 0 = none
var c: TComponent; ix: Integer;
begin
  Result := 0;
  if not GuiResolve(AId, AClass, c) then Exit;
  if c is TComboBox then ix := TComboBox(c).ItemIndex
  else if c is TListBox then ix := TListBox(c).ItemIndex
  else ix := -1;
  if ix >= 0 then Result := ix + 1;
end;

procedure IndexSet(AId: Int64; AClass: TClass; N1: Integer);   // 1-based, 0 = none
var c: TComponent;
begin
  if not GuiResolve(AId, AClass, c) then Exit;
  if c is TComboBox then TComboBox(c).ItemIndex := N1 - 1
  else if c is TListBox then TListBox(c).ItemIndex := N1 - 1;
end;

// --- checkbox ---------------------------------------------------------------
function f_checkbox(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TCheckBox, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_cb_caption_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCheckBox, c) then TCheckBox(c).Caption := A[1].Str; Result := A[0]; end;
function f_cb_caption_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCheckBox, c) then Result := ValStr(TCheckBox(c).Caption) else Result := ValStr(''); end;
function f_cb_checked_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCheckBox, c) then TCheckBox(c).Checked := ArgOn(A[1]); Result := A[0]; end;
function f_cb_checked_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCheckBox, c) then Result := ValInt(Ord(TCheckBox(c).Checked)) else Result := ValInt(0); end;
function f_cb_onchange(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0]; if GuiResolve(A[0].Hnd, TCheckBox, c) then TCheckBox(c).OnChange := GuiNotifyHandler(AVM, c, 'onchange', A[1].Str, A[0].Hnd); end;

// --- radio button -----------------------------------------------------------
function f_radio(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TRadioButton, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_rb_caption_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TRadioButton, c) then TRadioButton(c).Caption := A[1].Str; Result := A[0]; end;
function f_rb_caption_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TRadioButton, c) then Result := ValStr(TRadioButton(c).Caption) else Result := ValStr(''); end;
function f_rb_checked_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TRadioButton, c) then TRadioButton(c).Checked := ArgOn(A[1]); Result := A[0]; end;
function f_rb_checked_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TRadioButton, c) then Result := ValInt(Ord(TRadioButton(c).Checked)) else Result := ValInt(0); end;
function f_rb_onchange(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0]; if GuiResolve(A[0].Hnd, TRadioButton, c) then TRadioButton(c).OnChange := GuiNotifyHandler(AVM, c, 'onchange', A[1].Str, A[0].Hnd); end;

// --- combo box --------------------------------------------------------------
function f_combo(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TComboBox, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_combo_add(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TComboBox); if s <> nil then s.Add(A[1].Str); Result := A[0]; end;
function f_combo_count(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TComboBox); if s <> nil then Result := ValInt(s.Count) else Result := ValInt(0); end;
function f_combo_item(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; n: Integer; begin E := NoError; Result := ValStr(''); s := ItemsOf(A[0].Hnd, TComboBox); if s <> nil then begin n := Round(AsDouble(A[1])); if (n >= 1) and (n <= s.Count) then Result := ValStr(s[n-1]); end; end;
function f_combo_clear(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TComboBox); if s <> nil then s.Clear; Result := A[0]; end;
function f_combo_index_set(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; IndexSet(A[0].Hnd, TComboBox, Round(AsDouble(A[1]))); Result := A[0]; end;
function f_combo_index_get(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(IndexGet(A[0].Hnd, TComboBox)); end;
function f_combo_text(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TComboBox, c) then Result := ValStr(TComboBox(c).Text) else Result := ValStr(''); end;
function f_combo_onchange(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0]; if GuiResolve(A[0].Hnd, TComboBox, c) then TComboBox(c).OnChange := GuiNotifyHandler(AVM, c, 'onchange', A[1].Str, A[0].Hnd); end;

// --- list box ---------------------------------------------------------------
function f_list(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TListBox, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_list_add(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TListBox); if s <> nil then s.Add(A[1].Str); Result := A[0]; end;
function f_list_count(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TListBox); if s <> nil then Result := ValInt(s.Count) else Result := ValInt(0); end;
function f_list_item(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; n: Integer; begin E := NoError; Result := ValStr(''); s := ItemsOf(A[0].Hnd, TListBox); if s <> nil then begin n := Round(AsDouble(A[1])); if (n >= 1) and (n <= s.Count) then Result := ValStr(s[n-1]); end; end;
function f_list_clear(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TListBox); if s <> nil then s.Clear; Result := A[0]; end;
function f_list_index_set(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; IndexSet(A[0].Hnd, TListBox, Round(AsDouble(A[1]))); Result := A[0]; end;
function f_list_index_get(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(IndexGet(A[0].Hnd, TListBox)); end;
function f_list_selected(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; ix: Integer; begin
  E := NoError; Result := ValStr('');
  if GuiResolve(A[0].Hnd, TListBox, c) then
  begin ix := TListBox(c).ItemIndex; if ix >= 0 then Result := ValStr(TListBox(c).Items[ix]); end;
end;
function f_list_onclick(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0]; if GuiResolve(A[0].Hnd, TListBox, c) then TListBox(c).OnClick := GuiNotifyHandler(AVM, c, 'onclick', A[1].Str, A[0].Hnd); end;

procedure RegisterChoiceFuncs(Reg: TPhosphorRegistry);
begin
  // checkbox
  Reg.Add('checkbox@:@', @f_checkbox);
  Reg.Add('checkbox_caption@:@$', @f_cb_caption_set); Reg.Add('checkbox_caption$:@', @f_cb_caption_get);
  Reg.Add('checkbox_checked@:@n', @f_cb_checked_set);  Reg.Add('checkbox_checked:@', @f_cb_checked_get);
  Reg.AddHost('checkbox_onchange@:@$', @f_cb_onchange);
  // radio button
  Reg.Add('radiobutton@:@', @f_radio);
  Reg.Add('radio_caption@:@$', @f_rb_caption_set); Reg.Add('radio_caption$:@', @f_rb_caption_get);
  Reg.Add('radio_checked@:@n', @f_rb_checked_set);  Reg.Add('radio_checked:@', @f_rb_checked_get);
  Reg.AddHost('radio_onchange@:@$', @f_rb_onchange);
  // combo box
  Reg.Add('combobox@:@', @f_combo);
  Reg.Add('combo_add@:@$', @f_combo_add);   Reg.Add('combo_count:@', @f_combo_count);
  Reg.Add('combo_item$:@n', @f_combo_item); Reg.Add('combo_clear@:@', @f_combo_clear);
  Reg.Add('combo_itemindex@:@n', @f_combo_index_set); Reg.Add('combo_itemindex:@', @f_combo_index_get);
  Reg.Add('combo_text$:@', @f_combo_text);
  Reg.AddHost('combo_onchange@:@$', @f_combo_onchange);
  // list box
  Reg.Add('listbox@:@', @f_list);
  Reg.Add('list_add@:@$', @f_list_add);   Reg.Add('list_count:@', @f_list_count);
  Reg.Add('list_item$:@n', @f_list_item); Reg.Add('list_clear@:@', @f_list_clear);
  Reg.Add('list_itemindex@:@n', @f_list_index_set); Reg.Add('list_itemindex:@', @f_list_index_get);
  Reg.Add('list_selected$:@', @f_list_selected);
  Reg.AddHost('list_onclick@:@$', @f_list_onclick);
end;

end.
