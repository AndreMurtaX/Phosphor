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
http, sqlite). **682 built-in functions** are registered across the standard
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
phosphor compile <in.bas> <out.pbc> compile to portable .pbc bytecode
phosphor pack <in.bas> <out>        build a standalone self-extracting executable
phosphor --gui <file.bas>           run a GUI program (hands over to phosphorgui)
phosphor                            an interactive REPL (state persists)
phosphor --version | --help | --diag
```

Two binaries ship, and the split is deliberate. `phosphor` is the headless host —
engine plus every non-GUI package — and works over a pipe, in CI and on a server with
no display. `phosphorgui` (built by `scripts/build-gui.ps1` / `.sh`) is the **complete**
runner: the same packages *plus* the 346 LCL GUI functions. `phosphor --gui` hands over
to it, so one command reaches everything.

The LCL cannot simply be loaded on demand: on Linux the gtk2 widgetset opens the X
display in a unit *initialization* section, before `main`, so a binary that merely links
it exits with `cannot open display` wherever none is reachable — a runtime flag cannot
undo a link-time decision.

Both binaries therefore check for a session first and say so plainly instead of letting
gtk print its bare warning: with neither `DISPLAY` nor `WAYLAND_DISPLAY` set they
explain the problem, suggest `DISPLAY=:0 phosphor --gui …` or `phosphor run …`, and exit
with code **3** (distinct from `1` program error and `2` usage, so a script can tell them
apart). `phosphorgui` manages this by listing a guard unit *before* `Interfaces`, which
puts its initialization ahead of the widgetset's. Windows needs no display, so the guard
is Unix-only.

**Compiling needs neither host**: the compiler is host-agnostic, so `phosphor compile
<gui-app.bas> <out.pbc>` already works — and both runners accept either a `.bas` or the
`.pbc` it produces.

`phosphor` (the console host) is the develop-compile-run tool. There is no dedicated
IDE — write `.bas` in any editor and run it. For a GUI program, `phosphorgui
<file.bas>` runs a `.bas` that builds an LCL window; to embed the engine in your own
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
| `host/gui/`      | `phosphorgui`, the LCL GUI host.                                 |
| `host/embed/`    | an example of embedding the engine.                              |
| `host/packages/` | opt-in packages: base64, zip, gzip, http, sqlite, crt.           |
| `tests/`         | the byte-exact oracle suite, negatives, classic tests, packages. |
| `examples/`      | runnable example programs.                                       |
| `scripts/`       | `build`, `build-gui`, `test-suite`, `test-packages`, `test-classic` (`.ps1`/`.sh`), `coverage.py`.|
| `docs/`          | the documentation above.                                         |

Requirements: FPC 3.2.2 (bundled with Lazarus). Windows builds work out of the box;
Linux needs a native `fpc` — see [docs/architecture.md](docs/architecture.md), "Linux".
