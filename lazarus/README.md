# Phosphor for Lazarus

Two things live here: a **package** you add to your project, and a **demo
application** that shows what adding it looks like.

Everything else about the API is in [docs/embedding.md](../docs/embedding.md).
This page is only about getting the units into your project.

## The package

`phosphor_engine.lpk` is the **engine and its built-in libraries — 29 units, no
LCL**. It is what an embedder links: the lexer, the compiler, the VM, the value
kernel, the sandbox, the budget, and the libraries a script gets for free
(strings, arrays, dictionaries, JSON, dates, files, regex).

It is a **runtime** package, so it is *used by projects* and is not installed
into the IDE — there are no components to drop on a form. Register it once:

```bash
lazbuild --add-package-link lazarus/phosphor_engine.lpk
```

(`--add-package`, the flag for design-time packages, refuses a runtime package
and says so. That refusal is correct.)

Then, in your own project: **Project → Project Inspector → Add → New
Requirement → phosphor_engine**. Or add it to the `.lpi` by hand:

```xml
<RequiredPackages>
  <Item>
    <PackageName Value="phosphor_engine"/>
  </Item>
</RequiredPackages>
```

Its only declared dependency is `FCL`, for `fpjson`. It also uses `RegExpr`,
which ships with FPC and resolves from the default unit path.

**What is deliberately NOT in it.** The console host, the GUI bindings
(`host/gui/libs`, 17 units that need the LCL) and the opt-in packages
(`host/packages`: zip, gzip, http, sqlite, base64, crt — each with its own
external dependency). A host adds those itself when it wants them, which is the
whole point of the seam: your application decides what a script can reach.

## The demo

```bash
lazbuild lazarus/demo/phosphor_demo.lpi
```

or open `lazarus/demo/phosphor_demo.lpi` in the IDE and press Run. Five
examples, and the fifth is the interesting one:

| | |
|---|---|
| 1 | a script printing, and calling functions the **application** registered |
| 2 | the script handling its own error with `ON ERROR` |
| 3 | nobody handled it, so the host is told — the ordinary case |
| 4 | a runaway loop meeting a ceiling `ON ERROR` **cannot** catch |
| 5 | **a bug in the host's own code**, contained, application still standing |

### How it is arranged, and why

`phosphordemorunner.pas` holds every decision — registering the host's
functions, setting the ceilings, running a script, classifying what came back —
and it has **no LCL in it**. `mainform.pas` is six controls and two clicks, with
no decisions at all.

That split is not tidiness. A windowed application is a program nothing runs:
its only entry point is a person clicking, and this project has twice found a
defect by hand on a path nothing automated ever executed. So
`demo_smoke.lpr` calls straight into the runner and asserts all five outcomes,
headless, on both operating systems, on every suite run — it is `probe_demo` in
`test-suite`. The window itself is compiled by `test-gui`, which catches a demo
that stopped building.

The integration you came here to copy is nine lines, and it is in
`phosphordemorunner.pas`:

```pascal
eng := TPhosphorEngine.Create();
eng.OnOutput := @sink.Take;             // where print goes
eng.Registry.Add('app_name$:', @h_app_name);   // your own functions
eng.Registry.Add('app_log:$',  @h_app_log);
eng.MaxSteps := 2000000;                // ceilings, for a script you did not write
eng.TimeoutMs := 3000;
eng.MaxOutputBytes := 1024 * 1024;
eng.ContainFaults := True;              // keep your process if the engine faults
rc := eng.Run(source);
```

The suffix on a registered **name** is its return type: `app_name$` answers a
string, `app_log` answers a number. The codes after the `:` are its arguments.

### Two handlers, not one

The demo installs `Application.OnException` **as well as** setting
`ContainFaults`, and an application embedding any interpreter wants both. They
cover different ground:

- `ContainFaults` keeps a fault inside the **interpreter** from ever reaching
  your program.
- `Application.OnException` catches a fault in **your own** code — a nil
  control, a bad cast in an event handler — which no interpreter setting can do
  anything about.

Without the second one, the LCL answers with a modal dialog. On a machine with
nobody in front of it, a modal dialog is a *hang*: no message, no exit code,
nothing in a log. That is worse than the crash it replaced.
