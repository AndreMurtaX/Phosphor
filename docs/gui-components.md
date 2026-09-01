# Phosphor BASIC — GUI component study

Which components of the Free Pascal **LCL** should make up Phosphor's complete GUI
library, how they are grouped into isolated packages, and in what order to build
them. This is a study and a plan of record, not yet code; increment 3
(form + button + one event) already stands, and the rest is scoped here.

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
| `x@(parent@[, left, top, w, h])` | constructor → a handle; parent first for a control, none for form/timer/dialog |
| `x_prop(h@)` / `x_prop$(h@)` | numeric / string getter |
| `x_prop@(h@, value)` | setter; returns the handle so calls read left to right |
| `x_onevent@(h@, "func")` / `x_onevent$(h@)` | bind an event to a BASIC function by name / read it back |
| `x_verb@(h@[, …])` | imperative action (show, focus, bringtofront, start…) |
| `x_free(h@)` | destroy; 1 the first time, 0 (and an error) on a double free |

The setter-`@` vs getter-no-`@` distinction is load-bearing, exactly as in the
reference: `form_width@(f@, 800)` sets, `form_width(f@)` reads.

### Shared control "chrome" — `PhosphorControlLib` (the backbone)

Every visual LCL control descends from `TControl` / `TWinControl` and shares a
large published-property set. Rather than repeat it per control, one package
exposes it generically for **any** control handle:

- **Geometry / state:** `control_left/top/width/height`, `control_align`,
  `control_anchors`, `control_visible`, `control_enabled`, `control_color`,
  `control_hint$`, `control_cursor`, `control_tag`, `control_tabstop`,
  `control_taborder`, font (`control_fontname$`, `control_fontsize`,
  `control_fontcolor`, `control_bold/italic/underline`).
- **Verbs:** `control_move@(x,y)`, `control_size@(w,h)`, `control_bounds@(x,y,w,h)`,
  `control_bringtofront@`, `control_sendtoback@`, `control_setfocus@`,
  `control_focused`, `control_invalidate@`, `control_parent@`, `control_free`.
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

The LCL event signatures Phosphor must marshal (from `Controls`/`Forms`):
`TNotifyEvent`, `TKeyEvent`, `TKeyPressEvent`, `TMouseEvent`, `TMouseMoveEvent`,
`TMouseWheelEvent`, `TCloseEvent`, `TCloseQueryEvent`. Each gets a `TGuiEventBridge`
variant (increment 3 built the `TNotifyEvent` one) that packs its arguments into a
`CallUserFunc(name, [...])` call — the host-callback seam already proven. Modifier
keys encode as a short string (`"S C A"` = shift/ctrl/alt), mouse button as 0/1/2,
matching the reference so its tests port with minimal change.

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
  invalidate a child's handle when its parent is freed — to be wired as breadth
  grows, matching the reference's automatic invalidation.
- **Alignment is LCL-native and smaller.** `TAlign` has 7 values
  (`alNone/alTop/alBottom/alLeft/alRight/alClient/alCustom`), not FMX's 20. Phosphor
  exposes those plus **anchors** (`akLeft/akTop/akRight/akBottom`), `BorderSpacing`
  and `Constraints` — LCL's more capable native layout model — rather than porting
  the FMX alignment codes.

## The complete LCL palette — inventory and scope

Grouped by Lazarus palette page. **Tier** = suggested build order (1 = core,
first). "Defer" = real but later; "Out" = out of scope with reason.

### Standard
| Component | Phosphor name | Verdict |
|---|---|---|
| TForm | `form@` | **Done** (incr. 3) |
| TButton | `button@` | **Done** (incr. 3) |
| TLabel | `label@` | **Tier 1** |
| TEdit | `edit@` | **Tier 1** |
| TMemo | `memo@` | **Tier 1** |
| TCheckBox | `checkbox@` | **Tier 1** |
| TRadioButton | `radiobutton@` | **Tier 1** |
| TToggleBox | `togglebox@` | Tier 2 |
| TComboBox | `combobox@` | **Tier 1** |
| TListBox | `listbox@` | **Tier 1** |
| TGroupBox | `groupbox@` | Tier 2 |
| TPanel | `panel@` | **Tier 2** |
| TRadioGroup / TCheckGroup | `radiogroup@` / `checkgroup@` | Tier 2 |
| TScrollBar | `scrollbar@` | Tier 3 |
| TFrame | — | Out (design-time composite; no BASIC analogue) |
| TMainMenu / TPopupMenu | `mainmenu@` / `popupmenu@` / `menuitem@` | **Tier 2** |
| TActionList | — | Defer (an action/command layer; later) |

### Additional
| Component | Phosphor name | Verdict |
|---|---|---|
| TImage | `image@` | **Tier 2** |
| TStaticText | `statictext@` | Tier 3 |
| TShape | `shape@` | Tier 3 (native basic shapes: rect/ellipse/circle/roundrect/triangle/star) |
| TBevel | `bevel@` | Tier 3 |
| TPaintBox | `paintbox@` + `canvas_*` | **Tier 4** (custom drawing — the native "shapes/path" answer) |
| TSplitter | `splitter@` | Tier 3 |
| TScrollBox | `scrollbox@` | Tier 2 |
| TFlowPanel | `flowpanel@` | Defer |
| TCheckListBox | `checklistbox@` | Tier 3 |
| TStringGrid / TDrawGrid | `stringgrid@` / `drawgrid@` | **Tier 3** (the reference's `15_stringgrid` shape) |
| TValueListEditor | `valuelist@` | Defer |
| TColorBox / TColorListBox | `colorbox@` | Defer |
| TMaskEdit | `maskedit@` | Tier 3 |
| TLabeledEdit | `labelededit@` | Defer |
| TPairSplitter | `pairsplitter@` | Defer |
| TControlBar / TTrayIcon | — | Defer / Tier 4 (`trayicon@`) |

### Common Controls
| Component | Phosphor name | Verdict |
|---|---|---|
| TTrackBar | `trackbar@` | **Tier 2** |
| TProgressBar | `progressbar@` | **Tier 2** |
| TPageControl / TTabSheet | `pagecontrol@` / `tabsheet@` | **Tier 3** |
| TTabControl | `tabcontrol@` | Tier 3 |
| TTreeView | `treeview@` / `treenode@` | Tier 3 |
| TListView | `listview@` / `listitem@` | Tier 3 |
| TStatusBar | `statusbar@` | Tier 3 |
| TToolBar / TToolButton | `toolbar@` | Defer |
| TUpDown | `updown@` | Defer |
| THeaderControl | — | Defer |
| TCoolBar | — | Out (niche) |
| TImageList | `imagelist@` | Tier 4 (backs toolbars/lists/trees) |

### Dialogs (high value, low cost — no form lifecycle to manage)
| Component | Phosphor name | Verdict |
|---|---|---|
| ShowMessage / MessageDlg | `msgbox` / `msgbox_yesno` | **Tier 1** |
| InputQuery / InputBox | `inputbox$` | **Tier 1** |
| TOpenDialog / TSaveDialog | `openfile$` / `savefile$` | **Tier 1** |
| TSelectDirectoryDialog | `selectdir$` | **Tier 1** |
| TColorDialog | `colordialog` | Tier 2 |
| TFontDialog | `fontdialog@` | Tier 2 |
| TOpenPictureDialog / TSavePictureDialog | `openpicture$` / `savepicture$` | Tier 3 |
| TFindDialog / TReplaceDialog | — | Defer |
| TCalendarDialog / TCalculatorDialog | `calendardialog` / `calcdialog` | Defer |

### Misc
| Component | Phosphor name | Verdict |
|---|---|---|
| TSpinEdit / TFloatSpinEdit | `spinedit@` / `floatspinedit@` | Tier 3 |
| TCalendar | `calendar@` | Tier 3 |
| TColorButton | `colorbutton@` | Defer |
| TComboBoxEx / TCheckComboBox | — | Defer |
| TEditButton family (TFileNameEdit, TDirectoryEdit, TDateEdit, TTimeEdit, TCalcEdit) | `filenameedit@` etc. | Defer |
| TFileListBox / TFilterComboBox | — | Defer |
| TShellTreeView / TShellListView | — | Defer |
| TArrow / TButtonPanel | — | Out (niche) |
| Ini/JSON/XML PropStorage | — | Out (engine already has config/json libs) |

### System / Data Controls
| Component | Verdict |
|---|---|
| TTimer / TIdleTimer | `timer@` — **Tier 2** (needs the message loop, i.e. the interactive host) |
| TAsyncProcess | Defer (a process lib, not GUI) |
| THTMLHelp… | Out |
| **TDB\*** (TDBGrid, TDBEdit, TDBNavigator, …, 15 controls) | **Out** — data-aware controls need `Data.DB` and a dataset, the same external-dependency line phase 1 drew for sqlite/http/rag. A future data phase. |

### FMX-only reference vocabulary → LCL disposition
| Reference feature | LCL disposition |
|---|---|
| Shapes as controls (`rectangle#`/`circle#`/`arc#`/`pie#`/`callout#`/`line#`/`roundrect#`/`ellipse#`) | Partly `shape@` (TShape: rect/ellipse/circle/roundrect/triangle/star); arc/pie/callout/line via `paintbox@` + `canvas_*` |
| `path#` retained vector path | `canvas_*` immediate-mode drawing (Polyline/Polygon/Arc); no retained path object |
| ~64 `effect#` bitmap filters | **Out** — no LCL compositor to filter native widgets |
| `floatani#`/`colorani#`/`pathani#`/… animations | **Out** now; timer-driven property tweening is the native path, revisit after breadth |
| per-control `opacity`, `rotation` | **Out** — native widgets don't composite; `TShape`/canvas can rotate drawings, widgets cannot |
| `media_player#` / `media_control#` | **Out** — no LCL media widget; an external-dependency phase |

## Proposed package layout (isolated units, like `engine/libs/`)

Under `host/gui/libs/`, one unit per family, each `RegisterXxxFuncs(engine.Registry)`.
They MAY use the LCL; the boundary check scans only `engine/`.

| Unit | Controls | Tier |
|---|---|---|
| `PhosphorGuiCore` *(done)* | handle wrapper, event bridge(s), `gui_error`, `app_*` | 1 |
| `PhosphorControlLib` | shared chrome + generic `control_set/get` TypInfo bridge + common events | **1 (next)** |
| `PhosphorFormLib` *(done)* | `form@`, window/geometry/state, form events | 1 |
| `PhosphorButtonLib` *(done)* | `button@`, `bitbtn@`, `speedbutton@` | 1 |
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
