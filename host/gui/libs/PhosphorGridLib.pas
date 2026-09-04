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
  SysUtils, Classes, Controls, Grids,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterGridFuncs(Reg: TPhosphorRegistry);

implementation

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
  Reg.Add('stringgrid@:@', @f_grid);
  Reg.Add('stringgrid_colcount@:@n', @f_colcount_set); Reg.Add('stringgrid_colcount:@', @f_colcount_get);
  Reg.Add('stringgrid_rowcount@:@n', @f_rowcount_set); Reg.Add('stringgrid_rowcount:@', @f_rowcount_get);
  Reg.Add('stringgrid_fixedrows@:@n', @f_fixedrows_set); Reg.Add('stringgrid_fixedrows:@', @f_fixedrows_get);
  Reg.Add('stringgrid_cell@:@nn$', @f_cell_set);
  Reg.Add('stringgrid_cell$:@nn', @f_cell_get);
  Reg.Add('stringgrid_clear@:@', @f_clear);
end;

end.
