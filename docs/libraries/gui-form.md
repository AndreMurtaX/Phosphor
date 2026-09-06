# gui-form — the window, and the two events that end it

`host/gui/libs/PhosphorFormLib.pas` · 12 functions · GUI package (the `phosphor`
host registers it only where a graphical session is reachable — always on Windows,
`DISPLAY` or `WAYLAND_DISPLAY` on Unix. Where there is none, `form@()` is an
ordinary catchable *no function form@* error and every non-GUI library still works)

## What it is for

A form is the window, and in Phosphor it is also the **owning** handle. Every
other control is built onto a parent and its handle does not own anything; the
form's does, so freeing it at the end of the run frees the whole control tree
underneath it exactly once. That is why this library is small: it registers the
window's own properties — caption, width, height, visibility — and leaves
position, fonts, colours, focus and everything else a *control* has to
`control_*`, which a form answers as readily as a button does.

The shape of the calls is the shape of the whole GUI surface. **A constructor
answers a handle, a setter answers the same handle back, a getter reads the
property.** Because a setter answers its own subject, setters nest and read as one
chain. And the naming does the typing: `form_width@` is the setter (it answers a
handle), `form_width` is the getter (it answers a number).

Errors are values here too, and this library never raises one. A fabricated,
freed or wrong-class handle — a button passed where a form was wanted — is
recorded in `gui_error()` and the call still answers something: a setter answers
the handle it was given, unchanged and unapplied; `form_caption$` answers `""`;
`form_width`, `form_height` and `form_visible` answer `0`. A program checks
`gui_error()` when it wants to know, and `gui_clearerror()` before the next thing
it wants to know about. Nothing in this library aborts a program.

The one behaviour a caller would not guess is what happens to **OnClose**.
`form_show` quietly installs a closer on the form so that shutting the window
ends the message loop, the way a main form would — otherwise the X button would
dispose of the window and leave `app_run()` spinning on a program with nothing to
show. A form has only one OnClose and two things must happen on it, so the closer
does not get replaced when the program binds `form_onclose@`: whichever call comes
first installs the closer, the program's handler runs first when the event fires,
and the terminator runs after it. Unbinding with `""` removes the program's
handler and keeps the terminator. And `form_close@` plus `form_visible` exist so
that all of this is reachable **headless**: a test asks the form to close exactly
as the X does, then reads `form_visible` to see whether the veto handler stopped
it, with no window manager anywhere in the picture.

## Functions

| function | what it answers |
| --- | --- |
| `form@() → handle` · `form@(caption$) → handle` · `form@(caption$, w, h) → handle` | a new top-level window, and the owning handle for it and everything later parented on it. There is no failing case and no in-between arity: `form@("Notes", 480)` matches no overload and fails as an unknown function (code `4`), it does not default the height |
| `form_caption@(f@, s$) → handle` | set the title bar text; answers `f@` so the call chains. On a bad handle: `gui_error()` becomes `1`, nothing is set, and `f@` still comes back |
| `form_caption$(f@) → str` | the title bar text; `""` when the handle is not a live form — indistinguishable from a form whose caption really is empty, so read `gui_error()` if the difference matters |
| `form_width@(f@, n) → handle` | set the window width in pixels; answers `f@`. Bad handle: recorded, unapplied, handle returned |
| `form_width(f@) → num` | the window width; `0` on a bad handle |
| `form_height@(f@, n) → handle` | set the window height in pixels; answers `f@`. Bad handle: recorded, unapplied, handle returned |
| `form_height(f@) → num` | the window height; `0` on a bad handle |
| `form_show@(f@) → handle` | realize the window: install the closer if it is not there yet, then show it. Answers the form, as `form_close@` does. On a bad handle nothing is shown and `gui_error()` is `1`. Headless, it makes the form visible without a window on screen, which is what `form_visible` then reports |
| `form_close@(f@) → handle` | ask the form to close, along exactly the path the X button takes: `form_onclosequery@` first, then `form_onclose@`, then hide. Answers `f@` whether the close happened or was vetoed — ask `form_visible` which it was. Bad handle: nothing is asked |
| `form_visible(f@) → num` | `1` while the form is still up, `0` once it has closed — and `0`, indistinguishably, for a handle that is not a live form |
| `form_onclose@(f@, name$) → handle` | bind the BASIC routine named by `name$` to run when the form actually closes; it is called with one argument, `sender@`, the form's own handle. `""` unbinds it *and still leaves the terminator installed*, so the window keeps ending the program. Answers `f@`; a non-form handle sets `gui_error()` and binds nothing |
| `form_onclosequery@(f@, name$) → handle` | bind a routine that is asked *whether* the form may close; it takes the same single `sender@` argument. **Only an explicit boolean `false` vetoes** — so the routine's name must carry `?` (and the bound string must carry it too, the suffix being part of the name), because a handler that answers anything else, or falls off its end, cannot make a window impossible to close. `""` unbinds it entirely. Answers `f@` |

## A worked example

A window that refuses to close while there is unsaved work. Because the X button
and `form_close@` take the same path, this program's close logic is exercisable by
a headless test that never opens a window.

```basic
rem Save, then close. Closing before saving is refused by the query handler.

dirty? = true

f@ = form@("Notes", 420, 300)
form_height@(form_width@(f@, 480), 320)     rem a setter answers its form, so it nests

b@ = button@(f@)
button_caption@(b@, "Save")
control_bounds@(b@, 20, 20, 120, 32)
button_onclick@(b@, "on_click")

form_onclosequery@(f@, "on_query?")         rem the '?' is part of the name
form_onclose@(f@, "on_close")

form_show@(f@)
println form_caption$(f@) + " is " + str$(form_width(f@)) + "x" + str$(form_height(f@))
println "gui_error = " + str$(gui_error())
app_run()

function on_click(sender@)
  dirty? = false
  form_caption@(f@, "Notes (saved)")
  form_close@(f@)                           rem ask, exactly as the X asks
  return 0
endfunction

function on_query?(sender@)
  if dirty? = true then println "refusing to close: unsaved work"
  return not dirty?
endfunction

function on_close(sender@)
  println "closing " + form_caption$(sender@)
  return 0
endfunction
```

Two things worth noticing:

- **Nothing calls `app_quit()`.** Closing the form ends `app_run()` by itself,
  because `form_show` installed the closer — and `on_close` running first is the
  program seeing the event before the terminator acts on it.
- **The veto is a `?` function, and its handle argument is live.** `sender@` is the
  form itself, not a copy: `form_caption$(sender@)` in `on_close` reads the caption
  the click handler had just written through `f@`.

## Notes

- `form_show` is the one name here whose answer does not match its own suffix: it
  hands back the handle it was given, while its unsuffixed name promises a number.
  Call it as a statement. Assigning it (`n = form_show@(f@)`) is a runtime *cannot
  store handle* type mismatch.
- Handles are watched. If a form is freed while a program still holds handles to
  the controls inside it, those handles resolve to `gui_error() = 1` rather than
  dereferencing a dead pointer — the rule this library states as *a bad handle is
  answered, never raised*.
- The rest of the window's surface is elsewhere: geometry, fonts, focus, the
  parent chain and the six input events in `control_*`; `app_run`, `app_quit`,
  `gui_error` and `gui_clearerror` in gui-core; and every widget you would put on
  a form in its own package under `host/gui/libs/`.
