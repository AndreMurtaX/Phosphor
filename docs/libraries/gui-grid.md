# gui-grid — two grids: one that keeps your strings, one that calls you back to paint

`host/gui/libs/PhosphorGridLib.pas` · 24 functions · GUI package (the `phosphor`
host registers it wherever a graphical session is reachable — always on Windows,
a `DISPLAY` or `WAYLAND_DISPLAY` elsewhere; where there is none these names are
simply not registered)

## What it is for

Two table controls, and the difference between them is *who owns the cells*.
A **string grid** (`stringgrid@`) is a grid that stores strings: write a cell,
read it back, clear the lot. A **draw grid** (`drawgrid@`) has the same rows,
columns and frozen headers but stores nothing at all — when it needs a cell it
calls a BASIC function and hands it a rectangle to paint. The program's own data
stays the model; the grid is only the window onto it.

Everything here is **1-based**, as the unit header says in the author's words:
cell `(g@, 1, 1)` is the top-left, which is the LCL's `Cells[0, 0]`. That holds
for the cells, for the cursor (`drawgrid_col`, `drawgrid_row`), and for the cell
numbers a draw handler is given. Fixed rows and columns are *part of* the counts,
not extra: a grid with `rowcount` 6 and `fixedrows` 1 has five data rows, and the
header is row 1 like any other.

Failures are **recorded, not raised** — the GUI rule everywhere. A handle that is
not a grid of that kind, or a cell outside the grid, sets `gui_error()` to 1 and
the call does nothing; readers still answer something usable (`""` from
`stringgrid_cell$`, `0` from a getter), and the setters answer **the grid handle**
rather than a success flag, so a caller keeps hold of the thing it changed.
Because `""` is also what an empty cell honestly contains, `gui_error()` — cleared
with `gui_clearerror()` — is how you tell an empty cell from a refused one.

The draw protocol is the part worth reading twice. `drawgrid_ondrawcell@` binds a
BASIC function of your own, declared with eight parameters in this order —
`sender@`, `col%`, `row%`, `x%`, `y%`, `w%`, `h%`, `state$`: the grid's own handle,
the cell in base-1, the rectangle **flattened to x, y, width and height** (a
program has no rect type to receive), and the cell's state as the same short string the
mouse and key events use — `"S"` selected, `"F"` focused, `"X"` fixed, joined by
spaces, tested with `instr(state$, "X") > 0`. `sender@` is a canvas target, so the
`canvas_*` verbs draw straight onto the grid that asked. An empty handler name
unwires, as everywhere else in the GUI. And since a headless run never paints,
`drawgrid_drawcell@` paints one cell **now**, on demand — the same discipline as
`button_click` firing one click — going through the grid's own `OnDrawCell`, so a
grid that has been unwired really does stop.

## Functions

### The string grid — the control keeps the cells

| function | what it answers |
| --- | --- |
| `stringgrid@(parent@) → handle` | a new string grid parented to `parent@` and registered as a handle. `0`, with `gui_error()` 1, when `parent@` is not a control that can hold children |
| `stringgrid_colcount@(g@, n) → handle` · `stringgrid_colcount(g@) → num` | how many columns, fixed ones included. The setter answers `g@` — unchanged and with `gui_error()` 1 if the handle is not a string grid; the getter answers `0`, which is never a real count, for the same case |
| `stringgrid_rowcount@(g@, n) → handle` · `stringgrid_rowcount(g@) → num` | how many rows in total, header rows included. Same refusal shape: the handle back, or `0` |
| `stringgrid_fixedrows@(g@, n) → handle` · `stringgrid_fixedrows(g@) → num` | how many leading rows are frozen as a header. They are counted inside `rowcount` and addressed like any other row |
| `stringgrid_cell@(g@, col, row, s$) → handle` | put `s$` in a cell, base-1, and answer the grid. A column or row outside the grid — including `0`, since cells start at 1 — writes nothing and records `gui_error()` 1; the handle still comes back |
| `stringgrid_cell$(g@, col, row) → str` | what that cell holds. `""` for a genuinely empty cell **and** for one outside the grid or a handle that is not a string grid; the out-of-bounds case also sets `gui_error()` 1, which is the only way to tell them apart |
| `stringgrid_clear@(g@) → handle` | empty every cell, header cells included, and answer the grid. The geometry — counts and fixed rows — is untouched; a refused handle changes nothing and records `gui_error()` 1 |

### The draw grid — the program paints the cells

| function | what it answers |
| --- | --- |
| `drawgrid@(parent@) → handle` | a new draw grid parented to `parent@`: geometry and a cursor, no cell storage. `0`, with `gui_error()` 1, when the parent cannot hold children |
| `drawgrid_colcount@(g@, n) → handle` · `drawgrid_colcount(g@) → num` | how many columns. Setter answers `g@`, getter `0` when the handle is not a draw grid — a string grid handle is *refused*, not coerced |
| `drawgrid_rowcount@(g@, n) → handle` · `drawgrid_rowcount(g@) → num` | how many rows, fixed ones included. Same refusal shape |
| `drawgrid_fixedrows@(g@, n) → handle` · `drawgrid_fixedrows(g@) → num` | how many leading rows are frozen. Cells in them draw with `"X"` in `state$` |
| `drawgrid_fixedcols@(g@, n) → handle` · `drawgrid_fixedcols(g@) → num` | the same for leading columns; a cell in either draws fixed |
| `drawgrid_col(g@) → num` | which column the cursor is on, base-1. `0` — never a legal cell — when the handle is refused |
| `drawgrid_row(g@) → num` | which row the cursor is on, base-1; `0` on a refused handle |
| `drawgrid_cursor@(g@, col, row) → handle` | move the cursor there, base-1, and answer the grid. That cell then draws with `"S"` and `"F"` in its state. A refused handle moves nothing and records `gui_error()` 1; the position itself is handed to the grid unchecked — only `drawgrid_drawcell@` validates a cell |
| `drawgrid_drawcell@(g@, col, row) → handle` | paint that one cell now, through the grid's own `OnDrawCell`, and answer the grid. A cell outside the grid paints nothing and records `gui_error()` 1. With **nothing bound** it simply does nothing and records **no** error |
| `drawgrid_ondrawcell@(g@, handler$) → handle` | bind the paint handler by name and answer the grid; `""` unwires it. A handler that fails at run time is recorded as `gui_error()` 2 rather than raised, so one bad repaint does not end the program. A refused handle binds nothing |

## A worked example

A window with both grids side by side: the string grid holds five days of
readings, and the draw grid beside it paints each one as a bar. Nothing is copied
between them — the painter reads the table every time it is asked for a cell.

```basic
rem Two grids, one model. Run it:  phosphor run bars.bas

DAYS = 5

f@ = form@("Two grids", 520, 260)

rem --- the string grid: this is where the numbers actually live ---
t@ = stringgrid@(f@)
control_bounds@(t@, 10, 10, 240, 200)
stringgrid_colcount@(t@, 2)
stringgrid_rowcount@(t@, DAYS + 1)
stringgrid_fixedrows@(t@, 1)
stringgrid_cell@(t@, 1, 1, "day")
stringgrid_cell@(t@, 2, 1, "high")
for d = 1 to DAYS
  stringgrid_cell@(t@, 1, d + 1, "day " + str$(d))
  stringgrid_cell@(t@, 2, d + 1, str$(18 + d))
next

rem --- the draw grid: same shape, no storage, one column of bars ---
bars@ = drawgrid@(f@)
control_bounds@(bars@, 260, 10, 240, 200)
drawgrid_colcount@(bars@, 1)
drawgrid_rowcount@(bars@, DAYS + 1)
drawgrid_fixedrows@(bars@, 1)
drawgrid_fixedcols@(bars@, 0)
drawgrid_ondrawcell@(bars@, "paint_bar")

drawgrid_cursor@(bars@, 1, 2)
println "cursor on column "; drawgrid_col(bars@); ", row "; drawgrid_row(bars@);
println " -- "; stringgrid_cell$(t@, 1, drawgrid_row(bars@))

rem A late correction. Changing the table does not repaint anything by itself,
rem so ask for the one cell that moved.
stringgrid_cell@(t@, 2, 3, "27")
drawgrid_drawcell@(bars@, 1, 3)

form_show(f@)
app_run()

function paint_bar(sender@, col%, row%, x%, y%, w%, h%, state$)
  rem sender@ is the grid itself: canvas_* paints straight onto it
  canvas_brushcolor@(sender@, 16777215)
  canvas_fillrect@(sender@, x%, y%, x% + w%, y% + h%)
  if instr(state$, "X") > 0 then
    canvas_fontcolor@(sender@, 0)
    canvas_textout@(sender@, x% + 4, y% + 2, "high")
  else
    rem row 3 here is row 3 there -- both grids are base-1 with one header row
    v = val(stringgrid_cell$(t@, 2, row%))
    if instr(state$, "S") > 0 then
      canvas_brushcolor@(sender@, 65535)
    else
      canvas_brushcolor@(sender@, 16744448)
    endif
    canvas_fillrect@(sender@, x% + 4, y% + 3, x% + 4 + int(v / 30 * (w% - 8)), y% + h% - 3)
  endif
  return 0
endfunction
```

Two things to notice:

- **The draw grid has no data to get out of date.** `paint_bar` reads
  `stringgrid_cell$` on every call, so correcting a cell and asking for that one
  cell back is the whole update path — there is no second copy to keep in step.
- **`state$` decides the drawing, not a separate query.** The handler never asks
  the grid what is selected or fixed; it is told, in the same short-string form
  the mouse and key events already use.

## Notes / Where the rest lives

`drawgrid_drawcell@` exists as much for tests as for repaints: a headless suite
never paints, so without a way to draw one cell on demand the entire protocol
would be code no test could reach. `tests/gui/15_drawgrid.bas` uses it that way,
and `tests/gui/07_image_grid.bas` covers the string grid.

Only the grid-shaped things are here. Position and size — `control_bounds@` and
`control_move@` — fonts and visibility come from the control library; the
`canvas_*` verbs a paint handler calls come from the canvas library; `gui_error()`
and `gui_clearerror()` from the GUI core; and `app_run()`, which is what actually
makes the paints happen, from there too. Sorting, selection ranges and CSV import
are not part of this library — a string grid gives you cells, and the program
decides what they mean.
