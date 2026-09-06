# Phosphor BASIC

An embeddable BASIC interpreter written in Free Pascal (FPC 3.2.2 / Lazarus).
Desktop only — Windows and Linux. MIT licensed.

The spiritual successor to Plan9Basic (Delphi/FireMonkey, now frozen). **Not a
port:** several language decisions change on purpose — see
[docs/decisions.md](docs/decisions.md).

## Status — the full language + libraries

Phosphor runs the full Plan9Basic **language + library oracle**, byte-exact green on
Windows *and* Linux: the whole `tests/suite` corpus (arithmetic, strings, arrays,
dictionaries, JSON, dates, regex, string lists, error handling, the strict-syntax
rules), the negative suite, and six opt-in host packages (crt, base64, zip, gzip,
http, sqlite). **685 built-in functions** are registered across the standard
libraries, every one of them exercised by a test and listed in the reference --
both held by a gate in the acceptance suite rather than by a promise. Errors are *values*, not
crashes: a library records its error state and the program keeps running. It is a
real, working interpreter — not a skeleton.

**Binary work is first-class.** `len` counts characters and `bytelen` counts bytes,
with `byteat`/`bytestr$`/`bytemid$` to read a string as bytes; `#` channels stream
through a sliding window and `seek`/`loc` are positionable and 1-based; and a
**buffer** (`buffer_new@`) is a mutable block of bytes behind a handle -- the same
handle `file_readallbytes@` returns, so reader, edit and writer compose without a
conversion step.

**The standard-BASIC command set from the founding brief is built** and covered by
`tests/classic` (byte-exact, both OSes): the `INPUT` / `LINE INPUT` statements and the
`INPUT$` function; classic `#`-number file I/O (`OPEN … FOR input|output|append AS #n`,
`PRINT #`, `INPUT #`, `LINE INPUT #`, `CLOSE`, and `EOF`/`LOF`/`LOC`); `PRINT USING`;
`SWAP`; and `while … wend`. These live alongside the IOUtils-style Io functions
(`file_writealltext`, `file_readalltext$`, `savetext$`, `dir_*`/`path_*`), so a file can
be worked either way. The `phosphor` host links **every** function package, so a program
it runs, compiles or packs reaches the whole library surface.
[docs/language-reference.md](docs/language-reference.md) documents it all.

What it is, precisely: an **engine-as-library** (`engine/`) that does no I/O of its
own and never names a host or GUI unit — the build fails if it does. Everything a
program can touch (the console, files, the GUI, the network) arrives through a small
host around it. Three hosts ship in this repo, plus the opt-in packages.

## Quickstart

```powershell
# Build the console host (drives fpc directly; the source of truth):
powershell -File scripts\build.ps1        # Windows
# bash scripts/build.sh                    # Linux

# Write a program:
#   println "Hello, " + "world"
bin\phosphor.exe run hello.bas
```

```
phosphor run  <file.bas>            run a program
phosphor --no-console <file.bas>    run with no console window (see below)
phosphor compile <in.bas> <out.pbc> compile to portable .pbc bytecode
phosphor pack <in.bas> <out>        build a standalone self-extracting executable
phosphor                            an interactive REPL (state persists)
phosphor --version | --help | --diag
```

**One binary, and it decides at startup.** `phosphor` links the LCL and asks a
single question when it starts: is a graphical session reachable? If it is, it brings
the widgetset up and registers the 426 LCL GUI functions alongside everything else; if
is not, it registers none of them and is a plain console interpreter. A GUI program
therefore needs no flag and no second file, and a `.bas` that never opens a window runs
identically on a desktop, over a pipe, in CI and on a headless server.

This works because **linking the LCL is not what connects to the display**. The unit
everyone reaches for, `Interfaces`, contains one thing: a `CreateWidgetset` call in its
*initialization* section — and on gtk2 that call opens the X display, before `main`,
which is why a binary that merely listed it died wherever no session existed. Name the
widgetset unit directly (`Gtk2Int` / `Win32Int` with `InterfaceBase`) and the same code
links while the call stays ours to make, when we have already checked. Measured both
ways on both platforms before this was built.

Where no session is reachable, a program that calls a GUI function is told exactly
that — `no function form@` — rather than the process dying inside gtk before `main`.
Windows always has the GUI: the win32 widgetset draws through USER32 and needs no
display server.

**Compiling needs no session either**: the compiler is host-agnostic, so `phosphor
compile <gui-app.bas> <out.pbc>` works on a headless machine, and `phosphor pack` makes
a standalone GUI application — the stub is this same complete binary.

**The console is kept by default, and can be let go.** A windowed program still has a
console, which is where `PRINT` goes — useful while developing, unwanted in something
you hand to someone. `phosphor --no-console <file.bas>` releases it at startup, and a
packed application (which ignores its command line by design) calls `crt_hideconsole()`
to do the same from inside. Both refuse to touch a console **shared with a terminal**:
run from a shell, they answer 0 and change nothing, because that window is the user's.
Printing after releasing is safe — output that was a console goes to the null device,
output redirected to a file or pipe keeps going there.

`phosphor` (the console host) is the develop-compile-run tool. There is no dedicated
IDE — write `.bas` in any editor and run it. A GUI program is run the same way,
`phosphor run <file.bas>`, and builds an LCL window; to embed the engine in your own
Pascal program, see [docs/embedding.md](docs/embedding.md).

## Learn the language

- **[docs/language-reference.md](docs/language-reference.md)** — the didactic guide:
  syntax, types, operators, control flow, functions, strings and arrays, with short
  runnable examples. Start here.
- **[docs/function-reference.md](docs/function-reference.md)** — the complete catalog
  of every built-in, by library.
- **[examples/](examples/)** — runnable programs (`crt_demo.bas`, `crt_dashboard.bas`,
  `gui_demo.bas`, …).

## Documentation for contributors

- [docs/architecture.md](docs/architecture.md) — the library/host seam, the boundary
  check, the UTF-8 policy, the Linux build.
- [docs/decisions.md](docs/decisions.md) — the frozen language decisions (five value
  types, `@` handles, base-1 indexing, strict boolean, real vs integer division, the
  opt-in execution limits) and the on-disk-bytecode format decisions.
- [docs/dev-agent-playbook.md](docs/dev-agent-playbook.md) — the hardened rules and
  round-by-round retrospective from the autonomous build loop that completed the oracle.
- [docs/gui-components.md](docs/gui-components.md) · [docs/embedding.md](docs/embedding.md)
  · [docs/roadmap.md](docs/roadmap.md).

## Layout

| path             | what                                                              |
| ---------------- | ---------------------------------------------------------------- |
| `engine/`        | the interpreter library. Host-agnostic, GUI-free.                |
| `engine/libs/`   | the standard built-in libraries (Str, Num, Array, Dict, Json, …).|
| `host/console/`  | the `phosphor` CLI: run / compile / pack / REPL.                 |
| `host/gui/`      | the 17 LCL GUI packages under `libs/`, and `phosphorguitest`, the headless runner for the GUI suite. The GUI *host* is `phosphor` itself. |
| `host/embed/`    | an example of embedding the engine.                              |
| `host/packages/` | opt-in packages: base64, zip, gzip, http, sqlite, crt.           |
| `tests/`         | six corpora: `suite` (the oracle), `negative`, `classic`, `packages`, `gui`, `skeleton`, plus the assert library and the Pascal probes. |
| `examples/`      | runnable example programs — and they are RUN: `test-examples` byte-compares each to a golden (a windowed one is compiled, since the compiler needs no display). |
| `scripts/`       | `build`, `test`, `test-suite`, `test-classic`, `test-packages`, `test-gui`, `test-examples` (`.ps1`/`.sh`), and the four source gates `coverage.py`, `check-codepage.py`, `check-sandbox.py` and `check-seams.py`.|
| `docs/`          | the documentation above.                                         |

Requirements: FPC 3.2.2 (bundled with Lazarus). Windows builds work out of the box;
Linux needs a native `fpc` — see [docs/architecture.md](docs/architecture.md), "Linux".
