# gui-misc — the calendar, the colour button, and the tray icon

`host/gui/libs/PhosphorMiscLib.pas` · 13 functions · GUI package, registered by the
`phosphor` host wherever a graphical session is reachable (always on Windows; on
Unix when `DISPLAY` or `WAYLAND_DISPLAY` is set), and by the headless GUI test
runner

## What it is for

The unit says it in one line: **controls that do not belong to a larger family.**
Every other GUI package covers a *kind* of widget — buttons, edits, containers,
ranges, dialogs. Three LCL controls were left over, each too small to earn a
package of its own and with nothing in common but that: a month grid
(`TCalendar`), a button that carries a colour and opens the colour dialog when you
press it (`TColorButton`), and a notification-area icon (`TTrayIcon`). This page
is the whole of that leftovers drawer.

The shape is the one every GUI package uses. A constructor takes the parent it
should live on and answers a **handle**; a property is a **pair of names that
differ only by suffix** — `calendar_date@` writes, `calendar_date` reads — and the
writer answers **the handle it just changed**, not a success flag, so calls chain
and no caller ever writes `if ... then` around a setter. Nothing here raises:
a handle that is dead, fabricated, or of the wrong class is *answered* — the
constructor gives handle `0`, a getter gives `0` or `""`, a setter gives its
argument back untouched — and the shared `gui_error()` becomes `1`. That is how
you tell a colour that really is `0` from a question that could not be asked;
`gui_clearerror()` puts it back to `0`. Both live in [gui-core.md](gui-core.md).

Dates and colours are plain numbers, not wrapper objects. A calendar's date is a
**date serial** — the same number `today()`, `strtodate()` and `datetostr$()`
speak — so the entire [date-time](date-time.md) library applies to it unchanged.
A colour is an LCL `TColor`, packed **blue × 65536 + green × 256 + red**: `255` is
red, not blue, and `16777215` is white. There is no `rgb`-style helper anywhere in
Phosphor, so those are the numbers you write. Pressing a colour button opens the
widget set's own colour dialog by itself — the program neither has to call
`colordialog@` nor gets a hook when the user picks; you read `colorbutton_color()`
back at the moment it matters.

The tray icon is the odd one and worth a paragraph. It has **no parent**:
`trayicon@()` takes no argument, appears on no form, and lives in the desktop's
notification area for exactly as long as its handle does — so closing the window
does not remove it, and `control_free()` is what does. It starts **hidden**, so
`trayicon_show@` is a required step rather than a nicety. And being *clicked*
needs a running message loop, which is why the headless suite can pin its
configuration (hint, visibility) but never its click. This package sets no image:
the icon's picture is not exposed, so what is drawn for it is whatever the widget
set draws for an icon that was never assigned one.

## Functions

### The calendar

| function | what it answers |
| --- | --- |
| `calendar@(parent@) → handle` | a new month grid parented on `parent@`. A handle that is not a live window-capable control builds nothing and answers the nil handle `0`, with `gui_error()` set to `1` |
| `calendar_date@(cal@, d) → handle` | show the day `d` names, `d` being a date serial. Answers `cal@` itself, always — on a handle that is not a calendar it is a no-op you can only detect through `gui_error()` |
| `calendar_date(cal@) → num` | the day currently shown, as a date serial; `0` when the handle is not a live calendar. The widget stores a **day, not an instant**, so a time fraction you wrote is not promised back — the test corpus asserts this round trip to within half a day, not exactly |

### The colour button

| function | what it answers |
| --- | --- |
| `colorbutton@(parent@) → handle` | a new colour button on `parent@`; handle `0` and `gui_error() = 1` when the parent cannot host a child. Clicking it opens the colour dialog with no code from you |
| `colorbutton_color@(cb@, c) → handle` | set the colour it shows and offers, `c` being a `TColor` number. Answers `cb@`; a wrong-class handle changes nothing and only `gui_error()` says so |
| `colorbutton_color(cb@) → num` | the colour it carries now — the user's choice, if they have made one. `0` for a dead or wrong-class handle, which is also the number for black: check `gui_error()` if the difference matters |

### The tray icon

| function | what it answers |
| --- | --- |
| `trayicon@() → handle` | a notification-area icon, **hidden**, with no parent and no owner but its handle. No arguments, and no failure case reachable from BASIC |
| `trayicon_hint$(ti@) → str` | its tooltip; `""` when none was set — and `""` too when the handle is not a tray icon, with `gui_error()` set |
| `trayicon_hint@(ti@, hint$) → handle` | set that tooltip; answers `ti@`, whether or not there was a tray icon behind it |
| `trayicon_visible(ti@) → num` | `1` while it is in the notification area, `0` while hidden — and `0` for a handle that is not a tray icon at all |
| `trayicon_show@(ti@) → handle` | put it in the notification area. Answers `ti@`; a bad handle shows nothing and sets `gui_error()` |
| `trayicon_hide@(ti@) → handle` | take it back out, without freeing it — `trayicon_show@` can put it back. Answers `ti@` |
| `trayicon_onclick@(ti@, handler$) → handle` | call the BASIC function named `handler$` when the icon is clicked, passing it one argument: the tray icon's own handle. An **empty name unwires** the event. Answers `ti@`. Firing needs a running message loop (`app_run()`), so under the headless runner this binds and never fires |

## A worked example

A one-window reminder: pick a day, pick the colour the note should be written in,
and leave a tray icon behind that can repeat the reminder on demand.

```basic
rem Run it:  phosphor run reminder.bas

f@ = form@("Reminder", 380, 320)

cal@ = calendar@(f@)
control_bounds@(cal@, 20, 20, 340, 190)
calendar_date@(cal@, today())

cb@ = colorbutton@(f@)
control_bounds@(cb@, 20, 224, 90, 30)
colorbutton_color@(cb@, 8388608)          rem TColor is $00BBGGRR -- dark blue

set@ = button@(f@)
button_caption@(set@, "Set reminder")
control_bounds@(set@, 124, 224, 236, 30)
button_onclick@(set@, "on_click")

note@ = label@(f@, "nothing set yet")
control_move@(note@, 20, 268)

ti@ = trayicon@()
trayicon_hint@(ti@, "Reminder -- nothing set")
trayicon_onclick@(ti@, "on_show")
trayicon_show@(ti@)

if gui_error() <> 0 then println "some control could not be built"

form_show(f@)
app_run()

rem The window is gone; the icon is not. Take it out deliberately.
control_free(ti@)

function on_click(sender@)
  when$ = datetostr$(calendar_date(cal@))
  control_fontcolor@(note@, colorbutton_color(cb@))
  label_caption@(note@, "reminder for " + when$)
  trayicon_hint@(ti@, "Reminder -- " + when$)
  return 0
endfunction

function on_show(sender@)
  msgbox(trayicon_hint$(sender@))
  return 0
endfunction
```

Two things worth noticing:

- **Nothing in it checks a setter.** Every `..._@` call answers the handle it
  changed, so there is no flag to test; the single `gui_error()` after the
  constructors covers the only failure this program can actually have — a control
  that was never built.
- **The tray icon is not part of the window.** It is created without a parent,
  survives `app_run()` returning, and is removed by `control_free()` at the end —
  the one control on this page whose lifetime the program has to think about.
  Its handler is reached only through a real click, which is why the headless
  suite asserts its hint and its `trayicon_visible` and stops there.

## Notes

- `calendar_date@` names a *day*: `today()` is fine to pass, and so is any serial
  from the date-time library, but the time inside one is the widget's to discard.
- The colour button and the standalone `colordialog@` in the dialogs package are
  two ways to reach the same picker. The button is the one that needs no event
  wiring at all; the dialog is the one you can title, preset and execute yourself.
- `control_free()`, `control_bounds@`, `control_move@` and `control_fontcolor@`
  used above are the shared control surface, described in
  [gui-control.md](gui-control.md); every handle on this page accepts them.
