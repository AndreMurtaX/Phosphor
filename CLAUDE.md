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
powershell -NoProfile -File scripts\test-suite.ps1   # suite + probes + 6 gates
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
  or `AddHost` for VM-aware ones. Codes: `n` numeric, `$` string, `@` handle, `?` bool;
  repeat for arity; a zero-arg function is `'name:'`.
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

## Traps that have already cost real time

- **`bin\phosphortest.exe` is built by the TEST RUNNERS, not by `build.ps1`.** Running it
  after an engine edit runs old code. This fired four times in one session and produced a
  wrong conclusion every time. Run the suite, not the binary.
- **Never start `phosphor.exe` with no arguments and no piped stdin** — it opens a REPL
  that never exits and locks its own executable. Always redirect; always use a timeout on
  anything that might loop.
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
- **`$?` after a pipeline measures the pipe.** Capture the exit code on its own line. And
  never gate on `cmd | grep -q`: `grep -q` exits at the first match and SIGPIPEs upstream,
  so it reads non-zero *even when it matched* — an intermittent false SKIP.
- **Pascal is case-insensitive:** a local `b` shadows a parameter `B`, a local `d1`
  shadows a function `D1`. Rename the local.
- **objfpc mode has no `case`-of-string.** Use an `if`/`else if` chain.
- **Read the RTL instead of guessing about it.** `C:\lazarus\fpc\3.2.2\source`. A patch
  was lost to an assumption about `intpower` (it reciprocates the *base*, not the result)
  that one grep would have settled; `Math.Floor` returns a 32-bit Integer behind a 64-bit
  guard; `IsSameDay` is wrong for negative TDateTime.
- **Bash heredocs mangle backslashes.** Write patch scripts with the Write tool, or
  rewrite so no escape is needed.

## The gates, and why they exist

`scripts/test-suite.ps1` runs six Python gates. Each exists because a rule stated in prose
turned out to be false and nothing could tell:

| gate | the rule it enforces |
|---|---|
| `coverage.py` | every registered name is exercised by a test **and** listed in the reference — both directions |
| `check-codepage.py` | no `Char` is concatenated into a code-page string (bytes ≥ 128) |
| `check-sandbox.py` | every routine reachable from a script that touches the filesystem asks the gate |
| `check-seams.py` | every host answers for every engine seam, in writing — a nil seam fails silently |
| `check-examples.py` | every ```basic block in the docs compiles |
| `check-suffix.py` | a registered name's suffix is the kind its body returns |

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
- **A guard that refuses something legitimate,** or worse, silently answers something
  wrong. A finiteness patch turned an entire band of correct subnormal results into `0`
  and passed its own byte-identical diff, because every pinned value sat outside the
  broken band. **Sweep a range against the pristine build; never a list you chose.**
- **A test that fails for the wrong reason is not a confirmation.** Read the failure
  message, not the exit code. When a test's whole value is that it broke something, assert
  that it broke.
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
