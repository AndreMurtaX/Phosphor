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

> **Amendment (2026-09-06) — that path is stale.** There is no `.claude/workflows/`
> directory in this checkout any more, so the file named above cannot be run. The
> council itself is not gone: it survives as an **agent skill invoked by name**
> (`adversarial-council`), outside the repository, which is why the checkout no
> longer carries a script for it. The sentence above is left as written because it
> is the dated record of how this plan was produced; only the way to re-run it
> changed.

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
   version byte and the magic and asserts each is refused with a message (6 checks
   today -- two body-corruption cases were added after this line was written, one
   flipping the first instruction's opcode byte and one its operand;
   `--fail` flips one); auto-run in the suite; `phosphor compile`/run verified
   end-to-end. Byte-exact green on Windows and Linux; the same `.pbc` runs on both
   (Double + endianness fixed). `-B -vewn` clean.

5. **Self-extracting deployment.** *DONE (2026-09-01).* `phosphor pack app.pbc
   app.exe` appends the payload to a copy of the
   `phosphor` binary (the *stub*) behind a fixed little-endian trailer
   (payload-offset, size, an FNV checksum, and the magic `PHOSPBC1`, at the very
   end) — **trailer bumped to `PHOSPBC2` on 2026-09-06**, adding a 32-bit flags
   word before the magic so `pack --no-console` can travel with the file; the
   magic IS the version, the reader accepts both and refuses anything else, and a
   packed file always carries the stub that made it (see README, "The console is
   kept by default — PE and ELF both ignore trailing bytes). At startup the stub reads its own
   tail (`GetModuleFileNameW` / `/proc/self/exe`); if the trailer's magic is there
   and the checksum matches, it runs the embedded bytecode and ignores its CLI
   arguments — so the SAME `phosphor` binary is the CLI tool bare and a standalone
   app once packed (on Unix the packed file is `chmod +x`'d). The AV/dropper caveat
   is stated plainly in [decisions.md](decisions.md) ("On-disk bytecode"). **Gate
   met:** `test.{ps1,sh}` add a third path — compile `hello.bas`, pack the `.pbc`
   (`pack` takes bytecode, not source, since 2026-09-06), run the standalone
   executable with no arguments, byte-compare to the same golden as the `--out` and
   stdout paths (all three flip under `-ProveFailure`); verified on Windows and
   Linux. `-B -vewn` clean.


6. **The filesystem ceiling — `SandboxRoot`.** *DONE (2026-09-06).* Step 2 claimed
   the engine was "safe to embed untrusted scripts" on the strength of three
   ceilings that all bound how **long** a script runs. None of them bounded **where
   it writes**, so a host that set all three still handed the script the whole
   filesystem — and on 2026-09-05 that gap was paid for outside this repository,
   when an unbounded run of a defective `dir_delete("")` walked the root of the
   current drive and erased the working trees of thirteen projects. The claim was
   the defect: a sentence in a plan said "safe" and nothing in the code was
   checking the half it did not mention.

   `engine/PhosphorSandbox.pas` is the missing ceiling, shaped like the other
   three: `TPhosphorEngine.SandboxRoot`, `''` by default, costing nothing when
   unset. With a root set, every path a script names — `file_*`, `dir_*`,
   `open … as #n`, the string-list and RAG loaders, and the `zip`/`gzip`/`base64`
   packages — is made absolute, has `.`/`..` collapsed and its symlinks followed,
   and must land inside the root or the call is refused. A refusal is a **value**
   (`0`, `""`, and `ioerror()`), not an exception, except `OPEN`, which has no
   return value and so fails the run catchably. With a root set the platform's
   scratch places (`temppath$`, `tempfilename$`, `homepath$`, `documentspath$`,
   `cfg_path$`) answer **inside** it, so a script that uses them runs unchanged
   and contained rather than failing on its first write; `sandboxroot$()` reports
   the root and nothing registered can change it. One rule holds with **no root at
   all**: an empty path or a bare filesystem root is never written to or deleted.

   **The part that is not the feature.** A rule enforced at every call site is a
   rule that rots one new function at a time, so `scripts/check-sandbox.py` is the
   real deliverable: it reads every routine in `engine/` and `host/packages/` that
   a script can reach, and fails the acceptance suite if one touches the
   filesystem without asking the gate — or carries a stale exemption. It found 20
   holes on its first run, including three the author had already convinced
   himself were covered. The hosts are deliberately outside its scope: a program
   reading the file named on its own command line is doing its job, before any
   script exists to bound.

   **Gate met:** `tests/probe_sandbox.lpr` (24 checks) is the proof, and its shape
   is the point — a guard whose job is to stop a deletion cannot be proven by
   attempting one on anything that matters, so the probe **builds its own victim
   tree** in the platform temp directory, outside the root it then sets, and
   asserts the tree is still standing afterwards. Seen failing: with rule 2
   disabled the probe reports 14 failures, and the tree it reports as destroyed is
   the one the probe itself created. `tests/suite/58_sandbox.bas` (27 assertions)
   pins the script-visible half and deliberately attempts **no deletion outside
   the root**. Every test runner (`phosphortest`, `phosphorguitest`,
   `phosphorpkgtest`, `phosphorhttptest`) now confines its script to the working
   directory with no flag to turn it off, and `phosphor --sandbox <dir>` offers the
   same to anyone running a script by hand. Byte-exact green on Windows and Linux;
   `-B -vewn` clean; `-ProveFailure` and `probe_sandbox --fail` both seen failing.

## Status — PHASE 3 STEPS 1–6 COMPLETE (2026-09-06)

Phosphor is now robust to run (catchable `ON ERROR`, in the label, function-call,
and `resume`/`resume next` forms), safe to embed untrusted scripts (fatal step /
time / output ceilings **and a filesystem root**), documented and demonstrated as
an embedding library (a third host + `docs/embedding.md`), and deployable (the
`.pbc` on-disk bytecode and the self-extracting `pack`). External integrations (sqlite/http/zip/base64) remain
opt-in host packages for whenever they are wanted; the engine stays dependency-free.

**Parallel / optional — integration libraries as opt-in host packages.** *CLOSED
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
skip pattern the headless GUI suite uses for a display. `PhosphorHttpLib` (an HTTP
client -- `http_get$`/`http_status`/`http_post$`, over FPC's `fphttpclient`) is
**verified against a real server on both OSes**: plain HTTP over loopback needs no
external library (only HTTPS would pull OpenSSL), so its own runner
`host/packages/phosphorhttptest` stands up a live `TFPHTTPServer` and the test drives
real requests at it -- no mocks, no network. It also **improves on the reference
socket layer**: FPC 3.2.2's `TInetSocket` connects only to a host's FIRST A record,
so one dead IP sinks the request even when the host's other IPs are healthy;
`PhosphorHttpLib` resolves ALL of a host's A records and tries each until one connects
(a `TFPHTTPClient` subclass pins the connect target while keeping the real hostname in
`Host:`). That fallback is proven deterministically -- the test server binds
`127.0.0.1` only and a test-only `http_get_via$` forces the candidate list, so
`"127.0.0.9,127.0.0.1"` must skip the dead address and reach the live one, no DNS or
real network involved. The `base64`/`zip`/`sqlite` tests run through `phosphorpkgtest`;
the `http` test through `phosphorhttptest`; all via `scripts/test-packages.{ps1,sh}`
(`tests/packages/00_base64`, `01_zip`, `02_sqlite`, `03_http`).

**Still out when this was written, and since resolved:** HTTPS **shipped** —
`http_verify_peer`, `http_ca_file$`, the URL scheme selecting TLS, and
`tests/packages/04_https` driving it against a loopback TLS server. IPv6 is still
out (FPC's socket layer is IPv4-only, so reaching an AAAA host would need a
hand-rolled `AF_INET6` connect) and is recorded in
[roadmap-net.md](roadmap-net.md), not dropped.

**Closure (2026-09-01).** Four packages shipped and are verified against reality on
both operating systems — `base64`, `zip`, and the multi-address-fallback `http` run
byte-exact on Windows and the Linux VM; `sqlite` runs byte-exact where its runtime
library is present (the VM) and is skipped where it is absent (this Windows box), the
same honest library-gate the GUI suite uses for a display. The engine never learned
any of them exist. The two deferrals are recorded, not stubbed, and the next one has a
plan of record: **[roadmap-net.md](roadmap-net.md)** — HTTPS chosen over IPv6, with
the reasoning and the step-by-step. This frame (a package + its own runner + a
byte-exact `tests/packages` file, library-gated when it needs a runtime dep, with its
own server-standing runner when it must be tested against a live peer) is the template
every future integration follows.

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

## Open questions — ALL FOUR ANSWERED (2026-09-01)

> Kept as the record of what was open and how it was settled, because a plan that
> deletes its questions cannot be audited. Each answer is the section above.
>
> 1. **Error-handler surface** → `on error goto` + `err()`/`errmsg$()`/`erl()` +
>    `resume`/`resume next`, plus `on error call fn`. No `try/catch`.
> 2. **Which limits ship** → `MaxSteps`, `MaxOutputBytes`, `TimeoutMs`, all **off
>    by default** (0 = unbounded), so an embedder opts in and pays nothing otherwise.
> 3. **`.pbc` specifics** → magic `PBC`, version 1, extension `.pbc`, and today's
>    **late-bound** resolution kept: functions resolve by name against whatever the
>    loading host registered, which is what lets one file run on hosts with
>    different packages. *(2026-09-06: the cost of that — a missing name surfacing
>    only when its line runs — is now paid at the two moments the host IS known.
>    `pack` REFUSES a payload naming a function this binary cannot provide, since
>    the executable it writes carries this binary as its stub and no other host
>    will load that payload; `compile --check` WARNS and carries on, because a name
>    this host lacks may be perfectly right for the host the file is meant for. The
>    compiler itself still has no registry, which is the point.)*
> 4. **Phase boundary** → deployment stayed inside phase 3; steps 1–5 all shipped
>    together, so the split was never needed.

### The questions as originally posed

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
