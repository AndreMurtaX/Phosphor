# gui-button — push, bitmap and speed buttons, and the click that reaches BASIC

`host/gui/libs/PhosphorButtonLib.pas` · 18 functions · a GUI package, registered by
`phosphor` when a graphical session is reachable

## What it is for

Three of the LCL's button classes, each given the same four verbs. A **push
button** (`button@`) is the ordinary one: a caption, and a click. A **bitmap
button** (`bitbtn@`) is the same control with room for a picture, which is what
makes an OK/Cancel row look like one. A **speed button** (`speedbutton@`) is the
toolbar kind — it can *latch*, and buttons that share a group index latch
exclusively, so a row of them is a choice rather than three independent actions.
That last one is why the family needs more than four verbs: `speedbutton_down`
and `speedbutton_groupindex@` are the state a push button does not have.

The library follows the GUI surface described in
[gui-components.md](../gui-components.md), and nothing here departs from it. A
constructor takes **only the parent** — geometry is a second call
(`control_bounds@`), never constructor arguments. A setter ends in `@` and answers
**the handle it was given**, so calls read left to right and can be chained; the
getter is the same name without the `@`. Everything a button shares with every
other control — position, colour, font, `enabled`, key and mouse events,
`control_free` — lives in the control backbone, not here. This page has only what
is specific to a button, which is its caption and its click.

**Errors are recorded, not raised.** Nothing in this file can fail a program. Hand
any of these a fabricated handle, a freed one, or a handle to the wrong kind of
control and the call simply does nothing useful: a constructor answers handle `0`
and builds no control, a setter answers the handle unchanged, a getter answers
`""` or `0`. Since `""` is also the honest answer for a button whose caption really
is empty, `gui_error()` is what separates *no caption* from *no button* — call
`gui_clearerror()`, do the work, then read it. `1` means a handle problem; `2`
means a bound handler failed at run time.

The three `*_onclick@` binders are the only **host-aware** functions here: each is
handed the executing VM and stores it in the event bridge, so a click that happens
much later can still run the handler through `CallUserFunc`. The handler is an
ordinary BASIC function, `function on_click(sender@) … endfunction`, and `sender@`
is the **live handle** of the button that fired — writing through it changes that
button. Passing `""` unwires the event. There is one bridge per control and event,
so binding a second time replaces rather than adds. One thing a caller would
otherwise be surprised by: **a handler name that is not a function is accepted
silently.** The bind records no error at all; the first click is where it shows,
as `gui_error()` = `2`.

## Functions

### Push button — `TButton`

| function | what it answers |
| --- | --- |
| `button@(parent@) → handle` | a new push button parented to `parent@`, owned by it and freed with it. A parent that is not a window control — a fabricated or freed handle, or a *graphic* control such as a speed button, which cannot host children — answers handle `0`, builds nothing, and records `gui_error()` `1` |
| `button_caption@(b@, s$) → handle` | sets the text and answers `b@`, so the next call can take it. On a handle that is not a button it changes nothing, still answers the handle, and records `1` — the return value is never a success flag |
| `button_caption$(b@) → str` | the text. `""` both for a button whose caption is empty and for a handle that is not a button; `gui_error()` is what tells the two apart |
| `button_click@(b@) → handle` | fires `OnClick` synchronously, right now, with no window shown and no message loop — the headless way to prove an event reaches its handler. With nothing bound, nothing happens and nothing is recorded. On a wrong handle nothing fires and `gui_error()` is `1`. Answers the button, like every other `@` in this library |
| `button_onclick@(b@, name$) → handle` | binds the click to the BASIC function `name$` and answers `b@`. `""` unwires it; binding again replaces the previous handler. A name that is not a function is accepted here and fails at the **first click**, as `gui_error()` `2` |

### Bitmap button — `TBitBtn`

The same four verbs, on the LCL control that carries a glyph beside its caption.

| function | what it answers |
| --- | --- |
| `bitbtn@(parent@) → handle` | a new bitmap button on `parent@`; handle `0` and `gui_error()` `1` for a parent that cannot hold controls |
| `bitbtn_caption@(bb@, s$) → handle` | sets the text, answers `bb@`; silently a no-op plus `gui_error()` `1` on a wrong handle |
| `bitbtn_caption$(bb@) → str` | the text; `""` when empty **and** when the handle is not a bitmap button |
| `bitbtn_click@(bb@) → handle` | fires `OnClick` at once, as `button_click@` does, and answers the button |
| `bitbtn_onclick@(bb@, name$) → handle` | binds or (with `""`) unwires the click; an unknown name surfaces only on the first click |

The **picture itself is not reachable from BASIC**: `Glyph` is an object-typed
property, and the generic property bridge sets ordinals, strings, floats, enums and
sets — not objects. What is reachable is the standard kind:
`control_set@(bb@, "Kind", "bkOK")` (also `bkCancel`, `bkYes`, `bkNo`, `bkClose`,
`bkHelp`, …). Set it **before** the caption — assigning `Kind` rewrites the caption
to the LCL's own (`&OK`), so a `bitbtn_caption@` done first is thrown away.

### Speed button — `TSpeedButton`

| function | what it answers |
| --- | --- |
| `speedbutton@(parent@) → handle` | a new speed button on `parent@`; handle `0` and `gui_error()` `1` for a parent that cannot hold controls. Note it is a *graphic* control: it cannot take focus and cannot itself be a parent |
| `speedbutton_caption@(sb@, s$) → handle` | sets the text, answers `sb@`; a no-op plus `1` on a wrong handle |
| `speedbutton_caption$(sb@) → str` | the text; `""` when empty and when the handle is not a speed button |
| `speedbutton_click@(sb@) → handle` | fires `OnClick`, and **only** that: a synthesised click does not latch the button the way a real mouse press does. Answers the button |
| `speedbutton_onclick@(sb@, name$) → handle` | binds or unwires the click, exactly as the other two families |
| `speedbutton_down@(sb@, n) → handle` | latches the button when `n` is non-zero, releases it when `0`, and answers `sb@`. Two LCL rules bite here and **neither records an error**: with the group index still `0` the button cannot latch at all, so `speedbutton_down(sb@)` keeps answering `0`; and releasing the only latched button of a group is refused unless `control_set@(sb@, "AllowAllUp", 1)` was set first |
| `speedbutton_down(sb@) → num` | `1` latched, `0` up. Also `0` — with `gui_error()` `1` — for a handle that is not a speed button |
| `speedbutton_groupindex@(sb@, n) → handle` | joins the button to group `n` and answers `sb@`. Buttons sharing a **non-zero** group are mutually exclusive: latching one releases the others. `0`, the default, means no group, and is exactly what makes the button unable to stay down |

## A worked example

A tool picker driven entirely from BASIC. It builds a form it never shows, then
synthesises the clicks — which is how the GUI suite tests event wiring on a
machine with no display. Run it with `phosphor run tools.bas`.

```basic
rem Two speed buttons behave as one choice because they share a group
rem index; a bitmap button confirms; a push button reports. Nothing is
rem displayed -- every click below is synthesised.

tool$ = "none"

f@ = form@("Tools", 320, 120)

pen@ = speedbutton@(f@)
speedbutton_caption@(pen@, "Pen")
speedbutton_groupindex@(pen@, 1)
control_bounds@(pen@, 10, 10, 60, 30)
speedbutton_onclick@(pen@, "on_tool")

fill@ = speedbutton@(f@)
speedbutton_caption@(fill@, "Fill")
speedbutton_groupindex@(fill@, 1)
control_bounds@(fill@, 76, 10, 60, 30)
speedbutton_onclick@(fill@, "on_tool")

ok@ = bitbtn@(f@)
control_set@(ok@, "Kind", "bkOK")     rem before the caption, or it wins
bitbtn_caption@(ok@, "Apply")
control_bounds@(ok@, 10, 50, 90, 30)
bitbtn_onclick@(ok@, "on_apply")

undo@ = button@(f@)
button_caption@(undo@, "Undo")
control_bounds@(undo@, 106, 50, 90, 30)
button_onclick@(undo@, "on_undo")

rem --- drive it with no window and no message loop ---
speedbutton_click@(pen@)
speedbutton_down@(pen@, 1)
println "pen down:  " + str$(speedbutton_down(pen@))
speedbutton_down@(fill@, 1)
println "fill down: " + str$(speedbutton_down(fill@))
println "pen down:  " + str$(speedbutton_down(pen@))
bitbtn_click@(ok@)
button_click@(undo@)
println "tool is " + tool$ + ", gui_error " + str$(gui_error())

function on_tool(sender@)
  tool$ = speedbutton_caption$(sender@)
  println "picked " + tool$
  return 0
endfunction

function on_apply(sender@)
  println "apply, from " + bitbtn_caption$(sender@)
  return 0
endfunction

function on_undo(sender@)
  button_caption@(sender@, "Undone")
  println "the handler renamed its sender to " + button_caption$(sender@)
  return 0
endfunction
```

It prints:

```
picked Pen
pen down:  1
fill down: 1
pen down:  0
apply, from Apply
the handler renamed its sender to Undone
tool is Pen, gui_error 0
```

Two things worth noticing:

- **Clicking and latching are separate acts.** `speedbutton_click@(pen@)` ran
  `on_tool` — that is the first line of output — but left the button up. Only
  `speedbutton_down@` latches it, and only because a group index was set first.
  Latching `fill@` then released `pen@` without any code saying so: the group is
  the state machine, not the program.
- **`sender@` is the button, not a copy of it.** `on_undo` writes a caption through
  the handle it was handed and the button it was fired on changes. That is the same
  property `tests/gui/01_events.bas` asserts, and it is what makes one handler
  usable by a whole row of buttons — as `on_tool` is here.

## Notes / Where the rest lives

- **Lifetime.** A button is created owned by its parent, so freeing the form
  destroys it. The handle notices — it watches the component — so a call on a
  button whose form is gone records `gui_error()` `1` rather than touching freed
  memory. `control_free(b@)` destroys a single button on its own.
- **A button's other published properties** come from the generic bridge, not from
  this file: `control_set@(b@, "Default", 1)` makes Enter press it,
  `control_set@(b@, "Cancel", 1)` makes Esc do so, and
  `control_get(b@, "Default")` reads back.
- **A wart that used to be here.** Until 2026-09-06 the three click verbs were
  registered as `button_click`, `bitbtn_click` and `speedbutton_click` — no
  suffix, which by Phosphor's own convention reads as *answers a number* — while
  each in fact returned the handle it was given. They carry `@` now, like every
  other setter on this page, so the name and the answer agree:
  `z@ = button_click@(b@)` is accepted, `n = button_click@(b@)` is the ordinary
  *cannot store handle into number variable* (`err()` code 3), and the unsuffixed
  spelling is gone — `button_click(b@)` is *no function button_click:@*.
  `scripts/check-suffix.py` is the gate that keeps the fifteen names it fixed from
  drifting back.
- **Key and mouse events** on a button are bound with `control_onkeydown@`,
  `control_onmousedown@` and friends — one set for every control, rather than one
  per widget. They are documented with the rest of the event model in
  [gui-components.md](../gui-components.md).
