# Phosphor BASIC — phase-1 roadmap (adversarially vetted)

> **STATUS 2026-09-02 — the FULL Plan9Basic oracle is met, not just the phase-1 subset.**
> Every in-scope `tests/suite` file (00–44, the four external-dep deferrals 23/32/33/34
> included) has a Phosphor equivalent that is byte-exact green on Windows AND the Linux
> VM; the negative suite is 02–19 (Plan9Basic parity), all rejecting for their own
> diagnostic; nine opt-in packages are green. Out of scope by nature (Delphi/FMX): the
> `tests/gui` corpus (answered via Lazarus LCL in phase 2), the `Demos` games, and
> `18_examples_catalog` (Plan9Basic's own website plumbing). This was reached by an
> autonomous builder+critic **gauntlet loop** (see [dev-agent-playbook.md](dev-agent-playbook.md),
> whose retrospective log is the round-by-round record) — 12 rounds, no human fix. The
> phase-1 plan below is kept as the historical record of how the engine was founded.

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

Reconcile the semantic reversions (strict boolean, base-1, 05/07 kept as
type-mismatch rejections, `#`→`@`, `?>`/`?<`→`max`/`min`) as a **rule set before
parser semantics land**,
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
   **Gate:** rules in docs; negatives 05/07 kept as rejections with their decided
   reason (bool → numeric var is a type-mismatch; see step 3 and decisions.md);
   the phase-1 subset and deferred-library list referenced by the runner manifest.
   **Deferral cost:** without it, a failing oracle file pulls the parser toward
   the exact semantics decisions.md rejects, and a negative-suite test then
   *defends* the wrong behaviour.

3. **Variables + boolean operators + inline IF + strict-boolean conditions.**
   *(DONE 2026-09-01.)* Variables typed by suffix (run-time store type-check),
   `and`/`or`/`not`, `true`/`false` literals, and inline `if <cond> then <stmt>`.
   Arithmetic/promotion/overflow were already the kernel's (increment 1). Strict
   boolean is structural: a bare value leaves the parser's "produced-bool" flag
   false and a condition rejects it. `tests/suite/01_language_core.bas` (32
   asserts) is byte-exact green; negatives 05/07 (bool → numeric var: type
   mismatch) and 06/08 (bare value as condition) reject for the intended reason.
   Correction to the sketch: bool is distinct and does not widen, so 05/07 stay
   **rejections**, not positives — see [decisions.md](decisions.md).

4. **Control flow.** *(DONE 2026-09-01.)* Block + inline IF/ELSE/ENDIF (nested),
   WHILE/ENDWHILE, DO WHILE/LOOP, REPEAT/UNTIL, FOR/NEXT (+STEP, nested),
   BREAK/CONTINUE (per innermost loop), SELECT CASE/CASE ELSE/ENDSELECT, and
   GOTO/GOSUB/RETURN/END with numeric line labels (forward refs resolved after
   parse). Compiled to jumps with backpatching; a GOSUB return stack in the VM.
   `tests/suite/02_control_flow.bas` (19 asserts) byte-exact green. Original
   step-4 sketch below (ELSEIF and the negatives are folded in as features land):

   IF/ELSEIF/ELSE,
   WHILE, DO/LOOP, REPEAT/UNTIL, FOR/NEXT, SELECT CASE, jump/label backpatching.
   Negatives 06/08 reject *for the strict-boolean reason*; 11 (spaced compound
   op) rejects.
   **Gate:** `01_language_core` + `02_control_flow` + inline-else + elseif green;
   06/08 reject with the strict-boolean diagnostic; a jump-backpatch nesting probe
   passes.

5. **User functions.** *(DONE 2026-09-01 — functions; global cap deferred.)*
   `function name(params) [local ...] ... endfunction`, `return <expr>`,
   recursion, per-call frames (params + locals isolated from globals: a name in
   the local list is a frame slot, any other name is a global). Calls resolve to
   a user function first, else the library registry, so forward references work.
   `tests/suite/03a_functions.bas` (18 asserts — the function subset of
   03_functions) is byte-exact green. Full `03_functions.bas` waits on
   arrays/handles (`func/pointer-return`) and the string lib `stri$`
   (`func/mixed-args`), steps 6-8. The global cap (negative 01 / 13_global_limit)
   is deferred with those files; its value is Claude/council's to decide.
   **Original gate:** `03_functions` green; negative 01 rejects for the intended
   reason; a recursion/frame-teardown probe shows no local leakage.

6. **DATA/READ/RESTORE.** *(DONE 2026-09-01.)* `data <consts>` collected into a
   source-order pool; `read <var>[, ...]` reads the next item and advances a data
   pointer; `restore` rewinds. `tests/suite/05_data_read.bas` (7 asserts) green.
   Arrays are split into their own step (6b) because they need handles.

6b. **Arrays (with handles).** *(DONE 2026-09-01.)* Built the handle registry
   (`PhosphorHandles`: 1-based Int64 ids, `IsHandle` validation, `ResetHandles`
   per run) and `TPhosphorArray` (N-dim, 1-based, kind = numeric/string/pointer),
   plus the array library (`PhosphorArrayLib`: dim@/sdim@/pdim@, ndims/lbound/
   ubound/arraysize/arraytype/arraytypename$, narr/sarr/parr set+get, and the
   generic `arr_get`/`arr_set` behind bracket sugar `a@[i]` / `a@[i] = x`; lexer
   gained `[` `]`). The engine registers built-in libraries and resets handles
   each Run. `tests/suite/04_arrays.bas` (import with `#`→`@`, 28 asserts) green.
   The char index `s$[[n]]` (string, by codepoint) rides with the string lib
   (step 8). The handle registry is also the prereq for step 7's dict/stringlist.

7. **Handle libraries + error-state contract.** *(DONE 2026-09-01.)* Also
   reorganized the function packages into `engine/libs/`
   (like Plan9Basic's `engine/Libs`), integrated only through the registry.
   `PhosphorDictLib` (dict@/sdict@/pdict@ + set/get/getdef/count/haskey/remove/
   clear/typename) and `08_dict.bas` (24 asserts) green. Fabricated-handle
   negatives 02/03/04 reject *for the library's recorded reason* ("not a valid
   array/dictionary handle") via `pointer@` (fabricate) + `arr_free`. `print`
   gained `;`-separated items. **Stringlist** (`PhosphorStrListLib`: strings@ +
   add/count/strings$/indexof/insert/delete/sort/exchange/clear/text/values/
   indexofname/commatext) is base-1 (reference is 0-based; imported with +1 and
   indexof-absent = 0); `10_strlist.bas` (27 asserts) green; negatives 09/10
   reject "not a valid string list handle". `chr$` started `PhosphorStrLib`.
   `ON ERROR` (the language-level handler) is a later step.

8. **String + numeric libraries.** *(DONE 2026-09-01.)*
   `PhosphorNumLib`: abs/sqr(=sqrt)/sgn/min/max/round/fix/cint/frac/log10/log2/ln/
   exp/trig+inverse/degtorad/radtodeg/randomize/rnd/isnan/isinfinite —
   `07_numbers.bas` (38) green. `PhosphorStrLib`: ucase$/lcase$/len/left$/right$/
   trim family/reverse$/asc/chr$/hex$/bin$/oct$/val/stri$/space$/string$/
   mulstring$/replacestr$/replacetext$/countstr/containsstr/starts*/ends*/
   isnumeric/isalpha/count/word$/wordcount/instr/instrrev — codepoint-aware
   (len/left$/right$/reverse$/asc), `instr` 1-based (0 absent). String index
   sugar `s$[n]` (line) and `s$[[n]]` (character, base-1 by codepoint) added to
   the lexer/compiler. `06_strings.bas` (base-1 adjusted, 62) green. `stri$`
   unlocked the FULL `03_functions.bas` (21, imported #→@) — replaces the 03a
   subset. 12 suite files + 9 negatives green.

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

**Status (2026-08-31): DONE — both gates green.** The pipeline (lexer → compiler
→ five-kind stack VM → registry with int%→n widening → ported assert package →
runner) runs `tests/suite/00_harness.bas` (13 asserts) and the founding-
divergence probe `tests/suite/00b_kernel.bas` (8 asserts) byte-exact via
`scripts/test-suite.ps1`. The opcode-numbering assertion was seen firing on a
corrupted literal, and `-ProveFailure` was seen catching a corrupted expectation.
One scoped deviation from the sketch below: comparison-as-value is proven with
`assert_true(2 > 1)` through a distinct `?` bool overload (kept variables and the
statement `:` out of increment 1 — they are step 3); and the alphabet gained a
`%` code so `assert_int` proves int-ness by dispatch.

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
exception, not a silent Double); `assert_true(2 > 1)` through a `?` bool overload
proves comparison flows as a usable bool value. **PROOF-OF-FAILURE**
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

## Open questions — owner decisions

The "cheap now, expensive later" forks the council surfaced. Freezing them shapes
increment 1 (the alphabet and lexer) and steps 3/8.

RESOLVED 2026-08-31 (see [decisions.md](decisions.md), "Resolved specifics"):

1. **Signature separator** — `:`. ✔
2. **String-escape rule** — doubled quote `""`; no escape character. ✔
3. **`s$[[n]]` character indexing under UTF-8** — base-1 by **codepoint**. ✔
4. **`bool` signature type-code** — distinct `?`, no widening to numeric; so
   `x = true` on a numeric `x` is a type-mismatch and negative 07 stays a
   rejection for that new reason. ✔

STILL PENDING (needed before its step, not before increment 1):

5. **too-many-globals cap** (negative 01) — reuse Plan9Basic's `13_global_limit`
   value or choose a new one, and enforce at compile or run time? Needed before
   step 5.
