rem ---------------------------------------------------------------
rem TWO MECHANISMS, EACH PINNED FROM BOTH ENDS.
rem
rem 1. NARROWING AN ARGUMENT TO AN ORDINAL. PhosphorControlLib's
rem    ArgOrd/ArgOrd32/ArgOrdIn used to be Round(ArgNum(v)), which
rem    trapped on the largest Int64 and wrapped silently below it.
rem    Moving them onto the engine's saturating ArgI64/ArgI32 fixed
rem    that and LOST A KIND: TValue is a plain record, so a vkBool
rem    leaves .Num at 0.0 and ArgI64 read the zero. control_set@'s
rem    documented @$? overload -- the one registered GUI signature
rem    that takes a '?' -- wrote False for `true` as well as for
rem    `false`, through BOTH of the bridge's ordinal branches
rem    (Visible is 32 bits, Tag is 64).
rem
rem    So this file pins the boolean AND the Int64 edge together. A
rem    fix for either one that breaks the other fails here.
rem
rem 2. AN ARGUMENT THAT BECOMES AN ALLOCATION. bitmap@, imagelist@
rem    and the four grid counts take ordinary integers and commit
rem    memory with them -- measured on this tree, one line each:
rem    2.3 GB, over 4 GB, and 2.5 GB in two seconds, all with
rem    nothing reported. Nothing raised, so `on error goto` had
rem    nothing to catch and gui_error() stayed 0; the host simply
rem    swelled. Now bounded, as a CATCHABLE error naming the size --
rem    the shape dim@ uses for the same question in the engine.
rem
rem    The refusals are pinned WITH the legitimate sizes beside
rem    them, including the exact limit, because a guard that refuses
rem    an ordinary bitmap would be worse than the leak it replaced.
rem
rem Written like 18_faults so a returning bug FAILS rather than
rem aborting the runner: `on error goto` records into `raised` and
rem `resume next` carries on, so the summary still names the case.
rem ---------------------------------------------------------------

raised = 0
msg$ = ""

on error goto trapped

f@ = form@("argord", 400, 300)
b@ = button@(f@)

rem =================================================================
rem PART 1a -- the boolean overload of control_set@
rem =================================================================

test_case("bool/false through the 32-bit ordinal branch")
raised = 0
gui_clearerror()
control_set@(b@, "Visible", false)
assert_eq(raised, 0, "a bool did not raise")
assert_eq(gui_error(), 0, "and was not refused")
assert_eq(control_visible(b@), 0, "false wrote False")

test_case("bool/and true writes True, which is the regression")
raised = 0
control_set@(b@, "Visible", true)
assert_eq(raised, 0, "true did not raise")
assert_eq(control_visible(b@), 1, "true wrote True, not the 0 a lost kind gave")

test_case("bool/read back through the bridge's own getter")
control_set@(b@, "Enabled", false)
assert_eq(control_get(b@, "Enabled"), 0, "false")
control_set@(b@, "Enabled", true)
assert_eq(control_get(b@, "Enabled"), 1, "true")
assert_eq(control_enabled(b@), 1, "and through the named getter too")

test_case("bool/the 64-bit branch lost it as well -- Tag is PtrInt")
control_set@(b@, "Tag", false)
assert_eq(control_tag(b@), 0, "false is 0")
control_set@(b@, "Tag", true)
assert_eq(control_tag(b@), 1, "true is 1, not 0")

test_case("bool/a bool still reaches a float property as 0 and 1")
rem Alignment is an enum, Left an ordinal; a form's AlphaBlendValue is
rem a byte. The float branch has its own converter (ArgNum), which
rem never lost the kind -- pinned so a future tidy-up cannot merge the
rem two and lose it here instead.
control_set@(b@, "Left", true)
assert_eq(control_left(b@), 1, "true reached an Integer property as 1")

test_case("bool/the other two overloads of the same name still work")
rem @$n, @$$ and @$? are three registered signatures; the boolean fix
rem must not have moved either of the others.
control_set@(b@, "Left", 12)
assert_eq(control_left(b@), 12, "the number overload")
control_set@(b@, "Hint", "a hint")
assert_eq(control_get$(b@, "Hint"), "a hint", "the string overload")
control_set@(b@, "Visible", true)
assert_eq(control_visible(b@), 1, "and the bool overload beside them")

rem =================================================================
rem PART 1b -- and the Int64 edge the boolean fix must not undo
rem =================================================================

test_case("int64/the largest Int64 still saturates and still does not trap")
raised = 0
n% = 9223372036854775807
control_left@(b@, n%)
assert_eq(raised, 0, "High(Int64) did not raise")
assert_eq(control_left(b@), 2147483647, "it saturated at High(Integer)")

test_case("int64/the negative end too")
raised = 0
control_top@(b@, -9223372036854775807)
assert_eq(raised, 0, "the negative end did not raise")
assert_eq(control_top(b@), -2147483648, "it saturated at Low(Integer)")

test_case("int64/a double past Integer does not wrap")
raised = 0
control_left@(b@, 3e9)
assert_eq(raised, 0, "3e9 did not raise")
assert_eq(control_left(b@), 2147483647, "3e9 saturated, never -1294967296")

test_case("int64/through the bridge, on both of its ordinal branches")
raised = 0
control_set@(b@, "Left", 1e19)
assert_eq(raised, 0, "1e19 through the bridge did not raise")
assert_eq(control_left(b@), 2147483647, "and saturated instead of truncating")
control_set@(b@, "Tag", 9007199254740992)
assert_eq(control_tag(b@), 9007199254740992, "a 53-bit tag kept its width")

test_case("int64/ArgOrdIn saturates into a narrower property, not past it")
rem control_cursor@ is the ArgOrdIn caller: TCursor is -32768..32767.
rem It delegates to ArgOrd, so the boolean fix reaches it too.
raised = 0
control_cursor@(b@, 9223372036854775807)
assert_eq(raised, 0, "High(Int64) into a 16-bit property did not raise")
assert_eq(control_cursor(b@), 32767, "it saturated at High(TCursor)")
control_cursor@(b@, -9223372036854775807)
assert_eq(control_cursor(b@), -32768, "and at Low(TCursor)")
control_cursor@(b@, 0)
assert_eq(control_cursor(b@), 0, "an ordinary cursor is untouched")

test_case("int64/and taborder, the other ArgOrdIn caller")
rem TabOrder is the ArgOrdIn caller whose answer the LCL then
rem RENORMALISES -- it moves the control to the end of the tab chain,
rem so on a form with one control the answer is 0 however large the
rem number was. What is pinned here is therefore what ArgOrdIn is for:
rem no trap, and never a wrapped NEGATIVE order.
raised = 0
control_taborder@(b@, 9223372036854775807)
assert_eq(raised, 0, "did not raise")
assert_true(control_taborder(b@) >= 0, "and did not wrap below zero")
control_taborder@(b@, 0)
assert_eq(control_taborder(b@), 0, "and an ordinary tab order is untouched")

rem =================================================================
rem PART 1c -- THE DOOR THE ROUND-ONE METHOD COULD NOT HAVE FOUND.
rem
rem The round-one enumeration was a grep for Reg.Add('literal'), which
rem by construction only sees a signature spelled as one string.
rem engine/libs/PhosphorCallLib registers callfunc* with argument
rem codes BUILT AT RUN TIME, and Resolve matches '*' against any kind
rem -- so there is a second way into every function in the host, and
rem the grep showed none of it. Re-deriving from every registration
rem form finds 28 such run-time registrations, five of them these.
rem
rem Both halves are pinned here because reading the code is not the
rem same as running it:
rem   * a bool still cannot reach an 'n' slot through the wildcard --
rem     it is a catchable "no function", not a silent zero;
rem   * and where a bool legitimately CAN go, the wildcard carries it,
rem     so the fix has to hold on this path too. It did not before:
rem     measured on the unpatched build this wrote False.
rem =================================================================

test_case("bool/a bool cannot reach an ordinal slot through callfunc")
control_left@(b@, 7)
raised = 0
msg$ = ""
r = callfunc("control_left@", b@, true)
assert_eq(raised, 1, "the wildcard re-resolves by kind and refuses")
assert_true(instr(msg$, "no function control_left@:@?") > 0, "naming the kinds it could not match")
assert_eq(control_left(b@), 7, "and nothing was written")

test_case("bool/but the one door that takes a bool works through it")
raised = 0
gui_clearerror()
control_set@(b@, "Visible", false)
assert_eq(control_visible(b@), 0, "false first")
r@ = callfunc@("control_set@", b@, "Visible", true)
assert_eq(raised, 0, "the wildcard route did not raise")
assert_eq(control_visible(b@), 1, "and true arrived as True, not as the 0 it used to")

test_case("bool/a number through the same wildcard is unaffected")
rem callfunc@ and not callfunc: control_left@ answers a handle, and the
rem suffix on callfunc is the return kind it is asked for.
raised = 0
r2@ = callfunc@("control_left@", b@, 21)
assert_eq(raised, 0, "a number resolves through the wildcard")
assert_eq(control_left(b@), 21, "and lands")

rem =================================================================
rem PART 2 -- AN ARGUMENT THAT BECOMES AN ALLOCATION, AND THE THREE
rem WAYS THE FIRST VERSION OF THIS GUARD GOT ITS BOUNDS WRONG.
rem
rem   (a) it priced an image-list entry like a bitmap, 4 bytes a pixel
rem       instead of the 19-20 it measures at, so imagelist@(8192,
rem       8192) -- EXACTLY its own accepted maximum -- still committed
rem       1684 MB with exit 0 and gui_error 0, byte for byte what the
rem       unguarded build did;
rem   (b) it priced a grid by its CELL PRODUCT, but a row costs
rem       nineteen cells, so it refused a 100 x 21000 sheet costing
rem       21 MB and admitted a 1 x 2000000 column costing 305 MB;
rem   (c) it bounded each object on its own, which is not a bound on
rem       the host: ten bitmaps each inside the cap came to 2132 MB,
rem       eight image-list entries each inside it killed the process,
rem       and so did ten grids each at the accepted cell limit.
rem
rem So there is now one budget -- GuiMaxLiveBytes, 1 GB -- that every
rem surface is charged against and credited back on, and a measured
rem cost model per kind. Both ends are pinned here: the refusals AND
rem the sizes that must keep working, including the ones the earlier
rem bound refused by mistake.
rem
rem MOST OF THESE COST NO REAL MEMORY, on purpose. TBitmap.SetSize is
rem lazy, so a bitmap that is charged at construction and never drawn
rem on commits nothing -- which is exactly what makes it possible to
rem drive the ledger to its edge here without a suite that needs a
rem gigabyte. The cases that DO allocate are kept small.
rem =================================================================

rem --- the numbers this file is written against ---------------------
rem   budget            1073741824 bytes (1024.0 MB)
rem   a surface         6 bytes a pixel + 4 a row
rem   an image-list ENTRY  20 bytes a pixel, charged per entry
rem   a grid            150 bytes a row + 8 a cell
budget% = 1073741824

rem =================================================================
rem PART 2a -- a bitmap, and the exact edge of the budget
rem =================================================================

test_case("size/an ordinary bitmap is built and drawn on")
raised = 0
gui_clearerror()
bm@ = bitmap@(64, 48)
assert_eq(raised, 0, "64 x 48 did not raise")
assert_eq(bitmap_width(bm@), 64, "and has the width asked for")
assert_eq(bitmap_height(bm@), 48, "and the height")
canvas_brushcolor@(bm@, 255)
canvas_fillrect@(bm@, 0, 0, 64, 48)
assert_eq(bitmap_pixel(bm@, 1, 1), 255, "and paints")
x = control_free(bm@)

test_case("size/a bitmap AT the budget's own edge is accepted")
rem 13377 x 13377 costs 13377^2 * 6 + 13377 * 4 = 1073718282 bytes,
rem which is 23542 short of the budget. Creating it costs nothing --
rem TBitmap.SetSize is lazy -- which is precisely why the check cannot
rem wait for the first drawing call.
raised = 0
edge@ = bitmap@(13377, 13377)
assert_eq(raised, 0, "the last size that fits is not an error")
assert_eq(bitmap_width(edge@), 13377, "and the bitmap is the size asked for")
x = control_free(edge@)

test_case("size/one pixel wider is refused, and the message adds up")
raised = 0
msg$ = ""
over@ = bitmap@(13378, 13378)
assert_eq(raised, 1, "past the budget is a catchable error")
assert_eq(err(), 6, "a runtime error, which on error goto catches")
assert_true(instr(msg$, "bitmap 13378 x 13378 is too large") > 0, "the message names what was refused")
assert_true(instr(msg$, "1024.1 MB") > 0, "and what it would have cost")
assert_true(instr(msg$, "1024.0 MB") > 0, "and the budget it was measured against")

test_case("size/the case that cost 2.3 GB is refused")
raised = 0
msg$ = ""
bad@ = bitmap@(20000, 20000)
assert_eq(raised, 1, "20000 x 20000 is refused")
assert_true(instr(msg$, "2288.8 MB") > 0, "and the message prices it")

test_case("size/a size too big to price is DESCRIBED, never mis-printed")
rem 2^31-1 squared is 4.6e18; multiplying that by 6 leaves an Int64,
rem so the cost saturates. A saturated cost must not be printed --
rem the first version of this guard reported "8796093022207.9 MB",
rem a number no reader could check.
raised = 0
msg$ = ""
wide@ = bitmap@(2147483647, 2147483647)
assert_eq(raised, 1, "refused")
assert_true(instr(msg$, "past anything this host could hold") > 0, "described, not priced")
assert_true(instr(msg$, "8796093022207") = 0, "and the saturation never reaches the reader")

test_case("size/a negative bitmap is still the empty one it always was")
rem NOT an error: two negatives multiply to a large positive, and a
rem guard that missed that would turn today's harmless 0 x 0 bitmap
rem into a refusal. TBitmap clamps these itself -- measured.
raised = 0
gui_clearerror()
neg@ = bitmap@(-5, -5)
assert_eq(raised, 0, "a negative size did not become an error")
assert_eq(bitmap_width(neg@), 0, "and is the empty bitmap it was before")
raised = 0
neg2@ = bitmap@(-100000, -100000)
assert_eq(raised, 0, "and the product of two big negatives is not a size")

test_case("size/no pixels means no cost, however many rows are named")
rem The per-row term is real, but charging it ALONE would have refused
rem 8 GB for a bitmap the LCL allocates nothing for.
raised = 0
flat@ = bitmap@(0, 2000000000)
assert_eq(raised, 0, "a zero-width bitmap of two billion rows is free")
assert_eq(bitmap_width(flat@), 0, "and empty")
raised = 0
flat2@ = bitmap@(2000000000, 0)
assert_eq(raised, 0, "and the other way round")

rem =================================================================
rem PART 2b -- THE BOUND IS ON THE HOST, NOT ON EACH OBJECT.
rem This is the hole the per-object cap left: every one of these
rem passed its own cap, and together they were 2132 MB.
rem =================================================================

test_case("size/four bitmaps fit the budget and the fifth does not")
rem 6688^2 costs 268400416 bytes each; four is 1073601664, which is
rem 140160 short of the budget, and a fifth cannot fit whatever it is.
raised = 0
gui_clearerror()
p1@ = bitmap@(6688, 6688)
p2@ = bitmap@(6688, 6688)
p3@ = bitmap@(6688, 6688)
p4@ = bitmap@(6688, 6688)
assert_eq(raised, 0, "four of them are inside the budget")
msg$ = ""
p5@ = bitmap@(6688, 6688)
assert_eq(raised, 1, "the fifth is refused -- the host is the bound, not the bitmap")
assert_true(instr(msg$, "already in use") > 0, "and the message says what is holding it")
assert_true(instr(msg$, "1023.8 MB") > 0, "and how much")

test_case("size/freeing one makes room again -- the credit half")
rem A charge that is never credited is a slow false refusal, which is
rem worse than the leak it replaced. A TBitmap is not a TComponent and
rem cannot send FreeNotification, so this is the path that has to be
rem got right by hand.
raised = 0
gui_clearerror()
assert_eq(control_free(p4@), 1, "the fourth is freed")
p6@ = bitmap@(6688, 6688)
assert_eq(raised, 0, "and its bytes came back")
assert_eq(bitmap_width(p6@), 6688, "with a real bitmap in their place")
x = control_free(p1@)
x = control_free(p2@)
x = control_free(p3@)
x = control_free(p6@)

test_case("size/two hundred cycles at the edge, to prove nothing leaks")
rem One missing credit fails on the second pass. Lazy, so this costs
rem no memory at all -- it is the LEDGER being exercised, not the
rem allocator.
raised = 0
gui_clearerror()
n = 0
for i = 1 to 200
  c@ = bitmap@(13377, 13377)
  if bitmap_width(c@) = 13377 then n = n + 1
  x = control_free(c@)
next
assert_eq(raised, 0, "two hundred cycles at the budget's edge, none refused")
assert_eq(n, 200, "and every one of them was really made")

rem =================================================================
rem PART 2c -- an image list: 20 bytes a pixel, PER ENTRY
rem =================================================================

test_case("size/an ordinary image list takes a bitmap")
raised = 0
gui_clearerror()
il@ = imagelist@(16, 16)
assert_eq(raised, 0, "16 x 16 did not raise")
icon@ = bitmap@(16, 16)
assert_eq(imagelist_addbitmap(il@, icon@), 1, "and the bitmap went in")
assert_eq(imagelist_count(il@), 1, "and is counted")

test_case("size/the no-argument overload keeps its own default")
raised = 0
il2@ = imagelist@()
assert_eq(raised, 0, "imagelist@() did not raise")
assert_eq(imagelist_count(il2@), 0, "and is an empty list")

test_case("size/a list AT the edge of one entry is accepted")
rem 7327^2 * 20 = 1073698580, which is 43244 short of the budget.
raised = 0
ile@ = imagelist@(7327, 7327)
assert_eq(raised, 0, "a list whose single entry just fits is allowed")
x = control_free(ile@)

test_case("size/one pixel wider and no entry could ever fit, so it is refused")
raised = 0
msg$ = ""
ilo@ = imagelist@(7328, 7328)
assert_eq(raised, 1, "refused at the constructor, where the program wrote the numbers")
assert_true(instr(msg$, "image list 7328 x 7328 is too large") > 0, "and named")

test_case("size/the case the old guard ACCEPTED at 1684 MB is refused")
rem imagelist@(8192, 8192) was exactly the previous maximum. It is
rem 67108864 pixels, and an entry is 20 bytes of them, not 4.
raised = 0
msg$ = ""
il8@ = imagelist@(8192, 8192)
assert_eq(raised, 1, "8192 x 8192 is refused now")
assert_true(instr(msg$, "1280.0 MB") > 0, "priced at what an entry really costs")

test_case("size/the case that cost over 4 GB is refused, and says so")
raised = 0
msg$ = ""
ilbad@ = imagelist@(30000, 30000)
assert_eq(raised, 1, "30000 x 30000 is refused")
assert_true(instr(msg$, "image list 30000 x 30000") > 0, "and names the list")

test_case("size/a NEGATIVE list is priced by magnitude, not clamped to zero")
rem The one place the "a negative size is an empty thing" rule of the
rem bitmap is false. Measured on the unpatched build, imagelist@(-d,-d)
rem plus one entry follows the +d curve exactly: -4096 cost 280 MB,
rem -8192 cost 1281 MB, -16384 and -100000 killed the process. A guard
rem that clamped these to zero priced the whole family at nothing.
raised = 0
msg$ = ""
iln@ = imagelist@(-8192, -8192)
assert_eq(raised, 1, "a negative list of the same magnitude is refused too")
assert_true(instr(msg$, "1280.0 MB") > 0, "at the same price as the positive one")
raised = 0
gui_clearerror()
ils@ = imagelist@(-5, -5)
tiny@ = bitmap@(8, 8)
assert_eq(raised, 0, "and a SMALL negative list is still no error, as it always was")
assert_eq(imagelist_addbitmap(ils@, tiny@), 1, "and still takes an entry")

test_case("size/an entry is charged, and it is charged against the SAME budget")
rem The reviewer's finding was that a per-entry cap says nothing about
rem a list. Proved here without allocating a gigabyte: a lazily charged
rem bitmap takes almost all the budget, and the image list's FIRST
rem entry is then refused for want of the rest.
raised = 0
gui_clearerror()
pad@ = bitmap@(13000, 13000)
assert_eq(raised, 0, "967 MB of budget taken by a bitmap that costs no memory")
ilc@ = imagelist@(2048, 2048)
src@ = bitmap@(64, 64)
msg$ = ""
k = imagelist_addbitmap(ilc@, src@)
assert_eq(raised, 1, "the entry is refused: it is charged, and the budget is shared")
assert_true(instr(msg$, "image list entry 2048 x 2048") > 0, "named as an entry")
assert_eq(imagelist_count(ilc@), 0, "and nothing went into the list")

test_case("size/and freeing the bitmap lets the same entry in")
raised = 0
gui_clearerror()
assert_eq(control_free(pad@), 1, "the bitmap is freed")
k = imagelist_addbitmap(ilc@, src@)
assert_eq(raised, 0, "the entry is taken now")
assert_eq(k, 1, "as entry 1")
assert_eq(imagelist_count(ilc@), 1, "and counted")

test_case("size/clearing a list gives its entries' bytes back")
raised = 0
k = imagelist_addbitmap(ilc@, src@)
assert_eq(imagelist_count(ilc@), 2, "a second entry")
imagelist_clear@(ilc@)
assert_eq(imagelist_count(ilc@), 0, "cleared")
pad2@ = bitmap@(13000, 13000)
assert_eq(raised, 0, "and the 160 MB the two entries held is available again")
x = control_free(pad2@)
x = control_free(ilc@)

rem =================================================================
rem PART 2d -- a grid: 150 bytes a ROW and 8 a CELL, which is a
rem different SHAPE from the cell product, not just a different number
rem =================================================================

g@ = stringgrid@(f@)

test_case("size/an ordinary grid is built and filled")
raised = 0
gui_clearerror()
stringgrid_colcount@(g@, 4)
stringgrid_rowcount@(g@, 6)
assert_eq(raised, 0, "an ordinary grid did not raise")
assert_eq(stringgrid_colcount(g@), 4, "the columns")
assert_eq(stringgrid_rowcount(g@), 6, "the rows")
stringgrid_cell@(g@, 2, 3, "here")
assert_eq(stringgrid_cell$(g@, 2, 3), "here", "and a cell round-trips")

test_case("size/THE WIDE AND SHALLOW SHEET THE CELL PRODUCT REFUSED")
rem 100 columns x 21000 rows is 2.1 M cells and costs 21 MB measured.
rem The cell-product bound refused it while admitting a single-column
rem 2-million-row grid costing fourteen times as much. This is the
rem false refusal, and it is pinned first.
raised = 0
gui_clearerror()
wide@ = stringgrid@(f@)
stringgrid_colcount@(wide@, 100)
stringgrid_rowcount@(wide@, 21000)
assert_eq(raised, 0, "a 21000-row hundred-column sheet is not an error")
assert_eq(stringgrid_rowcount(wide@), 21000, "and the rows were made")
assert_eq(stringgrid_colcount(wide@), 100, "and the columns")
stringgrid_cell@(wide@, 100, 21000, "corner")
assert_eq(stringgrid_cell$(wide@, 100, 21000), "corner", "and the far corner holds a value")
stringgrid_rowcount@(wide@, 2)

test_case("size/and the other four shapes the cell product refused")
rem Every one of these is under 80 MB measured. All five were refused
rem by the previous bound; all five must pass.
raised = 0
gui_clearerror()
sh@ = stringgrid@(f@)
stringgrid_colcount@(sh@, 50)
stringgrid_rowcount@(sh@, 50000)
assert_eq(raised, 0, "50 x 50000")
stringgrid_rowcount@(sh@, 2)
stringgrid_colcount@(sh@, 20)
stringgrid_rowcount@(sh@, 150000)
assert_eq(raised, 0, "20 x 150000")
stringgrid_rowcount@(sh@, 2)
stringgrid_colcount@(sh@, 12)
stringgrid_rowcount@(sh@, 200000)
assert_eq(raised, 0, "12 x 200000")
stringgrid_rowcount@(sh@, 2)
stringgrid_colcount@(sh@, 8)
stringgrid_rowcount@(sh@, 300000)
assert_eq(raised, 0, "8 x 300000")
stringgrid_rowcount@(sh@, 2)
stringgrid_colcount@(sh@, 1)

test_case("size/the tall column is still allowed, and still priced")
rem 1 x 2000000 costs 316 MB by the model and 305 MB measured, so it
rem stays -- but it is now priced at that rather than at 134 MB.
raised = 0
lim@ = stringgrid@(f@)
stringgrid_colcount@(lim@, 1)
stringgrid_rowcount@(lim@, 2000000)
assert_eq(raised, 0, "two million rows in one column is allowed")
assert_eq(stringgrid_rowcount(lim@), 2000000, "and the rows were made")
stringgrid_rowcount@(lim@, 2)

test_case("size/but fifty columns of them is 1049 MB and is not")
raised = 0
msg$ = ""
stringgrid_colcount@(lim@, 50)
stringgrid_rowcount@(lim@, 2000000)
assert_eq(raised, 1, "50 x 2000000 is past the budget")
assert_true(instr(msg$, "1049.0 MB") > 0, "priced by rows AND cells")
assert_eq(stringgrid_rowcount(lim@), 2, "and the grid kept the rows it had")

test_case("size/the case that cost 2.5 GB is refused")
raised = 0
stringgrid_rowcount@(g@, 20000000)
assert_eq(raised, 1, "20000000 rows is refused")
assert_eq(stringgrid_rowcount(g@), 6, "and the grid is unchanged")
raised = 0
stringgrid_colcount@(g@, 20000000)
assert_eq(raised, 1, "and 20000000 columns too")
assert_eq(stringgrid_colcount(g@), 4, "with the grid unchanged")

test_case("size/High(Integer) rows is refused and the grid is unchanged")
raised = 0
msg$ = ""
stringgrid_rowcount@(g@, 2147483647)
assert_eq(raised, 1, "High(Integer) rows is refused")
assert_true(instr(msg$, "2147483647 rows") > 0, "and named")
assert_eq(stringgrid_rowcount(g@), 6, "and the grid is unchanged")

test_case("size/A COLUMN COSTS 296 BYTES OF ITS OWN, whatever the rows do")
rem This case was written to pin the opposite. An earlier draft of the
rem guard said in a comment that "with no rows there is no grid,
rem whatever the column count says" and priced columns at nothing --
rem and this test asserted it. Running it showed 672 MB for a five-row
rem grid of two million columns, identically on both builds, and the
rem sweep behind it put a column at 290-296 bytes from 250,000 up to
rem 2,500,000. Priced at zero, twenty million columns would have been
rem 6.7 GB straight through a guard just rewritten to stop that.
raised = 0
gui_clearerror()
e@ = stringgrid@(f@)
stringgrid_colcount@(e@, 100000)
assert_eq(raised, 0, "a hundred thousand columns is 34 MB and allowed")
assert_eq(stringgrid_colcount(e@), 100000, "and they were made")
raised = 0
msg$ = ""
stringgrid_colcount@(e@, 20000000)
assert_eq(raised, 1, "twenty million of them is past the budget and is not")
assert_true(instr(msg$, "20000000 columns") > 0, "the message names the columns")
assert_true(instr(msg$, "6408.6 MB") > 0, "and prices them, column term and all")
assert_eq(stringgrid_colcount(e@), 100000, "and the grid is unchanged")
stringgrid_colcount@(e@, 1)

test_case("size/the draw grid is the same two counts under another name")
dg@ = drawgrid@(f@)
raised = 0
drawgrid_rowcount@(dg@, 20000000)
assert_eq(raised, 1, "drawgrid rows refused")
raised = 0
drawgrid_colcount@(dg@, 20000000)
assert_eq(raised, 1, "drawgrid columns refused")
raised = 0
drawgrid_rowcount@(dg@, 8)
drawgrid_colcount@(dg@, 3)
assert_eq(raised, 0, "an ordinary draw grid is untouched")
assert_eq(drawgrid_rowcount(dg@), 8, "the rows")
assert_eq(drawgrid_colcount(dg@), 3, "the columns")

test_case("size/a count that CLEARS a grid is still not a size")
rem A negative count empties the grid -- documented, and it must not
rem become an error just because the guard sits in front of it.
raised = 0
gui_clearerror()
stringgrid_rowcount@(g@, -1)
assert_eq(raised, 0, "a negative row count is not a refusal")
assert_eq(stringgrid_rowcount(g@), 0, "it emptied the grid, as it always has")
stringgrid_rowcount@(g@, 6)
assert_eq(stringgrid_rowcount(g@), 6, "and the grid takes rows again after")

test_case("size/ten grids do not each get their own gigabyte")
rem The third failure the per-object cap left: ten grids, each at the
rem accepted cell limit, killed the process past 2200 MB. Driven here
rem against a lazily charged bitmap so it costs no memory.
raised = 0
gui_clearerror()
gpad@ = bitmap@(13000, 13000)
gm@ = stringgrid@(f@)
stringgrid_colcount@(gm@, 1)
msg$ = ""
stringgrid_rowcount@(gm@, 2000000)
assert_eq(raised, 1, "a 316 MB grid does not fit beside a 967 MB bitmap")
assert_eq(stringgrid_rowcount(gm@), 5, "and the grid is untouched")
raised = 0
x = control_free(gpad@)
stringgrid_rowcount@(gm@, 2000000)
assert_eq(raised, 0, "and fits once the bitmap is freed")
stringgrid_rowcount@(gm@, 2)

test_case("size/a grid is credited when its FORM dies -- the other half")
rem The credit path a bitmap cannot use. No handle owns a child grid:
rem the form owns the tree, so when the form is freed the grid dies
rem without the handle layer hearing anything about it. Only
rem FreeNotification can tell the ledger, and if it does not, a
rem long-running host loses that memory from its budget for good --
rem a false refusal that arrives an hour later.
raised = 0
gui_clearerror()
ff@ = form@("owner", 400, 300)
gg@ = stringgrid@(ff@)
stringgrid_colcount@(gg@, 1)
stringgrid_rowcount@(gg@, 2000000)
assert_eq(stringgrid_rowcount(gg@), 2000000, "a 316 MB grid inside its own form")
raised = 0
t1@ = bitmap@(13000, 13000)
assert_eq(raised, 1, "967 MB does not fit beside it")
raised = 0
gui_clearerror()
assert_eq(control_free(ff@), 1, "the FORM is freed, not the grid")
t2@ = bitmap@(13000, 13000)
assert_eq(raised, 0, "and the grid's bytes came back with it")
assert_eq(bitmap_width(t2@), 13000, "with a real bitmap in their place")
x = control_free(t2@)

rem =================================================================
rem PART 2e -- THE SIBLING PATH: the property bridge writes the same
rem two counts by name, and used to walk straight past the guard.
rem =================================================================

test_case("size/control_set@ reaches RowCount and is stopped there too")
raised = 0
msg$ = ""
control_set@(g@, "RowCount", 20000000)
assert_eq(raised, 1, "the bridge is gated as well")
assert_true(instr(msg$, "too large") > 0, "with the same message")
assert_eq(stringgrid_rowcount(g@), 6, "and the grid is unchanged")

test_case("size/and ColCount, and the draw grid through the bridge")
raised = 0
control_set@(g@, "ColCount", 20000000)
assert_eq(raised, 1, "ColCount too")
raised = 0
control_set@(dg@, "RowCount", 20000000)
assert_eq(raised, 1, "and a draw grid through the same door")

test_case("size/no spelling of the name walks past the gate")
rem The gate is handed the CANONICAL name out of the RTTI record, not
rem the string the program typed, so case cannot be used to miss it.
raised = 0
control_set@(g@, "rowcount", 20000000)
assert_eq(raised, 1, "lower case is the same property")
raised = 0
control_set@(g@, "ROWCOUNT", 20000000)
assert_eq(raised, 1, "and upper case")

test_case("size/an ordinary count through the bridge still works")
raised = 0
gui_clearerror()
control_set@(g@, "RowCount", 9)
assert_eq(raised, 0, "9 rows did not raise")
assert_eq(gui_error(), 0, "and was not refused")
assert_eq(stringgrid_rowcount(g@), 9, "and was applied")
control_set@(g@, "ColCount", 3)
assert_eq(stringgrid_colcount(g@), 3, "and the columns too")

test_case("size/the bridge CHARGES what it wrote, not what it was asked")
rem The gate runs before the write and the ledger is told after, so a
rem grid grown through the bridge is priced at what it became. Grow it
rem to 500000 rows by name, then check the budget really moved: a
rem 13000-square bitmap needs 967 MB and 75 MB is now spoken for.
raised = 0
gui_clearerror()
bg@ = stringgrid@(f@)
control_set@(bg@, "ColCount", 1)
control_set@(bg@, "RowCount", 500000)
assert_eq(stringgrid_rowcount(bg@), 500000, "the bridge grew it")
msg$ = ""
bpad@ = bitmap@(13300, 13300)
assert_eq(raised, 1, "and the 79 MB it took is charged against the budget")
raised = 0
control_set@(bg@, "RowCount", 2)
bpad2@ = bitmap@(13300, 13300)
assert_eq(raised, 0, "shrinking it through the bridge gives the bytes back")
x = control_free(bpad2@)

test_case("size/the gate does not touch a control that is not a grid")
rem Every OTHER ordinal property goes through the same call. A gate
rem that answered for all of them would have broken every setter in
rem the package, silently.
raised = 0
gui_clearerror()
control_set@(b@, "Left", 20000000)
assert_eq(raised, 0, "a button's Left is not a cell count")
assert_eq(control_left(b@), 20000000, "and was written")
lb@ = listbox@(f@)
list_add@(lb@, "alpha")
control_set@(lb@, "ItemIndex", 0)
assert_eq(raised, 0, "and a list box's ItemIndex is not either")

test_case("size/the LCL's own extent ceiling still answers the old way")
rem GuiExtentOk records gui_error 1 and does not raise; the new size
rem guards raise and do not record. Both are pinned so neither gets
rem quietly converted into the other.
raised = 0
control_size@(b@, 40, 20)
gui_clearerror()
control_width@(b@, 1000000)
assert_eq(raised, 0, "a million pixels wide is still not an error value")
assert_eq(gui_error(), 1, "it is still gui_error 1")
assert_eq(control_width(b@), 40, "and the control kept its width")

test_case("size/and through the BRIDGE, which is where it was only claimed")
rem The round-one report cited 18_faults as covering Width and Height
rem through control_set@. It does not -- it pins ItemIndex, Name,
rem Alignment and Anchors. The claim was true; the citation was not.
rem So it is pinned here, where it is actually checked.
raised = 0
gui_clearerror()
control_set@(b@, "Width", 2000000000)
assert_eq(raised, 0, "the LCL's extent trap does not escape")
assert_eq(gui_error(), 1, "it is recorded as gui_error 1")
assert_eq(control_width(b@), 40, "and the control kept its width")
raised = 0
gui_clearerror()
control_set@(b@, "Height", 2000000000)
assert_eq(gui_error(), 1, "and Height the same way")
assert_eq(control_height(b@), 20, "with the height unchanged")

rem =================================================================
rem PART 2f -- A SIZE THAT ARRIVES IN A FILE. image_load@ and
rem imagelist_addfile take no dimensions at all, so every guard above
rem is blind to them. Measured on the unpatched build: a FIFTY-FOUR
rem BYTE .bmp whose header claims 30000 x 30000 took the host past
rem 2.4 GB and had to be killed, with gui_error 0 and nothing raised;
rem imagelist_addfile of a real 50 MB 1-bit .bmp committed 1731 MB
rem into a 32 x 32 icon list. The bomb is BUILT HERE rather than
rem checked in, so the file that proves it is the file you can read.
rem =================================================================

rem Built under the SANDBOX ROOT rather than under a relative "bin/",
rem so the file half of this suite does not quietly depend on which
rem directory the runner happened to be started from: the root is what
rem the sandbox will admit, whatever that directory is.
scratch$ = path_combine$(sandboxroot$(), "bin")
made = dir_create(scratch$)
bomb$ = path_combine$(scratch$, "19_bomb.bmp")
okbmp$ = path_combine$(scratch$, "19_ok.bmp")

rem A 54-byte BITMAPFILEHEADER + BITMAPINFOHEADER and not one byte of
rem pixel data, declaring 30000 x 30000.
hb@ = buffer_new@(54)
x = buffer_set(hb@, 1, 66)
x = buffer_set(hb@, 2, 77)
x = buffer_setint(hb@, 3, 4, 54, false)
x = buffer_setint(hb@, 11, 4, 54, false)
x = buffer_setint(hb@, 15, 4, 40, false)
x = buffer_setint(hb@, 19, 4, 30000, false)
x = buffer_setint(hb@, 23, 4, 30000, false)
x = buffer_setint(hb@, 27, 2, 1, false)
x = buffer_setint(hb@, 29, 2, 24, false)
wrote = file_writeallbytes(bomb$, hb@)

rem And an ordinary 2 x 2 24-bit bitmap, 70 bytes, so the legitimate
rem side of the same door is pinned beside the refusal.
ok@ = buffer_new@(70)
x = buffer_set(ok@, 1, 66)
x = buffer_set(ok@, 2, 77)
x = buffer_setint(ok@, 3, 4, 70, false)
x = buffer_setint(ok@, 11, 4, 54, false)
x = buffer_setint(ok@, 15, 4, 40, false)
x = buffer_setint(ok@, 19, 4, 2, false)
x = buffer_setint(ok@, 23, 4, 2, false)
x = buffer_setint(ok@, 27, 2, 1, false)
x = buffer_setint(ok@, 29, 2, 24, false)
x = buffer_setint(ok@, 35, 4, 16, false)
wroteok = file_writeallbytes(okbmp$, ok@)

test_case("file/the fixtures were written where the sandbox can see them")
assert_eq(wrote, 1, "the 54-byte bomb was written")
assert_eq(wroteok, 1, "and the ordinary 2 x 2 bitmap")

test_case("file/an ordinary picture still loads, and reports its size")
raised = 0
gui_clearerror()
im@ = image@(f@)
image_load@(im@, okbmp$)
assert_eq(raised, 0, "a 2 x 2 bitmap did not raise")
assert_eq(gui_error(), 0, "and was not refused")
assert_eq(image_picwidth(im@), 2, "the width it declares")
assert_eq(image_picheight(im@), 2, "and the height")
assert_eq(image_empty(im@), 0, "and the image is no longer empty")

test_case("file/the 54-byte bomb is refused before anything is decoded")
raised = 0
msg$ = ""
im2@ = image@(f@)
image_load@(im2@, bomb$)
assert_eq(raised, 1, "a header that claims 900 million pixels is a catchable error")
assert_true(instr(msg$, "picture is too large") > 0, "named as a picture")
assert_true(instr(msg$, "19_bomb.bmp") > 0, "and the file is named")
assert_true(instr(msg$, "30000 x 30000") > 0, "and the size it CLAIMED")
assert_eq(image_empty(im2@), 1, "and nothing was loaded")

test_case("file/imagelist_addfile is the same door and the same answer")
raised = 0
msg$ = ""
ilf@ = imagelist@(32, 32)
k = imagelist_addfile(ilf@, bomb$)
assert_eq(raised, 1, "the image list's file door is bounded too")
assert_true(instr(msg$, "image list entry is too large") > 0, "named as an entry")
assert_eq(imagelist_count(ilf@), 0, "and nothing went in")
raised = 0
gui_clearerror()
k = imagelist_addfile(ilf@, okbmp$)
assert_eq(raised, 0, "while an ordinary file still goes in")
assert_eq(k, 1, "as entry 1")

test_case("file/a missing file is still gui_error, not a size refusal")
rem The two answers must stay apart: one is "no such file", the other
rem is "that file is too big to load".
raised = 0
gui_clearerror()
image_load@(im@, path_combine$(scratch$, "19_does_not_exist.bmp"))
assert_eq(raised, 0, "a missing file does not raise")
assert_true(gui_error() <> 0, "it is recorded, as it always was")

x = file_delete(bomb$)
x = file_delete(okbmp$)

end

trapped:
rem Anything that RAISES lands here. The message is captured before
rem `resume next` carries on, so a case can assert what it said.
raised = 1
msg$ = errmsg$()
resume next
