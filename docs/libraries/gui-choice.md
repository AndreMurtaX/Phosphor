# gui-choice — the controls that pick a value

`host/gui/libs/PhosphorChoiceLib.pas` · 61 functions · GUI only (registered by
`phosphor` when a graphical session is reachable)

## What it is for

The controls that pick a value: check box, radio button, toggle box, combo box,
list box, check list box, and the two grouped-choice boxes — radio group and check
group. Geometry, colour and font are **not** here: those come from
`host/gui/libs/PhosphorControlLib.pas` and work on every control alike. This
library adds only what a chooser has that a button does not — its **state** and its
**item list**.

Eight controls, but only three shapes, and the names repeat on purpose. A
**two-state** control (`checkbox@`, `radiobutton@`, `togglebox@`) has a caption, a
checked flag and an onchange. An **item list with one selection** (`combobox@`,
`listbox@`, `radiogroup@`) has add / count / item / clear plus an itemindex. An
**item list with a check per item** (`checklistbox@`, `checkgroup@`) has the same
item list, but answers per item instead of once. Learn one and the other two are
spelling.

Two conventions decide most of the answers. **Indexing is base-1**: item `n` is the
nth item, `combo_item$(c@, 1)` is the first, and an index outside `1..count`
answers `""` rather than reading past the end. And **0 is a real answer, not an
error** — an itemindex of `0` means *nothing is selected*, which is what a fresh
list, a cleared list and a deselected list all say; setting an itemindex to `0`
selects nothing. That makes the obvious composition safe without a guard:
`radiogroup_item$(rg@, radiogroup_itemindex(rg@))` answers `""` when nothing is
chosen instead of failing.

Nothing here raises. A handle that is not a control of the expected kind is
*checked*, not dereferenced: the constructors then answer handle `0`, the readers
answer the empty answer for their type (`0` or `""`), the mutators do nothing —
and every one of those records the failure in the shared `gui_error()` slot, which
`gui_clearerror()` resets. A mutator answers **the control's own handle**, not a
success flag, so a call can be used as an expression; whether it did anything is a
separate question, asked of `gui_error()` or of the control itself. Note also that
`checked` carries no `?` suffix: it is a number, `1` or `0`.

## Functions

### Two-state controls — check box, radio button, toggle box

The same six operations three times over. A toggle box is a button that stays in
or out; a radio button de-selects its siblings under the same parent, which is the
only behavioural difference between the three.

| check box | radio button | toggle box | what it answers |
| --- | --- | --- | --- |
| `checkbox@(parent@) → handle` | `radiobutton@(parent@) → handle` | `togglebox@(parent@) → handle` | a new control parented to `parent@`. Handle `0` when `parent@` is not a container that can hold children, with `gui_error()` set. The control arrives at the widget set's default position and size — give it bounds with `control_bounds@` |
| `checkbox_caption@(c@, s$) → handle` | `radio_caption@(c@, s$) → handle` | `togglebox_caption@(c@, s$) → handle` | the control, its label text now `s$`. On a wrong handle: nothing changes and `gui_error()` records it |
| `checkbox_caption$(c@) → str` | `radio_caption$(c@) → str` | `togglebox_caption$(c@) → str` | the current caption; `""` on a wrong handle — indistinguishable from a control whose caption really is empty |
| `checkbox_checked@(c@, on) → handle` | `radio_checked@(c@, on) → handle` | `togglebox_checked@(c@, on) → handle` | the control. Any non-zero number ticks it, `0` clears it. Setting it **fires the onchange handler**, exactly as a click would |
| `checkbox_checked(c@) → num` | `radio_checked(c@) → num` | `togglebox_checked(c@) → num` | `1` when ticked, `0` when not — and also `0` on a wrong handle, so check `gui_error()` if the handle is in doubt |
| `checkbox_onchange@(c@, fn$) → handle` | `radio_onchange@(c@, fn$) → handle` | `togglebox_onchange@(c@, fn$) → handle` | the control, with the BASIC function named `fn$` wired to its change event; it is called with one argument, the control's handle — `function on_change(sender@)`. **An empty name unwires the event.** The name is resolved when the event fires, not now: a handler that does not exist, or that fails, records `gui_error()` = 2 rather than ending the program |

### Combo box and list box

Two item lists that answer one selection. They differ in one place each, and that
place is the last two rows.

| combo box | list box | what it answers |
| --- | --- | --- |
| `combobox@(parent@) → handle` | `listbox@(parent@) → handle` | a new control on `parent@`; handle `0` if the parent cannot hold it |
| `combo_add@(c@, s$) → handle` | `list_add@(l@, s$) → handle` | the control, with `s$` **appended** at the end. There is no insert and no remove: items go on the end and come off all at once |
| `combo_count(c@) → num` | `list_count(l@) → num` | how many items there are; `0` for an empty list and `0` for a wrong handle |
| `combo_item$(c@, n) → str` | `list_item$(l@, n) → str` | the text of item `n`, counting from **1**. `""` when `n` is outside `1..count` — silently, without setting `gui_error()`, so an empty item and a bad index read alike |
| `combo_clear@(c@) → handle` | `list_clear@(l@) → handle` | the control, emptied. The selection goes with the items |
| `combo_itemindex@(c@, n) → handle` | `list_itemindex@(l@, n) → handle` | the control, with item `n` selected. **`0` selects nothing** |
| `combo_itemindex(c@) → num` | `list_itemindex(l@) → num` | the 1-based position of the selected item, `0` when nothing is selected |
| `combo_text$(c@) → str` | — | the combo's **edit text**, which is not the same question as the selection: on an editable combo it is whatever the user typed, and need not be one of the items. `""` on a wrong handle |
| — | `list_selected$(l@) → str` | the text of the selected item, `""` when nothing is selected. The same answer as `list_item$` at `list_itemindex`, in one call |
| `combo_onchange@(c@, fn$) → handle` | `list_onclick@(l@, fn$) → handle` | the control, with `fn$` wired — the combo on its **change** event, the list box on its **click**. Empty name unwires |

### Radio group and check group

A bordered, captioned box that owns its buttons and lays them out itself. The radio
group gives **one** answer for the whole box; the check group gives **one per
item**. Both are what a plain container full of radio buttons only approximates,
because the group manages the mutual exclusion and the geometry.

| radio group | check group | what it answers |
| --- | --- | --- |
| `radiogroup@(parent@) → handle`, `radiogroup@(parent@, caption$) → handle` | `checkgroup@(parent@) → handle`, `checkgroup@(parent@, caption$) → handle` | a new group on `parent@`, with the box caption set if given. Handle `0` when the parent cannot hold it |
| `radiogroup_add@(g@, s$) → handle` | `checkgroup_add@(g@, s$) → handle` | the group, with one more button appended. The group creates the button itself; there is no child handle to hold |
| `radiogroup_count(g@) → num` | `checkgroup_count(g@) → num` | how many buttons the group has; `0` when empty or when the handle is wrong |
| `radiogroup_item$(g@, n) → str` | `checkgroup_item$(g@, n) → str` | the caption of button `n`, base-1; `""` outside `1..count` |
| `radiogroup_clear@(g@) → handle` | `checkgroup_clear@(g@) → handle` | the group, emptied of buttons |
| `radiogroup_itemindex(g@) → num` | `checkgroup_checked(g@, n) → num` | the group's one answer: the 1-based button chosen, `0` for none. The check group is asked per button instead — `1` or `0` for button `n`, and an `n` past the end sets `gui_error()` rather than pretending the button exists and is unticked |
| `radiogroup_itemindex@(g@, n) → handle` | `checkgroup_checked@(g@, n, on) → handle` | the group. `0` chooses nothing in a radio group; in a check group any non-zero `on` ticks button `n`, and an out-of-range `n` sets `gui_error()` and changes nothing |
| `radiogroup_caption$(g@) → str` | `checkgroup_caption$(g@) → str` | the caption of the box itself — the border's label, not any button's |
| `radiogroup_caption@(g@, s$) → handle` | `checkgroup_caption@(g@, s$) → handle` | the group, with the box caption set |
| `radiogroup_onchange@(g@, fn$) → handle` | — | the group, with the function named `fn$` called — again as `function on_change(sender@)` — whenever the chosen button changes. Empty name unwires. **The check group has no event**: read its ticks when you need them |

### Check list box

A list box whose every item carries its own tick — the flat, scrolling answer to
the same question the check group asks in a box. Note the spelling: the
constructor is `checklistbox@`, everything else is `checklist_`.

| function | what it answers |
| --- | --- |
| `checklistbox@(parent@) → handle` | a new check list box on `parent@`; handle `0` when the parent cannot hold it |
| `checklist_add@(cl@, s$) → handle` | the control, with `s$` appended, unticked |
| `checklist_count(cl@) → num` | how many items; `0` when empty or on a wrong handle |
| `checklist_item$(cl@, n) → str` | the text of item `n`, base-1; `""` outside `1..count` |
| `checklist_checked@(cl@, n, on) → handle` | the control, item `n` ticked when `on` is non-zero and cleared when it is `0`. An `n` outside `1..count` sets `gui_error()` and changes nothing |
| `checklist_checked(cl@, n) → num` | `1` when item `n` is ticked, `0` when it is not. Also `0` for an index past the end — and unlike the setter, and unlike `checkgroup_checked`, that case is **not** recorded in `gui_error()`. Ask `checklist_count` first if the index came from outside |

## A worked example

An order form: one size out of several, any number of toppings, where to eat it,
and a summary line the controls keep up to date. Save it as `order.bas` and run it
with `phosphor run order.bas`.

```basic
rem --- the window ---
f@ = form@("Order", 380, 300)

rem one answer out of three
sz@ = radiogroup@(f@, "Size")
control_bounds@(sz@, 12, 12, 170, 104)
radiogroup_add@(sz@, "small")
radiogroup_add@(sz@, "medium")
radiogroup_add@(sz@, "large")
radiogroup_itemindex@(sz@, 2)           rem base-1: "medium"
radiogroup_onchange@(sz@, "on_change")

rem one answer per item
tops@ = checkgroup@(f@, "Toppings")
control_bounds@(tops@, 196, 12, 170, 104)
checkgroup_add@(tops@, "cheese")
checkgroup_add@(tops@, "olives")
checkgroup_add@(tops@, "ham")
checkgroup_checked@(tops@, 1, 1)

rem a list with an edit on top of it
mode@ = combobox@(f@)
control_bounds@(mode@, 12, 128, 170, 28)
combo_add@(mode@, "eat in")
combo_add@(mode@, "take away")
combo_itemindex@(mode@, 1)
combo_onchange@(mode@, "on_change")

rush@ = checkbox@(f@)
checkbox_caption@(rush@, "rush it")
control_bounds@(rush@, 196, 132, 170, 24)
checkbox_onchange@(rush@, "on_change")

msg@ = label@(f@, "medium, cheese (eat in)")
control_move@(msg@, 12, 176)

qb@ = button@(f@)
button_caption@(qb@, "Quit")
control_bounds@(qb@, 12, 216, 100, 32)
button_onclick@(qb@, "on_quit")

form_show@(f@)
app_run()

function on_change(sender@)
  rem itemindex answers 0 for "nothing chosen" and item$ answers "" for 0,
  rem so these two compose with no guard between them
  s$ = radiogroup_item$(sz@, radiogroup_itemindex(sz@))
  for i = 1 to checkgroup_count(tops@)
    if checkgroup_checked(tops@, i) = 1 then s$ = s$ + ", " + checkgroup_item$(tops@, i)
  next
  s$ = s$ + " (" + combo_text$(mode@) + ")"
  if checkbox_checked(rush@) = 1 then s$ = s$ + "  RUSH"
  label_caption@(msg@, s$)
  return 0
endfunction

function on_quit(sender@)
  app_quit()
  return 0
endfunction
```

Two things worth noticing:

- **One handler serves three controls.** Wiring is by *name*, not by reference, so
  the same function can be named as often as you like, and `sender@` tells the
  handler which control woke it if it needs to know. Passing `""` instead would
  unwire the event again.
- **The check group is the one control here that cannot tell you.** It has no
  event, so ticking a topping does not run `on_change` — the summary catches up
  the next time the size, the mode or the rush box changes. Read a check group when
  you need its answer; do not wait to be told.

## Notes / Where the rest lives

- **Everything a chooser shares with every other control lives elsewhere.**
  Position, size, colour, font, hint, visibility, focus, disposal and the keyboard
  and mouse events are `control_` functions from
  `host/gui/libs/PhosphorControlLib.pas` — `control_bounds@`, `control_enabled@`,
  `control_setfocus@`, `control_free` and the rest all accept the handles this
  library hands out.
- **Item lists are append-and-clear.** Nothing here inserts at a position or
  removes one item; rebuild the list instead. The check list box does not even have
  a clear — rebuild it by freeing the control, or track what you added.
- **`gui_error()` is a sticky, shared slot.** It holds the last recorded failure
  from any GUI call, so call `gui_clearerror()` immediately before the call you
  intend to check, the way the GUI tests do.
- A wider map of the GUI surface — which LCL components are exposed, which are
  deliberately not, and how the packages are split — is in
  [gui-components.md](../gui-components.md). The tests that pin this library's
  behaviour are `tests/gui/04_choice.bas` (check box, radio button, combo, list),
  `tests/gui/11_more_input.bas` (toggle box, check list box) and
  `tests/gui/14_new_controls.bas` (radio group, check group).
