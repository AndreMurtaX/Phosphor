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

3. **The embedding API + a third host.** *DONE (2026-09-01).* The engine gained the
   embedding lifecycle a scripting host needs: **`Prepare(source)`** compiles and
   runs a script's top level once and keeps the VM **alive** (globals and handles
   intact), and **`CallFunction(name, args): TValue`** then calls the routines it
   defined, as often as the host likes, over that live state; `Finish` (and the
   destructor) discard it. `Run` stays the one-shot form; both share the compile /
   configure helpers. The **third host**,
   [`host/embed/phosphorembed.lpr`](../host/embed/phosphorembed.lpr), is neither
   console nor GUI: it registers a host function, prepares a script, and calls its
   routines from Pascal — exchanging values, reading back errors, under a step
   limit. **Gate met:** the embed host builds and runs on both OSes and is
   auto-run in the suite (`ok:/fail:`, 6 checks, `--fail` flips one), alongside the
   two Pascal probes; [`docs/embedding.md`](embedding.md) walks a host author
   through the whole surface with that file as the worked example. `-B -vewn` clean.
   **Deferral cost, paid down:** "embeddable" is now demonstrated by an outside
   embedder, not just the two built-in hosts.

4. **The `.pbc` on-disk bytecode.** *DONE (2026-09-01).* `engine/PhosphorBytecode`
   serializes a compiled `TProgram` — opcodes (explicit numbers), the constant
   pool, the var/func tables, the data pool — to an **explicitly little-endian**
   stream (NtoLE/LEToN, a fixed 8-byte Double), behind a header of the magic
   `PBC`, a **format-version byte** and the highest opcode number; a bad magic, an
   unsupported version, an opcode-set mismatch or corruption is **refused out
   loud**, never run as the wrong opcodes. `phosphor compile a.bas a.pbc` writes
   one (front-end in the console host); `phosphor a.pbc` detects the magic and runs
   it via the new `TPhosphorEngine.RunBytecode(stream)`, no lexer/compiler
   involved. **Gate met:** `tests/probe_bytecode` compiles a rich program
   (data/read/func/for/strings) and a simple one to bytecode, runs the bytecode and
   asserts its output is **byte-identical** to running the source, then corrupts the
   version byte and the magic and asserts each is refused with a message (4 checks;
   `--fail` flips one); auto-run in the suite; `phosphor compile`/run verified
   end-to-end. Byte-exact green on Windows and Linux; the same `.pbc` runs on both
   (Double + endianness fixed). `-B -vewn` clean.

5. **Self-extracting deployment.** *DONE (2026-09-01).* `phosphor pack app.bas
   app.exe` compiles the script and appends the `.pbc` payload to a copy of the
   `phosphor` binary (the *stub*) behind a fixed little-endian trailer
   (payload-offset, size, an FNV checksum, and the magic `PHOSPBC1`, at the very
   end — PE and ELF both ignore trailing bytes). At startup the stub reads its own
   tail (`GetModuleFileNameW` / `/proc/self/exe`); if the trailer's magic is there
   and the checksum matches, it runs the embedded bytecode and ignores its CLI
   arguments — so the SAME `phosphor` binary is the CLI tool bare and a standalone
   app once packed (on Unix the packed file is `chmod +x`'d). The AV/dropper caveat
   is stated plainly in [decisions.md](decisions.md) ("On-disk bytecode"). **Gate
   met:** `test.{ps1,sh}` add a third path — pack `hello.bas`, run the standalone
   executable with no arguments, byte-compare to the same golden as the `--out` and
   stdout paths (all three flip under `-ProveFailure`); verified on Windows and
   Linux. `-B -vewn` clean.

## Status — PHASE 3 STEPS 1–5 COMPLETE (2026-09-01)

Phosphor is now robust to run (catchable `ON ERROR`, in the label, function-call,
and `resume`/`resume next` forms), safe to embed untrusted scripts (fatal step /
time / output ceilings), documented and demonstrated as an embedding library (a
third host + `docs/embedding.md`), and deployable (the `.pbc` on-disk bytecode and
the self-extracting `pack`). External integrations (sqlite/http/zip/base64) remain
opt-in host packages for whenever they are wanted; the engine stays dependency-free.

**Parallel / optional — integration libraries as opt-in host packages.** *Started
(2026-09-01).* Each is an **opt-in package under `host/packages/`** that a host
registers if it wants it, exactly like the GUI libs — the engine stays
dependency-free and the boundary check keeps passing. **Landed:** `PhosphorBase64Lib`
(base64/hex, from FPC's fcl-base) and `PhosphorZipLib` (zip archives, from FPC's
paszlib) — both ship with the compiler, so no external runtime library, byte-exact
green on Windows and Linux. `PhosphorSqliteLib` (an in-memory/file SQLite database
via FPC's SQLdb driver: `sqlite_open@`/`exec`/`scalar$`/`scalar`/`query$`/`close`)
needs the SQLite runtime library, so it is **verified against reality where the
library is present** (byte-exact on the Linux VM, which has `libsqlite3.so`) and the
suite **skips it where it is absent** (Windows here has no `sqlite3.dll`) — the same
skip pattern the headless GUI suite uses for a display. All run through
`host/packages/phosphorpkgtest` + `scripts/test-packages.{ps1,sh}`
(`tests/packages/00_base64`, `01_zip`, `02_sqlite`). **Still out:** `http` — its
client ships with FPC (`fphttpclient`) but testing it needs a server / OpenSSL, so
it stays out until it can be verified against reality, not stubbed. These are
breadth, not a gate; they land any time.

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
