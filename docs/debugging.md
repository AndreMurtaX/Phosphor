# Debugging a Phosphor program

Two ways to drive one mechanism. **In the terminal**, which is what you use now;
**over a socket**, which is what an editor attaches to. Both guarantee the same
thing, and it is the guarantee worth attacking first: **a program produces exactly
the same output with or without a debugger attached.**

The session goes to **stderr**. The program's own output goes to **stdout**. So
`phosphor debug x.bas > out.txt` captures the program and nothing else.

---

## The program used below

Save it as `demo.bas`. The line numbers matter in the examples, so copy it as it is.

```basic
rem a small program with a function, to watch the debugger walk
total = 0

function dobro(n) local r
  r = n * 2
  return r
endfunction

for i = 1 to 3
  parcela = dobro(i)
  total = total + parcela
  println "i="; i; " parcela="; parcela
next

println "total="; total
end
```

---

## Starting it

```text
phosphor debug [--stop-at-entry] [--break N,N] <file.bas>
```

With no `--break` it stops on the first statement. With `--break` it stops only
where you said, unless you also pass `--stop-at-entry`.

| key | what it does |
| --- | ------------ |
| `s` | step into — one statement, and *into* a call if the line has one |
| `n` | step over — a call on this line runs to completion |
| `o` | step out — run until the current function returns |
| `c` | continue to the next armed line |
| `w` | the call stack |
| `v` | variables: the stopped frame's locals, then the globals |
| `l` | list the source around here |
| `q` | stop the program (a clean stop, like `end`) |
| `h` | help |
| Enter | repeat the last command |

---

## Five things to try, with what you should see

### 1. Step into a function and watch the depth change

Run `phosphor debug demo.bas` and press `s` four times.

```text
-- entry at demo.bas:2  (depth 0)
    2 | total = 0
(dbg) s
-- step at demo.bas:4  (depth 0)
(dbg) s
-- step at demo.bas:9  (depth 0)
    9 | for i = 1 to 3
(dbg) s
-- step at demo.bas:10  (depth 0)
   10 |   parcela = dobro(i)
(dbg) s
-- step at demo.bas:5  (depth 1)
    5 |   r = n * 2
```

**depth 0 → 1** is the debugger having entered `dobro`. Without it, the step did
not step in.

### 2. Read the stack and the variables from inside the function

Still stopped on line 5, press `w` and then `v`.

```text
(dbg) w
#0  dobro()   line 5
#1  <top level>
(dbg) v
locals of dobro()
   n                    1
   r                    0
globals
   total                0
   i                    1
   parcela              0
```

`n = 1` is the parameter. `r = 0` because line 5 **has not run yet** — the debugger
stops *before* a statement, not after. The globals are listed beside the locals
because in this language an undeclared name inside a function **is** a global, so a
pane that hid them would hide most of what a function touches.

### 3. Step out and see the result already computed

```text
(dbg) o
-- step at demo.bas:11  (depth 0)
   11 |   total = total + parcela
(dbg) v
globals
   total                0
   i                    1
   parcela              2
```

The function ran to completion and returned: `parcela` is 2. `total` is still 0,
because line 11 is the statement about to run, not the one that ran.

### 4. A breakpoint inside a loop

```text
phosphor debug --break 11 demo.bas
```

Press `c` three times. It must stop **once per pass**, with `parcela` reading 2,
then 4, then 6. One stop would mean the breakpoint is not re-arming.

### 5. With no terminal it must not wait

```text
phosphor debug demo.bas < /dev/null        # NUL on Windows
```

It says once that there is no terminal, runs the program to the end, and exits 0.
A debugger that waits here would hang any script or test runner that invoked it —
the same shape as the REPL trap, which is why this one is asserted in block Q of
`scripts/test.{ps1,sh}`.

---

## What would be a defect

Worth aiming at, because these are what the engine promises.

**The program's output changing.** Compare `phosphor demo.bas` with
`phosphor debug demo.bas < /dev/null`: both must print `i=1 parcela=2 … total=12`,
byte for byte. A debugger that moves the program it is debugging is the worst
failure available here, and it is asserted three ways — detached, attached and
answering *continue*, attached and stepping — over 936 generated programs in
`tests/probe_sweep.lpr`.

**A value reading wrong, or under the wrong name.** Names carry their type suffix,
because in Phosphor the suffix is part of the name: `count%` and `count$` are two
variables. Values are rendered as `print` would render them.

**Stopping on a line you did not ask for, or not stopping on one you did.** A line
with no executable statement — a comment, a blank line, `endif` — has nowhere to
stop, and a `--break` on it simply never fires.

**A `.pbc` being accepted.** Bytecode carries no source and no variable names, so
`phosphor debug x.pbc` is refused with that reason rather than run half-blind.

---

## Over a socket

The protocol is `docs/debug-protocol.md` in the PhosphorIDE repository. **The editor
listens and the debuggee connects**, which is the direction a host implementer gets
backwards first. One JSON object per line, UTF-8, terminated by a single `\n`.

```text
phosphor debug --port 5000 demo.bas
```

The quickest way to watch a whole session is the test, which stands in for the
editor and drives one:

```text
python tests/debug_protocol_test.py bin/phosphor.exe
```

It asserts 117 things across eight sessions — `initialize` and its capabilities,
`setBreakpoints` before `launch`, a command refused in the wrong state, the stop at
the armed line, `stackTrace` with frame 0 innermost and `(main)` outermost,
`variables` with name/value/kind/scope, `evaluate` over globals, locals, a
shadowed name, a const and an array element — and twelve strings it must refuse,
`continue` once per loop pass, `exited` with the code, `pause` on a
program that never stops on its own, a one-line loop body stopping once per pass,
**a breakpoint on the first executed statement**, and **a line on every frame of a
recursion** — and that the program's own stdout is untouched by all of it.

The last two are there because PhosphorIDE found both by driving this host on
2026-09-16, and neither was visible to the 52 assertions that came before them.
A breakpoint on the first executed statement was answered installed and never
fired: this host always arms with stop-at-entry, because a stop is the only
thread-safe moment to take the running VM, and the engine tests entry BEFORE
breakpoints — so the first boundary was always an entry, and an entry the editor
had not asked for was resumed from in silence. It was never "line 1": every
fixture anyone writes opens with a comment, so it was line 2 that could not be
stopped on, and nobody noticed for a year.

It is Python rather than Pascal on purpose: the other end of this protocol is a
separate program in a separate repository, and a test written in the host's own
language could agree with the host about something the specification does not say.

### `evaluate`, and what it will not do

**`evaluate` reports `true` as of 2026-09-17**, and the paragraph it replaces was
right about the engine and is still right: there is no side-effect-free expression
entry point in here, and there is no new one. What changed is that the host stopped
needing one.

The specification's rule is that a host which cannot guarantee an evaluation
changes nothing must say `false` rather than offer a half-safe one. This host can
guarantee it, in five steps, and the guarantee is checkable rather than promised:

1. **The whole source is compiled again with one line appended** — `<hidden> =
   (<expr>)`. Appending can only ADD names and instructions, so every global index
   and every instruction of the running program is where it was; that is the
   property `TPhosphorEngine.ReplRun` has rested on since the REPL existed
   (`PhosphorEngine.pas:117-131`), and it was checked over 154 real programs rather
   than assumed. It costs one compile: 0,9 ms on the mean of 7558 `.bas` files in
   the two repositories, 15,7 ms on the worst.
2. **The gate reads the EMITTED INSTRUCTIONS, never the text.** `expr` is a string
   an editor sends verbatim, and `total) : total = 99 : println (1` is a legal line
   whose middle statement writes a global. The compiler refuses most such smuggles
   — but by accident, on the trailing fragment failing to be a statement rather
   than on the payload, so balancing the tail gets them all past it. A comment
   defeats any scheme that neutralises the tail by appending a terminator. None of
   that is visible to a text rule and all of it is plain in the instruction
   stream, which may contain only opcodes that compute, and exactly one store: the
   last instruction, into the slot this host itself named. 39 hostile strings were
   measured against it.
3. **No call the user writes is performed**, which is what `capabilities.
   evaluateCalls: false` says out loud. `len(x$)` is refused along with all 1145
   registered names, because `TPhosphorRegistry` carries no notion of an effect —
   its whole answer is Found/IsHost/Func — so this host cannot tell `len` from
   `kill` and does not guess. `a@[i]`, `s$[n]` and `s$[[n]]` DO answer: they reach
   a call, but not one the user wrote, because the compiler lowers bracket syntax
   to `arr_get` / `strline$` / `strchar$` (`PhosphorCompiler.pas:1035`, `:1046`,
   `:1056`), and refusing them would mean a debugger that renders an array as `@1`
   in its variables pane and then declines to look inside it. Each is allowed only
   when the program defines no function of that name and arity: `opCall` asks
   `FindUserFunc` first, so a program defining `function arr_get(a@, k)` would turn
   `a@[1]` in a watch box into arbitrary user code. Removing that one guard was
   measured turning four protocol assertions red.
4. **It runs on a VM created for the request and freed with it** — no `OnOutput`,
   no `OnInput`, no `OnBreakpoint`, no `OnDebug`, its own step, time and memory
   ceilings — seeded from the stopped VM with every global, and then with the
   chosen frame's locals over the globals of the same name, which is the
   language's own shadowing rule rather than a second copy of it. A fresh VM has
   nothing to save and restore, which is not a smaller version of that problem but
   the absence of it: the alternative needed fifteen fields put back, a list that
   is a snapshot of what `ExecFrom` touches and has no test that is not a second
   copy of itself.
5. **The handle registry is checked either side**, because it is the one piece of
   program state a fresh VM does not isolate — it is process-wide. If the count of
   live handles moved, no answer is sent.

What this bought that a hand-written evaluator would not: the language's own
precedence, including the two irregularities a re-implementation gets wrong.
`-2 ^ 2` is `-4` because `^` takes a PRIMARY base (`PhosphorCompiler.pas:1331-
1346`), `2 ^ 3 ^ 2` is 64 because it is left-associative, and `a < b < c` does not
chain because `ParseComparison` is an `if` and not a `while` (`:1378-1398`). A
second expression reader was built and checked against the engine over 77
expressions before this was chosen; it worked, and it was a second copy of a
language whose precedence is eleven private procedures with the operator sets
written inline. The sibling repository has spent three roadmap items on rules that
existed twice and drifted.

### A breakpoint with a condition

**`capabilities.conditionalBreakpoints` reports `true` as of 2026-09-17.**
`setBreakpoints` takes an optional `conditions` array, parallel to `lines` and read
by the same index, and a breakpoint whose condition is false is **not a stop**: the
program halts at the boundary as it always did, the condition is evaluated there,
and the editor is told nothing at all. No event, no round trip, no band, no
repainted panes.

**It is the same evaluator, and that is the point.** A condition and a watch cannot
come to disagree about what an expression means, because `EvaluateExpr` has exactly
one caller-visible behaviour and two callers. Everything the section above says
about the gate, the fresh VM and the refused calls is true of a condition word for
word -- including that `len(x$)` is refused, which is worth knowing before you type
one.

**Three answers, and each is a decision that could have gone the other way:**

- **A condition that does not COMPILE is refused in the `setBreakpoints` reply**,
  under a `rejected` key carrying the line, the condition and the host's own
  wording — and the breakpoint is then installed **unconditional**. Refusing at
  reply time is what lets an editor put the message beside the line while the
  person is still looking at it. Installing it unconditional is the lesser of two
  evils: a mark that is visible and never honoured is worse than one that fires too
  often. `rejected` is omitted entirely when there is nothing to reject, so a
  client that has never heard of it sees the reply it always saw.
- **A condition that compiles and then cannot be EVALUATED stops the program**, and
  the `stopped` event carries `text` saying why. A name out of scope at that line
  cannot be caught at reply time -- scope is a frame and there is no frame yet --
  so the choice is between stopping with an explanation and a breakpoint that
  silently never fires. The first puts the mistake in front of the person who made
  it, on the line they made it on.
- **A condition that is not a BOOLEAN is the same case.** `if` in this language
  refuses a non-boolean outright, so `i% + 1` as a condition is not a truthiness
  question a debugger gets to answer differently from the language it is debugging.

**Only a breakpoint stop is filtered.** A step that happens to land on a conditional
line stops, because the person asked to step and the condition is not about them;
so does an entry, a pause and an exception.

**What it costs, measured, and what is not done about it.** One condition is one
evaluation, and an evaluation is a compile. On a six-line program that is 0,039 ms
per hit -- 5000 hits in 196 ms, which is FASTER than the 5000 round trips the same
breakpoint would have cost unconditional. On a 606-line program it is **2,3 ms per
hit**: 2000 hits in 4,5 s, against 11,5 s for the same mark with no condition.

Half of that went away when the BASE source stopped being recompiled on every
evaluation -- it cannot change, `FSource` is written once -- which took the same
measurement from 4,3 ms to 2,3. The other half is the chunk itself, and it is **not
cached, deliberately and not by oversight**: a cache keyed on the expression would
take a hit to microseconds, and `TProgram.Patch` re-points the prologue's
`opPushConst` instructions at fresh constants so the kept program does not grow --
measured at zero instruction growth over 10000 correct evaluations. It is a known
piece of work with a proven technique, and it is not in this increment.

**A defect it found on the way.** `TPhosphorVM.Create` did not initialise
`FErrHandler`, and 0 is a valid pc, so a freshly created VM carried an `ON ERROR`
handler installed at instruction 0. `Run` resets it; `RunFrom` deliberately does
not, because a handler is part of a REPL session — so the hole was exactly a VM
created and then driven by `RunFrom`, which is what `evaluate` does and nothing
else did. It was invisible because what happened next depended on the program's
own text: one containing `end` reached that halt and `RunFrom` returned **True**
for a run that had faulted, with `LastError` empty. `probe_bytecode` now pins the
pair, with and without `end`, because a check on the second half alone passes with
the defect in place.

**The editor attaches.** PhosphorIDE drives this protocol end to end as of
2026-09-16 — start, breakpoints, step over/into/out, continue, a variables pane
and a call-stack pane — on Windows and on gtk2. That sentence used to read "the
editor cannot attach yet"; it is kept in the history because the contract was
written and agreed before either end could exercise it, which is what made two
independent implementations meet at all.

A second implementation is also the only thing that finds certain defects. Both
of the ones fixed on 2026-09-16 were reported by the editor's side, and both were
invisible from here: the assertions in this file all had a comment on line 1.

---

## What a host can do without either of these

The seam is public, so an embedder can drive it from Pascal directly —
`TPhosphorEngine.OnDebug` is asked at a statement boundary and its answer says what
happens next, and `ArmDebug(lines, stopAtEntry)` says where to ask. The read-only
state window is on the VM: `DbgFrameDepth`, `DbgFrameFunc`, `DbgFrameCallerLine`,
`DbgLocal`, `DbgGlobal`, and the names through `TProgram.GlobalName` /
`LocalName`.

`DbgFrameCallerLine(AFrame)` is the line the CALLER was on when it entered that
frame, and a host wants it one off from where it looks: the line where activation
`i` is standing is the caller line of the frame `i` called into. It reads
`TCallFrame.CallerStmtPC`, which has ridden on every activation since faults
learned to resume in the caller — nothing new is recorded for it.

This engine is single-threaded, so **stopping means calling back, not blocking**:
the seam is invoked from inside the hook and returns the next action. A host that
wants to wait for a person does its waiting inside the callback, which is what both
drivers above do. See `docs/embedding.md` for the rest of the embedding surface.
