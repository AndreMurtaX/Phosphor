# Attack plan — everything open, in the order it should be taken

**Status: the plan of record.** Written 2026-09-15 from a verification pass that read
every open item against the source rather than trusting the ledger, because the ledger
had already been measured drifting: two findings were fixed months earlier and still
listed, and one was filed twice at two severities.

Read [docs/dev-agent-playbook.md](dev-agent-playbook.md) for the findings themselves and
the rules each defect produced, and [docs/proof-axes.md](proof-axes.md) before sweeping
anything. This file answers a different question: **given all of it is open, what order
does the work go in, and how does each stage know it is finished.**

Two things about it are load-bearing.

**Section 5 is the inventory of defects that were NOT on the ledger** — sixteen of them,
found while verifying the thirty-three that were. They are recorded here and nowhere
else; the playbook's numbered list points at this section rather than copying them,
because this project has already been bitten by a second copy of a fact drifting away
from the first.

**Section 4 says what this plan could get wrong**, including which verifications were
weakest and what would make the order change. A plan without that section reads as more
certain than the measurements behind it.

Item ids: `dNN` are the playbook's numbered findings, `mN` the missing features, `rN` the
debugger residuals, `nNN` the new defects in section 5.

---


Scope: 34 ledger items verified against the source today. **33 are live**, 1 is closed, 1 is a duplicate. The verification also surfaced **16 defects and classes that are not on the ledger** — §5, and it is the most valuable part of this document.

Sequencing principle, stated once so the rest follows from it: **nearly every engine fix in this set has at least one plausible wrong fix that is byte-exact green on both OSes today.** That was measured item by item, not assumed — the `{$IFDEF UNIX}` move guard, the partial JSON rewrite that manufactures NULs, the `is TComponent` node guard that access-violates on exactly the case it guards, `GuiChargeAdd`, a charge placed after the `Assign`, a cumulative-`APos` meter, four *new* 2 GiB allocations created by "consistency", a `check-budget.py` `ALLOWED` entry that closes a hole by declaring it closed. A green suite cannot distinguish any of those from the right fix. So: repair what measures, then fix what is measured — with one deliberate exception for the three items that destroy user data.

---

## 1. First move

**d49 — argument handling in the six bash runners.** `scripts/test-examples.sh:28`, `test-classic.sh:65`, plus `test.sh`, `test-packages.sh` and `test-gui.sh` (which never read `$1` at all) accept the project's own canonical `-ProveFailure` and print OK at exit 0, so *"`-ProveFailure` was seen catching a corrupted expectation"* — one of the five conditions for done — has never been true on Linux for five of six harnesses; and it creates `scripts/lib/runner.{sh,ps1}` (**confirmed absent**: `scripts/lib` does not exist), the shared file d50 and d64 both need.

---

## 2. Waves

### Wave 1 — Instruments that can fail
`d49` · `d50` · `d64` · `d56` · `d57`

**Why here.** Four of the five done-conditions are currently unenforced somewhere. `-ProveFailure` is a silent full run on Linux (d49). Eight `fpc` invocation sites in `scripts/test-suite.{ps1,sh}` and `scripts/test-gui.{ps1,sh}` discard the `-vewn` log and judge by `Test-Path` — and a **live** `Comment level 2 found` warning is sitting behind that blindfold at `scripts/probe_budget.lpr:588` right now (d50). The boundary check strips `(* *)` on Windows and not on Linux, in a tree whose CLAUDE.md tells authors to reach for `(* *)` (d64). The GUI watchdog calls `Application.Terminate` at `host/gui/phosphorguitest.lpr:177`, which the LCL gives no way to clear, so every later `app_run()` dispatches nothing and one hang is reported as a screenful of unrelated failures (d56). `assert_eq`'s epsilon is *relative* with the 1.0 only a floor on the scale, so a mutation of nine thousand at 9.007e15 passes — because `assert_int` is `:%%` with no message overload (d57).

**Concurrency.** Track A: d49 → d50 → d64, strictly serial, one new `scripts/lib/runner.{sh,ps1}` (writing that helper three times is the waste severity-ordering guarantees). Track B: d56, `host/gui/phosphorguitest.lpr` alone. Track C: d57, `tests/PhosphorTestLib.pas` + `tests/suite/57_buffer.bas` + `tests/gui/18_faults.bas` + `tests/gui/19_argord_and_size.bas`. No file collisions between tracks.

**Gate to leave.** All twelve runners canonicalise `--prove|--prove-failure|-ProveFailure` to one flag and `exit 2` on anything else, proven by a new `check_runners` in `scripts/check-crossrefs.py` that **named exactly those five bash scripts on the unpatched tree** and names none now (if it names none before, the pattern measures nothing). All eight fpc sites route through `Assert-CleanBuild`/`strict_build`; `probe_budget.lpr:588` was **watched turning the suite red** with the real warning before its fix landed in the same commit, and a deliberate nested brace planted in a *different* probe, rebuilt with `-B`, was caught and removed. All four boundary-check copies strip `//`, `{ }` and `(* *)`: a `uses SysUtils (* never windows *), Classes;` fixture is silent on both OSes, and a real `uses Windows;` is red on **both** — if Linux stays silent, the new sed ate the uses clause. The watchdog writes its summary, flushes StdErr and `Halt(1)`, **measured on win32 and gtk2** (see §5 — this is the estimate I trust least); `17_event_loop` and `21_loop_lifecycle` still finish inside 30 s byte-exact with the dog silent. `assert_int:%%$` exists, the five ≥1e12 sites are converted, and both mutations (one digit in `57_buffer.bas:415`, nine thousand in `gui/18_faults.bas:73`) were watched **passing** on the old tree and **failing** on the new.

---

### Wave 2 — Stop the three that destroy bytes
`d14` · `d07` · `d12`

**Why here and not later.** These are the only items in the set where waiting has a victim. `host/packages/PhosphorGzipLib.pas:337-346` evaluates `RawInflate` as an *argument* to `SaveFileStr`, so a budget refusal truncates the destination to zero with `fmCreate` and writes the partial inflate over it, and only then reads `GzipSpent` (d14). `engine/libs/PhosphorIoLib.pas:622` and `:599` are, after the sandbox gate, one bare `RenameFile` — POSIX `rename` on Linux, which silently replaces an existing file and answers 1 against `docs/libraries/io.md:64`, which promises 0 (d07). `engine/libs/PhosphorConfigLib.pas` hands a hand-edited `.ini` to stock `TMemIniFile`, whose only comment marker is `;` (`inifiles.pp:272`), so a `#` line inside a section is re-emitted as `=# inner` and one before the first section is dropped — on a file `docs/libraries/config.md:12` invited the user to hand-edit (d12).

d14 goes first **inside** the wave for two non-severity reasons: it is three lines, and its probe is the first thing in this tree that can observe a budget refusal in a host package at all — `host/packages/phosphorpkgtest.lpr` installs no ceilings and the engine defaults `MaxSteps`/`TimeoutMs` to 0, so every `tests/packages/*.bas` runs with an **inert budget** (see §6, n17). Wave 5 cannot be proven without that harness.

**Concurrency.** Three disjoint units, three disjoint test homes — `PhosphorGzipLib` + `scripts/probe_budget.lpr`; `PhosphorIoLib` + `tests/suite/26_ioutils.bas`; `PhosphorConfigLib` + `tests/suite/22_config.bas`. Fully parallel.

**What I gave up.** d62 shares `PhosphorIoLib.pas`, `26_ioutils.bas` and `docs/libraries/io.md` with d07 and is deferred to Wave 6 — one extra ceremony, paid to stop a file-overwriting defect a wave earlier. **Constraint that makes this safe: d07's new assertions must not pin `ioerror()` values**, so d62 can change the refusal code later without churning them.

**Gate to leave.** `gzip_decompressfile` refuses *before* `SaveFileStr`: the sentinel destination is byte-identical after a refused inflate (watched failing first, with 65536 zeros there), and the stale-flag twin is gone — a missing source after a refused inflate no longer reports `err()=7`. `file_move`/`dir_move` refuse an existing destination in **plain code on both platforms** (never `{$IFDEF UNIX}` — Windows' compliance today lives in FPC's choice of `MoveFileW`-without-flags, not in this tree), `file_move(a$,a$)` still answers 1, the Windows case-only rename survives, and **the new assertions were watched failing on the Linux VM against the unpatched engine** — Windows cannot witness this failure at all, so a Windows-only see-it-fail does not count. A hand-written `.ini` built with `file_writealltext` (not `cfg_set@`) keeps `# top` and `# inner` across a save, `cfg_keycount` reads 1 not 2, `cfg_keys$` has no blank entry, **and a value containing `chr$(10)` survives save + reload** — that last one is what stops the fix from being `#`-shaped; the empty-`FileName` sandbox refusal in `Save` survives the move away from `UpdateFile`, and a Phosphor-authored `.ini` is shown byte-identical across the change (the golden records a count, not the file).

---

### Wave 3 — Every gate enumerates its own domain; every assertion can fail
`d48` · `d54` · `d53` · `d44` · **n12** ‖ `d55` · `d51` · `m4` · **n11** ‖ **n4** · **n5**

**Why here.** Five gates enumerate by literal path list or narrow glob while their docstrings, the runner comment blocks and CLAUDE.md's gate table claim the whole tree. `scripts/check-seams.py:242` globs `host/**/*.lpr`, so `lazarus/demo/phosphordemorunner.pas` — the file `lazarus/README.md` calls *the integration you came here to copy*, with four of five seams nil — is outside a gate CLAUDE.md:199 says covers every host, **while the gate counts a gitignored `host/console/backup/` as a seventh host** (d48, n8). `scripts/check-manifests.py:68` iterates a literal dict, so `tests/skeleton` and `tests/gui/hostmode` are in no category at all while `coverage.py` credits their names — two gates covering for each other (d54). 44 negatives, **0 expectation files** (confirmed), judged on an exit code with the diagnostic printed and never compared (d53). `scripts/coverage.py:141` prints *every registered function is exercised by a test* at 715/715 while 426 GUI names are outside its world, 79 of them with no call site (d44).

**d48 + d54 land as one change**, because the rule is the same sentence in two files: derive the candidate set from `git ls-files`, classify each member, and **fail on unclassified**. Widening a glob is the instance fix this project has a name for — and for d48 it is worse than nothing: widening to `**/*.lpr` sweeps in eight probes that null seams on purpose and forces ~40 exemption rows nobody reads, inside which a real nil seam can then hide.

**Concurrency.** Track A (serial): d48+d54 → d53 (also edits `check-manifests.py`; doing it first writes a rule against a dict d54 then deletes) → d44 + n12. Track B: `tests/suite/49_on_error.bas` (d55), `tests/gui/hostmode/gui.bas` + `scripts/test-gui.*` (d51), `docs/roadmap.md` + `tests/suite/13_global_limit.bas` (m4), `tests/probe_debug.lpr` (n11). Track C: `host/console/phosphor.lpr` only — n4 and n5, the two host-side protocol repairs that unblock the PhosphorIDE lane (below). No collisions across tracks.

**Why this wave gates Wave 4.** d44's output *is* Wave 4's worklist: an entire untested modal/dialog/tray surface, 12 event binders never bound, 13 property pairs where neither reader nor writer is called — exactly the class d10 and d42 are instances of. Fixing a GUI defect while the gate prints 100 % means the next one is found the way these were, by a human reading 426 functions.

**Gate to leave.** `check-seams.py`'s first run on the derived domain was seen exiting 1 naming `phosphordemorunner.pas:OnInput/:OnBreakpoint/:OnDebug/:HostServices`, with the host count **falling to 6, not rising to 8**; all three directions assert (unclassified scratch `.pas` fails; a deleted `OnInput` assignment fails naming that seam; the finished tree exits 0). `check-manifests.py` exits 1 on a planted `tests/skeleton/zzz_unlisted.bas` (`assert_int(1,2)` — no message argument) and again on the same file in `tests/gui/hostmode`, exits 1 on a category entry holding no `.bas`, and the clean-tree count rises **108 → 112**. 44 hand-written `.reason` files derived from each negative's own `rem` header and never copied off a run; two mutated negatives from different families were watched passing today and failing after. `coverage.py` iterates a **separate** `test_libs` list so `libs`/`all_names`/`all_libs` and the README's 715-and-426 claims are untouched; TOTAL reads 1141 with all 715 engine names still covered and **79** (d52's stricter count — calls, comments and string literals stripped) listed as a dated, can-only-shrink backlog; a name credited only by a `rem` stays listed. `check-crossrefs.py` gains line-number verification for `path:line` citations (n12) and reports the seven stale ones. d55's repaired assertion was watched failing via a 1→2 mutation the pristine tree passed; d51's hostmode case **fails when `--sandbox` is removed**; a 513-ceiling planted in `TPhosphorCompiler.VarIndex` and rebuilt with `-B` is rejected by the new `13_global_limit` while an ordinary small program still compiles; `probe_debug`'s new `Entry = 0` fixture moves when `(hdr >= 0)` is loosened to `(hdr >= -2)`. `docs/dev-agent-playbook.md:571` ("All six gate blind spots are closed") is re-scoped, not re-asserted.

---

### Wave 4 — The GUI host: lifetimes, then the ledger
`d10` · `d42`

**Why here.** `host/gui/libs/PhosphorControlLib.pas:265-304` — `f_free` is the **one** `control_*` function that resolves with raw `HandleObj` instead of `GuiResolve`, and its only guard is ownership (`:299`), so a `TTreeNode` is freed *with its whole subtree* and answered 1 / `gui_error` 0 against `docs/libraries/gui-tree-list.md:21-24`, which promises a refusal. Because a node is not a `TComponent` it cannot `FreeNotification`, so every descendant handle keeps a non-nil dangling pointer the next `GuiResolveObj` dereferences for a VMT read — and `control_free(tv@)` then `control_free(node@)` is a **double free**, heap corruption rather than a fault, which on Windows passes quietly and surfaces somewhere the embedder blames their own code. Four doors, not one. d42 rides with it: `host/gui/libs/PhosphorCanvasLib.pas:188-194` is the only surface-producing name in `host/gui` with no ledger call at all.

Placed above the budget wave because the damage is to the *host's heap* and is attributed to the embedder, where Wave 5's damage is loud (a machine slows, a disk fills). Placed below Wave 1 because d56 must be in before a GUI hang can report legibly, and below Wave 3 because the backlog must be printed before "this subsystem is covered" means anything.

**Concurrency.** Same unit family, same two test files, same golden bumps, one gtk2 round — **one track, not two**.

**Gate to leave.** `control_free` on a `node@`/`item@` answers 0, records `gui_error` 1, leaves the handle registered, and **`treeview_nodecount` is unchanged** — that third assertion is load-bearing; if only the return value and `gui_error` fail, the test pins the answer and not the defect. The guard tests the memoized `Watched` field, never `h.Control is TComponent` (which dereferences the VMT of the object it is guarding) and never `TControl` (which breaks `bitmap@`, five dialogs, `timer@`, `imagelist@`, `menuitem@` — loudly, which is the good case). `image_setbitmap@` calls `GuiChargeSet` with `GuiSurfaceBytes` of the **source** bitmap **before** the `Assign`: at the ledger edge the call raises **and** `image_picwidth` is still 0 (the only assertion that kills a charge placed after the copy); 200 setbitmaps into one image at the edge are not refused (kills `GuiChargeAdd`); an ordinary setbitmap on a clear ledger succeeds and reads back (kills over-tight pricing); `control_free` credits it back. The `Picture.Bitmap`-getter `ForceType` allocation (§6, n19) is decided in writing. `scripts/check-budget.py`'s deliberate exclusion of `host/gui/libs` is either lifted for the ledger verbs or re-stated as an exemption with a reason. Green on **Linux/gtk2** as well as win32 — free order and heap reuse differ, and this is a lifetime wave.

---

### Wave 5 — Work that is actually bounded
`d18` + **n1** · `d45` · `d46` · `d47`

**Why here.** `engine/libs/PhosphorStrLib.pas:1056` and `:1065` compute `w - CpLen(s)` in 32-bit from a *saturating* `ArgI32`, so `center$("x", -1e18)` wraps `pad` to 2147483647 and builds a 2 GiB string (≈8 GiB in the three-arg form) — four lines above a comment (`:1178-1188`) that already states the clamp-before-subtracting rule for `f_mid`'s two siblings and did not sweep the pad family. `engine/libs/PhosphorBufferLib.pas:431-437` has no `Budget*` call at all while its two-arg twin at `:426` does, under **one** registered BASIC name, so a script escapes the ceiling by typing a third argument of `1`. `host/packages/PhosphorZipLib.pas:457` prices an archive from the central directory's *declared* size while `zipper.pp:1093`'s inflate loop reads until the DEFLATE stream ends and never consults it — and two of three extractors (`:989`, `:1054`) do not reach even that guard.

**Concurrency.** Track A (serial, one commit stream): d18 + n1 + d45 — they share `engine/libs/PhosphorBufferLib.pas` and both end in `scripts/check-budget.py` (a clamp-order rule and a nested-hand-rolled-search rule); splitting them rebuilds the same unit twice and edits the same gate twice. Track B: d46 + d47 as **one change** — install the `OnProgressEx` meter where the `TUnZipper` is **constructed** (`TZipReader.Create`, and `f_unzip_extract`'s local `uz`), not at each door, or the next extractor added is the fourth instance. Track B inherits d14's refuse-before-you-write ordering.

**Direction of travel, stated because reversing it is silent:** center$ → siblings, never siblings → center$. Rewriting `ltab$`/`rtab$`/`lfill$`/`rfill$` to match center$'s subtract-first shape would create four *new* 2 GiB doors with every suite, all gates and both OSes green.

**Gate to leave.** `scripts/probe_budget.lpr` links `PhosphorGzipLib` and `PhosphorZipLib`. `center$` answers the string unchanged at **both** arities for a saturating negative width, watched failing in milliseconds having allocated nothing — the 2 GiB defect is never executed. `buffer_fillrange`/`buffer_copy`/`buffer_slice$` refuse a saturating count at **every** position, not just 1 (n1). `buffer_indexof` is refused at both arities through **one** shared body, priced over the whole haystack (never by `Copy()`ing a tail inside the guard, which allocates inside the check), asked exactly once with `BudgetAllows` and never `BudgetCharge`; its probe is sized so the *ungated* run still terminates (~200 KB × ~2 KB) — a bomb-sized case would hang with no console output, the same tell as the REPL and `app_run` traps. One honest ~2 MB archive is refused with `peLimit` at **all three** zip doors — today `unzip_extract` refuses and the other two extract it in full and answer 1 with `zip_error()` 0, and that asymmetry is the see-it-fail, no bomb and no byte-patching needed; the liar is then caught by the meter with a central-directory size field patched to 1 (names and CRC untouched). Both directions: a small honest archive still extracts through all three under the same ceiling, and a multi-entry archive is not over-charged (charge the **delta** of the cumulative position, not the position). The `Spent` flag is read **before** the `except` path answers, or a mid-entry `Terminate` surfaces as `EZipError`/`ZipErr=1` with no `peLimit`, indistinguishable from a corrupt archive. `OnCreateStream` is not used anywhere (it sets `IsCustomStream` and drops `FOutputPath`). `check-budget.py` gained both rules, each watched flagging its real site and silent after, with the compare-first and clamp-first cells left quiet; **nothing was added to `ALLOWED`** to close a hole.

---

### Wave 6 — Contracts the engine states and does not keep
`d08` · `d62` · `d65` · **n6** · `d13` · `m3`

**Why here.** Nothing here corrupts memory; everything answers a script something false while a document promises otherwise — which is exactly why it waits until the corpus can tell the difference. `engine/libs/PhosphorJsonLib.pas:1318-1322` abandons the *entire* re-spell when one literal fails, and `fpjson` reads only the first complete top-level value (`joStrict` unset, `:1496`), so a lone quote in a tail nobody parses restores the fpjson defects the unit exists to fix — measured: 4 bytes where 6 are owed, 0 where 1 is. `engine/libs/PhosphorIoLib.pas` — the unit that *owns* `ioerror()` — records a refusal in 6 of ~24 names, reports a refusal as *file not found* at `:156`, and **clears the slot on no path at all**, so `ioerror()` after a successful write reports a previous call's failure (measured: good write → `ioerror=2`). `engine/PhosphorCompiler.pas:2564`/`:2576` is the last parser in the compiler that does not recognise `:` as the end of a statement, against eight siblings that name `tkColon`. `engine/PhosphorHandles.pas:281` frees every live object in the process and restarts ids at 1 generation 0, so two engines alias each other's handles past the class check while `docs/embedding.md:49/65/74` promise three times that handles are the engine's.

**Concurrency.** Four disjoint tracks: (A) `PhosphorJsonLib` — d08. (B) `PhosphorIoLib` + `PhosphorSysLib` + `PhosphorStrListLib` — d62 (this is where d07's unit re-opens). (C) `PhosphorCompiler` print arm — d65. (D) `PhosphorHandles` + `PhosphorVM` — n6, then d13 + m3 as one file, one doc pass, one probe.

**d13 and m3 are one lane but not one dependency.** m3 does **not** need a per-engine table: `GLive` already *is* the live count for a single-engine process because all six entry points reset the table before they run, and what m3 needs — a refusal channel out of `RegisterHandle`, whose only failure value is 0 and whose 24 callers ignore it — is not made easier by moving ownership.

**Gate to leave.** A trailing unmatched quote, a trailing apostrophe and an unterminated single-quoted tail no longer disarm the re-spell (U+0800 twice reads six bytes, `\u0000` reads one), **and the `01 01` canary still comes back as four bytes, never as a manufactured NUL** — that canary must be in the same commit or the partial-rewrite mistake ships green; acceptance did not move (a genuinely broken document still raises with fpjson's own wording and the **original** text's positions). Every attempting io entry point sets the slot on failure **and clears it on success**, with a refusal code whose text is true of a refusal, set at the **entry points** and never in the shared helpers (which `CopyTree` calls in a loop — last-writer-wins would report a straddling tree clean); `strings_savetofile` no longer answers `l.Count` for a refused write; predicates do not clear the slot; a `check-sandbox.py` sibling rule refuses a new `SandboxAllows`-false branch that forgets it; the fix was removed from **one** entry point and rebuilt with `-B` to confirm that pair alone goes red. All three print-before-colon spellings compile **and `println :` still emits exactly one newline, asserted on BYTES in `probe_limits`** — compile-acceptance rows cannot see the wrong fix. n6: a faulting watch evaluated through `CallFunction` from a stop no longer leaves `err()`/`errmsg$()`/`erl()` answering the debugger's fault to the resumed script, watched failing first on the shipped binary. Handles are documented as process-wide beside the root and the budget, `embedding.md:49/65/74` reconciled so the tree does not carry both claims, and a two-engine probe asserts the **aliasing** (engine A wrote "A" and reads "A"; today it reads "B") in both directions. `MaxHandles` is the fifth ceiling, refusing as a **level** — 100 000 create-and-free under a ceiling of 100 must succeed — reaching the script as `peLimit` at an instruction boundary, inert at 0; the latching and always-on variants were both **built deliberately and watched failing** the second and third assertions before the real one went in.

---

### Wave 7 — Second implementations, and the decisions
`r1` · `r3` · `m1` · `m2` · `m5` · `m6` · `m7` · **n14**

**Why last.** Every item here is either a decision whose cost changes with a measurement, or a contract with software this tree cannot run in its own suites. `r3`'s real cause is `engine/PhosphorLexer.pas:452` — every identifier is lowercased at *tokenisation*, so the spelling is **discarded, not shadowed**, and it affects every variable a debugger displays, not only function names; the fix needs a raw-text field on `TToken` before anything else is possible. `m1` is ~750 lines and its own class sweep produced n6, already fixed in Wave 6 as its see-it-fail. `m5` is blocked on hostname verification that **does not exist in FPC 3.2.2 at all** (`sslsockets.pp:156` `DoVerifyCert` returns True; `X509_check_host` is unbound). `m2`'s recorded blocker has dissolved — all four *"nothing speaks it yet"* comments are false — and what remains is the transport.

**Concurrency — and this is the one free lunch in the whole plan.** `m2`'s **editor half lives in `C:\Dev\PhosphorIDE`**: a different repository, a different build, none of this project's ceremony. It is the single item in the set that a second person can work concurrently with every earlier wave, and it needs only Wave 3's n4/n5 to have landed before its contract test can be honest. Start it whenever there is a spare hand. Within Wave 7 itself: Track A = the debugger lane (r3 → m1, `host/console/phosphor.lpr` + `tests/debug_protocol_test.py`); Track B = the HTTP lane (m5, m6, m7 — one unit, one roadmap file); Track C = r1's chosen option and n14, both compiler-adjacent and mutually exclusive with nothing.

**Gate to leave.** A mixed-case function reports its source spelling through both the engine probe and the DAP `stackTrace` frame name, verified non-trivial by reverting **only** the lexer change and watching *both* new assertions fail; `CallFunction('GREET$')` and `('greet$')` both still resolve; **a `.pbc` written either side of the change is byte-identical** (the function name is the one name actually serialized, at `engine/PhosphorBytecode.pas:302`, behind an exact-match `PBC_VERSION` that would not notice a drift). ~~If `evaluate` ships: call-free, with the whitelist written over the **emitted opcodes** and not the parse tree (`a@[1]` and `[1,2,3]` lower to `opCall` and must be refused), `LiveHandleCount` unchanged either side, `FErrHandler := -1` for the window, and `probe_sweep` gains a fourth leg evaluating at every stop with byte-identical stdout — with the corpus proven to contain an `on error` shape, or that leg is measuring the off state.~~ **SHIPPED 2026-09-17** (PhosphorIDE roadmap item 25). Four of the five held exactly as written and one was traded deliberately; the accounting, because a gate nobody reconciles is a gate:

- **the whitelist over the emitted opcodes, not the parse tree** — as written, and the warning was worth its place: 39 hostile `expr` strings were measured against it, and the ones that matter (`total) : total = 99 : println (1`, a newline, a comment after the payload) all COMPILE. The compiler's own refusals land on the trailing fragment, not on the payload, so balancing the tail defeats them and only the instruction walk is left standing.
- **`a@[1]` and `[1,2,3]` must be refused** — **traded.** `[1,2,3]` is refused (a JSON literal is not an expression the gate admits). `a@[i]`, `s$[n]` and `s$[[n]]` are ALLOWED, through exactly the three names the compiler's own bracket lowering emits (`PhosphorCompiler.pas:1035`, `:1046`, `:1056`), and only where the program defines no function of that name and arity. The reason is that the alternative is a debugger which renders an array as `@1` in its variables pane and then declines to look inside it — the only door out of that pane. `t_arr_get` is fifteen lines of read (`PhosphorArrayLib.pas:245-260`); the shadow guard was removed on purpose and watched turning four protocol assertions red. `capabilities.evaluateCalls: false` still says what it says, because no call the USER WRITES is performed.
- **`LiveHandleCount` unchanged either side** — better than asked: it is not a test, it is a runtime check inside `DoEvaluate` on every request, and a request that moved it gets no answer at all.
- **`FErrHandler := -1` for the window** — the plan was right and the cause was one line further back than it says. `TPhosphorVM.Create` never initialised the field, so EVERY freshly created VM carried a handler at pc 0; `Run` resets it and `RunFrom` deliberately does not. Fixed in the constructor, which is where it belonged, and pinned by `probe_bytecode.CheckFreshVMHasNoHandler` — with `end` and without, because a check on the second half alone passes with the defect in place.
- **`probe_sweep` gains a fourth leg** — **NOT DONE, and not deferred quietly.** `probe_sweep` is an ENGINE probe and this evaluator is host-side by design: the leg could only exist by putting a second copy of the gate in the probe, which is the thing the design refuses. The concern behind it — that the corpus contain an `on error` shape — is answered at the right level instead, in `tests/debug_protocol_test.py`'s seventh session: the fixture installs `on error goto`, a faulting evaluation is asserted reported rather than handled, the handler is asserted never to have run, and the program's own `err()`/`errmsg$()` are asserted empty after the resume. That is n6's exact shape, driven through the wire rather than around it. A corpus-scale version would be a Python sweep opening one session per program, and it is worth having; it is not written. m2 ships its framing tests headless **before** the transport exists (split frame, two frames in one read, trailing partial, CRLF, 2 MB unterminated line) and asserts a comment-line breakpoint comes back **absent** from the echo — a failure that is the proof, not a thing to weaken. m5's fixture is reissued for a **name** with a SAN and the pinned-https assertion watched failing before the SNI handler exists, with `nm -D libssl.so.3 | grep peer_certificate` **measured on the VM** and not reasoned about. m6 and m7 are re-recorded with the blockers that are actually true.

---

## 3. Design forks — owner's to overrule, mine to call

| # | Fork | Options | My call |
|---|---|---|---|
| 1 | **r1** — a bare zero-arity name used as a value (`p$ = date$` is silently the empty string; 109 names) | (a) leave; (b) compile warning — needs a new `OnCompileWarning` seam every host must then answer for; (c) resolve to the function; (d) host-side lint (`phosphor --lint` or a `scripts/check-*.py`) | **(d), with the read-never-written refinement.** Measured: the naive rule fires on two legitimate corpus files (`home$` in `10_sqlite_sandbox.bas`, `date$` in `31_regex_dict_num.bas`); read-never-written takes the false-positive surface to **zero**. And the decisive cost nobody had named — the registry is populated by the **host**, so (b) and (c) make compile-time behaviour host-dependent: `home$` is registered under `phosphorpkgtest` and an ordinary identifier under `phosphortest`. |
| 2 | **d13** — the process-wide handle table | (A) own it per-engine (large: ambient install that must outlive the run, three unwatched lifetimes at risk); (B) stop promising it is owned | **(B) now, (A) the first time a host wants two engines.** No host in the tree embeds two. (B) is one paragraph and makes `PhosphorHandles` say what `PhosphorBudget` and `PhosphorSandbox` already say about themselves. |
| 3 | **m3** — the handle ceiling's refusal channel | (i) fatal at the VM instruction boundary; (ii) catchable, across 24 `RegisterHandle` call sites | **(i).** One place to change, consistent with the four ceilings it joins, overshoots by at most the handles one `opCall` mints. The silent-0 variant hands the script a fake handle **and** a successful call, and every suite passes. |
| 4 | **d62** — what code a refusal gets | new code 5 (`access denied`, already in `IoErrorText`) vs overloading 3 | **5.** The comment at `:535` says 3 means *refused* and the table at `:788` prints *path not found* — they contradict today, and any fix that skips this ships a refusal reported as a missing file. |
| 5 | **d46** — a metered refusal leaves a partial file at the zip destination | unlink the partial entry, or document it | **Unlink for zip** (d14 just established refuse-before-you-write); gzip already documents truncation at `docs/libraries/gzip.md:56`. Decide before writing the meter, not after a reviewer finds it. |
| 6 | **d12** — a value containing `chr$(10)` (Phosphor's own API can produce an unparseable line) | reject in `cfg_set@` with a returned error, or escape it in the new line layer | **Reject.** Errors are values in this engine; escaping invents a convention that is ambiguous with a real `;#` comment. |
| 7 | **m1** — capability honesty | flip `evaluate: true` with a second `evaluateCalls: false` key; or keep it false and ship the Pascal door for embedders only | **Flip, with the second key.** A call-free evaluator's guarantee *always* holds for what it accepts and refuses the rest in writing — that is bounded, not half-safe. Keeping it false answers a protocol question by leaving a working engine feature unreachable. **DONE 2026-09-17**: both keys ship, `evaluate: true` and `evaluateCalls: false`, and the handshake now carries six capabilities rather than five. The second key earns its place the way the decision said it would — it is the one thing an editor needs before it offers a watch box, and finding it out one refusal at a time is how a capability flag stops being worth having. |
| 8 | **m5** — hostname verification | build it now (it does not exist in FPC 3.2.2 at all), or leave https pinning disabled | **Build it — but measure `libssl.so.3`'s peer-certificate symbol on the VM first.** Without it the pinned-https gate is meaningless, and the one-line "delete the https clause" fix ships the IP as SNI to every virtual-hosted host and *succeeds* against the wrong peer. |
| 9 | **m7** — one roadmap line, two features | keep as one, or split | **Split.** Client certs are ~6 lines in a seam the package already overrides (the cost is the server-side descendant that sets `SSL_VERIFY_FAIL_IF_NO_PEER_CERT`); CONNECT genuinely does not exist in `fphttpclient.pp` and should be deferred with the measured reason. |
| 10 | **n14** — `10 : PRINT`, `x = 1 : : y = 2`, `lbl: : stmt` all rejected today | accept (classic BASIC) or keep rejecting | **Accept — as its own item**, touching `Compile`'s loop, `ParseBlockUntil` and `ParseInlineStatements`. **Never fold it into d65**, which is two set tests in the print arm. |
| 11 | **d48** — `phosphordemorunner.pas:HostServices` | exemption, or `mainform` installs the record | **Exemption with the sentence written** ("the demo never enters a script-driven message loop"). Filling it puts LCL into a unit whose stated invariant at `:11-13` is that it has none. Do not let a gate change decide this silently. |
| 12 | **The global cap** (m4) | reopen, or confirm | **Confirm; do not reopen.** Decided 2026-09-01 (`docs/decisions.md:292`). A global count is derived from the *source text* — one assignment line per global — so it is not a script-supplied amplifier at all, and `MaxMemoryBytes` already covers the storage. The live work is prose + extending the test past 513. |
| 13 | **d57 retires a live instruction** | fold, or flag | **Flag.** `assert_int:%%$` makes `CLAUDE.md:77-78`, `docs/dev-agent-playbook.md:198-199` and `:228-229`, and the `rem` at `tests/suite/43_syntax_const.bas:122-123` false. Separate commit, so the CLAUDE.md diff is seen. |

---

## 4. What this plan could get wrong

**Weakest verifications, in order.**

1. **The whole HTTP lane (m5, m6, m7) rests on an unmeasured symbol.** The Linux VM was unreachable today (ssh timed out), so `SSL_get_peer_certificate` vs OpenSSL 3's `SSL_get1_peer_certificate` in `libssl.so.3` is **unknown**. `openssl.pas:2499` returns nil *silently* on a missing symbol, so a hostname check built on it either refuses everything or passes everything on Linux while staying green on Windows. If the symbol is gone, m5 is not medium — it is a week, and the fork above changes answer.
2. **d56's `Halt` from inside a `TTimer.OnTimer` dispatch is unmeasured on gtk2.** Finalization unwinds with the message loop, the widgetset and possibly live forms on the stack. If gtk2 teardown blocks or re-enters there, the watchdog becomes a *permanent* hang — precisely the thing it exists to prevent, and indistinguishable from the bug it was added for. **This is the estimate I trust least in Wave 1.** If it blocks, d56 leaves Wave 1, becomes its own investigation, and Wave 4 moves behind it.
3. **d12 was verified entirely by reading**, on the stated belief that `bin/phosphor.exe` was absent. **It is present and current** — I confirmed it exists, dated Sep 12 20:49, with no `engine/` or `host/` `.pas` newer than it. The reading is decisive line by line, but the four symptoms should be probed once in a scratch directory before the fix lands; there was no reason not to.
4. **d46/d47's headline number was never reproduced** (correctly — it is a bomb). The mechanism is read from `zipper.pp:1093` and `:2747`; the 1.99 GB / 8.3 s figure is not evidence and should not be quoted.
5. **d44's "79"** came from `coverage.py`'s own `load_corpus`/`is_referenced` under a stricter stripping rule written for the occasion. It may move by one or two. It must not move *down to 76* — that is the count a `rem` can satisfy.
6. **m2 is the largest single estimate with the least harness behind it.** The accept-on-the-UI-thread failure cannot be caught by any headless test, because `tests/phosphoridetest.lpr` deliberately creates no widgetset. "Medium for item 7 alone" is a guess sized against `uphosphorrun.pas`'s existing pipe machinery, not against a measurement.
7. **d10's class fix is sized "small"** on the basis that the invalidation walk already exists (`PhosphorJsonLib`'s `InvalidateBorrowed`, `GuiOtherFormShown`). If node→`TreeView` / item→`Owner.Owner` resolution is unreliable for some registration path, it grows — and the instance fix (refuse the free) is the documented contract anyway, so take that first and let the class fix be a separate decision.

**What would make me re-order.**

- If **the Linux VM stays down**, d07's only honest see-it-fail is impossible (Windows passes the new assertions *today*). Hold d07, do d12 and d14, and do not let anyone "verify" d07 by simulating POSIX semantics on Windows and calling it done — that mutation is a step in its test plan, not a substitute for the VM.
- If **fixing `coverage.py` prints substantially more than 79, or prints any *engine* name uncovered**, that is a bigger finding than anything in Waves 4-6 and should be triaged before proceeding.
- ~~If **Wave 1's clean-log check turns the tree red for something other than `probe_budget.lpr:588`** — particularly LCL/gtk2 notes in the `test-gui` build, which no clean-log check has ever seen — that is a decision to take deliberately, not a red suite to grep away. Widening the exclusion filter past `Compiling|Linking` hides our notes in the same build.~~
  **ANSWERED 2026-09-15 by doing it.** It turned the tree red for `probe_budget.lpr:588` as predicted, **and for two more** — `phosphorguitest.lpr(191,3)` and `(192,3)`, `Local variable "GuiSvc"/"Dog" is assigned but never used`, live for as long as that file has existed. They are not cosmetic: taking `@Dog.Bark` is not a read as far as FPC's dataflow is concerned, and what the note was really pointing at is that **nothing ever released either object**. Fixed by releasing them at the two exits that can reach them, timer first because it holds a method pointer into the watchdog. **No LCL or gtk2 note appeared on either platform**, win32 or gtk2, so the exclusion filter stayed at `Compiling|Linking` and the feared decision never had to be taken.
- **Honest scope note:** this is 33 items for one week. Waves 5-7 will not all land. If only Waves 1-4 land, the tree is measurably better and the rest is better understood — which is the argument for this order rather than for starting with the scariest defect.

---

## 5. Not on the ledger — found in the verification pass

**New defects, with anchors.**

- **n1 · `engine/libs/PhosphorBufferLib.pas:152`** — `if APos + ACount - 1 > Int64(ALen) then`: the operands are bounds-checked individually and the **sum is not**, so a saturating `ArgI64` at `APos >= 2` wraps negative and the guard passes. Six registered names through one shared guard. Measured on `bin/phosphor.exe`, 8-byte buffer, exit 0: `buffer_fillrange` and `buffer_copy` answer **9223372036854775807** bytes they never touched, `buffer_slice$` answers `""` where it owes an error. `p=1` is correctly refused, which is why a sweep that tried only position 1 saw nothing. **Its own ledger entry — different file from d18, and its failing test needs no budget.**
- **n3 · `host/packages/PhosphorGzipLib.pas:341`** — `GzipSpent` is a unit global reset only at the top of `RawInflate`, and Pascal's short-circuit `and` means a failed `LoadFileStr`/`GzipUnwrap` never calls it, so a **missing source file after any refused inflate is reported as a budget refusal** with `peLimit`. Same three lines as d14.
- ~~**n4** — a `setBreakpoints` frame with no `lines` key reaches `arr.Clone` with `arr` nil and kills the debuggee.~~ **CLOSED 2026-09-15 by `6f3ca5d`**, and verified closed on 2026-09-18: the only `arr.Clone` left in the file is inside the comment at `host/console/phosphor.lpr:1521` explaining that it used to be there. Every element of `lines` is type-checked now, not just the array — a string, a JSON null and a nested array each used to raise from inside the parse loop.
- **n5 — five clauses, and on 2026-09-18 three of them are closed.** Each was read before it was struck; the file has been edited many times since the list was written and every line number in it had drifted.
    - ~~`setBreakpoints` answers the **requested** set rather than the installed one.~~ **CLOSED by `6f3ca5d`.** `host/console/phosphor.lpr:1521` says so in the past tense and introduces `EnsureStoppable`. This is the clause the citation below was for.
    - ~~Outer frames report `line: 0`.~~ **CLOSED.** `host/console/phosphor.lpr:1698-1711` reads `TCallFrame.CallerStmtPC` through `DbgFrameCallerLine`; a frame whose line still cannot be named reports 0 and the editor draws that as an empty cell, which is correct and is not the defect.
    - **STILL OPEN.** The `error` event carries no text: `host/console/phosphor.lpr:2343` is `SendEvent('error', nil)`. The editor already decodes a `Text` field it is never sent.
    - **STILL OPEN.** `continued` and `trace` are never emitted — zero occurrences of either in the host. `trace` goes to stderr instead.
    - **STILL OPEN, and narrower than it sounds.** `initialize` is not enforced as the first frame: `dbgConnected` is read in exactly one place (`host/console/phosphor.lpr:2395`, where `initialize` promotes it) and nothing refuses a command that arrives before it. A pre-`initialize` command IS answered; what cannot happen early is `launch`.

    THE RULE MOVED, AND SO DID THE CITATION. It was `docs/debug-protocol.md:163-173` when written and was correct then; PhosphorIDE's `e731b40` inserted the conditional-breakpoint section two days later and those lines are now that. The installed-set rule is at **`docs/debug-protocol.md:235-243`** — not 235-245, because `:245` begins a version-2 proposal and a mechanical offset would make a deferred design read as specified. **A citation into PhosphorIDE should be written by name and, if a pointer is needed, by section heading**: a heading survives an insertion above it and a line number does not, and `scripts/check-crossrefs.py` exempts that file by name so nothing here can catch the drift. This is the only line-numbered citation into the sibling in the whole tree, which is why the answer is a convention rather than a gate.
- **n6 · `engine/PhosphorVM.pas:2225-2227`** — `Fault` writes `FErrCode`/`FErrMsg`/`FErrLine` unconditionally, and `CallUserFunc` (`:4423-4716`) never saves or restores them. So a host that evaluates a watch through `CallFunction` from a stop — **the re-entry `docs/embedding.md:956` explicitly blesses** — and whose watch faults, resumes the script with `err()`, `errmsg$()` and `erl()` answering the *debugger's* fault. Unpinned; no probe reads `err()` across a stop.
- **n7 · `engine/libs/PhosphorStrListLib.pas:1215`** — `SaveTextToFile(...); Result := ValInt(l.Count);` discards the Boolean, so a sandbox-**refused** `strings_savetofile` answers the line count as if it had written them. A fabricated success, and a worse defect than d62's stale code.
- **n8 · `scripts/check-seams.py`** — the gate reports *"12 seams filled across 7 hosts"* for a tree that ships **six** `.lpr` under `host/`; the seventh is `host/console/backup/phosphor.lpr`, untracked and matched by `backup/` in `.gitignore`, counted a second time under the same basename key. The gate scans gitignored scratch.
- **n9 · `engine/libs/PhosphorJsonLib.pas:787`** — `JsonNestsTooDeep` scans to `Length(AText)` and counts brackets fpjson never reads: a valid one-level object followed by 300 `[` is **refused** ("nests more than 256 levels deep") while `json_parse@`'s own parser accepts it. Opposite direction from d08, same mis-scoping. `JsonHasUEscape` (`:1259`) is the third copy — a `\u` in the ignored tail triggers a full re-spell and its budget charge for nothing.
- **n10 · `engine/libs/PhosphorIoLib.pas:156`** — `file_readalltext$` sets `GIoError := 2` on any failure, so a **sandbox refusal is reported to the script as "file not found"**; and `IoErrorText` has no code meaning *refused* while the comment at `:535` says 3 means refused and the table at `:788` prints *path not found*.
- **n11 · `engine/PhosphorOpcodes.pas:498`** — the `hdr >= 0` bound in `StoppableLines` is reachable and untested: `engine/PhosphorBytecode.pas:508` validates `Entry` only as `0 <= Entry < Count`, so a legal `.pbc` with `Entry = 0` or `1` makes `hdr` −2 or −1, and the build carries no `-Cr`, so `FInstrs[-1]` is an unchecked read below the array. Deleting the guard would be green on both OSes. (r2's residual — see struck items.)
- **n13 · all four boundary-check copies** — ~~CLOSED 2026-09-15 with d64; one alternation in `scripts/lib/boundary.{sh,ps1}`, guarded by the tenth gate `check-boundary.py` over `tests/boundary`. Measured on the way: it was live on BOTH platforms (bash 8/11, PowerShell 10/11), and reordering the passes is not the fix because brace-first breaks the mirror case.~~ `//` is stripped to end-of-line **before** braces, so a `{ ... // ... }` whose closing `}` sits on the `//` line loses its terminator and the brace stripper swallows forward to the next `}` in the file, potentially a real `uses` clause — **hiding a violation**. One site today (`engine/PhosphorValue.pas:1526`), harmless because its brace is fourteen lines later.
- **n14 · `engine/PhosphorCompiler.pas:2936-3014`** — the statement-*sequencing* loops reject an empty statement: `x = 1 : : y = 2`, `10 : println "x"` and `lbl: : println "x"` all exit 1. `10 : PRINT` is common classic BASIC. Four constructs; a neighbour of d65, not part of it.
- **n17 · `host/packages/phosphorpkgtest.lpr`** — installs no `MaxSteps` and no `TimeoutMs`, and `engine/PhosphorEngine.pas:374,377` default both to 0, so `BudgetBegin(0,0)` answers *go ahead* on its first line. **Every `tests/packages/*.bas` runs with an inert budget**, which is the structural reason a completely broken zip meter or gzip ordering fix is byte-exact green on both OSes. This is a harness gap, not a package defect, and it is why d14 must precede Wave 5.
- **n19 · `host/gui/libs/PhosphorCanvasLib.pas:193`** — `Picture.Bitmap` is a *getter*: `lcl/include/picture.inc:422-436` `TPicture.ForceType` creates, `Assign`s and frees, so merely **reading** `.Bitmap` on an image that went through `image_load@` builds a full-size uncharged bitmap conversion before the new `Assign` replaces it. A second uncharged allocation on the same line as d42.
- **n20 · `host/gui/libs/PhosphorControlLib.pas:301`** — `control_free(tv@)` then `control_free(node@)` calls `Free` on already-freed memory with no read involved: a **double free**, not a stale read. Heap corruption that on Windows passes quietly — the shape most likely to produce an intermittent, unreproducible failure rather than a clean crash.
- **n26 · `host/packages/PhosphorHttpLib.pas:1354-1356`** — `http_proxy`/`http_proxyauth`/`http_clearproxy` exist on the client handle, but **no verb consumes a client handle** (`f_http_get`/`f_http_status`/`f_http_post` all take a bare url$), so the proxy settings never reach a request. That is the only reason fphttpclient's missing CONNECT is a deferral rather than a live defect.

**Wider classes, named because the fix for one member is not the fix.**

- **d12 is four doors, not one.** The RTL's rule is *"a line I cannot parse"*, not `#`: any unrecognised in-section line gets an empty `Ident` and is re-emitted with a spurious `=`; **a value containing a newline produces exactly such a line through `cfg_set@` alone** — no hand editor anywhere near it; a key beginning `;` is appended as a duplicate on every set and read back as the caller's default; a section beginning `;` is written without brackets and reloads as a comment.
- **d10 is four doors, not one** — `control_free(node@)`, `control_free(tv@)`, freeing the owning **form**, and freeing a node whose tree is already gone (n20). And the bookkeeping the class fix needs already exists one file away (`engine/libs/PhosphorJsonLib.pas:292`) and one function away in the GUI itself (`host/gui/libs/PhosphorGuiCore.pas:1490-1503`) — the mechanism is present and simply unapplied.
- **d18's class swept to a grid** — a saturating `Arg*` used as an *operand* before it is clamped or compared. Broken: 2 sites (`center$` ×2) + n1. Correct-by-compare-first: 6. Correct-by-clamp-first: 9, **two of which are this same class already fixed once, with a comment at `PhosphorStrLib.pas:1178-1188` stating the rule** four lines below the site that still has the bug. And `scripts/probe_budget.lpr:262-263` already tests `center$("x", 2e9)`: the *positive* half of the width axis was swept and the negative half never was.
- **Five gates enumerate by convention, not by derivation** — `coverage.py:141`, `check-sandbox.py:81-88`, `check-budget.py:80-82`, `check-codepage.py:229`, `check-suffix.py:108`. Each goes silently blind the day a sixth directory ships code, exactly as `check-seams.py` did when `lazarus/demo/` arrived. And `check-budget.py` **excludes `host/gui/libs` by design and says so**, so d42's entire class is gate-less by construction.
- **`check-budget.py` can be satisfied without pricing anything.** `gated_names` resolves `GATE` hits transitively over callers, so both zip extractors would resolve as GATED the moment they were tainted — because they reach `BudgetAllows(AEntries.Count)` through `ArchiveLocalNamesAreSafe`. The gate asks whether a routine *reaches* a consultation, never whether the consultation prices *that routine's* work. Repairing the `NATIVES` substring taint alone would read green before and green after.
- **d62 is 18 bodies in `PhosphorIoLib` plus 8 more across `PhosphorSysLib` and `PhosphorStrListLib`**, and `GIoError` is private to `PhosphorIoLib`'s implementation section, so `PhosphorSysLib`'s six (`mkdir`/`rmdir`/`forcedirectories`/`chdir`/`fileexists`/`kill`) **cannot** set it. Three sibling libraries (Gzip, Zip, Image) set their error slot at every refusal — the house rule exists, and the unit that owns `ioerror()` is the one that breaks it.

**Items whose size or shape moved.**

- **r2 is done and the ledger never said so** (struck, below) — and **d52 is d44 filed twice**, at two severities, for one line of Python, anchored under a file that is correct.
- **d18 is two units and a gate rule**, not one function. **d47's cited line 840 is `f_zip_addfile`**; the extractors are at 989 and 1054. **d46 has a second site** the item does not name: `PhosphorZipLib.pas:250`, `zip_read$`, same declared-size trust, expanding into memory.
- **m4 is already half-done** — the cap was decided against and the test imported on 2026-09-01 (`ee359f9`); what is left is `docs/roadmap.md:126,135-136` still calling it undecided while `:286` of the same file records it resolved, an orphaned sentence fragment at `:292-293`, and a `rem` in `13_global_limit.bas` stating Plan9Basic's HeapMem as if it were ours — **at exactly 513 globals**, so a reintroduced 513 cap ships byte-exact green.
- **m3 is not blocked by d13**, and **m5's blocker is not SNI plumbing** (FPC performs no hostname verification at all), and **m6's blocker is not AF_INET6** (`TFPCustomHTTPClient.FSocket` is private with no seam; the AAAA half is free in `netdb.pp`), and **r3's cause is not registration** (it is the lexer, and it is every identifier). Four recorded reasons that are stale in a way no gate can see.
- **n12 · seven stale line citations found in one pass** — playbook `:799` cites `PhosphorStrLib.pas:860` (real: 1053), d65's `2228/2240` (real: 2564/2576), d13's `PhosphorEngine.pas:286` (now `SandboxRoot`'s declaration), d62's `embedding.md:296-298` (real: 445-452), d47's 840, d48's `check-seams.py:212` (real: 242), d50's 220 (real: 344 and 83). `check-crossrefs.py` gates that a **path** named in prose exists and never the line after it, so every citation in a 1400-line playbook can drift silently. **That gap is worth a gate more than most of the items it mis-cites.**

---

## 6. Struck from the ledger

- **r2 — "the two guards inside `StoppableLines` that no compiled fixture can reach" — CLOSED.** `tests/probe_debug.lpr:480` `CheckStoppableGuards` exists for exactly this, headed at `:453` with those words; its fixture hand-builds the adversarial shape at `:506-507` (an `opNop` where the jump would be) and asserts line 40 is kept (`:490`), which is the `opJump` conjunct doing work; it is invoked at `:756`, corruptible at `:517` (`--fail` appends `,99`), and registered in **both** runners (`test-suite.ps1:283`, `test-suite.sh:208`). It landed in `2ee6b70`; `tests/probe_step.lpr:2089-2090` names it done in prose. **Residual filed as n11** (the `hdr >= 0` bound is reachable via a legal `.pbc` with `Entry = 0` and is untested — two `Emit` lines in the existing fixture). Separately: the `FInstrs[hdr].Op = opStmt` conjunct is **untestable by observation** — `PhosphorOpcodes.pas:506` already short-circuits on `opStmt` before `skip[]` is consulted, so deleting it is behaviour-preserving and a guaranteed mutation-test survivor **by construction, not by missing coverage**. Record that in a comment at `:498` so the next reviewer does not report it.
- **d52 — duplicate of d44.** Its own text says so (*"anchor is `coverage.py:141`, not `tests/gui/manifest.txt:1`"*), and its filed anchor is innocent: `tests/gui/manifest.txt` lists 22 basenames plus 3 comment lines and `tests/gui/*.bas` is exactly 22 — **confirmed today, both directions clean**. Fold it into d44 with a dated pointer in the append-only style the ledger already uses. **Carry its number forward: 79** (GUI names with an actual call, comments and string literals stripped; 80 excluding the `compile`-only `examples/gui_demo.bas`), not d44's looser 76 — the three-name gap (`inputbox$`, `msgbox`, `openfile$`) is precisely the difference between a gate that requires a call and one a `rem` can satisfy. The fold edit rides in d44's Wave 3 commit.

---

## Open after the 2026-09-18 close review

Five critics and a judge attacked the day's five changes and one deferral before
they were committed. Two blockers and nine should-fixes were ruled real; all of
them are closed in the tree. These are what was ruled real and **not** taken, each
with why, plus what the review itself did not reach.

**The two blockers, for the record, because both are closed but neither should be
forgotten.** The first was a regression in a commit that had already been pushed:
reporting a boundary under its most specific fact made an interrupt landing on an
armed line arrive as `breakpoint`, while the host's only queue drain was still
keyed on `pause`. A frame arriving while the program stood on a conditional mark
was consumed, never read and never re-nudged — the editor's Pause button did
nothing and every frame behind it died too. The second was **not** today's, and
the judge struck the critic's attribution: `daRun` has always meant both "the user
pressed Continue" and "resume", so any host resume cancelled a step in flight.
Both are closed by one repair — one drain at every boundary, and `daKeep` for a
resume that decides nothing — and both are pinned by tests watched failing first.

### Filed, not fixed

- **`setBreakpoints` never reads its `path`.** The handler reads `lines` and
  `conditions` only, so a frame naming another file replaces *this* file's whole
  set — measured: a stop on a line the editor never marked in this file, and none
  on the line it did. The comment that promised otherwise has been withdrawn. Not
  repaired blind, because a strict comparison against `FPath` fails **worse** than
  the bug: an editor spelling the same file differently — forward slashes, a
  relative path, a different case, a symlink — would have every breakpoint
  silently ignored, which is a dead debugger rather than a confused one. Wants a
  measurement of what real editors actually send, then a comparison built for it.
- **`--no-console` rewires `ErrOutput`, and every diagnostic writes to `StdErr`.**
  On win64 those are separate records (`FPC_STDOUT_TRUE_ALIAS` is defined only for
  atari and embedded), so a packed `--no-console` application whose program faults
  raises instead of printing and exits 3 — the code reserved for an interpreter
  bug — where the honest answer is 1. Pre-existing. The fix is the same one that
  would close it properly: route the ~108 `Writeln(StdErr, ...)` sites through
  `TConsoleHost.WriteStdErr`, which already branches on whether the handle is a
  console and gets both cases right. That is a large mechanical edit and wants its
  own change, not a rider on a review.
- **The standard text files are `threadvar`s.** Every thread FPC starts re-opens
  and re-stamps them, so the codepage pinned at the door is pinned for the main
  thread's copies. Latent today — no thread in this host writes a diagnostic —
  and it disappears entirely under the `WriteStdErr` route above.
- **A citation's line number rots invisibly.** `check-crossrefs.py` validates the
  path and never the line, and three citations about this very mechanism were
  wrong, one of them written the same day. All three are now written by NAME
  instead, which is the cheap fix and the one that scales; a gate that checked
  line numbers would be noisy enough to be turned off. Worth revisiting only if
  named citations start rotting too.

### What nobody checked

Named on purpose. A review's silence is not coverage, and this project's own rule
is that a stage which never rejects is measuring nothing — so it follows that a
stone never turned over is not a stone known to be clean.

- **`stepInto` and `stepOut` colliding with a frame.** Every step measurement in
  the review, and every new test, is `stepOver`. `daKeep` applies to all three and
  `dmStepOut` carries an extra clamp; nobody collided a frame with either.
- **The rest of the command set in the entry segment.** Only `setBreakpoints`,
  `pause` and `disconnect` were ever sent with `launch`. `evaluate`, `stackTrace`
  and `variables` arriving there are untested, and `stackTrace` is state-guarded.
- **A segment whose first frame closes the session.** The drain breaks on it, so
  every frame behind it stays queued. Nobody asked what the editor is owed for
  those.
- **The packed stub and the GUI door**, end to end — which is exactly where the
  `--no-console` item above would bite.

## Decided 2026-09-18 — the compiled breakpoint condition stays uncached

`docs/debugging.md` records that a condition is recompiled on every hit,
deliberately and not by oversight. The sibling repository's roadmap lists it as a
defect of this one. **It is not, and the decision to leave it stands — but the
first version of this entry got all three of its load-bearing numbers wrong, in
the direction that made the deferral look safe.** A close review overturned them
with measurements, a judge reproduced those independently, and the table below is
a third run, taken for this rewrite with its own driver. That history is written
down because the entry's whole job is to stop the next reader taking the
measurement again, and for one day it would have handed them a wrong answer
instead.

A mark on the loop line, 40 hits, best of two rounds, driven over the protocol
the way an editor drives it. Filler lines are assignments to distinct globals,
because the prologue copies every live global in and a lines-only shape
understates what a real program pays:

| program | no mark at all | mark, **no** condition | condition never true | condition always true |
| --- | --- | --- | --- | --- |
| 606 lines | 0,007 s **total** | 5,930 ms/hit | 2,12 ms **per evaluation** | 7,902 ms/hit |
| 1206 lines | — | 6,045 ms/hit | 6,00 ms | — |
| 1806 lines | — | 6,085 ms/hit | 11,05 ms | — |
| 2406 lines | — | 6,315 ms/hit | 18,55 ms | — |

**Read the units.** Two of those columns take **zero stops**, so there is no hit
to divide by: the no-mark arm is a session's fixed cost and is reported as a
total, and the false-condition arm is reported per *evaluation*. The first
version of this entry printed both as "ms/hit" over hits that never happened,
which made the cheapest column look comparable with the others when it is not.

**The 5,9 ms is not work. It is one poll quantum.** The park loop in
`TDebugProto.OnStop` sleeps 5 ms between reads while the VM is parked — its own
comment says this seam MAY block — so no stop can cost less than 5 ms however
fast the editor answers. 150 consecutive stops answered instantly never once fell
below it. The flatness in the table is the same fact from the other side: 5,930 →
6,315 ms while the program grows four-fold. **The real work of a stop is under a
millisecond**, and any ratio quoted against 5,9 ms is a ratio against a constant
this host chose. Make that loop event-driven and every such ratio is void without
a line of this entry changing.

**The crossover is BELOW 2000 lines, not past it** — this entry said "somewhere
past 2000", and a reader who took that as the safe band would ship a 1700-line
file into the regime it promised they were not in. Measured three times
independently: **~1200 lines** when the added lines carry globals (twice, here
and by the judge) and **~1650** on a lines-only shape. The arithmetic was
available from the entry's own two rows all along — 5,93 ms ÷ 3,6 µs per line ≈
1650 — so the printed figure was not even the one its own numbers gave. Against
the stop's *real* work rather than the sleep, the crossover is nearer 200 lines.
And the growth is worse than linear: +3,9 ms, +5,1, +7,5 over each 600-line step.

**The always-true row is the one the feature exists for**, and no earlier version
priced it: 7,902 ms/hit — the condition *plus* the stop it correctly took. A
cache would save the ~2 ms of condition there too, on the arm where the user is
being stopped anyway and is not counting milliseconds.

**So why still no cache?** Not the ratio, which was a measurement of a sleep.
**Priority, said plainly:** nothing in this tree or the sibling has measured a
real program suffering, the shape that would suffer is a hot conditional line in
a file past ~1200 lines, and the work is not small.

*(The earlier draft closed with "at that size a person is not watching a
breakpoint fire thousands of times". That argument is struck: a conditional
breakpoint exists **precisely** so the person is not watching, and taken
seriously it would make the unconditional baseline infinite. It cannot support
the deferral it was written to support.)*

**And the work is not small, for a reason that is new.** The per-hit cost is not
only the compile. `TDebugProto.EvaluateExpr` compiles `FSource` plus one appended
line, then emits a **prologue** that copies every live global and every local of
the chosen frame in with `prog.Consts.Add(...)`, then runs the chunk on a fresh
VM. Those values change at every hit, so the prologue must be re-emitted at every
hit whatever else is cached.

The **instruction** half of that is a solved problem and this entry said
otherwise: `docs/debugging.md` and the field comment on `FSource` both already
describe re-pointing the prologue's `opPushConst` with `TProgram.Patch`, measured
at zero instruction growth over 10 000 evaluations, and `Patch` is **existing**
public surface — three lines that set an emitted instruction's operand. Saying
the fix "means new surface on `TConstPool` or `TProgram`" put a third, opposite
account of the same work into the tree.

**What today's measurement actually adds is the pool.** `Patch` moves a pointer;
it does not free what the pointer left behind. `TConstPool` has `Add` and `Get`,
no setter and no truncate, so a kept program still grows by one pool entry per
global per hit, for ever. That half is genuinely uncovered, and closing it wants
new surface on `TConstPool` — an engine type on the VM's hot path — plus a test
that asserts **pool growth as well as time**, because a timing-only assertion is
green with the leak.

Revisit if a real program is ever measured suffering. Until then this entry
exists so the next reader does not take the measurement again — and so that the
next reader knows it was taken three times before it was right.
