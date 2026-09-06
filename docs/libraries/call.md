# call — running a BASIC routine chosen by name at run time

`engine/libs/PhosphorCallLib.pas` · 6 functions (46 registry entries) · always available

## What it is for

Some programs cannot know at compile time which routine to run: an event table,
a dispatch table keyed by a command word, a list of steps read from a file. This
library is the one that closes that gap — `callfunc` takes the *name* of a BASIC
user function as a string, runs it, and gives back its result.

It is the language-visible face of the engine's host-callback seam
(`TPhosphorVM.CallUserFunc`): the same re-entrant path a GUI event dispatcher
takes to reach a handler. Proving it here, headless and with no GUI at all,
froze that seam before phase 2's LCL host was built on top of it — which is why
a console program can exercise the exact mechanism a button click uses.

There are five spellings of `callfunc` and **one** primitive. The suffix on the call
(none / `%` / `$` / `@` / `?`) is chosen to read as the callee's return type, one
per value kind, so `n% = callfunc%(...)` and `ok? = callfunc?(...)` read right.
The suffix is *not* a check: the value that comes back is whatever the routine
returned, and its kind is verified where it is finally stored, like any other
value. `z$ = callfunc$("bump")` on a routine that returns a number does not fail
at the call — it fails at the assignment, with `cannot store int into string
variable` (`err()` code 3).

Two things a caller would otherwise be surprised by. First, the name is matched
**exactly** — suffix and all (`"shout$"`, `"identity@"`), case-insensitively —
because the suffix is part of a function's name in this language; storing
`"shout"` for a routine called `shout$` finds nothing. Second, a routine you call
this way runs over the **caller's globals and handles**, with fresh locals of its
own: an event handler bumping a shared counter is the canonical use, and a handle
passed in and returned is the same live object, not a copy.

**Where it looks, and in what order.** The program's own routines first, the
library second — the same two lookups, in the same order, that a direct call
makes. So `callfunc("sqr", 9)` means what `sqr(9)` means, and a routine your
program defines under a library name shadows that library name here exactly as it
does everywhere else. *(Reaching the library was added on 2026-09-06. Before that
`callfunc` saw only the program's routines, so a built-in named at run time was an
error while the identical direct call worked.)*

## Functions

`name$` is the routine to run. Up to **eight** arguments may follow it, each of
any of the five kinds, and each is passed straight through, unconverted, in
order.

**Checking before calling.** A name that comes from data — a dictionary, a
configuration file, something typed — cannot be checked when the program is
packed: a name in a dictionary is not an instruction, and no amount of analysis
makes it one. `phosphor pack` does check an indirect call whose callee is written
at the call site, because that name is a constant like any other; everything else
is a runtime error by nature. What `funcexists?` adds is *when* the program finds
out: a dispatch table built at startup can be validated at startup, in the place
that built it, instead of failing on whichever branch reaches the bad entry
first.

That arity is not free-form by accident. The registry resolves a call by its
argument KINDS, so a signature per kind combination would be 5^n keys for n
arguments — in a table that is searched linearly. Instead one signature per arity
says "any kind" at every argument position, and it is consulted only after normal
resolution has found nothing, so no ordinary call pays for it.

| function | what it answers |
| --- | --- |
| `callfunc(name$) → num` | the result of running `name$` with no argument. When neither the program nor the library has anything of that name taking none: a catchable runtime error, `err()` code 4 — never a silent no-op and never a `0` |
| `callfunc(name$, a, …) → num` | the same with one to eight arguments. The parameter count is part of the match, in both places it looks: a routine declaring two parameters is not reached by a one-argument call, and the message names the call it could not resolve as a **signature** — `no function missing$:$%`, one kind code per argument (`n` number, `%` int, `$` string, `@` handle, `?` bool) |
| `callfunc$(name$ [, a, …]) → str` | the same call, written where the callee returns a string. Answers the routine's value unchanged; if that value is not a string, nothing fails here — the mismatch surfaces as a type error (code 3) at the variable or expression that receives it |
| `callfunc%(name$ [, a, …]) → int` | the same, written where the callee returns an `int64` |
| `callfunc@(name$ [, a, …]) → handle` | the same, written where the callee returns a handle. The handle that comes back is the live object, not a copy — mutating it through the returned name changes what the callee still refers to |
| `callfunc?(name$ [, a, …]) → bool` | the same, written where the callee returns a bool |
| `funcexists?(name$) → bool` | can this name be called at all — by this program or by the library — **without calling it**? The same two places, in the same order. About the NAME only: the arity and kinds of a call that has not happened yet are not knowable, so there is no arity form and this never guesses |

Three failures are shared by all five spellings, and all three are catchable by
an `on error` handler installed in the **caller**:

- **The routine itself fails.** The error arrives at the caller unchanged — code,
  message and line describe what went wrong inside the callee, and it is handled
  once, by the level that installed the handler. `resume next` continues at the
  statement after the call; the assignment never completed, so the target variable
  still holds whatever it held before.
- **Too much re-entrancy.** Each `callfunc` re-enters the interpreter with a
  native call and so spends process stack, which is bounded at 256 levels:
  `call nesting too deep: <name> is more than 256 re-entrant calls in`. Ordinary
  BASIC recursion is a jump inside one interpreter loop and is *not* bounded by
  this ceiling.
- **`end` inside the callee ends the program.** Not just that routine. Nothing
  after the call runs, and the call yields no value at all — a pending expression
  it was part of is abandoned rather than completed with a fabricated result.

A call may also be written as a statement on its own, `callfunc("bump")`, when it
is run purely for its effect on shared state; the return value is discarded.

## A worked example

A dispatch table, headless: three entries, each the *name* of a routine, fired in
order by a loop that knows nothing else about them. `onclose` is deliberately
never defined, so the third iteration shows what an unbound event does.

```basic
rem An event table. Each entry is the NAME of a BASIC routine; the loop that
rem fires them knows nothing about them beyond that name.

handlers@ = sdim@(3)
handlers@[1] = "onopen"
handlers@[2] = "onhit"
handlers@[3] = "onclose"

score = 0

on error goto unbound
for i = 1 to arraysize(handlers@)
  r = 0
  r = callfunc(handlers@[i], i)
  println handlers@[i] + " -> " + str$(r)
next
goto done

unbound:
println "unbound event: " + errmsg$()
err_clear()
resume next

done:
on error goto 0
println "score is " + str$(score)
println callfunc$("shout$", "finished")
end

function onopen(n)
  score = score + n
  return score
endfunction

function onhit(n)
  score = score + 10 * n
  return score
endfunction

function shout$(t$)
  return ucase$(t$) + "!"
endfunction
```

It prints:

```
onopen -> 1
onhit -> 21
unbound event: no function onclose:%
onclose -> 0
score is 21
FINISHED!
```

Three things worth noticing:

- **The handlers moved `score`, which is the caller's global.** Neither routine
  was passed it and neither returned it into place; they simply ran over the same
  variables. That sharing is the whole point of the seam — it is how a GUI handler
  bumps a counter the form already displays.
- **`r = 0` before the call is doing real work.** The unbound third entry fails
  *during* the assignment, so `r` is never written; `resume next` then continues
  at the `println`, which would otherwise print the previous iteration's 21 under
  the name `onclose`. A failed call leaves its target alone — it does not zero it
  for you.
- **`no function onclose:%` is one message for both places.** It does not say
  "no BASIC function", because by the time it is written the engine has looked in
  the program's routines *and* in the library and neither had the name — and from
  the caller's side that is one question, not two. The `%` is the kind of the one
  argument passed: `i` is a `for` counter, so it is an integer.

## Notes / Where the rest lives

These five register through `AddHost`, so the VM hands each call the engine that
is executing and the primitive can re-enter BASIC. The library is still
host-agnostic: "run a BASIC routine" needs no console, file or window, only the
VM already on the stack. `err`/`errmsg$`/`erl` use the same seam for a different
reason — see [err.md](err.md).

A GUI host does **not** go through `callfunc` to dispatch an event; it calls
`CallUserFunc` directly with the handler name and the sender handle. `callfunc`
and an LCL button click are two callers of one mechanism, which is why the
headless tests are meaningful proof for the GUI path.

`on error goto`, `resume`, `resume next` and `end` are language, not library, and
are described in [language-reference.md](../language-reference.md). The behaviour
this page describes is pinned by `tests/suite/48_callback.bas` (every spelling,
shared globals, a handle round trip, indirect recursion), `tests/negative/
12_callfunc_unknown.bas` (an unknown name is rejected, not ignored),
`tests/suite/54_onerror_reentrancy.bas` (a fault inside a call is handled once,
and the depth ceiling is a catchable error rather than a crash) and
`tests/classic/11_callback_end.bas` (`end` inside a callee ends the program).
