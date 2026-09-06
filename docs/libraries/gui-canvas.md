# gui-canvas — immediate-mode drawing, and the shape control

`host/gui/libs/PhosphorCanvasLib.pas` · 34 functions · GUI package: registered
whenever the host can bring a widgetset up (always on Windows; on Unix when
`DISPLAY` or `WAYLAND_DISPLAY` is set)

## What it is for

This is the **LCL-native answer to the reference's FMX shapes and path**. The
reference drew into a retained scene graph — objects you create, keep and let the
framework re-render. Phosphor draws **immediately**: you ask a surface for a line
and the line is in the pixels, right there, with nothing kept and nothing to
re-render. What you get back is not an object to hold; it is paint.

The surface is the interesting part. `bitmap@(w, h)` is an **off-screen** drawing
surface — it needs no window, no form, not even a visible session on Windows, which
is why the whole library is provable headlessly: a test draws a rectangle and reads
`bitmap_pixel` back to show the paint landed. But every `canvas_*` call takes **any
handle that has a canvas**, not just a bitmap: an off-screen `bitmap@`, a live
`paintbox@`, or any control that paints itself — a `drawgrid@` handed to its own
draw handler, a `stringgrid@`. One resolver, three kinds of target, the identical
calls for all of them. The drawing primitives used to resolve a bitmap and nothing
else, which is exactly why `paintbox@` could not exist before.

The design stance is the project's usual one, applied to a mutator: **a drawing
call answers the surface it drew on, not a success flag.** `canvas_lineto@` hands
you back the same handle, so calls read left to right and a statement is never a
boolean you have to test. Failure is a *value in a different place*: a fabricated,
freed or wrong-class handle, or a malformed point list, records `1` in the shared
GUI error slot and **draws nothing** — read it with `gui_error()`, clear it with
`gui_clearerror()`. The readers (`bitmap_width`, `bitmap_pixel`, `canvas_textwidth`,
the `shape_*` getters) answer `0` when they cannot answer properly, and `0` is also
a perfectly good width, colour and shape kind — so when the difference matters, ask
`gui_error()`, not the value.

Two things a caller would otherwise trip on. **Colours are plain TColor numbers**
(`$00BBGGRR`, blue in the high byte): `0` black, `255` red, `65280` green,
`65535` yellow, `16711680` blue, `16777215` white. And **canvas coordinates are not
indexes** — Phosphor is base-1 everywhere a program counts things, but a canvas
counts device pixels, and the top-left pixel is `(0, 0)`. `canvas_fillrect@(bm@, 10,
10, 60, 60)` paints columns 10 through 59.

## Functions

### The surfaces

| function | what it answers |
| --- | --- |
| `bitmap@(w, h) → handle` | a new off-screen drawing surface `w`×`h` pixels, owned by the handle it answers. It needs no window and no parent. Its initial content is whatever the widgetset leaves there, so set a brush colour and `canvas_clear@` before you trust a pixel you did not paint |
| `bitmap_width(bm@) → num` | its width in pixels; `0` on a handle that is not a bitmap, with `gui_error()` at `1` |
| `bitmap_height(bm@) → num` | its height in pixels; `0` on a handle that is not a bitmap, `gui_error()` `1` |
| `bitmap_pixel(bm@, x, y) → num` | the TColor at `(x, y)`, counting from `(0, 0)`. This is the headless proof that drawing happened. `0` — which is also plain black — on a handle that is not a bitmap, so check `gui_error()` when black is a possible answer |
| `paintbox@(parent@) → handle` | a live drawing surface parented to `parent@`, drawn on by the same `canvas_*` calls a bitmap takes. Handle `0` when `parent@` is not a windowed control, `gui_error()` `1`. It belongs to its parent, which frees it |
| `paintbox_onpaint@(pb@, handler$) → handle` | wire the BASIC routine named `handler$` — declared with one parameter, `sender@` — to be called every time the widget is asked to paint. `sender@` arrives as the paint box itself, so the handler draws with the ordinary `canvas_*` calls. An empty name **unwires** the event. Answers `pb@` either way; a handle that is not a paint box records `gui_error()` `1` and wires nothing |
| `image_setbitmap@(img@, bm@) → handle` | show `bm@` in the image control `img@`, and answer `img@`. The bitmap is **copied**, not linked: drawing on `bm@` afterwards changes nothing on screen until you call this again. Either handle being wrong leaves the picture untouched, with `gui_error()` `1` |

### Pen, brush and font

State is **per surface and sticky** — it holds until changed, and every drawing call
below uses whatever was last set.

| function | what it answers |
| --- | --- |
| `canvas_pencolor@(surf@, color) → handle` | `surf@`, with the outline colour set. The pen draws lines and the *borders* of the shapes |
| `canvas_penwidth@(surf@, n) → handle` | `surf@`, with the pen `n` pixels wide |
| `canvas_brushcolor@(surf@, color) → handle` | `surf@`, with the fill colour set. The brush fills shape interiors, is what `canvas_clear@` paints with, and is the background `canvas_textout@` writes onto |
| `canvas_fontsize@(surf@, points) → handle` | `surf@`, with the text size for `canvas_textout@` and the two measuring calls |
| `canvas_fontcolor@(surf@, color) → handle` | `surf@`, with the colour `canvas_textout@` writes in — the *font* colour, distinct from the pen |

Each of these answers the handle it was given **even when it could not use it**: a
bad or wrong-class handle changes nothing, records `gui_error()` `1`, and is handed
straight back unread.

### Drawing

| function | what it answers |
| --- | --- |
| `canvas_moveto@(surf@, x, y) → handle` | `surf@`, with the current point moved without drawing |
| `canvas_lineto@(surf@, x, y) → handle` | `surf@`, having drawn from the current point to `(x, y)` in the pen colour, and left the current point there |
| `canvas_line@(surf@, x1, y1, x2, y2) → handle` | `surf@`, having drawn one segment between two explicit ends — the `moveto`/`lineto` pair as a single call |
| `canvas_rectangle@(surf@, x1, y1, x2, y2) → handle` | `surf@`, having drawn a rectangle **outlined in the pen and filled with the brush** |
| `canvas_fillrect@(surf@, x1, y1, x2, y2) → handle` | `surf@`, having filled a rectangle with the brush and **no outline** |
| `canvas_roundrect@(surf@, x1, y1, x2, y2, rx, ry) → handle` | `surf@`, having drawn a rectangle whose corners are rounded by the ellipse `rx`×`ry`; outlined and filled like `canvas_rectangle@` |
| `canvas_ellipse@(surf@, x1, y1, x2, y2) → handle` | `surf@`, having drawn the ellipse inscribed in that rectangle, outlined and filled |
| `canvas_arc@(surf@, x1, y1, x2, y2, start, extent) → handle` | `surf@`, having drawn an arc of that ellipse: `extent` degrees counter-clockwise from `start` degrees. **Degrees** — the LCL's sixteenths-of-a-degree are converted here, because a program should not have to know that unit to draw a quarter circle |
| `canvas_pie@(surf@, x1, y1, x2, y2, start, extent) → handle` | `surf@`, having drawn the same span as a filled wedge back to the centre. Degrees, as above |
| `canvas_polygon@(surf@, points$) → handle` | `surf@`, having drawn a closed outlined-and-filled polygon through `points$`, written `"x,y x,y x,y"` — a comma inside a pair, spaces between pairs. Anything malformed, fewer than two points, or more than 256, is **refused entirely**: nothing is drawn and `gui_error()` is `1`, rather than a shape with a stray vertex at the origin |
| `canvas_polyline@(surf@, points$) → handle` | `surf@`, having drawn the same points as an open line in the pen colour. Same point format, same all-or-nothing refusal |
| `canvas_clear@(surf@) → handle` | `surf@`, with its whole drawable area filled **with the current brush colour**. Set the brush first; clearing does not mean white |
| `canvas_textout@(surf@, x, y, s$) → handle` | `surf@`, with `s$` drawn in the font colour on the brush background, `(x, y)` being its **top-left** corner |
| `canvas_textwidth(surf@, s$) → num` | how many pixels `s$` would occupy across, in the surface's current font — before you draw it. `0` on a handle with no canvas, `gui_error()` `1` |
| `canvas_textheight(surf@, s$) → num` | the same measurement vertically; `0` on a handle with no canvas |

### The shape control

`shape@` is the one *retained* thing here: a small child control that keeps drawing
itself, for when a plain filled outline is all you want and a whole bitmap is more
machinery than the job needs.

| function | what it answers |
| --- | --- |
| `shape@(parent@) → handle` | a new shape control parented to `parent@`. Handle `0` when `parent@` is not a windowed control, `gui_error()` `1`. Like every child control it belongs to its parent and is freed with it |
| `shape_kind@(sh@, kind) → handle` | `sh@`, with its outline set: `0` rectangle, `1` square, `2` roundrect, `3` roundsquare, `4` ellipse, `5` circle, `6` squared-diamond, `7` diamond, `8` triangle. A number outside the widgetset's range is **ignored silently** — the shape keeps the kind it had and no error is recorded |
| `shape_kind(sh@) → num` | which of those it currently is; `0` on a handle that is not a shape — and `0` is also "rectangle", so read `gui_error()` to tell them apart |
| `shape_brushcolor@(sh@, color) → handle` | `sh@`, with its interior colour set |
| `shape_brushcolor(sh@) → num` | that colour; `0` (black) on a handle that is not a shape, `gui_error()` `1` |
| `shape_pencolor@(sh@, color) → handle` | `sh@`, with its outline colour set |
| `shape_pencolor(sh@) → num` | that colour; `0` on a handle that is not a shape, `gui_error()` `1` |

## A worked example

A bar chart painted off-screen, **checked before any window exists**, then shown in
a form beside a live paint box that redraws itself. Run it with
`phosphor run chart.bas`.

```basic
rem A chart drawn on a bitmap, verified headlessly, then displayed.

const WHITE = 16777215
const BLACK = 0
const BLUE  = 16711680

bm@ = bitmap@(320, 200)
canvas_brushcolor@(bm@, WHITE)
canvas_clear@(bm@)                  rem clear paints with the BRUSH colour
canvas_pencolor@(bm@, BLACK)
canvas_fontsize@(bm@, 9)
canvas_fontcolor@(bm@, BLACK)

for i = 1 to 5
  h = i * 28
  x = i * 60 - 40
  canvas_brushcolor@(bm@, BLUE)
  canvas_rectangle@(bm@, x, 170 - h, x + 34, 170)
  canvas_brushcolor@(bm@, WHITE)
  canvas_textout@(bm@, x, 174, str$(h))
next

canvas_moveto@(bm@, 10, 170)        rem the baseline
canvas_lineto@(bm@, 310, 170)

rem No window has been opened, and the drawing is already checkable.
gui_clearerror()
if bitmap_pixel(bm@, 30, 160) = BLUE then
  println "the first bar is really blue -- "; bitmap_width(bm@); "x"; bitmap_height(bm@)
endif

f@ = form@("Rainfall", 360, 330)
pic@ = image@(f@)
control_bounds@(pic@, 10, 10, 320, 200)
image_setbitmap@(pic@, bm@)         rem a COPY: later drawing on bm@ will not show

pb@ = paintbox@(f@)
control_bounds@(pb@, 10, 220, 320, 60)
paintbox_onpaint@(pb@, "draw_legend")

form_show(f@)
app_run()

function draw_legend(sender@)
  rem sender@ is the paint box, and the same canvas_* calls reach it
  canvas_brushcolor@(sender@, WHITE)
  canvas_clear@(sender@)
  canvas_brushcolor@(sender@, BLUE)
  canvas_fillrect@(sender@, 0, 0, 20, 20)
  canvas_fontcolor@(sender@, BLACK)
  canvas_textout@(sender@, 26, 2, "millimetres of rain")
  return 0
end function
```

Two things worth noticing:

- **The same seven calls drew on two different kinds of target.** `bm@` is an
  off-screen buffer and `sender@` is a live widget, and neither the loop nor
  `draw_legend` had to know which it had.
- **A bitmap keeps its picture; a live surface does not.** The chart survives
  because the pixels are the bitmap. The legend survives because the *handler* is
  wired — the widget is repainted from `draw_legend` every time it is uncovered or
  resized, so anything lasting on a live surface belongs inside the handler, not in
  a one-off call before `app_run()`.

## Notes

- **Freeing.** A `bitmap@` is owned by its handle, so `control_free(bm@)` releases
  both the handle and the pixels — worth doing in a loop that builds many. A
  `paintbox@` or `shape@` is owned by its parent form and dies with it; freeing it
  early is `control_free()` too.
- **Read `gui_error()` immediately.** The slot is shared by the whole GUI, and the
  canvas resolver clears it while trying each kind of surface in turn, so a stale
  error from an earlier line can be wiped by a successful drawing call. Call
  `gui_clearerror()` before the call you care about and read the error right after
  it.
- **Where the rest of the GUI lives.** Forms, controls, layout, the event model and
  the other sixteen GUI packages are described in
  [gui-components.md](../gui-components.md); `gui_error()` and `gui_clearerror()`
  belong to the shared GUI core, not to this library.
