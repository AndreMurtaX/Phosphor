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
- **`ValAdd` concatenates when the LEFT operand is a string** (a string on the
  RIGHT of a number is a type mismatch the compiler refuses, not a silent
  concatenation -- see negative 17), so a string-element `+=`
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

## 2b. Pascal style: empty parens mark a CALL

**A parameterless call site carries `()`; a declaration does not.** Pascal lets a
parameterless function call look exactly like a variable read — `a := Pop;` mutates the
stack, `t := FLex.Cur;` is a function, not a field — so the parens are what tell a
reader that something *happens*. This is a deliberate divergence from the FPC/Lazarus
RTL idiom, adopted for this codebase.

```pascal
a := Pop();            v := FLex.Cur();      Tokenize();      inherited Create();
function Pop: TValue;  { NO parens on the declaration or the impl header }
cb := @host.Output;    { NEVER on an @ reference -- it would call, not take the address }
```

Rules, in order of how easily they are got wrong:
- **Never after `@`.** `@Foo()` is a compile error (`Variable identifier expected`) —
  loud, not silent, which is what makes a sweep safe to attempt at all.
- **Never on a declaration or implementation header**, and never on a `property`
  (a property cannot take parens; `Count` here is a property, not a function).
- **A name that is a local variable in one unit and a routine in another** (`pop`,
  `cur`, `ok`) must be judged PER FILE — a global name list will parenthesise a
  variable declaration and break the build. Exclude, per file, every identifier that
  file declares on the left of a `:` in a var/param/field list.
- Applied wholesale in one sweep (1445 sites, 39 files) rather than gradually: partial
  adoption is worse than either convention applied consistently.

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
- **`{$codepage UTF8}` CORRUPTS binary string LITERALS — a landmine.** Every Phosphor
  unit sets `{$codepage UTF8}`, which re-encodes a non-ASCII byte literal in source to
  its multi-byte UTF-8 form: `#$FF` becomes `C3 BF`, `#$8B` becomes two bytes. So a
  binary header, magic number, or CRC written as a *literal* is silently wrong, and a
  round-trip decompresses/parses to garbage or `""`. Build binary bytes at RUNTIME with
  `Chr($8B)` (a single raw byte); runtime `Chr()`, stream writes, and `PInt64`/`PByte`
  casts are unaffected — only source literals are poisoned. When bytes must be exact
  (gzip/zlib headers, .pbc magic, protocol framing), assemble them with `Chr()`/a stream,
  never `#$xx`/`'…'` literals.
- **gzip in memory:** FPC's `TGZFileStream` is file-only. For in-memory gzip use
  paszlib `zstream` with the skip-header form — `Tcompressionstream.Create(level, dst,
  True)` / `Tdecompressionstream.Create(src, True)` give raw DEFLATE (negative
  windowBits); wrap it yourself with the 10-byte gzip header + CRC32 + ISIZE trailer.
- **`TUnZipper.Files` is a STICKY filter** across calls: `UnZipFiles(list)` leaves the
  list in `FFiles`, and a later `UnZipAllFiles` then treats a non-empty `FFiles` as
  "only these" — a reused reader silently extracts just the last filter. `UZ.Files.Clear`
  before `UnZipAllFiles`. (And a predicate returns 1/0, not a Pascal bool — `assert_true`
  carries a message only on its `:n$` overload; there is no `assert_*:?$`.)
- **objfpc mode has NO `case`-of-string.** `case s of 'amp': …` does not compile; use an
  `if/else-if` chain over the (lowercased) string. Bites entity/keyword decoders.
- **A name/value bag needs TWO parallel `TStringList`s, not `Values[]`.** `TStringList`
  deletes the entry when you set `Values[name] := ''`, so an empty value silently drops
  the key — wrong for HTTP headers/params. Keep a names list + a values list yourself
  (case-insensitive match for header names), so an empty value is a real stored value.
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
- **Not every assert has a message overload.** `assert_int` is `:%%` only (no `:%%$`);
  passing a 3rd message arg raises `no function assert_int:%%$` and halts the file. When
  citing a doc/reason on such an assert, put it in a `rem` above, not a 3rd argument.
- **A backslash in a string literal is an escape** (`"\2"` is a rejected unknown escape,
  `"\\"` collapses to one backslash) — keep backslashes out of assertion messages, or
  double them. This bites file paths and cited expressions in `msg$`.
- **A library-gate must be DETERMINISTIC — and beware `cmd | grep -q` under
  `pipefail`.** `grep -q` exits at the first match and SIGPIPEs the upstream, so
  `ldconfig -p | grep -q libX` reads **non-zero even when it matched** (same class as
  the `set -e` + empty-pipeline trap): an intermittent, maddening false SKIP that hides
  the very failure the gate guards. Capture into a var and test it (`x="$(cmd)"; case
  "$x" in *libX*) …`), and back it with a direct file check (`for f in …/libX.so*; do
  [ -e "$f" ] && …`). Never gate a test on a `cmd | grep -q` pipeline.
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
- **A TEST THAT FAILS FOR THE WRONG REASON IS NOT A CONFIRMATION.** Three times this
  round a new test failed against the old build and looked like proof, and was not:
  it used a handle the file had already closed (SQLite), it passed the value in the
  wrong parameter and corrupted an opcode that was valid (the .pbc probe), and it
  looped forever because `resume` retries the failing statement and nothing in the
  handler changed. Read the failure MESSAGE, not just the exit code -- "byteat: byte
  1 is outside 1..0" is a different fact from "byte 2 is outside 1..1", and only the
  second one is the bug you are fixing.
- **A SANITY CHECK CAN SILENTLY FAIL TO SABOTAGE.** The .pbc probe wrote through
  `TBytesStream.Bytes` and the byte read back afterwards was not the one written, so
  the "corrupted" file was intact and the test passed for nothing. When a test's
  whole value is that it broke something, ASSERT THAT IT BROKE -- read the mutation
  back before running it.
- **MEASURE THE LIBRARY, DO NOT REASON ABOUT IT.** Two full rounds of reasoning about
  where fcl-json loses bytes were wrong. A twenty-line Pascal probe dumping hex
  answered it in one run: TJSONString.Create is exact, AsJSON is not, and of the
  several Add overloads exactly one corrupts. The same probe run on the OTHER machine
  found that `GetJSON(text)` is lossy on Linux and exact on Windows, and that the fix
  is its second argument. Neither fact was derivable from reading the source.
- **GREEN SUITES PROVE THE ABSENCE OF REGRESSION, NOT THE PRESENCE OF CORRECTNESS.**
  With 659/659 functions covered and every golden byte-exact on both OSes, an
  adversarial hunt (12 finder agents over disjoint slice x failure-mode pairs, every
  finding put to three independent refuters, 74 candidates -> 69 confirmed) found
  defects the suites could not see, including ones that killed the process: ordinary
  arithmetic raising a hardware trap `on error` could not catch, an archive entry
  writing outside its destination, a handler silently corrupting the arithmetic it
  returned to. The suites were not weak; they were answering a different question.
  When a subsystem is "done", the next useful move is to attack it, not to extend it.
- **Fix the CLASS, and when a class recurs, write the CHECK.** Each of these rounds
  fixed a root rather than a list: one finiteness invariant instead of seven
  arithmetic patches, one saturating narrowing primitive instead of 131 conversion
  sites, one overlap-preserving rule instead of seven ON ERROR symptoms. And a class
  that has already been swept twice does not need a third sweep, it needs
  `scripts/check-codepage.py`: the check found ELEVEN sites where the hunt had
  reported five.
- **A blanket replace is only as good as the audit of what it replaced.** Replacing
  `Round(AsDouble(x))` with the saturating `ArgI32(x)` at 131 sites was right at 128
  of them and WRONG at three, where the callee wanted a value rather than an index --
  hex$ started answering in 32 bits. The call sites were indistinguishable; only the
  callees' types told them apart. After any mechanical sweep, re-run the original
  reproductions against the FIXED build rather than assuming uniformity.
- **A completeness claim in prose is a promise; make it a check.** `function-reference.md`
  called itself the complete catalog and had drifted 14 functions behind the registry —
  eight of them for months, unnoticed, because nothing compared the two. Prose cannot
  fail a build. `scripts/coverage.py` now enumerates every `Reg.Add`/`AddHost` name and
  exits non-zero if one is missing from the reference, exactly as it already did for
  tests. The same rule applies to any invariant a comment asserts: if reordering,
  renaming or deleting something would break it *silently*, the check belongs in a
  script. `build-gui.{ps1,sh}` verify `PhosphorDisplayGuard` precedes `Interfaces` in
  the `uses` clause for that reason — that order is the only thing making the guard
  work, and violating it still compiles and still passes on Windows.

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

- **2026-09-05 · round 24 · the last two GUI items, and four traps in the way.**
  `FreeNotification` and `drawgrid@` — held back as "their own increment" — closed
  together. Neither was hard; getting there was instructive.
  - **`x is TClass` on a possibly-dead pointer IS A DEREFERENCE.** It reads the
    object's VMT. The first `TGuiHandle.Destroy` asked `c is TComponent` to decide
    whether to unhook — on a `TTreeNode` already destroyed with its tree, that is
    the exact access violation the change existed to prevent. ASK ONCE, WHILE THE
    POINTER IS CERTAINLY LIVE, and remember the answer.
  - **A TComponent field needs explicit visibility.** `TComponent` is `{$M+}`, so a
    field with no section defaults to *published*, and a plain `TObject` cannot be
    published. Two errors, no obvious connection to what changed.
  - **A HEADLESS RUNNER MUST NEVER OPEN A DIALOG.** That access violation escaped
    into the LCL, whose default handler is a modal box — *"Press OK to ignore and
    risk data corruption"* — and the suite sat on it. A HANG IS WORSE THAN A
    FAILURE: no message, no exit code, no file name, and on an unattended run it
    holds the machine. `Application.OnException` now reports and halts 3. The owner
    saw the box before the tooling did, which is the wrong way round.
  - **A synthesiser must go through the real event property.** `drawgrid_drawcell@`
    first called the bridge object directly; a test caught it, because unwiring
    `OnDrawCell` then left the synthetic path still firing. `control_keydown@` calls
    `KeyDown` for the same reason — reaching past the property exercises a path no
    real paint or keypress ever takes.
  - **One principled exemption, not a silencing.** The new name gate flagged the
    playbook's own round-23 entry, which lists `crt_gotoxy` and friends precisely
    because they do not exist. A record of a mistake has to be able to name it, so
    the RETROSPECTIVE LOG is exempt and sections 0-5 above it stay gated — verified
    by planting a ghost in each half.

- **2026-09-05 · round 23 · asked whether one README sentence was true; ended up
  building sixteen controls.** Three audits ran: one sentence, one document, and all
  thirteen documents against the code. Between them they found the largest gaps in
  the project, and none of them were failing tests.
  - **The GUI plan named sixteen things nobody had built**, five of them Tier 1 —
    including seven of the eight event signatures, so a program could not bind a
    key, a mouse click with coordinates, a wheel or a form close AT ALL, while the
    page showed the handler shapes as if they existed. All sixteen built the same
    day, plus `paintbox@` (which needed the canvas target generalised from "a
    TBitmap" to "anything with a canvas" before it could exist at all). 311 → 412
    GUI names.
  - **The audit found two CODE defects the tests never would have.**
    `control_set@(b@, "Anchors", "akLeft,akRight")` — the natural line to write
    after reading the page, and the same shape that works one line earlier for an
    ENUM — fell through to `SetOrdProp(.., 0)` because `tkSet` is in `IsOrdKind`:
    it wrote the EMPTY set, wiping 7 to 0, and left `gui_error` at 0. IT DESTROYED
    LIVE STATE AND REPORTED SUCCESS, which is worse than an error because nothing
    looks wrong. And the two halves of the bridge disagreed: writing an unreadable
    property recorded error 3, reading one answered 0 with error 0.
  - **Three DOCUMENTED calls aborted the reader's program.** `narr_set@` and
    friends were documented as answering a handle; they answer the value written.
    `h@ = narr_set@(a@, 1, 42)` → "cannot store int into handle variable", exit 1.
  - **THE GATES ONLY EVER CHECKED ONE DIRECTION.** `registered → documented` was
    enforced; `documented → registered` was not, so a page could call a function
    that never existed and everything stayed green. `decisions.md` advertised
    `crt_gotoxy`/`crt_color`/`crt_clear` for months. Two rules close it: the CALL
    FORM (a backticked `name(` — a variable is never followed by a parenthesis) and
    the FAMILY PREFIX (`crt_something` where other `crt_` names are registered).
  - **A gate that cries wolf is a gate people learn to skip.** The first version
    flagged `http_get_via$`, which is real — registered by the http TEST HOST, a
    program rather than a unit. Fixed the gate, not the document. It also caught
    two things I had written myself that same hour, which is the point.
  - **The pattern across all three audits is one thing:** the project gated what it
    could count and left everything else to prose. Numbers, names and directions
    are all mechanically checkable, and every one of them had drifted somewhere.

- **2026-09-05 · round 22 · the runner could report success for work it did not do.**
  Asked whether one README sentence was true. It was not, but the audit's completeness
  critic found something worse than the wording: FIVE paths by which the acceptance
  suite prints SUITE OK without having checked anything.
  - `tests/negative` emptied printed **`PASS  reject: *.bas`** — the Linux loop has no
    `nullglob`, so it runs once on the unexpanded pattern, phosphortest fails to open a
    file named `*.bas`, and the non-zero exit reads as a correct rejection. Demonstrated
    before being fixed; a hollow pass indistinguishable from a real one.
  - A missing probe SOURCE and a missing GATE FILE were `continue`d in silence on BOTH
    platforms. Delete `tests/probe_bytecode.lpr` or `scripts/check-codepage.py` and the
    suite stayed green. The gate skip sits **ten lines under a comment saying "a gate
    that quietly does not run is worse than no gate, because it reads as a pass"**. The
    rule was written and then not applied to the line beneath it.
  - Nothing checked that `manifest.txt` COVERS `tests/suite`. An unlisted `.bas` never
    ran on either OS, while `coverage.py` still counted it as "exercised by a test"
    because that gate globs `tests/**/*.bas`. Two gates agreeing on a green nobody
    earned: one proved the function was mentioned, the other never ran the file
    mentioning it.
  - **THE LESSON IS ONE I HAD ALREADY WRITTEN AND DID NOT FOLLOW.** Earlier the same
    day I fixed `test-suite.sh` accepting an unknown flag by silently running the full
    suite — the identical class — and committed it alone. Round 13's rule says: WHEN YOU
    FIND A BUG CLASS, SWEEP EVERY INSTANCE IN THE SAME COMMIT. One instance was fixed
    and four were left, in the same two files, for the rest of the day.
  - **The prove-it script caught a defect in the fix itself.** A manifest entry with no
    golden printed the diagnosis and then killed the run on `ReadAllBytes` under
    `ErrorActionPreference=Stop` — so the operator saw the reason but never saw SUITE
    FAILED. Fixed by skipping already-reported entries so the run reaches its summary.
    Five sabotages, each restored, each seen failing.

- **2026-09-05 · round 21 · the last unbuilt promise: the byte buffer.**
  `decisions.md` had settled binary I/O in one line since the founding brief -- "no
  scalar BYTE type; binary I/O uses a buffer-as-handle" -- and the handle existed
  while the buffer did not. `file_readallbytes@` returned a `TPhosphorBytes` that
  nothing could look inside: you could carry a file's bytes from a read to a write
  and no further. 23 names / 29 registry entries close it, and deliberately add NO
  type -- the package operates on the SAME handle Io already hands out, so reader,
  edit and writer compose with no conversion step between them.
  - **The spelling changed and the decision did not.** The brief wrote
    `buffer_new(1024)`; the rule that a built-in's return type comes from the suffix
    on its OWN name arrived later, so the constructor had to be `buffer_new@`. The
    old spelling was still sitting in decisions.md, where a reader copying it out
    would have got "unknown function" -- the exact defect class the library-map gate
    was built for, in a file the gate does not read. FIXED THE PAGE, not just the code.
  - **The aliasing check was the one worth writing.** Pascal strings are
    reference-counted with copy-on-write. An INDEXED write uniques for you; whether
    `FillChar`/`Move` on `Data[1]` uniques first is a property of the compiler, not
    something to reason about. Rather than argue it, the check was SEEN FAILING:
    replacing `FillChar(b.Data[1], ...)` with `FillChar(PAnsiChar(Pointer(b.Data))^, ...)`
    turned exactly three assertions red -- filling a clone rewrote the original, and
    a string the buffer was built from. The real code is correct; the test now proves
    it stays that way.
  - **The suite style is not the classic style, and the file was written in the wrong
    one.** It ran, exited 0, and reported `passed: 0 / failed: 0` -- a golden of two
    lines that asserted nothing. `println` belongs to tests/classic, where the whole
    output is the golden; tests/suite asserts. A GREEN RUN WITH A ZERO COUNT IS NOT A
    PASS: read the count, not the exit code.
  - **Asked "is the documentation updated?" -- and the sweep found five stale
    claims that had nothing to do with this round's work.** Three were COUNTS
    nobody was watching: README said "nine opt-in host packages" (six),
    architecture.md "20 isolated packages under host/gui/libs/" (17), and
    architecture.md still called phase 3 "**Next**" while roadmap-phase3.md in the
    same directory said "STEPS 1-5 COMPLETE" -- two pages of the same project
    contradicting each other. The fifth was the console host's own header comment
    listing four of the seven verbs it implements, so `compile`, `pack` and `--gui`
    were invisible to anyone reading the source instead of running `--help`.
    A NUMBER IN A SENTENCE IS AS CHECKABLE AS A NAME IN A TABLE. coverage.py now
    gates all three counts against what is actually registered, and refuses to pass
    when it can no longer FIND a claim -- a gate that silently checks nothing is
    the failure it exists to prevent. Seen failing on all three before being
    trusted, by perturbing each claim by one.
  - **One literal could not be written.** `-9223372036854775808` is not expressible:
    the magnitude `2^63` overflows Int64, so the lexer makes it a Double and the
    negation follows. Written as `-9223372036854775807 - 1`, which is exact. Not a
    defect -- a property of the notation, now pinned by a test so it is not
    rediscovered as one.

- **2026-09-04 · round 20 · all 69 findings closed, and what the closing cost.**
  Fourteen commits, each one class at a time, each verified on both OSes before the
  next began: hardware traps escaping the VM; the codepage char-concat class (third
  sweep, now with a check that found ELEVEN sites where the hunt reported five); 131
  unchecked narrowings; zip-slip and packages freeing handles they did not own; ON
  ERROR across re-entrant calls; JSON that could not carry a byte; the 64 KB channel
  window showing through; an unvalidated .pbc; six libraries answering in the RTL's
  words instead of their own; four language semantics that were quietly wrong; nine
  places where the machine's locale reached the program; and a FOR bound that lived
  in a global. 152 new assertions across seven suite files, three classic goldens, a
  package file, a negative and two probe cases.
  - **The last critical was found by counting, not by testing.** After the twelfth
    commit I listed the hunt's 69 findings against what had been fixed and one
    CRITICAL had no commit against it: a FOR loop's bound in a hidden global, so a
    function recursing from inside its own loop rewrote its own limit and f(3)
    answered 3 instead of 15. Nothing had failed; it simply had not been done. KEEP
    THE LIST AND TICK IT OFF -- momentum is not coverage.
  - **Fixing that one exposed a second defect beneath it**, exactly as round 19's
    rule warned: the compiler registers a function before parsing its body, so the
    local-type table missed anything the body added, and the new slot read a garbage
    type and then segfaulted. Second time this round that a structural fix uncovered
    something older than itself.
  - **Two fixes had to be argued down to their real scope.** The power-precedence fix
    would have flipped '^' from left- to right-associative as a side effect (2^3^2:
    64 into 512) -- caught by testing the chain, not just the sign. And the JSON key
    limitation is fcl-json's hash, not Phosphor's: it is DOCUMENTED, and the test
    asserts what is true on both platforms, because a platform-dependent golden would
    have been worse than saying so.
  - **One accidental correctness was removed on purpose.** json_keys@ was right on
    Windows only because two bugs cancelled -- a lossy name hash and a re-encoding
    Add overload. Fixing one alone would have broken it; fixing the mechanism made it
    honest on both. Two bugs agreeing on one platform is not a behaviour to keep.
- **2026-09-04 · round 19 · an adversarial hunt on a project that looked finished.**
  Every suite green, byte-exact on both OSes, 659/659 documented and tested. Twelve
  finders over disjoint slice x lens pairs, three refuters per finding: **69 confirmed
  defects**, thirteen of them critical. Reproduced every headline one by hand before
  acting -- all of them stood. Fixed so far, by class, each with regression tests and
  both OSes verified: hardware traps escaping the VM (`10.0^200 * 10.0^200` exited
  217 and `on error` could not see it); the codepage char-concat class for the third
  time, now with a check; 131 unchecked narrowings (`dict_key(d@, 4294967297)`
  truncated to 1 and walked past the bounds test one line below it); zip-slip and
  packages freeing handles they did not own; and ON ERROR across re-entrant calls.
  - **The ON ERROR round is the one worth reading.** Seven confirmed defects, four
    roots. The deepest: a handler runs at the level it was INSTALLED at while
    `resume` returns to the level the failing STATEMENT ran at, and everything
    between belonged to the pending resume -- so the handler ran directly on top of
    it and `1000 + risky(0)` came back as 12. The engine had no bug in any single
    line; it had two different meanings for "where we are".
  - **Fixing one defect can expose another that was masked.** Making a nested fault
    propagate OUTWARD (root 2) immediately produced an infinite loop, because the
    statement boundary lived in FIELDS and every statement run by a nested call had
    been overwriting the outer activation's resume point all along. Nobody could see
    it while faults were mishandled locally. Budget for this: after a structural
    fix, re-run the reproductions expecting NEW failures, not just the old ones gone.
  - **My own mechanical sweep introduced a regression** (hex$ in 32 bits), found by
    re-running the hunt's reproductions against the fixed build. Rule in section 4.
  - **Seeing it fail found a hole in the CHECK, not the code.** The first
    check-codepage.py anchored to the start of a line, so reintroducing `if c then
    r := r + c` did not trip it. A check you have not watched fail is a check you
    have not written.
- **2026-09-04 · round 18 · asked whether the docs covered the new work; they did not.**
  The honest answer needed an audit, not an assertion. Enumerating the registry against
  `function-reference.md` found **14 undocumented built-ins** — six from the last two
  rounds (the byte primitives, `callfunc%`, `callfunc?`) and **eight that had never been
  listed at all** (the `dir_*`/`file_*` timestamp pairs), plus three stale section
  counts. The README's `scripts/` row named three of seven scripts, and nothing recorded
  the display guard's exit code 3 or that `phosphorgui` accepts a `.pbc`.
  - **The lesson is not the 14 entries — it is that the drift was invisible.** A
    document that calls itself complete has no way to fail. So the reference is now
    gated by `coverage.py` alongside the test gate (§4): remove one entry → `UNDOCUMENTED:
    bytelen`, exit 1; restore it → 659/659, exit 0. Seen failing before being trusted.
  - Same reasoning applied one step further. Documenting the guard's load-order
    invariant in `architecture.md` was still only a promise, and a uses-clause reorder
    fails in the nastiest way available: compiles clean, green on Windows, silently
    unguarded on Linux. Both `build-gui` scripts now check the order and refuse to
    compile — proven both OSes with the lines swapped (exit 1) and restored (exit 0).
  - Rule of thumb this produced: **when you write a comment saying "must stay X", ask
    what fails if someone changes it. If the answer is "nothing, until much later",
    write the check in the same commit as the comment.**
- **2026-09-02 · round 17 · the complete runner, and a measurement stated too broadly.**
  Asked for one binary carrying every library including the graphical ones. Findings:
  compiling already covered everything (`CompileFile` touches the registry zero times);
  a `--gui` flag cannot load the LCL in-process because gtk2 binds the X display in a
  unit INITIALIZATION section, before `main` — a runtime flag cannot undo a link-time
  decision. Answer: `phosphorgui` registers every package too (complete runner) and
  `phosphor --gui` hands over to it. Also added the build scripts the GUI *application*
  never had — only `phosphorguitest` was buildable from `scripts/`.
  - **The lesson is about how I reported the measurement.** My probe ran `env -u
    DISPLAY` and I presented "an LCL-linked binary dies on Linux" as if it were a
    property of the platform. The owner pushed back — he had a live GTK session on that
    very VM — and he was right: with `DISPLAY=:0` and the session's Xwayland cookie the
    same binary runs fine, exit 0. The true statement is narrower and more useful: it
    must not DEPEND on a display, because a plain ssh session (how this project's own
    Linux verification arrives), CI and containers have none. **State what the
    experiment actually held constant; a deliberately hostile environment proves a
    conditional, not an absolute** — and correct the code comments, not just the chat
    reply, because the comment is what the next reader inherits.
- **2026-09-02 · round 16 · the empty-parens convention, and a half-enforced rule.**
  The owner proposed marking parameterless CALL sites with `()` so a call cannot be
  misread as a variable. Adopted and swept wholesale (1445 sites, 39 files); the rule
  itself is §2b. Two lessons, and the second matters more than the convention:
  - **The sweep broke on exactly the ambiguity the convention exists to remove.** A
    global name list wrote `var ... bestPop, pop(), idx ...` because `pop` is a local
    Integer in one unit and a method in another. A purely lexical transform cannot see
    scope — so scope it per FILE (exclude every identifier that file declares left of a
    `:`), and lean on the compiler: `@Foo()` and a parenthesised `property` both fail
    LOUDLY, which is what makes such a sweep safe to attempt at all. Measure before
    committing to a sweep: the first estimate was "some dozens", the truth was 1778.
  - **A discipline enforced by only ONE of the two runners is half a discipline.**
    `-ProveFailure` existed in test-suite.ps1 and had never existed in test-suite.sh, so
    on Linux the oracle suite could not prove it was able to fail. It went unnoticed for
    every previous round because the Windows run always covered it — and surfaced only
    when the VM was the half being checked. Rule: when a verification gate is added to a
    `.ps1`, add it to the `.sh` in the same commit, and periodically diff the two
    runner families for capabilities that exist on one side only.
- **2026-09-02 · round 15 · a stateful REPL.** The owner typed six lines at the prompt
  and found `let br? = 2 = 2` / `println br?` printing `false`. The LANGUAGE was right
  (one program prints `true`); the REPL ran every line as its own program, so each
  line's state was executed and thrown away. Lessons:
  - **A tool that documents its own defect has still shipped the defect.** The banner
    literally said "Each line runs as its own program" — an accurate sentence that made
    the tool useless for its one job. Honesty in a message is not a substitute for
    fixing the thing; if a limitation reads as absurd when a user hits it, it is a bug.
  - **Verify the user's claim BOTH ways before touching anything.** Two of the three
    surprising lines were correct (`a% = 10.5` → `10.00` is integer coercion with
    ties-to-even). Running the same source as ONE program isolated the real defect to
    the host in one probe, and stopped a "fix" to the perfectly good boolean path.
  - **Append-only compilation makes an incremental REPL almost free.** Globals get
    their index on FIRST appearance and instructions are emitted in order, so compiling
    `session + newline` leaves every earlier index and instruction position untouched:
    run from the previous instruction count over a VM whose globals persist and you get
    variables AND user functions carrying across lines, with no new symbol-table
    machinery. `RunFrom` grows FVars without clearing it and leaves handles, channels,
    the DATA cursor and the ON ERROR handler alone.
  - **Reuse the compiler's own error messages as a signal.** Multi-line blocks work
    because the host treats exactly the compiler's unterminated-block messages
    (`expected 'endif'`, …) as "keep reading" and shows a `...>` prompt — no second
    parser, no brace counting.
  - **A REPL is testable.** `tests/classic/*.repl` pipes a session to stdin and pins the
    whole transcript, prompts included, byte-exact on both OSes.
- **2026-09-02 · round 14 · streamed channels + random access.** Closed the two limits
  round 13 reported honestly instead of hiding: `open … for input` slurped the whole
  file, and there was no way to reach a byte at a known offset. A channel now streams
  through a sliding 64 KB window and `OPEN … FOR BINARY` + `SEEK` give random access.
  Lessons:
  - **Report a limit precisely and it becomes the next work item.** Round 13's honest
    "no streaming, no random access" list was the whole design brief for this round.
    Measure the limit, too: "a 200 MB file peaked at 417 MB" is what made the fix
    obviously worth doing, and "39 ms to open 200 MB and read 4 bytes" is what proved
    it landed.
  - **A buffered reader must pull until it holds a TERMINATOR, not a fixed count.** The
    line and field readers refill the window until a terminator is present (or EOF),
    otherwise a line straddling a chunk boundary silently comes back truncated — the
    classic buffered-IO bug. Pinned with a 4000-line file well past the window.
  - **When an existing function contradicts a frozen language rule, fix it while you
    are there.** `loc()` returned a 0-based byte count in a language whose own charter
    says BASE 1 IN EVERYTHING. Nothing depended on it, so it became 1-based and now
    pairs cleanly with the new `seek` (`seek #n, loc(n)` is a no-op). Grep for
    dependents first; if there are none, the inconsistency is free to remove.
  - **`FillChar` over a record holding a managed string leaks it.** The channel slot
    reset had this latent bug; fields are now assigned individually.
  - **Say what you deliberately did NOT build, and why.** Classic `FIELD`/`GET`/`PUT`
    fixed records were skipped because byte-addressed SEEK covers the same ground —
    recorded in decisions.md so the omission reads as a choice, not an oversight.
- **2026-09-02 · round 13 · byte-level file work.** A user question ("how would I work
  with a file byte by byte?") turned into the round's biggest find. **The rule this
  produced, and it is the most important one here: WHEN YOU FIND A BUG CLASS, SWEEP FOR
  EVERY INSTANCE IN THE SAME COMMIT — do not fix the two you tripped over.** Round 12
  fixed the `{$codepage UTF8}` byte-concat trap in `hex_decode$`, then a scan found it
  in `http_urldecode$`. That scan was not exhaustive enough: this round found FOUR more
  live instances — `ChanLine` (`line input #`), `NextFieldStr` (`input #`),
  `strings_delimitedtext`, and `http_htmlencode$`/`htmldecode$` (the `url_` half of that
  very unit had been fixed while the `html_` half was missed, in the same file). Two of
  them were in code I had written the same day. The grep that finds them all is
  `:= .* \+ (Chr|S\[|Buf\[|buf\[)` over every accumulation loop, not just the ones named
  "decode". Verified before/after on the bytes `41 80 FF 42`: readers returned
  `41 3f 3f 42`, now `41 80 FF 42`.
  Other lessons folded in:
  - **A "byte-exact" storage layer is not a byte-capable language.** Phosphor's strings,
    files and `#` channels all carried bytes correctly, yet nothing could ADDRESS a byte:
    `len` counts codepoints, `chr$` ENCODES (so `chr$(200)` is two bytes and no lone byte
    ≥ 128 was constructible), and `asc` answers 0 for all 64 bytes `80..BF`. Added
    `bytelen`/`byteat`/`bytestr$`/`bytemid$` to the ENGINE — deliberately not a package,
    because the only byte-exact accessor had been the hex codec in an opt-in package,
    leaving the embedding host (Phosphor's headline use case) with no byte access at all.
    Rule: when a capability exists only in `host/packages`, ask whether the embed host
    needs it.
  - **Free functions must type-check their handle.** `strings_free` called `FreeHandle`
    with no class test, so `strings_free(a@)` on an array silently destroyed it while
    `arr_free` next door checked. Any `*_free` gets the same audit.
  - **Preallocate every byte builder.** `hex_encode$` was quadratic (64 MB ≈ 37 s) while
    its own `hex_decode$` sibling preallocated — the fix pattern was already in the file.
  - **An empirical workflow beats reading.** Six scenarios each PROVEN by running code,
    every claim attacked by two verifiers, refuted 6/6 headline claims (e.g. `input$(k,#n)`
    is byte-exact but is NOT streaming — `open for input` slurps the whole file). Reading
    the source alone would have shipped the streaming claim.
- **2026-09-02 · round 12 · scope-completion audit (standard-BASIC commands + library
  review).** A strict re-audit against the founding brief (`prompt-inicial.md`, not the
  oracle) found the standard-BASIC command set unbuilt despite "oracle complete". Built
  it all — `INPUT`/`LINE INPUT`/`INPUT$`, classic `#` file I/O (OPEN/PRINT#/INPUT#/LINE
  INPUT#/CLOSE/EOF/LOF/LOC), `PRINT USING`, `SWAP`, `while…wend` — green byte-exact both
  OSes (`tests/classic`). Integrated every package into the console host so run/compile/
  pack reach the whole surface. Then a **3-agent adversarial library review** (each bug
  reproduced with a probe before the fix) found real defects, all fixed + regression-
  tested. **New rules folded in:**
  - **The `{$codepage UTF8}` byte-concat trap (paid for THREE times: hex_decode$,
    http_urldecode$, string$).** Accumulating raw bytes with `r := r + Chr(b)` re-encodes
    any byte ≥ 128 to its UTF-8 form or `'?'` — silent corruption in any codec advertised
    as byte-exact. Build byte strings by INDEXED assignment into a `RawByteString`
    (`SetLength(r,n); r[i] := Chr(b)`), exactly as the gzip header does; `ValStr` of a
    RawByteString keeps the bytes. A single-expression `Chr(a)+Chr(b)` (chr$/ucase$) is
    SAFE — only loop accumulation over a CP_UTF8 string corrupts. Grep new byte code for
    `:= .* \+ Chr(`.
  - **A library function must never crash the interpreter.** An unguarded Double→Int64
    (`Round`/`Trunc`/`Floor` on a value past Int64 range, or `AsFloat`/`AsString` on an
    off-type JSON node) raised an FPC exception that escaped `Run` and killed the process
    — ON ERROR could not catch it, so an untrusted script could take the host down with
    one big number. Fix is TWO-layer: a central `try/except` around the VM's library-call
    dispatch converts ANY library exception into a CATCHABLE engine error (the safety
    net, `PhosphorVM` opCall), plus `PhosphorValue.InI64Range` / VM `SafeI32` guards at
    the hot conversion sites for clean messages. A reader returns a value/default, never
    raises (`json_getn`/`gets$` coerce; `json_parse('')` reports an error not a nil node).
  - **`local` goes on the `function` line** (`function f() local a, b`), never a separate
    line — cost two test rewrites. Other confirmed non-bugs worth pinning: `dim@(n)`
    creates an array; `zip_addstr(z@, text$, name$)` is content-then-name; `assert_true`
    has no bool+message form (`:?` only); `resume <label>` is unsupported (`resume next`).
  - **Coverage is a measurable, repeatable asset** (`scripts/coverage.py`, 655/655): it
    enumerates every registered built-in and fails on any untested one. It found 6 real
    gaps (5 CRT cursor helpers, `http_ca_file$`) the oracle never touched.
  - **Consistency findings the OWNER (user) caught, not the agents:** `callfunc%` /
    `callfunc?` were missing (only 3 of 5 return-suffix spellings) — completeness of the
    five-type model must be checked across EVERY facet (function names, params, and the
    dynamic-call primitive all take all five suffixes). Rule: when a feature is "one per
    value kind", assert all five exist.
  No human FIXED anything this round, but the human's inspection surfaced two gaps the
  three review agents missed — a reminder that adversarial review complements, does not
  replace, an owner reading for consistency.
- **2026-09-02 · round 11 · local RAG retrieval index (oracle 33) — THE LAST ORACLE
  FILE.** Green both OSes, `tests/suite/33_rag` 22 asserts, no human needed. New PURE
  ENGINE lib `engine/libs/PhosphorRagLib` (registered in `PhosphorEngine`, boundary
  clean — only `SysUtils`/`Classes`/`StrUtils`/`fpjson`): a dependency-free retrieval
  index over a folder of markdown docs with YAML-style front-matter, reproducing the
  Delphi reference's multi-signal keyword scoring (tags×3 + title×2.5 + functions×5 +
  id×3 + library-hint×10 + language boost) so the same query picks the same document.
  Functions: `rag@`/`rag_free`/`rag_rebuild@`, `rag_retrieve$`/`_json$`/`_budget$`,
  `rag_doc$`/`rag_functions$`/`rag_tags$`, `rag_analyze$`, `rag_count`/`rag_funccount`,
  `rag_summary$`, `rag_error`. Five things worth folding in:
  (1) **`next` is BARE in Phosphor** — no loop variable. Porting a reference
  `for k … next k` verbatim halts the parser with "expected end of line" on the
  `next k`; drop the variable. (Same class as round-1's syntax divergences; belongs
  in §4 as a porting checklist item.)
  (2) **objfpc reserved-word / case-insensitive name traps, twice in one file:** a
  nested `procedure Try(...)` is a compile break (`try` is reserved → "Syntax error,
  identifier expected but TRY found"), and a local `stop: Boolean` collides
  case-insensitively with a `const STOP: array…` ("Duplicate identifier STOP"). Name
  loop-scratch vars distinctly from any const in scope, and never a keyword.
  (3) **Improve-beyond-reference, made VISIBLE:** the reference's validator RAISED on
  a bad handle, so its own test could only *comment* that "a fabricated handle is
  refused… provoked where it can be seen" — it could not assert it without halting.
  Phosphor's errors-as-values design turns the refusal into an actual passing
  assertion: `rag_count(pointer@(n))` answers 0 (IsHandle refuses to dereference the
  fabricated id) and `rag_error()` reads the reason (the ioerror/valcode pattern). The
  round-3 handle discipline, finally a green line instead of a comment. This is the
  memory rule "improve beyond reference where it has an artifact" — the artifact was a
  property the reference wanted to prove but its raise-on-invalid design forbade.
  (4) **The budget-poison regression the oracle pins passes EITHER WAY, but reproduce
  it honestly:** an over-budget doc is admitted *truncated* only when its score ≥ the
  high-relevance threshold (8.0), so caching the FULL loaded content and truncating a
  LOCAL copy is what keeps a small-budget-first call from poisoning a later
  large-budget one. A naive "load, truncate, cache truncated" would pass the first
  assertion and fail the second — exactly the defect the oracle's comment narrates.
  (5) **instr divergence proven, not assumed (round-4 template):** a see-check-fail
  confirmed `instr` of an absent substring is 0 in Phosphor (asserting the reference's
  `-1` FAILED with "got 0"), so the `0` is right semantics, not a fudged constant; the
  reference's `instr(...) + 1` "contains" idiom drops the `+1` (round-5 again), and
  function suffixes carry Phosphor's `@` where the Delphi reference wrote `#`.
  **★ WITH 33 GREEN ON BOTH OSes, THE ENTIRE PLAN9BASIC ORACLE `tests/suite` CORPUS IS
  COMPLETE** — every portable oracle file (including the four external-dep deferrals
  23/32/33/34) now has a Phosphor equivalent, byte-exact green on Windows AND the Linux
  VM, boundary intact, zero warnings/notes.
- **2026-09-02 · round 10 · HTTP offline config surface (oracle 32).** Green both OSes,
  `tests/packages/08_http_offline` 68 asserts, no human needed, no library-gate (plain
  config needs no runtime lib). Extended `PhosphorHttpLib` with a client-config handle
  (`http_client@`) + a form handle + ~60 setters/getters/encoders, validated through
  `PhosphorHandles` like every package (a fabricated id is `nil is T…` = refused). Kept
  `http_get$`/`post$`, the multi-address fallback, and TLS verification working. Two
  traps → §3: objfpc has no `case`-of-string (if/else-if chain for the HTML-entity
  decoder), and a name/value bag must be parallel `TStringList`s because `Values[]:=''`
  deletes the key. url-encoding via runtime `IntToHex` sidesteps the round-8 codepage
  landmine, as predicted.
- **2026-09-02 · round 9 · full SQLite statement API (oracle 34).** Green both OSes,
  `tests/packages/07_sqlite_full` 64 asserts (mirrors 34), no human needed. Rewrote
  `PhosphorSqliteLib` from the SQLdb simple API onto the **raw sqlite3 C API** via
  FPC's dynamic binding (`SQLite3Dyn`): open/exec/scalar/query kept working AND the
  full surface added (prepare→step→reset→finalize, per-parameter bind, per-column
  type/value, a JSON row/table bridge, transactions, introspection, changes/lastid,
  escape/quote, error code+msg+strerror, backup/vacuum) — ONE API on one driver, no
  two half-APIs. Five things worth folding into §3/§2:
  (1) **The dynamic binding is the library-gate, for free.** `TryInitializeSqlite('')`
  returns `-1` **without raising** when `libsqlite3`/`sqlite3.dll` is absent, so a
  module-init `GReady := TryInitializeSqlite('') > 0` gates every function and the
  package still BUILDS everywhere (no link-time dep). **Do NOT `ReleaseSQLite` at
  finalization:** this unit finalizes before `PhosphorHandles` (it `uses` it), so
  unloading the library first would leave a lingering db's destructor calling
  `sqlite3_close` through a dangling pointer. Leave it loaded; the OS reclaims it.
  (2) **SQLite's own index bases are split** — bind parameters are 1-based, result
  columns 0-based. Phosphor presents a **uniform 1-based** surface (binds pass the
  index straight through, columns subtract 1), consistent with strings/arrays/JSON;
  the see-check-fail proved a wrong base misses, not a fudged constant.
  (3) **No cursor may outlive its connection.** A statement is a handle too; the db
  owns a child list and its destructor `FreeHandle`s each child (finalizing the
  `sqlite3_stmt` AND nilling its registry slot), so a stale statement id is refused
  by `IsHandle`, never dereferenced. Each child removes itself from the list on free.
  (4) **Bridge, don't duplicate (round 5 again).** `PhosphorJsonLib` grew two
  interface functions — `JsonRegisterNode`/`JsonNodeFromHandle` — so the sqlite
  package builds/reads JSON rows that `json_*` reads back, one wrapper and one owner,
  boundary untouched (both are engine-side, pure fpjson).
  (5) A nested `{...}` inside a `{ }` doc comment is FPC's **"Comment level 2 found"**
  warning, and the note-strict build FAILS on it — keep braces out of brace-comments
  (a JSON shape `{name,type}` in prose becomes `(name,type)`).
- **2026-09-02 · round 8 · archive + gzip packages (oracle 23; completes 11's gzip).**
  Green both OSes, `tests/packages/06_archive` 42 asserts (matches 23), no human needed.
  Extended `PhosphorZipLib` to a handle-based create/add/list/extract API (FPC `Zipper`),
  added a new `PhosphorGzipLib` (real RFC-1952 gzip over paszlib `zstream`), extended
  `PhosphorBase64Lib` with file + url-safe variants — all ship with FPC, so no
  library-gate. Because these are external-facing they are opt-in HOST packages tested
  via `phosphorpkgtest`, not the engine suite — and gzip closing 11's gzip half means no
  separate `11_*` file is needed (regex → 31, base64 → 00_base64). Three FPC traps folded
  into §3, one of them a real landmine: **`{$codepage UTF8}` silently corrupts binary
  byte LITERALS** (a gzip header written as `#$8B…` decompressed to `""` until it was
  built from `Chr()` at runtime). Also: paszlib's in-memory gzip is the `zstream`
  skip-header form, and `TUnZipper.Files` is a sticky cross-call filter.
- **2026-09-02 · round 7 · `16_doc_examples` (documentation-vs-reality regression).**
  Green both OSes, 35 asserts, no human needed. A "not a port": harvested Phosphor's
  own doc claims (the arithmetic rules in `decisions.md`/`roadmap.md`, cited by line)
  plus curated built-in examples over the functions Phosphor actually ships, every
  value confirmed by RUNNING it. Combing all docs found **no page that lies** — a
  checked negative, not a skip. Divergences pinned for the right reason (`mid$`
  base-1 → "Hel" not "ell"; `instr` 1-based; `string$(3,65)`→"AAA" by code vs
  `mulstring$("ab",3)`→"ababab", the repeat the reference's broken doc actually meant).
  Test-authoring traps folded into §4 (`assert_int` has no message overload; a
  backslash in a message is an escape).
- **2026-09-02 · round 6 · `17_host_services` (the host-agnostic design, executed).**
  Green both OSes, 7 asserts, no human needed. Added a nil-by-default host seam
  (`THostServices` record: `ProcessMessages`/`HandleMessage`/`ClipboardCopy`/
  `ClipboardPaste`) modeled on round 2's `OnBreakpoint`, plus a new engine lib
  `PhosphorHostLib` (`processmessages`/`handlemessage`/`copytext$`/`pastetext$`/
  `strerror`). Every function guards `if Assigned(vm.HostServices.X)` and returns the
  empty answer (0/"") otherwise — asking an absent service can never fault on a nil
  method, which is the whole point of the file. Two patterns worth reusing: (1) group
  related host callbacks into ONE zero-initialized **record** field (not N separate
  `of-object` fields) — it reads as "a bundle of services a host fills in", keeps
  `ConfigureVM` a single assignment, and the phase-2 GUI event loop will install into
  the same record; (2) a script-visible error uses the `ioerror`/`valcode` pattern — a
  module-level code set on failure and read back by `strerror()`, so a missing service
  is a value the program can branch on, never an exception.
- **2026-09-02 · round 5 · `28_strlist` (StrListLib property surface) + a build.sh
  clean-build bug.** Green both OSes, faithful 63-assert adaptation, no human needed.
  Extended `PhosphorStrListLib` with ~40 `strings_*` functions covering everything the
  oracle exercised that was a *property* rather than a list op: capacity, the text
  getter, append, the delimiters (delimiter/quotechar/strictdelimiter/delimitedtext),
  the name/value setters (values-by-name, valuefromindex-by-index, keynames, a settable
  namevalueseparator), case sensitivity, the named duplicates policy, equals, batched
  begin/endupdate, the line-break controls, the encoding names, the file+stream round
  trips, and the change-handler NAMES. Two decisions worth keeping: (1) **onchange/
  onchanging store a name and read it back — no VM seam.** The oracle only asserts the
  name goes in and comes back ("the firing belongs to a host with an engine"), so a
  stored string is the whole job; `AddHost`/`CallUserFunc` would have been gold-plating
  the seam a phase-2 event loop will add. Read what the oracle actually asserts before
  reaching for the re-entrant path. (2) **The stream pair needs IoLib's byte-buffer
  type, so expose it, don't duplicate it.** `file_readallbytes@` hands back a
  `TPhosphorBytes` that was private to `PhosphorIoLib`'s implementation; `is TPhosphorBytes`
  needs the real type, so it moved to IoLib's *interface* and `PhosphorStrListLib` now
  `uses PhosphorIoLib`. Two sibling engine libs sharing a handle type is fine and keeps
  the boundary check green (pure RTL file/byte work, no host unit). The base adaptation
  followed round 4's template: every index +1, `strings_find` answers 0 (not −1) when
  absent, and — the new wrinkle — **`instr` is 1-based/0-absent in Phosphor, so a
  reference "does it contain X" written as `instr(...) + 1` drops the `+1`** (the offset
  existed only because Plan9Basic's `instr` was 0-based/−1-absent). The see-check-fail
  was decisive and free: a base-0 index isn't a soft miss here, it's a HARD runtime
  error (`string list index 0 out of bounds 1..2`) that halts the file — so a green
  `passed: 63` is itself proof every index landed base-1.
  **The trap (a real needed-a-fix):** running `scripts/build.sh` on the VM per the
  "run the console builds too, per OS" rule, it exited 1 on a **clean** build without
  printing `built:`. Root cause was `set -euo pipefail` + `issues="$(grep … | grep …)"`:
  a clean log has no matches, the grep pipeline exits non-zero, and `set -e` treats that
  failing command substitution in an assignment as fatal — so build.sh could NEVER exit
  0 on the clean build it exists to confirm. It had gone unseen because the Linux
  console build is only reached by this rule (the suite's VM verify is `test-suite.sh`),
  and `test-packages.sh`'s copy survives only because its package logs happen to carry a
  matching line. Fix: guard the substitution with `|| true` so `issues` captures the
  (possibly empty) text and the existing `[ -z "$issues" ]` decides clean-vs-dirty
  (verified both branches: clean→exit 0, a planted Note→"build NOT clean"→exit 1).
  **Rule:** in a `set -e` script, a `var="$(pipeline)"` whose pipeline may legitimately
  match nothing MUST end `|| true`, or a success reads as a failure. And "green on the
  suite" still is not "the console build is clean on this OS" — run it, and make sure it
  can actually report success.
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
