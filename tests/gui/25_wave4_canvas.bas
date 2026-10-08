rem ---------------------------------------------------------------
rem WAVE 4 (ledger d44): every GUI name no test had called, drawing side.
rem
rem Like 09_canvas, drawn on an off-screen bitmap and PROVEN by reading
rem pixels back, headless. Colours are TColor numbers: 255 red, 65280
rem green, 16711680 blue, 16777215 white. Every expected value comes from
rem the geometry written out beside it, not from a run:
rem   * canvas_clear fills the whole surface with the brush colour;
rem   * an ellipse in (10,10)-(90,90) covers its centre (50,50), and not
rem     the bounding box's corner (12,12), which lies outside the curve;
rem   * a line along y = 50 one pixel wide does not reach y = 53; a line
rem     along y = 80 nine pixels wide spans exactly 76..84 -- a centred
rem     pen covers w div 2 rows each side -- so 75 and 85 are untouched;
rem   * a larger font is taller;
rem   * text drawn in a colour leaves pixels of that colour, and the
rem     cell of a leading SPACE -- background only -- stays the brush's;
rem   * a shown paint box is painted when its paint is processed, which is
rem     what app_processmessages() is for.
rem An adversarial review (2026-10-08) showed three of these could not
rem fail: a font colour that set the BRUSH still left green pixels, a pen
rem two pixels too narrow still reached three rows, and a processmessages
rem that did nothing still answered 0. Each now has the check that fails.
rem A paint box is never painted without a window on screen (measured
rem on win32 and gtk2), so its handler is run through this runner's
rem test-only gui_test_fire, which calls TPaintBox.Paint -- the method a
rem real repaint ends in.
rem ---------------------------------------------------------------

paints = 0

test_case("canvas4/clear fills the surface with the brush")
bm@ = bitmap@(100, 80)
canvas_brushcolor@(bm@, 255)
r@ = canvas_clear@(bm@)
assert_eq(bitmap_pixel(r@, 0, 0), 255, "the first corner is the brush colour")
assert_eq(bitmap_pixel(bm@, 99, 79), 255, "and so is the last")

test_case("canvas4/an ellipse covers its centre, not its corners")
e@ = bitmap@(100, 100)
canvas_brushcolor@(e@, 16777215)
z@ = canvas_clear@(e@)
canvas_brushcolor@(e@, 255)
canvas_pencolor@(e@, 255)
r@ = canvas_ellipse@(e@, 10, 10, 90, 90)
assert_eq(bitmap_pixel(r@, 50, 50), 255, "its centre is filled")
assert_eq(bitmap_pixel(e@, 12, 12), 16777215, "the box's corner is outside the curve")

test_case("canvas4/pen width")
w@ = bitmap@(100, 100)
canvas_brushcolor@(w@, 16777215)
z@ = canvas_clear@(w@)
canvas_pencolor@(w@, 16711680)
canvas_penwidth@(w@, 1)
canvas_line@(w@, 10, 50, 90, 50)
assert_eq(bitmap_pixel(w@, 50, 50), 16711680, "a one-pixel line is on its row")
assert_eq(bitmap_pixel(w@, 50, 53), 16777215, "and three rows away is untouched")
canvas_penwidth@(w@, 9)
canvas_line@(w@, 10, 80, 90, 80)
assert_eq(bitmap_pixel(w@, 50, 76), 16711680, "a nine-pixel line's first row is 80 - 4")
assert_eq(bitmap_pixel(w@, 50, 84), 16711680, "and its last is 80 + 4")
assert_eq(bitmap_pixel(w@, 50, 75), 16777215, "the row before is untouched")
assert_eq(bitmap_pixel(w@, 50, 85), 16777215, "and so is the row after")

test_case("canvas4/font size and colour")
t@ = bitmap@(200, 100)
canvas_brushcolor@(t@, 16777215)
z@ = canvas_clear@(t@)
canvas_fontsize@(t@, 8)
small = canvas_textheight(t@, "Xg")
canvas_fontsize@(t@, 32)
assert_true(canvas_textheight(t@, "Xg") > small, "a larger font is taller")
canvas_fontcolor@(t@, 65280)
canvas_textout@(t@, 5, 5, " XXXX")
sw = canvas_textwidth(t@, " ")
th = canvas_textheight(t@, " XXXX")
assert_eq(bitmap_pixel(t@, 5 + int(sw / 2), 5 + int(th / 2)), 16777215, "a space's cell is the brush, not the font colour")
greens = 0
for yy = 0 to 99
  for xx = 0 to 199
    if bitmap_pixel(t@, xx, yy) = 65280 then greens = greens + 1
  next
next
assert_true(greens > 0, "text drawn in green leaves green pixels")

test_case("canvas4/a shape's pen")
f@ = form@("canvas4", 300, 200)
sh@ = shape@(f@)
r@ = shape_pencolor@(sh@, 16711680)
assert_eq(shape_pencolor(r@), 16711680, "and the pen colour reads back")

test_case("canvas4/a paint box's handler")
pb@ = paintbox@(f@)
paintbox_onpaint@(pb@, "on_paint")
x = app_processmessages()
assert_eq(paints, 0, "no window on screen, no paint")
assert_eq(gui_test_fire(pb@, "paint"), 1, "TPaintBox.Paint is what a repaint calls")
assert_eq(paints, 1, "and it runs the handler")
paintbox_onpaint@(pb@, "")
x = gui_test_fire(pb@, "paint")
assert_eq(paints, 1, "unbound, it stays quiet")

test_case("canvas4/a shown paint box is painted when messages are processed")
paints = 0
paintbox_onpaint@(pb@, "on_paint")
f@ = form_show@(f@)
x = app_processmessages()
assert_true(paints > 0, "showing it and processing messages paints it")
paintbox_onpaint@(pb@, "")
f@ = form_close@(f@)
x = app_processmessages()
end

function on_paint(sender@)
  paints = paints + 1
  return 0
endfunction
