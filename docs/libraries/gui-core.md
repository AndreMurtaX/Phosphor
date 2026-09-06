# gui-core — the message loop, and the error slot every GUI package shares

`host/gui/libs/PhosphorGuiCore.pas` · 5 functions · GUI package (the `phosphor`
host registers the GUI wherever a graphical session is reachable — always on
Windows, `DISPLAY` or `WAYLAND_DISPLAY` elsewhere; where it is not, these names
simply do not exist and every non-GUI name still works)

## What it is for

This unit is the foundation the other sixteen GUI packages stand on, and almost
all of it is invisible from BASIC. It holds two mechanisms: the **control handle**
(an LCL object wrapped so the engine's ordinary `@` handle registry can free a
whole control tree exactly once — only a form's wrapper owns its control, because
LCL frees children with their parent) and the **event bridge** (an object owned by
the control it serves, which calls a BASIC routine by name through the engine's
host-callback seam). Both are Pascal. What it registers for a program to call is
just five verbs: the three that drive the message loop, and the two that read and
reset the GUI's error state.

The design stance is the phase-1 contract, held to across the whole GUI surface:
**no exception ever crosses into BASIC**. A fabricated handle, a handle whose form
was freed underneath it, a handle of the wrong class, an index past the end, a
property that is not published — every one of them is *recorded* in a single
shared slot and answered with a benign value (`""`, `0`), never raised. `gui_error()`
reads that slot. It is shared deliberately: with one handle registry and one
resolver behind every package, nearly every GUI failure is "this handle is not a
live control of the expected class", and one slot says that for all seventeen
packages instead of seventeen parallel slots saying it separately.

The slot is **sticky**, like `err()`. Nothing clears it but `gui_clearerror()` — a
later successful call does not. So the useful shape is *clear, act, ask*: the test
corpus calls `gui_clearerror()` immediately before the call whose outcome it wants
to judge, then reads `gui_error()`. Reading it after ten calls tells you only that
one of the ten failed.

The loop deserves one warning. `app_run()` is **Phosphor's own loop**, not LCL's
`Application.Run`, and `app_quit()` deliberately does *not* terminate the
application — it only asks the loop to return. That is what makes `app_run()`
re-enterable: a host that runs one script after another, or an embedder that
drives the engine between loops, gets a GUI that is still a GUI the second time.
The one thing that *does* terminate the application is `end` inside an event
handler, which has to end the program the window was clicked in, window included.

## Functions

| function | what it answers |
| --- | --- |
| `app_run() → num` | enter the message loop and dispatch events until something leaves it. Returns `0` when it does. It is left by `app_quit()` **or** by the application terminating — which is what closing the last window does, and what `end` in a handler does. There is no timeout: with no window shown and no path to `app_quit()`, it does not return |
| `app_processmessages() → num` | dispatch everything currently pending and come straight back, so a long computation can keep its window alive without entering the loop. Always `0`; with nothing pending it does nothing and still answers `0` |
| `app_quit() → num` | ask the running `app_run()` to return. Always `0`. It leaves the application usable — a later `app_run()` enters the loop normally. Called when no loop is running it is harmless: `app_run()` clears the request on entry, so it cannot poison the next loop |
| `gui_error() → num` | the code of the last GUI failure, `0` if none since the last clear. `1` a handle that is not a live object of the expected class (fabricated, freed with its form, wrong class), an index outside the control's range, or an operation the control refused; `2` a bound BASIC handler that failed at run time — the event still returned, the failure is here; `3` the named property is not published on that control, or is of a kind the property bridge cannot reach. Reads a slot shared by every GUI package, not only this one |
| `gui_clearerror() → num` | set that slot back to `0`. Always answers `0`. The only thing that clears it |

## A worked example

A window with two buttons and a status line. The interesting part is the bottom
of the script: `app_run()` blocks there, the handlers run *inside* it, and the
program carries on at the next line once one of them asks to quit.

```basic
rem A counter window. on_click updates a label; on_done leaves the loop.
clicks = 0

f@ = form@("gui-core", 320, 170)

b@ = button@(f@)
button_caption@(b@, "Click me")
control_bounds@(b@, 20, 20, 130, 32)

q@ = button@(f@)
button_caption@(q@, "Done")
control_bounds@(q@, 170, 20, 130, 32)

status@ = label@(f@, "no clicks yet")
control_move@(status@, 20, 74)

rem Clear, act, ask: the slot is sticky, so it is only meaningful about the
rem calls made since the clear.
gui_clearerror()
button_onclick@(b@, "on_click")
button_onclick@(q@, "on_done")
if gui_error() <> 0 then println "wiring failed, code " + str$(gui_error())

form_show(f@)
app_run()                  rem blocks here until on_done calls app_quit()

println "closed after " + str$(clicks) + " clicks"

function on_click(sender@)
  clicks = clicks + 1
  label_caption@(status@, str$(clicks) + " clicks")
  return 0
endfunction

function on_done(sender@)
  app_quit()
  return 0
endfunction
```

Two things worth noticing:

- **A handler that fails does not abort the program.** If `on_click` divided by
  zero, the click would still return to LCL and the window would still be usable;
  what changes is that `gui_error()` becomes `2`. That is the only way a program
  learns a handler broke.
- **Closing the window works too.** The X button terminates the application,
  which also ends `app_run()`, so the `println` after it runs whether the user
  pressed *Done* or closed the window.

## Notes

`app_processmessages()` and the engine's own `processmessages()` reach the same
pump here — the `phosphor` host installs LCL's as the engine's host-services pump,
so a console-side library can keep a window responsive without naming the GUI.
The engine one is always registered and answers `1` or `0` for *whether a host
supplied a pump at all*; this one exists only when the GUI does. See
[host.md](host.md).

Everything else in this unit is reached through the other GUI pages, never by
name: the handle wrapper is why `control_free` and the end of a run can dispose a
whole tree once, and the event bridge is what `button_onclick@`, `form_onclose@`,
`timer_ontimer@` and the rest hand their handler name to. One bridge exists per
control per event, so a control can carry several events at once, and binding
`""` unwires one. The full component inventory and the event/handle model live in
[gui-components.md](../gui-components.md).
