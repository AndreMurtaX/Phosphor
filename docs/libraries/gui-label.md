# gui-label — a caption on a form, in the two kinds the LCL has

`host/gui/libs/PhosphorLabelLib.pas` · 6 functions · GUI package (the `phosphor`
host registers it whenever a graphical session is reachable — always on Windows,
`DISPLAY` or `WAYLAND_DISPLAY` on Unix — and the headless GUI test runner registers
it too; on a machine with no session these names are not registered at all, so a
call is an unknown function rather than a silent failure)

## What it is for

A form needs text that is not editable: a field's title, a status line, a result.
This package builds the two controls that carry it — `label@` (a `TLabel`) and
`statictext@` (a `TStaticText`) — and gives each one a caption it can set and read.
That is deliberately *all* it gives. The unit header says so in as many words: a
label's geometry, colour, font and alignment come from the shared control backbone
(`control_move@`, `control_bounds@`, `control_fontsize@`, `control_bold@`,
`control_color@`, `control_visible@`, `control_free`) and from the generic property
bridge, so this package registers no font, colour or layout names of its own. The
properties with no named helper are reached by name: `control_set@(l@, "AutoSize",
0)`, `control_set@(l@, "WordWrap", 1)`, `control_set@(l@, "Alignment", "taCenter")`,
and for a static text `control_set@(st@, "BorderStyle", "sbsSunken")`.

The two are not the same control wearing two names. **A label is a `TControl`: it
has no window handle**, so it cannot take the keyboard focus, has no place in the
tab chain, and the key events of the shared surface (which resolve a `TWinControl`)
do not bind to it — its mouse events do, because those live on `TControl`. **A
static text is a real window**: it has a handle, a tab order, an optional border,
and it can host children. The rule of thumb the two names encode: reach for a label
for text the user only reads, and for a static text when the text must look like a
field or sit in the tab order.

The design stance is the one the whole GUI surface takes: **nothing here raises,
and a mutator answers information rather than a success flag**. Both setters answer
the handle they were given, so a call chains or nests; that means the return value
tells you nothing about whether the set happened. Both getters answer `""` when the
handle is not a live control of the right class — and `""` is also what a genuinely
empty caption answers, because empty is a real answer. `gui_error()` is what tells
the two apart: it is `1` after a fabricated, freed or wrong-class handle, it is
shared by every GUI package, and it is **sticky** until `gui_clearerror()`, so read
it right after the call you are questioning.

One consequence worth stating before it surprises someone: a constructor that
cannot do its job answers **handle `0`**, which is not a handle (Phosphor handles
are 1-based). The program keeps running, and every later call that is handed that
`0` records `gui_error` 1 of its own. `label@` fails that way only for one reason —
its `parent@` is not a live windowed control. A form, `panel@`, `groupbox@` or
`scrollbox@` is one; another label is not.

## Functions

| function | what it answers |
| --- | --- |
| `label@(parent@) → handle` · `label@(parent@, caption$) → handle` | a new label parented to `parent@`, with an empty caption or with `caption$`. The label is a child of the parent's window, so the form's tree owns it and `AutoSize` starts **on** — turn it off before setting bounds or the label will resize itself back. Answers handle `0` and records `gui_error` 1 when `parent@` is not a live `TWinControl` (a label cannot be a parent) |
| `label_caption@(l@, s$) → handle` | `l@` itself, so the call chains or nests. On a handle that is not a live label the caption is left alone and `gui_error` becomes 1 — the handle still comes back, so this return value is never a success flag |
| `label_caption$(l@) → str` | the current caption; `""` on a handle that is not a live label, which is the same answer a label whose caption really is empty gives. Check `gui_error()` when the difference matters |
| `statictext@(parent@) → handle` · `statictext@(parent@, caption$) → handle` | a new static text — a windowed, non-wrapping caption with an optional border — parented to `parent@`. `AutoSize` starts **off**, so the bounds you set are the bounds you get. Same failure as `label@`: handle `0` and `gui_error` 1 for a parent that is not a live windowed control |
| `statictext_caption@(st@, s$) → handle` | `st@` itself. A handle that is not a live static text (a *label* handle included — the two families do not accept each other's controls) changes nothing and records `gui_error` 1 |
| `statictext_caption$(st@) → str` | the current caption; `""` for a handle that is not a live static text, indistinguishable from an empty caption except through `gui_error()` |

## A worked example

A small window with both kinds of caption: a bold title, a wrapped paragraph of
body text that also serves as the click target, and a bordered static text that
reports the count. It runs under `phosphor run` on any machine with a desktop
session — no flag and no second binary.

```basic
rem Both captions on one form. The label wraps and hears the mouse;
rem the static text is a real window with a sunken border.

clicks = 0

f@ = form@("Captions", 380, 210)

title@ = label@(f@, "Disk report")
control_move@(title@, 16, 14)
control_fontsize@(title@, 13)
control_bold@(title@, 1)

rem AutoSize is on for a new label, and it would undo the bounds below,
rem so switch it off first and let WordWrap use the width.
msg$ = "Click this paragraph. A label has no window handle, so it takes no focus"
msg$ = msg$ + " and no tab order -- but mouse events live on TControl, so it"
msg$ = msg$ + " still hears the click."
body@ = label@(f@, msg$)
control_set@(body@, "AutoSize", 0)
control_set@(body@, "WordWrap", 1)
control_bounds@(body@, 16, 46, 344, 64)
control_onmousedown@(body@, "on_body_click")

st@ = statictext@(f@, "clicks: 0")
control_bounds@(st@, 16, 126, 150, 26)
control_set@(st@, "BorderStyle", "sbsSunken")

form_show@(f@)
app_run()

function on_body_click(sender@, button%, x%, y%, mods$)
  clicks = clicks + 1
  statictext_caption@(st@, "clicks: " + str$(clicks))
  label_caption@(title@, "Disk report (" + statictext_caption$(st@) + ")")
  return 0
endfunction
```

Two things worth noticing:

- **The handler reads a caption back out of the control.** `statictext_caption$`
  is not a convenience for debugging; the control is the state, and the program
  does not have to keep a shadow copy of the string it last wrote.
- **Nothing checks a return value, and that is correct.** If `f@` had failed to
  build, every call below it would record `gui_error` 1 and the program would still
  reach `app_run()` — so a program that wants to know asks `gui_error()`, once,
  after the block of construction it cares about, rather than testing each answer.

## Notes

- **Freeing.** A label and a static text are non-owning handles: the form owns the
  control tree, and closing the form (or `ResetHandles` at program end) frees them.
  `control_free(l@)` destroys one early on purpose. Either way the handle is
  *watched* — after the control dies, every use of the stale handle answers `""` or
  handle `0` with `gui_error` 1 instead of dereferencing a dead pointer.
- **A label's events.** `control_onmousedown@`, `control_onmouseup@` and
  `control_onmousemove@` bind on a label, because those events belong to
  `TControl`. `control_onkeydown@`, `control_onkeyup@` and `control_onkeypress@`
  resolve a `TWinControl`, so they bind on a static text and quietly do not bind on
  a label.
- **Where the rest lives.** The shared control surface (`control_*`) comes from
  `host/gui/libs/PhosphorControlLib.pas`; the error and handle model, the package
  inventory and the LCL palette this maps onto are in
  [../gui-components.md](../gui-components.md). `tests/gui/03_input.bas` covers the
  label and `tests/gui/11_more_input.bas` the static text, both headless.
