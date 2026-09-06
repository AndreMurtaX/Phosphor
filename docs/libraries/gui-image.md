# gui-image — a picture on a form, and a shared strip of icons

`host/gui/libs/PhosphorImageLib.pas` · 17 functions · GUI hosts (the `phosphor`
binary and the headless `phosphorguitest` runner register it; an embedding host
has these names only if it calls `RegisterImageFuncs`)

## What it is for

Two different jobs live in this package because both are about pictures. The
first is the **image control**: a box on a form that displays one picture, loaded
from a file or handed a bitmap. The second is the **image list**: a strip of
same-sized icons that a toolbar, a tree view or a list view indexes into, which is
not a control at all — nothing shows it, other controls just point at it.

The unit header states the division of labour: *geometry and visibility come from
`PhosphorControlLib`; this adds loading and the picture's own size.* An image is
positioned with `control_bounds@`, `control_move@`, `control_size@` and hidden with
`control_visible@`, exactly like a button. What is specific to an image is the
three display flags that decide how the picture fills that box, the picture's own
pixel size (which is *not* the control's size), and whether there is a picture at
all.

The design stance is the phase-1 GUI contract, and the header says it in one line:
**a load failure is recorded in `gui_error()`, never raised.** A missing file, a
file that is present but not decodable as a picture, a handle that is not an image,
a control that cannot take an image list — none of these raise anything into BASIC.
They are answered. `image_load@` therefore always gives back the handle you passed
it, so calls chain left to right; "did it work" is a separate question, asked of
`gui_error()`. For the same reason `imagelist_addfile` and `imagelist_addbitmap`
answer **the base-1 index the picture took**, not a success flag — a mutator
answers information, and `0` is the index no picture ever has.

One thing that would otherwise surprise a caller: the two loaders record *different*
codes. `image_load@` uses the reference's picture codes — `6` for a file that is not
there, `7` for one that is there and will not decode — while `imagelist_addfile`
records the generic bad-input code `1`, the same one a stale handle gives. If you
need to tell a missing icon file from a dead list handle, call `gui_clearerror()`
first and check the count.

## Functions

### The image control

| function | what it answers |
| --- | --- |
| `image@(parent@) → handle` | a new image control inside `parent@`, sized and placed by the control backbone afterwards. Handle `0` when `parent@` is not a live window control, with `gui_error()` at `1` |
| `image_load@(img@, path$) → handle` | loads the picture at `path$`. Answers `img@` **always** — even when nothing loaded — so the outcome is read from `gui_error()`: `6` no such file, `7` a file that is present but not decodable. A missing file is detected before the picture is touched, so the image keeps whatever it was showing |
| `image_stretch@(img@, on) → handle` | scale the picture to fill the control's box. Answers `img@` so calls chain; a handle that is not an image changes nothing and records `1` |
| `image_stretch(img@) → num` | `1` when stretching is on, `0` when it is off — and `0` for a handle that is not an image, which reads the same as a genuine "off" |
| `image_center@(img@, on) → handle` | center the picture in the box instead of pinning it to the top-left. Same answer and same silence on a bad handle |
| `image_center(img@) → num` | `1` when centering is on; `0` off, and `0` for a non-image handle |
| `image_proportional@(img@, on) → handle` | keep the picture's aspect ratio while stretching. On its own it does nothing visible — it is the modifier `image_stretch@` obeys |
| `image_proportional(img@) → num` | `1` when proportional scaling is on; `0` off, and `0` for a non-image handle |
| `image_picwidth(img@) → num` | the **picture's** own width in pixels, not the control's — `control_width` answers the box. `0` when nothing is loaded, and `0` for a handle that is not an image |
| `image_picheight(img@) → num` | the picture's own height in pixels, `0` in the same two cases |
| `image_empty(img@) → num` | `1` when the control is holding no picture. A handle that is not an image at all also answers `1` — empty is the safe answer, so this is the question to ask after a load without having to trust the handle first |

`on` is a number here, not a `?` bool: `0` is off and anything non-zero is on.

### The image list

| function | what it answers |
| --- | --- |
| `imagelist@() → handle` | a new, empty image list at the widgetset's default cell size |
| `imagelist@(w, h) → handle` | the same, with every cell `w` × `h` pixels — the size each icon is drawn at, whatever size the file was |
| `imagelist_count(il@) → num` | how many pictures the list holds. `0` for an empty list and `0` for a handle that is not a list, with `gui_error()` at `1` for the second |
| `imagelist_clear@(il@) → handle` | drops every picture and answers the list handle. Controls already attached keep pointing at the list, which is now empty — attaching is not undone by clearing |
| `imagelist_addfile(il@, path$) → num` | the **base-1 index** the picture took, which is also the new count. `0` when the file is missing *or* is not a decodable picture, with `gui_error()` at `1` and nothing added |
| `imagelist_addbitmap(il@, bm@) → num` | the same index, from an existing `bitmap@` rather than a file. The list takes a copy, so the bitmap can be freed afterwards. `0` if either handle fails to resolve — a list that is not a list, or a handle that is not a bitmap |
| `imagelist_attach@(il@, ctl@) → handle` | points `ctl@` at the list and answers **the list handle**, not the control. Only three controls have such a property: `toolbar@`, `treeview@`, and `listview@` (which receives it as its *small* images). Anything else — a button, a form — changes nothing and records `1` |

## A worked example

A picture viewer that cannot fail: when the file is missing or is not a picture, it
draws a placeholder instead of stopping. It also builds a one-icon strip and hands
it to a toolbar.

```basic
rem   phosphor run viewer.bas

f@ = form@("Viewer", 480, 400)

pic@ = image@(f@)
control_bounds@(pic@, 20, 20, 440, 300)
image_stretch@(pic@, 1)            rem fill the box ...
image_proportional@(pic@, 1)       rem ... without distorting the picture
image_center@(pic@, 1)

gui_clearerror()
image_load@(pic@, "logo.png")
if image_empty(pic@) = 1 then
  println "no picture (gui_error " + str$(gui_error()) + ") -- drawing one"
  ok = placeholder(pic@, 440, 300)
else
  println "logo.png is " + str$(image_picwidth(pic@)) + " x " + str$(image_picheight(pic@))
endif

rem One strip of 16x16 icons, shared by the toolbar.
icons@ = imagelist@(16, 16)
green@ = bitmap@(16, 16)
canvas_brushcolor@(green@, 65280)
canvas_fillrect@(green@, 0, 0, 16, 16)
slot = imagelist_addbitmap(icons@, green@)
println "the swatch took index " + str$(slot) + " of " + str$(imagelist_count(icons@))

tb@ = toolbar@(f@)
imagelist_attach@(icons@, tb@)

form_show(f@)
app_run()

function placeholder(img@, w, h) local bm@
  bm@ = bitmap@(w, h)
  canvas_brushcolor@(bm@, 15790320)
  canvas_fillrect@(bm@, 0, 0, w, h)
  canvas_pencolor@(bm@, 0)
  canvas_textout@(bm@, 20, h / 2, "picture not available")
  image_setbitmap@(img@, bm@)
  return 1
endfunction
```

Two things worth noticing:

- **The program never asks "did the load succeed?" directly.** It asks
  `image_empty`, which answers usefully whether the file was missing, undecodable,
  or the handle was junk. `gui_error()` is then only for *reporting* which of those
  it was — and `gui_clearerror()` before the load is what makes that code
  trustworthy, since the slot is shared by the whole GUI surface and stays set until
  something clears it.
- **`imagelist_addbitmap` answers `1`, not "ok".** The index is what the toolbar
  button will later be told to draw, so the useful answer and the success answer are
  the same value — which is why there is no separate flag.

## Notes / Where the rest lives

**Sizing.** `image_picwidth` / `image_picheight` and `control_width` /
`control_height` are different questions with the same units. The flags are how you
reconcile them: `image_stretch@` alone distorts, `image_stretch@` plus
`image_proportional@` fits, `image_center@` places what is left over.

**Drawing** is not here. `bitmap@`, the `canvas_*` primitives and
`image_setbitmap@` — the way to put something *drawn* into an image control rather
than something *loaded* — live in the canvas package, `gui-canvas.md`. Asking the
user for a filename is a dialog: `openpicture$` and `savepicture$`, in
`gui-dialog.md`.

**Lifetime of a list.** An image list is registered as an **owning** handle, unlike
a child control, whose parent form owns it. That means `control_free` on the list
really frees it, while the toolbar or tree view attached to it is still pointing at
it. Free the list last, after the controls that use it — the ordinary rule for any
shared resource.
