# Changelog

## Unreleased

- **A crypto library** in the engine, always available
  ([docs/libraries/crypto.md](docs/libraries/crypto.md)): `sha256$`, `sha1$`,
  `md5$`, `hmac_sha256$`, `pbkdf2_sha256$`, and `password_hash$` /
  `password_verify?` for storing passwords as salted PBKDF2 records in Django's
  format (600 000 rounds by default), plus `crypto_equal?`, a comparison whose
  timing does not depend on where two strings differ.
- **A string grid can be a record list**: `stringgrid_row` / `stringgrid_col`
  read the cursor, `stringgrid_cursor@` moves it, and `stringgrid_onselect@`
  calls a handler when it moves. And **a double click** on any control:
  `control_ondblclick@`, with `control_dblclick@` to deliver one from code.

## 0.1.0 -- 2026-10-10

The first release: an embeddable BASIC interpreter in Free Pascal 3.2.2, for
Windows and Linux, MIT licensed. One binary, `phosphor`, is the interpreter, the
REPL, the bytecode compiler, the packer, the debugger and the GUI host. Start
with [docs/getting-started.md](docs/getting-started.md).

### What is in it

- The language: structured BASIC with functions, base-1 strings and arrays,
  `on error goto` / `resume`, and the classic command set -- `INPUT`, `#`-channel
  file I/O, `PRINT USING`, `SWAP`, `while ... wend`.
- 721 built-in functions across the engine libraries and the opt-in packages:
  files and directories, strings, numbers, dates, JSON, regex (find and split),
  dictionaries and arrays, byte buffers, configuration files, base64, zip,
  gzip, SQLite, HTTP and HTTPS (GET and POST), a terminal library, and GUI
  controls through the LCL.
- `phosphor compile` to portable `.pbc` bytecode, `phosphor pack` to a
  standalone executable, and `phosphor debug` with a socket protocol for an
  editor.
- An embedding API (`TPhosphorEngine`) with execution ceilings a host can set:
  steps, time, output, memory, handles, and a filesystem sandbox root.

### How it was checked

Every suite is byte-exact on Windows and Linux, in CI on clean machines and on
the development machines; ten source gates hold rules that prose cannot (every
built-in is called by a test and documented, every path a script can reach
asks the sandbox, every loop over a script-chosen count consults the budget,
and more -- see the README). Four adversarial rounds before this release found
and fixed 71 defects, each with a test seen failing first. The full record is
in [docs/dev-agent-playbook.md](docs/dev-agent-playbook.md).

### Known limits -- read these before trusting a script you did not write

- **The console host sets no time or memory ceiling.** `phosphor` bounds a
  script only by `--sandbox`; a host that embeds the engine sets the other
  ceilings itself ([docs/embedding.md](docs/embedding.md)).
- **Not yet attacked systematically:** the filesystem sandbox, the regex
  guard, and the debug protocol over HTTP were each reviewed and tested, but
  the generated adversarial sweeps the other areas received have not been run
  against them.
- **Open:** an image whose frame is larger than the size it declares (a GIF
  frame past its logical screen; a JPEG whose frame header sits past its first
  4096 bytes) is decoded in full before the GUI's size check sees it. Do not
  load untrusted images in a GUI program.
- **Open question:** whether OpenSSL and the GUI widgetsets can raise a
  floating-point exception from inside their own code, as SQLite could before
  this release, has not been measured.
- **Regex depth:** to keep the matcher off the stack's end, a pattern that
  repeats a group is refused past a text length the remaining stack allows --
  about 5 KB for a CSV-line pattern on Windows' main thread. Single-character
  repeats (`a*`, `.*`, `[0-9]+`) have no such limit.
- **Version 0.x:** the language and the embedding API may still change.
