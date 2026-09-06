# gui-tree-list — a tree of nodes and a report list of rows

`host/gui/libs/PhosphorTreeListLib.pas` · 14 functions · GUI hosts (the `phosphor`
binary and the headless `phosphorguitest` runner register it; an embedding host has
these names only if it calls `RegisterTreeListFuncs`)

## What it is for

Two controls that show *many* things instead of one value. A **tree view** shows a
hierarchy — a node, its children, their children — and a **list view** shows rows
under column headers, the shape a file manager's detail pane has. The list view is
created in report style and stays there: columns are the reason this control exists
here, so `listview@` sets `ViewStyle` to report before it hands the handle back.

The unit header states the design point that shapes everything else: *nodes
(`TTreeNode`) and items (`TListItem`) are not `TComponent`s, so they ride on the
handle registry through the generalized `GuiResolveObj`; their container owns them,
so their wrappers are non-owning.* In BASIC that means a node handle and an item
handle are ordinary values you keep in a variable and pass to functions, exactly
like a control handle — but they are **not controls**. The `control_*` backbone
(`control_bounds@`, `control_visible@`, `control_free`) resolves only real
controls, so it applies to the `treeview@` and the `listview@` themselves and
records `gui_error()` `1` if you point it at a node or an item. Nor does anything
here free a node or an item: the tree and the list own them.

The stance on failure is the phase-1 GUI contract: **nothing raises**. A fabricated
handle, a freed one, or a live handle of the wrong class is recorded in
`gui_error()` as `1` and answered with a benign value — a `0` handle from the
constructors, `""` from the string readers, `0` from the counters. The mutators go
one step further and answer **the handle you passed in, always**, whether or not
the change happened, so calls chain left to right and "did it work" stays a
separate question asked of `gui_error()`. Clear the slot with `gui_clearerror()`
before a sequence you intend to check, because it is shared by the whole GUI
surface.

Three things a caller would otherwise be surprised by. First, `treenode@` decides
what to build from **the class of the handle you give it**: a tree view parent
makes a root node, a node parent makes a child of that node, and anything else
makes nothing (handle `0`, `gui_error()` `1`). Second, the two counters answer
different questions — `treeview_nodecount` counts *every* node in the tree, flat,
while `treenode_childcount` counts only one node's immediate children. Third, an
item's caption fills the **first** column, so subitem `1` appears under column
**2**: with columns `name` and `size`, the caption is the name and the first
subitem is the size.

## Functions

### The tree view

| function | what it answers |
| --- | --- |
| `treeview@(parent@) → handle` | a new tree view inside `parent@`, positioned afterwards by the control backbone. Handle `0` when `parent@` is not a live window control, with `gui_error()` at `1` |
| `treenode@(parent@, caption$) → handle` | a new node carrying `caption$`. A tree view `parent@` gives a **root** node appended at the top level; a node `parent@` gives a **child** of that node. Handle `0` for anything else — a button, a list item, a stale handle — with `gui_error()` at `1` and no node added |
| `treenode_caption@(n@, caption$) → handle` | renames the node and answers `n@` **always**, so calls chain. A handle that is not a node changes nothing and records `1`; the answer is the same either way |
| `treenode_caption$(n@) → str` | the node's text. `""` for a handle that is not a node, which reads the same as a node genuinely captioned `""` |
| `treenode_childcount(n@) → num` | how many **immediate** children the node has — not its grandchildren. `0` for a leaf and `0` for a handle that is not a node, with `gui_error()` at `1` for the second |
| `treeview_nodecount(tv@) → num` | how many nodes the tree holds **in total**, at every depth. `0` for an empty tree and `0` for a handle that is not a tree view |

### The list view

| function | what it answers |
| --- | --- |
| `listview@(parent@) → handle` | a new list view inside `parent@`, already in report style (columns showing). Handle `0` when `parent@` is not a live window control, with `gui_error()` at `1` |
| `listview_addcolumn@(lv@, caption$) → handle` | appends a column headed `caption$` and answers **`lv@`**, not the column — columns have no handle in this package, so a column cannot afterwards be renamed, resized or removed from BASIC. A handle that is not a list view adds nothing and records `1` |
| `listview_itemcount(lv@) → num` | how many rows the list holds. `0` for an empty list and `0` for a handle that is not a list view |
| `listitem@(lv@, caption$) → handle` | a new row appended to the list, its caption filling the **first** column. Handle `0` when `lv@` is not a list view, with `gui_error()` at `1` and no row added |
| `listitem_caption@(it@, caption$) → handle` | rewrites the first column's text and answers `it@` **always**; a handle that is not an item changes nothing and records `1` |
| `listitem_caption$(it@) → str` | that text. `""` for a handle that is not an item — indistinguishable from an empty caption |
| `listitem_subitem@(it@, s$) → handle` | **appends** one more cell to the row, under the next column along, and answers `it@`. There is no replace and no remove: the *n*th call fills column *n+1*, and calling it more times than the list has columns stores text nothing shows |
| `listitem_subitem$(it@, n) → str` | the *n*th subitem, **base-1** — `n = 1` is the cell under column 2. `""` when `n` is outside `1..count`, and `""` for a handle that is not an item, which both read the same as a cell genuinely holding `""` |

## A worked example

A two-pane window: a tree of projects on the left, a report of files on the right.
The row helper is a plain BASIC function, because a row of three columns is three
calls and nothing in the package bundles them.

```basic
rem   phosphor run browser.bas

f@ = form@("Browser", 640, 420)

rem --- the tree, on the left ---
tv@ = treeview@(f@)
control_bounds@(tv@, 8, 8, 200, 370)

gui_clearerror()
root@ = treenode@(tv@, "projects")
a@ = treenode@(root@, "phosphor")       rem parent is a node -> a child
b@ = treenode@(root@, "notes")
treenode_caption@(b@, "notes (old)")    rem answers b@, so it could be chained

println "the root has " + str$(treenode_childcount(root@)) + " children"
println "the tree holds " + str$(treeview_nodecount(tv@)) + " nodes in all"
println "renamed to: " + treenode_caption$(b@)

rem --- the report, on the right ---
lv@ = listview@(f@)
control_bounds@(lv@, 216, 8, 416, 370)
listview_addcolumn@(lv@, "name")        rem column 1: the item's caption
listview_addcolumn@(lv@, "size")        rem column 2: subitem 1
listview_addcolumn@(lv@, "kind")        rem column 3: subitem 2

first@ = row@(lv@, "readme.md", "4 KB", "text")
second@ = row@(lv@, "browser.bas", "1 KB", "basic")

println str$(listview_itemcount(lv@)) + " rows"
desc$ = listitem_caption$(first@) + " is " + listitem_subitem$(first@, 1)
println desc$ + ", a " + listitem_subitem$(first@, 2) + " file"
println "anything go wrong? gui_error = " + str$(gui_error())

form_show(f@)
app_run()

function row@(lv@, name$, size$, kind$) local it@
  it@ = listitem@(lv@, name$)
  listitem_subitem@(it@, size$)
  listitem_subitem@(it@, kind$)
  return it@
endfunction
```

Two things worth noticing:

- **The same function builds roots and children.** `treenode@(tv@, ...)` and
  `treenode@(root@, ...)` differ only in what the first handle is, which is why a
  recursive tree-filler needs no special case for the top level — it passes down
  whatever handle it was given.
- **`listitem_subitem$(first@, 1)` reads the *size* column.** The base-1 index runs
  over the subitems, and the caption is not one of them. Off by one against the
  column number is the mistake to expect, and it is silent: an index past the end
  answers `""` rather than complaining.

## Notes / Where the rest lives

**Lifetime.** A control handle knows when its control dies — `TGuiHandle` wires
LCL's `FreeNotification`, so a child of a freed form resolves to `gui_error()` `1`
like any other stale handle. Nodes and items **cannot** be watched that way,
because `FreeNotification` is a `TComponent` service and they are not components.
They keep the weaker guarantee described in
[gui-components.md](../gui-components.md): do not free a tree or a list while you
still hold handles to its nodes or items. Drop those handles first.

**What is deliberately not here.** There is no removal (no way to delete a node, a
row or a column), no selection (nothing answers which node is selected), no
expand/collapse, no sorting, and no events — a click on a node reaches BASIC only
through the generic `control_onmousedown@` on the tree view control, which reports
where the pointer was, not which node it hit. The escape hatch for anything the
package does not name is the property bridge, `control_set@` and `control_get$`
([gui-control.md](gui-control.md)); it resolves controls, so it reaches the
`treeview@` and `listview@` — `ViewStyle`, `RowSelect`, `ShowLines` — and never a
node or an item.

**Icons.** Both controls take a shared strip of images through
`imagelist_attach@(il@, ctl@)` in [gui-image.md](gui-image.md); a list view
receives it as its *small* image list. Assigning an image *index* to a particular
node or row is not exposed by this package.

**Geometry, colour, font and focus** come from the control backbone in
[gui-control.md](gui-control.md), the same as for a button. Creating the form and
running the loop is [gui-form.md](gui-form.md) and [gui-core.md](gui-core.md),
which is also where `gui_error()` and `gui_clearerror()` are described.
