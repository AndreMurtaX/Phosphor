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
- **Commit + push as AndreMurtaX**, `Co-Authored-By: Claude Opus 5`. Update docs and
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
  `TPhosphorVM`. Type codes: `n` numeric (a Double, or an `int%` widened into one),
  `%` an exact `int%` slot that does not widen, `$` string, `@` handle, `?` bool,
  `nn`/`$$`/… for arity; `#` is never a code. Read a numeric arg with
  `AsDouble(Args[i])` (handles int%↔double); a zero-arg fn is `'name:'`.
- **THE GATE AND THE KERNEL MUST BE HANDED THE SAME PATH, AND EVERY WAY THEY CAN
  READ IT DIFFERENTLY IS THE SAME DEFECT.** Five instances so far, each of which
  passed every suite: a byte the kernel stops at (`#0`), an order of operations
  (`..` collapsed before links were followed, where path_resolution(7) does the
  opposite), a SEPARATOR, an entry no string test can see through (a junction to a
  drive root), and a length the walk could not hold. The separator is the RTL's
  doing and it is everywhere: a backslash is an ordinary name byte on POSIX and
  `AllowDirectorySeparators` says otherwise, which reaches `ExpandFileName`,
  `ExtractFilePath`, `ForceDirectories`, `IncludeTrailingPathDelimiter` and
  `ExcludeTrailingPathDelimiter` alike. The
  instance-versus-class lesson has a sharp edge here: one round fixed the ORDER and
  reused the SPLITTER, and the same escape was still live; the next fixed the
  splitter and the `..` branch still popped components with `ExtractFilePath`, which
  a new test caught and reading had not.
- **THE STRING YOU VALIDATE MUST BE THE STRING THAT DECIDES.** A zip entry carries
  its name twice; `SafeEntryName` was asked about the copy the archive ADVERTISES
  and extraction wrote under the copy it CARRIES, so a byte landed outside the
  sandbox root while every suite and all eight gates stayed green. When a library
  re-reads a value between your check and its use — and paszlib re-reads it inside
  the very call you are guarding — find the read that decides, and judge that one.
  MEASURE WHICH HOOK FIRES WHERE: the remedy that suggests itself (`OnCreateStream`)
  fires early enough but changes how the library builds the path, and the one that
  sounds later-and-safer (`OnStartFile`) fires after the file has already been
  created. AND THEN THE NAME WAS NOT THE ONLY THING THAT DECIDED: an entry whose
  ATTRIBUTES say symbolic link is extracted with its CONTENT as the link target, and
  a target is not a name, so the same escape had a second spelling the name guard
  passed. It lands only on Linux — paszlib forces `IsLink := False` off UNIX — so a
  Windows-green suite could not see it, and a reviewer who built on the VM found it
  in one run. When you close an escape, ask what ELSE the library does with an entry
  besides writing it under its name; and when a defect has an OS-conditional code
  path, the second machine is not a formality.
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
  before `UnZipAllFiles`. (And a predicate returns 1/0, not a Pascal bool.
  `assert_true` today has all four forms — `:n`, `:n$`, `:?`, `:?$`
  (`tests/PhosphorTestLib.pas:344`); `assert_int` is `:%%` ONLY, and a third
  argument to it raises `no function assert_int:%%$` and halts the file.)
- **A CONSTANT-FOLDED CONDITION IS DEAD CODE ON ONE TARGET AND LIVE ON THE OTHER.**
  `if DirectorySeparator <> '/'` is a compile-time constant per target: on Linux FPC
  reports the body as unreachable and `-vewn` fails the build, while Windows compiles
  it clean. Guard a separator-dependent statement with `{$IFNDEF UNIX}`, not with a
  runtime test — and do not reach for a local variable to defeat the folding, because
  the build is `-O2`.
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
- **A SCRIPT'S OWN FLAG SPELLING IS PART OF THE MEASUREMENT.** `scripts/test-classic.sh`
  takes `--prove` **or** `-ProveFailure` (line 65 accepts both); `scripts/test-examples.sh`
  takes `--prove-failure` and nothing else. So `--prove-failure` handed to `test-classic.sh`,
  and either of the other two handed to `test-examples.sh`, is not an error — the argument is ignored, the suite runs normally and
  exits 0, and the run is indistinguishable from a ProveFailure that worked. Only
  reading the output for the words ProveFailure prints, and finding NOTHING, catches
  it. Check the flag in the script before quoting its exit code.
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
- **A TEST WRITTEN AFTER A DEFECT RECORDS THE DEFECT, and this is a pattern here,
  not a run of accidents.** Four expectations in this tree asserted a wrong answer
  as correct, and each of them then guarded it:
  - `tests/suite/51_arith_faults.bas` pinned `(10.0 ^ 30) mod 2.5` at 0. Zero is
    not the remainder of anything; it is what `a - b*Int(a/b)` degenerates to once
    `a` is large. The case had been written to prove the quotient is no longer
    NARROWED to Int64 -- which it did -- and it recorded the surviving rounding as
    if it were the arithmetic.
  - `tests/probe_value.lpr` pinned the same operator twice, `1e308 mod 1e-308`
    expecting `peIntOverflow`. That one sat directly under a
    `ValDivReal(1e308, 1e-308)` overflow assertion that really IS correct, which
    is exactly how it read as right.
  - Block K of `scripts/test.{ps1,sh}` required a packed application truncated
    past its magic to behave as the CLI -- a damaged MyApp.exe handing a user a
    BASIC prompt, at exit 0, asserted as the expected behaviour.
  - `54_onerror_reentrancy` asserted `ginner`/`gouter` at 10, which is the answer
    a loop gives when `resume next` cuts it off after one pass. The correct answer
    is 0.

  None of the four was careless. Every one was written by reading a run and
  recording what it printed, which is the natural way to write a test and the
  reason the shape recurs: the implementation is the only oracle in the room, so
  the assertion becomes a photograph of it. **DERIVE THE EXPECTED VALUE
  INDEPENDENTLY.** Where the operation has an external definition -- IEEE, POSIX,
  the RTL's own documentation -- pin it against that, and against a second path
  through the engine that reaches the same answer another way; `CheckFloatRemainder`
  is built on exactly that and compares against C/Python `fmod` as well as the
  invariant `0 <= |r| < |b|`. Where it does not, write the arithmetic out in a
  `rem` beside the assertion, choosing operands whose answer is exact in any float
  width, so the next reader can check the number without running anything. A
  golden read off a run is a record of behaviour, not of correctness.
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
- **AND A GATE'S REACH IS A CLAIM OF THE SAME KIND.** `check-codepage.py` opens
  with "The rule is absolute on purpose -- ASCII-only sites are flagged too" and
  then skips every assignment that is not an accumulate, so a site of exactly the
  class it exists for sat in `engine/PhosphorLexer.pas` for the life of the gate.
  Measured by importing the gate and calling its own `scan` and
  `char_operands` on the pristine file: `char_operands` answers `['c']`, and
  `scan` never asks it. A gate is proof of what it READS, and what it reads is
  not what its header says it covers -- so when you write one, feed it a site it
  must catch and watch it catch that site.

### Every path a human can reach must have something that reaches it too

The two defects the owner found by hand in one afternoon were both on paths no
automated thing executed: the Windows key encoder (needs a keypress) and
`phosphorgui` (which nothing ran). Neither was a weak test; neither had a test.

- **Ask of every program in the tree: what runs this?** If the answer is "a
  person", that is the bug, before any line of it is read. `examples/` had seven
  programs and no runner while `tests/` had six corpora and five runners.
- **Split the decision from the I/O.** The part of a human-facing path that is a
  pure function of its inputs — which key this event means, which colour this
  attribute maps to — comes out into a function a probe can call with no console,
  no display and no person. What is left should be a handful of lines with no
  decisions in them.
- **A seam left nil answers silently.** The engine offers `OnOutput`, `OnInput`,
  `OnBreakpoint` and `HostServices` and installs none; leaving one nil is a
  designed behaviour for a headless runner, which is exactly what makes the nil
  case look like the working case. `scripts/check-seams.py` makes every host
  answer for every seam, once, in writing.

### A destructive defect is verified by READING

A finding whose CONTENT is destruction — it deletes, it overwrites, it sends — is
confirmed by reading the code, or by running the repro only after the fix is in a
**rebuilt** binary, or in a disposable VM. Never on the working machine, and never
"in a sandbox directory": on 2026-09-05 the sandbox directory protected against a
CWD-relative walk and the defect was drive-root-relative, so it walked `C:\`.

Two mechanical parts of that, both paid for:

- **Check which binary a script builds before trusting it.** `test-suite.ps1`
  builds `phosphortest`; only `build.ps1` builds `phosphor.exe`. Running the one
  the suite did not rebuild is running the old code, defect included.
- **Test a destructive guard through its NON-destructive path.** The guard runs
  before the recursive branch, so proving `dir_delete("")` is refused proves
  `dir_delete("", 1)` is too — and the test is never one edit away from being the
  disaster it tests for. Where the destructive path itself must be exercised, the
  test creates its own victim, outside the root and inside the platform temp
  directory (`tests/probe_sandbox.lpr`), so the blast radius is what the test made.

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

## What the 2026-09-06 gauntlet left open

The whole-tree adversarial sweep returned 59 confirmed findings. As of 2026-09-10
the crashes, the seven security and data-loss findings, all 21 wrong answers and
every one of the 59 is closed on both operating systems. **The list below is
kept as the record of what was found and what it cost; nothing on it is open.**
It was written when nineteen remained, and they are
listed here rather than in a task tracker because this project has learned that a
backlog nobody can find is a backlog that does not exist.**

Some may already be closed by later work: the budget landed after the sweep ran,
and it plausibly reaches both hangs. **Verify before fixing** -- closing something
already closed is how a patch introduces a defect.

~~**Four wrong answers, in the front end**~~ -- CLOSED 2026-09-09. The GOTO
refusal was narrowed to the jumps that PROVABLY never return, discriminating on
the opcode at AddGoto: opJump is refused, opGosub and opSetErrHandler are not.
The first version refused all of them and its reviewer measured twelve programs
that answer correctly without the check; all twelve are pinned now, and both
refused shapes have a negative test, because they reach the check from two
different procedures and one file cannot cover both.

**WHAT THAT LEFT OPEN, and it is the honest residual.** The opcode is a BOUND,
not an equivalence. opGosub and opSetErrHandler come back only when their TARGET
does, which the call site cannot see: a subroutine ending in `goto` instead of
`return`, and a handler that never reaches `resume`, abandon the activation
exactly as `goto` does. Measured on both operating systems -- `on error goto h`
inside a function, handler falling through to the end of the program, run under
callfunc, prints the tail TWICE, byte for byte the wrong answer of this defect's
own repro. It is NOT a regression: the tree before the check behaves identically,
and refusing it at compile time is what cost the first version its twelve correct
programs. **The repair belongs in the VM**, which can see at fault time what the
compiler cannot -- that a handler jump crossed a frame boundary.

~~**Two hangs and a breakage**~~ -- ALL CLOSED 2026-09-10, which empties the
2026-09-06 sweep's backlog.

BREAK inside a function DEFINED in a loop body bound to the enclosing loop.
ParseStatement accepts a `function` wherever a statement may appear, so the body
was compiled with the enclosing loop still counted and `break` was fixed up to
jump past it -- with the function's frame still pushed, so the tail of the
program ran again and again. 262,146 lines in six seconds, no error, no exit.
This is the GOTO defect of 2026-09-09 in different syntax and one sentence closes
both: **the compiler must scope control-flow targets to the function being
compiled.** ParseFunction saves, zeroes and restores the loop depth; `break` in a
function body meets the check that already existed. tests/negative/31 pins the
refusal, four assertions in 02_control_flow pin what must stay legal -- including
an outer loop whose body DEFINES a function, which is what proves the depth is
restored rather than discarded.

app_quit() did not wake app_run(). The loop was one call to
Application.HandleMessage -- AppProcessMessages, then Idle(Wait=True) -- with
**nothing in between**, and a script's app_quit always runs inside a dispatched
event. The flag was set, correct, and unread while the loop blocked in
AppWaitMessage for a message that with no window shown never came. Waking it does
NOT fix this and was tried first: Idle runs ProcessAsyncCallQueue BEFORE the wait
(application.inc:471), so a queued nudge is consumed on the way in. **Reading the
flag between dispatch and wait is what closes it.** Nothing is polled and nothing
is slept.

Closing ANY window called Application.Terminate, so two things were wrong on one
line. Termination is documented as belonging to the LAST window, and that flag
has no public way to be cleared -- round 28 records that exact defect as fixed
for app_quit, and it was; the fix landed there and this second caller kept doing
it. Closing is now GuiLeaveLoop, and only when nothing else is still shown.
Finding the other windows took two wrong answers worth recording:
Screen.CustomForms does not hold a form this host showed headless, and the handle
registry holds a TGuiHandle WRAPPER, so walking it and testing `is TForm` finds
nothing ever. GuiCore answers it, because unwrapping is its business.

A THIRD caller of Application.Terminate was found while fixing those two and
closed with them: `end` inside an event handler. Same poison, same host running
one script after another. AVM.Halted is already set, so leaving the loop is all
that was needed; ending the process happens on its own.

tests/gui/21_loop_lifecycle.bas pins all four, and the fourth is the mirror:
closing the LAST window must still end the loop, or one hang has been traded for
another.

**Blind spots in the gates, and each one means a gate reports a pass it did not
earn.** ~~test-packages silently skips the whole SQLite corpus on a Windows box
where SQLite works~~ -- CLOSED 2026-09-10, and it was worse than recorded: THREE
corpora and **169** assertions, not 85, including 10_sqlite_sandbox, the entire
corpus for the SQLite half of the security work. The runner guessed by path --
two directories on Windows, ldconfig plus seven on Linux -- and the Windows guess
missed the PATH, where this machine's copy lives. Both sides now ASK the binary
(`phosphorpkgtest --sqlite-check`), which is what the OpenSSL branch in the same
file had always done. All 169 pass and match their goldens; no defect was hiding.
**A guess about where a library lives is not a gate.**

~~check-suffix.py hardcodes the parameter name `Args`, and cannot see a computed
registration at all~~ -- BOTH CLOSED 2026-09-10, and the first was bigger than
recorded. Of the 407 handler bodies under host/gui/libs, **352 call the parameter
`A`**, 54 call it `Args` and one calls it `AArgs`; every `A[0]` was unreadable, so
the gate resolved 1031 of 1232 and called the other 201 indeterminate. The name is
written on each routine's own header and is now read from there: **1206 of 1260**,
44 indeterminate, and not one of the newly-visible registrations was lying. The
computed ones -- `Names[s] + ':$'`, `OptPaths[i] + ':'` -- were neither judged NOR
COUNTED, so they were absent from the one line anybody reads; the arrays are read
with the same two patterns coverage.py uses, so the two gates now enumerate the
same registry, and an array a registration names but the file does not declare is
REPORTED rather than skipped. Both proven by planting: a `$`-named GUI function
returning `A[0]` (a handle) is caught with file, line and signature where the old
gate exited 0 saying "every one returns what its name says"; a renamed array
fails the gate by name.

~~test-suite never builds bin/phosphor.exe but runs check-examples.py~~ -- CLOSED
2026-09-10. Building it is scripts/build's job and stays there; what the gate
lacked was a way to NOTICE. It now refuses a binary OLDER than the newest engine
source and says which file is newer, so an engine edit followed by the suite is a
loud failure instead of every documentation example being compiled by yesterday's
compiler and reported as a pass. The same trap CLAUDE.md records for
phosphortest.exe, which cost four wrong conclusions in one day.

~~check-seams.py's SEAM_TYPES is a hardcoded literal~~ -- CLOSED 2026-09-10, and
the comment ABOVE the list already claimed it was "read from the source rather
than listed here, so a seam added to TPhosphorEngine cannot be missed". The
comment described the gate somebody meant to write; the code was the one that got
written. A seam is now derived structurally: a method pointer (`of object`)
declared under engine/, or a record whose fields are all method pointers. Proven
by planting a new seam type and property -- the old gate exits 0 reporting "5
seams filled", the new one names every host that leaves it nil. The gate also
caught the first version of its own derivation, which missed
TPhosphorBreakpointProc because a Pascal parameter list contains semicolons.

~~check-codepage.py scans line by line~~ -- CLOSED 2026-09-10. A line that cannot
stand alone -- ending in an operator, an assignment, a comma or an open paren --
is joined to the next, and the report keeps the line the statement STARTED on.
The join is deliberately NARROW: running the pattern over the whole unit with
DOTALL was tried first and is wrong, because the expression then runs to the next
semicolon, which in an if/else chain is the end of the whole chain -- and
Utf8Char, the one function that must build raw bytes and does it correctly, was
reported as a defect. Proven by planting `Result := Result +` / `c;` across two
lines: the old gate says "no char-into-string concatenation found", the new one
names file, line, function and operand.

**All six gate blind spots are closed.**

~~**Three test gaps**~~ -- ALL CLOSED 2026-09-10.

The sandbox's strongest claim -- a link planted INSIDE the root and pointing out
of it, where every component of the path as written is inside and only resolving
it shows otherwise -- was asserted on Unix and skipped on Windows, because
creating a SYMLINK there needs SeCreateSymbolicLink. True, and the wrong
conclusion: a directory JUNCTION redirects a directory just as well, `mklink /J`
makes one with no privilege at all, and it is therefore the form a confined
script or a careless user can actually create. Six assertions now run on Windows
(probe_sandbox 131 -> 137) and the skip line is gone. Proven to measure something
by disabling link-following in the sandbox: the read comes back with the contents
of the file OUTSIDE the root, the write answers 1, four assertions go red.

No manifest-driven corpus checked that its manifest covered its DIRECTORY. A file
containing `assert_int(1, 2)` -- an assertion that cannot pass -- was dropped into
tests/packages and the runner printed PACKAGES OK. **scripts/check-manifests.py**
is the eighth gate and checks both directions across all four manifest-driven
corpora: a .bas nothing lists is a test nothing runs, and a listing with no file
behind it is a skip nobody asked for. Duplicate entries too, which read as two
passes. tests/classic and tests/negative are named in NO_MANIFEST with the reason
rather than left out silently.

coverage.py counted tests/negative/*.bas -- programs the suite requires to be
REJECTED -- as coverage. It was crediting exactly one function: `arr_free`
appeared nowhere else in the tree, so the only thing proving it worked was a file
asserting that it does NOT. The corpus now excludes negatives, which dropped the
figure to 714/715 and named the hole; tests/suite/04_arrays.bas exercises it for
real, including catching the revocation with `on error` inside a running program
rather than by a file that must fail. Back to 715/715, honestly.

~~**Three documentation errors**~~ — CLOSED 2026-09-08, and two of them became
rules rather than edits. The lexer's header claimed a doubled quote was the only
escape, "since '' is now integer division", which docs/decisions.md:155 records
as SUPERSEDED on 2026-09-02; it now names the escape set the scanner implements.
sys.md said 22 functions where its unit registers 40, and coverage.py's count
check was a hand-written table covering README and architecture.md -- two of
forty-two places, which is a sample and not a gate; it now derives every library
page's header count from that page's own unit, and a page that stops STATING one
fails too. gzip.md said a 19-byte empty stream; measured, it is 20 (and 23 at
level 0). README's gate heading said six where the suite runs seven -- and the
paragraph under it had PREDICTED that, saying nothing checked the list and naming
the last two gates that had joined unannounced; coverage.py now counts the gates
test-suite actually runs.

---

## What the 2026-09-10 gauntlet found


The second whole-tree adversarial sweep, run after the 2026-09-06 backlog had been
emptied and with every suite byte-exact green on both operating systems. Fourteen
file-disjoint lanes attacked ~40,000 lines; every claim then went to two
adversarial refuters -- one that reran the reproduction, one that hunted for proof
the behaviour was intentional or already closed -- and a split vote went to a
tie-breaker. **78 claims, 65 confirmed, 13 refuted.** 22 high, 25 medium, 18 low.

Two things about the shape of the result are worth more than any single finding.

**A green suite told us nothing it had not told us the day before.** The tree was
clean-building with zero notes, byte-exact on Windows and Linux, eight gates
passing, with `-ProveFailure` seen catching a corruption -- and it was hiding a
hang, four crashes, five sandbox escapes and twenty wrong answers. The rule in
section 0 is not a slogan.

**The refuters earned their place.** 13 of 78 killed is a real rejection rate,
against the round where refuters killed 0 of 45 and were measuring nothing. Three
survivors were also CORRECTED by their refuters rather than accepted as written --
a severity lowered, a mechanism restated, an anchor moved to the file that
actually holds the defect -- and those corrections are carried in the list below,
not the finder's original wording.

Anything not yet struck through is OPEN. Verify before fixing: a finding is a
report, not a diagnosis, and closing something already closed is how a patch
introduces a defect.


### Security and sandbox escape (5)

1. ~~**engine/PhosphorSandbox.pas:310** [high]~~ -- CLOSED 2026-09-10. Resolution is
   one LEFT-TO-RIGHT walk now: each component's links are followed before the next
   component is applied, so a `..` comes off what the link resolved to. The
   splitter is the kernel's as well -- on POSIX only `/` separates, because a
   backslash there is an ordinary filename byte and reading it as a separator let a
   `..` be counted against the wrong depth. Both halves were needed and the second
   was found by a test, not by reading: the fix for the ORDER reused the SPLITTER,
   and the same escape was still live. See the invariant in section 2.
2. ~~**engine/PhosphorSandbox.pas:378** [high]~~ -- CLOSED 2026-09-10. A path holding
   a `#0` is refused outright, for a READ as well as a write, in both the perilous
   rule and the gate: no caller can mean a name with a NUL in it, so this refuses
   rather than guess where to cut.
3. ~~**host/console/phosphor.lpr:1016** [high]~~ -- CLOSED 2026-09-10. The question
   is "was the flag given", not "is the value non-empty" -- `GSandboxGiven` carries
   the fact the value could not, because `''` is how "no sandbox" is spelled too.
   `--sandbox ""` now prints `phosphor: cannot establish the sandbox root <dir> --
   refusing to run unconfined` and exits 2, exactly as `--sandbox "   "` already
   did. `--out ""` had the same shape one branch down and is refused with it.
4. ~~**host/packages/PhosphorZipLib.pas:456** [high]~~ -- CLOSED 2026-09-10. The
   local file headers are read up front and the names extraction will actually use
   are judged: each must pass `SafeEntryName` AND be byte-identical to the name the
   central directory advertised. A link entry is refused outright on both operating
   systems -- its target is its content, which no name check can see. An archive
   that merely could not be re-read is answered `0`, not accused. See the invariant
   in section 2.
5. ~~**host/console/phosphor.lpr:845** [medium]~~ -- CLOSED 2026-09-10. The stub
   carries a 24-byte mark in its own initialised data, where truncation cannot
   reach, holding the length the packer finished with; a marked binary whose length
   or trailer disagrees exits 2 with the reason. Falling through to the CLI now
   requires an UNMARKED binary, which is the only file that is genuinely a bare
   stub. Applications packed before this date carry no mark and keep the old failure
   mode -- repack them.

### Data loss (9)

6. ~~**engine/PhosphorSandbox.pas:245** [high]~~ -- CLOSED 2026-09-10. A path this
   unit cannot resolve to ONE directory is refused rather than assumed ordinary:
   the walk records the link it could not follow, and both rules read that. Unable
   to say is not permission -- but it is not licence to refuse either, and the
   first spelling of this fix refused 42 of the 62 entries in
   `%LOCALAPPDATA%\Microsoft\WindowsApps` -- every reparse point in it -- so an
   entry the platform resolves to the very path already built (a Store app alias, a
   compressed or cloud-backed file, any reparse tag FPC declines to decode) is
   ordinary and is allowed. **Both of those numbers were wrong here first**: the
   review measured 42 of 62, the source comment said "eight of the ten", and this
   page copied the comment rather than the measurement. Corrected in both places.
   The cost is in `docs/embedding.md` and is not one number: a read with no root
   set touches no disk, a write to a path that is not a directory is one
   `FileGetAttr` (~20 us), and a write or delete NAMING A DIRECTORY -- every
   `dir_create`, every `dir_delete`, which is what this rule exists for -- walks
   every component, 175 us at depth three and 825 us at depth twelve.
7. **engine/libs/PhosphorIoLib.pas:622** [high] -- On Linux file_move overwrites an existing target file and reports 1; dir_move does the same onto an existing EMPTY directory -- docs/libraries/io.md:59,102 promise 0 in both cases (Windows refuses; the refusal is an accident of MoveFileW)
8. **engine/libs/PhosphorJsonLib.pas:1311** [high] -- A tail fpjson ignores disarms the \u re-spelling: unmatched quote or apostrophe after the value silently restores all four fpjson escape defects on a document json_parse@ accepts with rc=0
9. ~~**engine/libs/PhosphorStrLib.pas:516** [high]~~ -- CLOSED 2026-09-10, as a
   consequence of 34 rather than by anyone aiming at it, and MEASURED here on
   2026-09-11 rather than assumed. The mechanism was the delegation itself:
   `DoReplace` handed the job to the RTL's `StringReplace` with `rfIgnoreCase`,
   which finds every match on an `AnsiUpperCase` copy and then copies bytes out of
   the ORIGINAL at the positions it found -- and `AnsiUpperCase` is not
   length-preserving over UTF-8. Rewriting the case-folding family removed that
   delegation, so the defect went with it.

   The finding's OWN reproduction: `replacetext$(U+017F + "abc", "abc", "Z")` was
   `C5 5A 63` -- the second byte of the character destroyed, a stray `c` appended,
   the result no longer valid UTF-8 -- and is now `C5 BF 5A`, which is what
   `replacestr$` always answered. Its sweep over codepoints 128..66000 found 11
   where `replacetext$("x" + C + "y", C, "Z")` was not `"xZy"`; it finds 0.

   MY FIRST TEST FOR THIS SAID IT WAS FIXED AND PROVED NOTHING. It used characters
   whose uppercase is the same length, so the pristine build answered identically
   -- which is what running it against the pre-change binary showed, and why that
   comparison is worth the three minutes every time.
10. **host/gui/libs/PhosphorControlLib.pas:301** [high] -- control_free on a node@ or an item@ destroys it (and the subtree it owns), answers 1 with gui_error 0, and leaves a live child handle that access-violates on the next read
11. **engine/PhosphorValue.pas:632** [medium] -- str$/print/print# format a Double with FloatToStr's 15-significant-digit default, so most computed Doubles silently change value across a str$/print#/input# round-trip, and str$(MaxDouble) rounds up past MaxDouble into text val() rejects as an overflow
12. **engine/libs/PhosphorConfigLib.pas:83** [medium] -- cfg_save mangles `#` comments inside a section into `=<text>` and drops `#` comments before the first section
13. **engine/PhosphorEngine.pas:286** [low] -- PhosphorHandles' table is one process-wide global: any engine's Run/Prepare/Finish frees every other live engine's handles, and only the docs' opposite promise (embedding.md 49/65/74) is on record
14. **host/packages/PhosphorGzipLib.pas:338** [low] -- A gzip_decompressfile refused by the budget has already written its truncated 256 MB inflate over the destination -- the refusal is announced after the damage, and embedding.md promises "nothing has been spent"

### Crashes (4)

15. ~~**engine/libs/PhosphorJsonLib.pas:633** [high]~~ -- CLOSED 2026-09-10. The
   scan holds its opening delimiter in a `Char` and closes on the SAME one, which
   is what `JsonHasUEscape` and `JsonRespellText` have done all along and say so in
   their own comments. This was the third scanner and the only one that had not
   been brought along -- the completeness half of one defect, three times. The
   hostile document and the same nesting without its prefix now get the identical
   refusal, which is what makes it a bypass rather than a difference of opinion
   about the document; and a single-quoted key still parses, because the scan
   learned the delimiter, not to refuse it.
16. ~~**engine/libs/PhosphorJsonLib.pas:1682** [high]~~ -- CLOSED 2026-09-10, and
   the gate went where the graft happens rather than on the doors. THIRTEEN
   functions add a node to a tree; guarding thirteen doors is how this project has
   written defects before, so `SetMember` and a new `AddItem` take the target's
   level and answer False, and every door goes through one of them. A refused node
   is freed there -- the caller had already built or cloned it, and a refusal that
   leaked would be worse than what it refused.

   THE HARD PART WAS KNOWING HOW DEEP THE TARGET IS. fpjson nodes carry no parent
   pointer, and measuring the owning tree per graft would turn a loop of N pushes
   into O(N squared). So `TPhosphorJson` records a `Level` when the handle is
   BORROWED -- one addition, and exact, because a live node's depth never changes:
   nothing here re-parents a node (every graft clones) and deleting an ancestor
   frees the node and empties the handle. `json_path@` adds one level per segment,
   not one in total.

   Measuring only the SOURCE's depth would have looked sufficient and was not: it
   stops the doubling trick and misses a plain loop that nests one level at a time,
   which is the shape the finding says an ordinary script hits by accident.

   THE REVIEW ACCEPTED THE CODE AND REJECTED THE TESTS, which is the useful half.
   No bypass, no over-refusal (599 lines of legitimate JSON work byte-identical to
   the pristine build), no leak, no measurable cost. But FIVE mutations survived
   all four runners: dropping the level at `json_get@` (though the same omission at
   `json_item@` was caught -- covered by accident at one door and not the other),
   neutering `JsonPathSegments`, pointing `json_merge@` at the source's level,
   deleting the two `V.Free` calls on refusal (4.2 GB against 13.9 MB), and
   lowering the graft ceiling from 256 to 220 -- 36 levels of silent over-refusal
   that `assert_true(built > 200)` could not see.

   All five are pinned now. `RegJson`'s level lost its default, so the omission is
   a compile error rather than a test's problem; the band became
   `built = 255`; three assertions pin the path level, the merge level and the
   agreement of two routes to one node; and the leak, which no assertion can see,
   is a check in `probe_limits` -- run the same work at 200 refusals and at 10,000
   and compare what is still allocated once the engine is freed. 4,948 KB with the
   Free, 245,573 KB without.

   WRITING THAT LEAK CHECK COST TWO GREEN RUNS, and the reason is worth more than
   the check. It measured 200 refusals against 1, because `resume next` on the LAST
   statement of a block leaves the block -- finding 7 of this very sweep, still
   open -- so the loop ran one pass and reported success. It passed with both Free
   calls deleted, twice, before the refusal count was printed. A probe that cannot
   fail is the thing this round is about, and it very nearly shipped inside the
   fix for it.
17. ~~**engine/libs/PhosphorJsonLib.pas:1789** [high]~~ -- CLOSED 2026-09-10 by
   REFUSING, not by snapshotting. `s.Count` was read once and `s` dereferenced
   every turn; merging an object into its own ancestor makes `SetMember` free the
   very node `s` points at, and `InvalidateBorrowed` protects HANDLES, not this
   library's own local. Snapshotting the pairs first would have stopped the crash
   and left a defined result nobody asked for -- the source flattened into the
   target as a side effect of destroying it. Overlapping trees have no merge that
   means anything, so both directions and the degenerate self-merge are refused as
   a value, using the `NodeContains` the borrow machinery already had.
18. **engine/libs/PhosphorStrLib.pas:860** [high] -- center$ with a saturating negative width wraps `pad := w - CpLen(s)` in 32-bit arithmetic and builds a 2 GiB string instead of returning the string unchanged (wrong answer + unbounded allocation, not a crash)

### Hangs (2)

19. ~~**engine/PhosphorCompiler.pas:534** [high]~~ -- CLOSED 2026-09-10, and it is
   the third time this one sentence has had to be written down: **the compiler must
   scope control-flow targets to the function being compiled.** The GOTO refusal of
   2026-09-09 applied it to labels, the BREAK fix later the same day applied it to
   the loop DEPTH -- and the depth is not the state. `FLoopBreaks`/`FLoopConts` are
   indexed BY that depth, and `PushLoop` clears the slot it is about to use, so the
   first loop inside a function body, pushing at depth 0, erased the ENCLOSING
   loop's recorded break sites. `PatchBreaks` then patched an empty list, the outer
   `break` kept its placeholder operand of 0, and jumping to instruction ZERO
   restarted the whole program: five seconds is five megabytes of output, with no
   error and no exit. `PopLoop` only decrements, so the slot afterwards held the
   function's own already-patched sites, which the enclosing loop re-patched to its
   own exit -- the 262,146-line symptom of the day before, back by another road.
   `ParseFunction` now saves the lists and NILS them, so `PushLoop` allocates fresh
   storage and the enclosing loop's lists cannot be reached from inside a function
   at all. Three assertions in `02_control_flow` (golden 23 -> 26), and each one
   needs the inner LOOP: the assertion added the day before passed throughout,
   because the function it defined inside a loop had no loop of its own.
   **Yesterday's fix was tested by the case that could not fail.**
20. **engine/PhosphorRegistry.pas:363** [medium] -- Overload resolution runs 2^(int-args) linear scans of the 1232-entry registry on every library call with no cache, so the idiomatic integer subscript costs ~50 us per array write and makes identical work 21x slower (1.01 s vs 21.02 s)

### Wrong answers (20)

21. ~~**engine/PhosphorVM.pas:1632** [high]~~ -- CLOSED 2026-09-10. `resume next`
   found "the next statement" by scanning forward for the next `opStmt`, which is
   a TEXTUAL successor: only ParseStatement emits one, and the code a block
   generates for itself carries none. So past the last statement of a `then` block
   the scan found the `else` block, past a case arm the next arm, and past a loop
   body the statement AFTER the loop -- the increment and the back-jump stepped
   over. A fault on a block's last line ran the branch not taken, ran the arm that
   did not match, and abandoned a loop after one pass, silently, exit 0.

   THE COMPILER KNOWS THE ANSWER AND NOW WRITES IT DOWN. `ParseStatement` patches
   each `opStmt`'s A with the pc that statement's code ends at, which IS the
   control-flow continuation by construction: at the end of a `then` block it is
   the jump over the `else`, at the end of a case arm the jump to `endselect`, at
   the end of a loop body the loop's own tail. Executing it does the right thing
   without the VM knowing anything about blocks. The scan stays for A = 0, which
   is a failed parse or a .pbc written before this.

   AND THE SUITE HAD PINNED THE DEFECT. `54_onerror_reentrancy`'s `ginner`/`gouter`
   asserted 10 -- the answer a loop gives when it is cut off after one pass. The
   correct answer is 0, and the expectation is corrected with the arithmetic
   written out beside it. Six assertions pin the fix, including that a fault in
   the MIDDLE of a block still resumes on the next line.
22. ~~**engine/PhosphorVM.pas:2810** [high]~~ -- CLOSED 2026-09-10, and it was
   WORSE THAN REPORTED. The finding says "after any `end`". Measured: a script
   written the way docs/language-reference.md teaches -- top level, then `end`,
   then the functions -- had its FIRST `CallFunction` answer 0, and a `$` function
   handed the host a `vkDouble`. The documented idiom and the documented embedding
   flow met at a flag nobody cleared, so the worked example only passed because it
   had no `end` in it.

   THE CLASS: `opHalt` sets FHalted and only ONE of the three entry points into
   execution cleared it. `Run` did; `RunFrom` (a REPL line) did not; `CallUserFunc`
   did not, and read the flag AFTER running a body -- so a halt raised by a
   previous call was taken to mean "this call halted", the body ran with all its
   side effects, and the real return value was dropped by the finally's
   `FSP := savedSP` with Err left NoError.

   All three answered. `RunFrom` clears it, because `end` ends the LINE that ran
   it and the prompt is still there. `Prepare` calls the new
   `TPhosphorVM.EndOfTopLevel` after a top level that completed, because the top
   level finishing is not the program being over. `CallUserFunc` refuses BEFORE
   pushing a frame, so nothing runs at all, and `TPhosphorEngine.Halted` lets a
   host ask rather than be told. The two meanings of `end` are now written down in
   both documents that teach it.
23. ~~**engine/libs/PhosphorNumLib.pas:49** [high]~~ -- CLOSED 2026-09-10. All four
   widened an `int%` to a Double before converting, which is wrong in both
   directions at once: above 2^53 a Double cannot hold every integer, so the value
   was silently changed (`round(9007199254740993)` answered ...992); and near
   High(Int64) the nearest Double lies ABOVE the range, so `InI64Range` refused a
   number that was never out of range (`round(9223372036854775806)` answered error
   1, for a value one below the top). `docs/libraries/num.md` promises both halves
   and neither was true. Rounding, truncating and flooring an integer are the
   identity, so the fast path is the correct answer and the cheap one -- ArgI64's
   rule, which has had it all along. Twelve assertions, including that the four
   still differ on a fraction, because an identity is only an identity for an int%.
24. ~~**host/gui/libs/PhosphorCanvasLib.pas:271** [high]~~ -- CLOSED 2026-09-10.
   Both passed `n - 1` where `NumPts` reaches `Windows.Polyline`/`Polygon` as
   cPoints, the NUMBER of points -- read in
   `lcl/interfaces/win32/win32winapi.inc`, not assumed -- while `ParsePoints`
   returns N as a count. The last vertex was dropped: a two-point polyline drew
   NOTHING and reported success, and a four-vertex square drew as a triangle. Nine
   assertions read the pixels back off the bitmap, headless, including the bottom
   and left sides of that square.
25. ~~**engine/PhosphorBudget.pas:975** [medium]~~ -- CLOSED 2026-09-10. `BranchOverflow` on TReLevel records "I could
   not judge this": set in the `|` case when the branch count passes
   `MaxReBranch`, cleared in `ResetLevel`, read by the refusal guard. So the
   branch table gives up toward ALLOW like the atom table beside it and like the
   unit's own header. Measured against the pristine build over 256 patterns --
   alternations of 1..26 branches in three families (disjoint characters,
   overlapping word bodies, greedy bodies), each with `+`, with no repeat, with
   `{10}` and nested one level, plus probe_budget's 40-pattern real-world corpus:
   50 REFUSE -> ALLOW, 0 ALLOW -> REFUSE, and nothing at 16 branches or below
   changed verdict at all.

   **THE HOLE IS WIDER ON PURPOSE, and the finding chose it.** Past 16
   alternatives a genuinely ambiguous repeat is now allowed too -- the sweep
   shows the overlapping family flipping, not only the disjoint one. That is the
   unit's stated contract, and the alternative is refusing a 17-verb HTTP method
   alternation for a reason that is not true of it, which is the failure mode
   this project names first. It is closeable without touching the contract:
   `BranchesOverlap` bails out entirely past `MaxReBranch + 1` branches, where it
   could soundly judge the TRACKED PREFIX instead -- an overlap between two of
   the first sixteen branches is a real overlap whatever the other branches are.
26. ~~**engine/PhosphorBytecode.pas:478** [medium]~~ -- CLOSED 2026-09-10. The function-entry bound is
   exclusive now (`>= AProg.Count`), with a message that names the valid range
   and a separate wording when the program has no instructions at all. The
   over-refusal question was measured, not argued: every `.bas` in tests/suite,
   tests/classic, tests/packages, tests/negative, examples and docs was compiled,
   serialized and read back through the real `ReadProgram` -- 119 files, 100
   compiled and loaded, 89 user functions, and the smallest `Count - Entry` gap
   anywhere is 4, at 11_callback_end.bas / quitter. A gap of 0 would be a
   legitimate file the new bound refuses; nothing comes near one. And because one
   off-by-one usually means a family, every bound this validator applies is now
   written into the policy comment with inclusive or exclusive stated -- which is
   how the handler target was found to have the same shape. See the new list
   below.
27. ~~**engine/PhosphorCompiler.pas:722** [medium]~~ -- CLOSED 2026-09-10. `FGotoLine` remembers the jump's line at
   `AddGoto`, where `FLex.Cur().Line` was already in hand and was being thrown
   away; `RecordLabel` takes the duplicate's own line. The line is a REQUIRED
   parameter with no default, because a default of 0 is the exact unsafe value
   this defect was made of. All six `AddGoto` sites and both `RecordLabel` sites
   pass a line they already held. `goto nowhere` on line 4 says line 4, a second
   `lab:` on line 4 says line 4, and `on error goto h` on line 2 of a function
   body says line 2 -- all three said "line 1" before. Fifteen label programs run
   against the pristine binary and the fixed one: every accepted program
   byte-identical, every refused one the same message with the true line.

   **NEITHER DIAGNOSTIC HAS A PERMANENT PIN, and that is the residual.** A `.bas`
   is dead before it can assert on a compile-time message, and the negative
   corpus is judged on the exit code alone, so a future edit could put the
   literal 0 back with every runner and all eight gates still green.
   `tests/probe_limits.lpr` is where these belong -- it already substring-matches
   a compiler message and exposes `ErrorLine` -- and they are not there yet.
28. ~~**engine/PhosphorVM.pas:1500** [medium]~~ -- CLOSED 2026-09-10 with 22: the
   same flag, the same cause, a different door. `RunFrom` resets the step counter,
   the output counter and the clock for each line and did not reset this. The tell
   was that it broke almost invisibly -- `println "plain"` still worked and
   `println len("abc")` printed nothing and reported success, because opCall checks
   the flag after each library call and leaves the line as though it had finished.
   `tests/classic/16_repl_after_end.repl` is that exact pair.
29. ~~**engine/PhosphorValue.pas:1077** [medium]~~ -- CLOSED 2026-09-10. `mod` forms no quotient
   at all. `DoubleRemainder` is binary long division that scales the divisor up
   to within a factor of two below the dividend and walks it back down halving,
   subtracting where it fits: every subtraction meets Sterbenz by construction
   and every scaling is a power of two, so no step rounds and no intermediate can
   overflow -- which REMOVES the spurious overflow rather than catching it. Its
   length is the exponent spread of two finite doubles, at most 2098 iterations
   for any input whatsoever, so it is bounded by the format and no script can
   lengthen it. Measured bit-identical to C/Python `fmod` on 400 random pairs
   spanning the whole exponent range and on every named case; probe_value runs
   4000 + 2000 pairs every suite run.

   **THE REMEDY WAS DEPARTED FROM TWICE, and both are measurements.** `Math.FMod`
   was READ before it was rejected, as the rule about this RTL requires: it is
   the identical formula (`rtl/objpas/math.pp`, `Result := X - Int(X/Y)*Y`), so
   "call the RTL" would have shipped all three wrong answers again. And the
   finder's Int64 fast path was not written, because the exact scaled subtraction
   subsumes it -- `1e16 mod 3` comes out of the general path as exactly 1 -- so
   the smaller change is the whole change. `Math.Frexp`/`Ldexp` were read and
   rejected too: `Ldexp` is `x * intpower(2.0, p)`, which overflows to +Inf for
   p >= 1024, exactly the scaling this needs.

   Over-refusal was swept, not sampled: 128,080 ordinary pairs (a in -200..200 by
   quarters, b in -4.0..4.0 by tenths) through the old formula and the new one --
   125,908 bit-identical, 2,172 differing only in the SIGN OF A ZERO, 0 differing
   in value. `ValToStr` spells both zeros `0`, so no golden can see the
   difference. **Both of this finding's wrong answers had been PINNED as
   expectations** -- see the note on that below.
30. ~~**engine/libs/PhosphorBufferLib.pas:718** [medium]~~ -- CLOSED 2026-09-10. The value is judged before
   `WriteRaw` is reached, and an unrepresentable one is a returned error naming
   it, so the buffer is left exactly as it was. That is the shape `buffer_setint`
   next door already had and the unit header already promised -- "never a raise
   and never a silent clamp". Swept over 91 decades from 1e-45 to 1e45 and the
   eight exact edges of a Single's range: only 1e39..1e45 and 3.5e38 changed, and
   each changed from writing +Inf to writing nothing. The largest finite Single
   (3.4028234663852886e38, both signs) and the smallest subnormal (1.4e-45) are
   still accepted and written. There is no refused band.
31. ~~**engine/libs/PhosphorConfigLib.pas:197** [medium]~~ -- CLOSED 2026-09-10, and the measurement confirms why the proposed
   remedy had to be replaced: `sysstr.inc` declares `maxdigits = 17` only under
   FPC_HAS_TYPE_EXTENDED and 15 otherwise, and `FloatToStrFIntl` clamps
   ffGeneral's precision to it. Over 299,832 random finite doubles,
   `FloatToStrF(ffGeneral, 17)` failed 281,619 round-trips on Win64 and 0 on
   Linux -- the same source line, two answers, which is the worst shape a fix can
   have in a project that ships on both. `NumToInv` keeps `FloatToStr`'s readable
   form when the bytes read back identically and falls back to `Str(V:24)` when
   they do not: 0 failures out of 299,832 on BOTH operating systems. The
   comparison is on the BYTES of the two doubles rather than `=`, which also
   makes a negative zero survive. Ordinary settings files are unchanged -- of 30
   stored values only the 6 that did not round-trip moved.
32. ~~**engine/libs/PhosphorDateTimeLib.pas:134** [medium]~~ -- CLOSED 2026-09-10. The nine
   date-TAKING functions that cannot survive `DecodeDate`'s Year=0 answer ask
   `SourceOk`, the guard `incmonth` and `incyear` already asked, moved up the
   unit so every caller can reach it. The guard is SYMMETRIC, so those nine now
   refuse an above-range number too, where they used to answer off the RTL's
   top-end clamp. That is a behaviour change beyond the half the finding reports
   and it was taken deliberately: the clamped answers were not uniformly right
   either, and `weekoftheyear(5000000)` answered 29556 on the pristine build,
   which is not an ISO week of anything.

   Over-refusal was swept, never a list: about 48,000 instants -- the whole span
   at stride 97, every day of the first and the last 401, a 2,001-day window
   across the 1899-12-30 epoch, that window again with +0.25 and -0.25 fractions,
   and the span again at stride 1009 -- accumulated into checksums with no
   on-error handler, so an in-range refusal aborts loudly instead of being
   counted quietly. Pristine against fixed: byte-identical. The sharpest case is
   in the suite, because noon on 0001-01-01 is -693593.5, a SMALLER number than
   its own midnight, and it is inside.

   The other half of the class is open. `yearof`, `monthof`, `dayof` and
   `formatdatetime$` still answer off the fictitious year 0 -- `formatdatetime$`
   renders the same unparseable `0000-00-00` that `datetostr$` now refuses,
   through a different door. docs/libraries/date-time.md says so.
33. ~~**engine/libs/PhosphorRagLib.pas:393** [medium]~~ -- CLOSED 2026-09-10. `ExtractKeywords` classifies CODEPOINTS, taking a
   character's span exactly as `Utf8Starts` takes it, so it agrees with `len()`,
   `left$()` and `mid$()` on the same string and stays total on the malformed
   fragments `bytemid$` and `buffer_slice$` can hand a program.

   **THE FINDER'S ONE-LINE REMEDY WAS MEASURED AND REJECTED.** "Keep every byte
   >= 128" makes a no-break space, an em dash, a curly quote and a fullwidth
   comma into word characters, so the words on either side glue into one token:
   on a three-document base the query `buttondoc<NBSP>zapiski` then found only
   one of the two documents its two ids name, where the same query with an ASCII
   space found both. So only a NAMED set separates and every other codepoint is
   kept, because throwing bytes away is the defect being fixed. Totality checked
   over all 256 single bytes between two ASCII words, 192 truncated lead bytes in
   three positions each, and codepoints 33..12400 -- no crash, no hang, no short
   answer, 340 classified as separators. The ASCII half did not move: pristine
   against fixed differs only on the non-Latin lines.
34. ~~**engine/libs/PhosphorStrLib.pas:554** [medium]~~ -- CLOSED 2026-09-10 with ONE rule, and it is the one this unit already
   owned. `containstext`, `startstext`, `endstext`, `strcmpi` and `replacetext$`
   fold through `Utf8CaseU`, the very function `aucase$` calls, so there is no
   second implementation to drift from; `SameText`/`CompareText` (a..z only) and
   `AnsiUpperCase` (a hook the PLATFORM installs) are both gone from the family.
   The cross-OS half was measured rather than asserted: a probe folding all 65536
   BMP codepoints and checksumming the result answers `changed=1128
   checksum=40774005D42ED26F` for `TCharacter.ToUpper` on Windows AND on Linux,
   against 34 and 31 changed with different checksums for the `AnsiUpperCase`
   control.

   **THE FINDER'S LITERAL REMEDY WAS A DENIAL OF SERVICE, and that is a
   measurement too.** Routing the family through a whole-string fold took 57 s
   where the old code took 0.055 s on `startstext(32 MB, "AAAAA")`, and 28 s on
   the matching `strcmpi` -- which under any TimeoutMs a host installs turns a
   working call into a peLimit, the very class of damage the patch exists to
   remove. So `startstext`, `endstext` and `strcmpi` fold only the stretch that
   can DECIDE the question (the needle's length for a prefix or suffix, the
   shorter operand for an ordering) through two non-allocating codepoint walks.
   Timings are back at 0.062 s, and a 4000-pair randomised property test says the
   bounded form answers exactly what the unbounded one does. `replacetext$` could
   no longer delegate to `StringReplace`, so it searches the folded bytes and
   copies the ORIGINAL bytes back out around each match, the two strings walking
   in step one character at a time.

   Over-refusal: all 9,025 printable ASCII pairs and 400 word pairs through all
   six functions, pristine against fixed -- zero differences. What DID change is
   stated because it is a policy choice the finding asked for: accented and
   non-Latin pairs now match where they used to differ, so a program relying on
   `strcmpi` separating "É" from "é" sees 0. `Utf8CaseU`'s per-codepoint append is
   now on the hot path of `containstext` and `replacetext$` as well, and measures
   12x slower than the RTL call it replaced on an 8 MB haystack -- the quadratic
   shape its own header warns about, still open.
35. ~~**host/gui/libs/PhosphorGuiCore.pas:649** [medium]~~ -- CLOSED 2026-09-10 by
   22, at the door instead of at this caller. `CallUserFunc` now refuses on a
   halted VM before it pushes a frame, so a handler dispatched after `end` runs
   NOTHING -- and every other caller of that seam gets the same guard, which is
   why it went there and not here. GuiCallBack still reads `AVM.Halted` after the
   call to leave the message loop; that part was already right.
36. ~~**engine/PhosphorCompiler.pas:2264** [low]~~ -- CLOSED 2026-09-10. The const branch
   asks `StoreCheck`, the routine an ordinary store asks, so a const takes the
   same coercion and the same refusal in the same words -- reported at the
   DECLARATION, which is the line the author has to change, instead of wherever
   the value first met an operator that cared. A 135-pair sweep of
   `const v<suffix> = <literal>` against `v<suffix> = <literal>` (27 literals x 5
   suffixes, comparing the verdict and, on success, the printed value) went from
   98 disagreements to 0, and every one of the 98 was the const ACCEPTING what
   the variable refuses. The change therefore deletes 98 wrong acceptances and
   introduces no new refusal: no `const` anywhere in the tree changes verdict,
   which `check-examples.py` independently confirms by compiling every ```basic
   block. `const i% = 1.5` now binds 2, which is the one line of it that changes
   what an accepted program computes. **The other unchecked binding is still
   open**: `function f(n%)` called with 1.5 does not take the coercion
   `n% = 1.5` takes.
37. ~~**engine/PhosphorLexer.pas:461** [low]~~ -- CLOSED 2026-09-10. `ByteHere` renders the
   offending byte numerically (`#233 (0xE9)`) unless it is printable ASCII
   33..126, where it is shown from a one-character String SLICE beside its number;
   `ColumnAt` adds the byte column, because a line number sends a reader to a line
   and no further when the character is invisible. Both the `unexpected
   character` and the `unknown escape sequence` messages use them, and the quoted
   form is built from a slice rather than a Char, so check-codepage.py's rule
   holds here by construction instead of by an argument about which bytes are
   safe. Over a sweep of 512 lexer refusals the distinct-message count went
   248 -> 415 with the refused SET byte-for-byte unchanged: 22 colliding groups
   became 0, the largest having been 129 different bytes all saying `unexpected
   character '?'`. Columns are identical on CRLF and LF files, measured on the
   same source written both ways. **NOTE that check-codepage.py could not see this
   site at all** -- its `scan` skips any assignment that is not an accumulate --
   so the class is still unguarded at that shape. See the new list below.
38. ~~**engine/libs/PhosphorStrLib.pas:562** [low]~~ -- CLOSED 2026-09-10. `isnumeric` tests the VALUE, so `"1e999"`,
   `"1e309"`, `"inf"`, `"nan"` and `"INF"` answer 0 and the documented
   isnumeric-then-val guard holds. The band a finiteness patch can flatten was
   swept rather than sampled -- every exponent from -400 to +400 in four
   spellings, plus 45 spellings people actually type, trimmed and untrimmed: 101
   lines moved out of 11,848 and every one is an intended change. Every NEGATIVE
   exponent is untouched, including 1e-320, 4.9406564584124654e-324 and 1e-400,
   which underflows to a finite 0 and is still accepted.
39. ~~**engine/libs/PhosphorStrLib.pas:956** [low]~~ -- CLOSED
   2026-09-10. Both clamp pos and count to what the string can hold BEFORE
   subtracting, which is the fix `f_mid` next door already carried.
   `delete$("hello", 2147483647, 2147483647)` answers `"hello"` where it used to
   answer `"hellohello"`. Swept over every (pos, count) in -3..13 on five strings
   including a multi-byte one -- 1,445 rows against the pristine build, zero
   differences anywhere in the in-range neighbourhood.
40. ~~**host/console/phosphor.lpr:546** [low]~~ -- CLOSED 2026-09-10. `IsBytecode` sniffs
   four bytes -- `PBC` and then the version byte -- so a source file whose first
   line begins with an uppercase identifier starting PBC runs as the source it
   is. **The finder's `Ord(buf[3]) < 32` was measured and found still to refuse
   two valid BASIC programs**: `PBC<TAB>= 3` and a line that is just `PBC` are
   both legal (the identical files written with the name XBC run and exit 0), and
   TAB, LF and CR are 9, 10 and 13. Those three are excluded. The price is one
   rule on the format -- `PBC_VERSION` must never become 9, 10 or 13 without
   changing this test -- and docs/decisions.md now records it where the format is
   frozen. A new lettered block O in BOTH scripts/test.ps1 and scripts/test.sh
   pins it and the mirror: a genuine .pbc is still read as bytecode, still runs,
   and still packs into a standalone executable. Line endings make the same block
   exercise a different half on each OS, because the bare-PBC file's fourth byte
   is CR on Windows and LF on Linux -- and without the fix the Windows half
   failed with "format version 13".

### Leaks and cost (3)

41. ~~**engine/PhosphorHandles.pas:45** [high]~~ -- CLOSED 2026-09-10. The table
   recycles slots through a free list and an id carries a generation in its high
   32 bits, so an id issued for a slot can never be issued again and a stale one
   decodes to a slot whose generation no longer matches. Enumeration is a
   doubly-linked list of the LIVE slots -- not a scan bounded by the count, which
   would have left the same defect for a program that creates a million handles
   and frees all but one. Measured here: 20,000 `json_setn@` after 200,000
   create/free cycles went from 8268 ms to 778 ms, and the table from 200,002
   slots to one. `tests/probe_handles.lpr` is new, 72 assertions.

   **THE REVIEW IS THE STORY.** The first version put the generation in the high
   32 bits and never checked that bit 63 stays clear. At generation 2^31 the id
   comes back NEGATIVE, `SlotOf` refuses anything below 1, and `RegisterHandle`
   hands out an id nothing will honour -- for an object that is live, unreachable
   and unfreeable. Worse, that dead slot is linked at the HEAD of the live list,
   so the whole enumeration truncates to one element: `InvalidateBorrowed` stops
   telling a borrowed JSON handle its node is gone, which is the access violation
   that function exists to prevent, and `GuiOtherFormShown` answers False with
   windows still on screen. **78 seconds of raw churn**, and the reviewer measured
   it rather than arguing it. `GEN_MAX` is `$7FFFFFFF` now and a `{$IF}` guard
   refuses a wider one at COMPILE time, because reaching the condition at runtime
   takes 87 seconds and no suite will ever pay that.

   Two more from the same review. `HandleObj` resolved the slot twice -- `IsHandle`
   then `SlotOf` again -- costing +41% on the hottest call in the unit; one
   resolution puts it 3% BELOW the pre-recycling code. And three of the original
   55 assertions could not fail: a mutation test found that a broken back-link, a
   dropped liveness test and an unvalidated `NextLiveHandle` argument all walked
   straight through. The three shapes that kill them are asserted now, and the
   mutation script is the proof: M3 reddens 2, M8 reddens 3, M15 reddens 1, and
   widening `GEN_MAX` fails to compile.

   What it costs, stated because the first version's comment sold only the win: a
   slot went from 8 bytes to 24, so a program holding a million handles LIVE pays
   25.2 MB of table against 8.39 MB. Bounded 24 in place of unbounded 8.
42. **host/gui/libs/PhosphorCanvasLib.pas:193** [high] -- image_setbitmap@ assigns a full surface copy into a TImage with no ledger charge, so live GUI surface accumulates while GuiChargeRoom reads zero
43. ~~**engine/PhosphorValue.pas:674** [low]~~ -- CLOSED 2026-09-10, and it was not
   low. The finding calls it "not a leak -- it is released", which is true and
   beside the point: the transient is EIGHT BYTES PER INPUT BYTE, on every len(),
   asc(), left$(), right$(), mid$() and pad. Under all four ceilings including a
   32 MB memory one, `s$ = string$(200000000, 65)` then `n% = len(s$)` reached a
   peak of 1716 MB and answered rc 0, scaling linearly to 4291 MB at 500 MB of
   string -- so it defeated the memory ceiling on the day that ceiling landed.
   `Utf8Len` counts in place instead of building a table it only measures: 190 MB
   and three times faster, byte-identical across all 138 .bas files under tests/.
   `Utf8Left` and `Utf8Right` still build the table, because they need the offsets.

### Gate blind spots (11)

44. **scripts/coverage.py:141** [high] -- coverage.py's "exercised by a test" loop globs only engine/libs and host/packages (line 141) -- the 426 host/gui/libs names are outside it, 76 of them are called by no .bas, and the gate still prints "every registered function is exercised by a test"
45. **engine/libs/PhosphorBufferLib.pas:436** [medium] -- buffer_indexof's 3-argument form bypasses the execution budget entirely -- a one-token escape from the ceiling that exists to make untrusted scripts safe to embed
46. **host/packages/PhosphorZipLib.pas:447** [medium] -- The decompression-bomb guard prices the work from the archive's own central directory: an under-reporting entry writes 1.99 GB in 8.3 s under a 256,000,000-unit / 2,000 ms budget
47. **host/packages/PhosphorZipLib.pas:840** [medium] -- zip_extract and zip_extractall never consult the execution budget: two of the three extractors walk into UnZipFiles/UnZipAllFiles unbounded, and check-budget.py cannot see them because they reach the unzipper through a field
48. **scripts/check-seams.py:212** [medium] -- check-seams.py:212 globs only host/**/*.lpr, so lazarus/demo/phosphordemorunner.pas -- a suite-built, documented host that fills OnOutput and leaves OnInput, OnBreakpoint and HostServices nil -- is outside the gate, while README.md and the playbook claim it covers "every host"
49. **scripts/test-examples.sh:28** [medium] -- Only test-suite.sh rejects an unknown ProveFailure spelling; test-examples.sh silently ignores the canonical `-ProveFailure` and prints EXAMPLES OK exit 0, test-classic.sh does the same for `--prove-failure`, and test.sh/test-packages/test-gui have no prove mode at all
50. **scripts/test-suite.ps1:220** [medium] -- test-suite.{ps1,sh} and test-gui.{ps1,sh} discard the -vewn log for nine sources and judge the build by file existence -- the class commit c65807a fixed only in build.* and test-packages.* -- and a live warning sits in scripts/probe_budget.lpr:588 because of it
51. **tests/gui/hostmode/gui.bas:5** [medium] -- tests/gui/hostmode/gui.bas touches no path, so the "the sandbox root reaches a GUI program" case passes identically with no --sandbox, with a bogus --sandbox, or with any root at all -- in scripts/test-gui.ps1:188 and equally in scripts/test-gui.sh:143
52. **tests/gui/manifest.txt:1** [medium] -- scripts/coverage.py:141 builds its coverage table from engine/libs + host/packages only, so "every registered function is exercised by a test" is printed while 79 of the 426 host/gui/libs names have no call site in any executed .bas (anchor is coverage.py:141, not tests/gui/manifest.txt:1)
53. **tests/negative/11_unknown_escape.bas:4** [medium] -- scripts/test-suite.ps1:177 and test-suite.sh:111 gate the negative corpus on the exit code alone, so a negative that stops exercising its own rule still reports PASS (11_unknown_escape.bas is the demonstration, not the location)
54. **tests/skeleton/hello.bas:1** [low] -- check-manifests.py enumerates nothing: tests/skeleton and tests/gui/hostmode are in neither CORPORA nor NO_MANIFEST, so a .bas dropped there is invisible to the gate while coverage.py still credits it as exercised (defect is in scripts/check-manifests.py:39-51,68, not in tests/skeleton/hello.bas)

### Test gaps (3)

55. **tests/suite/49_on_error.bas:76** [medium] -- tests/suite/49_on_error.bas:76: the only assertion in the "error inside a called function" case is dead code -- h5 leaves by `goto done`, jumping past it (and past line 77, which leaves the VM stuck in-handler -- NOT, as the finder says, "h5 still installed")
56. **host/gui/phosphorguitest.lpr:177** [low] -- The GUI test runner's hang watchdog calls Application.Terminate instead of ending the process, permanently disabling the message loop for every later app_run() in the same file
57. **tests/PhosphorTestLib.pas:76** [low] -- tests/PhosphorTestLib.pas:76 -- assert_eq's relative 1e-12 epsilon loses all resolution above ~1e12, and because assert_int has no `:%%$` message overload, six live assertions that need a message fall back onto it (57_buffer.bas:412/415/416, gui/18_faults.bas:73, gui/19_argord_and_size.bas:122) where their expected literal can be mutated without failing

### Documentation errors (6)

58. ~~**docs/embedding.md:230** [high]~~ -- CLOSED 2026-09-10. embedding.md has a
   section of its own now, "What the four ceilings do not bound", and memory leads
   it with the measurement out of `PhosphorBudget.pas` and the remedy that is
   actually available (bound the PROCESS -- job object, rlimit, cgroup). The other
   two sites point at it rather than repeating it: decisions.md:311 and
   architecture.md:158. The section also carries the network, the GUI, the
   environment, the host's own `--out` file and a second thread, because the
   finding was about a set presented as complete and one more item would have left
   it just as complete-looking. What a script CANNOT do is stated with them: no
   library in `engine/` or `host/` spawns a process.

   AND ON THE SAME DAY THE ENGINE HALF FOLLOWED. `TPhosphorVM.MaxMemoryBytes` is a
   fourth ceiling, measured as GROWTH from the heap the run began with -- so it
   bounds the script and not the application, which an absolute measurement would
   not: a host already holding 300 MB would refuse every script under a 32 MB
   ceiling before it ran a line. `opAdd` asks it before it concatenates, which is
   the one instruction whose result size is known in advance and the one
   `PhosphorBudget.pas` named as the hole; a check beside the wall clock in the
   step loop catches everything the pre-check cannot size.

   THE CHEAP QUESTION IS ASKED FIRST. `GetFPCHeapStatus` is about 39 ns here,
   twelve times a short concatenation, so consulting it in front of every `+`
   would tax every string-building script for a ceiling only large allocations can
   cross. Below 64 KB a concatenation pays one integer test; measured against the
   pristine build, string-heavy work with no ceiling set is unchanged within
   noise.

   Checks in `probe_limits`, 33 -> 47 assertions (the commit message said 30; it
   was 33, and in this project a count is load-bearing). Two of the first five
   were holes: the backstop check "passed" while measuring nothing, because adding
   one `chunk$` a thousand times stores a thousand REFERENCES to one buffer --
   AnsiStrings are refcounted -- and the growth-not-absolute check passed both ways
   because its script was four lines and the periodic check only looked every 4096
   steps.

   THE REVIEW THEN FOUND THREE BLOCKING DEFECTS AND THREE MORE HOLES, and reshaped
   the design.

   `used < FHeapBase` answered "nothing to charge" and turned the ceiling OFF for
   the rest of the run. Reachable two ways: a TPhosphorVM run a second time (1.3 GB
   through a 128 MB ceiling) and a host freeing its own memory mid-run (1516 MB
   against 591). The floor falls now -- `FHeapBase := used`. Sampling the base
   later does NOT fix it and the reviewer measured that too:
   `GetFPCHeapStatus().CurrHeapUsed` does not fall when the LAST large chunk is
   released, so the base stays high whatever the ordering. That same fact is why
   the check for it needs TWO ballasts and frees the first: with one, the counter
   reads 520 MB before the free and 520 MB after, and the branch is unreachable.

   `len()` allocated EIGHT BYTES PER INPUT BYTE. `Utf8Len` was
   `Length(Utf8Starts(S)) - 1` -- a table of one Int64 per byte, built to count its
   own entries. Three lines under all four ceilings reached 1716 MB and answered
   rc 0, scaling linearly to 4291 MB. Counting in place is the same rule without
   the table: 190 MB and three times faster, byte-identical across all 138 .bas
   files. That was open finding 12 and it is closed here because it made the new
   ceiling's headline claim false.

   A THRESHOLD ALONE WAS NOT ENOUGH, and neither was a periodic check. 700
   concatenations of 64000 bytes -- each under the threshold -- reached 43 MB under
   a 4 MB ceiling and finished before the step-loop check ever looked. The growth
   ACCUMULATES now, so the heap is asked once per 64 KB added rather than once per
   concatenation, and the overshoot is bounded by 64 KB plus the allocation in
   flight. And twelve `string$` calls in forty instructions reached 3814 MB under a
   256 MB ceiling, so every library call is asked on the way out -- one query
   against a call that costs 21 to 115 us is under a thousandth of it.

   THE PERIODIC CHECK IS GONE. With those two doors asked directly it became
   unreachable as the only catcher -- growth through any other seam has to be
   RETAINED to matter, and retaining it means a container (a library call) or a
   string (an opAdd). It also cost one test per instruction, measured at 3 to 4
   percent on a tight arithmetic loop with no ceiling set. A branch no test can
   reach, that everything pays for, is decoration.

   Nine mutations now, eight of them red: RoomFor ignoring its growth argument,
   TextLenOf answering 0, the pre-check disabled, the after-a-call check disabled,
   the base from zero, and the floor not falling. `MemCheckFrom = 0` survives and
   should: it is a cost knob, not a correctness one.
59. ~~**CLAUDE.md:51** [low]~~ -- CLOSED 2026-09-10. Both short forms carried the
   same gap: CLAUDE.md:51 and this file's own section-2 bullet listed four codes
   where the alphabet is five. Both now read `n % $ @ ?`, and both say `#` is never
   a code, as `PhosphorRegistry.pas` and decisions.md:175 do.
60. ~~**docs/embedding.md:27** [low]~~ -- CLOSED 2026-09-10. It says two, which is
   what the block under it lists.
61. ~~**docs/embedding.md:269** [low]~~ -- CLOSED 2026-09-10. embedding.md:269,
   README.md's "same seven on Linux" and its "six source gates described above" all
   say eight, and the README table gained the two rows it was missing --
   `check-budget.py` and `check-manifests.py`. The README heading and its prose
   count were already right, because `coverage.py` gates exactly those two numbers.
   Everything a gate does not read is what drifted, which is the whole argument for
   gates.
62. **docs/embedding.md:298** [low] -- docs/embedding.md:296-298 promises a sandbox refusal is reported by `ioerror()` for four functions; `file_writealltext` and `dir_getfiles$` (and `file_appendalltext`) never touch the slot, so it keeps its previous value -- "No error" in a fresh run. **The sentence was corrected on 2026-09-10** to name which two report the refusal (`file_readalltext$` sets 2, `dir_delete` sets 3) and to say the other two leave the slot alone; the finding stays OPEN because the better fix is probably in `PhosphorIoLib.pas`, where a refused write could set 3 like `file_delete` next door does, and that is a code change this documentation pass may not make.
63. ~~**docs/function-reference.md:88** [low]~~ -- CLOSED 2026-09-10, and the numbers
   were counted off the source rather than taken from the finding: Str is 64 names /
   69 entries, the page's twenty-three headings now sum to 828, and 715 names is
   unchanged because `stri$` and `str$` were already names -- 103491e added an
   arity to each, not a function. The entries column still has no gate, so it will
   drift again the same way.

### Cross-OS divergence (1)

64. **scripts/build.sh:23** [low] -- scripts/build.sh:23 and scripts/test-suite.sh:18 strip only // and { } comments while their PowerShell counterparts (build.ps1:66-68, test-suite.ps1:40-42) also strip (* *), so a forbidden unit named inside a paren comment fails the boundary check on Linux and passes on Windows -- and build.sh's own comment at 20-22 claims the missing pass (test-suite.sh's does not)

### Breakage (1)

65. **engine/PhosphorCompiler.pas:2228** [low] -- `print`/`println` rejects the `:` statement separator wherever an item is expected -- after the bare keyword, and after a trailing `;` or `,` -- because lines 2228/2240 omit tkColon that all five sibling parsers, including `print using`, include

### Killed by the refuters (13, kept so they are not re-found)

Three of these were security-adjacent, so the integrator re-read the refutations
rather than trusting the count. All three hold, each on a measurement the finder
had not made -- but two leave a residual that is worth more than the finding was,
and one of those is NEW, found by the refuter while killing the claim:

- **`gzip_decompress$` drops every member but the first of a CONCATENATED gzip
  stream, and no page says so.** The CRC/ISIZE claim it was found under is
  correctly refused -- `docs/libraries/gzip.md:41-43` states that the trailer is
  "stripped and not verified" and gives the reason -- but multi-member silence is
  undocumented and the finder's proposed remedy (compare against `Length(Src)-8`)
  would have refused every legitimate concatenated stream. **Open, low.**
- **`scripts/test-gui.sh:66` matches a bare `gtk` and an unanchored `cannot
  open`.** The claim that this swallows real failures is measurably false: on the
  actual gtk2 session a failing run writes 59 bytes matching none of those tokens
  and the run exits 1, twice measured. But the pattern is wider than the one
  string it has to match, and anchoring it to `cannot open display` is a one-line
  hardening. **Open, low.** The finder's own proposed anchor (`^Gtk-WARNING`) is
  wrong and would turn a legitimate skip into a false failure -- the real line
  begins `(phosphorguitest:NNNN):`.
- **HTTPS verification is chain-only; the hostname is not checked.** Refused as a
  defect and correctly so: it is disclosed in the unit header, in
  `docs/libraries/http.md` and in `docs/roadmap-net.md:79`, which proposes the
  identical `X509_check_host` remedy nine days earlier. It is a scheduled roadmap
  step, not a discrepancy between code and documentation. Nothing to fix; it does
  need doing.


- `engine/PhosphorCompiler.pas:1323` -- The two-word `else if` the language reference promises is a syntax error in the one-line IF form, because the lexer merges it into `elseif` and the inline branch only looks for `else`
- `engine/PhosphorVM.pas:2802` -- TimeoutMs on a prepared session is a wall-clock fuse lit at Prepare -- it counts the host's idle time, and disagrees with the library-side budget, which restarts on every call
- `scripts/check-suffix.py:53` -- check-suffix.py cannot see a `%` name that returns a Double, because it maps `%` and no-suffix to the same kind -- and dict_get%, documented as `-> int`, returns 1.5
- `engine/libs/PhosphorJsonLib.pas:245` -- json_getn aborts the program on a member holding a numeric string like "1e999" -- NumVal produces a non-finite Double and the declared default is never used
- `engine/libs/PhosphorConfigLib.pas:203` -- cfg_getn/cfg_getns raise on numeric text that overflows a Double, where the docs promise 0
- `engine/libs/PhosphorNumLib.pas:178` -- cmpval answers 0 (equal) for two int% that the engine's own `>` operator says differ
- `engine/libs/PhosphorDateTimeLib.pas:406` -- daysbetween/weeksbetween/monthsbetween/yearsbetween narrow to a 32-bit local: negative distances, and weeksbetween larger than daysbetween
- `host/console/phosphor.lpr:1300` -- A script can be given no command-line arguments at all: `phosphor prog.bas a b` exits 2, while the documented `paramstr$()` returns the host's own flags -- and the same program packed sees the arguments correctly
- `host/console/phosphor.lpr:989` -- The REPL exits 0 after reporting errors, so a script that pipes commands into `phosphor` is told the whole file succeeded
- `host/embed/phosphorembed.lpr:111` -- The embedding worked example reads `v.Num` without checking `v.Kind`, so a host copying it silently gets 0.0 from any `%`-suffixed BASIC routine
- `host/packages/PhosphorHttpLib.pas:142` -- HTTPS certificate verification never checks the hostname: a certificate issued for a different name is accepted, contradicting the unit header's "wrong host" claim
- `host/packages/PhosphorGzipLib.pas:286` -- gzip_decompress$ / gzip_decompressfile never check the CRC32 or ISIZE trailer they write -- a corrupted stream returns wrong bytes with gzip_error() = 0
- `scripts/test-gui.sh:66` -- test-gui.sh reports "GUI SUITE SKIPPED" and exit 0 for a genuine GUI failure whenever stderr mentions gtk, which every gtk2 program on a desktop prints

### Noticed while closing the wrong answers on 2026-09-10 -- NOT the gauntlet's list

Fourteen of the twenty wrong answers above were closed by four file-disjoint
lanes, each scope-locked to its own files. What a lane could see and could not
touch is here. **None of these went through a refuter**: each is one agent's
measurement, unconfirmed by a second party, which is why they are kept apart from
the sweep above. Verify before fixing, as with everything on this page.

1. **`scripts/check-codepage.py` cannot see the class it exists for, at any PLAIN
   assignment.** Measured by importing the gate and running its own functions over
   the pristine `engine/PhosphorLexer.pas`: on
   `FErr := 'unexpected character ''' + c + '''';` it reports `ACC target = FErr`,
   `is an accumulate = False`, `char operands = ['c']`. Its own `char_operands`
   identifies the Char correctly and `scan` never asks, because the
   `if not re.search(... base ...): continue  # not an accumulate` test requires
   the target name to appear on the right-hand side; `scan` returns 0 hits for
   the whole file. Finding 37 sat at that shape for the life of a gate whose own
   header says "The rule is absolute on purpose -- ASCII-only sites are flagged
   too". The widening is one line: keep the accumulate test as the reason to STRIP
   the base from the expression, but do not use it to SKIP the line. It was
   reported rather than done because widening it will surface other sites across
   the tree that need triage. **A GATE'S REACH IS A CLAIM, and it needs exactly
   what a completeness claim in prose needs.**
2. **`scripts/build.ps1` does not pass `-B`, so the project's documented clean
   build is an INCREMENTAL one.** CLAUDE.md and section 0 both state the bar as
   `fpc -B -vewn`; `build.ps1:113` omits it. Measured in two lanes independently:
   5,078 lines compiled on a second invocation against 35,320 from clean, and
   2,176 of 35,180 in the other. This is the stale-`.ppu`-in-the-same-filesystem-
   tick trap one level up -- it applies to the project's own script, not only to
   hand-rolled mutation builds. Both lanes worked around it, one by deleting
   `bin\units` first and one by running fpc by hand with build.ps1's exact
   argument list plus `-B`. Adding `-B` to the `$args` array makes the script do
   what its synopsis claims. The `phosphortest` build inside `test-suite.ps1`
   omits `-B` too, and separately discards its own `-vewn` log -- that half is
   open finding 50.
3. **FPC's `Math.FMod` carries the identical defect just removed from float
   `mod`.** `rtl/objpas/math.pp`: `Result := X - Int(X/Y)*Y`. Nothing in
   `engine/`, `host/`, `tests/` or `lazarus/` calls it today -- grepped -- so
   there is nothing to fix, but any future library reaching for it reintroduces
   all three wrong answers of finding 29 at once. A banned-RTL-routine entry
   beside `check-budget.py`'s narrowing list would catch it, and is the same shape
   as the 32-bit-narrowing sweep that file already runs.
4. **`rnd(0)` and `rnd(1)` both answer 0 on every call, forever.** The
   one-argument form (`engine/libs/PhosphorNumLib.pas:178`, registered at `:251`)
   clamps its bound up to 1 and calls `Random(hi)`, which is `0..hi-1`. That is
   defensible as a design -- the zero-argument `rnd()` is the fraction, one line
   below -- but in every classic BASIC `RND(1)` means "the next random fraction",
   so a ported program gets a silently constant 0 rather than a diagnostic. It
   cost a lane directly: a property test built on `rnd(0)` generated 4000
   identical empty strings and reported 0 mismatches while measuring nothing -- it
   passed against a deliberately broken build. Either make the one-argument
   `rnd(1)` the fraction, matching the reference, or say so loudly in
   `docs/libraries/num.md`.
5. **A label placed inside a `for` block is not resolvable.** `on error goto sng`
   with `sng:` in the loop body fails with `undefined label sng`. `RecordLabel` is
   reached only from Compile's top-level loop and a `for` body is consumed by
   `ParseBlockUntil`, so the label is never recorded at all. That may well be
   intended -- a label belongs to the program, not to a block, which is the rule
   the `goto`-out-of-a-function refusal rests on -- but nothing says so and the
   message does not hint at it. The line number is right now that finding 27 is
   closed; the diagnostic is not.
6. **`scripts/test-suite.ps1` writes its capture to a fixed
   `%TEMP%\phosphortest.out`, so two runs on one machine collide.** `$env:TEMP` is
   per-USER, not per-worktree. Two lanes hit it: a full suite run died with
   `O arquivo ja esta sendo usado por outro processo` because another worktree had
   the file open, and the failure surfaced as a PowerShell `ReadAllBytes`
   exception rather than as anything about concurrency -- it reads like a broken
   harness, not like a collision. Both worked around it by pointing TEMP at their
   own scratch directory. Derive the name from the process id or the worktree.
   (`test-suite.ps1:105` and `:200`.)
7. **The handler target is the same off-by-one family as finding 26, and it was
   measured rather than guessed.** `opSetErrHandler` bounds its target inclusively
   (`> AProg.Count`), so a `.pbc` whose installed ON ERROR handler points at
   `pc = Count` passes validation; when the error fires, pc jumps past the last
   instruction, the dispatch loop ends, and the program reports success having
   done nothing. Measured on a compiled
   `on error goto oops / x = 1/0 / println "after"` whose handler operand was
   repointed to the instruction count: the honest file prints "handled" then
   "after" with rc 0, the edited file prints NOTHING with rc 0 -- byte for byte
   the silent no-op of finding 26. It was deliberately NOT changed, because unlike
   a function entry (which must have an instruction to run) a handler at `Count`
   might be what the compiler legitimately emits for
   `on error goto <label at the very end>`. Closing it means repeating the corpus
   sweep that settled the function entries -- smallest `Count - Entry` gap 4 -- for
   handler targets. `opGosub` shares the bound and the shape (a gosub to `Count`
   ends the program instead of returning) and nobody measured that one.
8. **`scripts/test.sh` has no ProveFailure switch at all**, while
   `scripts/test.ps1` has had one since it was written: `bash scripts/test.sh
   --prove` ignores the argument, runs a normal pass and exits 0. That is the
   shape `test-suite.sh` guards against with its unknown-argument refusal, and it
   means "a check is only trustworthy once seen to fail" can be exercised on
   Windows and not on Linux for this harness. Open finding 49 names the other
   scripts; this one is a counterpart that was written on one OS only.
9. **`check-budget.py`'s `bounded` reads a conjunction as unbounded when ANY name
   in it is tainted**, so a `while` whose condition is
   `p <= Length(S)` and `n < ALimit` together scores as a hole even though the
   first conjunct bounds it by a string already in memory. Two lanes rewrote
   correct walks as a `while` on the length alone with a `Break` on the limit
   inside, to pass honestly.
   Arguably the better shape either way, but the gate is teaching a style rather
   than measuring a fact, and the next person will read the rejection as a false
   positive and reach for an exemption. Treating a conjunction as bounded when any
   conjunct is derived would fix it.
10. **Two suite goldens are byte-exact COUNTS only** (`passed: N / failed: 0`), so
   a file can silently lose an assertion to an edit and still pass if another is
   added in the same change. Noticed while moving `43_syntax_const.expected` from
   28 to 33.
11. **`PhosphorRagLib.DetectFunctionNames` splits the RAW query on
   `[' ', ',', ';', '(', ')']` only** -- the same class as finding 33, one
   function down. A function name separated from its neighbour by a Unicode
   separator rather than an ASCII one is not recognised.
12. **A config now round-trips a negative zero, and nothing says whether it
   should.** `FloatToStr` renders `-0.0` as `0`, so `-0.0` used to come back
   `+0.0`; `NumToInv` compares BYTES rather than `=`, so the value takes the exact
   `Str(V:24)` path and survives. The behaviour changed as a side effect of a
   correct choice, which is the kind of change that needs writing down before
   someone depends on either answer.

## Retrospective log (appended each round)

Newest first. Each entry: what broke or was missed, and the rule it produced. A
"needed-a-human" entry is a case the agents could not resolve autonomously — its rule
exists so they can next time.

- **2026-09-10 · round 39 · fourteen wrong answers, four of which the tests had
  pinned as correct.** Four file-disjoint lanes closed findings 25-27, 29-34 and
  36-40. Six runners, nine probes, eight gates, `-ProveFailure` seen catching a
  mismatch on the suite and on the classic runner. The headline is not any of the
  fourteen.

  - **THE TESTS HELD FOUR OF THESE DEFECTS IN PLACE.** `51_arith_faults.bas`,
    two places in `probe_value.lpr`, block K of `test.{ps1,sh}` and
    `54_onerror_reentrancy` each asserted a wrong answer as the expected one.
    Every one had been written by reading a run. The rule is in section 4 and in
    CLAUDE.md: derive the expected value from an external definition, from
    arithmetic written out beside the assertion, or from a second path through
    the engine — never off the implementation you are testing.
  - **THREE OF THE FOURTEEN CLOSED BY DEPARTING FROM THE FINDER'S REMEDY, AND
    EACH DEPARTURE IS A MEASUREMENT.** `Math.FMod` was read and found to carry
    the identical formula. The strings finder's whole-string fold measured 57 s
    against 0.055 s, which is a peLimit under any host timeout. "Keep every byte
    >= 128" glues words across a no-break space and loses a document. And
    `Ord(buf[3]) < 32` still refuses two valid BASIC programs. **A finding is a
    report, not a prescription** — and the smallest remedy still has to be
    measured against the input it might REJECT, not only against the input that
    reported it.
  - **A GATE'S REACH IS A CLAIM.** `check-codepage.py` says "the rule is absolute
    on purpose" and cannot see the class it exists for at a plain assignment;
    finding 37 sat at that shape for the life of the gate. Measured by importing
    the gate and calling its own `scan` and `char_operands`. The same pass
    found that `build.ps1` does not pass `-B`, so the command this page names as
    the clean build is an incremental one. **An unmeasured gate is prose that
    compiles.**
  - **`git diff --cached --binary > file` THROUGH POWERSHELL REDIRECTION WRITES A
    UTF-8 BOM**, and CRLF with it, after which `git apply` refuses every hunk
    with "patch does not apply" — which reads exactly like a stale or badly
    generated diff rather than like an encoding problem. It cost a real detour.
    Write the diff through a raw byte path (the Bash tool, or `cmd /c`), and
    prove the file before handing it over: `git apply --check --reverse` is the
    cheap way.
  - **`$env:TEMP` IS PER-USER, NOT PER-WORKTREE.** With lanes running the suite
    concurrently, `test-suite.ps1`'s fixed `%TEMP%\phosphortest.out` made one
    lane's run abort another's, and the failure surfaced as a PowerShell
    `ReadAllBytes` exception. When lanes are meant to run in parallel, every file
    a runner writes outside the worktree is shared state.
- **2026-09-07 · round 38 · the twenty-one wrong answers, the seven escapes, and the
  briefing that finally stopped costing a round.** The gauntlet's remaining classes,
  closed in two councils. The process finding is the headline: the three rules that
  round 37 derived from two failed rounds were put in the FIRST briefing this time,
  and six of seven lanes were accepted first pass, against three of four rejected
  before. **A rule learned from a failure is worth what it costs only if it moves
  into the brief.**

  - **A CLASS DISGUISED AS SIX DEFECTS, AND THE CAUSE WAS A FUNCTION'S SCOPE.** Six
    of the twenty-one wrong answers were UTF-8 operations counting bytes. The
    reason the class kept coming back is that the codepoint-aware family was
    PRIVATE to PhosphorStrLib while two of its three callers -- ValSub in
    PhosphorValue, FormatUsing in PhosphorVM -- live in other units and could not
    reach it. Each grew its own byte walk. Ask where a duplicated idea's owner
    lives before writing the sixth copy of it.
  - **TWO ENCODERS THAT DISAGREED.** Only one of the two UTF-8 encoders had the
    bottom guard, so `chr$(-1)` and `lfill$(...,-1)` answered differently, one of
    them with a byte that cannot occur in UTF-8. A second copy is not a duplicate;
    it is a second answer.
  - **A GREP THAT IS TRUE WHEN IT RUNS IS NOT AN INVARIANT** (round 37's lesson,
    paid for again at integration): the stack lane made a library `peLimit` fatal
    on a grep finding none in any library; the budget lane then gave libraries
    their own refusals. Both verified in isolation by two reviewers each; together,
    `probe_budget` went 205/2. **Integration is a test, not a formality**, and the
    fix was to discriminate on PROVENANCE rather than on the error code.
  - **A RULE STATED AS TEXT ALWAYS LOSES TO A NEW SPELLING.** The perilous-path
    guard was textual and `C:\.`, `C:\dir\..` and `\\server\share\..` walked
    through it -- the SECOND spelling to do so. Made structural (resolve, then ask
    whether the volume is the whole of what is left), and the sweep against the
    pristine unit answered 86/45: forty-five spellings of a root were not
    recognised as one, and a reviewer's independent sweep found 56 more.
  - **READING THE RTL FOR ONE PLATFORM IS NOT READING IT.** That same fix was
    correct on Windows and broke POSIX, because `AllowDirectorySeparators` is
    `['\','/']` on Unix TOO (`rtl/unix/sysunixh.inc:35`), so `ExpandFileName`
    mangles a legal POSIX filename containing a backslash. Only a native run found
    it.
  - **AN ENUMERATION THAT COUNTS ARGUMENTS IS BLIND TO A DIRECTORY WALK.** The zip
    lane correctly diagnosed a gate that counts ROUTINES, then shipped an
    enumeration that counts ARGUMENTS -- and `zip_compress` hands each enumerated
    CHILD to the RTL as a disk path that is not an `Args[i]`. PhosphorIoLib already
    said the rule twice: re-asked at every level of the recursion.
  - **A MARKER MUST NOT BE A BYTE THAT OCCURS IN DATA.** A JSON fix rewrote the
    source text with `#1` sentinels and unmarked afterwards by scanning for them --
    so a document carrying `#1` of its own came back corrupted, and an
    all-printable-ASCII document became a NUL-injection primitive. A sentinel
    scanned for after the fact cannot tell what it produced from what was already
    there.
  - **THE GATE AND THE THING IT GUARDS MUST SHARE A BASE.** SQLite's
    `PRAGMA data_store_directory` moves the base a relative filename resolves
    against; the gate kept resolving against the process CWD. Every call in the
    escape was one the gate allowed. The remedy was to stop MODELLING the
    resolver and call it -- `sqlite3_vfs_find(nil)^.FullPathname`, the function the
    pager itself uses.
  - **THE DESTRUCTIVE-DEFECT RULE HELD, UNDER TEST.** Eight agents across two
    councils closed four sandbox escapes and three data-loss defects, and every one
    reported running NO destructive repro. The technique that made it possible is
    the pure probe: `probe_sandbox` asks `IsPerilousPath` and `SandboxAllows` about
    131 spellings and touches no filesystem at all. **A guard that can only be
    tested by letting it fail is a guard that will not be tested.**

- **2026-09-07 · round 37 · three rounds to close three mechanisms, and the two
  defects only integration could find.** Seventeen crashes, all in the engine,
  produced by three design seams with no enforcer. Four lanes, three rounds,
  twenty-four agents. All four patches merged on the third.

  - **EVERY ROUND CLOSED WHAT IT WAS GIVEN AND INTRODUCED ONE NEW DEFECT OF THE
    SAME CLASS.** Round one: four patches, three rejected. Round two: four
    patches, four rejected — a glob rewrite that silently answered wrong for 100
    of 7225 enumerated inputs, a guard that refused an ordinary non-recursive
    60-deep call chain, twelve library doors where NaN became a silent 0, and a
    search cost that refused 19 of 27 searches which together run in 62 ms. All
    four passed their authors' own tests.
  - **THE CAUSE IS THE PIN, NOT THE CARE.** A lane asked to fix something
    REWRITES it, then judges the rewrite against pins the author chose. Round
    one's subnormal band and round two's glob band were both outside the
    author's pins, and in both cases the author reported "byte-identical". The
    glob author sampled 4000 random pairs; an exhaustive walk of the same
    alphabet found 100 divergences, because the generator drew names from a
    smaller alphabet than patterns.
  - **WHAT BROKE THE CYCLE, and it was three rules, not more effort.** (1) SCOPE
    LOCK: change only what the numbered ask requires; a defect left for the next
    round is free, one introduced costs a round. (2) PREFER THE REMEDY THE
    REVIEWER ALREADY MEASURED — the glob fix was swapping two `else if` branches,
    which its reviewer had already applied and measured at 0 of 7225. (3) PROVE
    IT ON THE REVIEWER'S HARNESS, NOT YOUR PINS. The harnesses were still on
    disk, 551 / 114 / 573 / 1594 files. **Run the thing that caught you.**
  - **A GREP THAT IS TRUE WHEN IT RUNS IS NOT AN INVARIANT.** The stack lane made
    a `peLimit` from a library call fatal, justified by `grep -rn peLimit engine/
    host/` finding none in any library. True that hour. The budget lane then gave
    libraries their own refusals. Both patches were verified in isolation by two
    reviewers each; together, `probe_budget` went to 205/2. **Lane isolation
    hides exactly this, so integration is a test, not a formality** — and the fix
    was to discriminate on PROVENANCE rather than on the code: a ceiling crossed
    inside a nested activation stays fatal, a library refusing up front stays
    catchable.
  - **PIN THE HALF THAT IS NOT SELF-RE-ARMING.** That rule's obvious test — a
    step budget crossed inside a callback — passes with the rule and without it,
    because `FSteps` is shared and the outer loop re-fires it an instruction
    later. It measures nothing. The frame ceiling is the one that genuinely
    escapes, because `CallUserFunc` restores `FFrameSP`. Measured both ways
    before the pin was written.
  - **`SizeOf(Extended)` IS 8 ON WIN64 AND 10 ON LINUX X86-64**, and an untyped
    float literal in FPC source is an Extended. Comparing a Double against one
    promotes BOTH, so `r.Num = 1.7976931348623157e308` is false on Linux and true
    on Windows; and `Power` carries its intermediate in whatever Extended is, so
    `10 ^ -310` differs in its last digits between the two. Three pins were
    testing the FPU and the literal parser rather than the engine. Compare
    against a TYPED `Double` constant, and assert the PROPERTY a check is named
    for — "is a subnormal, not zero" — rather than a decimal string. All three
    rounds of review ran on Windows only, and round two's reviewer had said so in
    writing.
  - **A FAULT IS NOT AN ERROR, AND ON ERROR MUST NOT SEE ONE.** `opCall`'s net
    caught every `Exception` and handed it to `ON ERROR` — including an access
    violation. Resuming a script after one resumes on memory a wild write has
    already reached, so it answers wrongly instead of dying, which is worse than
    the crash: a crash is loud. Now `peFatal` (8), never offered to `ON ERROR`,
    and `ContainFaults` for the host to keep its PROCESS while losing the run.
    Classifying it needs the RTL, not memory: `EExternal` is the OS/hardware root
    and `EIntError`/`EMathError` DESCEND FROM IT, so "is EExternal" alone calls a
    division by zero a state fault.

- **2026-09-06 · round 33 · a suffix that lied, and the two functions that were
  missing because writing them was hard.** The owner asked for `dict_clear@`'s
  suffix to be fixed and for `encodedate`/`incmonth` to be added. Both asks turned
  out to be the visible corner of something bigger.

  **`dict_clear@` returned `ValInt(1)`** — a lie about the type and a bare success
  flag, the two things this codebase calls defects, in three characters. It now
  answers the dictionary, exactly as its sibling `dict_set@` always did, so the `@`
  is true and the call chains. Nothing was lost: the `1` was constant and never
  once said whether anything had been removed.

  - **A gate audit found the class: 14 more, out of 1297 registrations.**
    `narr_set@`/`sarr_set@` promise a handle and answer the value written;
    `arr_set` and `button_click`/`form_show` carry no suffix (so promise a number)
    and answer a string or a handle. Verified by hand, not just reported:
    `x = arr_set@(a@, 1, "hi")` prints `before` and then aborts with *cannot store
    string into number variable*. **Nothing checks this.** `TPhosphorRegistry.Add`
    stores `'dict_clear@:@'` as an opaque key; the suffix is part of the NAME, not
    a checked contract, which is exactly why an int-returning function could live
    behind an `@` name for a year. A gate that compares a registration's suffix to
    the `Val*` its implementation returns is the obvious next one to build.
  - **The failure is at RUN time, not compile time** — `opStoreVar` is what checks
    the kind. I wrote "rejected at compile time" in a source comment and a review
    agent caught it; `println "before"` printing first is the proof. The old
    `dict.md` said the same thing and had said it for as long as the wart existed.

  **`encodedate` and `incmonth` were absent because they are the hard ones.** Every
  other `inc*` is arithmetic on a number — a day is 1, a week is 7 — so they were
  cheap and they got written. A month is 28, 29, 30 or 31, and constructing a date
  needs three numbers validated against each other. `date-time.md` had a paragraph
  declaring the hole permanent.

  - **The rule this produces: the missing function is usually the one that was
    hard, and that is the one a program most needs.** A library that has seven of
    eight siblings is not 87% done; the absent one is where the difficulty went.
  - **Two functions, three different failure modes, and catching an exception
    would have fixed only one.** `incyear` past 9999 RAISED, aborting with the
    RTL's own words. `incmonth` did NOT raise — its re-encode answers 0 silently,
    so the step came back as `1899-12-30`, a plausible date that is wrong. A
    `try/except` around both would have looked right and left the worse one
    unguarded. The verdict has to be computed BEFORE the RTL is asked, which is
    what `MonthStepYear` does, in `Int64` because a year near 9999 times twelve
    plus an `Integer` step overflows 32 bits — and an overflow there approves
    exactly the call the check exists to refuse.
  - **`TryEncodeDate` takes `Word`.** Year 65537 arrives as 1 and encodes a real
    date in the year 1. The parts are therefore checked as `Integer` before the
    narrowing, and `encodedate(65537, 1, 1)` is refused. A range check written
    after a cast is not a range check.
  - **What was deliberately NOT fixed, and is written down rather than left
    implied:** `incday`/`incweek` still step off the end silently, because they
    really are additions and cannot raise — and `datetostr$` and `yearof` then
    CLAMP the out-of-range number back to `9999-12-31` and report it as real. That
    is a whole-library question, not these two functions', and `date-time.md` now
    says so where a reader will meet it.
  - **THE GUARD FAILED THE WAY IT WAS WRITTEN TO PREVENT, and adversarial review
    found it, not me.** The first version checked only the year the step *lands*
    in. `DecodeDate` answers year 0 for any number at or below −693594 rather than
    refusing it, so the arithmetic started from a year that does not exist and
    landed back inside 1..9999: `incmonth(x, 12)` was refused while
    `incmonth(x, 13)` answered `1899-12-30` — non-monotonic, and exactly the
    silent wrong date the comment above it claimed to stop. **A guard that trusts a
    decomposition has to check that the decomposition is real.** The input was not
    exotic: the same change documents `incday` as having no range check, so one
    step back from the first representable day produces such a number.
  - **Four reviewers, one lens each, all told to REFUTE.** They cost ~530k tokens
    and returned four findings, two certain and load-bearing — this one, and a
    count in the unit header that said *seven* while the page I wrote in the same
    edit said *nine*. Writing a count and a list in one sitting is not enough to
    keep them agreeing.

- **2026-09-06 · round 36 · a 144-agent gauntlet, a 10-agent council, and 45
  findings closed.** A session-wide adversarial sweep over 38 commits returned 45
  findings that survived three refuters each. Two sandbox escapes, a modal crash
  dialog, an out-of-bounds write, a silent stack overflow, a REPL that wedged
  permanently, and a `resume next` that looped for ever. All closed, on both
  operating systems.

  - **THE SWEEP FOUND MORE THAN 34 ROUNDS AND SEVEN GATES HAD.** That is the
    headline and it should be uncomfortable. Gates check what someone thought to
    check; an adversary with a lens and an instruction to REFUTE checks what
    nobody did.
  - **It was wrong once, and I repeated it before verifying.** It claimed
    `dir_delete("C:/", 1)` was permitted. It was not — FPC's
    `AllowDirectorySeparators` is `['\','/']` on Windows, so the guard already
    caught it. I relayed that as "confirmed by reading" on a wrong reading of the
    RTL, and alarmed the owner. **Two minutes of running the pure function would
    have settled it.** Adjacent holes WERE real (`C:\\`, `C://`, a UNC share
    root), which is the trap: a false report next to true ones reads as true.
  - **Zero of 45 were killed by the refuters.** Three refuters each, majority to
    kill, and none died. That is not a sign the findings were all solid — it is a
    sign the refuters were too soft. A verification stage that never rejects is
    measuring nothing, exactly like a test that passes with the fix removed.
  - **THE COUNCIL'S LANES WERE NOT DISJOINT, AND I SAID THEY WERE.** I gave
    `coverage.py`'s blind spot to the gates lane and README's counts to another —
    but a correct total is not knowable until the counter is fixed, so both lanes
    fixed the same file and their patches conflicted. **Partition by dependency,
    not by directory.**
  - **`isolation: worktree` is not a sandbox.** One lane edited the MAIN tree
    anyway and produced its patch by diffing it, capturing another lane's work.
    Caught because the patch size exactly matched the main tree's diff. An agent
    given a path in its prompt will use that path.
  - **The best thing the council built was a RATCHET.** The gates lane recorded
    every known-stale mention in a table that FAILS the gate when an entry stops
    occurring — so fixing a page forces its line to be deleted, and a new stale
    mention fails on the spot. A backlog that can only shrink beats a backlog
    nobody reads. Its end state is the label, not the entry: four mentions are
    DELIBERATE (a name written to say it is gone) and five are HISTORY (a dated
    record must not be rewritten to match today's tree).
  - **A claim in a test comment is not a test.** `42_syntax_elseif` said it pinned
    "all FIFTEEN names"; it pinned thirteen. Written by the change that widened
    the rule, in the block whose purpose is to catch the next widening.
  - **The stale-harness trap fired four times in one session** and cost a wrong
    conclusion every time. `build.ps1` builds `phosphor`, not `phosphortest`.
    Run the suite, not the binary.

- **2026-09-06 · round 35 · a modal dialog on a headless machine, and the
  out-of-bounds write behind it.** The owner saw *"Access violation. Press OK to
  ignore and risk data corruption."* while an adversarial sweep was running. Two
  defects met in it, and the second was only findable because of the first.

  - **`phosphor` links the LCL, and that alone is enough.** The `Forms` unit
    routes unhandled exceptions to `Application.HandleException`, whose default is
    a modal box — in a console run, with no window, on a machine with nobody
    watching. The process then sits there holding a lock on its own executable,
    so the next build fails too. `phosphorguitest` has had
    `Application.OnException` since the day a suite hung on exactly this; **when
    round 31 merged the two hosts into one, the guard did not come along.** A
    merge moves code into a binary that never needed protecting from it, and the
    protection is the thing nobody lists. `phosphor` now reports to stderr and
    exits 3. Audited the rest: only two `.lpr` files link the LCL, and both are
    covered.
  - **The crash was a WRITE past an allocation.** A `.pbc` with one byte changed —
    a one-parameter function's local-slot count from 1 to 0 — passed the loader.
    `opCall` resolves by name AND arity, so the call matched; the frame is then
    sized from `LocalTypes` and each argument written into it, so an empty table
    means `Locals[0] :=` on a zero-length array. `ValidateProgram` already existed
    for precisely this class and checked the function's *entry point* but not the
    relationship the call path assumes. It now requires
    `Length(LocalTypes) >= ParamCount`, and bounds every local slot by the widest
    table in the program.
  - **THREE DEFECTS IN MY OWN TEST, each found by removing the fix and watching
    the test stay green.** (1) The assertion was `rc <> 0` — "did not run" — which
    a crash also satisfies, so the check passed while the interpreter was
    crashing; it now requires the loader's own word, `corrupt`. (2) The corruption
    was applied to a program with a `data` section, which `WriteProgram` puts
    AFTER the function table, so the shifted read was refused by the stream reader
    before the VM saw anything. (3) The function's name was found by searching
    FORWARD, and `dbl` is in the file twice — the call site stores the callee name
    as a constant, and the constant pool is written first — so four bytes of a
    string constant were corrupted and the function table left untouched.
  - **The rule: "the test passes" and "the fix works" are different claims.**
    Only removing the fix separates them. Here it took three attempts before the
    probe crashed with exit 217 without the validator and passed with it — and
    every one of those attempts had looked green.

- **2026-09-06 · round 34 · fifteen names lied about their own return type, and
  the fix was to build the check first.** A built-in's return type IS the suffix
  on its name — that is the whole type system for the library — and nothing
  enforced it. `TPhosphorRegistry.Add` stores `'dict_clear@:@'` as an opaque
  lookup key, so an int-returning function sat behind an `@` name for a year.

  - **The gate came before the fix, and that ordering was the point.** A
    subagent's audit had reported 14; `scripts/check-suffix.py` was written to
    answer the same question from source, and it disagreed twice — both times
    because *my gate* was wrong, not the report. It double-reported files reached
    by two globs, and it let `arr_set:@n$` pass because the house pattern opens
    with a PLACEHOLDER (`Result := ValInt(0);`) before the guards, so collecting
    every `Result :=` made the error path vouch for the success path. Judging by
    the LAST assignment fixed it. **A list you did not derive yourself is a
    hypothesis; deriving it is also how the check gets debugged.**
  - **Two of the four families were not design decisions at all.** `form_close@`
    sits one line below `form_show`, `button_onclick@` beside `button_click` —
    the convention (a setter ends in `@` and answers the handle) was already
    everywhere. Four names had simply missed it. Renaming was not a judgement
    call; reading the neighbours made that obvious in a minute.
  - **"Answers the value written" is not information.** The array setters handed
    back the value the caller had just passed in, while the `@` on their names
    promised the array. They now answer the array, like `dict_set@`, so the call
    chains — and the only thing lost was a value the caller already had.
  - **A doc claim can be load-bearing in appearance only.** `array.md` said
    `arr_set`'s return "is what makes `a@[i] += 1` work with the index evaluated
    once". Both compiler paths end in `opPop`; what makes it work is `opDupN`.
    The sentence had been wrong since before this change, and it read exactly
    like a constraint — the kind that stops you making a correct change. **Check
    a claim that blocks you before you honour it.**
  - **The stale-harness trap fired three times in one session.** `build.ps1`
    builds `phosphor`, not `phosphortest`; only the runners build the harness. So
    `bin\phosphortest.exe tests/...` runs OLD code and reports a failure that was
    already fixed. Every time it cost a wrong conclusion until the timestamps
    were checked. The rule is unchanged and simple: **run the suite, not the
    binary** — and if you do run the binary, `ls -l` it first.

- **2026-09-06 · round 33c · a stray `next` was a silent no-op, and the obvious
  fix broke eighteen assertions.** A block terminator with no open block fell
  through to the expression path, where a lone identifier compiles to a variable
  read and an `opPop`. So deleting a `for` line by accident left a program that
  still ran — once, with the loop gone — and said nothing. Eleven terminators
  behaved that way, plus `then`, `to`, `step` and `local`, which belong in the
  middle of a line.

  The rule that makes the check sound: **`ParseBlockUntil` consumes the terminator
  it is waiting for, so a terminator reaching `ParseStatement` is orphaned by
  definition.** No bookkeeping needed.

  - **THE FIRST VERSION FIRED ON THE WORD AND WAS WRONG.** These are *contextual*
    keywords, decided by the parser, not reserved by the lexer — a program may
    have a variable called `elseif` or `next`, and `tests/suite/42_syntax_elseif`
    exists to pin exactly that. The check turned its 18 assertions into a compile
    error. The suite caught it in one run; nothing else would have.
  - **The narrow rule is the right one:** fire only when the NEXT token ends the
    statement (EOL, EOF or `:`). `elseif = 5` stays an assignment; a bare `elseif`
    cannot be doing anything at all, which is precisely why the typo was silent.
  - **When a check has to distinguish two readings of the same word, the
    discriminator is what FOLLOWS it, not the word.** Reaching for the word is the
    tempting version and it is the one that breaks working programs.
  - **The regression test now covers the family, not the instance.** 42 pins all
    fifteen names as ordinary variables, so the next attempt to widen this fails
    there rather than in someone's program. A test that pinned only `elseif` let
    me break `next` — pin the RULE, not the example that happened to be written.

- **2026-09-06 · round 33b · the REPL had a test, and it covered two of seven
  block forms.** `08_repl` entered `function` and `if`. The other five — `for`,
  `while`, `wend`, `do…loop`, `repeat…until`, `select case` — were never typed
  interactively, which is how `expected 'next'` could be missing from
  `IsUnterminatedBlock` while a test existed and passed.

  - **The proof a regression test is worth anything is watching it catch the
    original bug.** With `expected 'next'` removed and the host rebuilt,
    `09_repl_blocks` fails and **`08_repl` still passes**. That contrast is the
    argument; without running it, "I added a test" is a claim.
  - **Silence plus exit 0 is a lie to a script.** Input ending inside an open
    block used to discard it without a word and answer 0 — anything piping a
    truncated file was told the whole file had run. It now names the missing
    terminator and exits 2. **stdout is byte-identical either way**, so pinning it
    needed the runner to learn an optional `<name>.exit`; seen failing when set
    to 0.
  - **What a piped test structurally CANNOT reach:** on Windows, an interactive
    console takes the `ReadConsoleW`/UTF-16 path in `TConsoleHost.ReadLine`, and a
    pipe takes the raw-byte path. Every automated REPL test is piped, so the
    console path — Ctrl+Z at line start, non-ASCII typed at the prompt, a line
    longer than the 8191-WideChar buffer — is exercised only by a person. Worth
    knowing before calling interactive mode "covered".
  - **The heredoc backslash trap bit again**, and this time it wrote a raw CR into
    a `.sh` file: `tr -d ' \r\n'` reached Python as a real carriage return. A
    shell script with CRLF fails on Linux. Rewritten as `tr -dc '0-9'`, which
    needs no backslash at all and is more forgiving of the file it reads. **When a
    patch needs an escape, that is the signal to find a spelling that does not.**

- **2026-09-06 · round 32 · a documented example that every gate approved and no
  reader could run.** The owner asked how to type a dictionary walk at the prompt.
  The REPL threw the line away: `IsUnterminatedBlock` listed six of the compiler's
  nine "expected X" messages and `next` was not among them, so a multi-line `for` —
  the one block a person is most likely to type interactively — was rejected while
  the banner two lines above promised the prompt would wait. Fixed by taking the
  list from the compiler rather than from memory.

  Then the one-liner failed too, for an unrelated reason, and that is the entry:
  **the example on `docs/libraries/dict.md` was not valid BASIC.** `case "string" :
  println …` is not how a case label is written. I had written it that day. Every
  gate passed it, and correctly so — `coverage.py` checks that a documented name is
  a registered function, and every name in that block was real. Nothing anywhere
  checked that the block was a *program*.

  So I compiled all of them: **71 blocks, 66 compiled, 4 of the 5 failures were
  defects** — a label inside a function reached by `on error goto` (which cannot
  work; a function's handler is a routine), and three conditions written `if x then`
  where the language wants `if x <> 0 then`. Now `scripts/check-examples.py` compiles
  every one on every suite run.

  - **The rule this produces: a gate that checks the parts does not check the whole.**
    Name-coverage is a real invariant and it was passing; it simply answers a
    different question than "would this run". Whenever a gate is added, ask what the
    *next* layer of wrongness looks like — here, the names were right and the grammar
    was wrong, and the only honest check was to hand the block to the compiler.
  - **The exemption rides on the thing it exempts.** The quick-reference block is a
    cheat sheet with `…` in it and is not meant to run. It is fenced ```basic
    notation, so the marker moves with the block; a list of `file:line` exemptions
    would have gone stale on the next edit. `coverage.py` was taught to match the
    first word of the fence, because a block excused from *compiling* is not excused
    from naming real functions — relabelling it would otherwise have quietly dropped
    it from the name gate too.
  - **Docs written the same day are not safer than old ones.** Two of the four were
    hours old. Writing an example is not testing it, and reading it back proves only
    that it looks right.

- **2026-09-06 · round 31 · the owner said one binary; the reason for two was false.**
  Phase 2 shipped two hosts and justified it in three documents: *the LCL cannot be
  loaded on demand, because on Linux gtk2 opens the X display in a unit
  initialization, before main — a runtime flag cannot undo a link-time decision.*
  Every clause of that is true except the one that mattered. **Linking the LCL is
  not what connects to the display.** The `Interfaces` unit contains one thing: a
  `CreateWidgetset` call in its initialization section. Name the widgetset unit
  directly (`Gtk2Int` / `Win32Int` with `InterfaceBase`) and the same code links
  while the call stays yours to make — or not.
  - **The owner proposed it; I had twice explained why it was impossible.** Both
    times I was quoting the project's own documents back, which is not evidence.
    The experiment took four minutes: three programs, headless and with a display,
    on both platforms. `uses Forms, Gtk2Int, InterfaceBase` without the call —
    alive, exit 0, headless. **When a design is defended by a measurement, re-run
    the measurement before defending it again.** A number in a document is a claim
    about the past.
  - **What the merge deleted.** `phosphorgui`, `build-gui.{ps1,sh}`,
    `PhosphorDisplayGuard` and the `uses`-clause ordering check that existed only
    to protect its trick, the `--gui` flag's handoff, and the exec of a second
    process. Two defects found the day before **evaporated with them**: `--sandbox`
    could no longer be dropped on the way to a child that never runs, and `pack`
    produces a working GUI application because the stub is the complete binary.
    *A defect that a design change makes unreachable is better closed than fixed.*
  - **What it cost, measured rather than estimated:** `phosphor` goes from 1.3 MB
    to 4.5 MB on Windows and 7.9 MB on Linux, and `pack` copies the running binary,
    so every packed application carries it. Stripping saves nothing — that is gtk
    bindings, not symbols. The owner was told the number before the work started
    and judged it irrelevant; the point of the rule is that the number was *known*
    and *theirs to judge*, not that it was small.
  - **The degradation is now a missing name, not a dead process.** Where no session
    is reachable, `form@()` answers *no function form@* — an ordinary catchable
    error — and every other library still works. Before, the binary that could open
    a window died inside gtk before its own first line.
  - **The dated record was annotated, not rewritten.** `roadmap-phase2.md` still
    says what phase 2 built and why it believed the split was necessary, with a
    note at the top saying what later replaced it and that the reason was wrong. A
    plan that edits its own history cannot be audited.
- **2026-09-06 · round 30 · the three paths nothing reached, and a defect in each.**
  Round 29 ended by naming what still had no automated visitor: the `--gui`
  handoff, the Unix keyboard, and a real message loop. All three are closed, and
  **every one of them had something in it** — which is the argument for closing a
  blind spot rather than reasoning about how likely it is to hold anything.
  - **The handoff** makes four decisions (is there a session, is `phosphorgui`
    beside me, spawn it, hand back its exit code) and nothing exercised any of
    them. Now driven against fixtures that open no window on purpose. Linux
    carries the case Windows cannot — no session, refuse before spawning, exit 3.
    *And the first version of that test could never run it*: `test-gui.sh` exports
    `DISPLAY=:0` near the top, so asking "is DISPLAY empty?" further down always
    answered no. **A branch is not tested by waiting for the environment to
    provide it** — take the session away for one command (`env -u DISPLAY`) and
    the branch that exists for every ssh session is exercised by the machine that
    has a session.
  - **The Unix keyboard** held two. `Result := c` assigned a Char into a String in
    a `{$codepage UTF8}` unit, re-encoding every byte ≥ 128 a terminal sent —
    the second half of every accented character. `check-codepage.py` names that
    exact blind spot in its own header, which is a gate documenting the hole it
    does not cover. And the assembly gathered ESC sequences only, so a typed
    accented character answered its **first byte** while Windows answered the
    whole character: two platforms disagreeing about what one keypress is.
    Extracting `CrtAssembleKey` then surfaced a third: a source cannot peek, so a
    byte read to be judged is a byte **consumed** — off the terminal, where it was
    the first byte of the next key. It is handed back now, and the reader keeps a
    one-byte pushback.
  - **The message loop.** `app_run()` — the verb every interactive GUI program
    ends with — had never run, because every other GUI test fires events
    synchronously. Entering it once worked. Entering it a **second** time found the
    defect: `app_quit` called `Application.Terminate`, which sets a flag the LCL
    gives no public way to clear, so every later `app_run()` in that process
    returned instantly having dispatched nothing. *The second call is the test.* A
    feature that works once and is silently dead afterwards passes every
    single-shot check ever written for it.
  - **A runner that can block needs a way not to.** `phosphorguitest` arms a
    watchdog timer that can only fire while a message loop is pumping — precisely
    the stuck case — and reports the file as failed. A hang tells nobody anything
    and blocks everything queued behind it; a hang that becomes a failure is a bug
    report.
  - **Two more things fell out, both about order and both small.** `test-classic`
    was the last runner that required the binary to already exist and told you to
    go build it: a suite whose result depends on the order you typed the commands
    in. And four `.sh` runners were committed non-executable while four were not.
  - **Recorded, not waved away:** one GUI-suite failure was seen once and did not
    reproduce in six further runs. The clipboard's bounded retry is the standing
    mitigation. An unexplained failure is written down as unexplained.
- **2026-09-06 · round 29 · the rule was written, and nothing was running it.**
  The owner ran `phosphor --gui examples/interactive.bas` and every INPUT prompt
  printed at once, each answered with an empty string. Then, asked the obvious
  question: *what is the point of writing a rule if a simple existing test finds
  the error anyway?* The answer is the entry.
  - **`phosphorgui` assigned `OnOutput` and stopped.** The engine documents a nil
    `OnInput` as "a program that asks for input gets an empty line" — correct for a
    headless runner, and a fabricated answer in a host with a console attached.
    `HostServices` was nil in **every** host in the tree, so `processmessages()`
    answered 0 and the clipboard answered `""` inside the one program written to
    provide them. Nothing failed, because nothing was looking.
  - **THE STRUCTURAL REASON, and it is the whole lesson: `phosphorgui` was the
    only program in the tree that nothing ever ran.** The GUI suite tests
    `phosphorguitest`, a different binary from a different file. `examples/` — the
    directory the README points at, the first code anyone runs — had no runner at
    all, while every corpus under `tests/` had one. Both defects the owner found by
    hand (this one and round 28's `getkey$`) sit on paths no automated thing
    touched. **The gates were not weak where they existed; they did not exist where
    a human was the only visitor.**
  - **So the deliverable is not the fix.** `scripts/check-seams.py` fails the suite
    if a host leaves an engine seam nil without a written reason — 7 filled, 21
    deliberately nil, each with its sentence — and a new seam or a new host fails
    until someone answers for it. `scripts/test-examples.{ps1,sh}` runs every
    example against a golden, sandboxed to the checkout, with a recorded `.in` for
    the interactive one and compile-only for the windowed one; its manifest covers
    the directory in both directions.
  - **What running them found immediately.** `examples/crt_keys.bas` could never
    reach its own last line (`x$ = crt_done()` — a number into a string variable),
    so the example the owner was told to try could not exit cleanly. And the
    clipboard, once actually exercised: a copy did NOT land before the next paste
    read it, so `pastetext$` returned the PREVIOUS contents while `strerror()` said
    0; and `copytext$("")` left the old text in place, because assigning `''` to
    `Clipboard.AsText` is not clearing. Both now write-then-confirm, bounded, and
    report failure instead of inventing success.
  - **AND THE PART THAT IS ABOUT ME.** The first version of the clipboard methods
    I wrote — an hour after building a gate against fabricated answers — was
    `Clipboard.AsText := AText; Result := True;`. Unconditional success, in new
    code, by the same hand, in the same session. Writing a rule does not install
    it. **A rule takes effect at the moment something fails when it is broken, and
    not one minute earlier.** Prose in this file is a description of a gate that
    must already exist; if the gate is not there, the paragraph is a wish.
- **2026-09-06 · round 28 · `getkey$` answered `chr$(0)` for every key, and the
  suite could not have known.** Reported by the owner running
  `examples/crt_keys.bas`: every keypress printed *control/extended, first code 0*,
  and `'q'` did not quit — because `'q'` never came back as `"q"`.
  - **The defect was a missing `begin`/`end`.** In `CrtKeyFromEvent` the `else`
    owned only the `SetLength(Result, 2)`; the two assignments under it ran for
    EVERY key. A printable key built its one-byte string, then had byte 1
    overwritten with `#0` and byte 2 written **one past the end** — over the
    AnsiString's terminator. Length 1 for printable keys, 2 for extended ones,
    first code 0 for both: exactly the output that was reported.
  - **`SetLength` stamps the SYSTEM code page, not the unit's.** The same function
    then returned a string tagged 1252 while the engine speaks UTF-8, so `=`
    against a UTF-8 string was False for identical bytes. The project's standard
    remedy for the `{$codepage UTF8}` trap is *build by index, do not concatenate a
    Char* — and that remedy leaves the wrong tag on the result. When the bytes are
    a PROTOCOL (`chr$(0)` + a code) rather than text, finish the job:
    `SetCodePage(RawByteString(Result), CP_UTF8, False)` re-tags without
    converting. Building it and tagging it are two halves of one rule.
  - **THE REAL LESSON: a path that needs a human at a keyboard is a path nothing
    is watching.** `EventToKey` is reachable only through a console handle, raw
    mode and a live keypress, so the headless suite never ran a line of it —
    and `check-codepage.py`'s own header records that an earlier sweep had already
    edited this very function. It was edited, shipped, and never executed by a test.
    The fix is not more care; it is to **separate the decision from the I/O**:
    `CrtKeyFromEvent(char, vk)` takes the two fields the console event carries and
    answers the key, with no console anywhere, and `tests/probe_crt.lpr` calls it
    directly. Seen failing: with the defect put back, the probe reports `'q'` as
    `[00]` and five checks fail.
  - **Where else this applies.** Any host-side seam that only a human, a display or
    a network peer can trigger — key decoding, mouse hit-testing, a terminal
    capability probe. Ask what part of it is a pure function of its inputs, lift
    that out, and test it. What is left needing a human should be a handful of
    lines with no decisions in them.
- **2026-09-06 · round 27 · the ceiling that was claimed and never built.**
  Phase 3 step 2 shipped `MaxSteps`, `TimeoutMs` and `MaxOutputBytes` and wrote
  down that the engine was now "safe to embed untrusted scripts". All three bound
  how LONG a script runs. **Nothing bounded where it writes**, and the sentence did
  not notice, because a plan is prose and prose does not fail a build. The bill
  arrived on 2026-09-05, outside this repository: an unbounded run of a defective
  `dir_delete("")` resolved the empty path to the root of the current drive and
  erased the working trees of thirteen projects.
  - **The rule: a safety claim is a test or it is a wish.** "Safe to embed
    untrusted scripts" is not a status line; it is a list of what a script cannot
    do, each item with a check that fails when it becomes false. When a document
    claims a property, go find the check. If there is none, either build it or
    change the sentence — the sentence is the part that will be believed.
  - **A per-call-site rule needs a gate, or it rots one function at a time.**
    `SandboxRoot` is asked at ~40 call sites; the next library function that opens
    a file is one forgotten line from being a hole, and nothing would say so. So
    the deliverable is not the guard, it is `scripts/check-sandbox.py`: it reads
    every routine a script can reach and fails the suite if one touches the
    filesystem without asking. **It found 20 holes on its first run**, three of
    which the author had already convinced himself were covered — including the
    RECURSIVE half of a lister and a deleter, where the top-level guard is asked
    once and the walk then descends on its own. *Guard the recursion, not the
    entry point: a directory symlink is how a bounded walk leaves its bounds.*
  - **A guard against destruction is tested by making your own victim.**
    `tests/probe_sandbox.lpr` builds a tree in the platform temp directory,
    OUTSIDE the root it then sets, and asserts the tree is still standing. If the
    guard ever breaks, what the test destroys is what the test created. Proven by
    disabling the root check and watching 14 assertions fail — including the one
    that reports the tree gone. The .bas half (`58_sandbox.bas`) deliberately
    attempts **no deletion outside the root at all**: if that assertion regressed
    it would BE the disaster it tests for.
  - **Redirect where you can, refuse where you must.** `temppath$`/`homepath$`/
    `cfg_path$` answer INSIDE the root rather than being refused, so a script that
    keeps working files in the platform's temp directory runs unchanged and
    contained. A ceiling a program cannot comply with gets switched off by whoever
    is in a hurry; one it does not notice stays on.
  - **The test runners have no opt-out.** `phosphortest`, `phosphorguitest`,
    `phosphorpkgtest` and `phosphorhttptest` confine the script to the working
    directory, unconditionally — no flag, no argument. The suite exists to run code
    that is being CHANGED, which is exactly the code most likely to name a path it
    did not mean to.
- **2026-09-05 · round 25 · the audit's medium and low findings, and what "low" hid.**
  Thirty-five findings across thirteen documents, filed by the audit as
  documentation. **Four of them were defects in the CODE**, and the page was the
  half telling the truth — so the page stayed and the function changed.
  - **`dir_delete` reported success for work it did not do.** `RemoveDir`'s answer
    was DISCARDED and the function returned 1 unconditionally: deleting a directory
    that still held a file answered 1, left it standing, and set no error, so a
    program had no way at all to learn it had failed. Filed *medium*. Its own
    sibling `file_delete` already answered `Ord(DeleteFile)` — the outlier was
    sitting next to the pattern.
  - **`dict_remove` answered 1 for a key that was never there** — the one question
    it exists to settle. **`json_stringify$` was documented compact and was not**,
    while the ARRAY branch of the same renderer already was, so objects were an
    inconsistency rather than a format. **`unzip_count`/`unzip_entry$` swallowed
    their exceptions** with `zip_error()` untouched, against their unit's own
    header — a caller could not tell a corrupt archive from an empty one.
  - **THE LESSON IS ABOUT SEVERITY, NOT ABOUT DOCS.** An auditor grading a
    doc-vs-code mismatch sees "the page is wrong" and files it low, because a
    reader is only misled. But the same mismatch read the other way is "the
    function is wrong", and then a program silently does the wrong thing. WHEN A
    PAGE AND A FUNCTION DISAGREE, ASK WHICH ONE IS RIGHT BEFORE ASKING WHICH TO
    EDIT — three of these four had the better behaviour written down and the worse
    one shipped.
  - **The reverse-name gate caught two of this commit's own edits** as they were
    written: a `http_ok` that does not exist and an `unzip_entry` missing its `$`.
    A gate earns its keep on the hand that installed it.

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
