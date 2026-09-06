# gui-container — the controls that hold other controls

`host/gui/libs/PhosphorContainerLib.pas` · 28 functions · a GUI package, registered
wherever the host can bring a widgetset up

## What it is for

A container is not a special kind of object with an API of its own. It is a control
that is *also a legal parent*: each one here is a `TWinControl`, so any child
constructor — `button@`, `edit@`, `label@`, another container — accepts its handle
where it would accept a form's, and every shared helper in
[gui-control.md](gui-control.md) (`control_bounds@`, `control_align@`,
`control_visible@`, the font and event helpers) works on it unchanged. That is why
this package is thin: it adds construction and the container-specific bits only — a
caption, a notebook's pages, a row of tabs.

**Two kinds of tabs, and they are not the same thing.** `pagecontrol@` gives every
tab a real page: `tabsheet@` builds one, controls are parented on the *sheet*, and
the widgetset swaps them when the user clicks a tab — the program is not involved.
`tabcontrol@` is the flat sibling: one page, a row of tabs, and no sheet at all. It
owns nothing to swap, so the program does the swapping itself in
`tabcontrol_onchange@`. Reach for the notebook when each tab holds *different*
controls, and for the flat one when every tab shows the *same* controls over
different data — a per-server form, a per-month sheet.

The stance is the one the rest of the GUI takes. Selections are **base-1**:
`pagecontrol_pageindex` and `tabcontrol_tabindex` answer `1` for the first tab and
**`0` for "nothing selected"** — never the LCL's `-1`. A **mutator answers the handle
it was given**, not a success flag, so calls chain and "did it work" is a separate
question, asked of `gui_error()`. And a handle that is fabricated, already freed, or
names something else is **answered, never raised**: a constructor hands back handle
`0`, a string getter `""`, a number getter `0`, and `gui_error()` is left at `1`. A
program can therefore build a whole window without a single guard and check once at
the end.

Two things would otherwise surprise a caller. `bevel_shape` and `bevel_style` are
**raw LCL enum ordinals starting at 0** — they are constants, not indices, so base-1
does not apply to them, and a value outside the enum is ignored rather than clamped.
And `splitter@` and `bevel@` are in this package for where they are *used*, not for
what they are: neither holds children. They are the furniture that goes between
containers.

## Functions

Throughout, `parent@` is any window-owning control (a form, a panel, a tab sheet),
`pc@` a page control, `tc@` a tab control, and `i`/`n` are base-1 positions except
where a row says otherwise.

### Plain containers

| function | what it answers |
| --- | --- |
| `panel@(parent@) → handle` | a blank panel on `parent@`, its caption explicitly cleared so a panel used as a plain surface draws no text. Handle `0`, and `gui_error()` `1`, when `parent@` cannot be a parent |
| `panel_caption@(p@, text$) → handle` | sets the text drawn across the panel and gives `p@` straight back, so the call chains. A handle that is not a panel changes nothing and is recorded, not raised |
| `panel_caption$(p@) → str` | that text. `""` both for a panel with no caption and for a handle that is not a panel — `gui_error()` is what tells those two apart |
| `groupbox@(parent@) → handle` | a titled frame that groups the controls built inside it. `0` on a parent it cannot use |
| `groupbox_caption@(g@, text$) → handle` | sets the title drawn into the frame's top edge; answers `g@` |
| `groupbox_caption$(g@) → str` | that title, `""` when there is none or the handle is not a group box |
| `scrollbox@(parent@) → handle` | a surface that grows scroll bars when its children do not fit. It has no caption of its own — it is a viewport, not a label. `0` on a bad parent |

### A notebook with a page per tab

| function | what it answers |
| --- | --- |
| `pagecontrol@(parent@) → handle` | an empty notebook — no pages until `tabsheet@` adds one. `0` on a bad parent |
| `tabsheet@(pc@, caption$) → handle` | a new page, appended, carrying `caption$` on its tab. The first argument must be a **page control** specifically: a form or a panel is not one, so it answers `0` and records the error. The caption is not optional — there is one signature and it takes both arguments |
| `tabsheet_caption@(t@, text$) → handle` | renames the tab afterwards; answers `t@` |
| `tabsheet_caption$(t@) → str` | the tab's text, `""` for a handle that is not a tab sheet |
| `pagecontrol_pagecount(pc@) → num` | how many pages it holds. `0` for a fresh notebook, and `0` again for a handle that is not one |
| `pagecontrol_pageindex(pc@) → num` | which page is showing, base-1. `0` when the notebook is empty or nothing is active — the LCL's `-1` never reaches BASIC |
| `pagecontrol_pageindex@(pc@, n) → handle` | show page `n`. `n = 0` shows none; an `n` that names no page is **ignored** — the current page stays and nothing is recorded, so read the value back if it matters. Answers `pc@` |

### Flat tabs over one shared page

| function | what it answers |
| --- | --- |
| `tabcontrol@(parent@) → handle` | a tab strip with no pages behind it, and no tabs yet. `0` on a bad parent |
| `tabcontrol_add@(tc@, caption$) → handle` | appends a tab with that caption and answers `tc@`, so a run of adds reads as one block. No page is created — that is the whole point of this control |
| `tabcontrol_count(tc@) → num` | how many tabs. `0` when empty, `0` for a handle that is not a tab control |
| `tabcontrol_tab$(tc@, i) → str` | the caption of tab `i`, base-1. `""` when `i` names no tab — an out-of-range index here is *answered empty and not recorded*, unlike a bad handle, which is |
| `tabcontrol_clear@(tc@) → handle` | drops every tab; `tabcontrol_count` becomes `0` and the selection with it. Answers `tc@` |
| `tabcontrol_tabindex(tc@) → num` | the selected tab, base-1; `0` when none is selected or the handle is wrong |
| `tabcontrol_tabindex@(tc@, n) → handle` | select tab `n`; `0` selects none, and an `n` that names no tab is ignored silently, as with the notebook. Answers `tc@` |
| `tabcontrol_onchange@(tc@, handler$) → handle` | call the BASIC function named `handler$` every time the selection changes; it is handed the tab control's own handle as its one argument. `""` unwires it. Because the tabs share a single page, this handler *is* the content swap — nothing happens without it |

### Layout furniture

| function | what it answers |
| --- | --- |
| `splitter@(parent@) → handle` | a draggable divider. It arrives aligned to the left edge and 5 px wide, and drags the aligned sibling it faces; between two controls that were positioned with `control_bounds@` and never aligned there is nothing for it to resize, so it looks inert. `0` on a bad parent |
| `bevel@(parent@) → handle` | a drawn line or frame — decoration, not a control the user can reach. `0` on a bad parent |
| `bevel_shape@(bv@, n) → handle` | which figure it draws: `0` box, `1` frame, `2` top line, `3` bottom line, `4` left line, `5` right line, `6` spacer (invisible). These are enum ordinals, **base-0**; a number outside `0..6` leaves the shape as it was, silently. Answers `bv@` |
| `bevel_shape(bv@) → num` | the current shape ordinal. `0` means box — and `0` is also what a handle that is not a bevel answers |
| `bevel_style@(bv@, n) → handle` | how it is shaded: `0` lowered, `1` raised. Anything else is ignored. Answers `bv@` |
| `bevel_style(bv@) → num` | the current style ordinal, `0` for a handle that is not a bevel |

## A worked example

A settings window that uses both kinds of tab at once: a notebook whose two pages
hold different controls, and — on the second page — a flat tab strip over a single
field, where the program swaps the value itself.

```basic
rem A settings window with both kinds of tab.
rem   phosphor run settings.bas

primary$ = "primary.example.com"
backup$  = "backup.example.com"

f@ = form@("Settings", 460, 320)
pc@ = pagecontrol@(f@)
control_align@(pc@, 5)                  rem alClient -- the notebook fills the form

rem --- page 1: a scrolling page with one captioned group on it ---
gen@ = tabsheet@(pc@, "General")
sb@ = scrollbox@(gen@)
control_align@(sb@, 5)
grp@ = groupbox@(sb@)
groupbox_caption@(grp@, "Startup")
control_bounds@(grp@, 12, 12, 400, 72)
chk@ = checkbox@(grp@)
checkbox_caption@(chk@, "Reopen the last file")
control_bounds@(chk@, 16, 28, 260, 22)

rem --- page 2: flat tabs over ONE field, with a rule under them ---
srv@ = tabsheet@(pc@, "Servers")
tc@ = tabcontrol@(srv@)
control_bounds@(tc@, 8, 8, 420, 34)
tabcontrol_add@(tc@, "Primary")
tabcontrol_add@(tc@, "Backup")
tabcontrol_tabindex@(tc@, 1)
tabcontrol_onchange@(tc@, "on_server_tab")

rule@ = bevel@(srv@)
bevel_shape@(rule@, 2)                  rem 2 = a top line, i.e. a hairline rule
bevel_style@(rule@, 0)                  rem 0 = lowered
control_bounds@(rule@, 8, 52, 420, 4)

hdr@ = panel@(srv@)
panel_caption@(hdr@, "Host name")
control_bounds@(hdr@, 8, 64, 420, 24)
field@ = edit@(srv@)
edit_text@(field@, primary$)
control_bounds@(field@, 8, 96, 280, 26)

println "pages: " + str$(pagecontrol_pagecount(pc@)) + ", first is " + tabsheet_caption$(gen@)
println "tabs on page 2: " + str$(tabcontrol_count(tc@)) + ", tab 1 is " + tabcontrol_tab$(tc@, 1)
println "gui_error: " + str$(gui_error())

form_show(f@)
app_run()

function on_server_tab(sender@)
  rem The two tabs share one edit box, so the swap is the program's job:
  rem keep what was typed for the tab we just left, show the other one.
  if tabcontrol_tabindex(sender@) = 1 then
    backup$ = edit_text$(field@)
    edit_text@(field@, primary$)
  else
    primary$ = edit_text$(field@)
    edit_text@(field@, backup$)
  endif
  return 0
endfunction
```

Two things worth noticing:

- **The children go on the sheet, not on the notebook.** `scrollbox@(gen@)` and
  `tabcontrol@(srv@)` are parented on tab sheets; building them on `pc@` would put
  them over the tab strip instead of on a page. `tabsheet@` is the only constructor
  here that insists on a particular parent, and this is why.
- **Nothing was checked as it went.** Every constructor above would have answered
  handle `0` on a mistake and left `gui_error()` at `1`; one `println` at the end
  reports the whole build. That is the same last-error-as-a-value shape `ioerror()`
  and `http_error()` use.

## Notes

The unit's header comment lists the five families it was written with — panel, group
box, scroll box, page control and tab sheet. `splitter@`, `bevel@` and the whole
`tabcontrol@` family arrived later and the comment was not extended; the
registration procedure at the foot of the file is the authoritative list, and it is
what this page was written from.

Everything a container inherits — position and size, alignment, colour, font,
visibility, focus, the key and mouse events, `control_parent@` for moving a control
between containers, and `control_free` — belongs to `PhosphorControlLib` and is
documented in [gui-control.md](gui-control.md). `gui_error()`, `gui_clearerror()`,
`app_run()` and the handle registry itself are in [gui-core.md](gui-core.md). The
containers that are *not* here because they are not general-purpose — a menu bar, a
tool bar, a status bar — live in their own packages.
