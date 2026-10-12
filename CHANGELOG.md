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

### Fixed (GUI, 2026-10-12)

- **A free inside a handler costs what it destroys, not what is alive.**
  `control_free` inside an event handler, and any free of a tree node or list
  item, asked every live handle whether it died with the object -- so freeing N
  controls in a program holding H handles cost N*H: 2000 buttons made and freed
  in one click took 2.1 s beside 100k other handles, against 0.1 s with none.
  The free now walks what dies (the components it owns, at every depth, the
  items under a menu item, the nodes and items of a dying tree or list view, a
  node's subtree) and finds each handle -- or deferred free -- through the
  object index round 9 added: 20-30 ms at 0, 10k and 100k handles alike.
  `tests/gui/35_free_cost.bas` pins what is dropped and the cost, as ratios
  measured in the run.
- **A tree node or list item handle no longer costs more the more of them a
  view holds.** Each one -- and each deferred free of one -- registered a free
  notification with its tree or list view, a list the runtime scans on every
  add and remove, so making k handles in one tree was quadratic: 90 000
  `treenode@` calls on top of 10 000 took 3.4 s, and 2000 node make+free pairs
  in a click 335 ms beside 100 000 nodes. The view now owns one watch that
  every handle into it joins and leaves in constant time: 0.2 s and 8 ms, and
  freeing the form that held the 100 000 nodes went from 1.7 s to 15 ms.
  `tests/gui/36_node_cost.bas` pins the ratios and
  `tests/gui/37_node_watch.bas` the node and item frees inside a handler.

### Fixed (stabilization batch 1, 2026-10-12)

- **A typed array holds its own kind** (ledger rows 2 and 13). An element
  write is now a store by the assignment rule, in the one setter every write
  goes through (the typed setters, `arr_set@`, `a@[i] = v` and `swap`): a
  string into a `dim@` array, or a number into an `sdim@` or `pdim@` one, is a
  type mismatch (`err()` 3) naming the array's kind, and nothing is written.
  It used to be kept as given, so `sarr_get$` could answer an int.
  `tests/suite/106_typed_array_kind.bas`.
- **`swap` is all-or-nothing** (ledger row 3). Both stores are checked before
  either is done, so `swap x, n%` with `x = 1e300` fails with both values
  unchanged instead of destroying `x`; an element's handle and indices are
  evaluated once, so `swap a@[1], a@[a@[1]]` exchanges the elements it read.
  `swap` is now in `docs/language-reference.md`.
  `tests/suite/107_swap_atomic.bas`.
- **`sin` and `cos` are fast again, with the same bits** (ledger row R1).
  Round 11 made them correctly rounded and identical on both OSes at about
  1 us a call; a proven fast path (Cody-Waite reduction below 1.5 * 2^20, a
  table kernel, and a rounding test that hands the rare doubtful call to the
  round-11 code) brings that to 20-30 ns for ordinary arguments, about the
  platform `sin`, and the huge-argument reduction is 10x faster too. No
  answer changed: `tests/probe_trig.lpr` compares every result bit for bit
  with a copy of the round-11 code (0 mismatches over 42 million checks on
  both OSes; its quick mode runs in the suite).

### Fixed (adversarial round 11, 2026-10-12) -- stabilization mode

Round 11 attacked the language core and the data libraries for the first time in
many rounds and found 41 survivors; only the eight HIGH were fixed in the round,
each reviewed adversarially before merge. The MEDIUM and LOW findings are in
`docs/stabilization-ledger.md` with a proposed decision each.

- **The language core.** `resume next` after a fault inside a `return`
  expression ran the code after the `return` (a function answered 99 where no
  path could): it now ends the function with its type's default, wherever the
  `return` sits and under `on error call` too. **Parameters and results obey
  their suffix** by the assignment rule: `twice%(2.5)` is 4 (was 5), a number
  passed to `a$` or returned from a `$` function is a type mismatch -- and
  unsuffixed parameters and plain-named functions hold only numbers now
  (`id("s")` with `function id(x)` is refused at runtime). A refused `on error
  call` handler's message names the fault it was handling. String `s$ - n` and
  `line input #`/`input #`/`input$(n, #)` respect `MaxMemoryBytes`.
- **Numbers.** `sin`/`cos` answered `x` itself on Linux for abs(x) >= 2^63 and
  lost digits below it; `log2`/`log10` were one ulp off on exact powers on
  Windows (`int(log2(8))` was 2). All four are now computed the same way on both
  OSes and correctly rounded; an `int%` given to a JSON number writer is stored
  as an exact integer (ids past 2^53 kept every digit).
- **No door opens a FIFO, a socket or a device** (except the null device): on
  Linux opening a FIFO blocked in the kernel past every ceiling, and round 9 had
  fixed one door of seventeen. One shared check runs before every open; on
  Windows it judges the handle, so a named pipe is refused by any of its names.
- **Contact manager: Export to CSV** wrote over any existing file, the open
  database included (on Linux every record was destroyed). It now refuses any
  SQLite database by its bytes, asks before replacing another file, and writes
  to a temporary file moved into place only when complete.

### Fixed (stabilization, 2026-10-11)

- The tests that failed for reasons of their own, not the engine's: the
  console-input harness checks a held Ctrl chord by its ANSWER only (how a
  console draws a control character differs between Windows 11 and the CI's
  Windows Server console) and prints any character in a FAIL line; the HTTP
  test server's raw mode reads a request's body before answering (closing a
  Windows socket with unread bytes sends a reset that can discard the answer --
  the one-off empty POST in `30_http_path_colon`); `phosphor --diag` waits up
  to 60 s for its second thread and says so if it does not finish, and block W
  prints the whole stderr when it fails; `probe_limits` scales its millisecond
  bounds by how much slower the machine is than the one they were measured on.
- (2026-10-12) The console-input harness starts each Windows case's console
  **hidden**, not minimised: a minimised window can still be brought to the
  foreground, and one key typed into it there made `getkey-then-input` fail
  once in a full battery. It refuses to run a case in a console whose window
  is visible.

### Fixed (adversarial round 10, 2026-10-11)

- **The contact manager judges a file by what it is, not how it is spelled.**
  New engine functions `file_kind$` (`file`, `dir`, `link`, `fifo`, `device`,
  `socket`, `stream`, `none`) and `path_canonical$` (the one full name: links
  followed, 8.3 names expanded, case as on disk) ask the operating system. With
  them the program refuses, at open and at backup, an 8.3 alias of another
  database's journal, a dangling link's 8.3 alias, NTFS streams
  (`other.db-journal:bk`, `x-wal::$DATA`), devices (`CON` hung inside SQLite) and
  Linux FIFOs (the program blocked for ever), and opens, judges and backs up
  under the canonical name -- so its own crashed file reached through a Windows
  link is rolled back, not opened torn. `file:` and `:memory:` are compared
  exactly, as SQLite does; a file shorter than 16 bytes no longer crashes the
  header check. 217 self-test checks.
- **The budget refuses an argument without spending the run, and a spent run
  names who spent it.** `strings_loadfromfile`, `unzip_extract` and
  `zip_extractall` latched the run on an oversized file or archive; they now
  refuse and the run goes on. `file_copy`/`dir_copy` ask a copy's whole price
  once, before reading. After a deliberate latch, a later refusal says which
  call spent the run. On Windows `file_getsize` and the `file_get*time` functions
  read the file, not its directory entry, so they are current while a file is
  written and through hard and symbolic links (round 9 had moved them to the
  directory entry: 0 or stale, on Windows only). A refused `strings_savetofile`
  no longer renames the list's encoding. `check-budget.py` settles a latch only
  with a reporter that reads the latch.
- **GUI: radios.** A radio choice set while a dialog was hidden was undone on
  Windows when it was shown again (the form handed focus to an unchecked radio,
  which checks itself on win32); radio exclusivity is now the library's on every
  OS; "no radio checked" is a per-OS answer -- gtk2 cannot uncheck a group's only
  checked radio, as `gui-choice.md` now says, pointing to `radiogroup@` for
  "none". Waiting `control_parent@` moves land as asked and are no longer refused
  as a cycle; `control_taborder` reads where a control will land.
- **Keyboard and temp directory.** On Unix, Ctrl+Z then `fg` inside a key loop
  works as in vim or less; keys typed ahead of `input` are edited exactly as the
  line discipline edits them live (ICANON, IUTF8, Latin-1 word erase, Tab from
  the prompt's column); a pasted megabyte is linear. On Windows the presses of a
  held Tab or Ctrl chord begin the next INPUT line. A relative TEMP/TMP/TMPDIR
  under a deleted working directory is skipped (it read uninitialised memory),
  and `~` is not expanded.
- `scripts/check-sandbox.py` knows the operating system's own file doors
  (`CreateFileW`, `GetFileAttributes(Ex)W`, `GetFinalPathNameByHandleW`,
  `FileGetAttr`, `FileGetSymLinkTarget`); `os_platform$` is documented with the
  spelling it answers (`Linux`, not `linux`).

### Fixed (adversarial round 9, 2026-10-11)

- **A budget refusal is reported where it can be heard.** An autosaving
  `cfg_set@` (and every autosaving setter or deleter) whose save the budget
  refused reported success while the value never reached the file, and
  `cfg_save` answered 0; `sqlite_row@`, `sqlite_fetchone@` and the last row of
  `sqlite_fetchall@` handed back rows whose text columns had become `""`. All are
  now the call's `peLimit`, and the refused change is put back. The classic
  `chdir`/`mkdir`/`rmdir`/`forcedirectories`/`kill`/`fileexists` and
  `strings_savetofile`/`strings_loadfromfile` raise the `peLimit` for a priced-out
  path instead of answering 0 -- and a refused path is still only a refused
  argument: the run goes on. Paths in the opt-in packages and SQL text are
  priced; the directory doors at their measured price. `file_getsize` asks the
  directory instead of opening the file, so a FIFO with no writer no longer
  blocks past every limit. `strings_values` keeps a sorted list sorted; a NUL
  quote character quotes nothing in `strings_delimitedtext$`.
  `scripts/check-budget.py` gained a refusal gate that holds one contract: a
  non-latching refusal is written into an error or the unit's own flag where it
  is asked, a helper with neither latches, and every latching call is asked
  about before its answer leaves.
- **GUI: a move lands at once unless a walk may stand on it.** Round 8 deferred
  every `control_parent@` inside any handler, so the program's view and the
  LCL's disagreed until the handler returned: the only window, moved into a host
  freed in the same handler, was hidden and `app_run` never ended; a form re-shown
  in the handler that freed its host had no window; a deferred embed ended a tray
  program's `app_run`. A move now waits only when the control or its parent is a
  running handler's sender or an ancestor of one (every LCL walk that runs BASIC
  reaches it through such an event -- the radio walks and `PaintControls`), and
  while one waits every rule reads the parent the program asked for. Waiting
  moves are bounded per control; freeing a windowed control no longer walks
  every live handle (15 s for 2000 frees at 100k handles is now 15 ms).
- **Keyboard and line input.** Unix `getkey$`/`inkey$` read one key per key: an
  escape sequence ends at its ECMA-48 final byte, so keys queued while the
  program was busy no longer merge; a key split across reads is waited for
  (100 ms for an escape sequence, 500 ms for UTF-8) while `inkey$` and
  `keypressed()` never wait. Keys typed ahead of `input` are edited and echoed on
  Linux by the terminal's own rules, and on Windows a held key's unanswered
  repeats are shown and erasable. Ctrl+C during a key function restores the
  console or terminal mode. `temppath$`/`tempfilename$` are always a full path,
  and an unusable TEMP/TMP is skipped exactly as if unset.
- **Contact manager.** Before SQLite 3.39.0, asking a file's name reads it, so
  the guard itself rolled back another program's hot journal: an older library
  is not asked about an existing file, and the whole self-test passes under a
  real 3.37.2. `file:` URIs, `:memory:`, empty and journal names, and names that
  are not a file (a Windows link that leads nowhere) are refused at open and at
  backup; a journal whose writer may be alive is not called a crash. A new block
  AI of `scripts/test.{sh,ps1}` runs the self-test without a sandbox through real
  symbolic links -- the sandboxed self-test could not fail with the Linux link
  judging removed. 213 self-test checks.
- The console-input harness runs each case in a `conhost.exe` named by path:
  a bare new console became a Windows Terminal tab that stayed open after the
  case, and two days of cases left 356 of them on the owner's desktop.

### Fixed (adversarial round 8, 2026-10-11)

- **Budget: a charge answers only for the work beside it, a refusal changes
  nothing, and every price is measured.** `check-budget.py` now reads where a
  charge sits, so it sees a case-fold before a metered loop (`path_matchespattern`
  ran 45 s under a 2 s ceiling), a concatenation (`path_combine$`) and a container
  shift (`json_removeat@`, 22 s step-only); about forty more unpriced sites were
  found and priced (RAG retrieval, SQLite copies and escaping, zip, http basic
  auth, file appends). A refused call leaves its container as it was:
  `strings_values` no longer appends a duplicate key, a sort is not left half
  done, a merge is priced before its first member is copied, a refused autosave
  or reload is rolled back. Prices are measured by `probe_limits --prices` and
  held between 0.5x and 4x of the work: searches, splits, `line$`/`s$[n]`,
  `json_parse@` (no longer counting commas inside strings: a 1 MB document is not
  refused on its 7th parse), `strings_delimitedtext$` and `reverse$` re-priced,
  deflate charged its wall time. **`strings_delimitedtext` no longer drops every
  field after an unquoted field holding a space** (`"John Smith,42,NY"` gave one
  field); it follows `TStrings.DelimitedText` and loses nothing.
- **GUI: every door that makes or unmakes a window asks `app_run`, and a move
  inside a handler is deferred.** An embedded form whose host was freed stayed
  visible and top-level with no window, so `app_run` never returned; it is now
  hidden with its host. Moving the only window into another form ends the loop as
  closing it does. A window shown with `control_visible@` or `control_set@
  "Visible"` had no closer: `form@` now installs it for every form. And
  `control_parent@` inside a radio's `onchange` while the LCL walked its siblings
  killed the program ("List index out of bounds"): a move asked for inside a
  handler lands when the handler returns.
- **One keyboard model, and INPUT reads a line, on both systems.** After any
  `getkey$`/`inkey$`/`keypressed()`, `input` on Windows answered part of a line,
  and on Linux it swallowed the keys typed right after the Enter; a line is now
  read in line mode, no further than its Enter. Modifier and lock keys alone are
  not keys (Shift+A was `chr$(0)+chr$(16)` then `A`); Alt+numpad entry answers its
  character; a repeat count of N is N keys; an emoji whose halves arrive
  separately is one key; `keypressed()` no longer answers 0 for ever behind 32
  mouse or focus events; Linux `getkey$` answers U+FFFD for bytes that are not
  UTF-8. The console line read asks for 32768 units, so a legacy conhost keeps as
  much of a line as it can. `temppath$()` on Windows continues past an unusable
  TEMP/TMP to USERPROFILE and the Windows Temp directory and never answers `""`.
- **Contact manager judges the journal SQLite will find, the way SQLite decides
  it.** It asks SQLite for the file's name (`PRAGMA database_list`, before any
  query): SQLite follows a symbolic link on Linux and drops a trailing dot on
  Windows, so another program's hot journal was rolled back through a link or
  through `x.db.`. A torn page 1 with a journal beside it is judged on the copy
  (the program's own file opens again); schema names are compared ignoring case,
  as SQLite compares them; a spent PERSIST journal is not a crash; an earlier
  version's file that lost a table is named for it. 205 self-test checks.
- CI: the Windows job's "nothing was skipped" step is case-sensitive (a PASS line
  saying a TEMP "is skipped" read as a SKIP), and the console-input harness
  measures the console's own line cap instead of assuming Windows 11's.

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
