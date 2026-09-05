# Phosphor BASIC — GUI component study

Which components of the Free Pascal **LCL** make up Phosphor's GUI library, how they
are grouped into isolated packages, and in what order they were built. This began as
a study written when increment 3 (form + button + one event) was all that stood; it
is now also the record of what was built from it.

> **STATUS 2026-09-05 — the plan is built, with named exceptions.** All **17**
> proposed packages exist under `host/gui/libs/`, registering **311 distinct names**
> (321 registry entries), covered by 13 byte-exact test files that run headless on
> Windows and Linux (`scripts/test-gui`). The **Verdict** column below now reads
> *Built* or *Not built*, measured against the registry rather than intended. Sixteen
> in-scope items in this document were never built and are marked as such — the
> largest being the event model: of the eight LCL signatures named under "The event
> model", **only `TNotifyEvent` has a bridge**, so key, mouse and close events cannot
> yet be bound. A name marked *Not built* does not exist under any spelling; copying
> it out of this page gives "unknown function".

Two inputs are crossed:

- **The LCL palette** — the authoritative set of components Lazarus ships
  (`lcl/registerlcl.pas` and each unit's `Register`). This is what Phosphor can
  actually expose, because the GUI is LCL-native.
- **The Plan9Basic GUI vocabulary** — the reference's `tests/gui/` oracle and its
  `Libs/GUI` packages, which prove *what a BASIC program actually reached for*.

## The "not a port" line, drawn once

Plan9Basic's GUI is **FireMonkey (FMX)** — a retained **scene graph**. The LCL is a
thin wrapper over **native widgets** (Win32/GTK/Qt). That difference decides the
whole surface:

- The reference's **interactive-widget** vocabulary — form, button, label, edit,
  memo, checkbox, radio, combobox, listbox, trackbar, progressbar, panel, layout,
  scrollbox, stringgrid, image, timer, focus, events — maps **directly** onto LCL
  and is the core of Phosphor's GUI.
- The reference's **scene-graph** vocabulary — vector **shapes** as live controls
  (`rectangle#`/`circle#`/`arc#`/`pie#`/`callout#`), the retained **path**
  builder, the ~64 bitmap **effects**, the **animation** objects
  (`floatani#`/`colorani#`/…), per-control **opacity/rotation**, and the **media
  player** — has **no LCL equivalent**. LCL is not a scene graph; it does not
  composite, filter, or tween native widgets. Reproducing that would mean
  shipping a second rendering engine, which is a non-goal.
- LCL, being desktop-native, **offers what the reference lacked**: tree and list
  views, tabbed notebooks, real menus and toolbars, a status bar, native file /
  color / font dialogs, spin and mask edits, a calendar, splitters. These are
  Phosphor's additions.

So Phosphor's GUI = (reference interactive vocabulary ∩ LCL) ∪ (LCL desktop
richness) − (FMX scene features). Where a scene feature has a *native* answer we
take that instead: **`TShape`** for a basic filled shape, and **`TCanvas` on a
`TPaintBox`/`TImage`** (immediate-mode `MoveTo`/`LineTo`/`Rectangle`/`Ellipse`/
`Polygon`/`TextOut`/`Arc`/`Pie`) for custom drawing. Timer-driven property changes
are the native answer to simple animation, deferred until the widget set is broad.

## The uniform surface (adopt the reference's shape)

The reference generates its entire API from one pattern, and it is a good one —
consistent, learnable, and mostly mechanical to implement. Phosphor adopts it,
mapped to its own conventions (`@` handle suffix, base-1, strict boolean):

| Form | Meaning |
|---|---|
| `x@(parent@)` | constructor → a handle; parent first for a control, none for form/timer/dialog. **Geometry is a second call**, not constructor arguments: `control_bounds@(h@, x, y, w, h)` or `control_move@`/`control_size@`. (The original plan put `[, left, top, w, h]` on the constructor; no constructor takes it. `form@` is the one with extra arities: `form@()`, `form@(caption$)`, `form@(caption$, w, h)`.) |
| `x_prop(h@)` / `x_prop$(h@)` | numeric / string getter |
| `x_prop@(h@, value)` | setter; returns the handle so calls read left to right |
| `x_onevent@(h@, "func")` | bind an event to a BASIC function by name; `""` unbinds. **There is no read-back getter** — the planned `x_onevent$(h@)` was never built, and none of the 14 registered binders has a `$` counterpart. |
| `x_verb@(h@[, …])` | imperative action (show, focus, bringtofront, start…) |
| `x_free(h@)` | destroy; 1 the first time, 0 (and an error) on a double free |

The setter-`@` vs getter-no-`@` distinction is load-bearing, exactly as in the
reference: `form_width@(f@, 800)` sets, `form_width(f@)` reads.

### Shared control "chrome" — `PhosphorControlLib` (the backbone)

Every visual LCL control descends from `TControl` / `TWinControl` and shares a
large published-property set. Rather than repeat it per control, one package
exposes it generically for **any** control handle:

- **Geometry / state (built):** `control_left/top/width/height`, `control_align`,
  `control_visible`, `control_enabled`, `control_color`, `control_hint$`,
  `control_cursor`, `control_tag`, font (`control_fontname$`, `control_fontsize`,
  `control_fontcolor`, `control_bold/italic/underline`).
  *Planned but never built as named helpers:* `control_anchors`, `control_tabstop`,
  `control_taborder`. The **capability is present** through the bridge below —
  `control_set@(h@, "Anchors", "akLeft,akRight")` and `control_get$(h@, "Anchors")`
  round-trip, as do `TabStop` and `TabOrder` — only the shorthand names are absent.
- **Verbs (built):** `control_move@(x,y)`, `control_size@(w,h)`,
  `control_bounds@(x,y,w,h)`, `control_bringtofront@`, `control_sendtoback@`,
  `control_setfocus@`, `control_focused`, `control_invalidate@`, `control_free`.
  *Planned but never built:* `control_parent@` — and unlike the three above it is
  **not** reachable through the bridge, because `TControl.Parent` is public rather
  than published, so RTTI cannot see it. A control's parent is fixed at construction.
- **The generic property bridge.** LCL controls carry full published-property
  RTTI, so `control_set@(h@, "PropName", value)` and `control_get(h@, "PropName")`
  / `control_get$(...)` reach **every** published property by name through
  `TypInfo` (`SetOrdProp`/`GetOrdProp`, `SetStrProp`, `SetFloatProp`, and the
  `GetPropInfo` kind check). This is the multiplier: the named helpers above cover
  the hot path and read well, while the bridge covers the long tail with no
  hand-written code. It is Phosphor's answer to `08_property_roundtrip`.

Per-family packages then add only what is specific to a control (a button's
`Default`, an edit's selection, a grid's cells).

### The event model

Binding is by name, as in the reference: `button_onclick@(b@, "on_click")`; `""`
unbinds. The handler is an ordinary function taking the sender handle first, and,
for richer events, the event's data:

```
function on_click(sender@)          rem TNotifyEvent
function on_key(sender@, key%, mods$)   rem TKeyEvent: key code + "S C A" modifier string
function on_mouse(sender@, button%, x%, y%, mods$)  rem TMouseEvent: button 0/1/2
```

**Only the first of these is built.** The plan named eight LCL event signatures to
marshal (from `Controls`/`Forms`): `TNotifyEvent`, `TKeyEvent`, `TKeyPressEvent`,
`TMouseEvent`, `TMouseMoveEvent`, `TMouseWheelEvent`, `TCloseEvent`,
`TCloseQueryEvent`, each getting a `TGuiEventBridge` variant packing its arguments
into a `CallUserFunc(name, [...])` call.

Increment 3 built the `TNotifyEvent` variant and **no other has been added since**.
All 14 registered binders — `button_onclick@`, `edit_onchange@`, `timer_ontimer@`
and the rest — are `TNotifyEvent`, which carries only the sender. So the two handler
shapes shown above (`on_key(sender@, key%, mods$)` and
`on_mouse(sender@, button%, x%, y%, mods$)`) describe an interface that **does not
exist yet**: a program cannot bind a key press, a mouse click with coordinates, a
wheel, or a form-close query. This is the largest unbuilt item in this document.
When the remaining seven are built, modifier keys encode as a short string
(`"S C A"` = shift/ctrl/alt) and mouse button as 0/1/2, matching the reference.

Caveat carried from the reference and confirmed for LCL: **a programmatic change
does not raise its event** (setting `Value` does not fire `OnChange` the way a user
drag does), and timers/animations fire only under a running message loop. Headless
tests therefore assert *wiring* (bind + read-back, and `button_click` to fire
`OnClick` synchronously), not spontaneous firing — which is exactly what
`tests/gui/01_events` already does.

### Error and handle model

- **Shared `gui_error()` / `gui_clearerror()`** (increment 3's choice), not the
  reference's per-library slot. With one uniform handle registry and one
  `GuiResolve`, almost every error is "this handle is not a live control of the
  expected class", which one slot conveys; per-lib slots would be boilerplate for
  ~15 packages. *(Revisitable: if a control ever needs a domain error distinct
  from bad-handle — an image's file-not-found, code 6/7 in the reference — that
  library adds its own code to the shared slot rather than a parallel slot.)*
- **No exceptions cross into BASIC.** A fabricated, freed, or wrong-class handle is
  recorded and answered with a benign value (`""`, `0`), never raised — the
  phase-1 contract and the reference's `02_handles` behaviour, already honoured.
- **Lifetime.** Controls live in the engine handle registry wrapped in
  `TGuiHandle`; only a form owns its tree, so `ResetHandles` frees each tree once
  (increment 3). LCL's `TComponent.FreeNotification` is the native hook to
  invalidate a child's handle when its parent is freed — **still not wired.** The
  condition this line set ("as breadth grows") has been met: 17 packages, 311 names,
  13 test files. Until it is wired, a child handle whose parent form was freed is a
  stale handle the registry cannot know about.
- **Alignment is LCL-native and smaller.** `TAlign` has 7 values
  (`alNone/alTop/alBottom/alLeft/alRight/alClient/alCustom`), not FMX's 20. Phosphor
  exposes those plus **anchors** (`akLeft/akTop/akRight/akBottom`), through
  `control_align@` and the property bridge. `BorderSpacing` and `Constraints` are
  **not** exposed: both are class-typed sub-objects, which the bridge refuses (it
  reaches ordinals, floats, strings, enums and sets, and records `gui_error` 3 for
  anything else). Reaching them would need named helpers that do not exist yet.

## The complete LCL palette — inventory and scope

Grouped by Lazarus palette page. **Tier** = suggested build order (1 = core,
first). "Defer" = real but later; "Out" = out of scope with reason.

### Standard
| Component | Phosphor name | Verdict |
|---|---|---|
| TForm | `form@` | **Built** |
| TButton | `button@` | **Built** (also `bitbtn@`, `speedbutton@`) |
| TLabel | `label@` | **Built** |
| TEdit | `edit@` | **Built** |
| TMemo | `memo@` | **Built** |
| TCheckBox | `checkbox@` | **Built** |
| TRadioButton | `radiobutton@` | **Built** — note the helpers are `radio_*` (`radio_checked@`), not `radiobutton_*` |
| TToggleBox | `togglebox@` | **Built** |
| TComboBox | `combobox@` | **Built** — helpers are `combo_*` |
| TListBox | `listbox@` | **Built** — helpers are `list_*` |
| TGroupBox | `groupbox@` | **Built** |
| TPanel | `panel@` | **Built** |
| TRadioGroup / TCheckGroup | `radiogroup@` / `checkgroup@` | **Not built** (was Tier 2). No constructor, so the bridge cannot reach them either. Nearest shipped: `groupbox@` with `radiobutton@` children, or `checklistbox@` |
| TScrollBar | `scrollbar@` | **Built** |
| TFrame | — | Out (design-time composite; no BASIC analogue) |
| TMainMenu / TPopupMenu | `mainmenu@` / `menuitem@` | **Built**; `popupmenu@` **not built** (was Tier 2) |
| TActionList | — | Defer (an action/command layer; later) |

### Additional
| Component | Phosphor name | Verdict |
|---|---|---|
| TImage | `image@` | **Built** (with `bitmap@`) |
| TStaticText | `statictext@` | **Built** |
| TShape | `shape@` | **Built** (rect/ellipse/circle/roundrect/triangle/star) |
| TBevel | `bevel@` | **Built** |
| TPaintBox | `paintbox@` | **Not built** (was Tier 4). What shipped instead is `bitmap@` + nine `canvas_*` primitives drawing onto an off-screen bitmap, shown with `image_setbitmap@` — custom drawing without a live paint event |
| TSplitter | `splitter@` | **Built** |
| TScrollBox | `scrollbox@` | **Built** |
| TFlowPanel | `flowpanel@` | Defer |
| TCheckListBox | `checklistbox@` | **Built** — helpers are `checklist_*` |
| TStringGrid / TDrawGrid | `stringgrid@` | **Built**. `drawgrid@` **not built** — and now Defer rather than Tier: an owner-drawn grid needs an `OnDrawCell` bridge, which the one-signature event model cannot carry |
| TValueListEditor | `valuelist@` | Defer |
| TColorBox / TColorListBox | `colorbox@` | Defer |
| TMaskEdit | `maskedit@` | **Built** |
| TLabeledEdit | `labelededit@` | Defer |
| TPairSplitter | `pairsplitter@` | Defer |
| TControlBar / TTrayIcon | — / `trayicon@` | Defer / **not built** (was Tier 4; untestable in a headless suite) |

### Common Controls
| Component | Phosphor name | Verdict |
|---|---|---|
| TTrackBar | `trackbar@` | **Built** |
| TProgressBar | `progressbar@` | **Built** |
| TPageControl / TTabSheet | `pagecontrol@` / `tabsheet@` | **Built** |
| TTabControl | `tabcontrol@` | **Not built** (was Tier 3; the layout table never assigned it a package) |
| TTreeView | `treeview@` / `treenode@` | **Built** |
| TListView | `listview@` / `listitem@` | **Built** |
| TStatusBar | `statusbar@` | **Built** |
| TToolBar / TToolButton | `toolbar@` | **Built** (this row said Defer while the package table assigned it to `PhosphorMenuLib`; it was built) |
| TUpDown | `updown@` | **Built** (same contradiction as TToolBar; it was built) |
| THeaderControl | — | Defer |
| TCoolBar | — | Out (niche) |
| TImageList | `imagelist@` | **Not built** (Tier 4 here, Tier 2 in the package table — the document contradicted itself) |

### Dialogs (high value, low cost — no form lifecycle to manage)
| Component | Phosphor name | Verdict |
|---|---|---|
| ShowMessage / MessageDlg | `msgbox` / `msgbox_confirm` | **Built** — the yes/no form is spelled `msgbox_confirm`, not `msgbox_yesno` |
| InputQuery / InputBox | `inputbox$` | **Not built** — the only Tier 1 item in this document with no implementation and no substitute |
| TOpenDialog / TSaveDialog | `openfile$` / `savefile$` | **Built** (also the retained `opendialog@` / `savedialog@` with `dialog_filter@`, `dialog_title@`, `dialog_execute`) |
| TSelectDirectoryDialog | `selectdir$` | **Built** (also `selectdirdialog@`) |
| TColorDialog | `colordialog@` | **Built** — as a retained handle, not the one-shot `colordialog` this row promised: `colordialog@()`, `dialog_execute()`, `colordialog_color()` |
| TFontDialog | `fontdialog@` | **Not built** (was Tier 2). `control_fontname@`/`fontsize@`/`fontcolor@` set a font; they do not ask the user to choose one |
| TOpenPictureDialog / TSavePictureDialog | `openpicture$` / `savepicture$` | **Not built** (was Tier 3). `openfile$` with an image filter covers most of it, without the preview pane |
| TFindDialog / TReplaceDialog | — | Defer |
| TCalendarDialog / TCalculatorDialog | `calendardialog` / `calcdialog` | Defer |

### Misc
| Component | Phosphor name | Verdict |
|---|---|---|
| TSpinEdit / TFloatSpinEdit | `spinedit@` / `floatspinedit@` | **Built** |
| TCalendar | `calendar@` | **Built** |
| TColorButton | `colorbutton@` | **Built** (this row said Defer; it was built) |
| TComboBoxEx / TCheckComboBox | — | Defer |
| TEditButton family (TFileNameEdit, TDirectoryEdit, TDateEdit, TTimeEdit, TCalcEdit) | `filenameedit@` etc. | Defer |
| TFileListBox / TFilterComboBox | — | Defer |
| TShellTreeView / TShellListView | — | Defer |
| TArrow / TButtonPanel | — | Out (niche) |
| Ini/JSON/XML PropStorage | — | Out (engine already has config/json libs) |

### System / Data Controls
| Component | Verdict |
|---|---|
| TTimer / TIdleTimer | `timer@` **built** (needs the message loop, i.e. the interactive host); `idletimer@` **not built** |
| TAsyncProcess | Defer (a process lib, not GUI) |
| THTMLHelp… | Out |
| **TDB\*** (TDBGrid, TDBEdit, TDBNavigator, …, 15 controls) | **Out** — data-aware controls need `Data.DB` and a dataset, the same external-dependency line phase 1 drew for sqlite/http/rag. A future data phase. |

### FMX-only reference vocabulary → LCL disposition
| Reference feature | LCL disposition |
|---|---|
| Shapes as controls (`rectangle#`/`circle#`/`arc#`/`pie#`/`callout#`/`line#`/`roundrect#`/`ellipse#`) | Partly `shape@` (TShape: rect/ellipse/circle/roundrect/triangle/star); the rest via `bitmap@` + `canvas_*` drawn off-screen and shown with `image_setbitmap@`. `paintbox@` was never built, and `canvas_*` has no arc, pie, polygon or polyline — so arc/pie/callout stay unanswered |
| `path#` retained vector path | `canvas_*` immediate-mode drawing onto a `bitmap@`; the nine shipped primitives are moveto/lineto/rectangle/fillrect/ellipse/textout plus pen and brush settings — **no** Polyline, Polygon or Arc, and no retained path object |
| ~64 `effect#` bitmap filters | **Out** — no LCL compositor to filter native widgets |
| `floatani#`/`colorani#`/`pathani#`/… animations | **Out** now; timer-driven property tweening is the native path, revisit after breadth |
| per-control `opacity`, `rotation` | **Out** — native widgets don't composite; `TShape`/canvas can rotate drawings, widgets cannot |
| `media_player#` / `media_control#` | **Out** — no LCL media widget; an external-dependency phase |

## Proposed package layout (isolated units, like `engine/libs/`)

Under `host/gui/libs/`, one unit per family, each `RegisterXxxFuncs(engine.Registry)`.
They MAY use the LCL; the boundary check scans only `engine/`.

**All 17 units below exist.** The *(done)* markers were written when three did; the
list is complete as a set of units, though several of the controls assigned to them
were never built — see the Verdict column above. An eighteenth file,
`PhosphorDisplayGuard.pas`, registers nothing: it is the headless-display guard, not
a function package.

| Unit | Controls | Tier |
|---|---|---|
| `PhosphorGuiCore` | handle wrapper, event bridge(s), `gui_error`, `app_*` | 1 |
| `PhosphorControlLib` | shared chrome + generic `control_set/get` TypInfo bridge + common events | **1 (next)** |
| `PhosphorFormLib` | `form@`, window/geometry/state, form events | 1 |
| `PhosphorButtonLib` | `button@`, `bitbtn@`, `speedbutton@` | 1 |
| `PhosphorLabelLib` | `label@`, `statictext@` | 1 |
| `PhosphorEditLib` | `edit@`, `memo@`, `maskedit@`, `spinedit@`, selection/clipboard | 1–3 |
| `PhosphorChoiceLib` | `checkbox@`, `radiobutton@`, `togglebox@`, `radiogroup@`, `checkgroup@`, `combobox@`, `listbox@`, `checklistbox@` | 1–3 |
| `PhosphorContainerLib` | `panel@`, `groupbox@`, `scrollbox@`, `pagecontrol@`/`tabsheet@`, `splitter@`, `bevel@` | 2–3 |
| `PhosphorRangeLib` | `trackbar@`, `progressbar@`, `scrollbar@`, `updown@` | 2 |
| `PhosphorGridLib` | `stringgrid@`, `drawgrid@` (columns/cells/rows/sort/CSV) | 3 |
| `PhosphorTreeListLib` | `treeview@`/`treenode@`, `listview@`/`listitem@` | 3 |
| `PhosphorImageLib` | `image@`, `imagelist@` | 2 |
| `PhosphorCanvasLib` | `paintbox@`, `shape@`, `canvas_*` drawing primitives | 4 |
| `PhosphorMenuLib` | `mainmenu@`, `popupmenu@`, `menuitem@`, `toolbar@`, `statusbar@` | 2–3 |
| `PhosphorDialogLib` | `msgbox`, `inputbox$`, `openfile$`, `savefile$`, `selectdir$`, `colordialog`, `fontdialog@` | 1–2 |
| `PhosphorTimerLib` | `timer@`, `idletimer@` | 2 |
| `PhosphorMiscLib` | `calendar@`, `colorbutton@`, `trayicon@` | 3–4 |

## Recommended build order

1. **`PhosphorControlLib` — the shared backbone + the generic property bridge.**
   *(Increment 4.)* This is the highest-leverage step: once `control_*` and the
   `TypInfo` bridge exist, every later control inherits geometry, visibility,
   colour, font, focus and the property long-tail for free, and each family unit
   only writes its specifics. Adapt `08_property_roundtrip` and `10_geometry`.
2. **Dialogs — `PhosphorDialogLib`.** `msgbox`/`inputbox$`/`openfile$`/`savefile$`/
   `selectdir$`. Cheap, no form lifecycle, immediately useful for real programs.
3. **Core input controls — Label, Edit/Memo, Choice.** The controls a form needs
   to be an actual application; adapt `01_controls`, `17_lists_text_image`,
   `22_focus_and_edit`, `11_form_events` (onchange).
4. **Layout & feedback — Container, Range, Timer, Image, Menu.** Panels, tabs,
   trackbar/progressbar, timer (needs the interactive host loop), image, menus and
   a status bar. Adapt `21_shapes_containers`, `05_progress_scale`, `14_timer`.
5. **Rich controls — Grid, Tree/List.** `stringgrid@` (adapt `15_stringgrid`),
   `treeview@`, `listview@`.
6. **Custom drawing — `PhosphorCanvasLib`.** `paintbox@` + `canvas_*` + `shape@`:
   the native answer to the reference's shapes/path, immediate-mode.

Each step: one isolated unit (or a few), an adapted GUI oracle file byte-exact
green **headless on Windows and Linux** (the increment-3 harness), the interactive
host exercised by hand. Deferred throughout, as in phase 1: DB controls
(`Data.DB`), media, FMX effects/animations, and the niche palette entries.

**All six steps were carried out** — 17 units, 311 names, 13 byte-exact test files
green on both OSes. What the order did *not* deliver, and what a seventh step would
be, in the order the gaps cost most:

1. **The other seven event bridges.** Key, mouse, wheel and close events cannot be
   bound at all. Everything below is small next to this.
2. **`inputbox$`** — a Tier 1 dialog promised three times in this document, one
   registration's worth of work, with no substitute.
3. **`TComponent.FreeNotification`** — the invalidation hook this page said would be
   wired "as breadth grows". Breadth grew.
4. **The missing constructors**, cheapest first: `fontdialog@` and `idletimer@`
   (each mirrors something already shipped), `radiogroup@`/`checkgroup@`,
   `popupmenu@` (plus a `control_popupmenu@` assignment helper), `tabcontrol@`.
5. **The named backbone helpers** `control_parent@` (not bridge-reachable) and
   `control_anchors`/`tabstop`/`taborder` (bridge-reachable today, so shorthand only).
6. **Nice to have, or to drop:** `imagelist@`, `openpicture$`/`savepicture$`,
   `trayicon@`, a real `paintbox@` with an `OnPaint` bridge, and `canvas_*` polygon
   and arc primitives.
