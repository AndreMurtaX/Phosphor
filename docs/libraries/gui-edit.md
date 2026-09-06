# gui-edit — the text-entry controls: edit, memo, spin and mask

`host/gui/libs/PhosphorEditLib.pas` · 37 functions · GUI package (registered only
where a graphical session is reachable; headless, these names are simply absent)

## What it is for

This is where a program **takes typed input**. The unit header states the split it
works to: geometry, colour, font, enabled and visible all come from the shared
backbone (`PhosphorControlLib` — `control_bounds@`, `control_move@`,
`control_fontsize@` and friends); this package adds only what is particular to a
text control — its **text**, the memo's **line access**, and the **onchange**
event. So building an edit is always two libraries: one call here to create it,
one call there to place it.

Five families live here, all built on the same LCL text widget. `edit@` is a
single-line box. `memo@` is a multi-line one that also answers its lines
individually, **1-based** like every other index in Phosphor. `spinedit@` is an
integer box with arrows, `floatspinedit@` its fractional sibling, and `maskedit@`
a box that enforces a shape as you type.

The design stance is the GUI backbone's, and it is worth stating plainly because
it is the opposite of what a widget library usually does: **a bad handle is
answered, never raised.** Hand `edit_text$` a handle that is not an edit — a
freed control, a form, a number a program made up — and it answers `""`; hand a
getter one and it answers `0`; hand a constructor a parent that is not a windowed
container and it answers handle `0`. Nothing throws, nothing prints. What is
recorded is `gui_error()`, which becomes `1` and **stays** `1` until
`gui_clearerror()`. So the way to check a build sequence is to build the whole
form and then ask once, not to test each call.

The mutators follow the project's other rule: **a mutator answers information, not
a success flag.** Every `@`-suffixed setter here answers the control's own handle,
so calls chain and a handle need never be re-stated. And every one of them that
touches the text **fires the onchange handler immediately** — synchronously, with
no message loop involved — which is why a handler that writes to the control it
is watching re-enters itself.

## Functions

### The single-line edit

| function | what it answers |
| --- | --- |
| `edit@(parent@) → handle` | a new empty single-line box parented to `parent@`. Handle `0` and `gui_error() = 1` when `parent@` is not a windowed container (a form, a panel, a scrollbox) |
| `edit_text@(e@, s$) → handle` | replaces the whole text and answers `e@`. Fires `onchange` before it returns. A handle that is not an edit changes nothing and still answers `e@` |
| `edit_text$(e@) → str` | what is in the box now; `""` for a box that is empty **and** `""` for a handle that is not an edit — the two are indistinguishable, so ask `gui_error()` if the difference matters |
| `edit_readonly@(e@, n) → handle` | locks the box against typing when `n` is any non-zero number, unlocks it at `0`. It stays selectable and copyable; readonly is not disabled |
| `edit_readonly(e@) → num` | `1` when locked, `0` when not — and `0` for a handle that is not an edit |
| `edit_maxlength@(e@, n) → handle` | caps how many characters the **user** may type. `0` means no cap. It does not truncate a longer string set through `edit_text@` |
| `edit_maxlength(e@) → num` | the cap, `0` when there is none; `0` for a bad handle |
| `edit_selectall@(e@) → handle` | selects the whole text, the usual prelude to letting a keystroke replace it. On an unrealized or unfocused control there is nothing to show for it; it answers `e@` either way |
| `edit_clear@(e@) → handle` | empties the box — the same end state as setting `""`, and it fires `onchange` the same way |
| `edit_onchange@(e@, name$) → handle` | wires text changes to the BASIC function called `name$`, which takes one argument — the sender's handle. An **empty name unwires** the event. The name is not checked here — it is looked up when the event fires, and a handler that is missing or that fails sets `gui_error()` to `2` rather than raising |

### The memo

| function | what it answers |
| --- | --- |
| `memo@(parent@) → handle` | a new empty multi-line box parented to `parent@`; handle `0` and `gui_error() = 1` on a parent that cannot hold a control |
| `memo_text@(m@, s$) → handle` | replaces the whole content, splitting `s$` on line breaks into lines |
| `memo_text$(m@) → str` | every line joined by the **host's own line ending** — CRLF on Windows, LF elsewhere — with a trailing one after the last line. A memo of `"one"`, `"two"` answers `"one⏎two⏎"`, not `"one⏎two"`. Compare per line with `memo_line$` if you want the same answer on both platforms |
| `memo_addline@(m@, s$) → handle` | appends one line and answers `m@`. This is the cheap way to build content; `memo_text@` in a loop rewrites everything each time |
| `memo_linecount(m@) → num` | how many lines there are — which, being 1-based, is also the index of the last one. `0` for an empty memo and `0` for a bad handle |
| `memo_line$(m@, n) → str` | line `n`, counting from **1**. `""` when `n` is `0`, negative, or past the end — an out-of-range line is answered, not an error |
| `memo_clear@(m@) → handle` | drops every line; `memo_linecount` returns to `0` |
| `memo_wordwrap@(m@, n) → handle` | wraps long lines at the box width when `n` is non-zero, `0` gives a horizontal scroll instead. Wrapping is display only: it never changes `memo_linecount` |
| `memo_wordwrap(m@) → num` | `1` when wrapping, `0` when not. A fresh memo answers `1` — the LCL wraps by default |
| `memo_readonly@(m@, n) → handle` | locks the memo against typing; the program's own `memo_addline@` and `memo_clear@` still work, which is what makes a readonly memo the natural log pane |
| `memo_readonly(m@) → num` | `1` when locked, `0` when not, `0` for a bad handle |
| `memo_onchange@(m@, name$) → handle` | wires content changes to the BASIC function called `name$`, which takes the sender's handle; empty name unwires. It fires for the program's own edits too, `memo_addline@` included |

### The spin edits

| function | what it answers |
| --- | --- |
| `spinedit@(parent@) → handle` | a new integer box with up/down arrows; handle `0` on a bad parent |
| `spinedit_value@(s@, n) → handle` | sets the number. A spin edit is integer-valued: a fractional argument is **rounded**, not truncated — `3.7` stores `4`. Use `floatspinedit@` when the fraction matters |
| `spinedit_value(s@) → num` | the number in the box, `0` for a bad handle |
| `spinedit_min@(s@, n) → handle` | the low end of the range the arrows and the widget's own clamping respect |
| `spinedit_max@(s@, n) → handle` | the high end. The range only binds once max is greater than min — a fresh spin edit has both at `0`, which the LCL reads as "no range at all" |
| `spinedit_onchange@(s@, name$) → handle` | wires value changes to the BASIC function called `name$`, which takes the sender's handle; empty name unwires |
| `floatspinedit@(parent@) → handle` | a new fractional spin box; handle `0` on a bad parent |
| `floatspinedit_value@(fs@, x) → handle` | sets the number, fraction kept |
| `floatspinedit_value(fs@) → num` | the number, `0` for a bad handle. It reads back to the precision the box is showing, so set the decimals **before** the value, not after |
| `floatspinedit_decimals@(fs@, n) → handle` | how many decimal places the box displays and keeps. The LCL default is `2` |

### The mask edit

| function | what it answers |
| --- | --- |
| `maskedit@(parent@) → handle` | a new box that enforces a shape as the user types; handle `0` on a bad parent |
| `maskedit_text@(me@, s$) → handle` | sets the content **through** the mask. Give it the value already punctuated the way the mask shows it — the mask matches on its own literals, and a segment whose literal it cannot find comes back blank rather than shifted |
| `maskedit_text$(me@) → str` | the content **including** the mask's literal characters — `"01/01/2026"`, not `"01012026"` — unless the mask carries the LCL's `;0` "do not save literals" flag. `""` for a bad handle |
| `maskedit_mask@(me@, s$) → handle` | sets the mask. `0` a required digit, `9` an optional one, `L`/`A` letters, `C` any character, anything else a literal; an optional `;save;blank` tail (as in `"00/00/0000;0;_"`) says whether the literals are part of the text and what an unfilled position looks like. An empty mask turns the control back into a plain edit |
| `maskedit_mask$(me@) → str` | exactly the string that was set, tail and all — not the parsed mask |

## A worked example

A small "new entry" form: a name, a quantity, a unit price, a due date, and a
read-only memo that logs the state after every change. It uses all five families
at once, and it is the shape most data-entry windows end up having.

```basic
rem A data-entry form. Run it:  phosphor run entry.bas

f@ = form@("New entry", 470, 420)

lbl@ = label@(f@, "Name:")
control_move@(lbl@, 16, 20)
name@ = edit@(f@)
control_bounds@(name@, 110, 16, 330, 26)
edit_maxlength@(name@, 40)
edit_text@(name@, "widget")

qty@ = spinedit@(f@)
control_bounds@(qty@, 110, 52, 90, 26)
spinedit_min@(qty@, 1)
spinedit_max@(qty@, 999)
spinedit_value@(qty@, 1)

price@ = floatspinedit@(f@)
control_bounds@(price@, 110, 88, 110, 26)
floatspinedit_decimals@(price@, 2)      rem decimals first, then the value
floatspinedit_value@(price@, 9.95)

due@ = maskedit@(f@)
control_bounds@(due@, 110, 124, 130, 26)
maskedit_mask@(due@, "00/00/0000")
maskedit_text@(due@, "01/01/2026")      rem punctuated the way the mask shows it

log@ = memo@(f@)
control_bounds@(log@, 16, 170, 438, 210)
memo_readonly@(log@, 1)                 rem the user cannot type; the program still can
memo_wordwrap@(log@, 0)
memo_addline@(log@, "ready — mask is " + maskedit_mask$(due@))

rem Ask once, after the whole form is built: gui_error is sticky.
if gui_error() <> 0 then println "a control did not build"
gui_clearerror()

rem Wire the events LAST, so the setup above does not log itself.
edit_onchange@(name@, "on_edit")
spinedit_onchange@(qty@, "on_edit")

form_show@(f@)
app_run()

function on_edit(sender@)
  line$ = edit_text$(name@) + " x" + str$(spinedit_value(qty@))
  line$ = line$ + " @ " + str$(floatspinedit_value(price@))
  line$ = line$ + " due " + maskedit_text$(due@)
  memo_addline@(log@, line$)
  rem keep the log bounded; linecount is 1-based, so it is also the last index
  if memo_linecount(log@) > 200 then memo_clear@(log@)
  return 0
endfunction
```

Two things worth noticing:

- **The events are wired after the setup, on purpose.** `edit_text@` and
  `spinedit_value@` fire `onchange` synchronously, so wiring first would have made
  the form log four lines about itself before the user touched anything. The same
  trap bites the other way inside a handler: an `on_edit` that called
  `edit_text@(name@, …)` would re-enter itself.
- **The memo is readonly and still written to.** `memo_readonly@` stops the *user*
  typing, not the program — `memo_addline@`, `memo_clear@` and `memo_text@` all
  keep working. That is what makes a memo the log pane rather than a second input.

## Notes

**Only some things have getters.** `spinedit_min@` and `spinedit_max@` are
write-only — there is no `spinedit_min`/`spinedit_max` to read them back, so a
program that needs its own bounds later must remember them. Likewise
`floatspinedit_decimals@` sets but does not report, and the float spin edit has no
min/max at all. This is deliberate scope, not an oversight: what the reference
corpus actually reached for was set, shown and read.

**Only three of the five families raise an event.** `edit_onchange@`,
`memo_onchange@` and `spinedit_onchange@` exist; `floatspinedit@` and `maskedit@`
have none. To notice those changing, poll them from a button or a timer handler.
All three that do exist are host-aware — they need the running VM to call back
into BASIC — so they are registered with `AddHost`, which a program never sees
except in that they are meaningless outside a running program.

**Where the rest of a text control lives.** Position, size, colour, font, focus,
tab order, enabled and visible are not here: they are the shared control backbone
every GUI widget gets, and they work on an edit exactly as on a button. Which
widget families exist, and why these ones, is the subject of
[gui-components.md](../gui-components.md).
