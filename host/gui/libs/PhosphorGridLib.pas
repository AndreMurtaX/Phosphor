{******************************************************************************
  Phosphor BASIC -- grid library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

    stringgrid@(parent@)
    stringgrid_colcount@/()   stringgrid_rowcount@/()   stringgrid_fixedrows@/()
    stringgrid_cell@(g@, col, row, s$)   stringgrid_cell$(g@, col, row)
    stringgrid_clear@(g@)

  Columns and rows are 1-BASED (Phosphor's convention): cell (g, 1, 1) is the
  top-left, i.e. TStringGrid.Cells[0, 0]. Geometry comes from PhosphorControlLib.
******************************************************************************}
unit PhosphorGridLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Types, Controls, Grids,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorVM, PhosphorGuiCore;

procedure RegisterGridFuncs(Reg: TPhosphorRegistry);

implementation

type
  { OnDrawCell's signature lives in Grids, so its bridge lives here rather than in
    GuiCore -- the same reason PhosphorFormLib owns its own closer. Owned by the
    grid it serves, so it dies with it. }
  TDrawCellBridge = class(TComponent)
  public
    VM: TPhosphorVM;
    Handler: String;
    SenderId: Int64;
    procedure Fire(Sender: TObject; aCol, aRow: Integer; aRect: TRect;
                   aState: TGridDrawState);
  end;

{ The cell's state as the short string the mouse and key events already use, so a
  program tests it the same way: instr(state$, "S") > 0. }
function StateStr(AState: TGridDrawState): String;
const
  NAMES: array[0..2] of String = ('S', 'F', 'X');
var
  i: Integer;
  present: array[0..2] of Boolean;
begin
  present[0] := gdSelected in AState;
  present[1] := gdFocused in AState;
  present[2] := gdFixed in AState;
  Result := '';
  for i := 0 to 2 do
    if present[i] then
    begin
      if Result <> '' then Result := Result + ' ';
      Result := Result + NAMES[i];
    end;
end;

procedure TDrawCellBridge.Fire(Sender: TObject; aCol, aRow: Integer;
  aRect: TRect; aState: TGridDrawState);
begin
  // Base-1 cells, as stringgrid@ already had them. The rectangle arrives as
  // x, y, w, h because a program has no rect type to receive.
  GuiCallBack(VM, Handler,
    [ValHandle(SenderId), ValInt(aCol + 1), ValInt(aRow + 1),
     ValInt(aRect.Left), ValInt(aRect.Top),
     ValInt(aRect.Right - aRect.Left), ValInt(aRect.Bottom - aRect.Top),
     ValStr(StateStr(aState))]);
end;

{ The bridge serving AGrid, created on demand -- one per grid. }
function DrawBridgeOf(AGrid: TComponent): TDrawCellBridge;
var i: Integer;
begin
  for i := 0 to AGrid.ComponentCount - 1 do
    if AGrid.Components[i] is TDrawCellBridge then
      Exit(TDrawCellBridge(AGrid.Components[i]));
  Result := TDrawCellBridge.Create(AGrid);
end;

function f_drawgrid(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; g: TDrawGrid;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  g := TDrawGrid.Create(pc);
  g.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(g, False));
end;

function f_dg_ondrawcell(AVM: TObject; const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; b: TDrawCellBridge;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TDrawGrid, c) then Exit;
  if A[1].Str = '' then
  begin
    TDrawGrid(c).OnDrawCell := nil;      // an empty name unwires, as everywhere else
    Exit;
  end;
  b := DrawBridgeOf(c);
  b.VM := TPhosphorVM(AVM);
  b.Handler := A[1].Str;
  b.SenderId := A[0].Hnd;
  TDrawGrid(c).OnDrawCell := @b.Fire;
end;

{ Draw one cell now, the way control_keydown@ presses one key now. A headless suite
  never paints, so without this the whole protocol would be unreachable by a test --
  and a program that wants to refresh a single cell needs it anyway. }
function f_dg_drawcell(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; col, row: Integer; st: TGridDrawState;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TDrawGrid, c) then Exit;
  col := ArgI32(A[1]) - 1;
  row := ArgI32(A[2]) - 1;
  if (col < 0) or (col >= TDrawGrid(c).ColCount) or
     (row < 0) or (row >= TDrawGrid(c).RowCount) then
  begin
    GGuiError := 1;   // out of range, the same answer stringgrid_cell@ gives
    Exit;
  end;
  // Go through the grid's OWN event, not the bridge behind it. control_keydown@
  // calls KeyDown for the same reason: a synthesiser that reaches past the event
  // property tests a path a real paint never takes -- and it showed, since
  // unwiring OnDrawCell left this still firing.
  if not Assigned(TDrawGrid(c).OnDrawCell) then Exit;
  st := [];
  if row < TDrawGrid(c).FixedRows then Include(st, gdFixed);
  if col < TDrawGrid(c).FixedCols then Include(st, gdFixed);
  if (col = TDrawGrid(c).Col) and (row = TDrawGrid(c).Row) then
  begin
    Include(st, gdSelected);
    Include(st, gdFocused);
  end;
  TDrawGrid(c).OnDrawCell(c, col, row, TDrawGrid(c).CellRect(col, row), st);
end;

function f_dg_colcount_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then TDrawGrid(c).ColCount := ArgI32(A[1]); end;
function f_dg_colcount_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then Result := ValInt(TDrawGrid(c).ColCount); end;
function f_dg_rowcount_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then TDrawGrid(c).RowCount := ArgI32(A[1]); end;
function f_dg_rowcount_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then Result := ValInt(TDrawGrid(c).RowCount); end;
function f_dg_fixedrows_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then TDrawGrid(c).FixedRows := ArgI32(A[1]); end;
function f_dg_fixedrows_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then Result := ValInt(TDrawGrid(c).FixedRows); end;
function f_dg_fixedcols_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then TDrawGrid(c).FixedCols := ArgI32(A[1]); end;
function f_dg_fixedcols_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then Result := ValInt(TDrawGrid(c).FixedCols); end;
{ Which cell has the cursor, base-1, so a handler can tell what it is drawing. }
function f_dg_col_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then Result := ValInt(TDrawGrid(c).Col + 1); end;
function f_dg_row_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then Result := ValInt(TDrawGrid(c).Row + 1); end;
function f_dg_setcursor(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then
  begin
    TDrawGrid(c).Col := ArgI32(A[1]) - 1;
    TDrawGrid(c).Row := ArgI32(A[2]) - 1;
  end; end;

function f_grid(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; g: TStringGrid;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  g := TStringGrid.Create(pc);
  g.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(g, False));
end;

function f_colcount_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStringGrid, c) then TStringGrid(c).ColCount := ArgI32(A[1]); Result := A[0]; end;
function f_colcount_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStringGrid, c) then Result := ValInt(TStringGrid(c).ColCount) else Result := ValInt(0); end;
function f_rowcount_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStringGrid, c) then TStringGrid(c).RowCount := ArgI32(A[1]); Result := A[0]; end;
function f_rowcount_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStringGrid, c) then Result := ValInt(TStringGrid(c).RowCount) else Result := ValInt(0); end;
function f_fixedrows_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStringGrid, c) then TStringGrid(c).FixedRows := ArgI32(A[1]); Result := A[0]; end;
function f_fixedrows_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStringGrid, c) then Result := ValInt(TStringGrid(c).FixedRows) else Result := ValInt(0); end;

function f_cell_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; col, row: Integer;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TStringGrid, c) then Exit;
  col := ArgI32(A[1]) - 1;   // 1-based -> 0-based
  row := ArgI32(A[2]) - 1;
  if (col >= 0) and (col < TStringGrid(c).ColCount) and (row >= 0) and (row < TStringGrid(c).RowCount) then
    TStringGrid(c).Cells[col, row] := A[3].Str
  else
    GGuiError := 1;   // out of range
end;
function f_cell_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; col, row: Integer;
begin
  E := NoError; Result := ValStr('');
  if not GuiResolve(A[0].Hnd, TStringGrid, c) then Exit;
  col := ArgI32(A[1]) - 1;
  row := ArgI32(A[2]) - 1;
  if (col >= 0) and (col < TStringGrid(c).ColCount) and (row >= 0) and (row < TStringGrid(c).RowCount) then
    Result := ValStr(TStringGrid(c).Cells[col, row])
  else
    GGuiError := 1;
end;
function f_clear(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStringGrid, c) then TStringGrid(c).Clean; Result := A[0]; end;

procedure RegisterGridFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('drawgrid@:@',            @f_drawgrid);
  Reg.Add('drawgrid_colcount@:@n',  @f_dg_colcount_set);  Reg.Add('drawgrid_colcount:@',  @f_dg_colcount_get);
  Reg.Add('drawgrid_rowcount@:@n',  @f_dg_rowcount_set);  Reg.Add('drawgrid_rowcount:@',  @f_dg_rowcount_get);
  Reg.Add('drawgrid_fixedrows@:@n', @f_dg_fixedrows_set); Reg.Add('drawgrid_fixedrows:@', @f_dg_fixedrows_get);
  Reg.Add('drawgrid_fixedcols@:@n', @f_dg_fixedcols_set); Reg.Add('drawgrid_fixedcols:@', @f_dg_fixedcols_get);
  Reg.Add('drawgrid_col:@',         @f_dg_col_get);
  Reg.Add('drawgrid_row:@',         @f_dg_row_get);
  Reg.Add('drawgrid_cursor@:@nn',   @f_dg_setcursor);
  Reg.Add('drawgrid_drawcell@:@nn', @f_dg_drawcell);
  Reg.AddHost('drawgrid_ondrawcell@:@$', @f_dg_ondrawcell);
  Reg.Add('stringgrid@:@', @f_grid);
  Reg.Add('stringgrid_colcount@:@n', @f_colcount_set); Reg.Add('stringgrid_colcount:@', @f_colcount_get);
  Reg.Add('stringgrid_rowcount@:@n', @f_rowcount_set); Reg.Add('stringgrid_rowcount:@', @f_rowcount_get);
  Reg.Add('stringgrid_fixedrows@:@n', @f_fixedrows_set); Reg.Add('stringgrid_fixedrows:@', @f_fixedrows_get);
  Reg.Add('stringgrid_cell@:@nn$', @f_cell_set);
  Reg.Add('stringgrid_cell$:@nn', @f_cell_get);
  Reg.Add('stringgrid_clear@:@', @f_clear);
end;

end.
