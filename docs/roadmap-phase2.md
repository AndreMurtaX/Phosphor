# Phosphor BASIC — phase-2 roadmap (GUI over the LCL)

Phase 1 delivered the engine and its non-graphical libraries, verified by a
byte-exact oracle suite. Phase 2 gives the same engine a **second consumer**: a
GUI host built on the Lazarus Component Library (LCL). The engine does not change
character — it still never learns a window exists. The boundary check
(`scripts/*`) keeps proving that: every `engine/` unit is scanned and the build
fails if one reaches `lcl`, `forms`, `windows`, and the rest.

Method, inherited from phase 1: **freeze the founding seam in the first
increment, prove it against reality before building on it**, and treat the
reference (`C:\Dev\Plan9Basic`, its `tests/gui/` suite and `engine/Libs/GUI`) as
an oracle for *shape*, not a thing to port.

## Status — PHASE 2 COMPLETE (2026-09-01)

The GUI control library is delivered and the engine never learned it exists. What
shipped:

- **The host-callback seam** (`Registry.AddHost` / `TPhosphorVM.CallUserFunc`) —
  host-agnostic, proven headless by `callfunc` before any GUI existed.
- **17 GUI packages** under `host/gui/libs/`, isolated per control family like
  `engine/libs/` but free to use the LCL: `GuiCore`, `Control` (the shared
  backbone + generic `TypInfo` property bridge), `Form`, `Button`, `Label`, `Edit`,
  `Choice`, `Container`, `Range`, `Menu`, `Timer`, `Image`, `Grid`, `TreeList`,
  `Canvas`, `Dialog`, `Misc` (and their siblings).
- **Controls**: form, button/bitbtn/speedbutton, label/statictext, edit/memo/
  spinedit/floatspinedit/maskedit, checkbox/radio/togglebox/combobox/listbox/
  checklistbox, panel/groupbox/scrollbox/pagecontrol+tabsheet/splitter/bevel,
  trackbar/progressbar/scrollbar/updown, mainmenu/menuitem/toolbar/statusbar,
  timer, image, stringgrid, treeview/listview, canvas drawing (bitmap + `canvas_*`
  + shape), the common dialogs, calendar, colorbutton.
- **Two hosts** mirroring `host/console/`: `phosphorgui` (interactive) and
  `phosphorguitest` (headless runner). `examples/gui_demo.bas` runs a real app.
- **Verification**: 13 byte-exact GUI test files (`tests/gui/00`–`12`) green on
  **Windows (win32)** and **Linux (gtk2, live display)** via `scripts/test-gui.
  {ps1,sh}`; both hosts `fpc -B -vewn` clean; the engine/console suite stays green;
  the boundary check still passes (the engine reaches no LCL unit).

Verification method that made a windowed toolkit byte-exact: build controls and
fire events **headless** (no `Show`, no message loop) — LCL fires OnChange/OnClick
on a programmatic change, and drawing is proven by reading a pixel back. Anything
inherently modal or window-realizing (setfocus, a dialog's Execute, msgbox) is
guarded or kept out of the headless suite and exercised in the interactive host.

**Out of scope, as decided:** data-aware controls (`TDB*`) need `Data.DB` — the
external-dependency line phase 1 drew for sqlite/http. FMX-only scene features
(effects, tween animations, retained vector path, media) have no LCL equivalent
(see [gui-components.md](gui-components.md)). Remaining phase-2 nice-to-haves —
richer key/mouse event marshalling and more example apps — are optional followups,
not blockers. **Next: [phase 3](roadmap-phase3.md).**

## The one architectural question, and its answer

A console program runs start to finish. A GUI program is event-driven: it builds
controls, binds events, then blocks in a message loop, and **an event must run a
BASIC routine and return**. The engine may not know about the loop or the window,
so the seam is expressed in engine terms:

- **Host-aware functions** (`TPhosphorHostFunc` / `Registry.AddHost`) receive the
  executing VM in addition to their arguments. The GUI constructors, the event
  binders and the message-loop driver take this channel; the dozen phase-1
  libraries do not.
- **`TPhosphorVM.CallUserFunc`** runs a named BASIC routine re-entrantly over the
  running program's own globals, handles and stack, and hands its return value
  back to the host.

Both are host-agnostic — "run a BASIC routine" needs no window — so they were
built and proven in **phase-2 increment 1** with `callfunc`, entirely headless
and GUI-free. See [decisions.md](decisions.md), "The host-callback seam." This is
the analogue of phase 1's increment 1: the plumbing every later step stands on.

**Status: increment 1 DONE (2026-09-01).** `engine/PhosphorRegistry` (dual
channel), `engine/PhosphorVM` (re-entrant `CallUserFunc`), `engine/libs/
PhosphorCallLib` (`callfunc`); `tests/suite/48_callback.bas` (10 asserts) +
negative `12_callfunc_unknown`; `-B -vewn` clean, byte-exact green on Windows.

## The GUI model (shape borrowed from the reference, cleaned up)

The reference's GUI API is a good starting grammar. Mapped to Phosphor's
conventions (`@` is the handle suffix, base-1, strict boolean):

- **Constructors** answer a handle: `f@ = form@("title", w, h)`, `b@ =
  button@(f@)` (parent first). Controls are LCL objects held in the **existing
  handle registry** (`PhosphorHandles`) — the same 1-based `@` handles arrays and
  dictionaries already use, so `ResetHandles` and fabricated-handle rejection come
  for free.
- **Properties**: a named setter returns the handle (`form_caption@(f@, "x")`),
  a getter reads it (`form_caption$(f@)`, `form_width(f@)`). Named helpers cover
  the common properties; a generic `TypInfo` bridge (`control_set@`/`control_get`)
  reaches every published property by name, so the surface is not capped by how
  many helpers get hand-written.
- **Events**: `button_onclick@(b@, "handlerName")` binds an event to a BASIC
  routine by name; `""` unbinds. The handler is `function handlerName(sender@)`,
  reached through `CallUserFunc(name, [sender])`. Phosphor gives the dispatcher
  the VM at bind time rather than walking the parent chain to find it — the
  reference records that walk as the cause of several dead-event bugs.
- **Errors, not exceptions**: each library keeps a last-error code
  — in the event ONE shared slot, `gui_error()` / `gui_clearerror()`, not a pair per
  package: with one handle registry and one resolver almost every error is "this is
  not a live control of the expected class", which one slot conveys and seventeen
  would only repeat; a fabricated, nil or wrong-class handle is
  recorded and answered with an empty value, never raised — matching the phase-1
  contract and the reference's `02_handles` behaviour.
- **Message loop**: `app_run` / `app_processmessages` / `app_quit`, thin over
  `Application`. Only the interactive host enters it.

## Verification strategy (the part that is genuinely new)

A window cannot be byte-compared. Two observations make phase 2 testable to the
same standard as phase 1:

1. **The reference's GUI tests display nothing.** `00_smoke` says it outright:
   create a form and a control, round-trip a property, free it — all headless,
   all assertion-based. So the byte-exact golden methodology transfers: a GUI
   suite file is just asserts over constructors, properties and error codes.
2. **LCL fires `OnClick` (and siblings) without a window handle** — `TControl.
   Click` calls the bound method directly. So an event can be *simulated* from
   BASIC (a `xxx_click`-style trigger, or the handler invoked directly) and the
   handler's side effect (a bumped global) asserted — no message loop, no
   display, no widgetset handle. This is exactly what `48_callback` already does
   through `callfunc`.

Which **widgetset** a headless test links was the open question; a spike settled
it (2026-09-01):

- **`nogui` is out.** It raises `EAccessViolation` in `TForm.CreateNew` — the
  widgetset is built for non-visual LCL (TProcess and the like) and does not carry
  the window-server classes a form instantiates. Verified, not assumed.
- **The real widgetset, headless, works.** Under `win32` on Windows, a program
  that `Application.Initialize`s, then `TForm.CreateNew(nil)` + `TButton.Create`
  + binds `OnClick` + calls `TControl.Click` twice, records `fired = 2` — no
  `Show`, no message loop, no visible window. `Click` is a plain method call that
  fires the handler synchronously; a window handle is never needed. This is the
  phase-1 byte-exact methodology intact.

So the headless GUI runner is a **console-subsystem app linking the platform
widgetset** (win32 on Windows), writing its `passed:/failed:` summary through
`FileWrite(StdOutputHandle, …)` exactly as `phosphortest` does (that path is
byte-exact whatever the subsystem, since the golden capture redirects stdout to a
file). The interactive host is verified by hand on the Windows desktop.

Cross-platform: **both OSes are proven** (spike, 2026-09-01). Windows needs no
display at all — the win32 widgetset constructs and fires events headless. On the
Linux VM (GNOME/Wayland), the same spike built against the **gtk2** widgetset runs
against the session's **live XWayland display** and reports `fired=2` with nothing
shown — no `xvfb`, no `sudo`. The Linux GUI runner therefore exports:

    DISPLAY=:0
    XAUTHORITY=$(ls /run/user/$(id -u)/.mutter-Xwaylandauth.* | head -1)

(the auth-cookie filename carries a per-session random suffix, so it is globbed,
not hard-coded). This depends on a desktop session being logged in on the VM; if
none is, the runner skips the GUI files with a clear message rather than failing.
`xvfb-run` would remove that dependency but needs a one-time `sudo apt install
xvfb` on the VM — kept as an optional convenience, not a requirement. The engine
and console suites stay byte-exact green on both OSes regardless.

VM gtk2 build flags that worked (fpc direct, Lazarus 4.8 at `/usr/share/lazarus/
4.8.0`): `-Tlinux -dLCL -dLCLgtk2 -Fu<laz>/lcl/units/x86_64-linux/gtk2
-Fu<laz>/lcl/units/x86_64-linux -Fu<laz>/components/lazutils/lib/x86_64-linux
-Fu<laz>/packager/units/x86_64-linux` (create the `-FU` unit-output dir first).

## Sequence (each step: gate; deferral cost)

1. **Host-callback seam.** *DONE.* `callfunc` + re-entrant `CallUserFunc`, proven
   headless. **Gate:** `48_callback` byte-exact; `12_callfunc_unknown` rejects;
   `-B` clean. **Deferral cost:** every event handler stands on it.

2. **GUI host skeleton + widgetset spike.** *DONE.* Widgetset settled (above):
   `win32` headless on Windows, `gtk2` on the Linux session's live display. Both
   hosts built: `host/gui/phosphorgui.lpr` (interactive) and `host/gui/
   phosphorguitest.lpr` (headless runner, `FileWrite(StdOutputHandle)` summary),
   mirroring `host/console/`. `scripts/test-gui.{ps1,sh}` build against the
   platform widgetset and run the GUI manifest byte-exact.

3. **Form + first control + one event, end to end.** *DONE (2026-09-01).* The
   first GUI packages, isolated under `host/gui/libs/` and registered through the
   engine's registry: `PhosphorGuiCore` (the `TGuiHandle` owning/non-owning
   wrapper so `ResetHandles` frees the LCL tree once; the `TGuiEventBridge` that
   runs a handler via `CallUserFunc`; `gui_error`/`gui_clearerror`; `app_*`),
   `PhosphorFormLib` (`form@`, caption/width/height, `form_show`), `PhosphorButtonLib`
   (`button@`, `button_caption`, `button_click`, host-aware `button_onclick@`).
   Controls live in the engine handle registry; a fabricated or wrong-class handle
   is recorded in `gui_error()`, per `02_handles`. `tests/gui/00_smoke` (9) and
   `01_events` (8) are byte-exact green headless on Windows; `01_events` fires a
   real LCL `OnClick` that runs a BASIC handler mutating a global AND the button
   through its sender handle. **Gate met** (Windows); Linux gtk2 cross-run next.

4. **Property surface — the shared backbone.** *DONE (2026-09-01).*
   `host/gui/libs/PhosphorControlLib` exposes the members every `TControl` shares
   (geometry, state, colour, font, focus) once, for any control handle, plus the
   generic `TypInfo` bridge: `control_set@(h, "PropName", value)` /
   `control_get` / `control_get$` reach every published property by name, so each
   later family unit writes only its specifics. `tests/gui/02_control` (24 asserts)
   is byte-exact green headless (Windows + Linux) — named helpers, the bridge
   (string/number/bool/enum by name), an unknown property recorded not crashed,
   and free/double-free. (`control_setfocus@` guards on `HandleAllocated` so it
   never realizes a window headless — a no-op until the interactive host shows the
   form; without the guard it hung.)

5. **Control breadth + geometry + containers.** *DONE (2026-09-01).* The planned
   control subset landed as isolated packages under `host/gui/libs/`, each with a
   byte-exact GUI test file green on Windows AND Linux: text (label/edit/memo),
   choice (checkbox/radio/combobox/listbox), containers (panel/groupbox/scrollbox/
   pagecontrol+tabsheet), range (trackbar/progressbar/scrollbar), menus + timer,
   image + string grid, tree view + list view (handles generalized to any TObject
   for the non-TComponent nodes/items), canvas drawing (an off-screen bitmap +
   `canvas_*`, proven by reading a pixel back, shown in an image; the LCL-native
   answer to the reference's shapes/path) + TShape, and the common dialogs
   (configuration byte-exact; modal Execute interactive-only). Event dispatch was
   generalized (one bridge per event name; `GuiNotifyHandler`), and LCL fires
   OnChange/OnClick on a programmatic change so events are headless-testable.
   `tests/gui/00`–`10` (11 files) green on both OSes; the engine/console suite
   stays green; the interactive `phosphorgui` builds clean.

6. **Interactive examples** — a couple of small apps run on the real host, as the
   human-facing proof the loop and events deliver. *(Remaining: the pieces are all
   in place; this is the demo pass.)*

Deferred exactly as phase 1 deferred them: anything pulling an external
dependency (sqlite, http, zip, media) stays out until its own phase.

## Layout

```
host/
  console/          phase-1 consumer (unchanged)
  gui/              phase-2 consumer: LCL application
    phosphorgui.lpr   interactive host (opens windows, runs the loop)
    phosphorguitest.lpr  headless suite runner (chosen widgetset, no display)
    libs/             GUI function packages, one unit per control family, each
                      RegisterXxxFuncs(engine) — isolated exactly like engine/libs,
                      but here they MAY use the LCL (the boundary check scans only
                      engine/).
tests/gui/          the phase-2 oracle suite + goldens (assertion-based, headless)
```
