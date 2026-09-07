rem ---------------------------------------------------------------
rem A SIZE THAT ARRIVES IN A FILE, PINNED ON EVERY AXIS THE FIRST
rem VERSION OF THAT DOOR WAS BLIND TO.
rem
rem 19_argord_and_size pins that a 54-byte .bmp claiming 30000 x
rem 30000 is refused. It pins that with ONE fixture, at ONE bit
rem depth, ONE call at a time -- and each of the three things that
rem door got wrong was invisible from there:
rem
rem  1. IT PRICED EVERY FORMAT AT A 32-BIT SURFACE'S 6 BYTES A
rem     PIXEL. An 8-bit greyscale PNG really costs 1 byte a pixel
rem     and a 1-bit .bmp 0.375, so everything low-depth was refused
rem     from 13377 square upward -- including a real 40000-square
rem     1-bit .bmp that loads in 587 MB, well inside the 1024 MB
rem     this host allows. Refusing that was the defect, not the
rem     load. The depth is in the header, two bytes along from the
rem     dimensions this door already read.
rem
rem  2. IT ASKED THE BUDGET, NOT THE LEDGER. "Could this file ever
rem     fit here" is not "does it fit here NOW", so any number of
rem     pictures that each fit could be loaded at once: eight loads
rem     of one 560 KB file reached 4416 MB with gui_error 0.
rem
rem  3. IT CHARGED AFTER THE LOAD AND THREW THE ANSWER AWAY, so the
rem     ledger recorded only the first picture ever loaded and the
rem     charge could not refuse anything even in principle.
rem
rem Every case below is a PAIR: the thing that must be refused and
rem the neighbouring thing that must not be, because a guard that
rem refuses an ordinary picture is worse than the leak it replaced.
rem The pairs differ in ONE header field at a time.
rem
rem THE FIXTURES ARE BUILT HERE rather than checked in, so the file
rem that proves each claim is the file you can read. They are
rem HEADERS ONLY -- no pixel data -- which is exactly the shape of
rem the bomb: what this door decides, it decides from the header,
rem and it decides it before anything is allocated.
rem
rem Written like 18_faults and 19: `on error goto` records into
rem `raised` and `resume next` carries on, so a returning bug FAILS
rem rather than aborting the runner.
rem ---------------------------------------------------------------

raised = 0
msg$ = ""

on error goto trapped

scratch$ = path_combine$(sandboxroot$(), "bin")
made = dir_create(scratch$)
f@ = form@("h", 300, 200)

rem The PNG signature and an IHDR: width, height, BIT DEPTH (byte
rem 25) and COLOUR TYPE (byte 26), 1-based, big-endian stated rather
rem than assumed. Colour type 0 is greyscale, 2 rgb, 3 PALETTE, 4
rem grey+alpha, 6 rgba. Twenty-six bytes and no IDAT, so nothing
rem here can decode: what is being measured is the DOOR.
function writepng(path$, w, h, depth, colour) local b@, x
  b@ = buffer_new@(26)
  x = buffer_set(b@, 1, 137)
  x = buffer_set(b@, 2, 80)
  x = buffer_set(b@, 3, 78)
  x = buffer_set(b@, 4, 71)
  x = buffer_set(b@, 5, 13)
  x = buffer_set(b@, 6, 10)
  x = buffer_set(b@, 7, 26)
  x = buffer_set(b@, 8, 10)
  x = buffer_setint(b@, 9, 4, 13, true)
  x = buffer_set(b@, 13, 73)
  x = buffer_set(b@, 14, 72)
  x = buffer_set(b@, 15, 68)
  x = buffer_set(b@, 16, 82)
  x = buffer_setint(b@, 17, 4, w, true)
  x = buffer_setint(b@, 21, 4, h, true)
  x = buffer_set(b@, 25, depth)
  x = buffer_set(b@, 26, colour)
  return file_writeallbytes(path$, b@)
endfunction

rem A BITMAPFILEHEADER + BITMAPINFOHEADER and not one byte of pixel
rem data. biBitCount is the two bytes at offset 29, which is the
rem field the first version of this door never read.
function writebmp(path$, w, h, bits) local b@, x
  b@ = buffer_new@(54)
  x = buffer_set(b@, 1, 66)
  x = buffer_set(b@, 2, 77)
  x = buffer_setint(b@, 3, 4, 54, false)
  x = buffer_setint(b@, 11, 4, 54, false)
  x = buffer_setint(b@, 15, 4, 40, false)
  x = buffer_setint(b@, 19, 4, w, false)
  x = buffer_setint(b@, 23, 4, h, false)
  x = buffer_setint(b@, 27, 2, 1, false)
  x = buffer_setint(b@, 29, 2, bits, false)
  return file_writeallbytes(path$, b@)
endfunction

rem Load PATH into a fresh image and answer 1 when the door RAISED.
rem The image is freed on the way out so the ledger goes back to
rem where it was: every case here starts from the same state, and a
rem case that quietly left 200 MB behind would move the next one's
rem answer without saying so.
function refused(path$) local im@, r
  raised = 0
  gui_clearerror()
  im@ = image@(f@)
  image_load@(im@, path$)
  r = raised
  x = control_free(im@)
  return r
endfunction

rem =================================================================
rem PART 1 -- THE BIT DEPTH DECIDES, read from the header. One
rem greyscale PNG at 30000 square, three depths: 1 bit is 107 MB and
rem 8 bits is 900 MB, both inside the budget; 16 bits is 1800 MB and
rem is not. Under the old flat 6 bytes a pixel ALL THREE were priced
rem at 5400 MB and all three were refused.
rem =================================================================
g1$ = path_combine$(scratch$, "20_30000_g1.png")
g8$ = path_combine$(scratch$, "20_30000_g8.png")
g16$ = path_combine$(scratch$, "20_30000_g16.png")
w1 = writepng(g1$, 30000, 30000, 1, 0)
w8 = writepng(g8$, 30000, 30000, 8, 0)
w16 = writepng(g16$, 30000, 30000, 16, 0)

test_case("depth/three fixtures that differ in one byte")
assert_eq(w1, 1, "the 1-bit header was written")
assert_eq(w8, 1, "the 8-bit one")
assert_eq(w16, 1, "and the 16-bit one")
assert_eq(file_getsize(g1$), 26, "each is twenty-six bytes")
assert_eq(file_getsize(g16$), 26, "the same twenty-six bytes")

test_case("depth/1-bit at 30000 square is admitted")
assert_eq(refused(g1$), 0, "107 MB of grey is not a size refusal")

test_case("depth/8-bit at 30000 square is admitted")
rem This is the case the round-two review measured: a real one of
rem these loads in 874 MB, and the old door refused it.
assert_eq(refused(g8$), 0, "900 MB is inside the 1024 MB budget")

test_case("depth/16-bit at the same size is refused, and named")
raised = 0
msg$ = ""
gui_clearerror()
im16@ = image@(f@)
image_load@(im16@, g16$)
assert_eq(raised, 1, "1800 MB of 16-bit grey is a catchable error")
assert_true(instr(msg$, "picture is too large") > 0, "named as a picture")
assert_true(instr(msg$, "30000 x 30000") > 0, "with the size it claimed")
assert_true(instr(msg$, "20_30000_g16.png") > 0, "and the file")
assert_eq(image_empty(im16@), 1, "and nothing was loaded")
x = control_free(im16@)

rem =================================================================
rem PART 2 -- AND THE COLOUR TYPE DECIDES WITH IT. This is the half
rem that "read the bit depth" gets wrong on its own: a PNG PALETTE is
rem expanded to a 32-bit surface whatever depth it declares, measured
rem at 30.6 bits a pixel for 1-, 4- and 8-bit palettes alike. Two
rem files, same 20000 square, same declared bit depth, one byte
rem apart -- greyscale costs 400 MB, palette costs 1600 MB. Reading
rem only the depth would have under-charged the second one fourfold.
rem =================================================================
pg$ = path_combine$(scratch$, "20_20000_grey8.png")
pp$ = path_combine$(scratch$, "20_20000_pal8.png")
wg = writepng(pg$, 20000, 20000, 8, 0)
wp = writepng(pp$, 20000, 20000, 8, 3)

test_case("colour/the pair differs only in the colour type byte")
assert_eq(wg, 1, "the greyscale header was written")
assert_eq(wp, 1, "and the palette one")
assert_eq(file_getsize(pg$), file_getsize(pp$), "both are the same length")

test_case("colour/8-bit GREYSCALE at 20000 square is admitted")
assert_eq(refused(pg$), 0, "400 MB of grey is not a size refusal")

test_case("colour/8-bit PALETTE at 20000 square is refused")
raised = 0
msg$ = ""
gui_clearerror()
imp@ = image@(f@)
image_load@(imp@, pp$)
assert_eq(raised, 1, "a palette becomes a 32-bit surface, and 1600 MB of one is refused")
assert_true(instr(msg$, "20000 x 20000") > 0, "with the size it claimed")
x = control_free(imp@)

rem =================================================================
rem PART 3 -- A .BMP CARRIES ITS DEPTH IN biBitCount, and the same
rem rule reads it there. Two 54-byte headers, same 4000 square, one
rem field apart. They are priced against what is LIVE, so a bitmap
rem holding 1012 MB of the budget is what makes the difference
rem visible at a size small enough to cost nothing: 4 MB of 1-bit
rem still fits beside it, 46 MB of 24-bit does not.
rem =================================================================
b1$ = path_combine$(scratch$, "20_4000_1bit.bmp")
b24$ = path_combine$(scratch$, "20_4000_24bit.bmp")
wb1 = writebmp(b1$, 4000, 4000, 1)
wb24 = writebmp(b24$, 4000, 4000, 24)

test_case("bmp/both headers were written, and are the same length")
assert_eq(wb1, 1, "the 1-bit header")
assert_eq(wb24, 1, "and the 24-bit one")
assert_eq(file_getsize(b1$), 54, "fifty-four bytes each")
assert_eq(file_getsize(b24$), 54, "the same fifty-four")

test_case("bmp/with nothing live, both sizes are admitted")
assert_eq(refused(b1$), 0, "4 MB is nothing")
assert_eq(refused(b24$), 0, "and neither is 46 MB")

test_case("bmp/behind a 1012 MB bitmap the two answers separate")
raised = 0
hold@ = bitmap@(13300, 13300)
assert_eq(raised, 0, "a 13300-square bitmap is itself allowed")
assert_eq(bitmap_width(hold@), 13300, "and really made")
assert_eq(refused(b1$), 0, "1 bit a pixel still fits in what is left")
assert_eq(refused(b24$), 1, "24 bits a pixel does not")

test_case("bmp/and the message says what is holding the room")
raised = 0
msg$ = ""
gui_clearerror()
imb@ = image@(f@)
image_load@(imb@, b24$)
assert_eq(raised, 1, "still refused")
assert_true(instr(msg$, "already in use") > 0, "the live total is in the message")
assert_true(instr(msg$, "20_4000_24bit.bmp") > 0, "and so is the file")
x = control_free(imb@)

test_case("bmp/freeing the bitmap admits it again")
rem The credit half. A ledger that refuses on what it has forgotten
rem to give back is a slow false refusal, which is the failure this
rem whole door is trying not to become.
x = control_free(hold@)
assert_eq(refused(b24$), 0, "the room came back with the bitmap")

rem =================================================================
rem PART 4 -- THE IMAGE LIST'S DOOR IS THE SAME PRICE PLUS ONE MORE
rem COPY. imagelist_addfile decodes the file at full size and then
rem copies it into a TBitmap before the list scales it into a 32 x 32
rem slot; the first version priced the SLOT -- 20 KB -- and let
rem 2060 MB through with exit 0 and both assertions passing. So a
rem file the picture door admits can be too big for the list door,
rem and that asymmetry is the point.
rem =================================================================
il1$ = path_combine$(scratch$, "20_14000_g1.png")
wi = writepng(il1$, 14000, 14000, 1, 0)

test_case("list/image_load@ admits a 14000-square 1-bit header")
assert_eq(wi, 1, "the fixture was written")
assert_eq(refused(il1$), 0, "24 MB of decode is not a size refusal")

test_case("list/imagelist_addfile refuses the very same file")
raised = 0
msg$ = ""
gui_clearerror()
il@ = imagelist@(32, 32)
k = imagelist_addfile(il@, il1$)
assert_eq(raised, 1, "the decode plus its copy is 1200 MB, and that is refused")
assert_true(instr(msg$, "image list entry is too large") > 0, "named as an entry")
assert_true(instr(msg$, "14000 x 14000") > 0, "with the size it claimed")
assert_eq(k, 0, "no index came back")
assert_eq(imagelist_count(il@), 0, "and nothing went in")

rem =================================================================
rem PART 5 -- AND EVERY RESERVATION IS GIVEN BACK. The charge is now
rem made BEFORE the load, which means every path out of the load has
rem to return it: the one that decoded, the one that failed in the
rem decoder, and the one that was refused at the door. A reservation
rem kept on any of them is a slow false refusal, so each path is
rem driven far enough that a single leak would close the budget.
rem =================================================================
r$ = path_combine$(scratch$, "20_16000_g8.png")
wr = writepng(r$, 16000, 16000, 8, 0)

test_case("credit/thirty loads that reserve 244 MB and fail to decode")
rem Five kept reservations would be 1220 MB and the sixth load would
rem be refused instead of merely failing.
assert_eq(wr, 1, "the fixture was written")
raised = 0
gui_clearerror()
imr@ = image@(f@)
n = 0
for i = 1 to 30
  image_load@(imr@, r$)
  if raised = 0 then n = n + 1
next
assert_eq(n, 30, "not one of the thirty turned into a size refusal")
assert_true(gui_error() <> 0, "every one of them failed in the decoder, as intended")
x = control_free(imr@)

test_case("credit/and a 1012 MB bitmap still fits after them")
raised = 0
after@ = bitmap@(13300, 13300)
assert_eq(raised, 0, "the budget is where it started")
assert_eq(bitmap_width(after@), 13300, "and the bitmap is really there")
x = control_free(after@)

test_case("credit/a hundred REFUSED list adds leave nothing behind")
raised = 0
gui_clearerror()
ilr@ = imagelist@(32, 32)
refusals = 0
for i = 1 to 100
  raised = 0
  z = imagelist_addfile(ilr@, il1$)
  refusals = refusals + raised
next
assert_eq(refusals, 100, "every one of them was refused")

rem An ordinary 2 x 2 bitmap, 70 bytes, so the legitimate side of the
rem same door is driven a hundred times beside the refused one.
ok$ = path_combine$(scratch$, "20_ok.bmp")
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
wok = file_writeallbytes(ok$, ok@)

test_case("credit/a hundred adds that really land, after those")
assert_eq(wok, 1, "the 2 x 2 fixture was written")
raised = 0
gui_clearerror()
n = 0
for i = 1 to 100
  n = imagelist_addfile(ilr@, ok$)
next
assert_eq(raised, 0, "none of the hundred was refused")
assert_eq(n, 100, "and the hundredth took index 100")
assert_eq(imagelist_count(ilr@), 100, "the list holds exactly them")

test_case("credit/a hundred ordinary picture loads, and the size after")
raised = 0
gui_clearerror()
imo@ = image@(f@)
for i = 1 to 100
  image_load@(imo@, ok$)
next
assert_eq(raised, 0, "loading the same small picture a hundred times is free")
assert_eq(image_picwidth(imo@), 2, "and it is really loaded")
assert_eq(image_empty(imo@), 0, "and not empty")
x = control_free(imo@)

test_case("credit/a missing file is still gui_error, not a size refusal")
rem The two answers must stay apart, and no reservation may be made
rem for a file that was never opened.
raised = 0
gui_clearerror()
imm@ = image@(f@)
image_load@(imm@, path_combine$(scratch$, "20_does_not_exist.png"))
assert_eq(raised, 0, "a missing file does not raise")
assert_true(gui_error() <> 0, "it is recorded, as it always was")

x = file_delete(g1$)
x = file_delete(g8$)
x = file_delete(g16$)
x = file_delete(pg$)
x = file_delete(pp$)
x = file_delete(b1$)
x = file_delete(b24$)
x = file_delete(il1$)
x = file_delete(r$)
x = file_delete(ok$)

end

trapped:
rem Anything that RAISES lands here. The message is captured before
rem `resume next` carries on, so a case can assert what it said.
raised = 1
msg$ = errmsg$()
resume next
