# gui-range — the controls that hold a number inside a range

`host/gui/libs/PhosphorRangeLib.pas` · 29 functions · GUI package (the `phosphor`
host registers the GUI wherever a graphical session is reachable — always on
Windows, `DISPLAY` or `WAYLAND_DISPLAY` elsewhere; where it is not, these names
simply do not exist and every non-GUI name still works)

## What it is for

Four widgets in this package say the same thing in four different ways: **a
number, and the two ends it lives between**. A **trackbar** is a slider the user
drags; a **progress bar** shows how far along something is; a **scroll bar** is
the classic thumb-in-a-groove; an **up/down** is the small pair of arrows that
step a value. As the unit header puts it, these are "controls that hold a value
within a range" — so each one gets exactly the same four verbs: a constructor,
`_min`, `_max` and `_position`.

Everything else about them lives elsewhere. Where the control sits, how big it
is, whether it is enabled, what colour and font it uses — all of that is
`PhosphorControlLib` (`control_bounds@`, `control_move@`, `control_enabled@`,
`control_free(h@)`), which works on any control handle. This package adds only
the range, and the trackbar's one event. That is why a page of four widgets is
29 names and not a hundred.

The shape is the GUI's uniform surface, and two parts of it are load-bearing.
First, **the `@` suffix separates writing from reading**: `trackbar_max@(tb@, 100)`
sets, `trackbar_max(tb@)` reads. Second, **a setter answers the handle, not a
success flag** — it hands you back the control you were talking to, so calls read
left to right and can be nested. Which means the answer of a setter tells you
nothing about whether it worked, by design: as everywhere in the GUI, no
exception crosses into BASIC, a handle that is not a live control of the expected
class is recorded in the shared slot that `gui_error()` reads, and the call
answers something benign — a getter `0`, a setter the handle you passed, a
constructor handle `0`. To judge one call, use the *clear, act, ask* shape:
`gui_clearerror()`, the call, `gui_error()`.

Two things a caller would otherwise be surprised by. **Set the range before the
position** — a widget only holds a position its current `min`/`max` allow, and
these three properties are handed straight to the platform widget in the order
you call them, which is why the test corpus writes min, then max, then position.
And **there is exactly one event in this package**: `trackbar_onchange@`. A
progress bar is output-only and needs none, but the scroll bar and the up/down do
not have a binder here either — when you need their value, read
`scrollbar_position()` or `updown_position()` from another control's handler or
from a `timer_ontimer@` tick.

## Functions

Every setter takes the value as a number and answers the handle; every getter
takes the handle and answers a number. Values are narrowed to 32-bit signed on
the way in (out-of-range numbers saturate at the 32-bit limits), and the widget's
own limits apply after that — read the value back if it matters.

### Trackbar — a slider the user drags

| function | what it answers |
| --- | --- |
| `trackbar@(parent@) → handle` | a new slider parented to `parent@`. Handle `0` and `gui_error()` `1` when `parent@` is not a live control that can hold children (a form, panel, group box, scroll box, tab sheet, tool bar) |
| `trackbar_min@(tb@, n) → handle` | set the low end; answers `tb@`. A handle that is not a live trackbar changes nothing, records `gui_error()` `1`, and still answers `tb@` |
| `trackbar_min(tb@) → num` | the low end; `0` when the handle is not a live trackbar |
| `trackbar_max@(tb@, n) → handle` | set the high end; answers `tb@`, and records `gui_error()` `1` on a bad handle |
| `trackbar_max(tb@) → num` | the high end; `0` on a bad handle |
| `trackbar_position@(tb@, n) → handle` | move the thumb; answers `tb@`. A position the current range does not allow is the widget's business, not an error — read it back to see what it took |
| `trackbar_position(tb@) → num` | where the thumb is now; `0` on a bad handle |
| `trackbar_onchange@(tb@, "func") → handle` | bind a BASIC function by name; it is called with one argument, the trackbar's own handle. `""` unbinds. Answers `tb@` either way; a bad handle binds nothing and records `gui_error()` `1`. A handler that fails at run time does not abort the event — it records `gui_error()` `2`. There is no read-back getter for a binding, here or anywhere in the GUI |

### Progress bar — output only

| function | what it answers |
| --- | --- |
| `progressbar@(parent@) → handle` | a new progress bar parented to `parent@`; handle `0` and `gui_error()` `1` when the parent cannot hold children |
| `progressbar_min@(pb@, n) → handle` | set the low end; answers `pb@`, `gui_error()` `1` on a bad handle |
| `progressbar_min(pb@) → num` | the low end; `0` on a bad handle |
| `progressbar_max@(pb@, n) → handle` | set the high end — the value that means "full"; answers `pb@` |
| `progressbar_max(pb@) → num` | the high end; `0` on a bad handle |
| `progressbar_position@(pb@, n) → handle` | how far along the bar is drawn; answers `pb@`. Nothing here throttles redraws: call it as often as your work reports progress |
| `progressbar_position(pb@) → num` | the position the bar is showing; `0` on a bad handle |

### Scroll bar — a standalone thumb in a groove

| function | what it answers |
| --- | --- |
| `scrollbar@(parent@) → handle` | a new scroll bar parented to `parent@`; handle `0` and `gui_error()` `1` when the parent cannot hold children. This is a scroll bar as a *control* — the bars a scroll box grows around its own content are not these |
| `scrollbar_min@(sb@, n) → handle` | set the low end; answers `sb@`, `gui_error()` `1` on a bad handle |
| `scrollbar_min(sb@) → num` | the low end; `0` on a bad handle |
| `scrollbar_max@(sb@, n) → handle` | set the high end; answers `sb@` |
| `scrollbar_max(sb@) → num` | the high end; `0` on a bad handle |
| `scrollbar_position@(sb@, n) → handle` | move the thumb; answers `sb@` |
| `scrollbar_position(sb@) → num` | where the thumb is now; `0` on a bad handle. With no binder in this package, this is how a program learns the user scrolled — poll it |

### Up/down — a small pair of increment/decrement arrows

| function | what it answers |
| --- | --- |
| `updown@(parent@) → handle` | a new up/down parented to `parent@`; handle `0` and `gui_error()` `1` when the parent cannot hold children. Not in the unit header's list — it was built later, into the same shape |
| `updown_min@(ud@, n) → handle` | set the low end; answers `ud@`, `gui_error()` `1` on a bad handle |
| `updown_min(ud@) → num` | the low end; `0` on a bad handle |
| `updown_max@(ud@, n) → handle` | set the high end; answers `ud@` |
| `updown_max(ud@) → num` | the high end; `0` on a bad handle |
| `updown_position@(ud@, n) → handle` | set the value the arrows step; answers `ud@` |
| `updown_position(ud@) → num` | the current value; `0` on a bad handle. Like the scroll bar, it has no binder here — read it when you need it |

## A worked example

A slider that drives a progress bar, with the number spelled out in a label. Save
it and run `phosphor run volume.bas`: drag the slider and the bar follows, because
the trackbar's `onchange` handler is the only thing wiring them together.

```basic
rem A slider, a progress bar that mirrors it, and a label that says the number.

f@ = form@("Range demo", 440, 220)

lbl@ = label@(f@, "40%")
control_move@(lbl@, 20, 20)
control_fontsize@(lbl@, 13)

bar@ = progressbar@(f@)
control_bounds@(bar@, 20, 56, 400, 24)
progressbar_min@(bar@, 0)
progressbar_max@(bar@, 100)
progressbar_position@(bar@, 40)

sl@ = trackbar@(f@)
control_bounds@(sl@, 20, 100, 400, 40)
trackbar_min@(sl@, 0)
trackbar_max@(sl@, 100)
trackbar_position@(sl@, 40)
trackbar_onchange@(sl@, "on_slide")

form_show@(f@)
app_run()

function on_slide(sender@)
  rem The handler reads the position from the handle it was HANDED, not from a
  rem global -- so a second slider could bind to this same routine.
  p = trackbar_position(sender@)
  progressbar_position@(bar@, p)
  label_caption@(lbl@, str$(p) + "%")
  return 0
endfunction
```

Two things worth noticing:

- **The range is set before the position, every time.** `trackbar_position@(sl@, 40)`
  before `trackbar_max@(sl@, 100)` would be asking for 40 inside a range that does
  not yet reach it. The three calls are independent property writes, applied in
  the order you make them.
- **Nothing keeps the two controls in step but your handler.** The progress bar
  has no notion of being bound to the slider; `on_slide` copies the number across.
  That is also why the bar's `min`/`max` are set explicitly to match — two
  independent ranges that happen to agree.

## Notes

**Chaining.** Because a setter answers its handle, the three range calls can be
written as one expression — `trackbar_position@(trackbar_max@(trackbar_min@(sl@, 0), 100), 40)`
is the same program as the three lines above. The test corpus writes them on
separate lines; both are idiomatic, and the nested form is the reason the setters
answer a handle at all.

**Whether a programmatic write fires `onchange`** is the widget set's business and
the test corpus does not pin it down for the trackbar — do not rely on it firing,
and do not rely on it staying silent. If a program needs to run the same work for
a user drag and for its own write, call that routine yourself after the write.

**Lifetime.** These controls are children: the form owns them, so freeing or
closing the form takes them with it and their handles stop resolving from that
moment. `control_free(h@)` destroys one early. Everything else about a range
control — geometry, colour, font, hints, tab order, `control_enabled@`,
`control_visible@` — is on the [gui-core](gui-core.md) backbone's neighbour
`PhosphorControlLib`, which treats these four exactly like every other control.
