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
  { RowCount/ColCount/FixedRows/FixedCols are declared PROTECTED on TCustomGrid and
    republished by TStringGrid and TDrawGrid, so this is how one guard can serve
    both without being written twice -- the same trick PhosphorControlLib's
    TControlAccess uses to reach a protected event. Never instantiated. }
  TGridAccess = class(TCustomGrid);

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

{ A GRID HAS AN INVARIANT AND THE LCL ENFORCES IT BY RAISING.

  TCustomGrid.CheckFixedCount refuses a header taller than the grid --
  EGridException 'FixedRows can't be > RowCount', 'FixedRows<0', and the two column
  spellings of the same -- and it runs from all four setters, so BOTH sides can trip
  it: raising the header above the row count, and dropping the row count below the
  header. That second one is the ordinary case, not an exotic one: a program that
  gives a grid a header row and then EMPTIES it (rowcount 0) killed the interpreter
  with a message naming neither the grid nor the line.

  So the quadruple is checked HERE, before the LCL is asked, exactly as
  stringgrid_cell@ below checks a cell before indexing it -- and a refused change
  answers gui_error 1 and leaves the grid alone. The rule is CheckFixedCount's,
  transcribed: a fixed count is never negative, and never exceeds its own count
  unless BOTH are zero (an all-fixed grid, which the LCL allows). Counts themselves
  are not checked: a negative RowCount or ColCount clears the grid, which the LCL
  does without complaint.

  Note the argument order matches CheckFixedCount's: cols, rows, fixed cols, fixed
  rows -- so a reader can hold this against Grids.pas line for line. }
function GridWouldRefuse(ACols, ARows, AFixedCols, AFixedRows: Integer): Boolean;
begin
  Result := True;
  if (AFixedRows < 0) or (AFixedCols < 0) then Exit;
  if not ((ACols = 0) and (AFixedCols = 0)) and (AFixedCols > ACols) then Exit;
  if not ((ARows = 0) and (AFixedRows = 0)) and (AFixedRows > ARows) then Exit;
  Result := False;
end;

{ The four setters, each proposing ONE new number and keeping the other three.

  THE TWO COUNTS ARE NOT SYMMETRICAL, and the difference is the LCL's, not a typo
  here. InternalSetColCount takes `if ACount<1 then Clear` BEFORE the check, so a
  column count of 0 empties the grid and never reaches CheckFixedCount; SetRowCount
  takes `if AValue>=0 then ... CheckFixedCount` and only its NEGATIVE branch clears.
  So rowcount 0 IS checked and colcount 0 is not -- which is exactly the case the
  report arrived with, "empty a grid that has a header row". Guessing symmetry here
  is what left that one still aborting after the first attempt at this guard. }
{ A COUNT IS ALSO AN ALLOCATION, and that is a different refusal from the header
  invariant above -- the LCL is perfectly willing to build the grid, which is the
  problem. Measured on this tree: stringgrid_rowcount@(g@, 20000000) committed
  2.5 GB in two seconds with nothing reported at all, and the drawgrid spelling did
  the same. So the size is gated FIRST, as a catchable error naming the cost, and
  only then does the header rule get its say as gui_error 1. The two are kept
  apart on purpose: a grid that refused to lose its header still has a grid, and a
  grid that was never built does not.

  IT IS PRICED BY ROWS, NOT BY CELLS, and getting that wrong the first time made
  this guard refuse ordinary grids while admitting the expensive one. Measured on
  this tree, one probe per process over an 11 MB floor:

      100 x  21,000   2.1 M cells    21 MB     <- a cell-product bound REFUSED this
       50 x  50,000   2.5 M cells    33 MB     <- and this
       20 x 150,000   3.0 M cells    52 MB     <- and this
        1 x 2,000,000 2.0 M cells   305 MB     <- and ALLOWED this, 14x dearer

  A row costs ~155 bytes and a cell ~10, so a row is fifteen cells and the cell
  product is simply the wrong shape. GuiGridBytes prices both terms; a 21,000-row
  hundred-column sheet is now 28 MB and passes, and the tall column is priced at
  what it actually costs.

  AND THE COUNT IS RE-CHARGED AFTER THE WRITE, not before it: only the write knows
  whether it happened (the header rule above may refuse it, and the LCL may raise),
  and a charge for a grid that was never resized is a false refusal waiting to
  happen. GridRecharge reads the grid back rather than trusting the value it gated.

  Both take E because a caller cannot report what it is not told. }
procedure GridRecharge(G: TCustomGrid);
var e2: TPhosphorError;
begin
  // Cannot refuse: this records what the grid already IS. Room was asked for
  // before the write, and nothing has grown since.
  GuiChargeSet(G, 'grid', GuiGridBytes(TGridAccess(G).ColCount,
                                       TGridAccess(G).RowCount), e2);
end;

procedure GridSetColCount(G: TCustomGrid; N: Integer; out E: TPhosphorError);
begin
  if not GuiChargeRoom(Format('grid %d columns x %d rows', [N, TGridAccess(G).RowCount]),
                       GuiGridBytes(N, TGridAccess(G).RowCount),
                       GuiObjectBytes(G), E) then Exit;
  if (N >= 1) and GridWouldRefuse(N, TGridAccess(G).RowCount,
                                  TGridAccess(G).FixedCols, TGridAccess(G).FixedRows) then
    GGuiError := 1
  else
    TGridAccess(G).ColCount := N;
  GridRecharge(G);
end;

procedure GridSetRowCount(G: TCustomGrid; N: Integer; out E: TPhosphorError);
begin
  if not GuiChargeRoom(Format('grid %d columns x %d rows', [TGridAccess(G).ColCount, N]),
                       GuiGridBytes(TGridAccess(G).ColCount, N),
                       GuiObjectBytes(G), E) then Exit;
  if (N >= 0) and GridWouldRefuse(TGridAccess(G).ColCount, N,
                                  TGridAccess(G).FixedCols, TGridAccess(G).FixedRows) then
    GGuiError := 1
  else
    TGridAccess(G).RowCount := N;
  GridRecharge(G);
end;

{ THE SAME BOUND, ON THE OTHER WAY IN. control_set@ writes any published property
  by name, and TStringGrid/TDrawGrid publish RowCount and ColCount -- so
  control_set@(g@, "RowCount", 20000000) reached the allocation above with the two
  functions above sitting unused beside it, and was killed at 2.5 GB like the
  named spelling. A guard with a second door is not a guard; this is that door.

  Installed from the unit's initialization, so LINKING this package is what arms
  it -- there is no registration call to forget and no order to get wrong. The name
  arrives canonical from the RTTI record (see PhosphorGuiCore.GuiAddPropGate), so
  SameText here is comparing against the one spelling the LCL published, not
  against whatever the program typed. FixedRows and FixedCols need no gate: they
  cannot exceed a count, and the LCL raises on the attempt, which the bridge
  already catches. }
function GridPropGate(AObject: TObject; const AProp: String; AValue: Int64;
                      out E: TPhosphorError): Boolean;
begin
  E := NoError;
  Result := True;
  if not (AObject is TCustomGrid) then Exit;
  if SameText(AProp, 'ColCount') then
    Result := GuiChargeRoom(Format('grid %d columns x %d rows',
                                   [AValue, TGridAccess(AObject).RowCount]),
                            GuiGridBytes(AValue, TGridAccess(AObject).RowCount),
                            GuiObjectBytes(AObject), E)
  else if SameText(AProp, 'RowCount') then
    Result := GuiChargeRoom(Format('grid %d columns x %d rows',
                                   [TGridAccess(AObject).ColCount, AValue]),
                            GuiGridBytes(TGridAccess(AObject).ColCount, AValue),
                            GuiObjectBytes(AObject), E);
end;

{ The gate's other half. The bridge calls this after SetOrdProp actually landed, so
  the ledger records the shape the grid REALLY has -- including the case where the
  header rule or the LCL refused the write and it still has the old one. Every
  ordinal write to a grid re-reads it; that is cheap and it cannot drift. }
procedure GridPropWritten(AObject: TObject; const AProp: String);
begin
  if AObject is TCustomGrid then
    if SameText(AProp, 'ColCount') or SameText(AProp, 'RowCount') then
      GridRecharge(TCustomGrid(AObject));
end;

procedure GridSetFixedCols(G: TCustomGrid; N: Integer);
begin
  if GridWouldRefuse(TGridAccess(G).ColCount, TGridAccess(G).RowCount,
                     N, TGridAccess(G).FixedRows) then
    GGuiError := 1
  else
    TGridAccess(G).FixedCols := N;
end;

procedure GridSetFixedRows(G: TCustomGrid; N: Integer);
begin
  if GridWouldRefuse(TGridAccess(G).ColCount, TGridAccess(G).RowCount,
                     TGridAccess(G).FixedCols, N) then
    GGuiError := 1
  else
    TGridAccess(G).FixedRows := N;
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
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then GridSetColCount(TDrawGrid(c), ArgI32(A[1]), E); end;
function f_dg_colcount_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then Result := ValInt(TDrawGrid(c).ColCount); end;
function f_dg_rowcount_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then GridSetRowCount(TDrawGrid(c), ArgI32(A[1]), E); end;
function f_dg_rowcount_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then Result := ValInt(TDrawGrid(c).RowCount); end;
function f_dg_fixedrows_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then GridSetFixedRows(TDrawGrid(c), ArgI32(A[1])); end;
function f_dg_fixedrows_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then Result := ValInt(TDrawGrid(c).FixedRows); end;
function f_dg_fixedcols_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TDrawGrid, c) then GridSetFixedCols(TDrawGrid(c), ArgI32(A[1])); end;
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
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStringGrid, c) then GridSetColCount(TStringGrid(c), ArgI32(A[1]), E); Result := A[0]; end;
function f_colcount_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStringGrid, c) then Result := ValInt(TStringGrid(c).ColCount) else Result := ValInt(0); end;
function f_rowcount_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStringGrid, c) then GridSetRowCount(TStringGrid(c), ArgI32(A[1]), E); Result := A[0]; end;
function f_rowcount_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStringGrid, c) then Result := ValInt(TStringGrid(c).RowCount) else Result := ValInt(0); end;
function f_fixedrows_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TStringGrid, c) then GridSetFixedRows(TStringGrid(c), ArgI32(A[1])); Result := A[0]; end;
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

initialization
  // Linking the package arms the bridge's gate -- see GridPropGate.
  GuiAddPropGate(@GridPropGate);
  GuiAddPropWritten(@GridPropWritten);

end.
