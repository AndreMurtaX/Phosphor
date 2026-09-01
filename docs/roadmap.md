# Phosphor BASIC — phase-1 roadmap (adversarially vetted)

How this was produced: three proposers argued opposed philosophies (oracle-first,
types-first, risk/irreversibility-first); four adversarial judges tried to refute
them (sequencing feasibility, cost-of-deferral, oracle convergence, reference-
reuse/scope); one synthesizer merged the survivors. This file is the vetted
plan of record. It supersedes the off-hand "lexer + five-value model first"
suggestion — the judges showed a generic types-first order defers all oracle
contact to the end (big-bang integration) and a naive oracle-first order plants
a three-type cell that step 3 would rewrite.

## Verdict

Build **oracle-first**, but **freeze the founding structures in the first
increment** rather than deferring them:

- the **five-kind value cell** (`vkDouble | vkString | vkInt | vkHandle | vkBool`)
  carried on the stack from the first instruction — not a Double-only cell
  widened later;
- the **`:`-separated registry** and its type-code alphabet;
- the **error-state record** shape (record-don't-raise), even though asserts
  never fail yet;
- only the **opcode encoding discipline** (explicit append-numbered literals,
  stored-vs-derived `TInstr` fields, indexable constant pool) — **never the
  opcode catalogue**, which grows by append as codegen needs it.

Target `00_harness.bas` first (earliest genuinely-runnable oracle file), but
**harden its definition-of-done** with a companion `00b_kernel.bas`: `00_harness`
alone goes green on a single-numeric Double cell and proves *nothing* about the
founding divergences — the false-milestone hazard all four judges flagged.

Do **not** accept "all 45 suite + 15 negative green" as the phase-1 finish line:
it drags `Data.DB` / `HttpClient` / `zip` past architecture.md's "no external
dependencies". Phase 1 is a **named subset** of core + pure-RTL files; defer
`23_archive`, `32_http_offline`, `33_rag`, `34_sqlite_full`.

Reconcile the semantic reversions (strict boolean, base-1, 05/07 reclassification,
`#`→`@`, `?>`/`?<`→`max`/`min`) as a **rule set before parser semantics land**,
and verify each parser-constraining negative **at the step that builds its
feature** — asserting the rejection *reason*, never batched at the end (the
`--expect-fail` runner greens any non-pass, so a negative can "pass" hollow as an
unknown-function error).

## The central hazard to pin now

`00_harness.bas` mixes integer literals into every numeric assert
(`assert_eq(2+3,5)`), but the ported assert library registers only Double-slot
overloads (`assert_eq:nn`). Under `int + int → int`, `2+3` is `int%`. Without a
defined coercion, the first oracle file fails to compile with "no function with
such arguments". **Rule, frozen in increment 1:** `int%` binds to an `n`
(numeric) signature slot by widening to Double at the host-parameter boundary, so
`assert_eq(2+3,5)` [int args] and `assert_eq(10/4,2.5)` [double args] both resolve
to `assert_eq:nn`. Exact-kind match first, then `int→double` widen, never
`double→int`.

## Sequence

Each step names its gate (exit criteria) and its cost of deferral. Per-file
triage of the oracle is done **lazily, one file ahead of each step**, not as a
45-file manifest up front (that manifest is the highest-uncertainty non-code task
and is unverifiable until the engine exists).

1. **First increment** — thin `lex → compile-to-TInstr → five-kind stack-VM`
   slice that runs `00_harness.bas` green, freezing the five-kind cell, the `:`
   registry, the error-state record, and the opcode discipline. *(Full DoD below.)*
   **Gate:** runner on verbatim `00_harness.bas` reports asserts-passed == assert
   line count, failed == 0, exit 0, byte-exact golden; `00b_kernel.bas` proves
   `7\2`=int 3, `3+4` stays int, `10/4`=double 2.5, int overflow returns a
   catchable error result, `2>1` is a producible bool value; opcode numbers are
   explicit append-only literals with an assertion; `-ProveFailure` shows FAIL
   then PASS; boundary scan still passes.
   **Deferral cost:** this is the plumbing for all later files; under-designing
   the `:` separator, type-code alphabet, coercion rule, error record, or
   stored/derived split forces a rewrite of every later package.

2. **Reconciliation & scope charter** (rules, not a 45-file manifest) — freeze
   the cross-cutting reversions and draw the phase-1 line (named subset;
   `23/32/33/34` and their zip/HttpClient/Data.DB deps explicitly out).
   **Gate:** rules in docs; negative 05 moved to positive, 07 tagged with its
   decided reason; the phase-1 subset and deferred-library list referenced by the
   runner manifest.
   **Deferral cost:** without it, a failing oracle file pulls the parser toward
   the exact semantics decisions.md rejects, and a negative-suite test then
   *defends* the wrong behaviour.

3. **Variables + five-kind arithmetic/promotion/overflow + boolean operators +
   comparison-as-value** — splits the proposers' step-3 big-bang (which also
   needed inline-IF and `and/or/not`). Reclassified positive 05 verified here.
   **Gate:** promotion/overflow oracle passes; reclassified-05 passes as positive;
   assert numeric family still dispatches with real variables.
   **Deferral cost:** a wrong promotion/overflow rule corrupts arithmetic across
   every later file; retrofitting the fifth type after exec grows rewrites every
   operator handler.

4. **Control flow + strict-boolean condition enforcement** — IF/ELSEIF/ELSE,
   WHILE, DO/LOOP, REPEAT/UNTIL, FOR/NEXT, SELECT CASE, jump/label backpatching.
   Negatives 06/08 reject *for the strict-boolean reason*; 11 (spaced compound
   op) rejects.
   **Gate:** `01_language_core` + `02_control_flow` + inline-else + elseif green;
   06/08 reject with the strict-boolean diagnostic; a jump-backpatch nesting probe
   passes.

5. **User functions + global cap** — function/local/return, recursion, typed
   local frames respecting all five kinds; global-limit wired so negative 01
   rejects at the cap.
   **Gate:** `03_functions` green; negative 01 rejects for the intended reason; a
   recursion/frame-teardown probe shows no local leakage.

6. **Arrays + DATA/READ/RESTORE** — `dim`, base-1 line index `s$[n]` and char
   index `s$[[n]]`, index-rounds. Validates the base-1-adjusted files.
   **Gate:** `04_arrays` + `05_data_read` green; a deliberate base-0 leak fails.

7. **Handle registry + error-state contract, end-to-end** — the `@` handle type
   and the first handle-minting packages (dict@, stringlist@, array@); fabricated
   or freed handles are rejected *for the library's recorded reason* (needs the
   library present, not a hollow unknown-function pass).
   **Gate:** handle files green; negatives 02/03/04/09/10 reject with the
   library's recorded detail; `ON ERROR` reads the increment-1 error record.

8. **String + numeric libraries** — `mid$`/`instr`/`len` base-1 everywhere;
   `max()`/`min()` replacing the freed `?>`/`?<`.
   **Gate:** `06_strings` + `07_numbers` + the 13 base-1-adjusted files green; a
   multibyte-input index probe matches the decided byte-vs-codepoint rule.

9. **Pure-RTL library breadth (phase-1 subset)** — json, datetime, config,
   encoding, ioutils, classic file I/O + `PRINT USING`; excludes
   sqlite/http/rag/archive.
   **Gate:** in-scope suite files green byte-exact; locale-independent float
   formatting matches so asserts don't fail for a formatting reason.

10. **Syntax-strictness roll-up** — compound-op adjacency, kind-from-first-token,
    const immutability, let-list, compound arrays. A standing regression that
    asserts every in-scope negative rejects *for the intended reason*.
    **Gate:** all in-scope negatives reject for the asserted reason; full in-scope
    suite + negative subset green byte-exact.

## First increment — definition of done

New engine units (all host-agnostic; the boundary scan must still pass):

- `engine/PhosphorValue.pas` — five-kind `TValue` (`vkDouble/vkString/vkInt/
  vkHandle/vkBool`; Int64 for int%, Double for numeric) + arithmetic/promotion/
  overflow kernel returning **error-carrying results**, never raising.
- `engine/PhosphorErrors.pas` — error-state record + codes (the record-don't-raise
  shape).
- `engine/PhosphorOpcodes.pas` — explicit append-numbered `TOpcode`; `TInstr`
  with STORED (token/i/n) vs DERIVED (proc) fields documented; `TConstPool`.
- `engine/PhosphorLexer.pas` — numbers (int literal → vkInt, decimal → vkDouble),
  strings (raw-UTF-8 slice, no transcode), identifiers, operators incl. `\`,
  parens, comma.
- `engine/PhosphorRegistry.pas` — `Lib.Add('name:signature')` on `:`; type-code
  alphabet `n` (numeric = Double|int%), `$`, `@`, `?`; `#` is never a type code;
  numeric-family coercion (int% → `n` slot by widening).
- `engine/PhosphorCompiler.pas` — source → `TInstr` stream over the constant pool.
- `engine/PhosphorVM.pas` — stack machine over `TValue`, dispatch via the opcode
  table into the kernel.
- `engine/PhosphorEngine.pas` — **replace the PRINT/PRINTLN stub**; wire
  lexer→compiler→VM→registry; expose test counters + error state; keep `OnOutput`
  as the only output seam.
- `tests/PhosphorTestLib.pas` — ported `test_case`/`assert_true`/`assert_false`/
  `assert_eq`(num+str+msg)/`assert_near` driving `AssertsPassed`/`AssertsFailed`.
- `host/console/phosphortest.lpr` — runner host (modelled on the reference
  `Plan9BasicTest.dpr`) that reads the counters and sets the exit code.
- `tests/suite/00_harness.bas` (+ `.expected`) — verbatim import, no adjustment.
- `tests/suite/00b_kernel.bas` (+ `.expected`) — the founding-divergence probe.
- `scripts/test-suite.ps1` — build the runner, run the manifest, byte-exact
  compare + exit-code check, with `-ProveFailure`.

Gates: **PRIMARY** — runner on verbatim `00_harness.bas` byte-exact, exit 0.
**HARDENING** — `00b_kernel.bas` proves `7\2`=int 3; `3+4` Kind stays vkInt;
`10/4`=vkDouble 2.5; an int% boundary `+` returns a catchable error result (not an
exception, not a silent Double); `ok? = 2 > 1 : assert_true(ok?)` proves
comparison is a usable bool value (reclassified-positive 05). **PROOF-OF-FAILURE**
— corrupting one expected value makes the runner report a failure and exit
non-zero; corrupting one opcode literal fires the numbering assertion; both shown
`-ProveFailure` style before a clean PASS.

## Rejected approaches (traps the council refuted)

- **"All 45 + 15 green" as the phase-1 DoD** — drags Data.DB/HttpClient/zip past
  the no-external-dependency line. Use a named subset; defer 23/32/33/34.
- **A `TAsmData{n,p,s}` (three-type) increment-1 cell** — every stack/pool/handler/
  marshalling consumer gets rewritten when int% lands. Freeze five kinds now.
- **Types-first with first oracle contact at step 9** — big-bang integration at
  the end; the "frozen" cell thaws once the corpus runs. Vertical slice first.
- **Freezing a full opcode catalogue up front** — the catalogue is
  codegen-determined; only the encoding discipline is frozen early.
- **Importing the negative suite verbatim with 05/07 as rejections** — re-ports
  the rejected Plan9Basic language and enshrines it in a guard. 05 → positive;
  07 → owner decision.
- **A `.pbc` format-version-byte check in increment 1** — decisions.md defers the
  packer; increment 1 runs in memory with no loaded stream. Replaced by an
  in-code append-only-numbering assertion.
- **A full up-front 45-file triage** — highest-uncertainty non-code task,
  unverifiable until the engine exists. Kept as a rule set + lazy per-file triage.
- **Batching all 15 negatives into a final hardening step** — verify each at the
  step that builds its feature, asserting the reason; final step is regression
  only.

## Open questions — owner decisions (PENDING)

These are the "cheap now, expensive later" forks the council surfaced. Freezing
them shapes increment 1 (the alphabet and lexer) and steps 3/8.

1. **Signature separator** — `:` (decisions.md's own choice) or `|`. Wrinkle: if
   `:` is also the BASIC statement separator (suite file 44), the lexer must keep
   registration-time `:` (Pascal) distinct from source `:`. *(They never collide
   in increment 1; the registry `:` is parsed in Pascal, not source.)*
2. **String-escape rule**, now that `\` is integer division — embedded quote as
   doubled `""`, a new escape character, or no in-literal escapes? Governs the
   lexer's literal slicer and every string literal in the suite.
3. **`s$[[n]]` character indexing under UTF-8** — base-1 by **byte** or by
   **codepoint**? Pins the entire string library and every multibyte assertion.
4. **Does `bool` get its own signature type-code `?`** (distinct overloads), or
   fold into the numeric family `n` the way int% does? Freezing the alphabet now
   is cheap. *(This also decides negative 07: if bool is distinct and does not
   widen to numeric, `x = true` on a numeric `x` is a type-mismatch rejection —
   07 stays negative for a NEW, documented reason.)*
5. **too-many-globals cap** (negative 01) — reuse Plan9Basic's `13_global_limit`
   value or choose a new one, and enforce at compile or run time? Needed before
   step 5.
