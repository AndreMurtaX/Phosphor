# Proof axes

**What a sweep must cross, so that nobody has to invent the list again.**

Every adversarial round in this project has ended the same way: the builder swept,
swept well, and swept an axis that did not contain the defect. Not once was the
sweep lazy. Every time, the axis simply was not on anybody's list, because each
piece invented its matrix from scratch and nothing accumulated.

On 2026-09-11 that cost piece A1 a round — a design three critics had approved was
measured refusing 23 of 288 correct programs, because its matrix always faulted a
function *in its own body*, where two depths coincide, and the clear compared
exactly those two depths. On 2026-09-12 it cost piece B2 three rounds in a row, each
one a different uncrossed axis: the sweep measured an engine with no debugger
attached; then it attached one but only ever entered through `Run`; then it entered
every door but the host never re-entered the engine from inside the stop.

So this file is an INPUT, not a record. A briefing starts from it. A builder answers
it with a grid: which cells were crossed, which were left empty, and why.

**Add to it whenever a reviewer finds an axis that mattered.** An axis earns its
place here by having hidden a real defect once.

---

## 0. The three rules that apply to every sweep

1. **Generated from indices, never a list you chose.** A list you chose contains
   what you already suspected. `tests/suite/51_arith_faults.bas` and two places in
   `tests/probe_value.lpr` pinned a wrong answer as correct for months because they
   were written by reading a run.
2. **Pristine versus patched, one source compiled against both.** The reference is
   the engine before your change, not your expectation of it.
3. **The sweep must be shown ABLE TO REJECT before its zero is believed.** Break the
   thing on purpose, watch the sweep go red, put it back. A sweep that has never
   failed is not known to be able to fail — the same rule as `-ProveFailure`, one
   level up. Several reviewers state this explicitly and it is why their zeros mean
   something.

---

## 1. Entry doors — how the host enters the engine

Five, and a proof through one says nothing about the others. `TPhosphorEngine`:

| door | what it is | who uses it |
|---|---|---|
| `Run(source)` | compile and run a whole program | `phosphor file.bas` |
| `RunBytecode(stream)` | run a loaded `.pbc` | a packed application |
| `Prepare(source)` then `CallFunction(name, args)` | compile once, call functions many times, VM kept alive between calls | **a GUI host and a debug adapter** |
| `ReplRun(line)` | one line at a time, state carried across lines | the REPL, and `tests/classic/*.repl` |
| `callfunc(...)` inside a script | the engine re-entering ITSELF through `CallUserFunc` | any script |

The third is where the re-entrancy floor, the halted state and any step clamp
actually live, and it is the door B3 spends its whole life in. B2 round 2 was
rejected for proving 200 generated programs through `Run` and none through it.

`CallUserFunc` does not begin a run the way `Run` does. Whether a HOST-initiated
call should is a decision, and as of 2026-09-12 nobody has written it down.

## 2. What the host does inside the callback

A seam that answers instantly is the easy case and the only one most sweeps build.

| behaviour | what it tests |
|---|---|
| answers and returns at once | the ordinary path |
| **parks for a measured time** | the wall-clock ledger: a host thinking for a minute must not fail a program with a five-second budget |
| **re-enters the engine from inside the stop** | evaluate-while-stopped. The cell a debug adapter lives in: stop, evaluate, continue |
| leaves a step pending when the run ends | step state must not leak into the next run |
| answers *stop* | the halted state, and whether the session can be reused afterwards |

Round 3 of B2 was rejected because every generated program had a host that answered
and returned; the two fixtures that re-entered did so with no ceiling set.

## 3. Ceilings active during the sweep

Four, and they are independent: `MaxSteps`, `MaxOutputBytes`, `TimeoutMs`,
`MaxMemoryBytes`. Default 0, meaning off, in every shipped host — so a sweep that
sets none of them is measuring the configuration an embedder is least likely to use.

**Cross the ceilings WITH the host behaviours.** `TimeoutMs` plus a host that parks,
and `MaxMemoryBytes` plus a host that re-enters, are where the interesting defects
are: both of B2 round 3's live in that cell.

## 4. Program shape

Cross these, and one statement per line so a boundary trace is readable:

- **body** — plain · `for` · nested `for` · `while` · `if`/`else` · `select` ·
  `gosub` · direct call · call inside a loop · recursion · two-deep call · `callfunc`
- **error** — none · `on error goto` + `resume next` · `on error call` · a second
  handler installed over the first
- **fault site** — none · at top level · inside a called function · **inside a
  function called from the handler**
- **ending** — falls off the end · `end` · a trailing call

`gosub` deserves its own column wherever a rule is keyed on call depth: it moves the
`gosub` stack and NOT the frame stack, so a rule written as `(line, FFrameSP)` treats
a `gosub` as not-a-call. That is a B2 round 1 finding.

## 5. The invariant worth asserting, whatever the piece

**The debugger must be invisible to the program.** For the same source, in the same
cell of the grid above, these must be byte-identical:

- detached — no seam installed
- attached, answering *continue* at every stop
- attached, stepping through every boundary

compared on **exit code, stdout, error line and error message**. Not on timing: a
number in a commit message does not re-run, and the differential is the half that
ages well. This is the shape of `LyraDebugBench`, read as a mirror and not imported.

Where a piece is not a debugger, the same idea holds with its own pair: the answer
must not depend on the thing that was supposed to be invisible.

## 5b. Products — the cells that are not cells

**Some defects do not live on an axis. They live on a PRODUCT of two, and a sweep
that crosses each axis independently misses every one of them.**

Round 1 of the grid's own first use was rejected for exactly this: the builder
answered every axis in this file, and the reviewer found a fourth by multiplying
two of them together. Independence is the assumption that fails.

Cross these as products, and say which product each row of your grid is:

| product | why it is not two separate questions |
|---|---|
| host **re-enters** × a ceiling is **set** | the ledger is shared. Either alone is quiet; together, the host's evaluation spends the script's budget |
| the **door** × what the host does in the stop | `Prepare`+`CallFunction` has a re-entrancy floor that `Run` does not; a clamp correct at one door detaches at the other |
| the script's **error handler's install depth** × the host's **evaluation depth** | two depths that coincide in the easy case. This is the A1 axis below, and it is the one the debugger meets again |
| **presence** of a debugger × what the program can **observe** | the invariant is not only "the answers do not move the program". A debugger that is merely ATTACHED must not move it either |

A grid of crossed cells and no products is a grid that answers the questions
somebody already knew to ask.

## 6. Axes that earned their place by hiding a defect

**These are cells to cross, not history to read.** They are listed here with their
provenance because knowing which defect an axis caught is what makes a builder
cross it properly — but the table is an OBLIGATION, and round 2 of B2 was rejected
for reading it as a record. If a row is not in your grid, it is an empty cell and
it needs its reason like any other.

| axis | what it hid | when |
|---|---|---|
| handler's depth ≠ failing statement's depth | a guard refusing 23 of 288 correct programs, approved by three reviewers | A1, 2026-09-11 |
| `gosub` versus a frame-stack call | step over walking a whole block | B2 r1 |
| the door: `Prepare`+`CallFunction` versus `Run` | a stop poisoning the session; a step leaking into the next run | B2 r2 |
| host re-entering the engine from inside the stop, ceiling set | two defects in one cell | B2 r3 |
| an attached debugger at all | four sweeps that all measured an unattached engine | B2 r1 |
| a source whose newest file is older than the binary | a staleness proof that had never once fired on Linux | harness, 2026-09-11 |
| 17-digit spellings versus 15-digit | a cross-OS divergence rate understated 48× | A3 |
| key LENGTH, not just key count | an index that made a real workload slower than the scan it replaced | A6 |
| arity 3+ with a dense key set | 143 wrong answers from one order-affecting line, every runner green | A2 |
