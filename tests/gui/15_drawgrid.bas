rem ---------------------------------------------------------------
rem drawgrid@ and the OnDrawCell protocol.
rem
rem The audit reclassified this from Tier 3 to Defer with a reason worth
rem keeping: OnDrawCell is not another event signature, it is a DRAWING
rem PROTOCOL. The handler is handed a cell, a rectangle and a state, and
rem is expected to paint into the grid's own canvas while the grid is
rem mid-paint. That description was right, and it is also what made the
rem thing buildable once two other pieces existed:
rem
rem   * the canvas target stopped meaning "a TBitmap" -- generalised for
rem     paintbox@, widened here to any control that paints itself, which
rem     is what lets a handler draw onto the grid that called it;
rem   * GuiCallBack, the callback seam exposed so a package owning its own
rem     event signature can use it without GuiCore knowing that signature
rem     exists (TDrawCellEvent lives in Grids).
rem
rem A headless suite never paints, so drawgrid_drawcell@ draws one cell on
rem demand -- the same discipline as control_keydown@ and button_click.
rem Without it the whole protocol would be code no test could reach.
rem ---------------------------------------------------------------

draws = 0
lastcol = 0
lastrow = 0
lastw = 0
lasth = 0
laststate$ = ""
drawerr = 0

f@ = form@("grid", 400, 300)
gui_clearerror()
g@ = drawgrid@(f@)
assert_eq(gui_error(), 0, "constructed")

test_case("drawgrid/shape, base-1 like stringgrid@")
drawgrid_colcount@(g@, 4)
drawgrid_rowcount@(g@, 5)
drawgrid_fixedrows@(g@, 1)
drawgrid_fixedcols@(g@, 1)
assert_eq(drawgrid_colcount(g@), 4, "four columns")
assert_eq(drawgrid_rowcount(g@), 5, "five rows")
assert_eq(drawgrid_fixedrows(g@), 1, "one fixed row")
assert_eq(drawgrid_fixedcols(g@), 1, "one fixed column")

test_case("drawgrid/the handler is handed the cell, the rectangle and the state")
drawgrid_ondrawcell@(g@, "on_draw")
assert_eq(gui_error(), 0, "binding records no error")
drawgrid_drawcell@(g@, 3, 4)
assert_eq(draws, 1, "the handler ran")
assert_eq(lastcol, 3, "column 3, base-1 -- not the LCL's 2")
assert_eq(lastrow, 4, "and row 4")
assert_true(lastw > 0, "the rectangle has a width")
assert_true(lasth > 0, "and a height")

test_case("drawgrid/state says what the cell is")
rem a fixed cell is in the header row or column
drawgrid_drawcell@(g@, 1, 1)
assert_true(instr(laststate$, "X") > 0, "cell 1,1 is fixed")
drawgrid_drawcell@(g@, 3, 4)
assert_eq(instr(laststate$, "X"), 0, "an ordinary cell is not")

rem put the cursor somewhere and that cell draws selected AND focused
drawgrid_cursor@(g@, 2, 3)
assert_eq(drawgrid_col(g@), 2, "the cursor column reads back base-1")
assert_eq(drawgrid_row(g@), 3, "and the row")
drawgrid_drawcell@(g@, 2, 3)
assert_true(instr(laststate$, "S") > 0, "the cursor cell is selected")
assert_true(instr(laststate$, "F") > 0, "and focused")
drawgrid_drawcell@(g@, 4, 5)
assert_eq(instr(laststate$, "S"), 0, "another cell is neither")

test_case("drawgrid/the handler really can draw on the grid it was called from")
rem this is the whole point of the protocol, and of widening the canvas target:
rem on_draw paints into sender@, which is the grid, not a bitmap
assert_eq(drawerr, 0, "the drawing calls inside the handler recorded no error")

test_case("drawgrid/a cell outside the grid is refused")
gui_clearerror()
drawgrid_drawcell@(g@, 99, 1)
assert_true(gui_error(), "past the last column")
gui_clearerror()
drawgrid_drawcell@(g@, 1, 0)
assert_true(gui_error(), "and before the first row, since cells are base-1")

test_case("drawgrid/an empty name unwires it")
drawgrid_ondrawcell@(g@, "")
draws = 0
gui_clearerror()
drawgrid_drawcell@(g@, 2, 2)
assert_eq(draws, 0, "the handler no longer runs")
assert_eq(gui_error(), 0, "and drawing a cell with nothing bound is not an error")

test_case("drawgrid/a stringgrid is not a drawgrid")
sg@ = stringgrid@(f@)
gui_clearerror()
drawgrid_colcount@(sg@, 3)
assert_true(gui_error(), "the handle is refused rather than coerced")

function on_draw(sender@, col%, row%, x%, y%, w%, h%, state$)
  draws = draws + 1
  lastcol = col%
  lastrow = row%
  lastw = w%
  lasth = h%
  laststate$ = state$
  rem paint into the GRID -- sender@ is the drawgrid, and canvas_* reaches it
  gui_clearerror()
  canvas_brushcolor@(sender@, 16777215)
  canvas_fillrect@(sender@, x%, y%, x% + w%, y% + h%)
  canvas_pencolor@(sender@, 0)
  canvas_textout@(sender@, x% + 2, y% + 2, str$(col%) + "," + str$(row%))
  if gui_error() <> 0 then drawerr = drawerr + 1
  return 0
endfunction
