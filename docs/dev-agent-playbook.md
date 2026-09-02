# Phosphor development-agent playbook

The instructions every builder/critic agent working on Phosphor receives. It is the
distilled, hard-won knowledge of the phases already shipped — written so a fresh agent
does **not** rediscover a solved problem, and so the project can advance without a
human in the loop. It is **living**: after each gauntlet round a retrospective critic
appends what the round taught (see the last section). Treat every rule here as binding
unless a newer rule supersedes it.

Provenance: the "why" behind most rules is a real defect this project hit. Where a rule
cost a human turn to fix, that is called out — those are the ones that most needed
turning into an instruction.

---

## 0. The prime directive — verify against reality

Nothing is "done" on a claim. Every increment is proven against a running system on
**both** operating systems before it is called complete:

- **Build clean, from scratch.** `fpc -B -vewn` (rebuild all, warnings+notes as
  surfaced) with **zero** warnings and **zero** notes. A note is a defect until proven
  cosmetic. Never silence a warning by suppressing it; fix the cause.
- **Byte-exact tests green.** The suite compares output to a committed golden, byte for
  byte. A test that "looks right" is not green; the bytes match or it fails.
- **Both OSes, every time.** Green on Windows is **not** proof. Cross-verify on the
  Linux VM (`ssh -i ~/.ssh/phosphor_vm andre@192.168.15.14`, `cd ~/Phosphor && git pull
  && bash scripts/<the .sh>`). Several defects this project shipped were Windows-green /
  Linux-broken (SIGPIPE, OpenSSL-3 soname, cert generation). The VM is the second
  reality, not a formality.
- **See the failure.** `-ProveFailure` (or the equivalent) must be seen catching a
  deliberately corrupted expectation, so you know the harness can actually fail.
- **Boundary intact.** The boundary check (engine may not reach a host/GUI unit) must
  still pass. The engine stays host-agnostic; host concerns live in `host/`.
- **No stray files, clean tree.** `git status` shows only intended changes; build
  artifacts stay ignored.
- **Commit + push as AndreMurtaX**, `Co-Authored-By: Claude Opus 4.8`. Update docs and
  memory. A green-but-uncommitted increment is not shipped.

If any of these cannot be met, you are **blocked** — report the blocker precisely; do
not lower the bar.

## 1. This is NOT a port — Plan9Basic is Delphi/FMX

Plan9Basic is Delphi + **FireMonkey (FMX)**. FMX UI, animation, sound, and game
rendering have **no direct Free Pascal peer**; Lazarus uses LCL, a different framework.
So:

- **Port what is portable** (pure language, pure-RTL libraries) and match the oracle
  **byte-exact**.
- Where Plan9Basic leans on Delphi/FMX, rebuild to **functional equivalence** on
  Lazarus + FPC — the critic judges *correctness*, not byte-identity, for those.
- **Improve on the reference confidently** where it has an artifact or a wart. Phosphor
  is a spiritual successor, free to be better (e.g. HTTP multi-address fallback beyond
  FPC's single-A-record socket; a real cert-verification default where FPC ships none).
- Read the reference's **actual source/behavior** before porting a file — never a hunch.
  ("IPv6→IPv4 fallback" was a wrong diagnosis that cost a human turn: FPC's socket layer
  is IPv4-only, so the real gap was *single A-record*. Diagnose against the code.)

## 2. Architecture invariants (do not violate)

- **Engine is host-agnostic and dependency-free.** `engine/` may not use `crt`, `lcl`,
  `forms`, `windows`, `unix`, `baseunix`, sockets, `Data.DB`, etc. Output leaves through
  **one seam**: `OnOutput`. Input/terminal/GUI/network are host concerns.
- **Libraries plug in through the `:`-signature registry.** A function is
  `Reg.Add('name:sigcodes', @fn)`; VM-aware ones use `AddHost` and cast `AVM` to
  `TPhosphorVM`. Type codes: `n` numeric (int%|double), `$` string, `@` handle, `?`
  bool, `nn`/`$$`/… for arity. Read a numeric arg with `AsDouble(Args[i])` (handles
  int%↔double); a zero-arg fn is `'name:'`.
- **Test-only stand-ins belong to the test runner, not the shipped engine.** A probe
  class / helper used only by an oracle file goes in `tests/PhosphorTestLib.pas` (which
  the runner registers), never in an engine `engine/libs/*` unit — the console/host
  binaries must not ship a test artifact. **`Reg.Add` overwrites by signature**, so if
  both the engine and the runner register the same name the later one silently shadows
  the earlier — keep exactly one source.
- **External integrations are opt-in HOST packages** under `host/packages/`, registered
  by a host that wants them — never in the engine. Each package = a unit + a byte-exact
  `tests/packages/NN_*.bas` + a manifest line; **library-gate** it (skip cleanly) where
  its runtime dep is absent; give it its **own server-standing runner** when it must be
  tested against a live peer (see http/https). This is the template for archive, http,
  sqlite, crt — and anything new.
- **Errors are values, not exceptions**, inside the engine. `print` emits no newline;
  `println` does (opPrint vs opPrintLn) — load-bearing for CRT and for exact output.
- **`ValAdd` concatenates when either operand is a string**, so a string-element `+=`
  (and any string `+=`) works through the generic `opAdd` compound path — no special
  string-append opcode is needed for it.
- **An undeclared variable used inside a function resolves to a GLOBAL** (the compiler's
  `LocalIndex` returns −1 → `VarIndex`); only names in the `local` list are frame slots.
  This is how an oracle probe like `calls` shared between a helper function and main
  works — do not "fix" it by auto-declaring locals.
- **Bracket-sugar `arr_get`/`arr_set` signatures are enumerated per arity** (up to 3
  indices today: `arr_get:@n/@nn/@nnn`, `arr_set` with 1/2/3 indices × num/str/handle
  value). A 4th+ index is one registry line per arity — the variadic impls
  (`t_arr_get`/`t_arr_set`) already handle any arity; only the signature strings gate it.

## 3. FPC / Lazarus reality (specific traps, already paid for)

- **Windows `-Fu` paths need backslashes**; forward-slash unit paths fail. Bash loops
  with `$var` + Windows backslash paths mangle expansion — prefer explicit inline `fpc`
  commands with a `S='C:\Dev\Phosphor'` prefix and `"-Fu$S\\engine"`.
- **`TInetSocket` (FPC 3.2.2) is IPv4-only and single-address** — it connects to the
  first A record only. Multi-homed hosts need a resolve-all-A + try-each fallback
  (`THostResolver` exposes `AddressCount`/`Addresses[i]`; `ConnectToServer` is virtual —
  subclass to pin the IP while keeping the URL's `Host:`).
- **OpenSSL:** FPC 3.2.2's loader never tries `libssl.so.3` — teach it `.3`
  (`openssl.DLLVersions[High]:='.3'`, `{$IFDEF UNIX}`). Its TLS handler **accepts any
  cert by default** (verification commented out) — turn on `VerifyPeerCert` + a CA
  bundle. Its in-process X.509 **generation is broken on OpenSSL 3** — ship a fixture
  cert, don't generate. A server writing to an aborted socket gets **SIGPIPE** (kills
  the process, exit 141) — `fpSignal(SIGPIPE, SignalHandler(SIG_IGN))` `{$IFDEF UNIX}`.
- **FPC's `crt` unit hangs on a non-interactive stdin** (spins even at init). Do terminal
  input with termios (Unix) / console API (Windows) directly, and **gate on `IsATTY` /
  `GetFileType==FILE_TYPE_CHAR`** so a piped stdin returns empty rather than blocking.
- **`TFPHTTPServer.Address`/`UseSSL`/`CertificateData` are protected** in `TFPHttpServer`
  — subclass and republish to set them. `TStringList.Text` appends a **platform-
  dependent** line ending (CRLF/LF) — a server must send exact bytes via a
  `ContentStream`, not `AResponse.Content`, or byte-exact breaks across OSes.
- Libraries with a shared unit path clash on the program `.ppu` only, not the engine
  `.ppu`s — separate `-FU` unit dirs per runner is safest.
- **`MSYS2_ARG_CONV_EXCL='*'`** when calling native tools whose args start with `/`
  (e.g. `openssl req -subj '/CN=...'`) so Git-Bash doesn't mangle them. Use `cygpath -m`
  for a Windows path with forward slashes that FPC will read.

## 4. Test & verification mechanics

- The **byte-exact test asserts return values**, so a pure function (e.g. a CRT function
  that returns an ANSI string) is fully testable through the assert library even when the
  runner discards `print`. Prefer this shape.
- **`phosphorpkgtest` discards `print`** — probe an unknown value by asserting it against
  a sentinel and reading the `got` in the FAIL line on stderr.
- **Real key input** was verified with a **pty** (`python3 pty.fork`, feed a byte, assert
  `getkey$` returns it) — use a pty when a TTY is genuinely required and a pipe is
  guarded out.
- Never let a test hang the suite: any interactive/terminal/network call must have a
  non-interactive fast path (empty/0), proven with `< /dev/null` and a `timeout`.
- **Every build script must SURFACE the `-vewn` output and FAIL on any warning/note** —
  never pipe the build to `/dev/null` and check only that the binary exists. A note can
  hide in a **host package** (e.g. a CRT unit) that the engine's own suite build never
  compiles, and it will not surface until someone reads a raw Linux build. The package
  and console-host build scripts enforce this (`strict_build` / `Assert-CleanBuild`);
  the check greps `warning|note:|error|fatal` minus `Compiling|Linking`. "Green on the
  suite" is not "clean everywhere" — run the package + console builds too, per OS.
- **`fpRead` (BaseUnix) is marked `inline` and FPC often declines to inline it**, which
  `-vewn` reports as a note. Call **`FileRead`** (SysUtils) instead — a plain function
  wrapping the same read — so the note stays inside the RTL, not your unit.

## 5. Gauntlet discipline (builder vs critic)

- **Builder and critic are separate agents with fresh context.** The critic must not know
  how hard the builder tried.
- **The critic is harsh and binary.** It obtains Plan9Basic's *real* behavior (run
  `plan9basic.exe` on the file, or read its committed expected output), puts ours beside
  it blind, and says which is correct — never a score out of 10, which drifts upward.
- **The exit is winning the comparison**, not a round count. If ours does not match (or,
  for a Delphi-only feature, is not functionally equivalent and clean), it loops.
- **Proceed continuously.** A finished file is a commit, not a checkpoint to stop at.
  Only halt when blocked or when the whole corpus meets the bar. (Stopping at phase ends
  cost human turns — do not.)

---

## Retrospective log (appended each round)

Newest first. Each entry: what broke or was missed, and the rule it produced. A
"needed-a-human" entry is a case the agents could not resolve autonomously — its rule
exists so they can next time.

- **2026-09-02 · round 4 · `19_language_contract` (functional-equivalence adaptation).**
  Green both OSes, 16 asserts, no human needed — the first *adaptation* rather than a
  byte-exact port. Plan9Basic indexes strings from 0; Phosphor from 1 (a deliberate
  divergence). The builder confirmed Phosphor's base against `06_strings`/`46`/`47`,
  renamed the "…-from-zero" cases to "…-from-one", shifted every char-index constant
  +1, and — the good part — ran a **see-check-fail probe** proving the oracle's base-0
  indices genuinely MISS under Phosphor (`s$[0]`→"", quote at `[[9]]` not `[[8]]`), so
  the assertions pass because the semantics is right, not because a constant was fudged.
  This is the template for every "not a port" file: adapt to Phosphor's documented
  semantics, then prove the divergence is exercised, don't assume it.
- **2026-09-02 · round 3 · `14_handle_registry` (probe classes + registry rules).**
  Green both OSes, faithful 16-assert port, no human needed. Reused the existing
  `PhosphorHandles` validation path (no second path, no weakening): `IsHandle` rejects a
  fabricated/nil/large `pointer@(n)`; `HandleObj(h) is TProbeA` discriminates class;
  `FreeHandle` revokes so a stale id is refused; a runner-side counter does the
  accounting (the registry keeps no live total, which is fine). Lesson (§2): a
  **pre-existing engine-side probe** in `PhosphorPlatformLib` that `24_platform_std`
  used had to move to the runner — a test stand-in must not ship in the StdLib, and
  because `Reg.Add` overwrites by signature, keeping both would have silently shadowed
  one. One source, on the runner side.
- **2026-09-02 · hardening · a latent note the process hid.** Round 2's builder flagged
  a `FpRead not inlined` note on the *Linux* build of `PhosphorCrtLib` — pre-existing,
  from the keyboard-input work, and it had escaped every prior "green" run. Root cause
  was a **verification gap, not just the note**: `test-packages.{ps1,sh}` and `build.sh`
  piped the `-vewn` build to `/dev/null` and only checked the binary existed, so a note
  in a host package (which the engine suite never compiles) was invisible. Fixed both:
  `fpRead`→`FileRead` (note gone), and the build scripts now capture the build and FAIL
  on any warning/note (§4). This is the retrospective doing its job — the gauntlet's own
  discipline surfaced a problem the earlier phases missed, and the fix is a sharper
  process, not just a patched line.
- **2026-09-02 · round 2 · `15_breakpoint_degrade` (TRACE + BREAKPOINT degrade
  headlessly).** Green both OSes, faithful 5-assert port, no human needed. Added
  `opTrace=40`/`opBreakpoint=41` (append-only, `VerifyOpcodeNumbering` extended),
  the two statement keywords, and a nil-by-default `OnBreakpoint` host seam wired
  like `OnOutput`. Core property proven: BREAKPOINT is report-and-continue, never
  a wait — with no seam installed it is a pure stack-balancing no-op, so a headless
  run cannot deadlock. Two traps folded in: (1) a procedural type whose parameter
  is `array of TValue` (`TPhosphorBreakpointProc`) must be declared AFTER `TValue`
  in the same `type` block — Pascal forbids the forward reference, unlike a pointer
  or class type; (2) the degrade seam stays engine-side as a `procedure-of-object`,
  so the boundary check passes untouched — a debug pause is a host concern, and the
  engine only ever *reports*. New statement keywords go in BOTH `ParseStatement`
  dispatch AND `IsReservedWord` (so `breakpoint:`/`trace:` are never read as a
  label), matching the hard-keyword pattern of `print`/`read`/`data`.
- **2026-09-02 · round 1 · `44_syntax_compound_arrays` (multi-dim array bracket).**
  Green both OSes, faithful 31-assert port, critic passed blind. No human needed — the
  builder scoped and shipped it from the spec. Lessons folded into §2: `ValAdd`
  string-concat covers string-element `+=`; undeclared-in-function → global (the shared
  probe counter relies on it); the per-arity bracket-signature enumeration. Nothing
  needed a human this round; the process rules held.
- **2026-09-02 · seed.** The rules above were distilled from Phases 1–3 and the opt-in
  packages. Notable needed-a-human cases turned into rules: the IPv6 misdiagnosis (§1,
  "diagnose against the code"); repeated phase-end checkpointing (§5, "proceed
  continuously"). Notable fixed→guardrail cases: crt-unit hang (§3), OpenSSL-3 soname &
  cert & SIGPIPE (§3), platform line-ending in TLS server (§3).
