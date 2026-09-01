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
