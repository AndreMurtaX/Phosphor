# Phosphor BASIC 1.0 — scope proposal (for the owner's decision)

Written 2026-10-11, after adversarial round 10, at the owner's request. Nothing
here is decided: each section ends with the decision it needs. The roadmaps
(`roadmap.md`, `roadmap-phase2.md`, `roadmap-phase3.md`, `roadmap-net.md`) are all
complete; this is the plan for what comes after them.

## Where the project stands

| Part | Size |
|---|---|
| engine (VM, compiler, budget, sandbox, `engine/libs`) | 37 000 lines of Pascal |
| hosts (console, GUI over the LCL, opt-in packages) | 28 000 lines |
| tests | 17 000 lines of Pascal, 34 000 of BASIC |
| scripts and gates | 16 000 lines |
| docs | 24 000 lines, the playbook 5 000 of them |
| registered names | 1 147 (439 of them the GUI's) |

Rounds 7 to 10 found 9, 6, 7 and 5 HIGH survivors. Almost every one was in code
the previous round had rewritten: each round fixes 20-30 findings across dozens
of files, and that new surface is what the next round attacks. The readiness
criterion (two consecutive rounds with no HIGH) cannot be met while every round
rewrites that much.

## 1. Scope freeze

No new registered name until 1.0. Fixes only.

**Decision:** freeze — yes or no.

## 2. What is core and what is opt-in

Today every `engine/libs` unit is linked into every engine, and the six
`host/packages` units are opt-in.

Proposed **core** (the language and what a script needs to be a program):
strings (`PhosphorStrLib`), numbers, arrays, dictionaries, string lists, date and
time, errors, `callfunc`, host and platform queries, `sys`, file I/O with the
sandbox, byte buffers, JSON, regex, config (INI), and the crypto digests and
password hashing.

Proposed to **move out to an opt-in package**: RAG (`PhosphorRagLib`, 1 537 lines,
14 names). It is a retrieval toolkit, not a language facility, it is the most
expensive library to keep priced, and nothing in the core depends on it.

Kept opt-in as today: crt, http/https, sqlite, zip, gzip, base64. The GUI stays
a host.

**Decision:** RAG out of the core — yes or no; and whether anything else in the
core list above should move out.

## 3. What the execution budget guarantees

The budget (`engine/PhosphorBudget.pas`) makes `MaxSteps` and `TimeoutMs` reach
inside library calls. Today it does that by **pricing every library function**
by the work its arguments imply, and `scripts/check-budget.py` checks that each
one asks. Seven rounds in a row found defects in that subsystem: unpriced
passes, prices off by 20-800x, refusals reported on the wrong channel, refusals
that spent the run, and guards that refused legitimate work. The cause is
structural: the engine cannot pre-empt native code, so every function has to
cooperate, and 1 147 functions are 1 147 chances to get it wrong.

Three options:

- **A. Keep it as it is.** The strongest guarantee on paper; the most code, the
  most findings per round, a gate that must model every new shape of work.
- **B. Bound by the clock after every call, and by memory.** The VM reads its
  clock after every library call, not every 4 096 instructions (one
  `GetTickCount64` per call), so a run overshoots `TimeoutMs` by at most ONE
  call. One call's work is bounded by the size of its input, and the input is
  bounded by `MaxMemoryBytes`, so the overshoot is bounded too. Keep RULE 1 only
  for allocations sized by an argument (`string$(1e18)` refused before it
  allocates), keep RULE 3 (the regex structural check), and keep the waits
  (`pause`, network) charged. Drop the per-function linear pricing and its gate
  rules. Every quadratic routine must still be made linear (that is a bug in
  its own right). `docs/embedding.md` then states the guarantee as: a run
  overshoots its time ceiling by at most one library call on an input no larger
  than the memory ceiling.
- **C. Keep pricing for the core, none for the packages,** and document the
  packages as outside the guarantee.

Recommendation: **B.** It turns the largest source of HIGH findings into a
bound that holds by construction, and the only thing a host must do is set
`MaxMemoryBytes` beside `TimeoutMs` (which `embedding.md` would prescribe).
What it gives up: a step-only host (`MaxSteps` with no `TimeoutMs`) is no longer
protected from one long call, and the overshoot is measured in one call's work
rather than in units.

**Decision:** A, B or C.

## 4. How adversarial rounds run until 1.0

- Attack as widely as today.
- Fix **only HIGH** inside the round, each with a minimal change, its diff
  reviewed adversarially before merge (round 6's diff review found 13 defects
  before they shipped).
- MEDIUM and LOW go to a ledger, each with an explicit decision: fix in a
  separate batch, accept and document, or drop.
- The readiness criterion stays: two consecutive rounds with no HIGH survivor.

**Decision:** adopt — yes or no.

## 5. What 1.0 is

Proposed definition:

1. The scope above, frozen.
2. Two consecutive stabilization rounds with no HIGH survivor.
3. Every runner green on Windows, WSL and CI, with no test red for reasons of its
   own for two weeks of commits.
4. The playbook split into a short "rules in force" document (what
   `CLAUDE.md` points at, small enough to read before a change) and the dated
   history it came from.
5. A 0.2.0 release first, to put what has been built since 0.1.0 in users' hands
   while the rounds continue (it needs the owner's approval to publish).

**Decision:** this definition, or changes to it; and whether to publish 0.2.0 now.
