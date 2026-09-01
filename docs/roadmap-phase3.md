# Phosphor BASIC — phase-3 roadmap (robust & deployable)

Phase 1 built the engine and its libraries; phase 2 gave it a GUI, a second
consumer that never told the engine it existed. Phase 3 turns a *working
interpreter* into something you can **embed safely** and **ship as one file**.

How this plan was reasoned (the phase-1 method, applied): three sequencing
philosophies were argued against each other — *deployment-first* (ship the `.pbc`
packer now, it is already signposted), *integration-first* (sqlite/http/zip make
real apps), *robustness-first* (catchable errors and limits make the engine safe
to embed) — then each was stress-tested and the survivors merged. This file is the
plan of record; it can be re-run through the adversarial council
(`.claude/workflows/adversarial-council.js`) to stress-test it further.

## Verdict

Phase 3 = **make Phosphor robust to run and safe to embed, then deployable** — in
that order:

1. a **catchable language-level error model** (`ON ERROR`), because a runtime
   error still aborts the whole program, and because it *adds opcodes* — so it
   must land **before** the on-disk format is frozen;
2. **execution limits** (a step budget, a timeout, an output cap) so a host can
   run **untrusted** scripts without them hanging or flooding it;
3. the **documented embedding API** and a **third demo host** (neither console nor
   GUI) that proves the "embeddable" promise the whole architecture rests on;
4. **then** the on-disk bytecode **`.pbc`** (its format already frozen in
   [decisions.md](decisions.md)) and its **self-extracting deployment stub**, now
   that the opcode set has stopped moving;
5. external integrations (sqlite, http, zip, base64) as **opt-in host packages**,
   never in the engine — the embedder's choice, the way the GUI libs are.

## The central hazard to pin now

The on-disk `.pbc` freezes the opcode numbers. `ON ERROR` and the limits **add
opcodes** (set/clear-handler, resume; possibly a step-check). Freezing the format
first (the deployment-first philosophy) would force a format-version bump and a
re-test the moment those land — the exact silent-format-break the opcode
discipline exists to prevent, paid twice. So every opcode-adding language change
happens **before** step 4. The format is designed to tolerate later additions (an
append-only numbering + a version byte checked-and-refused-out-loud), but the
cheap move is to stabilize the language first and freeze once.

A second hazard, from the integration-first philosophy: pulling `Data.DB` /
sockets / zip **into the engine** would break the one rule the boundary check
guards. Those belong in `host/`, opt-in, exactly where the LCL lives — so the
engine stays the same dependency-free library it is today.

## Sequence

Each step names its gate (exit criteria) and its cost of deferral. As in phases
1–2, verify against reality — byte-exact where output is deterministic, on Windows
**and** Linux — and keep the engine host-agnostic (the boundary check must pass).

1. **`ON ERROR` — catchable runtime errors.** *DONE (2026-09-01, commit bdc1b44).*
   `on error goto <label>` installs a handler, `on error goto 0` clears it; inside
   it `err()` / `errmsg$()` / `erl()` read the code / message / line, `err_clear()`
   resets them, `resume` retries the failing statement and `resume next` continues
   at the following one, and `error(msg$)` raises a catchable error. (Decided:
   `on error goto`, BASIC-idiomatic; a structured `try` can be sugar over it later.)
   Built with three opcodes (`opStmt` marks a clean statement boundary; `opSet
   ErrHandler`; `opResume`) and one `Fault()` funnel in the VM through which every
   runtime-error site now routes; `err`/`errmsg$`/`erl`/`err_clear` are host-aware
   (they read the VM through the callfunc seam) in `engine/libs/PhosphorErrLib`.
   A user-requested addition landed too: **`on error call func`** — on a fault, run
   `function func(code%, msg$)` and continue by its return value (0 resumes next,
   non-zero aborts), a callback form with no label/resume boilerplate (commit
   8126d31). **Gate met:** `tests/suite/49_on_error` (13 asserts — catch + resume
   next, resume retry, `error()`, `err_clear`, an error caught from a called
   function, and the call form) byte-exact green on Windows and Linux;
   `negative/13_resume_no_handler` rejects `resume` with no handler,
   `negative/14_on_error_call_abort` rejects a call-handler that returns non-zero;
   the full engine + GUI suites still green; `-B -vewn` clean. **Scope note:**
   `resume`/`resume next` target the failing statement in the handler's own frame;
   an error caught from a deeper called function should recover with `goto`, not
   resume — a later refinement can lift that.

2. **Execution limits — safe to embed untrusted scripts.** *DONE (2026-09-01,
   commit 98857df).* Three opt-in ceilings on `TPhosphorEngine`, `0` (the default)
   meaning unlimited and costing nothing: **MaxSteps** (an instruction budget --
   the answer to an infinite loop), **MaxOutputBytes** (total bytes through
   OnOutput), **TimeoutMs** (a wall-clock ceiling, checked every 4096 steps).
   Enforced in the VM dispatch loop and the output seam. A ceiling is **fatal by
   design** (the new `peLimit` code): it aborts directly, *not* through the ON
   ERROR path, so a script cannot catch and escape its own limit. The **handle
   ceiling** is deferred (it needs registry cooperation). **Gate met:** because
   limits are a host-facing API (set from Pascal, not a `.bas`), they are tested
   with `tests/probe_limits.lpr` (5 checks: step/output/time bound their infinite
   cases, a normal script within the ceilings runs clean, and ON ERROR cannot
   escape a limit; `--fail` flips one). Both Pascal probes now auto-run in the
   suite runner -- which surfaced and fixed a stale check in the pre-existing
   `probe_value.lpr`. Byte-exact green on Windows and Linux. **Deferral cost, paid
   down:** the "embeddable" promise is now *safe* -- a host can run user-supplied
   scripts without risking a hang or a flood.

3. **The embedding API + a third host.** Stabilize and document the public
   surface — `Create`, `Registry.Add`/`AddHost`, `OnOutput`, an `OnInput` seam,
   `Run`/`CallUserFunc`, the error state, the limits — with host↔BASIC value
   marshalling helpers. Build a **third example host** that is neither console nor
   GUI: a minimal FPC program that embeds Phosphor as a *scripting layer* (a
   config/formula/macro evaluator), registers a couple of host functions, runs a
   user script and exchanges values back. Write `docs/embedding.md`.
   **Gate:** the embedding example builds and runs on both OSes; the API is
   exercised by a test; the doc walks a host author through registering a function
   and running a script with limits.
   **Deferral cost:** "embeddable" stays aspirational — demonstrated only by the
   two built-in hosts, never by an outside embedder.

4. **The `.pbc` on-disk bytecode.** With the opcode set stable, implement the
   frozen format (decisions.md, "On-disk bytecode"): serialize a compiled
   `TProgram` — opcodes (explicit numbers), the constant pool, the var/func tables,
   the data pool — to a little-endian `.pbc`, its **format-version byte checked and
   refused out loud** on load. A `phosphorc` front-end compiles `.bas` → `.pbc`;
   the engine loads a `.pbc` and runs it without recompiling.
   **Gate:** a `.bas` compiled to `.pbc`, loaded and run, is **byte-identical** in
   output to running the `.bas` directly; a corrupted or wrong-version `.pbc` is
   refused with a clear error (seen failing before it is trusted); the same `.pbc`
   runs on Windows and Linux (Double + endianness are fixed).
   **Deferral cost:** no standalone distribution — but this is convenience over the
   already-working in-memory path, hence sequenced after robustness.

5. **Self-extracting deployment.** A per-platform stub that appends a `.pbc`
   payload to a runner binary, so `phosphorpack app.bas → app` yields a standalone
   executable that reads its own tail and runs the embedded bytecode — no Phosphor
   install on the target. The docs state the **antivirus/dropper caveat plainly**
   (a binary that executes its own appended payload is the classic shape heuristic
   AV flags; decisions.md records this up front).
   **Gate:** a packed executable runs on a clean machine with the same output; the
   stub is per-platform but the `.pbc` it carries is not; the AV caveat is
   documented.
   **Deferral cost:** the "one file to ship" story; last because it depends on the
   format and is the most deployment-fiddly.

**Parallel / optional — integration libraries as opt-in host packages.** sqlite,
http, zip, base64 (the phase-1 deferrals `23/32/33/34` + `11_encoding`), each an
**opt-in package under `host/`** that the embedder links if it wants it, exactly
like the GUI libs — the engine stays dependency-free and the boundary check keeps
passing. These are breadth, not a gate; they can land any time, in any order.

## Rejected approaches (the traps the reasoning refuted)

- **Packer-first.** Freezing the on-disk opcode format before `ON ERROR` (which
  adds opcodes) forces a version bump and a re-test the moment it lands, and the
  packer is convenience over the working in-memory path. Stabilize the
  opcode-touching language changes first; freeze once.
- **External libraries in the engine.** sqlite/sockets/zip in `engine/` break the
  one rule the boundary check guards. They are host-appropriate — opt-in packages
  in `host/`, the embedder's choice, where the LCL already lives.
- **A language redesign (new types, a module system).** Gold-plating. The
  five-kind cell, base-1, and the current syntax are proven against the oracle;
  `ON ERROR` is the one genuine robustness gap. A module/import system is
  speculative until a real multi-file program needs it.
- **`try/catch` instead of `on error goto`.** (An owner decision, noted in step 1.)
  `on error goto`/`resume`/`err()` is BASIC-idiomatic and matches the lineage; a
  structured `try` can be added later as sugar over the same mechanism.
- **Skipping the format-version refusal to save a byte.** The whole point of the
  frozen decisions is that a `.pbc` from a different build is refused *out loud*,
  never executed as the wrong opcodes. Non-negotiable in step 4.

## Open questions — owner decisions

1. **Error-handler surface** — `on error goto` + `err()`/`errmsg$()`/`erl()` +
   `resume`/`resume next`, or a structured `try/catch`? (Lean: `on error goto`.)
2. **Which limits ship first** — step budget, wall-clock, output cap, handle
   ceiling — and are they **off by default** (unbounded, as today) or set to a sane
   cap that an embedder can raise?
3. **`.pbc` specifics** — the magic/extension, and whether the file freezes a
   function table or keeps today's late-bound resolution (functions resolved by
   name against whatever packages the loading host registered).
4. **Phase boundary** — is deployment (steps 4–5) part of phase 3, or does phase 3
   end at "robust & embeddable" (steps 1–3) and deployment become phase 4? (This
   file scopes 1–5 as phase 3; splitting is cheap if 1–3 want to ship first.)
