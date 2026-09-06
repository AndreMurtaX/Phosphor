# gui-control — the members every visual control shares

`host/gui/libs/PhosphorControlLib.pas` · 77 functions · GUI package (the `phosphor`
host registers the seventeen GUI packages when a graphical session is reachable —
always on Windows, a `DISPLAY` or `WAYLAND_DISPLAY` on Unix)

## What it is for

Every visual LCL control descends from `TControl`, so **one** package exposes the
members they all share — geometry, visibility, colour, font, focus, the tab chain,
the mouse and key events — for *any* control handle. A per-family package
(`PhosphorButtonLib`, `PhosphorEditLib`, …) then only writes what is specific to its
control: `button_caption$` lives there, `control_width` lives here and works the same
on a button, a label, a panel, a page tab and a form.

The second half of the package is the multiplier. LCL controls carry full published-
property RTTI, so `control_set@(c@, "PropName", value)` and `control_get` /
`control_get$` reach **every published property by name** through `TypInfo` — no
hand-written helper per property. The named helpers below cover the hot path and read
better at a call site; the bridge covers the long tail with no extra code. It is
Phosphor's answer to the reference's `08_property_roundtrip`.

**Nothing here is raised.** A handle that was fabricated, freed or is of the wrong
class, and a property the control does not publish, are *recorded* in `gui_error()`
and answered with a benign value: a getter answers the zero of its own type (`0` or
`""`), and a setter writes nothing and still answers the handle it was handed. So a
run of writes against a stale handle does nothing at all instead of ending the
program, and `gui_error()` is where a program asks whether any of it worked — `1`
means the handle, `3` means the property. `gui_clearerror()` resets it, which is how
you attribute a code to one specific call.

**Read and write are two names, not one function with a success flag.**
`control_width(c@)` answers the width; `control_width@(c@, n)` sets it. The `@` on
the setter's own name is its return type, and what it returns is the control, so
writes chain and nest — `control_bold@(control_fontsize@(lbl@, 11), 1)` does both.
Booleans travel here as `0`/`1` numbers rather than `?` bools, because what is behind
them is an LCL ordinal being read back. Exactly two names break the pattern on
purpose: `control_free` answers whether it freed something, and `control_mousewheel`
answers whether the wheel was consumed.

## Functions

Throughout, `c@` is any control handle. Unless a row says otherwise, a getter given a
handle it cannot resolve answers `0` or `""` with `gui_error() = 1`, and a setter
given one changes nothing and answers that same handle back.

### Geometry

| function | what it answers |
| --- | --- |
| `control_left(c@) → num`<br>`control_left@(c@, x) → handle` | the left edge in pixels, in the **parent's** client coordinates — not the screen's |
| `control_top(c@) → num`<br>`control_top@(c@, y) → handle` | the top edge, likewise |
| `control_width(c@) → num`<br>`control_width@(c@, w) → handle` | the width. A value the `Constraints` refuse is clamped by the LCL, so reading it back is the only way to know what you got |
| `control_height(c@) → num`<br>`control_height@(c@, h) → handle` | the height, likewise |
| `control_align(c@) → num`<br>`control_align@(c@, a) → handle` | the `TAlign` ordinal: `0` none, `1` top, `2` bottom, `3` left, `4` right, `5` client, `6` custom. A number outside `0..6` leaves the alignment alone — and, unlike the bridge, records nothing, so pass a constant you trust |
| `control_move@(c@, x, y) → handle` | left and top in one call |
| `control_size@(c@, w, h) → handle` | width and height in one call |
| `control_bounds@(c@, x, y, w, h) → handle` | all four at once through `SetBounds`, so the control never passes through an intermediate rectangle on its way |

### State and appearance

| function | what it answers |
| --- | --- |
| `control_visible(c@) → num`<br>`control_visible@(c@, on) → handle` | the control's own `Visible` flag as `1`/`0` — what was asked for, not a claim about pixels: a shown control inside a hidden parent still answers `1` |
| `control_enabled(c@) → num`<br>`control_enabled@(c@, on) → handle` | whether the control accepts input, `1`/`0`. A disabled control still answers every getter here |
| `control_color(c@) → num`<br>`control_color@(c@, col) → handle` | the background colour as a `TColor` integer, **blue in the high byte** (`$00BBGGRR`): `65280` is green, `16777215` white. There is no colour-building helper in the GUI surface — the number is the value |
| `control_hint$(c@) → str`<br>`control_hint@(c@, text$) → handle` | the tooltip text; `""` when none was set. Whether it is ever *shown* is `ShowHint`, which has no named helper and is reached through the bridge |
| `control_cursor(c@) → num`<br>`control_cursor@(c@, cur) → handle` | the `TCursor` index. `0` is the default cursor; the stock shapes are negative |
| `control_tag(c@) → num`<br>`control_tag@(c@, n) → handle` | the integer the program owns and the LCL never reads. The usual way one shared handler tells its senders apart |

### Font

Each of these writes into the control's own `Font`; the pair round-trips.

| function | what it answers |
| --- | --- |
| `control_fontname$(c@) → str`<br>`control_fontname@(c@, name$) → handle` | the face name. A face the system does not have is not an error anywhere — the widgetset substitutes, and the name reads back as it was written |
| `control_fontsize(c@) → num`<br>`control_fontsize@(c@, pt) → handle` | the size in points |
| `control_fontcolor(c@) → num`<br>`control_fontcolor@(c@, col) → handle` | the text colour, same `TColor` encoding as `control_color` |
| `control_bold(c@) → num`<br>`control_bold@(c@, on) → handle` | `1` when bold is in the style set. Setting adds or removes **only** bold; italic and underline are left as they were |
| `control_italic(c@) → num`<br>`control_italic@(c@, on) → handle` | the same for italic |
| `control_underline(c@) → num`<br>`control_underline@(c@, on) → handle` | the same for underline |

### Verbs

| function | what it answers |
| --- | --- |
| `control_bringtofront@(c@) → handle` | the control, moved to the front of its parent's z-order |
| `control_sendtoback@(c@) → handle` | the control, moved to the back |
| `control_invalidate@(c@) → handle` | the control, marked for repaint. Nothing is drawn until the host pumps messages |
| `control_setfocus@(c@) → handle` | the control. It focuses only a windowed control whose window **already exists** — after `form_show@` — and is a deliberate no-op before that and headless, because asking whether it *could* focus would force the window into being and hang a run with no display. A control that cannot take focus at all (a label) is a silent no-op, not an error |
| `control_focused(c@) → num` | `1` only when this control really holds the focus in a realized window; `0` headless, before the form is shown, and for anything that cannot be focused |
| `control_free(c@) → num` | `1` when it destroyed a control, `0` with `gui_error() = 1` for a stale, doubly-freed or fabricated handle. Freeing a **form** frees the whole tree it owns, and every handle naming a control in that tree is afterwards *refused* — it answers `0`/`""` with `gui_error() = 1` rather than dereferencing a dead pointer |

### The layout backbone

| function | what it answers |
| --- | --- |
| `control_parent@(child@, newparent@) → handle` | the child, now living on `newparent@`. The one member the bridge cannot reach: `Parent` is public, not published, so RTTI does not see it. A parent that is one of the child's own descendants would make a cycle the LCL recurses on until the stack is gone, so the chain is walked first and the request refused with `gui_error() = 1`; an LCL refusal of its own is caught and recorded the same way |
| `control_anchors$(c@) → str`<br>`control_anchors@(c@, ids$) → handle` | the anchor set as an identifier list without brackets — `"akLeft,akRight"` — which is exactly the text the setter takes, so the pair round-trips. On a control with no published `Anchors`: `""` / no write, and `gui_error() = 3` |
| `control_tabstop(c@) → num`<br>`control_tabstop@(c@, on) → handle` | whether Tab reaches this control, `1`/`0`. Windowed controls only: on a label the getter answers `0` and **both** halves record `gui_error() = 1` |
| `control_taborder(c@) → num`<br>`control_taborder@(c@, n) → handle` | its 0-based position in the parent's tab chain. Windowed controls only, as above |
| `control_spacing(c@) → num`<br>`control_spacing@(c@, px) → handle` | `BorderSpacing.Around` — one gap for all four edges. `BorderSpacing` is a class-typed sub-object, which is precisely why the bridge refuses it and this named helper exists |
| `control_minwidth(c@) → num`<br>`control_minwidth@(c@, px) → handle` | `Constraints.MinWidth`; `0` is the LCL's "no constraint" |
| `control_maxwidth(c@) → num`<br>`control_maxwidth@(c@, px) → handle` | `Constraints.MaxWidth`, likewise |
| `control_minheight(c@) → num`<br>`control_minheight@(c@, px) → handle` | `Constraints.MinHeight`, likewise |
| `control_maxheight(c@) → num`<br>`control_maxheight@(c@, px) → handle` | `Constraints.MaxHeight`, likewise |

### Binding an event

Each binder takes the **name of a BASIC function** as a string, including its type
suffix — a handler called `on_wheel?` is bound as `"on_wheel?"`. An empty name
unwires the event. A handler that fails at run time is recorded (`gui_error() = 2`),
never raised into the middle of the widgetset.

| function | what it answers |
| --- | --- |
| `control_onkeydown@(c@, fn$) → handle` | the control. The handler is called as `(sender@, key%, mods$)`, `mods$` being any subset of `"S C A"` in that order. Key events exist only on windowed controls: binding one to a label binds nothing and records `gui_error() = 1` |
| `control_onkeyup@(c@, fn$) → handle` | the same signature on the release |
| `control_onkeypress@(c@, fn$) → handle` | called as `(sender@, ch$)` — the **character**, not the key code |
| `control_onmousedown@(c@, fn$) → handle` | called as `(sender@, button%, x%, y%, mods$)` with `0`/`1`/`2` for left/right/middle. Mouse events live on `TControl`, so a label or a shape can carry them too |
| `control_onmouseup@(c@, fn$) → handle` | the same signature on the release |
| `control_onmousemove@(c@, fn$) → handle` | called as `(sender@, x%, y%, mods$)` — position without a button |
| `control_onmousewheel@(c@, fn$) → handle` | called as `(sender@, delta%, x%, y%, mods$)`. Only an **explicit boolean `true`** from the handler consumes the event; a handler that answers a number, or falls off its end, leaves it unconsumed |

### Synthesising an event

These call the control's own `KeyDown` / `MouseDown` / … directly, so a handler runs
exactly as it would under a real click — with no window manager and no message loop.
That is what makes the whole event surface testable headless.

| function | what it answers |
| --- | --- |
| `control_keydown@(c@, key, mods$) → handle` | the control, after its key-down handler has run. `mods$` is any subset of `S`, `C`, `A` in any order — the same text a handler receives, read back the other way. Windowed controls only (`gui_error() = 1` otherwise) |
| `control_keyup@(c@, key, mods$) → handle` | the same for the release |
| `control_keypress@(c@, ch$) → handle` | the control, after its key-press handler has run on the **first byte** of `ch$`. An empty string presses nothing and is not an error |
| `control_mousedown@(c@, button, x, y, mods$) → handle` | the control, after its mouse-down handler has run at `x`,`y` |
| `control_mouseup@(c@, button, x, y, mods$) → handle` | the same for the release |
| `control_mousemove@(c@, x, y, mods$) → handle` | the control, after a move to `x`,`y` |
| `control_mousewheel(c@, delta, x, y, mods$) → num` | **not a handle** — `1` if the wheel was consumed, `0` if it was not, which is the handler's own decision read straight back out of one call. A positive `delta` is one way, a negative one the other; `0` when there is no handler, or the handle is bad |

### The generic property bridge

| function | what it answers |
| --- | --- |
| `control_set@(c@, name$, value) → handle`<br>`control_set@(c@, name$, value$) → handle`<br>`control_set@(c@, name$, value?) → handle` | the control, with the published property `name$` written. The BASIC type decides the write: a string sets a string property, an **enum by its identifier** (`"alClient"`) or a **set by its identifier list** (`"akLeft,akRight"`); a number sets a float or any ordinal. A string aimed at a plain ordinal is a mistake, not a value to coerce: it is refused with `gui_error() = 3` and the old value stays. An unknown property, or a class-typed one like `Constraints`, is refused the same way |
| `control_get(c@, name$) → num` | the property's numeric or ordinal value — an enum or set reads as its number. A property that has no numeric reading (a string, a class) answers `0` **and** records `gui_error() = 3`, so a real zero and an unreadable property are distinguishable |
| `control_get$(c@, name$) → str` | the string value; an enum as its identifier (`"alClient"`); a set as its bracket-less identifier list, in exactly the form `control_set@` accepts. Anything else answers `""` with `gui_error() = 3` |

## A worked example

A window whose top strip reports where the pointer is, with Escape to leave. It uses
a named helper wherever there is one, the bridge for the one property that has none,
and binds the mouse and key events to the **form** — which can carry both.

```basic
rem Run it:  phosphor run pointer.bas

f@ = form@("where is the pointer", 420, 220)
control_set@(f@, "ShowHint", 1)          rem no named helper; the bridge reaches it

bar@ = panel@(f@)
control_align@(bar@, 1)                  rem alTop: keeps the full width as it resizes
control_height@(bar@, 44)
control_color@(bar@, 15790320)

readout@ = label@(bar@, "move the pointer over the window")
control_move@(readout@, 12, 14)
control_fontname@(readout@, "Courier New")
control_bold@(control_fontsize@(readout@, 11), 1)
control_hint@(readout@, "the last position the form reported")
control_anchors@(readout@, "akLeft,akTop,akRight")

rem Mouse events live on TControl, key events need a windowed one -- a form is both.
control_onmousemove@(f@, "on_move")
control_onkeydown@(f@, "on_key")
if gui_error() <> 0 then println "something up there was refused, code " + str$(gui_error())

form_show@(f@)
app_run()

function on_move(sender@, x%, y%, mods$)
  label_caption@(readout@, "x=" + str$(x%) + "  y=" + str$(y%) + "  [" + mods$ + "]")
  return 0
endfunction

function on_key(sender@, key%, mods$)
  if key% = 27 then app_quit()
  return 0
endfunction
```

Two things worth noticing:

- **`control_bold@(control_fontsize@(readout@, 11), 1)` is one statement doing two
  writes.** Every setter answers the control it changed, so the inner call hands the
  outer one its argument. That is the whole reason a mutator answers a handle instead
  of a `1` nobody reads.
- **The binding could have gone to `readout@` and half of it would have vanished.** A
  label is not a windowed control, so `control_onkeydown@` on it binds nothing and
  records `gui_error() = 1` — which is why the check is there and why the program asks
  once, after the whole block, rather than never.

## Notes

- **Headless is a first-class mode.** `control_setfocus@` and `control_focused` are
  the two functions whose answers depend on a real window existing; everything else
  in this package — including every synthesised event — behaves identically with no
  display, which is how `tests/gui/*.bas` runs byte-exact on Windows and Linux.
- **Where the rest lives.** Constructing controls (`form@`, `button@`, `panel@`,
  `label@`, …) and everything specific to one family belongs to that family's
  package; `gui_error()` and `gui_clearerror()`, the shared error state this page
  keeps referring to, belong to `gui-core`, together with `app_run` and
  `app_quit`. [gui-components.md](../gui-components.md) is the map of all seventeen.
