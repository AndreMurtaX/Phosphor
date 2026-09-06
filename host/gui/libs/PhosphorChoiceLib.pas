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
  SysUtils, Classes, Controls, StdCtrls, CheckLst, ExtCtrls,
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
  else if c is TListBox then Result := TListBox(c).Items
  else if c is TRadioGroup then Result := TRadioGroup(c).Items
  else if c is TCheckGroup then Result := TCheckGroup(c).Items;
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

{ A SELECTION IS AN INDEX, SO IT IS BOUND-CHECKED BEFORE IT IS WRITTEN.

  TListBox.SetItemIndex asks the widgetset, which raises -- 'TListBox Index 3 out of
  bounds 0 .. 0' -- and that killed the program. It is the ordinary case that finds
  it, not a hostile one: restoring a saved selection against a list that has since
  got shorter is the shape a program actually has. So the range is checked here, the
  way stringgrid_cell@ and checkgroup_checked@ already check theirs, and an index the
  control has no item for answers gui_error 1 and leaves the selection alone.

  0 is not out of range: it is Phosphor's spelling of "nothing selected" (ItemIndex
  -1), which is why the accepted band is 0..Count and not 1..Count. }
procedure IndexSet(AId: Int64; AClass: TClass; N1: Integer);   // 1-based, 0 = none
var c: TComponent; items: TStrings;
begin
  if not GuiResolve(AId, AClass, c) then Exit;
  if c is TComboBox then items := TComboBox(c).Items
  else if c is TListBox then items := TListBox(c).Items
  else Exit;
  if (N1 < 0) or (N1 > items.Count) then begin GGuiError := 1; Exit; end;
  if c is TComboBox then TComboBox(c).ItemIndex := N1 - 1
  else TListBox(c).ItemIndex := N1 - 1;
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
var s: TStrings; n: Integer; begin E := NoError; Result := ValStr(''); s := ItemsOf(A[0].Hnd, TComboBox); if s <> nil then begin n := ArgI32(A[1]); if (n >= 1) and (n <= s.Count) then Result := ValStr(s[n-1]); end; end;
function f_combo_clear(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TComboBox); if s <> nil then s.Clear; Result := A[0]; end;
function f_combo_index_set(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; IndexSet(A[0].Hnd, TComboBox, ArgI32(A[1])); Result := A[0]; end;
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
var s: TStrings; n: Integer; begin E := NoError; Result := ValStr(''); s := ItemsOf(A[0].Hnd, TListBox); if s <> nil then begin n := ArgI32(A[1]); if (n >= 1) and (n <= s.Count) then Result := ValStr(s[n-1]); end; end;
function f_list_clear(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TListBox); if s <> nil then s.Clear; Result := A[0]; end;
function f_list_index_set(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; IndexSet(A[0].Hnd, TListBox, ArgI32(A[1])); Result := A[0]; end;
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

// --- toggle box (a button that stays in/out) --------------------------------
function f_togglebox(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TToggleBox, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_tg_caption_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TToggleBox, c) then TToggleBox(c).Caption := A[1].Str; Result := A[0]; end;
function f_tg_caption_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TToggleBox, c) then Result := ValStr(TToggleBox(c).Caption) else Result := ValStr(''); end;
function f_tg_checked_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TToggleBox, c) then TToggleBox(c).Checked := ArgOn(A[1]); Result := A[0]; end;
function f_tg_checked_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TToggleBox, c) then Result := ValInt(Ord(TToggleBox(c).Checked)) else Result := ValInt(0); end;
function f_tg_onchange(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0]; if GuiResolve(A[0].Hnd, TToggleBox, c) then TToggleBox(c).OnChange := GuiNotifyHandler(AVM, c, 'onchange', A[1].Str, A[0].Hnd); end;

// --- check list box (a list whose items each carry a check) -----------------
function f_checklist(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TControl; begin E := NoError; if MakeChild(A[0].Hnd, TCheckListBox, c) then Result := ValHandle(GuiRegister(c, False)) else Result := ValHandle(0); end;
function f_clb_add(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCheckListBox, c) then TCheckListBox(c).Items.Add(A[1].Str); Result := A[0]; end;
function f_clb_count(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCheckListBox, c) then Result := ValInt(TCheckListBox(c).Items.Count) else Result := ValInt(0); end;
function f_clb_item(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; n: Integer;
begin
  E := NoError; Result := ValStr('');
  if GuiResolve(A[0].Hnd, TCheckListBox, c) then begin n := ArgI32(A[1]); if (n >= 1) and (n <= TCheckListBox(c).Items.Count) then Result := ValStr(TCheckListBox(c).Items[n-1]); end;
end;
function f_clb_checked_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; n: Integer;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TCheckListBox, c) then begin n := ArgI32(A[1]); if (n >= 1) and (n <= TCheckListBox(c).Items.Count) then TCheckListBox(c).Checked[n-1] := ArgOn(A[2]) else GGuiError := 1; end;
end;
function f_clb_checked_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; n: Integer;
begin
  E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TCheckListBox, c) then begin n := ArgI32(A[1]); if (n >= 1) and (n <= TCheckListBox(c).Items.Count) then Result := ValInt(Ord(TCheckListBox(c).Checked[n-1])); end;
end;

// --- the two grouped-choice controls ---------------------------------------
// A bordered, captioned box that owns its buttons: the radio group gives ONE answer
// (ItemIndex), the check group gives one per item (Checked[i]). Both are what a
// groupbox@ full of radiobutton@ children only approximates -- the group manages
// the mutual exclusion and the layout itself.
function f_radiogroup(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; g: TRadioGroup;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  g := TRadioGroup.Create(pc); g.Parent := TWinControl(pc);
  if Length(A) >= 2 then g.Caption := A[1].Str;
  Result := ValHandle(GuiRegister(g, False));
end;
function f_checkgroup(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; g: TCheckGroup;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  g := TCheckGroup.Create(pc); g.Parent := TWinControl(pc);
  if Length(A) >= 2 then g.Caption := A[1].Str;
  Result := ValHandle(GuiRegister(g, False));
end;

function f_rg_add(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TRadioGroup); if s <> nil then s.Add(A[1].Str); Result := A[0]; end;
function f_rg_count(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TRadioGroup); if s <> nil then Result := ValInt(s.Count) else Result := ValInt(0); end;
function f_rg_item(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; n: Integer;
begin E := NoError; Result := ValStr(''); s := ItemsOf(A[0].Hnd, TRadioGroup);
  if s <> nil then begin n := ArgI32(A[1]); if (n >= 1) and (n <= s.Count) then Result := ValStr(s[n-1]); end; end;
function f_rg_clear(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TRadioGroup); if s <> nil then s.Clear; Result := A[0]; end;
// base-1 out, base-1 in; 0 means nothing is chosen, matching ItemIndex's own -1
function f_rg_index_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TRadioGroup, c) then Result := ValInt(TRadioGroup(c).ItemIndex + 1); end;
function f_rg_index_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; n: Integer;
begin E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TRadioGroup, c) then Exit;
  // Same rule and same reason as IndexSet above -- TRadioGroup raises too
  // ('TRadioGroup Index 499 out of bounds -1 .. 0'), and here even a NEGATIVE index
  // raised, which IndexSet's controls happened to tolerate. 0 selects nothing.
  n := ArgI32(A[1]);
  if (n < 0) or (n > TRadioGroup(c).Items.Count) then begin GGuiError := 1; Exit; end;
  TRadioGroup(c).ItemIndex := n - 1; end;
function f_rg_caption_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValStr('');
  if GuiResolve(A[0].Hnd, TRadioGroup, c) then Result := ValStr(TRadioGroup(c).Caption); end;
function f_rg_caption_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TRadioGroup, c) then TRadioGroup(c).Caption := A[1].Str; end;
function f_rg_onchange(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TRadioGroup, c) then
    TRadioGroup(c).OnClick := GuiNotifyHandler(AVM, c, 'onchange', A[1].Str, A[0].Hnd); end;

function f_cg_add(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TCheckGroup); if s <> nil then s.Add(A[1].Str); Result := A[0]; end;
function f_cg_count(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TCheckGroup); if s <> nil then Result := ValInt(s.Count) else Result := ValInt(0); end;
function f_cg_item(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; n: Integer;
begin E := NoError; Result := ValStr(''); s := ItemsOf(A[0].Hnd, TCheckGroup);
  if s <> nil then begin n := ArgI32(A[1]); if (n >= 1) and (n <= s.Count) then Result := ValStr(s[n-1]); end; end;
function f_cg_clear(const A: array of TValue; out E: TPhosphorError): TValue;
var s: TStrings; begin E := NoError; s := ItemsOf(A[0].Hnd, TCheckGroup); if s <> nil then s.Clear; Result := A[0]; end;
function f_cg_checked_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; n: Integer;
begin E := NoError; Result := ValInt(0);
  if not GuiResolve(A[0].Hnd, TCheckGroup, c) then Exit;
  n := ArgI32(A[1]);
  if (n >= 1) and (n <= TCheckGroup(c).Items.Count) then
    Result := ValInt(Ord(TCheckGroup(c).Checked[n-1]))
  else GGuiError := 1; end;
function f_cg_checked_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; n: Integer;
begin E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TCheckGroup, c) then Exit;
  n := ArgI32(A[1]);
  if (n >= 1) and (n <= TCheckGroup(c).Items.Count) then
    TCheckGroup(c).Checked[n-1] := ArgI32(A[2]) <> 0
  else GGuiError := 1; end;
function f_cg_caption_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValStr('');
  if GuiResolve(A[0].Hnd, TCheckGroup, c) then Result := ValStr(TCheckGroup(c).Caption); end;
function f_cg_caption_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TCheckGroup, c) then TCheckGroup(c).Caption := A[1].Str; end;

procedure RegisterChoiceFuncs(Reg: TPhosphorRegistry);
begin
  // togglebox
  Reg.Add('togglebox@:@', @f_togglebox);
  Reg.Add('togglebox_caption@:@$', @f_tg_caption_set); Reg.Add('togglebox_caption$:@', @f_tg_caption_get);
  Reg.Add('togglebox_checked@:@n', @f_tg_checked_set); Reg.Add('togglebox_checked:@', @f_tg_checked_get);
  Reg.AddHost('togglebox_onchange@:@$', @f_tg_onchange);
  // check list box
  Reg.Add('radiogroup@:@',  @f_radiogroup);  Reg.Add('radiogroup@:@$', @f_radiogroup);
  Reg.Add('radiogroup_add@:@$',      @f_rg_add);
  Reg.Add('radiogroup_count:@',      @f_rg_count);
  Reg.Add('radiogroup_item$:@n',     @f_rg_item);
  Reg.Add('radiogroup_clear@:@',     @f_rg_clear);
  Reg.Add('radiogroup_itemindex:@',  @f_rg_index_get);   Reg.Add('radiogroup_itemindex@:@n', @f_rg_index_set);
  Reg.Add('radiogroup_caption$:@',   @f_rg_caption_get); Reg.Add('radiogroup_caption@:@$',   @f_rg_caption_set);
  Reg.AddHost('radiogroup_onchange@:@$', @f_rg_onchange);
  Reg.Add('checkgroup@:@',  @f_checkgroup);  Reg.Add('checkgroup@:@$', @f_checkgroup);
  Reg.Add('checkgroup_add@:@$',      @f_cg_add);
  Reg.Add('checkgroup_count:@',      @f_cg_count);
  Reg.Add('checkgroup_item$:@n',     @f_cg_item);
  Reg.Add('checkgroup_clear@:@',     @f_cg_clear);
  Reg.Add('checkgroup_checked:@n',   @f_cg_checked_get); Reg.Add('checkgroup_checked@:@nn', @f_cg_checked_set);
  Reg.Add('checkgroup_caption$:@',   @f_cg_caption_get); Reg.Add('checkgroup_caption@:@$',  @f_cg_caption_set);
  Reg.Add('checklistbox@:@', @f_checklist);
  Reg.Add('checklist_add@:@$', @f_clb_add);   Reg.Add('checklist_count:@', @f_clb_count);
  Reg.Add('checklist_item$:@n', @f_clb_item);
  Reg.Add('checklist_checked@:@nn', @f_clb_checked_set); Reg.Add('checklist_checked:@n', @f_clb_checked_get);
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
