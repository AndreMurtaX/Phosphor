# err — reading and raising a caught error

`engine/libs/PhosphorErrLib.pas` · 5 functions · always available

## What it is for

BASIC's `on error goto <label>` catches a runtime error instead of aborting the
program. This library is the part the **handler** talks to: it answers what went
wrong, where, and lets a program raise a failure of its own that any handler
catches like the engine's own.

The design rule it follows is the one the rest of the engine follows: **an error
is a value a program can read, not an event that ends it**. Nothing here throws,
nothing here blocks, and every function answers something usable when there is no
error to describe — `err()` answers `0`, `errmsg$()` answers `""`.

Four of the five are *host-aware*: they read the caught-error state of the VM that
is executing, through the same seam `callfunc` uses. That is an implementation
detail with one visible consequence — they are meaningful **only while a program is
running**, which is the only time they can be called anyway.

## Functions

| function | what it answers |
| --- | --- |
| `err() → num` | the code of the last caught error, `0` when none. `1` integer overflow, `2` division by zero, `3` type mismatch, `4` unknown function, `5` syntax, `6` a runtime error (including one raised by `error`) |
| `errmsg$() → str` | its message, exactly as the engine would have printed it; `""` when there is no error |
| `erl() → num` | the 1-based source line the error happened on, `0` when there is none. `erl` is *where*, `err` is *what* |
| `err_clear() → num` | forget the caught error: `err()` returns to `0`, `errmsg$()` to `""`, `erl()` to `0`. Use it after a handler has dealt with something, so a later `err()` describes a later problem and not this one |
| `error(msg$) → num` | fail the current statement with a runtime error carrying `msg$`. Caught by an active handler exactly like a division by zero; with no handler it ends the program with that message. Code `6` |

## A worked example

A configuration reader that survives a bad file. The point is that the *caller*
decides what a failure means — the library only reports it.

```basic
rem Read a number from a config file, falling back to a default when
rem anything at all goes wrong -- a missing file, a key that is not a
rem number, or a value the program itself judges invalid.

rem `on error call` is the form to use inside a function: the handler is a
rem ROUTINE, so it needs no label, and a label written inside a function body is
rem not somewhere `on error goto` can reach.
failed? = false

function complain(code, msg$)
  println "config: " + msg$ + "  (code " + str$(code) + ")"
  failed? = true
  return 0                       rem 0 resumes at the next statement
endfunction

function port_or_default(path$, fallback)
  on error call complain
  failed? = false
  n = 0
  cfg@ = cfg_open@(path$)
  rem section, key, default -- three arguments after the handle. cfg_gets$ takes
  rem only a key and a default, so it would read "server" and fall back to "port".
  raw$ = cfg_get$(cfg@, "server", "port", "")
  if raw$ = "" then error("no 'port' key in " + path$)
  rem the handler RESUMED us here, it did not return for us, so every later
  rem statement has to ask whether the earlier one already failed
  if failed? = false then n = val(raw$)
  if failed? = false and (n < 1 or n > 65535) then error("port " + raw$ + " is out of range")
  on error goto 0
  if failed? = true then return fallback
  return n
endfunction

port = port_or_default("server.ini", 8080)
println "listening on " + str$(port)
```

With no `server.ini` in the working directory it prints:

```
config: no 'port' key in server.ini  (code 6)
listening on 8080
```

Six things worth noticing:

- **The config handle is not closed.** That library registers no close and no
  free at all: a handle lives until the program ends, and `cfg_save` is the only
  thing that reaches the disk. The first version of this example called a closing
  function that does not exist, and no gate caught it, because the reverse check
  could not read inside a code block. It can now.

- **A right-arity call can still be the wrong call.** This example used to read
  the port with `cfg_gets$(cfg@, "server", "port")`, which compiles, runs, and
  raises nothing — `cfg_gets$` takes a *key* and a *default*, so it looked up a
  key named `server` in section `General` and answered its default, `"port"`. The
  emptiness check could then never fire, and the program reported `port port is
  out of range` for a file it had never really read. Nothing but running it says
  so; `check-examples.py` compiles every block on this page and this one compiled.

- **A handler that answers `0` resumes; it does not return.** That is why the two
  checks after the first one ask `failed? = false` before they run. Without the
  guards a missing key reports twice — once for the key, and again for the `0`
  that `val("")` left in `n` — which reads like two faults where there was one.
  (A handler answering anything non-zero does the opposite: it re-raises, and the
  function never reaches its own `return`.)

- **`error` is not special.** The handler cannot tell a failure the program raised
  from one the engine raised, and does not need to: both arrive with a code, a
  message and a line.
- **`err_clear` before returning to normal work.** Without it, a later `err()`
  read somewhere else would still be describing this error, long after it was
  handled. The handler above does not need it because it answers through a
  variable of its own, which is the shape to prefer when the caller has to make a
  decision.

- **A label written inside a function is not a handler.** `on error goto` needs a
  label the compiler can see from where the error happens, and a function body's
  labels are not that. Inside a function, `on error call` — the handler is a
  routine, taking the code and the message.

## Where the rest of the mechanism lives

`on error goto`, `on error call`, `resume`, `resume next` and `on error goto 0`
are **language**, not library — the compiler emits them, so they are described in
[language-reference.md](../language-reference.md). This page covers only the five
functions a handler calls once it has been reached.
