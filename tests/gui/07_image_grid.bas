rem ---------------------------------------------------------------
rem An image (its display flags and the missing-file error path) and a
rem string grid (1-based cells). No real picture file is needed: the
rem error path is checked with a name that does not exist. Headless.
rem ---------------------------------------------------------------

test_case("image/display flags and empty state")
f@ = form@("host", 500, 400)
im@ = image@(f@)
assert_eq(gui_error(), 0, "image@ built an image")
assert_eq(image_empty(im@), 1, "a fresh image holds no picture")
image_stretch@(im@, 1)
assert_eq(image_stretch(im@), 1, "stretch round trip")
image_center@(im@, 1)
assert_eq(image_center(im@), 1, "center round trip")

test_case("image/a missing file is recorded, not raised")
gui_clearerror()
image_load@(im@, "bin/does-not-exist.png")
assert_true(gui_error(), "loading a missing file sets an error")
assert_eq(image_empty(im@), 1, "and leaves the image empty")

test_case("grid/1-based cells")
g@ = stringgrid@(f@)
stringgrid_colcount@(g@, 3)
stringgrid_rowcount@(g@, 4)
assert_eq(stringgrid_colcount(g@), 3, "colcount round trip")
assert_eq(stringgrid_rowcount(g@), 4, "rowcount round trip")
stringgrid_cell@(g@, 1, 1, "top-left")
stringgrid_cell@(g@, 3, 4, "bottom-right")
assert_eq(stringgrid_cell$(g@, 1, 1), "top-left", "cell 1,1 is the corner")
assert_eq(stringgrid_cell$(g@, 3, 4), "bottom-right", "cell 3,4 round trip")

test_case("grid/out of range is recorded")
gui_clearerror()
stringgrid_cell$(g@, 9, 9)
assert_true(gui_error(), "a cell past the edge is recorded, not crashed")

test_case("grid/clear empties the cells")
stringgrid_clear@(g@)
assert_eq(stringgrid_cell$(g@, 1, 1), "", "clear emptied the corner")
