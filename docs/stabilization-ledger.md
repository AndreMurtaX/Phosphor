# Stabilization ledger -- round 11 (2026-10-12)

Round 11 ran in stabilization mode (docs/proposal-1.0.md, section 4): its eight
HIGH survivors were fixed inside the round; the MEDIUM and LOW survivors are
listed here, each with a PROPOSED decision for the owner to confirm or change:

- **FIX** -- a real defect, to be fixed in a separate batch after the HIGHs,
  with the same minimal-change and diff-review rules;
- **DOC** -- the code is acceptable and the documentation must say what it does
  (or the smallest code change that makes the documentation true);
- **ACCEPT** -- a platform or design limit, to be documented as such.

Each finding's full repro, expected and actual values and the skeptic's
verdict are in the round's workflow result; the title and location here are
enough to find the code.

| # | area | sev | finding | where | proposed | note |
|---|---|---|---|---|---|---|
| 1 | core | MEDIUM | VM instructions that do O(n) work on script strings are unpriced: TimeoutMs = 1000 runs 60 s ('s$ - 1'), and 'print using' runs 56 s and reports success | engine/PhosphorValue.pas ValSub (~line 1802-1807: Utf8Len plus Utf8Left over the whole string) and ValCompare (~line 216 | **FIX** | same class as the budget: decide with proposal-1.0 section 3 (option B bounds it by the clock after each call -- extend to these instructions) |
| 2 | core | MEDIUM | Array element kind is not enforced: dim@ stores strings, sdim@ stores numbers, and sarr_get$ returns an int | engine/libs/PhosphorArrayLib.pas t_arr_set (~line 227-242): `a.Data[flat] := Args[High(Args)]` never checks a.Kind. It i | **FIX** | a typed array accepts any kind; refuse on write as an assignment refuses. FIXED 2026-10-12, stabilization batch 1 |
| 3 | core | MEDIUM | A SWAP that fails on its second store has already done the first, destroying a value; SWAP is also missing from language-reference.md | engine/PhosphorCompiler.pas ParseSwap (~line 2291-2315): EmitWriteTarget(m1, t2) is followed by EmitWriteTarget(m2, t1)  | **FIX** | check both stores before doing either; add SWAP to language-reference.md. FIXED 2026-10-12, stabilization batch 1 |
| 4 | core | MEDIUM | language-reference.md says a suffix-less number is a double-precision float; it holds an Int64 and overflows, so the reference's own factorial example dies at n = 21 | docs/language-reference.md 'Data types & the suffix convention' table (~line 103-105) and quick reference (~line 1161),  | **DOC** | the reference must say what a suffix-less numeric holds (Int64 for integral literals) and fix its factorial example |
| 5 | core | LOW | 'for i% = 1 to 3 step 0.5' never ends: banker's rounding of the int% loop variable sticks at 2 | engine/PhosphorCompiler.pas ParseFor (~line 1799-1838): the literal step is accepted as a Double for any loop variable.  | **FIX** | refuse a fractional step for an int% loop variable at compile time |
| 6 | core | LOW | FOR's STEP must be a numeric literal, but the language reference documents 'step k' | engine/PhosphorCompiler.pas ParseFor (~line 1799-1818) against docs/language-reference.md Loops notes (~line 340) and qu | **DOC** | either allow an expression or make the reference say a literal |
| 7 | data | MEDIUM | Windows: tanh raises 'Invalid floating point operation' for x < about -354.9, and asinh/acosh raise 'no finite result' for /x/ > about 1.34e154, although every true value is small and finite | engine/libs/PhosphorNumLib.pas f_tanh/f_asinh/f_acosh/f_cosh call the RTL math.pp versions. tanh computes exp(-2x), whic | **FIX** | answer the IEEE result (-1 / +-inf limits) instead of raising |
| 8 | data | MEDIUM | sinh, tanh and asinh lose almost all precision near zero (sinh(1e-10) wrong in the 8th digit, asinh(1e-20) = 0, tanh(4.8e-17) about 15% too large) | engine/libs/PhosphorNumLib.pas f_sinh/f_tanh/f_asinh call the rtl/objpas/math.pp formulas: sinh = 0.5*(e^x - 1/e^x), tan | **FIX** | use expm1/log1p-style formulas near zero |
| 9 | data | MEDIUM | tan refuses every /x/ >= 2^63 ('Invalid floating point operation' on Windows, 'tan has no finite result' on Linux) and is inaccurate well before that | engine/libs/PhosphorNumLib.pas f_tan: System.Tan is evaluated with x87 fptan on both targets. fptan cannot reduce /x/ >= | **FIX** | with the round-11 argument reduction, tan answers like sin/cos |
| 10 | data | MEDIUM | A string list whose sorted flag is on is left unsorted by strings_insert, strings_strings (set), strings_exchange, strings_move, strings_text, strings_commatext and strings_delimitedtext; strings_find then misses items that are present | engine/libs/PhosphorStrListLib.pas: t_strings_set (line 900), t_strings_insert (920), t_strings_exchange (943) and t_str | **FIX** | every mutator of a sorted list keeps it sorted or clears the flag (as the RTL does) |
| 11 | data | MEDIUM | asc decodes ill-formed UTF-8 into characters that are not there: overlong C0 80 is 0, C1 BF is 127, a truncated F0 9F 98 is 2008, F4 90 80 80 is 1114112 (beyond U+10FFFF) | engine/libs/PhosphorStrLib.pas f_asc (around line 425): it decodes by masking the lead byte by length and checks neither | **FIX** | asc of an ill-formed sequence answers U+FFFD, the rule the rest of the string library keeps |
| 12 | data | MEDIUM | rnd(n) is strongly biased for large bounds: rnd(3*2^61) falls below 2^61 half the time instead of a third | engine/libs/PhosphorNumLib.pas f_rnd_n calls System.Random(Int64). That function (rtl/inc/system.inc:652) takes 63 rando | **FIX** | rejection sampling for bounds above 2^32 |
| 13 | data | MEDIUM | Typed arrays accept any kind on write: a string goes into a dim@ (numeric) array, a number into an sdim@ or pdim@ array, with no error until a later read | engine/libs/PhosphorArrayLib.pas t_arr_set (line 227): `a.Data[flat] := Args[High(Args)]` with no check against a.Kind. | **FIX** | same as "Array element kind is not enforced". FIXED 2026-10-12, stabilization batch 1 |
| 14 | data | LOW | reverse$ is not its own inverse and changes len when a stray continuation byte follows an ASCII character | engine/libs/PhosphorStrLib.pas CpReverse (line 169) and CpSpan/CpLen: a character is "a lead byte and every continuation | **ACCEPT** | documented: reverse$ of ill-formed UTF-8 is not involutive |
| 15 | data | LOW | Small cross-OS numeric divergences: exp(1), atan2(-0, -1), frac(-0), atanh(0.5), acos near 1 | engine/libs/PhosphorNumLib.pas f_exp/f_atan2/f_frac/f_atanh/f_acos call RTL math. On Win64 float = Double and the fallba | **ACCEPT** | document the last-digit differences of the platform libm, or route through the round-11 functions |
| 16 | recent | MEDIUM | getkey$ ignores TimeoutMs and MaxSteps (pause is bounded, a key wait is not), and no user doc says so | host/packages/PhosphorCrtLib.pas: f_getkey to KbdRead/HeadKey (WaitForSingleObject(h, INFINITE)) on Windows, and the Uni | **DOC** | a key wait is a person, like INPUT: document that key waits are outside the ceilings (or bound them by TimeoutMs -- owner choice) |
| 17 | recent | MEDIUM | File times: Linux sets 1904 when asked for 2040 (answers 1) and reads post-2038 files as 0; Windows rounds to 2 s (up), reads pre-1980 files as 0, ignores sets outside 1980-2099 | engine/libs/PhosphorIoLib.pas t_file_gettime: WinDosAge (FileTimeToDosDateTime), FileAge/FileDateToDateTime on Unix. t_f | **FIX** | 64-bit time on Linux; Windows range and rounding documented |
| 18 | recent | MEDIUM | path_canonical$("file/") on Linux answers the file's name (and "filelink/" the target's) for a path the kernel refuses with ENOTDIR | engine/libs/PhosphorIoLib.pas CanonicalUnix: the not-a-directory check, which skips the last component | **FIX** | a trailing separator on a non-directory answers "" as the kernel refuses it |
| 19 | recent | MEDIUM | Linux directory listings truncate names at a backslash: dir_getfiles$ answers names that do not exist, dir_copy silently drops files and duplicates others | engine/libs/PhosphorIoLib.pas CollectEntries / CopyTree / DeleteTree (sr.Name from FindFirst/FindNext). The root cause i | **FIX** | a backslash is an ordinary character in a Linux name |
| 20 | recent | MEDIUM | file_copy's price (two units a byte) refuses a 130 MB copy that takes 210 ms, about 10x its measured cost and outside embedding.md's 'at most four times' bound | engine/libs/PhosphorIoLib.pas ReadAllBytesTimes (BudgetAllows(len * ATimes)) and CopyFileBytes (ATimes = 2). docs/embedd | **FIX** | reprice copies by measurement, or moot under proposal-1.0 option B |
| 21 | recent | LOW | file_kind$ answers differ across OSes for the same spellings; Windows answers "none" for an existing file at a path of 260+ chars | engine/libs/PhosphorIoLib.pas KindOfWin (the KIND_ERR_PATH_NOT_FOUND to 'none' mapping; no \\?\ prefix in KindFullW) and | **DOC** | document per-OS spellings; long paths (\\?\) on Windows answered |
| 22 | gui-app | MEDIUM | Saving or deleting a product line wipes unsaved contact input on both company pages | examples/contact_manager.bas#rebuild_line_lists (the final 'Put the ticks back' loop calling load_contact); reached from | **FIX** | contact manager |
| 23 | gui-app | MEDIUM | A save after another copy of the program deleted the record reports success and silently drops the edit | examples/contact_manager.bas#finish (no changes check) as used by on_company_save, on_contact_save, on_user_save, on_lin | **FIX** | contact manager: report "the record no longer exists" |
| 24 | gui-app | MEDIUM | Searching a tax id typed with punctuation does not find a company stored without it, contrary to the doc | examples/contact_manager.bas#refresh_companies (q$ is only fold$/like_pattern$; no tax_key$ comparison) and #search_key$ | **FIX** | contact manager: normalise the query as the stored key is normalised |
| 25 | gui-app | MEDIUM | Saving or adding a product line resets the 'Serving the product line' filter to (any) but leaves the list filtered | examples/contact_manager.bas#rebuild_line_lists (combo_itemindex@(c@, 1) without refresh_companies(k)) | **FIX** | contact manager |
| 26 | gui-app | MEDIUM | After saving a company that no longer matches the search, the status names a different company | examples/contact_manager.bas#on_company_save (status built from edit_text$ after refresh_companies) | **FIX** | contact manager |
| 27 | gui-app | MEDIUM | CSV export is superlinear and freezes the window: 27 s for 20,000 companies with no progress | examples/contact_manager.bas#export_csv (string accumulation and per-cell nth$ walk; no progress pump) | **FIX** | contact manager: build the file linearly, show progress |
| 28 | gui-app | MEDIUM | calendar_date@ silently drops dates before 1752-09-14 on Windows once the calendar has a window, and turns a stored one into TODAY when the form is shown | host/gui/libs/PhosphorMiscLib.pas#f_cal_date_set (checks only MinDateTime/MaxDateTime; the win32 month-calendar range is | **ACCEPT** | the Windows calendar control has no earlier dates: refuse the set with gui_error and document |
| 29 | gui-app | MEDIUM | gui-edit.md says memo setters fire onchange immediately, but on a form never shown they fire nothing (an edit does) | docs/libraries/gui-edit.md (intro paragraph and memo_onchange@ row); host/gui/libs/PhosphorEditLib.pas memo setters | **DOC** | state when a setter fires onchange (on a form never shown, an edit does and a memo does not) |
| 30 | gui-app | LOW | Picking a history entry loads its date, subject and notes but leaves the Kind list showing another kind | examples/contact_manager.bas#on_history_select | **FIX** | contact manager |
| 31 | gui-app | LOW | Company list puts names with an accented first letter after Z | examples/contact_manager.bas#refresh_companies, #refresh_contacts, #export_csv, #refresh_lines (ORDER BY ... COLLATE NOC | **FIX** | contact manager: order by the folded key |
| 32 | gui-app | LOW | docs/contact-manager.md states stale sizes: 205 self-test checks and about 3,850 lines | docs/contact-manager.md (intro and 'It tests itself') | **DOC** | update the numbers |
| 33 | gui-app | LOW | gui-choice.md does not say that combo_itemindex@ and list_itemindex@ fire no change event, while it says checkbox_checked@ and radiogroup selection do | docs/libraries/gui-choice.md combo_itemindex@/list_itemindex@ rows | **DOC** | state which setters fire a change event |

Totals: ACCEPT 3, DOC 7, FIX 23.

## Found by the diff reviews of the round-11 fixes

Each HIGH fix was reviewed adversarially before merge. Two HIGH defects the
reviews found in the FIFO fix (a Windows named pipe reached by another spelling;
RAG and the GUI picture loaders opening a FIFO) were fixed before merge, and so
were two MEDIUMs in the core fix (every user-function call 13-28% slower; a
refused `on error call` handler hiding the fault it was handling). What the
reviews found and was left, by the stabilization rule:

| # | area | sev | finding | proposed | note |
|---|---|---|---|---|---|
| R1 | num | MEDIUM | `sin`/`cos` now cost about 1 us a call, 17x the old (a trig-heavy loop runs 2x slower) | **FIX** | a fast path: polynomial below pi/4, Cody-Waite for moderate arguments, Payne-Hanek only for huge ones; word-level bit reads. FIXED 2026-10-12, stabilization batch 1 |
| R2 | num | MEDIUM | `tan` refuses every abs(x) >= 2^63 while `sin`/`cos` now answer | **FIX** | route `tan` through the same reduction |
| R3 | num | LOW | `tan`, `atan`, `ln`, `exp` still differ by 1 ulp between the OSes | **ACCEPT** | or route through pure-Pascal versions; document |
| R4 | json | LOW | `json_getn` widens an Int64 node to a Double; the "json_getn answers the same for both" assertion in 105_json_int_round11 passes without the fix | **DOC** | state it in json.md; rewrite or drop that assertion |
| R5 | core | LOW | the file-read memory checks run after the read-ahead, so one huge line can overshoot the ceiling by about 2x before the refusal | **FIX** | ask inside the read-ahead; pre-check `input$(n, #)` |
| R6 | core | LOW | `docs/embedding.md` still says memory reaches a script through two doors only (`+` and library calls) | **DOC** | name string `-` and the file reads |
| R7 | io | LOW | the special-file check and the open are two calls: another process can swap a file for a FIFO in between | **ACCEPT** | documented in io.md |
| R8 | io | LOW | a FIFO at a WAL database's `-shm` name is not on the SQLite door's list (it fails with "disk I/O error", no hang) | **FIX** | add `-shm` to the companions checked |
| R9 | io | LOW | the GUI picture loaders' special-file check has no automatic test (they need the LCL) | **FIX** | a phosphorguitest case |
| R10 | app | LOW | a read-only CSV target is replaced, and on Windows `NAME.old` is left behind | **FIX** | refuse a write-protected target, check `file_delete` |
| R11 | app | LOW | replacing by rename breaks hard links and drops the mode/attributes; a writable file in an unwritable folder is now refused without a reason | **DOC** | say so in contact-manager.md; name the folder in the message |
| R12 | app | LOW | a crash between the two moves leaves only `NAME.old`; two self-test checks can pass vacuously (no 8.3 alias on the volume; the move-aside branches are never reached) | **FIX** | recover `NAME.old` on start; make the checks say when they did not run |
| R13 | app | LOW | the CSV export's refusal messages talk about SQLite | **FIX** | export-specific wording |

## Test stability

| # | where | what | proposed |
|---|---|---|---|
| T1 | `tests/debug_protocol_test.py` (block R) | "a hot breakpoint keeps every hit while frames arrive mid-run" failed once on the CI Windows runner (1 of 40 hits), passed on the rerun and 8 of 8 locally: a noise thread sends a frame every 0.5 ms | **FIX** -- bound the noise to what the runner can carry, or measure the rate it achieves and judge the hits against that |
| T2 | the GUI runner on Linux | `phosphor` exits on "cannot open display" when WSLg announces a display it does not have (after a reboot); unset DISPLAY and WAYLAND_DISPLAY | **DOC** -- the Linux battery already unsets both |
| T3 | `tests/console_input_test.py` (blocks V, AE, AH of `scripts/test.ps1`) | the Windows console cases read keystrokes typed at the desktop while they run (seen 2026-10-12: answers held letters nobody sent), although each case's console is hidden since that day | **FIX** -- the injected input must not depend on keyboard focus (write only to the case's own input buffer, refuse a case whose console can take focus); until then, do not type during that block |
| T4 | `scripts/test-packages.ps1` HTTPS cases (15, 16, 17 and the TLS part of 14) | failed together on Windows while the Linux package runner ran at the same moment in WSL: WSL forwards a Linux listener to Windows `localhost`, so the two runners' fixed test ports collide across the machines (passed alone at once) | **FIX** -- pick a free port per run and pass it to the test; until then, never run the two package runners at the same time |
