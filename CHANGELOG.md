# Changelog

## Unreleased

- **A crypto library** in the engine, always available
  ([docs/libraries/crypto.md](docs/libraries/crypto.md)): `sha256$`, `sha1$`,
  `md5$`, `hmac_sha256$`, `pbkdf2_sha256$`, and `password_hash$` /
  `password_verify?` for storing passwords as salted PBKDF2 records in Django's
  format (600 000 rounds by default), plus `crypto_equal?`, a comparison whose
  timing does not depend on where two strings differ.
- **A string grid can be a record list**: `stringgrid_row` / `stringgrid_col`
  read the cursor, `stringgrid_cursor@` moves it, `stringgrid_onselect@`
  calls a handler when it moves, and `stringgrid_colwidth@` sizes one column.
  And **a double click** on any control:
  `control_ondblclick@`, with `control_dblclick@` to deliver one from code.
- **Modal forms**: `form_showmodal(f@)` shows a form as a dialog and answers
  its result once a button with `button_modalresult@` is pressed, a handler
  calls `form_modalresult@`, or the form is closed (`2`). In the GUI test
  runner a modal form is acted in by a function queued with `gui_test_modal`.
- **A real application among the examples**:
  [examples/contact_manager.bas](examples/contact_manager.bas) keeps suppliers,
  customers, their contacts (social media, WhatsApp, the product lines they
  serve) and the history of what was said to them in SQLite, behind a login with
  users, roles and hashed passwords. `PHOSPHOR_CONTACTS_DEMO=1` opens it on
  sample data. It tests itself: with `PHOSPHOR_SELFTEST=1` it builds its windows
  without showing them and drives them, and `test-examples` runs it that way on
  both systems (a new `selftest` mode, under `xvfb-run` on Linux). Its tour is
  [docs/contact-manager.md](docs/contact-manager.md).

### Fixed (adversarial round 5, 2026-10-10)

- `password_verify?` accepted wrong passwords when a record's hash was shorter
  than 32 bytes, and accepted records Django refuses; only Django's canonical
  record is a record now. PBKDF2 charges the salt and the password to the
  execution budget, not only the rounds.
- On Windows a program's arguments are split by Microsoft's rules
  (`CommandLineToArgvW`): `\"` and a backslash before a closing quote no longer
  mangle or merge arguments. Arguments that are not UTF-8 arrive as U+FFFD; an
  empty file name is refused; `--` before the file and `-` after it work.
- Modal forms: `END` in a handler ends the program even while a modal is up;
  answering a modal no longer ends `app_run`; controls freed inside a modal are
  released during it; a form parented inside another is refused. A timer's
  handler is no longer re-entered while it waits (Windows did, Linux did not).
  In the GUI test runner, a modal session now behaves as `ShowModal` does --
  visible, `onclosequery` and `onclose` on an answer, a veto keeps it open for
  the next queued function.
- `stringgrid_row` / `stringgrid_col` answer 0 for a grid with no scrollable
  cell, and a very negative cursor position lands on the first cell.
- The contact manager: 14 defects, from an unopenable database leaving an
  invisible process to tax ids bypassed by punctuation, the 2026 alphanumeric
  CNPJ, non-ASCII case, quadratic list refreshes, and a backup onto the open
  database; its database schema is now version 2, migrated in place. Its
  self-test has 133 checks.

### Fixed (adversarial round 7, 2026-10-11)

- **Library work that grows with what the script hands in is priced.** About
  fifty functions whose work is linear in a string or container argument charged
  nothing -- `ucase$`, `len`, the slicers, `val`, `environ$`, the `path_*`
  family, `dict_get`, `strings_values$`, `json_clone@`, `crypto_equal?`,
  `buffer_equal` and their siblings -- so under MaxSteps 1000000 / TimeoutMs 2000
  a 200-call loop over a 50 MB string ran up to 36x past the clock and reported
  success. Every such pass now asks the budget at a measured per-family price
  (`BudgetMilli*` in `engine/PhosphorBudget.pas`): up front when its size is
  known, for what it read when only the walk can tell. Five routines that were
  worse than linear are linear now: `strings_delimitedtext`, `rag_analyze$`,
  `funcexists?`, `word$`/`wordcount`, and the join behind `dir_getfiles$`. A JSON
  render the budget stops is the calling function's limit error, not `""`.
  `scripts/check-budget.py` gained a linear pass that sees the class, and
  `docs/embedding.md` says exactly what is bounded.
- GUI: a modal session's in-session release freed objects an LCL method was still
  running on (a radio button whose check opened the modal, freed inside it, crashed
  the outer `radio_checked@`). A session now releases only what was made inside
  it; everything older waits until no handler is running.
- GUI: a form embedded in another counted as a window, so closing the main window
  left `app_run` running with nothing on screen; and whether `app_run` ended
  depended on statement order ("close A, then hide B" ran forever). A window is now
  a visible, top-level, non-modal form, and every window that leaves the screen --
  closed or freed -- asks `app_run`, which answers once every handler has returned.
  Hiding is not closing. The docs no longer say anything terminates the application.
- On Windows, `getkey$`/`inkey$` dropped any character outside the BMP, and INPUT
  at a console split a typed line longer than 8191 UTF-16 units (a pair at the cut
  became two U+FFFD): a key is now its whole character, a line its whole line.
  `cfg_path$` reads the application name from the wide executable name; a TEMP or
  TMP holding an unpaired surrogate is skipped. `compile` and `pack` refuse a
  misspelt option instead of writing it as the output file. Each of the nine
  round-6 surrogate guards on the command line now has a case of its own.
- **Contact manager: its own unfinished database no longer locks it out.** A file
  it left mid-upgrade or before its first commit (unmarked, a journal beside it)
  was refused as possibly another program's; it is now judged on a temp copy that
  SQLite recovers as it would the real one, so the program's own files open and
  another program's file and journal stay byte for byte as they were. The damage
  check compares indexes and foreign keys too (a file missing the unique user-name
  index let `josé` and `JOSÉ` in as two users); an earlier version's file that lost
  a column is named for that; `fold$` steps a stray byte alone, as `alcase$` does.
  194 self-test checks.

### Fixed (adversarial round 6, 2026-10-10)

- On Windows a command-line word holding an unpaired UTF-16 surrogate was
  silently shortened (FPC's UTF8Encode drops it), so `phosphor` could run or
  overwrite a different file than the one named. A program's argument now keeps
  it as U+FFFD; a word `phosphor` would use as a path is refused.
- A modal session no longer frees what the handler that opened it still stands
  on (heap corruption when a timer's own tick opened the modal and a later
  round freed it); a handler that re-binds itself no longer garbles the fault
  report; `END` inside a modal reports no spurious faults; a modal dialog does
  not keep `app_run` alive; a form cannot be re-parented while modal; in the
  test runner the session sets `fsModal`, so LCL code that reads it behaves as
  it does for real.
- PBKDF2's price per round now matches the budget's clock (two verifications
  at Django 5.2's default cost fit the prescribed `MaxSteps`); the record's
  canonical spelling and the salt's time ceiling are now each held by a test
  that can fail.
- `drawgrid_row` / `drawgrid_col` answer 0 for a grid with no scrollable cell.
- The contact manager: a backup target is judged by file identity, not by its
  spelling; upgrades and refreshes are linear; user names, product lines and
  search use Unicode case folding (schema version 3), with the Turkish `İ`
  folded to a plain `i` so an upgraded `İLKER` still signs in as `ilker`;
  another program's SQLite file is never written to -- whose file it is is
  read from its header bytes before SQLite opens it, since SQLite would roll
  a hot journal back into it -- and a file with the program's mark but not
  its tables is refused as damaged; a backup onto a `-journal`, `-wal` or
  `-shm` name is refused; an old read-only database is refused with a reason.
  Its self-test has 176 checks.
- Found by reviewing round 6's own diff before it shipped: `sha256$`, `sha1$`,
  `md5$` and `hmac_sha256$` charged nothing to the budget, so a loop of them
  over a large string ran past every ceiling and reported success -- each is
  now priced per 64-byte block and refused before it hashes. "The last window
  was closed" is judged when `app_run` reads it, after every handler has
  returned, so a handler that closes one window and shows the next (a wizard,
  or the main window shown once a login dialog is answered) no longer ends the
  loop with a window on screen. A packed application whose own file name holds
  an unpaired surrogate says so instead of calling its program corrupt.
  `phosphor debug -- ""` says the name is empty, and `debug --` is documented.

### Changed

- **A program gets its own command line.** Everything after the file is the
  program's: `phosphor app.bas a "b c"` gives it `paramcount()` 2,
  `paramstr$(1)` and `paramstr$(2)`, and `paramstr$(0)` is now **the program's
  path** -- before, both functions read the interpreter's own command line, and
  `phosphor` refused any argument after the file. A word starting with `-` that
  is not one of `phosphor`'s options is refused unless it follows `--`. A packed
  executable now passes its whole command line to its program instead of
  ignoring it, and `phosphor debug` passes on what follows the file. An embedding
  host sets `ProgramPath` and `ProgramArgs`; a host that sets neither gives the
  script no arguments.

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
