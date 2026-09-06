# gui-menu — menu bars, context menus, and the strips at the window's edges

`host/gui/libs/PhosphorMenuLib.pas` · 12 functions · GUI package (the `phosphor`
host registers it wherever a graphical session is reachable; on a headless machine
these names are not registered at all)

## What it is for

A window's commands do not live in the window's client area. A **menu bar** hangs
off the form, a **context menu** hangs off the control it pops up on, and a **tool
bar** and a **status bar** are strips glued to the top and the bottom. This package
builds all four, and wires what the user chooses to a BASIC routine.

The unit states the shape of the menu half in the author's own words: `mainmenu@`
answers the form's menu bar, and `menuitem@` answers an item whose **parent decides
what it is** — a main menu gives a top-level item on the bar, another menu item
gives a submenu entry under it, a popup menu gives a context-menu entry. There is
one constructor, not three.

The stance a caller will otherwise be surprised by is that **a menu item is a
`TComponent`, not a `TControl`**. It has no position, no size and no parent
control, so none of the `control_*` helpers apply to it — not even the generic
property bridge `control_set@`, which resolves its handle as a control and refuses.
Its caption and its click therefore live here, as `menuitem_caption@` /
`menuitem_caption$` and `menuitem_onclick@`. The same reasoning explains why
`popupmenu@` takes the control it will belong to: `PopupMenu` is an object-typed
property, so no set-a-property-by-name bridge can reach it, and attaching is
exactly the half the constructor exists to do. `popupmenu_attach@` is the other
half — one menu, several controls.

**Errors are values here, and a mutator answers information rather than a success
flag.** Nothing in this package raises. A handle that is fabricated, freed or of
the wrong class makes a constructor answer handle `0` and records code `1` in the
GUI error slot you read with `gui_error()` (sticky until `gui_clearerror()`); a
reader answers `""`, which is a real answer, so the error slot is where you find
out whether the caption was empty or the handle was wrong. Every mutator answers
**its own subject back**, so calls chain and a failed call still hands you a
handle. Nothing here is freed by the program either: the bar belongs to the form,
an item to its menu, a popup to its control, and each dies with its owner.

Finally, `menuitem_click@` chooses an item **from the program**, firing its
`OnClick` synchronously before the call answers — no window shown, no message loop
running. That is what makes menu wiring testable headless, and it is how
`tests/gui/06_menu_timer.bas` checks it.

## Functions

### The menu bar and its items

| function | what it answers |
| --- | --- |
| `mainmenu@(f@) → handle` | a fresh, empty menu bar, created on that form and installed as its menu. Given anything that is not a form handle it builds nothing, answers handle `0`, and records `gui_error()` `1` |
| `menuitem@(parent@) → handle`, `menuitem@(parent@, caption$) → handle` | one new item appended to `parent@`'s items — a top-level item when the parent is a `mainmenu@`, a submenu entry when it is another item, a context-menu entry when it is a `popupmenu@`. Any other parent (a form, a button, a stale handle) is not a menu: handle `0` and error `1`. Called with one argument the caption starts empty, to be set later |
| `menuitem_caption@(mi@, caption$) → handle` | renames the item and answers **the item**, so work can continue with it. A handle that is not a menu item renames nothing, records error `1`, and still answers what was passed in |
| `menuitem_caption$(mi@) → str` | the caption as it currently reads; `""` for a handle that is not a menu item — read `gui_error()` to tell that apart from a genuinely empty caption |
| `menuitem_onclick@(mi@, handler$) → handle` | run the named BASIC routine when the item is chosen; the routine receives one argument, the sender's handle. `""` **unwires** it, and wiring again replaces the previous routine. A routine that fails records error `2` instead of aborting the program. Answers the item |
| `menuitem_click@(mi@) → handle` | choose the item programmatically: its handler runs synchronously, in this call, whether or not a window is on screen. With nothing wired it does nothing; with a handle that is not a menu item it does nothing and records error `1`. Either way it answers the handle it was given |

### A context menu

| function | what it answers |
| --- | --- |
| `popupmenu@(ctl@) → handle` | a new, empty context menu created **on** that control and installed as its popup in the same call — the attaching is the point. Fill it with `menuitem@`. Given a handle that is not a control: `0` and error `1` |
| `popupmenu_attach@(pm@, ctl@) → handle` | point a second control at an existing popup, so one menu serves several. Answers the **menu**. If either handle fails to resolve nothing is attached, error `1` is recorded, and the answer is still that first handle |

### The strips at the edges

| function | what it answers |
| --- | --- |
| `toolbar@(parent@) → handle` | a top-aligned tool bar on any window control — a form or a panel. It is a container, not a widget of its own: put ordinary `button@` or `speedbutton@` controls on it with the tool bar as their parent, and point it at icons with `imagelist_attach@`. A parent that is not a window control (a `label@`, say) gives `0` and error `1` |
| `statusbar@(parent@) → handle` | a status strip at the bottom of a window control, configured for **one line of text**, not an array of panels. A parent that is not a window control gives `0` and error `1` |
| `statusbar_text@(sb@, text$) → handle` | write that line, and answer the status bar. A handle that is not a status bar writes nothing, records error `1`, and still answers the handle |
| `statusbar_text$(sb@) → str` | what the line currently reads; `""` for a handle that is not a status bar |

## A worked example

A window whose commands all arrive through menus: a File menu on the bar, the same
Open on a tool bar button, a context menu on the text box, and a status bar
reporting whatever was chosen last. Before the window is ever shown, the program
chooses File > Open itself and prints the result.

```basic
rem   phosphor run menus.bas
opened = 0

f@ = form@("Menus", 480, 320)

rem --- the bar, a top-level item, two items under it ---
mm@    = mainmenu@(f@)
mfile@ = menuitem@(mm@, "File")
mopen@ = menuitem@(mfile@, "Open")
mquit@ = menuitem@(mfile@, "Quit")
menuitem_caption@(mopen@, "Open...")      rem a caption is writable afterwards
menuitem_onclick@(mopen@, "on_open")
menuitem_onclick@(mquit@, "on_quit")

rem --- the strip at the top: a container for ordinary buttons ---
tb@     = toolbar@(f@)
tbopen@ = button@(tb@)
button_caption@(tbopen@, "Open")
button_onclick@(tbopen@, "on_open")       rem the very same handler as the menu

rem --- the strip at the bottom: one line of text ---
sb@ = statusbar@(f@)
statusbar_text@(sb@, "Ready")

rem --- a context menu, created ON the control it pops up on ---
notes@ = memo@(f@)
control_bounds@(notes@, 10, 46, 460, 190)
pm@     = popupmenu@(notes@)
mclear@ = menuitem@(pm@, "Clear")
menuitem_onclick@(mclear@, "on_clear")

rem --- self-check: choose it from the program, no window needed ---
menuitem_click@(mopen@)
println "wiring: " + statusbar_text$(sb@) + "   (gui_error " + str$(gui_error()) + ")"

form_show@(f@)
app_run()

function on_open(sender@)
  opened = opened + 1
  statusbar_text@(sb@, "Open chosen " + str$(opened) + "x")
  return 0
endfunction

function on_clear(sender@)
  memo_text@(notes@, "")
  statusbar_text@(sb@, "Notes cleared")
  return 0
endfunction

function on_quit(sender@)
  app_quit()
  return 0
endfunction
```

Two things worth noticing:

- **The self-check line runs before `form_show`.** `menuitem_click@` reaches the
  handler synchronously, so the status bar already reads `Open chosen 1x` while
  nothing is on screen. A menu's wiring can be tested without a user, a window or a
  message loop.
- **Nothing binds a handler to one widget.** The menu item and the tool bar button
  both name `on_open`; each passes its own sender handle, so one routine serves
  both entry points, which is what a tool bar is for.

## Notes

- **What a menu item still cannot do.** This package exposes a menu item's caption
  and its click, and nothing else. `Checked`, `ShortCut` and `Enabled` have no path
  today: the generic bridge `control_set@` resolves its first argument as a
  `TControl`, and a `TMenuItem` is not one, so it answers error `1` rather than
  setting the property.
- **A status bar carries one string.** It is created with the LCL's simple-panel
  mode on purpose, so `statusbar_text@` writes *the* text; there is no panel array
  and no per-panel addressing.
- **Removal is not here.** There is no function to delete an item or a menu. A menu
  bar lives as long as its form, a popup as long as its control, an item as long as
  the menu it was added to.
- **`gui_error()` is sticky.** Every failure above records a code and leaves it
  there; call `gui_clearerror()` before a call whose outcome you intend to test, as
  the GUI suite does.

## Where the rest lives

`gui_error()`, `gui_clearerror()`, `app_run()`, `app_processmessages()` and
`app_quit()` belong to the GUI core package, not this one. Which LCL components
Phosphor exposes, and which it deliberately does not, is
[gui-components.md](../gui-components.md); the toolbar's icons come from
`imagelist@` and its `imagelist_attach@`, which live with the image package.
