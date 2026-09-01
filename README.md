# Phosphor BASIC

An embeddable BASIC interpreter written in Free Pascal (FPC 3.2.2 / Lazarus).
Desktop only — Windows and Linux. MIT licensed.

The spiritual successor to [Plan9Basic](../Plan9Basic) (Delphi/FireMonkey, now
frozen). **Not a port:** several language decisions change on purpose. See
[docs/decisions.md](docs/decisions.md).

## Status — walking skeleton

This is the phase-1 skeleton. It proves the path exists; it is **not** the
interpreter yet. Today `TPhosphorEngine` recognizes only `PRINT` / `PRINTLN` of
a string literal (plus `REM` / `'` comments). What that already demonstrates:

- the **engine-as-library** boundary — the engine does no I/O of its own and
  never names a host or GUI unit (the build fails if it does);
- **UTF-8** preserved byte-for-byte from source literal to output;
- the full **build → link → run → byte-exact golden compare** loop, on win64.

The real lexer, parser, exec core, and the five-type value model replace the
stub next. The founding brief is in [prompt-inicial.md](prompt-inicial.md).

## Quickstart

```powershell
# Build (authoritative, drives fpc directly) and run the smoke test:
powershell -File scripts\build.ps1
powershell -File scripts\test.ps1

# Run a file, or start the REPL:
bin\phosphor.exe run tests\skeleton\hello.bas
bin\phosphor.exe
```

Or open `host/console/phosphor.lpi` in Lazarus and build (Ctrl+F9).

Requirements: FPC 3.2.2 (bundled with Lazarus). Windows builds work out of the
box here; Linux needs a native `fpc` (or a cross toolchain) — see
[docs/architecture.md](docs/architecture.md), "Linux".

## Layout

| path             | what                                                     |
| ---------------- | -------------------------------------------------------- |
| `engine/`        | the library. Host-agnostic, GUI-free. `PhosphorEngine.pas`. |
| `host/console/`  | first consumer: REPL + file runner (`phosphor`).         |
| `tests/skeleton/`| day-1 smoke test + golden output.                        |
| `scripts/`       | `build.ps1` (source of truth), `test.ps1`.               |
| `docs/`          | [architecture](docs/architecture.md), [decisions](docs/decisions.md). |

## Documentation

- [docs/architecture.md](docs/architecture.md) — the library/host seam, the
  boundary check, UTF-8 policy, the phase plan, and the Linux build gap.
- [docs/decisions.md](docs/decisions.md) — the frozen language decisions (five
  types, `@` handles, base-1, strict boolean, …) and the on-disk-bytecode
  decisions taken up front.
