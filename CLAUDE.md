# Phosphor — working rules

Phosphor BASIC is an **embeddable** BASIC interpreter in Free Pascal 3.2.2: an engine
linked as a library, plus hosts that provide the console, the GUI and the opt-in
packages. Windows + Linux, MIT. It is a spiritual successor to Plan9Basic, **not a
port** — Plan9Basic is Delphi/FMX, which has no Free Pascal peer.

This file is the short form, loaded every session. The binding document is
[docs/dev-agent-playbook.md](docs/dev-agent-playbook.md) — 1400 lines, every rule with
the defect that produced it, plus a dated retrospective per round. When a rule here is
surprising, its "why" is there. **Read the playbook before a large change.**

---

## Done means proven, on both machines

Nothing is done on a claim. An increment is complete when:

- `fpc -B -vewn` builds with **zero warnings and zero notes**. A note is a defect until
  proven cosmetic. Never suppress; fix the cause.
- Every suite is **byte-exact** green — the goldens compare bytes, not intent.
- **`-ProveFailure` was seen catching a corrupted expectation.** A harness nobody has
  watched fail is not known to be able to fail.
- The **boundary check** passes: `engine/` reaches no host or GUI unit.
- Green on **Linux too**: `ssh -i ~/.ssh/phosphor_vm andre@192.168.15.14`,
  `cd ~/Phosphor && git pull -q && bash scripts/test-suite.sh`. Windows-green has
  shipped Linux-broken defects (SIGPIPE, OpenSSL-3 soname, cert generation).
- Committed **and pushed** as `--author="AndreMurtaX <andre.murta@fhinck.com>"`, docs
  and the playbook updated. A green uncommitted increment is not shipped.

If one of these cannot be met you are **blocked** — say so precisely; do not lower the
bar.

```powershell
powershell -NoProfile -File scripts\build.ps1        # clean build + boundary check
powershell -NoProfile -File scripts\test-suite.ps1   # suite + probes + 8 gates
powershell -NoProfile -File scripts\test-classic.ps1 # also: -examples -packages -gui
powershell -NoProfile -File scripts\test.ps1
```

Same names with `.sh` on Linux.

---

## Architecture invariants

- **The engine is host-agnostic and dependency-free.** No `crt`, `lcl`, `forms`,
  `windows`, `unix`, sockets, `Data.DB`. Output leaves through one seam: `OnOutput`.
  Terminal, GUI and network are host concerns.
- **Libraries register through the `:`-signature registry** — `Reg.Add('name:sig', @fn)`,
  or `AddHost` for VM-aware ones. Codes: `n` numeric (a Double, or an `int%` widened
  into one), `%` an exact `int%` that does not widen, `$` string, `@` handle, `?`
  bool. `#` is never a code. Repeat for arity; a zero-arg function is `'name:'`.
- **The suffix on a name IS its return type** (none=Double, `$`, `%`=Int64, `@`=handle,
  `?`=bool) — and the registry never checked it against the body. Fifteen names lied
  before `scripts/check-suffix.py` existed. The suffix on the *function's own name*
  decides; a `%` argument does not make the result an Int64.
- **Errors are values, not exceptions,** inside the engine.
- **A mutator returns information, not a success flag.** A container setter answers the
  container so calls chain. A bare `1` is a defect.
- **Test-only stand-ins belong to `tests/PhosphorTestLib.pas`**, never to `engine/libs/*`
  — the shipped binaries must not carry a test artifact. `Reg.Add` **overwrites by
  signature**, so a duplicate name silently shadows.
- **External integrations are opt-in host packages** under `host/packages/`, each with a
  byte-exact test, a manifest line, and a deterministic library gate.
- **`print` emits no newline; `println` does.** Load-bearing for exact output.
- **An undeclared variable inside a function resolves to a GLOBAL.** Only names in the
  `local` list are frame slots. Do not "fix" this.

## Writing a `.bas` test

BASE-1 indexing. Conditions need a comparison (`if x <> 0 then`, not `if x then`). A
`case` label takes its own line. `on error goto LABEL` + `resume next`; `err()` and
`errmsg$()` describe it.

- **Not every assert has a message overload.** `assert_int` is `:%%` only — a third
  argument raises `no function assert_int:%%$` and halts the file. Cite the reason in a
  `rem` above.
- **A backslash in a string literal is an escape.** `"\2"` is a rejected unknown escape;
  `"\\"` collapses to one. Keep paths and cited expressions out of `msg$`, or double them.
- **`resume next` continues in CONTROL-FLOW order, and did not until 2026-09-10.**
  It used to leave the block: a loop whose failing call was the last line of its
  body ran ONE pass, stopped, and reported success, and a fault on the last line
  of a `then` block ran the `else` arm. Fixed -- each statement's boundary now
  records where that statement's code ends -- but the old behaviour is worth
  knowing, because it cost two wrong readings of a leak probe that were BOTH
  green, and because a test written before that date may still encode it.

## Traps that have already cost real time

- **`bin\phosphortest.exe` is built by the TEST RUNNERS, not by `build.ps1`.** Running it
  after an engine edit runs old code. This fired four times in one session and produced a
  wrong conclusion every time. Run the suite, not the binary.
- **Never start `phosphor.exe` with no arguments and no piped stdin** — it opens a REPL
  that never exits and locks its own executable. Always redirect; always use a timeout on
  anything that might loop.
- **A program that calls `app_run()` never returns** — it is a message loop waiting for a
  person. `examples/gui_demo.bas` is one, and `examples/manifest.txt` marks it `compile`
  for that reason: the runner compiles it and does not execute it. Same class as the REPL
  trap and it has the same tell — you are waiting on something with no console output.
- **`{$codepage UTF8}` corrupts binary string LITERALS.** Every unit sets it, so `#$8B`
  in source becomes two bytes. Build exact bytes at runtime with `Chr()`; runtime calls,
  stream writes and pointer casts are unaffected. Applies to gzip headers, `.pbc` magic,
  protocol framing.
- **A destructive defect is confirmed by READING**, or by running the repro only against a
  rebuilt binary in a disposable VM. On 2026-09-05 a scratch directory did not help: the
  defect was drive-root-relative and walked `C:\`. **Never call recursive directory
  removal on any filesystem root.** Test a destructive guard through its non-destructive
  path — the guard runs before the recursive branch.
- **A golden `.expected` records a COUNT.** If it changes, read the run and confirm every
  assertion passed before touching it. Never regenerate from a failing run.
- **An exit code answers the question the tool asked, not the one you meant.** Three
  spellings of the same trap, each of which has produced a false report here:
  - **`$?` after a pipeline measures the pipe.** Capture the exit code on its own line.
  - **`cmd | grep -q` is not a gate**: `grep -q` exits at the first match and SIGPIPEs
    upstream, so it reads non-zero *even when it matched* — an intermittent false SKIP.
  - **Windows `ping` exits 0 when a ROUTER answers** "destination host unreachable", so
    `ping host && echo up` says up for a machine that is off. Ask the port instead:
    `Test-NetConnection -ComputerName h -Port 22` (or just try the `ssh`). On 2026-09-08
    this reported a powered-off VM as online, one message after I had correctly said it
    was down.
- **A check can be written so that it cannot fail, and then it reports the thing it
  guards as broken.** The suite back-dated `bin/phosphortest` by a flat two hours and
  demanded exit 3 from `RefuseIfStale`. But a `git pull` that changes no `.pas` leaves
  every source stamped at the previous checkout, so on 2026-09-11 the Linux tree's
  newest source was SIXTEEN hours old, a two-hour-old binary was still newer than all
  of them, the guard correctly said nothing, and the harness declared the guard broken.
  It had never once fired on Linux. Windows passed the same morning by a ONE-MINUTE
  margin. **Derive a check's parameters from the thing it measures** -- the back-date
  target is now computed from the newest source the guard actually reads -- and assert
  BOTH directions, because a guard that refused everything would have passed too.
- **And a filter can hide the answer as easily as an exit code can.** Piping a run
  through `grep` for the line you expect shows nothing when the tool instead printed an
  error you did not expect — which reads like a silent pass. `scripts/test-suite.sh`
  refuses an argument it does not know for exactly this reason, and says so in a comment
  that begins "it already cost a false report once"; minutes later a `grep` of mine hid
  that refusal. When a command prints nothing, look at its exit code before believing it.
- **Pascal is case-insensitive:** a local `b` shadows a parameter `B`, a local `d1`
  shadows a function `D1`. Rename the local.
- **A `{` inside a `{ }` comment NESTS it** -- `Comment level 2 found`, a warning,
  and this project's bar is zero warnings, so it fails the build. Writing about
  JSON or about a Pascal block in a comment is how you hit it. Describe the shape
  in words, or use `(* *)` for that comment.
- **A default parameter whose default is the UNSAFE value hides an omission.**
  `RegJson(..., ALevel: Integer = 1)` -- 1 is what a ROOT has, so a borrow site
  that forgot the argument silently claimed to be at the top of its tree. A review
  measured that the omission passed every runner on both OSes at one door and was
  caught at another, which is worse than uncovered because it reads as covered.
  Make it required and the omission is a compile error.
- **Two runs of a PowerShell runner at once clobber each other.** The three `.ps1`
  runners wrote their scratch files into the shared user `TEMP` under fixed names, so
  two worktrees running suites at the same moment died on a file lock -- which reads
  exactly like a test failure. Three reviewers lost a run to it on 2026-09-11 before
  anyone named it. `$tmp` is now a per-process directory; the bash twins always used
  `mktemp`. Its cleanup is a plain `rmdir` that can only succeed on an EMPTY directory,
  deliberately, because this tree has lost thirteen working copies to a recursive one.
- **`fpc` will reuse a `.ppu` written in the same filesystem tick as the `.pas`.**
  This is the stale-binary trap one level down, and it makes a MUTATION TEST report
  false survivors: a reviewer saw five, and `-B` turned one of them straight back
  into CAUGHT. Always pass `-B` when you rebuild to test a deliberate break.
- **Mutating an engine source without rebuilding `bin/phosphor.exe` makes
  `check-examples.py` refuse for staleness** -- and in a runner summary that reads
  exactly like the gate catching your mutation. Rebuild both binaries, then read
  the failure.
- **objfpc mode has no `case`-of-string.** Use an `if`/`else if` chain.
- **Read the RTL instead of guessing about it.** `C:\lazarus\fpc\3.2.2\source`. A patch
  was lost to an assumption about `intpower` (it reciprocates the *base*, not the result)
  that one grep would have settled; `Math.Floor` returns a 32-bit Integer behind a 64-bit
  guard; `IsSameDay` is wrong for negative TDateTime.
- **NEVER write a patch script through a bash heredoc. Use the Write tool.** Not
  "prefer" -- never. A quoted heredoc still ate a backslash on 2026-09-10, in a
  script patching a Pascal string that contained one, and the failure surfaced as
  an anchor that did not match rather than as anything mentioning quoting. If a
  literal backslash has to appear in a patch script, spell it `chr(92)`.

## The gates, and why they exist

`scripts/test-suite.ps1` runs eight Python gates. Each exists because a rule stated in prose
turned out to be false and nothing could tell:

| gate | the rule it enforces |
|---|---|
| `coverage.py` | every registered name is exercised by a test **and** listed in the reference — both directions |
| `check-codepage.py` | no `Char` is concatenated into a code-page string (bytes ≥ 128) |
| `check-sandbox.py` | every routine reachable from a script that touches the filesystem asks the gate |
| `check-seams.py` | every host answers for every engine seam, in writing — a nil seam fails silently |
| `check-examples.py` | every ```basic block in the docs compiles |
| `check-suffix.py` | a registered name's suffix is the kind its body returns |
| `check-budget.py` | a loop or an allocation over a script-supplied count consults the budget, or is exempt with a reason |
| `check-manifests.py` | every `.bas` in a manifest-driven corpus is listed, and every listing has a file — a test nothing runs is not a test |

**If reordering, renaming or deleting something would break an invariant *silently*, the
check belongs in a script.** A completeness claim in prose is a promise; a gate is the
proof. `function-reference.md` called itself complete while drifting 14 functions behind.

## How this project gets things wrong

The failure modes are known, named, and keep recurring. Watch for them in your own work:

- **Fixing the instance instead of the class.** A recursion ceiling added to the one
  function where the overflow was noticed; a path rule left textual so one more spelling
  walked through; a sandbox guard put on one of a function's two path arguments. When a
  class recurs, write the check — `check-codepage.py` found eleven sites where a manual
  hunt had reported five.
- **Checking a different copy of the value than the one that acts.** The sandbox gate
  read the whole path where the kernel stops at the first `#0`; its splitter counted
  `a\b` as two components where Linux counts one; `SafeEntryName` judged the name a zip
  entry ADVERTISES while extraction wrote under the name it CARRIES. Every suite and all
  eight gates stayed green through all three. Find the read that DECIDES and judge that
  one — and when a library re-reads the value inside the call you are guarding, measure
  which hook fires where instead of picking the one that sounds late enough.
- **A guard that refuses something legitimate,** or worse, silently answers something
  wrong. A finiteness patch turned an entire band of correct subnormal results into `0`
  and passed its own byte-identical diff, because every pinned value sat outside the
  broken band. **Sweep a range against the pristine build; never a list you chose.**
- **A test that fails for the wrong reason is not a confirmation.** Read the failure
  message, not the exit code. When a test's whole value is that it broke something, assert
  that it broke. **And a test written with the fix already in hand can pass because it
  never reached the defect** -- on 2026-09-10 the assertion pinning "an outer loop whose
  body defines a function still breaks" passed on both sides of a live hang, because the
  function it defined had no loop of its own. Remove the fix, watch the new test fail,
  put it back. Every time.
- **A test written after a defect records the defect.** Four expectations in this tree
  asserted a wrong answer as correct: `tests/suite/51_arith_faults.bas` and two places in
  `tests/probe_value.lpr` pinned the float-`mod` bug, block K of `test.{ps1,sh}` pinned a
  truncated packed application opening a REPL at exit 0, and `54_onerror_reentrancy`
  pinned a loop cut short after one pass. None was careless: each was written by reading
  a run and recording what it printed, which is how a defect becomes a golden and then
  guards itself for months. **Derive the expected value independently of the
  implementation** — from an external definition (IEEE, POSIX, the RTL's own docs), from
  arithmetic written out beside the assertion, or from a second path through the engine
  that reaches the answer another way. Never off the run.
- **Saving a scope counter is not saving the scope.** The BREAK fix saved `FLoopDepth`
  around a function body and left `FLoopBreaks`/`FLoopConts` -- which are INDEXED BY that
  depth -- shared with the enclosing loop, which turned one hang into a worse one. When
  you save a variable to scope something, ask what else is keyed by it.
- **Green suites prove the absence of regression, not the presence of correctness.** With
  every golden byte-exact on both OSes, an adversarial sweep still found defects that
  killed the process. When a subsystem looks finished, attack it rather than extend it.
- **A verification stage that never rejects is measuring nothing.** Refuters that killed
  0 of 45 findings were too soft, exactly like a test that passes with the fix removed.
- **Measure the library; do not reason about it.** Two rounds of reasoning about where
  fcl-json loses bytes were wrong; a twenty-line probe answered it in one run.
- **When agents work in parallel, partition by dependency, not by directory** — and
  `isolation: worktree` is not a sandbox: an agent given a path in its prompt will use it.

## Conventions

- **Pascal: empty parens mark a CALL.** `a := Pop();` at the call site; no parens on the
  declaration, on a `property`, or after `@` (`@Foo()` is a compile error).
- **Adapt the comments with the code.** When importing or reworking an oracle test, the
  explaining `rem` lines are part of the change.
- **Improve on the reference confidently** where Plan9Basic has an artifact or a wart.
- Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
