# Phosphor BASIC — architecture

An embeddable BASIC interpreter in Free Pascal (FPC 3.2.2 / Lazarus). Desktop
only: Windows and Linux. The spiritual successor to Plan9Basic, not a port —
several language decisions change on purpose (see [decisions.md](decisions.md)).

## The one rule

**The engine is a library. The host is a consumer of it.** The engine knows
nothing about **consoles, windows, or the LCL**: everything a program *prints*
leaves through a callback, everything it *reads from the user* comes back the same
way, and the engine cannot tell which host it is talking to. The console host is
merely the first consumer; the GUI host is another.

The engine does reach the **filesystem** directly, and that is deliberate rather
than an exception to the rule: `engine/libs/PhosphorIoLib` implements 58 names on
`TFileStream`/`FileExists`/`ForceDirectories`, and the `#`-channel statements live
in the VM. A file is not a user interface — it needs no callback to be portable,
and routing it through one would have made every host reimplement it. What the rule
protects is the *interaction* surface, which is what differs between a terminal, a
window and an embedder.

This is enforced, not just intended. `scripts/build.ps1` scans every `engine/`
unit's `uses` clauses and fails the build if one names a host- or GUI-facing
unit (`crt`, `lcl`, `forms`, `windows`, `unix`, …). It is the Phosphor
equivalent of Plan9Basic's FireMonkey-boundary check, and like that one it is
meant to catch the mistake before it can be linked.

## Layout

```
Phosphor/
  engine/                 the library core. Host-agnostic, GUI-free, no I/O of its own.
    PhosphorEngine.pas      public facade (TPhosphorEngine, OnOutput callback).
    PhosphorValue/Errors/Opcodes/Lexer/Compiler/VM/Registry/Handles.pas  the core.
    PhosphorSandbox.pas     the filesystem ceiling: the one place that decides
                          whether a path a script named may be touched. Every
                          library that opens, lists, writes or deletes asks it,
                          and scripts/check-sandbox.py fails the suite if one
                          stops asking.
    libs/                 function packages, integrated only through the registry
                          (like Plan9Basic's engine/Libs): PhosphorArrayLib,
                          PhosphorDictLib, ... The engine registers them in Create.
  host/
    console/              the first consumer: REPL + file runner.
      phosphor.lpr          program; produces the `phosphor` binary.
      phosphor.lpi          Lazarus project file (opens/builds in the IDE).
    gui/                  the second consumer: 17 LCL packages under libs/, plus
                          phosphorgui (the interactive host) and phosphorguitest.
    packages/             the six opt-in packages a host may register.
    embed/                the third consumer: phosphorembed, which is what the
                          embedding API is tested through.
  tests/
    skeleton/            day-1 smoke test (hello.bas + golden hello.expected).
    suite/ negative/ classic/ packages/ gui/   the corpora that grew from it.
  scripts/
    build.ps1            authoritative build (drives fpc directly).
    test.ps1            build + run + byte-exact golden compare.
  docs/
    architecture.md     this file.
    decisions.md        frozen language & on-disk-bytecode decisions.
  bin/                    build output (git-ignored).
```

### Why the engine has no I/O of its own

`TPhosphorEngine` exposes `OnOutput: procedure(const AText: String) of object`.
`PRINTLN` puts the trailing LF into the text it emits; `PRINT` does not. The
host writes those bytes wherever it likes and never has to reason about line
endings. Input, when it lands, arrives by the same kind of callback — synchronous
(see [decisions.md](decisions.md), "Input"). This is the seam that let
Plan9Basic's engine run headless in `NoFmxProbe`, and it is the starting point
here rather than a retrofit.

## Build

```powershell
# Authoritative build (fpc), then the smoke test with a byte-exact golden compare:
powershell -File scripts\build.ps1
powershell -File scripts\test.ps1
```

Or open `host/console/phosphor.lpi` in Lazarus and build (Ctrl+F9). Both paths
are kept working; `scripts/build.ps1` is the source of truth.

Two habits the scripts encode, both inherited from how this project is run:

- **Trust the artifact, not the exit code.** After compiling, `build.ps1`
  checks the binary exists and actually runs (`--version`) before reporting
  success — a step can "succeed" having produced nothing.
- **A check is only trusted once seen to fail.** `test.ps1 -ProveFailure`
  corrupts the expectation on purpose so you can watch the comparison report
  FAIL, then a plain run shows PASS.

## UTF-8

UTF-8 everywhere, stated explicitly, resolved on day one rather than discovered
later — FPC's string types (AnsiString / UTF8String / UnicodeString) are a
minefield otherwise.

- Sources are UTF-8. Units carry `{$codepage UTF8}` so Pascal string literals
  are UTF-8 bytes.
- The engine never transcodes source bytes: it slices literals out of the
  source string and hands the raw bytes to the host. What you typed is what
  comes out.
- The console host writes output as raw bytes straight to the OS stdout handle,
  so the golden comparison is byte-exact regardless of the console's codepage. On
  Windows, when that handle is an interactive console it writes through the
  console's native Unicode API (`WriteConsoleW`) instead; it does **not** change the
  console's code page, because switching to 65001 is exactly the unreliable path
  that approach exists to avoid. Redirected to a file or a pipe, it is raw bytes
  either way. A source may be saved with a UTF-8 BOM; the host strips it.

## Phases

1. **Done.** Engine + non-graphical libraries + console host (REPL and file
   execution). The five-kind value model, the `:`-separated registry, the
   record-don't-raise error state and the stack VM replaced the day-1 stub; a
   byte-exact oracle subset passes on Windows and Linux. See
   [roadmap.md](roadmap.md).
2. **Done.** GUI over the LCL — a *second consumer* of the same engine, which
   still never knows it exists. Controls are reached through named helper
   functions plus a generic `TypInfo` bridge for every published property, with
   events bound by name; LCL events are synchronous method pointers on the main
   thread, so the mobile-era marshalling is simply gone. 17 isolated packages
   under `host/gui/libs/`, verified byte-exact headless on both OSes. See
   [roadmap-phase2.md](roadmap-phase2.md) and [gui-components.md](gui-components.md).
3. **Done.** Robust and deployable, all five steps: the catchable language-level
   error model (`ON ERROR` / `resume` / `resume next`, re-entrant across calls),
   execution limits so a host can run untrusted scripts safely — `MaxSteps`,
   `MaxOutputBytes` and `TimeoutMs`, each `0` by default meaning unlimited and
   costing nothing, plus a fixed call-depth ceiling, the documented embedding API
   with `phosphorembed` as a third consumer, the on-disk bytecode (`.pbc`, validated
   on load rather than trusted), and the self-extracting deployment stub --
   `phosphor pack app.bas app.exe` appends a payload to the stub binary, so the same
   binary is the CLI bare and the application packed. See
   [roadmap-phase3.md](roadmap-phase3.md), which carries the per-step record.

## The GUI host and the display guard

Two host binaries ship because the LCL cannot be loaded on demand. On Linux the
gtk2 widgetset opens the X display from a unit *initialization* section, before
`main` runs — so a binary that merely **links** the LCL dies with gtk's bare
`cannot open display` wherever no session is reachable, and no runtime flag can
undo that. The headless `phosphor` therefore does not link it; `phosphorgui`
does, and `phosphor --gui` hands over.

That same load order is what makes the guard work, and it is fragile enough to
state plainly:

> `PhosphorDisplayGuard` **must stay first in `phosphorgui.lpr`'s `uses`
> clause**, ahead of `Interfaces`. Unit initialization runs in `uses` order, so
> first means *before the widgetset touches the display*. Move it and the guard
> still compiles, still passes its tests on Windows, and silently stops working
> on Linux.

The guard checks `DISPLAY` and `WAYLAND_DISPLAY` (either is enough), and when
both are empty it explains the situation, points at `DISPLAY=:0 phosphor --gui
<file>` and at `phosphor run <file>`, and halts with **exit code 3** — separate
from `1` (program error) and `2` (usage) so a script can tell "no display" from
"your program failed". `phosphor --gui` runs the same check inline before it
execs, so the user gets a message either way rather than gtk's bare `cannot open
display`. The two texts are written separately and each names its own binary, so
they read alike without being byte-identical. On
Windows there is no display to miss, so the whole guard is `{$IFDEF UNIX}`.

A `DISPLAY` that is *set but broken* still fails inside gtk; the guard is aimed
at the common, confusing case — an ssh session, a service, a container.

## Linux

Desktop means Windows **and** Linux, but this machine can build only Windows
today. Concretely, what is installed:

- FPC 3.2.2 with the `x86_64` code generator (`ppcx64.exe`) — the compiler can
  *target* Linux, the CPU is the same.
- RTL/packages compiled **only** for `x86_64-win64` (`units/x86_64-win64`).
- Binutils **only** for `x86_64-win64`.

What a Windows→Linux cross-build additionally needs, and what is missing:

1. FPC RTL + packages built for `x86_64-linux` (`units/x86_64-linux`).
2. Cross binutils targeting Linux (`x86_64-linux-gnu-ld`, `-as`).
3. Target system libraries (libc and friends) to link against.

`scripts/build.ps1 -TargetOS linux` stops with this explanation rather than
emitting a broken command.

Two supported ways to get a Linux binary, in order of preference:

- **Build natively on Linux** (recommended). The phase-1 engine and console host
  are plain console FPC with no external dependencies, so a native `fpc` on a
  Linux box, in WSL2, or on a Linux CI runner compiles the same sources
  unchanged. The console host is already portable: it guards the Windows console
  API with `{$IFDEF WINDOWS}` and falls back to raw UTF-8 bytes on Unix (where
  the terminal is UTF-8 natively). Run, from a checkout on the Linux machine:

  ```
  bash scripts/build.sh          # build the console host
  bash scripts/build-gui.sh      # build phosphorgui (needs the LCL; see below)
  bash scripts/test.sh           # skeleton smoke test (byte-exact golden)
  bash scripts/test-suite.sh     # the oracle suite + negatives
  bash scripts/test-classic.sh   # the standard-BASIC command set + the REPL
  bash scripts/test-packages.sh  # the opt-in host packages
  python3 scripts/coverage.py    # every built-in is tested AND documented
  ```

  These are the Unix counterparts of the `.ps1` scripts (same boundary check,
  same byte-exact goldens; the `.expected` files are marked `-text` so their LF
  bytes are identical on both platforms). `lazbuild host/console/phosphor.lpi`
  also works on Linux and is the IDE path.

  **Verified 2026-09-01** on Ubuntu (Linux 6.8, x86_64, FPC 3.2.2): all three
  scripts pass natively — the four suite files and four negatives are byte-exact
  green, the goldens are identical to the Windows run, and UTF-8 output renders
  correctly through the raw-byte path. Phosphor is confirmed cross-platform.
- **Cross-compile from Windows.** Install the FPC cross bits above
  (`fpcupdeluxe` is the usual way to add the `x86_64-linux` cross target and its
  binutils on Windows). Workable, more moving parts; revisit if a Windows-only
  release workflow ever needs it.

The bytecode format (a later phase) is defined little-endian with a fixed
`Double`, so the same `.pbc` runs under either OS; only the self-extracting stub
is per-platform. See [decisions.md](decisions.md), "On-disk bytecode".
