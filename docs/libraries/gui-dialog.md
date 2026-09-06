# gui-dialog — the common dialogs: files, folders, colour, font, and a message

`host/gui/libs/PhosphorDialogLib.pas` · 30 functions · GUI package — the `phosphor`
host registers it wherever a graphical session is reachable; the modal calls need a
user in front of it

## What it is for

This is the package a program reaches for when it needs the operating system's own
dialogs: choose a file to open, choose a name to save under, pick a folder, pick a
colour, pick a font — plus the two smallest ones, a message and a single line of
typed text. Everything a BASIC program would otherwise have to build out of forms
and buttons, and would build worse.

It offers the same job in **two shapes**. The *retained* shape is a handle you
configure and then show: `opendialog@()` hands you a dialog, `dialog_title@`,
`dialog_filter@`, `dialog_filename@`, `dialog_initialdir@` set it up, and
`dialog_execute` shows it and answers whether the user accepted. The *one-shot*
shape is a single expression that builds, shows and frees a dialog for you —
`openfile$()`, `savefile$()`, `selectdir$()`, `inputbox$()` — and answers the chosen
path, folder or text directly. Use the one-shot when you want a file; use the
retained one when you also want a title, a filter, and a starting folder.

The design line that shaped this page is that **a dialog's Execute is modal — it
blocks until the user answers**. That makes it the interactive host's business, not
the headless byte-exact suite's, which would simply hang on it. So what the tests
check is a dialog's **configuration** (`tests/gui/10_dialog.bas` round-trips every
property this library sets), and the showing half is documented interactive-only.
Nothing here fails a headless run — it waits, forever, which is worse.

Two conventions carry over from the rest of the GUI, and one surprise is local to
this package. The conventions: a setter is the name with `@`, and it answers **the
handle** rather than a success flag, so calls read left to right; the reader is the
same name with `$` or with no suffix. And **nothing here raises a BASIC error** — a
fabricated handle, or one of the wrong family, leaves the property untouched, makes
the getter answer `""` or `0`, and records the mistake in `gui_error()`. The
surprise: `dialog_title@` reaches every dialog, but `dialog_filter@`,
`dialog_filename@` and `dialog_initialdir@` only reach **file** dialogs (open, save,
select-directory). A colour or font dialog refuses them, quietly, into `gui_error()`.

## Functions

### Building a dialog

Each constructor always succeeds and hands back an **owned** handle; free it with
`control_free(d@)` when the dialog is not going to be shown again.

| function | what it answers |
| --- | --- |
| `opendialog@() → handle` | a file-open dialog, not yet shown |
| `savedialog@() → handle` | a file-save dialog — same configuration surface, different button |
| `selectdirdialog@() → handle` | a folder chooser. It is a file dialog too, so it reads its answer back through `dialog_filename$` |
| `colordialog@() → handle` | a colour chooser. Configure it with `colordialog_color@`, not with the file properties |
| `fontdialog@() → handle` | a font chooser. Configure it with the `fontdialog_font…` family |

### Configuring one

Setters answer the handle they were given — including when they did nothing, so a
chain never breaks; check `gui_error()` if you need to know. Getters answer `""`
when the handle is not a dialog of the right family.

| function | what it answers |
| --- | --- |
| `dialog_title@(d@, title$) → handle` | the handle. Sets the window caption; works on **all five** dialogs |
| `dialog_title$(d@) → str` | the caption set so far; `""` when none was set, and `""` for a handle that is not a dialog |
| `dialog_filter@(d@, filter$) → handle` | the handle. The filter is LCL's `description|mask` pairs joined by `\|`, e.g. `"Text\|*.txt\|All\|*.*"`. Ignored (and recorded in `gui_error()`) on a colour or font dialog |
| `dialog_filter$(d@) → str` | the filter string as set; `""` when unset or unreachable |
| `dialog_filename@(d@, name$) → handle` | the handle. Before showing, the name the dialog opens with; a program sets it to suggest a save name |
| `dialog_filename$(d@) → str` | after `dialog_execute` answered `1`, the path the user chose — a folder, for a select-directory dialog. `""` when the dialog was cancelled, never shown, or is not a file dialog |
| `dialog_initialdir@(d@, dir$) → handle` | the handle. The folder the dialog opens in. A directory that does not exist is the platform's problem, not an error here |
| `dialog_initialdir$(d@) → str` | the starting folder as set; `""` when unset |

### The colour and the font dialog

Colours are LCL `TColor` integers — `color("navy")` builds one from a name and
`colortostr$(n)` turns one back into a name, or into a `$`-prefixed hex string when
it matches none of the sixteen named ones.

| function | what it answers |
| --- | --- |
| `colordialog_color@(d@, color) → handle` | the handle. Before showing, the preselected colour; the same property is where the answer lands afterwards |
| `colordialog_color(d@) → num` | the chosen colour after `dialog_execute` answered `1` — otherwise still whatever was preselected. `0` (black) for a handle that is not a colour dialog |
| `fontdialog_fontname@(d@, face$) → handle` | the handle. Preselects a typeface by name |
| `fontdialog_fontname$(d@) → str` | the chosen face; before showing, the preselected one. `""` when the handle is not a font dialog |
| `fontdialog_fontsize@(d@, points) → handle` | the handle. Preselects a point size |
| `fontdialog_fontsize(d@) → num` | the chosen size in points. `0` for a wrong handle — and `0` is also LCL's "whatever the default is", so it is not proof of failure; `gui_error()` is |
| `fontdialog_fontcolor@(d@, color) → handle` | the handle. Preselects the text colour |
| `fontdialog_fontcolor(d@) → num` | the chosen text colour as a `TColor`; `0` for a wrong handle |

### Showing one — modal, interactive host only

| function | what it answers |
| --- | --- |
| `dialog_execute(d@) → num` | `1` when the user accepted, `0` when they cancelled. Also `0` — with `gui_error()` set — when the handle is not a dialog at all, which is the one case the return value alone cannot tell you. **Blocks** until the user answers |

### One-shot dialogs — modal, interactive host only

These build their own dialog, show it, and free it before answering. There is no
handle to keep and nothing to free.

| function | what it answers |
| --- | --- |
| `msgbox(msg$) → num`, `msgbox(msg$, title$) → num` | always `0` — there is nothing to report; it is called for what the user sees. The two-argument form takes the **message first**, the window title second |
| `msgbox_confirm(msg$) → num` | `1` for Yes, `0` for No — and `0` when the user closes the window without answering, which counts as No |
| `openfile$() → str`, `openfile$(filter$) → str` | the path the user chose, or `""` when they cancelled. Empty is the real answer for "no file", not an error |
| `savefile$() → str`, `savefile$(filter$) → str` | the path to save to, or `""` on cancel. It does **not** write anything — the program still has to |
| `openpicture$() → str`, `openpicture$(filter$) → str` | the same as `openfile$`, through a picture chooser that shows a preview of the selected image; `""` on cancel |
| `savepicture$() → str`, `savepicture$(filter$) → str` | a path to save an image to, with the same preview pane; `""` on cancel |
| `selectdir$() → str` | the folder the user chose, or `""` on cancel |
| `inputbox$(prompt$) → str`, `inputbox$(prompt$, default$) → str`, `inputbox$(title$, prompt$, default$) → str` | what the user typed. On **cancel it answers the default** — `""` for the one-argument form — so an empty answer and a cancelled one are the same string. See the note below |

## A worked example

A small file-copier: it asks which report to copy using the retained dialog —
because it wants a title, a filter and a starting folder — and asks where to put it
with the one-shot, because there it wants none of that.

```basic
rem Copy a report somewhere the user picks. Every step can be cancelled,
rem and every cancel is an empty string or a zero, not an error.

d@ = opendialog@()
dialog_title@(d@, "Choose a report")
dialog_filter@(d@, "Reports|*.txt;*.md|All files|*.*")
dialog_initialdir@(d@, dir_getcurrent$())

if dialog_execute(d@) = 1 then
  src$ = dialog_filename$(d@)
  dest$ = savefile$("Text|*.txt")
  if dest$ = "" then
    println "no destination chosen"
  else
    if msgbox_confirm("Copy " + src$ + " to " + dest$ + "?") = 1 then
      ok = file_copy(src$, dest$)
      if ok = 1 then
        msgbox("Copied to " + dest$, "Report copier")
      else
        msgbox("Could not write " + dest$, "Report copier")
      endif
    endif
  endif
else
  println "cancelled"
endif

control_free(d@)
```

Two things worth noticing:

- **The retained dialog outlives its showing.** `dialog_filename$(d@)` is read
  *after* `dialog_execute` returned, from the same handle — which is why the handle
  exists at all, and why it has to be freed. The one-shot `savefile$` has nowhere to
  keep an answer, so it hands the path straight back.
- **The colour and font dialogs have exactly this shape.** `colordialog@()`, then
  `colordialog_color@(c@, color("navy"))` to preselect, then `dialog_execute(c@)`,
  then `colordialog_color(c@)` for the answer. The property that configures is the
  property that reports.

## Notes

**`inputbox$` cannot tell cancel from an empty answer.** LCL's `InputBox` returns
the default when the user cancels, so the two are literally the same string. A
program that must distinguish them passes a default it would never accept as a real
answer — `inputbox$("Name", "Enter a name:", chr$(1))` — and treats that exact
string coming back as "cancelled". The alternative, inventing a sentinel inside the
library, would have been worse: it would fail silently for the one program whose
users type that exact text.

**Freeing.** Every constructor here registers an **owned** handle, so a program that
builds a dialog per button click leaks one dialog per click until it calls
`control_free(d@)`. The one-shot calls own their dialog inside a `try…finally` and
free it whether the user accepted or cancelled, so they never leak.

**Where the rest of the GUI is.** The dialog handles share the common-dialog
surface only; they are not controls, have no geometry, and take no events. The
control chrome (`control_bounds@`, `control_visible`, the event binders) lives in
`PhosphorControlLib`, and the widget families each have their own package — see
[gui-components.md](../gui-components.md) for the map of all seventeen.
