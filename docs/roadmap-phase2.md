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
  (`xxx_error()` / `xxx_clearerror()`); a fabricated, nil or wrong-class handle is
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

The open question is which **widgetset** a headless test links. Options, to be
settled at increment 2 with a spike, not guessed here: the `nogui` widgetset
(LCL object model without a display — ideal if it constructs `TForm`/`TButton`);
failing that, the real widgetset under a virtual display on the Linux VM
(`xvfb-run`) and a normal desktop session on Windows. The interactive host is
verified by hand on the Windows desktop regardless.

## Sequence (each step: gate; deferral cost)

1. **Host-callback seam.** *DONE.* `callfunc` + re-entrant `CallUserFunc`, proven
   headless. **Gate:** `48_callback` byte-exact; `12_callfunc_unknown` rejects;
   `-B` clean. **Deferral cost:** every event handler stands on it.

2. **GUI host skeleton + widgetset spike.** A `host/gui/` program (LCL app) that
   opens one window and runs the loop, and a decision on the headless widgetset
   for the test runner. Mirrors `host/console/`. **Gate:** the window opens on the
   Windows desktop; the headless runner links its chosen widgetset and constructs
   a `TForm` without a display. **Deferral cost:** picks the whole verification
   path; wrong choice reworks the test harness.

3. **Form + first control + one event, end to end.** `form@`, `button@`,
   `button_onclick@`, a simulated click running a BASIC handler that mutates a
   global — the `07_engine_by_parent` / `11_form_events` shape, adapted. Controls
   enter the handle registry; fabricated/wrong-class handles reject per
   `02_handles`. **Gate:** a GUI suite file (adapted from the reference) byte-exact
   green headless; the interactive host shows the form and the click works.

4. **Property surface.** Named helpers for common properties + the `TypInfo`
   generic bridge; the `08_property_roundtrip` methodology (write back what was
   read; assert neither half errors). **Gate:** an adapted property-roundtrip file
   green.

5. **Control breadth + geometry + containers**, one isolated library unit per
   family under `host/gui/libs/` (mirroring `engine/libs/`): label, edit,
   checkbox, panel, listbox, image, timer, … Each imports its reference test,
   adapted to Phosphor's conventions. **Gate:** each family's file green as it
   lands.

6. **Interactive examples** — a couple of the reference's small games/apps run on
   the real host, as the human-facing proof the loop and events deliver.

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
