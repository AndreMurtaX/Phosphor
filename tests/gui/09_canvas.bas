rem ---------------------------------------------------------------
rem Immediate-mode drawing on an off-screen bitmap -- the LCL-native
rem answer to the reference's shapes/path. It needs no window, so the
rem drawing is PROVEN headless by reading a pixel back. The bitmap can
rem then be shown in an image control. Plus the simple TShape control.
rem
rem Colours are TColor numbers: 255 = red, 65280 = green, 16711680 = blue.
rem ---------------------------------------------------------------

test_case("canvas/a bitmap surface")
bm@ = bitmap@(100, 80)
assert_eq(bitmap_width(bm@), 100, "width")
assert_eq(bitmap_height(bm@), 80, "height")

test_case("canvas/a filled rectangle really paints")
canvas_brushcolor@(bm@, 255)
canvas_fillrect@(bm@, 10, 10, 60, 60)
assert_eq(bitmap_pixel(bm@, 30, 30), 255, "a pixel inside the rectangle is red")

test_case("canvas/another colour, another region")
canvas_brushcolor@(bm@, 65280)
canvas_fillrect@(bm@, 61, 10, 90, 60)
assert_eq(bitmap_pixel(bm@, 75, 30), 65280, "a pixel in the second region is green")
assert_eq(bitmap_pixel(bm@, 30, 30), 255, "and the first region is still red")

test_case("canvas/show the bitmap in an image")
f@ = form@("host", 300, 200)
im@ = image@(f@)
image_setbitmap@(im@, bm@)
assert_eq(image_picwidth(im@), 100, "the image now carries the 100-wide bitmap")

test_case("shape/config round trips")
sh@ = shape@(f@)
shape_kind@(sh@, 4)
assert_eq(shape_kind(sh@), 4, "shape kind (ellipse) round trip")
shape_brushcolor@(sh@, 255)
assert_eq(shape_brushcolor(sh@), 255, "brush colour round trip")

rem ---------------------------------------------------------------
rem POLYLINE AND POLYGON DREW ONE VERTEX SHORT.
rem
rem Both passed n - 1 to the LCL, and NumPts reaches Windows.Polyline
rem as cPoints -- the NUMBER of points, read in the widgetset source,
rem not assumed -- while ParsePoints returns N as a count. So the last
rem vertex was dropped: a two-point polyline drew NOTHING and reported
rem success, and a four-vertex square drew as a three-sided triangle.
rem
rem Read back off the bitmap, headless, like everything else here.
rem ---------------------------------------------------------------

test_case("canvas/a two-point polyline draws its one segment")
pb@ = bitmap@(16, 16)
canvas_brushcolor@(pb@, 16777215)
canvas_fillrect@(pb@, 0, 0, 16, 16)
canvas_pencolor@(pb@, 255)
x@ = canvas_polyline@(pb@, "0,0 15,15")
assert_eq(gui_error(), 0, "it reported success")
assert_eq(bitmap_pixel(pb@, 0, 0), 255, "and the first end really is painted")
assert_eq(bitmap_pixel(pb@, 7, 7), 255, "and so is the middle of the segment")

test_case("canvas/a three-point polyline draws BOTH segments")
canvas_brushcolor@(pb@, 16777215)
canvas_fillrect@(pb@, 0, 0, 16, 16)
x@ = canvas_polyline@(pb@, "0,0 15,0 15,15")
assert_eq(bitmap_pixel(pb@, 7, 0), 255, "the first segment")
assert_eq(bitmap_pixel(pb@, 15, 7), 255, "and the second, which used to be missing")

test_case("canvas/a four-vertex polygon has four sides")
canvas_brushcolor@(pb@, 16777215)
canvas_fillrect@(pb@, 0, 0, 16, 16)
canvas_brushcolor@(pb@, 16777215)
x@ = canvas_polygon@(pb@, "0,0 15,0 15,15 0,15")
assert_eq(bitmap_pixel(pb@, 7, 0), 255, "top")
assert_eq(bitmap_pixel(pb@, 15, 7), 255, "right")
assert_eq(bitmap_pixel(pb@, 7, 15), 255, "bottom -- the side that was lost")
assert_eq(bitmap_pixel(pb@, 0, 7), 255, "left -- and so was this one")
