{******************************************************************************
  Phosphor BASIC -- menu library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

    mainmenu@(form@)                    the form's menu bar
    menuitem@(parent@[, caption$])      an item; parent is a main menu (a top-
                                        level item) or a menu item (a submenu)
    menuitem_caption@/$
    menuitem_onclick@(mi@, "func")      run a BASIC routine when it is chosen
    menuitem_click@(mi@)                choose it programmatically (headless: fires
                                        OnClick synchronously, no window needed)

  A menu item is a TComponent, not a TControl, so the control_* helpers do not
  apply; its own caption/onclick are here.
******************************************************************************}
unit PhosphorMenuLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, Forms, Menus, ComCtrls,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterMenuFuncs(Reg: TPhosphorRegistry);

implementation

function f_mainmenu(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; mm: TMainMenu;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TForm, c) then begin Result := ValHandle(0); Exit; end;
  mm := TMainMenu.Create(c);
  TForm(c).Menu := mm;
  Result := ValHandle(GuiRegister(mm, False));
end;

function f_menuitem(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; item: TMenuItem;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TComponent, c) then begin Result := ValHandle(0); Exit; end;
  if c is TMainMenu then
    item := TMenuItem.Create(TMainMenu(c))
  else if c is TPopupMenu then
    item := TMenuItem.Create(TPopupMenu(c))
  else if c is TMenuItem then
    item := TMenuItem.Create(TMenuItem(c).Owner)
  else
  begin
    GGuiError := 1;   // parent is neither a main menu nor a menu item
    Result := ValHandle(0);
    Exit;
  end;
  if Length(A) >= 2 then item.Caption := A[1].Str;
  if c is TPopupMenu then TPopupMenu(c).Items.Add(item)
  else if c is TMainMenu then TMainMenu(c).Items.Add(item)
  else TMenuItem(c).Add(item);
  Result := ValHandle(GuiRegister(item, False));
end;

function f_mi_caption_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TMenuItem, c) then TMenuItem(c).Caption := A[1].Str; Result := A[0]; end;
function f_mi_caption_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TMenuItem, c) then Result := ValStr(TMenuItem(c).Caption) else Result := ValStr(''); end;
function f_mi_click(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TMenuItem, c) then TMenuItem(c).Click; Result := A[0]; end;
function f_mi_onclick(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0]; if GuiResolve(A[0].Hnd, TMenuItem, c) then TMenuItem(c).OnClick := GuiNotifyHandler(AVM, c, 'onclick', A[1].Str, A[0].Hnd); end;

// --- tool bar (a container for tool buttons, top-aligned) -------------------
function f_toolbar(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; tb: TToolBar;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  tb := TToolBar.Create(pc); tb.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(tb, False));
end;

// --- status bar (a simple text strip at the bottom) -------------------------
function f_statusbar(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; sb: TStatusBar;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  sb := TStatusBar.Create(pc); sb.Parent := TWinControl(pc);
  sb.SimplePanel := True;   // use the single SimpleText, not multiple panels
  Result := ValHandle(GuiRegister(sb, False));
end;
function f_statusbar_text_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStatusBar, c) then TStatusBar(c).SimpleText := A[1].Str; Result := A[0]; end;
function f_statusbar_text_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStatusBar, c) then Result := ValStr(TStatusBar(c).SimpleText) else Result := ValStr(''); end;

{ A context menu, created on and attached to the control it belongs to. Attaching
  is the half a property bridge cannot do: PopupMenu is object-typed, so no
  set-by-name reaches it, which is why the constructor takes the control. }
function f_popupmenu(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; pm: TPopupMenu;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TControl, c) then begin Result := ValHandle(0); Exit; end;
  pm := TPopupMenu.Create(c);
  TControl(c).PopupMenu := pm;
  Result := ValHandle(GuiRegister(pm, False));   // owned by the control
end;

{ Attach an existing popup to another control, so one menu can serve several. }
function f_popup_attach(const A: array of TValue; out E: TPhosphorError): TValue;
var pmc, c: TComponent;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TPopupMenu, pmc) then Exit;
  if not GuiResolve(A[1].Hnd, TControl, c) then Exit;
  TControl(c).PopupMenu := TPopupMenu(pmc);
end;

procedure RegisterMenuFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('toolbar@:@', @f_toolbar);
  Reg.Add('statusbar@:@', @f_statusbar);
  Reg.Add('statusbar_text@:@$', @f_statusbar_text_set); Reg.Add('statusbar_text$:@', @f_statusbar_text_get);
  Reg.Add('mainmenu@:@', @f_mainmenu);
  Reg.Add('popupmenu@:@', @f_popupmenu);
  Reg.Add('popupmenu_attach@:@@', @f_popup_attach);
  Reg.Add('menuitem@:@',  @f_menuitem);
  Reg.Add('menuitem@:@$', @f_menuitem);
  Reg.Add('menuitem_caption@:@$', @f_mi_caption_set);
  Reg.Add('menuitem_caption$:@',  @f_mi_caption_get);
  Reg.Add('menuitem_click@:@',    @f_mi_click);
  Reg.AddHost('menuitem_onclick@:@$', @f_mi_onclick);
end;

end.
