{******************************************************************************
  Phosphor BASIC -- tree and list-view library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  A tree view of nodes and a report-style list view of items. Nodes (TTreeNode)
  and items (TListItem) are not TComponents, so they ride on the handle registry
  through the generalized GuiResolveObj; their container owns them, so their
  wrappers are non-owning.

    treeview@(parent@)     treeview_nodecount(tv@)
    treenode@(parent@, caption$)   parent = a tree view (a root) or a node (a child)
    treenode_caption@/$    treenode_childcount(n@)

    listview@(parent@)     listview_addcolumn@(lv@, caption$)   listview_itemcount(lv@)
    listitem@(lv@, caption$)   listitem_caption@/$
    listitem_subitem@(it@, s$)   listitem_subitem$(it@, n)     (n is 1-based)
******************************************************************************}
unit PhosphorTreeListLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, ComCtrls,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterTreeListFuncs(Reg: TPhosphorRegistry);

implementation

// --- tree view --------------------------------------------------------------
function f_treeview(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; tv: TTreeView;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  tv := TTreeView.Create(pc);
  tv.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(tv, False));
end;

function f_treenode(const A: array of TValue; out E: TPhosphorError): TValue;
var o: TObject; node: TTreeNode;
begin
  E := NoError;
  if not GuiResolveObj(A[0].Hnd, TPersistent, o) then begin Result := ValHandle(0); Exit; end;
  if o is TTreeView then
    node := TTreeView(o).Items.Add(nil, A[1].Str)             // a root node
  else if o is TTreeNode then
    node := TTreeNode(o).Owner.AddChild(TTreeNode(o), A[1].Str) // a child node
  else
  begin
    GGuiError := 1;
    Result := ValHandle(0);
    Exit;
  end;
  Result := ValHandle(GuiRegister(node, False));
end;

function f_tv_nodecount(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TTreeView, c) then Result := ValInt(TTreeView(c).Items.Count) else Result := ValInt(0); end;
function f_node_caption_set(const A: array of TValue; out E: TPhosphorError): TValue;
var o: TObject; begin E := NoError; if GuiResolveObj(A[0].Hnd, TTreeNode, o) then TTreeNode(o).Text := A[1].Str; Result := A[0]; end;
function f_node_caption_get(const A: array of TValue; out E: TPhosphorError): TValue;
var o: TObject; begin E := NoError; if GuiResolveObj(A[0].Hnd, TTreeNode, o) then Result := ValStr(TTreeNode(o).Text) else Result := ValStr(''); end;
function f_node_childcount(const A: array of TValue; out E: TPhosphorError): TValue;
var o: TObject; begin E := NoError; if GuiResolveObj(A[0].Hnd, TTreeNode, o) then Result := ValInt(TTreeNode(o).Count) else Result := ValInt(0); end;

// --- list view --------------------------------------------------------------
function f_listview(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; lv: TListView;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  lv := TListView.Create(pc);
  lv.Parent := TWinControl(pc);
  lv.ViewStyle := vsReport;
  Result := ValHandle(GuiRegister(lv, False));
end;

function f_lv_addcolumn(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; col: TListColumn;
begin
  E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TListView, c) then begin col := TListView(c).Columns.Add; col.Caption := A[1].Str; end;
end;
function f_lv_itemcount(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TListView, c) then Result := ValInt(TListView(c).Items.Count) else Result := ValInt(0); end;

function f_listitem(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; item: TListItem;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TListView, c) then begin Result := ValHandle(0); Exit; end;
  item := TListView(c).Items.Add;
  item.Caption := A[1].Str;
  Result := ValHandle(GuiRegister(item, False));
end;
function f_item_caption_set(const A: array of TValue; out E: TPhosphorError): TValue;
var o: TObject; begin E := NoError; if GuiResolveObj(A[0].Hnd, TListItem, o) then TListItem(o).Caption := A[1].Str; Result := A[0]; end;
function f_item_caption_get(const A: array of TValue; out E: TPhosphorError): TValue;
var o: TObject; begin E := NoError; if GuiResolveObj(A[0].Hnd, TListItem, o) then Result := ValStr(TListItem(o).Caption) else Result := ValStr(''); end;
function f_item_subitem_add(const A: array of TValue; out E: TPhosphorError): TValue;
var o: TObject; begin E := NoError; if GuiResolveObj(A[0].Hnd, TListItem, o) then TListItem(o).SubItems.Add(A[1].Str); Result := A[0]; end;
function f_item_subitem_get(const A: array of TValue; out E: TPhosphorError): TValue;
var o: TObject; n: Integer;
begin
  E := NoError; Result := ValStr('');
  if GuiResolveObj(A[0].Hnd, TListItem, o) then
  begin
    n := Round(AsDouble(A[1]));   // 1-based
    if (n >= 1) and (n <= TListItem(o).SubItems.Count) then Result := ValStr(TListItem(o).SubItems[n-1]);
  end;
end;

procedure RegisterTreeListFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('treeview@:@', @f_treeview);
  Reg.Add('treeview_nodecount:@', @f_tv_nodecount);
  Reg.Add('treenode@:@$', @f_treenode);
  Reg.Add('treenode_caption@:@$', @f_node_caption_set); Reg.Add('treenode_caption$:@', @f_node_caption_get);
  Reg.Add('treenode_childcount:@', @f_node_childcount);
  Reg.Add('listview@:@', @f_listview);
  Reg.Add('listview_addcolumn@:@$', @f_lv_addcolumn);
  Reg.Add('listview_itemcount:@', @f_lv_itemcount);
  Reg.Add('listitem@:@$', @f_listitem);
  Reg.Add('listitem_caption@:@$', @f_item_caption_set); Reg.Add('listitem_caption$:@', @f_item_caption_get);
  Reg.Add('listitem_subitem@:@$', @f_item_subitem_add);
  Reg.Add('listitem_subitem$:@n', @f_item_subitem_get);
end;

end.
