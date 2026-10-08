rem ---------------------------------------------------------------
rem image_setbitmap@ IS A SURFACE, AND THE LEDGER NOW SEES IT (d42, n19).
rem
rem Every other name in host/gui that makes a surface charges the one
rem GUI budget (GuiMaxLiveBytes, 1 GB) and is credited when the surface
rem dies. image_setbitmap@ charged nothing: it put a full copy of the
rem bitmap into the image, so any number of images could hold a
rem 6688-square picture each while the ledger read only the bitmap.
rem The copy is real -- LCL shares the pixels on assignment and splits
rem them the first time either side is drawn on -- so the image is
rem charged a surface of the bitmap's size, BEFORE the assignment, and
rem the assignment is refused, as a catchable error, when it does not fit.
rem
rem n19 rode on the same line: it read Picture.Bitmap, which is a
rem GETTER that converts whatever picture the image holds into a new
rem full-size bitmap before the assignment replaced it. The setter is
rem used now, which never converts.
rem
rem MOST OF THIS COSTS NO REAL MEMORY. TBitmap.SetSize is lazy, these
rem bitmaps are never drawn on, and the form is never shown, so the
rem ledger is driven to its edge without the suite needing a gigabyte
rem (see 19_argord_and_size.bas, which works the same way).
rem
rem The numbers, written out:
rem   a surface   6 bytes a pixel + 4 a row
rem   6688^2      = 44729344 pixels
rem   one         = 44729344 * 6 + 6688 * 4 = 268402816 bytes (255.9 MB)
rem   four        = 1073611264, which is 130560 short of 1073741824
rem So one bitmap plus three images holding it fit, and a fourth does not.
rem
rem Written like 18_faults: `on error goto` records into `raised`, so a
rem returning bug FAILS a case rather than aborting the file.
rem
rem THE TRAP IS LIFTED AROUND EVERY RUN OF ASSERTIONS (2026-10-08): it
rem guards the statements under test, never an assertion. Armed over an
rem assertion, an argument that raised was skipped by `resume next` --
rem neither passed nor failed -- and the test library now fails any
rem assertion that runs while a trap is armed. So a raise in a checked
rem call aborts the run, which is a failure, and not a silent skip.
rem ---------------------------------------------------------------

raised = 0
msg$ = ""

on error goto trapped

f@ = form@("setbitmap", 400, 300)
b@ = bitmap@(6688, 6688)
i1@ = image@(f@)
i2@ = image@(f@)
i3@ = image@(f@)
i4@ = image@(f@)

test_case("setbitmap/an ordinary bitmap still reaches the image")
small@ = bitmap@(32, 24)
canvas_brushcolor@(small@, 255)
canvas_fillrect@(small@, 0, 0, 32, 24)
raised = 0
image_setbitmap@(i1@, small@)
on error goto 0
assert_eq(raised, 0, "a small bitmap did not raise")
assert_eq(image_picwidth(i1@), 32, "and the image holds a picture of its width")
assert_eq(image_picheight(i1@), 24, "and its height")
assert_eq(image_empty(i1@), 0, "and is not empty")
on error goto trapped

test_case("setbitmap/three images fit, the fourth is refused")
raised = 0
image_setbitmap@(i1@, b@)
image_setbitmap@(i2@, b@)
image_setbitmap@(i3@, b@)
on error goto 0
assert_eq(raised, 0, "the bitmap and three copies are inside the budget")
assert_eq(image_picwidth(i3@), 6688, "and the third image holds the picture")
on error goto trapped
rem i4 holds the small picture first (4704 bytes, which still fits), so
rem the refusal below can show that the image KEEPS what it had.
image_setbitmap@(i4@, small@)
on error goto 0
assert_eq(raised, 0, "a small picture still fits beside them")
on error goto trapped
msg$ = ""
image_setbitmap@(i4@, b@)
on error goto 0
assert_eq(raised, 1, "the fourth copy is refused -- it would pass the budget")
assert_eq(err(), 6, "a runtime error, which on error goto catches")
assert_true(instr(msg$, "picture 6688 x 6688 is too large") > 0, "the message names what was refused")
assert_true(instr(msg$, "255.9 MB") > 0, "and what it would have cost")
assert_true(instr(msg$, "already in use") > 0, "and says the room is taken")
rem picwidth, not image_empty: LCL calls a lazy bitmap that was never
rem drawn on EMPTY even while an image holds it, so image_empty answered
rem 1 here against the unfixed build too and measured nothing. And this
rem is the assertion that kills a charge made AFTER the copy: the copy
rem would already be in the image when the refusal came.
assert_eq(image_picwidth(i4@), 32, "and the refused image kept the picture it had")
on error goto trapped

test_case("setbitmap/an image re-given the same picture is not charged twice")
rem i1 already holds a 6688 surface; replacing it with another of the
rem same size costs nothing new. A charge that ADDED instead of
rem replacing would refuse this.
raised = 0
for k = 1 to 200
  image_setbitmap@(i1@, b@)
next
on error goto 0
assert_eq(raised, 0, "two hundred re-assignments at the edge, none refused")
on error goto trapped

test_case("setbitmap/a smaller picture gives room back")
raised = 0
image_setbitmap@(i2@, small@)
on error goto 0
assert_eq(image_picwidth(i2@), 32, "i2 now holds the small picture")
on error goto trapped
image_setbitmap@(i4@, b@)
on error goto 0
assert_eq(raised, 0, "and the room it gave back admits the fourth")
assert_eq(image_picwidth(i4@), 6688, "which now holds the picture")
on error goto trapped

test_case("setbitmap/freeing an image gives its room back")
rem A TImage is a TComponent, so it is credited by FreeNotification
rem whoever frees it -- and that is its ONLY credit path, because the
rem form owns it, not its handle. The room is proved with a BITMAP, not
rem another image: an earlier draft re-made an image each pass, and
rem with the notification removed it still passed, because the
rem allocator handed each new TImage the address of the one just freed
rem and the ledger took it for the same object. A bitmap is a different
rem class and size, so it can never inherit a dead image's entry.
raised = 0
on error goto 0
assert_eq(control_free(i4@), 1, "the image is freed")
on error goto trapped
n = 0
for k = 1 to 50
  t@ = image@(f@)
  image_setbitmap@(t@, b@)
  x = control_free(t@)
  nb@ = bitmap@(6688, 6688)
  if bitmap_width(nb@) = 6688 then n = n + 1
  x = control_free(nb@)
next
on error goto 0
assert_eq(raised, 0, "fifty cycles at the edge, none refused")
assert_eq(n, 50, "and every freed image's room was there for a bitmap")
on error goto trapped

test_case("setbitmap/an image freed with its form gives its room back")
raised = 0
g@ = form@("setbitmap-2", 200, 100)
gi@ = image@(g@)
image_setbitmap@(gi@, b@)
on error goto 0
assert_eq(raised, 0, "a fourth surface fits again")
on error goto trapped
x = control_free(g@)
rem A bitmap again, for the reason the case above gives.
nb@ = bitmap@(6688, 6688)
on error goto 0
assert_eq(raised, 0, "and freeing the form credited the image it owned")
on error goto trapped

end

trapped:
raised = 1
msg$ = errmsg$()
resume next
