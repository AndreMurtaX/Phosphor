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

It asserts 25 things — `initialize` and its capabilities, `setBreakpoints` before
`launch`, a command refused in the wrong state, the stop at the armed line,
`stackTrace` with frame 0 innermost and `(main)` outermost, `variables` with
name/value/kind/scope, `evaluate` refused to match its own capability, `continue`
once per loop pass, `exited` with the code — and that the program's own stdout is
untouched by all of it.

It is Python rather than Pascal on purpose: the other end of this protocol is a
separate program in a separate repository, and a test written in the host's own
language could agree with the host about something the specification does not say.

**`evaluate` reports `false`**, and not because it would be unsafe: there is no
side-effect-free expression entry point in this engine at all. The specification
says a host that cannot guarantee an evaluation changes nothing must say so rather
than offer a half-safe one.

**The editor cannot attach yet.** PhosphorIDE's transport is unwritten and it
disables its Debug menu on purpose while that is true. What exists today is the
engine's half of a contract that two independent implementations must agree on,
which is why the work order put it last.

---

## What a host can do without either of these

The seam is public, so an embedder can drive it from Pascal directly —
`TPhosphorEngine.OnDebug` is asked at a statement boundary and its answer says what
happens next, and `ArmDebug(lines, stopAtEntry)` says where to ask. The read-only
state window is on the VM: `DbgFrameDepth`, `DbgFrameFunc`, `DbgLocal`,
`DbgGlobal`, and the names through `TProgram.GlobalName` / `LocalName`.

This engine is single-threaded, so **stopping means calling back, not blocking**:
the seam is invoked from inside the hook and returns the next action. A host that
wants to wait for a person does its waiting inside the callback, which is what both
drivers above do. See `docs/embedding.md` for the rest of the embedding surface.
