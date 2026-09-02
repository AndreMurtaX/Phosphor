# Phosphor BASIC

An embeddable BASIC interpreter written in Free Pascal (FPC 3.2.2 / Lazarus).
Desktop only — Windows and Linux. MIT licensed.

The spiritual successor to Plan9Basic (Delphi/FireMonkey, now frozen). **Not a
port:** several language decisions change on purpose — see
[docs/decisions.md](docs/decisions.md).

## Status — a complete interpreter

Phosphor runs the full Plan9Basic **language + library oracle**, byte-exact green on
Windows *and* Linux: the whole `tests/suite` corpus (arithmetic, strings, arrays,
dictionaries, JSON, dates, regex, string lists, error handling, the strict-syntax
rules), the negative suite, and nine opt-in host packages. Around **700 built-in
functions** are registered across the standard libraries. Errors are *values*, not
crashes: a library records its error state and the program keeps running.

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
phosphor                            a line-at-a-time REPL
phosphor --version | --help | --diag
```

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
| `tests/`         | the byte-exact oracle suite, negatives, and package tests.       |
| `examples/`      | runnable example programs.                                       |
| `scripts/`       | `build.{ps1,sh}`, `test-suite.{ps1,sh}`, `test-packages.{ps1,sh}`.|
| `docs/`          | the documentation above.                                         |

Requirements: FPC 3.2.2 (bundled with Lazarus). Windows builds work out of the box;
Linux needs a native `fpc` — see [docs/architecture.md](docs/architecture.md), "Linux".
