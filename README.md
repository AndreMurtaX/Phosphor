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
http, sqlite). **715 built-in functions** are registered across those libraries and
packages together -- 534 names from `engine/libs` and 181 from `host/packages` -- and
the `phosphor` binary registers all of them, which is why the resolution section below
points back at this number instead of stating a second one. Every one is exercised by
a test and listed in the reference -- both held by a gate in the acceptance suite
rather than by a promise. Errors are *values*, not
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
phosphor compile [--check] <in.bas> <out.pbc> compile to portable .pbc bytecode
phosphor pack [--no-console] <in.pbc> <out>   standalone executable (from bytecode)
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

**A function name is resolved when the program runs, not when it compiles** — and
that is what makes a `.pbc` portable. Which functions exist is a *host's* decision:
`phosphor` registers all 715 names counted above — it links every package — the
package test runner adds the assertion library, and the GUI runner adds 426 more, as
does `phosphor` itself wherever a graphical session is reachable. No GUI name
collides with a library name, so that is 1141 in one process. The compiler has no
registry at all and cannot know which names will exist; the VM asks whichever host
loaded the program.

The cost is that a typo survives until the line runs, so the two moments where the
host IS known now check:

- **`phosphor pack` refuses** a `.pbc` that calls a name this binary cannot provide,
  and names it with the line that first calls it. It can be certain: the executable
  it writes carries this very binary as its stub, so no other host will ever load
  that payload. Portability is not lost here — packing is where you give it up on
  purpose.
- **`phosphor compile --check` warns** and carries on, exit 0, `.pbc` written. A
  name this host lacks is not necessarily a mistake; the file may be meant for a
  host that has it.

**The console is kept by default, and can be let go.** A windowed program still has a
console, which is where `PRINT` goes — useful while developing, unwanted in something
you hand to someone. `phosphor --no-console <file.bas>` releases it at startup;
`phosphor pack --no-console <in.pbc> <out>` **bakes the choice into the executable**,
which is what a packed application needs because it ignores its command line by
design; and `crt_hideconsole()` does the same from inside a program that decides for
itself. Both refuse to touch a console **shared with a terminal**:
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

## The six source gates

After the acceptance corpus, `test-suite` runs six Python checks over the *source* —
invariants no compiler can check and no golden happens to cover. They run in the
suite rather than in the build, because building should not need Python but passing
should mean the invariants hold; and a missing interpreter **fails** the run instead
of skipping them, since a gate that quietly does not run reads as a pass. Unlike the
function totals above, *nothing checks this list* — `coverage.py` gates four named
claims and the number of gates is not one of them — which is how `check-suffix.py`
and `check-examples.py` joined the suite on 2026-09-06 and were named nowhere here.
It is verified the only way it can be: by reading `scripts/test-suite.ps1` and
`scripts/test-suite.sh`, which run the same six on both platforms.

| gate | what it refuses to let through |
| ---- | ------------------------------ |
| `coverage.py` | a registered built-in that no test calls, that the function reference omits, or that its own library page does not describe — and, the other way round, a function name or a count a document states that the registry does not back. |
| `check-codepage.py` | a `Char` concatenated into a code-page string, where every byte `>= 128` is silently destroyed. The class has been swept three times. |
| `check-sandbox.py` | a routine a script can reach that touches the filesystem without asking the sandbox gate first — or without being exempt by name, with a reason. |
| `check-seams.py` | a host that neither fills an engine seam (`OnOutput`, `OnInput`, `OnBreakpoint`, `HostServices`) nor records why leaving it nil is right. A nil seam answers silently. |
| `check-suffix.py` | a registered name whose type suffix is not the kind its body returns. The suffix *is* the return-type system for built-ins, and fifteen registrations lied. |
| `check-examples.py` | a `basic` code block in the docs that does not compile. `coverage.py` already refuses a block calling a function that does not exist; it cannot refuse one whose names are all real and whose syntax is wrong. |

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
| `scripts/`       | `build`, `test`, `test-suite`, `test-classic`, `test-packages`, `test-gui`, `test-examples` (`.ps1`/`.sh`), and the six source gates described above.|
| `docs/`          | the documentation above.                                         |

Requirements: FPC 3.2.2 (bundled with Lazarus). Windows builds work out of the box;
Linux needs a native `fpc` — see [docs/architecture.md](docs/architecture.md), "Linux".
