rem ---------------------------------------------------------------
rem A STRING GRID AS A RECORD LIST: which row is picked, an event when
rem the pick changes, and a double click on any control.
rem
rem   stringgrid_row / stringgrid_col     the cursor, base-1
rem   stringgrid_cursor@                  move it, as a click would
rem   stringgrid_onselect@                handler(sender@) on a move
rem   control_ondblclick@ / control_dblclick@
rem
rem EXPECTED VALUES, from the LCL's own source (lcl/grids.pas), not
rem from a run:
rem   - TCustomStringGrid's constructor sets FixedCols := 1 and
rem     FixedRows := 1, so a fresh grid's cursor sits on the first
rem     scrollable cell: column 2, row 2.
rem   - SetCol/SetRow exit early when the value is unchanged, and
rem     otherwise go MoveExtend -> TryMoveSelection -> CheckLimits,
rem     which CLAMPS the cell into [Fixed..Count-1] on each axis, then
rem     MoveSelection fires OnSelection. So a move fires once for each
rem     axis that changes, and a cell outside the scrollable area lands
rem     on the nearest one inside it.
rem   - TControl.DblClick fires OnDblClick.
rem ---------------------------------------------------------------

test_case("grid select/a fresh grid's cursor is past the fixed row and column")
f@ = form@("grid select", 400, 300)
g@ = stringgrid@(f@)
stringgrid_colcount@(g@, 3)
stringgrid_rowcount@(g@, 5)
assert_eq(stringgrid_col(g@), 2, "column 2: column 1 is fixed by default")
assert_eq(stringgrid_row(g@), 2, "row 2: row 1 is fixed by default")

test_case("grid select/moving the cursor fires the handler once per axis")
moves = 0
lastrow = 0
stringgrid_onselect@(g@, "on_select")
stringgrid_cursor@(g@, 2, 4)
assert_eq(stringgrid_row(g@), 4, "the cursor is on row 4")
assert_eq(stringgrid_col(g@), 2, "and still on column 2")
assert_eq(moves, 1, "one axis changed: one event")
assert_eq(lastrow, 4, "and the handler read the new row through its sender")
stringgrid_cursor@(g@, 3, 5)
assert_eq(moves, 3, "both axes changed: two more events")
stringgrid_cursor@(g@, 3, 5)
assert_eq(moves, 3, "the same cell again changes nothing and fires nothing")

test_case("grid select/a cell outside the scrollable area is clamped into it")
stringgrid_cursor@(g@, 3, 1)
assert_eq(stringgrid_row(g@), 2, "the header row is fixed: the cursor stops on row 2")
stringgrid_cursor@(g@, 9, 9)
assert_eq(stringgrid_col(g@), 3, "past the last column lands on the last column")
assert_eq(stringgrid_row(g@), 5, "past the last row lands on the last row")

test_case("grid select/an empty name unwires the handler")
stringgrid_onselect@(g@, "")
before = moves
stringgrid_cursor@(g@, 2, 2)
assert_eq(moves, before, "no handler, no event")

test_case("grid select/with no fixed column the first column can hold the cursor")
control_set@(g@, "FixedCols", 0)
stringgrid_cursor@(g@, 1, 3)
assert_eq(stringgrid_col(g@), 1, "column 1 is an ordinary column now")
assert_eq(stringgrid_row(g@), 3, "row 3")

test_case("grid select/a bad handle answers 0 and records the error")
gui_clearerror()
assert_eq(stringgrid_row(f@), 0, "a form is not a string grid")
assert_eq(gui_error(), 1, "and that is recorded")
gui_clearerror()
assert_eq(stringgrid_col(f@), 0, "the column getter too")
assert_eq(gui_error(), 1, "recorded")

test_case("grid columns/each column has its own width")
stringgrid_colwidth@(g@, 1, 150)
stringgrid_colwidth@(g@, 3, 40)
assert_eq(stringgrid_colwidth(g@, 1), 150, "column 1 is 150 px")
assert_eq(stringgrid_colwidth(g@, 3), 40, "column 3 is 40 px, independently")
gui_clearerror()
stringgrid_colwidth@(g@, 4, 10)
assert_eq(gui_error(), 1, "a column past the last is refused")
gui_clearerror()
stringgrid_colwidth@(g@, 1, 32001)
assert_eq(gui_error(), 1, "a width past the GUI's 32000 ceiling is refused")
assert_eq(stringgrid_colwidth(g@, 1), 150, "and the width is unchanged")
gui_clearerror()
assert_eq(stringgrid_colwidth(g@, 0), 0, "column 0 does not exist: 0")
assert_eq(gui_error(), 1, "and that is recorded")

test_case("double click/on a grid and on a button")
dbl = 0
control_ondblclick@(g@, "on_dbl")
control_dblclick@(g@)
assert_eq(dbl, 1, "the grid's double click ran the handler")
b@ = button@(f@)
control_ondblclick@(b@, "on_dbl")
control_dblclick@(b@)
assert_eq(dbl, 2, "any control can carry it -- a button too")
control_ondblclick@(b@, "")
control_dblclick@(b@)
assert_eq(dbl, 2, "an empty name unwires it")
dead@ = button@(f@)
control_free(dead@)
gui_clearerror()
control_dblclick@(dead@)
assert_eq(gui_error(), 1, "a freed control is refused and recorded")
end

function on_select(s@)
  moves = moves + 1
  lastrow = stringgrid_row(s@)
  return 0
endfunction

function on_dbl(s@)
  dbl = dbl + 1
  return 0
endfunction
