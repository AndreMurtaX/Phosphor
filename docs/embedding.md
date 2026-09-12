# Embedding Phosphor BASIC

Phosphor is a **library**. A host program links the engine, registers its own
functions, runs user scripts, and exchanges values with them — and the engine
never learns who is driving it (see [architecture.md](architecture.md), "The one
rule"). The console REPL, the LCL GUI and the `phosphorembed` example are three
consumers of the *same* engine; yours is another.

The worked example this document follows is
[`host/embed/phosphorembed.lpr`](../host/embed/phosphorembed.lpr) — a host that
registers a function, prepares a script once, and calls its routines from Pascal.

## Getting the units into your project

Add the Lazarus package once, then depend on it:

```bash
lazbuild --add-package-link lazarus/phosphor_engine.lpk
```

**Project → Project Inspector → Add → New Requirement → `phosphor_engine`.** It
is a *runtime* package — 29 units, no LCL, no components to install into the
IDE. See [../lazarus/README.md](../lazarus/README.md) for what it does and does
not carry, and `lazarus/demo/` for a Lazarus application with the whole thing
wired up, which the suite builds and exercises on every run.

Without Lazarus, two unit paths are the entire requirement:

```
-Fu<phosphor>/engine -Fu<phosphor>/engine/libs
```

plus `-Fu<phosphor>/host/packages` if you want the opt-in libraries (zip, gzip,
http, sqlite, base64, crt) and `-Fu<phosphor>/host/gui/libs` if you want the GUI
bindings. The engine itself needs neither.

## The facade — `TPhosphorEngine`

```pascal
uses PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorEngine;
     // ...and PhosphorVM as well, if you register a HOST function (AddHost):
     // its signature names TPhosphorVM, so the unit has to be visible.

var eng: TPhosphorEngine;
eng := TPhosphorEngine.Create;    // registers all built-in libraries
try
  // ... register host functions, set OnOutput/limits, run or prepare ...
finally
  eng.Free;                        // frees any prepared VM and its handles
end;
```

`Create` builds the registry and registers the whole standard library (strings,
numbers, arrays, dictionaries, JSON, date/time, regex, I/O, config, `callfunc`,
`ON ERROR`, ...). You add yours on top.

## Four ways to run

- **One-shot:** `eng.Run(source)` compiles and runs `source` to completion.
  Returns `0`, or the 1-based line of the first error (`eng.ErrorMessage`
  explains it). This is what the console and test hosts use.

- **Embedding (load once, call many):** `eng.Prepare(source)` compiles and runs
  the script's *top level* once — defining its routines and doing any setup — and
  keeps the VM **alive**, with its globals and handles intact. You then call the
  routines it defined as often as you like:

  ```pascal
  rc := eng.Prepare(userScript);                 // 0 on success
  v  := eng.CallFunction('total', [ValInt(3), ValInt(100)]);   // -> a TValue
  v  := eng.CallFunction('greet$', [ValStr('world')]);
  ```

  Each `CallFunction` runs over the same live globals and handles the script set
  up. A second `Prepare` (or `Finish`) discards the previous one.

  **`end` means two different things and the difference is the one an embedder
  has to know.** A script's top level ends with `end` more often than not — the
  language reference teaches it as the way to stop before a block of functions —
  and that ends the *top level*, nothing more: `Prepare` returns `0` and every
  routine it defined is callable. But `end` reached inside a routine YOU called
  means the script has decided its work is finished. That call returns a default
  value with no error, because `end` is not `return` and there is nothing to
  return; every later `CallFunction` is then refused outright with `peRuntime`
  and a message that says so. `eng.Halted` reports it if you would rather ask
  than be told, and `Prepare` again is the way back.

- **Precompiled bytecode:** `eng.RunBytecode(stream)` runs a `.pbc` compiled
  earlier (`phosphor compile a.bas a.pbc`), with no lexer or compiler involved.
  Give it a `TFileStream` over the file, or a `TBytesStream` over an embedded
  payload. A stream that is not a valid `.pbc` — wrong magic, unsupported version,
  a mismatched opcode set, or corruption — is refused with a clear message (return
  `1`), never executed as the wrong opcodes.

- **A line at a time (REPL):** `eng.ReplRun(line)` compiles and runs one line
  against a VM that persists between calls, so variables and routines defined on
  one line are there on the next; `eng.ReplReset` starts over. This is what the
  console host's prompt uses, and what an embedder wants for a command box.

## Registering a host function

A host function is a plain function matching one of two shapes, added to the
registry by a **signature** `'name:codes'`:

```pascal
function host_discount(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValDouble(0.10);
end;

eng.Registry.Add('host_discount:', @host_discount);   // no arguments, returns a number
```

Now a script can call `host_discount()` like any built-in. The signature's codes
are the argument kinds, in order; the alphabet (see
[decisions.md](decisions.md) and `PhosphorRegistry`):

| code | kind |
|---|---|
| `n` | numeric (accepts a Double, or an int% widened) |
| `%` | integer (exact int%, no widening) |
| `$` | string |
| `@` | handle |
| `?` | bool |

So `Add('clamp:nnn', @clamp)` registers a three-number `clamp`, and overloads are
just more `Add`s under the same name with different codes. The function's own
name may carry a return-type suffix for the caller to read (`greet$`, `dim@`); it
is part of the name, not a code.

**Registering a lot of names is free at the call site.** The registry indexes its
signatures, so what a call costs does not grow with how many are registered, or
with where yours sits among them: resolving against a table of 8,194 signatures
costs the same for a key registered near the front of it and one registered last
(`tests/probe_registry.lpr`, which fails if that stops being true). *Resolution*
is what is free. `funcexists?` is not: it asks a name-prefix question the
signature index cannot answer and still scans every registered signature, about
100 us a call on the shipped host, so keep it out of a loop. Until
2026-09-11 it was a linear scan run once per integer-widening combination: a loop
calling a two-integer built-in cost about 13x the same loop without the call, and
now costs about 1.2x — roughly 21 us of overhead per call on the shipped host
against under half a microsecond today.

**Which overload wins is a rule, not an accident of registration order.** An
exact reading beats one that has to widen an `int%` into an `n` slot; among
readings that widen, the fewest widenings wins, wherever that reading happens to
be found, and a tie between two equally cheap readings goes to the one that
widens the EARLIER argument (`t:n%` answers a two-int call, not `t:%n`); a `*`
wildcard answers only what no exact reading can. The order is the same before and
after the indexing above, and `tests/probe_registry.lpr` pins it in both
directions — including the case where the costlier reading is the one the engine
reaches first.

**Calling back into BASIC.** A function that must run a BASIC routine (an event
dispatcher, an indirect call) uses the host-aware shape and `AddHost`; it receives
the executing VM (as `TObject`; cast to `TPhosphorVM`) and can call
`CallUserFunc`:

```pascal
function invoke(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Result := TPhosphorVM(AVM).CallUserFunc(Args[0].Str, [Args[1]], Err);
end;
eng.Registry.AddHost('invoke:$n', @invoke);
```

## Exchanging values — `TValue`

Values crossing the boundary are `TValue` (five kinds:
`vkDouble/vkString/vkInt/vkHandle/vkBool`). Build them with the constructors and
read them by kind:

```pascal
ValInt(42)   ValDouble(3.14)   ValStr('hi')   ValBool(True)   ValHandle(id)

case v.Kind of
  vkInt:    n := v.Int;
  vkDouble: x := v.Num;
  vkString: s := v.Str;
  vkBool:   b := v.Bl;
  vkHandle: h := v.Hnd;
end;
ValToStr(v)   // a locale-independent text form of any value
```

Everything is base-1 and UTF-8, as inside the language.

## Errors, not exceptions

The engine records errors; it does not raise into your program. After `Run`,
`Prepare` or `CallFunction`, check the engine's state:

```pascal
v := eng.CallFunction('boom', []);
if eng.LastError.Code <> peNone then
  Writeln('script error: ', eng.ErrorMessage);   // e.g. "division by zero"
```

Codes (`PhosphorErrors`): `peNone` 0, `peIntOverflow` 1, `peDivByZero` 2,
`peTypeMismatch` 3, `peUnknownFunction` 4, `peSyntax` 5, `peRuntime` 6, `peLimit`
7, `peFatal` 8. A script can also handle its own errors with `ON ERROR` (see
[roadmap-phase3.md](roadmap-phase3.md)).

### Reading a program one line at a time

A host with a prompt — a REPL, a console pane, a scripting bar — has to tell two
different failures apart. `if a = 1 then` with nothing after it is not wrong; it is
**unfinished**, and the answer is to read another line. `csae 2` for `case 2` is
wrong, and no continuation will ever repair it.

Two properties answer that, and both are about the last **compile**:

```pascal
if eng.ReplRun(line) <> 0 then
begin
  if eng.ErrorUnterminatedBlock and eng.ErrorAtEndOfInput then
    pending := line          // a block with no terminator, and the input ran out
  else
    ShowMessage(eng.ErrorMessage);
end;
```

`ErrorUnterminatedBlock` says the failure was something opened and never closed: an
`if`, a loop, a `select case`, a `function` — or a JSON literal spread over several
lines, which continues at a prompt for the same reason a block does.
`ErrorAtEndOfInput` says the **parser** ran out of input — it asked for the next
token and the file had ended — rather than a wrong token turning up where the
terminator belonged.

That word *parser* is load-bearing. A check that runs once the whole program has
been read answers `False` here even though there is nothing left to read: `goto
nowhere` is not a program waiting for another line, it is a program that is wrong,
and the lexer merely happens to be parked at the end by the time the label is
looked up.

**Ask both**, even though the first is the one that carries the answer today. The
second is the belt: it is inferred from the token the parser was actually looking
at, for every failure the parser raises, so a construct added to the engine later
that records "unterminated" at a real token cannot make your prompt wait for a line
that can never come. It costs one `and` — and because the two now agree on every
refusal the engine's own corpus sweep can produce, a construct that runs out of
input without saying so fails a test rather than reaching your prompt.

Both describe the last **compile**, and both are cleared by every entry point —
`Run`, `RunBytecode`, `Prepare`, `CallFunction`, `ReplRun` — so they never answer
about a compile that failed earlier in the session.

Do not classify by `ErrorMessage`. The console host did, against nine string
literals of its own, and the wording could not be improved without breaking
multi-line entry at the prompt with nothing anywhere to say so. The text is for a
person to read; these two are the interface.

### When the interpreter itself takes a fault

Codes 1 to 6 describe something the **program** did. `peLimit` describes a
ceiling **you** set. `peFatal` is different in kind: it says something happened
**to the interpreter** — an access violation, a stack overflow, a corrupt heap.

`ON ERROR` is never offered a `peFatal`, and `err()` never returns 8 inside a
script. That is deliberate, and it is the one design choice here worth
understanding, because the engine is perfectly capable of offering it:

> By the time an access violation fires, a wild write has **already landed**, and
> nothing in the exception says where or what it hit. A script that catches it
> and carries on answers wrongly instead of dying — and a wrong answer nobody is
> told about is worse than a crash, because a crash is loud.

So a fault always ends the run. What you choose is whether it also ends your
**process**:

```pascal
eng.ContainFaults := True;
if eng.Run(src) = 0 then
  { fine }
else if eng.LastError.Code = peFatal then
begin
  Log('the script engine faulted: ' + eng.ErrorMessage);
  SaveEverything();          // your user's work is still here
  ShutDownCleanly();
end
else
  ShowMessage('script error: ' + eng.ErrorMessage);
```

`ContainFaults` is **off by default**, because it changes what escapes `Run` and
a host that would rather fail fast should keep failing fast. With it off, the
Pascal exception travels out of `Run` into your application — which, in a Lazarus
program, means the LCL's default handler and its **modal crash dialog**. On a
machine with nobody in front of it, a modal dialog is a *hang*: no message, no
exit code, nothing in a log. That is worse than the crash it replaced.

**So do at least one of these two things, whichever fits your application.**
Either set `ContainFaults` and handle `peFatal` as above, or install your own
handler before anything can raise — this is what `phosphor.exe` itself does, in
`host/console/phosphor.lpr`:

```pascal
{ FIRST, before anything can raise: take the LCL's modal crash dialog out of the
  picture. Linking Forms is what puts it there, and a binary links Forms whether
  or not it ever opens a window. }
Application.OnException := @TCrashGuard.Report;   // log, then Halt -- never a dialog
```

One caveat that is not a limitation so much as an honest boundary: **the engine
instance is spent afterwards.** A contained fault unwound Pascal frames the
interpreter still believed in, so its value stack, frame stack and handles are in
whatever state the unwinding left them. A later `Run` on the same instance
answers `peFatal` immediately without executing anything. Containment buys you
the process, not the interpreter — build a new engine if you want to go on
scripting.

## Running untrusted scripts — limits

If the script is not yours, bound it before running. Each ceiling is `0`
(unlimited) by default and costs nothing; a ceiling is **fatal** — `ON ERROR`
cannot catch it, so a script cannot escape its own limit:

```pascal
eng.MaxSteps       := 1000000;        // instruction budget (bounds an infinite loop)
eng.MaxOutputBytes := 64 * 1024;      // bytes the SCRIPT pushes through a host seam
eng.TimeoutMs      := 2000;           // wall-clock ceiling
eng.MaxMemoryBytes := 256*1024*1024;  // heap this script may ADD while it runs
```

When one is hit, the run aborts and `eng.LastError.Code` is `peLimit`. The
ceilings are cumulative over a prepared session (`Prepare` + all its
`CallFunction`s); re-`Prepare` to reset the counters.

`MaxOutputBytes` counts what the **script** pushes through a host seam, which is
`PRINT`/`PRINTLN` text *and* the payload a `BREAKPOINT` statement hands to
`OnBreakpoint` — the message plus each operand's size. What a host then writes on
its own account is the host's. The second half matters because a `breakpoint`
inside a loop is a script-driven stream like any other: with no ceiling set it is
as unbounded as `PRINT` is, and with one set it is bounded by the same number.

`MaxMemoryBytes` is measured from where the heap stood when the run began, so it
bounds what the **script** adds and not how much your application was already
holding. It is a ceiling and not a quota: an allocation already under way cannot
be interrupted, so it stops the *next* one rather than preventing every
overshoot. For an absolute bound on the process you still want a job object on
Windows or an rlimit or cgroup on Linux — but without it, three instructions
could take 14.7 GB and report success, and now they cannot.

**Four more ceilings are fixed rather than yours to set**, and they are why an
unbounded recursion ends in a message instead of in the process dying. Ordinary
BASIC recursion stops at 262,144 activation frames, and at 1,048,576 local slots
held by those frames together — a frame costs a fixed part plus a per-slot part,
and one number cannot bound both. The expression stack stops at 1,048,576 values.
A callback that re-enters the interpreter — `callfunc`, a GUI event, an `on error
call` handler — stops at 256, because those levels cost process stack rather than
heap. The first three are fatal in the same way as the three above; the re-entry
one arrives as an ordinary catchable runtime error. Before they existed,
`function f(n) return f(n + 1)` reached 1020 MB in 3.3 s, and a `.pbc` that
pushed in a loop was handed 96 GB by `SetLength` rather than the out-of-memory
exception everyone assumes is waiting there.

### The ceilings reach inside a library call, too

The step, output and time ceilings used to be tested only **between
instructions**, which left the
hole they were meant to close: a library call is one instruction, so anything
that ran long *inside* one escaped all three. A host that set exactly the ceilings above
still hung for ever on a forty-character string handed to a backtracking regex.

Since 2026-09-07 a library operation that can run long **consults the same
ceilings while it runs**, and an operation whose size its arguments already fix
**refuses up front** instead of starting:

```basic
x$ = string$(1000000000000000000, 65)   ' refused immediately, not attempted
println regex_find$("(a+)+$", "aaaa...!")   ' refused: the pattern can backtrack
```

The judge only ever refuses a pattern it can **show** is ambiguous. Anything it
cannot parse confidently — nesting deeper than it tracks, more alternatives than
it tracks, an unterminated class, a backreference — is allowed to run. That is
the direction a host is entitled to know, because the other one refuses working
patterns for a reason that is not true of them.

Two things follow for you. First, **a refusal of this kind is an ordinary
catchable error, not a fatal ceiling** — `err()` is `7`, the message names the
function and the size it declined, and `resume next` continues. Nothing has been
spent, so a script that catches it and asks for something smaller is behaving
correctly. Second, it only happens **when you set a ceiling**: a host that leaves
them at `0` behaves exactly as it always did, and pays nothing. And note which
ceilings arm it — the library budget is armed by `MaxSteps` or `TimeoutMs`, so
`MaxMemoryBytes` on its own does not turn it on. The memory ceiling is asked
directly at `+` and on the way out of every library call, which is what bounds a
script that sets only that one; the *work* refusals above still need one of the
other two.

The rule is kept honest by `scripts/check-budget.py`, one of the eight source
gates: a loop or an allocation over a script-supplied count must consult the
budget or be listed as exempt with a reason. Prose rots; this project has learned
that twice.

Three of those bound how **long** a script runs and the fourth bounds how much
**heap** it adds; `SandboxRoot`, below, bounds **where** it writes. None of them
is a wall, and what they leave open is listed after them.

## The filesystem sandbox

A script that is bounded in time and output can still delete your home directory.
`SandboxRoot` is the ceiling for that: set it and every path the script names —
through `file_*`, `dir_*`, `open … as #n`, the string-list and RAG loaders, and
the `zip`/`gzip`/`base64` packages — must resolve inside that directory, or the
call is refused.

```pascal
eng.SandboxRoot := '/var/tmp/run-42';   // '' (the default) = unbounded
if eng.SandboxRoot = '' then            // it did not take -- do not run the script
  raise Exception.Create('no sandbox root');
```

What "resolve inside" means, exactly: the path is made absolute against the
working directory, split into components the way the **kernel** splits them, and
then walked from left to right, each component's symlinks followed *before* the
next component is applied. A `..` therefore comes off what the link resolved to,
and not off the spelling.

Both halves of that walk were paid for. Resolution used to collapse `..`
textually before following any link, and the Linux kernel does the opposite
(path_resolution(7)), so `<root>/link/..` left the root while the gate said it
had not. The splitter was the second half: the RTL reads a backslash as a
separator on Unix and the kernel does not, so a directory named `a\b` was two
components to the gate and one to Linux, and every `..` after it was applied at
the wrong depth — the same escape, still live after the order was fixed. On
Windows either slash separates, on POSIX only `/`. So `../../etc/passwd`, a link
planted inside the root, a link followed by `..`, and a directory literally named
`a\b` followed by `..` are all outside the root, and all refused.

Four details worth knowing before you rely on it:

- **Read the root back, and refuse to run if it is empty.** Assigning creates the
  directory when it is not there, resolves it through symlinks, and leaves the
  root `''` when it could not be made — which is also how "no sandbox" is spelled,
  so an assignment that failed is indistinguishable from one you never wrote, and
  the script gets the whole filesystem. Nothing raises. `phosphor --sandbox` makes
  exactly this check and exits 2 (`cannot establish the sandbox root <dir> --
  refusing to run unconfined`); an embedder has to make it too. What reading it
  back answers is the root actually installed, which is the resolved absolute
  path and not the string you assigned.

- **A refusal is a value, not an exception.** `file_writealltext` answers `0`,
  `file_readalltext$` answers `""`, `dir_getfiles$` answers `""`, `dir_delete`
  answers `0`. Two of those four also record the refusal in `ioerror()` —
  `file_readalltext$` sets `2`, `dir_delete` sets `3` — while `file_writealltext`
  and `dir_getfiles$` leave the slot holding whatever the previous call put in
  it, so read it immediately after the call that refused or not at all. The one
  exception is `OPEN`, which has no return value to answer with and so fails the
  run with a catchable runtime error. This is the same house rule the rest of the
  library follows: a call that could not do what it was asked says so in its
  answer.

- **The scratch directories move inside the root.** With a root set, `temppath$`,
  `tempfilename$`, `homepath$`, `documentspath$` and `cfg_path$` all answer a
  directory inside it. A script that keeps its working files in the platform's
  temp directory therefore runs unchanged and contained, instead of failing on its
  first write for a reason it cannot see. `sandboxroot$()` reports the root; there
  is no function that sets or clears it, so a script cannot widen its own cage.

- **It is process-wide, not per-engine.** A library function is a plain callback
  with no VM to ask, so the root lives in `PhosphorSandbox` as one process-wide
  setting. Two engines in the same process share it, and the last host to assign
  `SandboxRoot` wins. If you run scripts with different trust levels, run them in
  different processes.

One rule applies **even with no root set**: a destructive call is never handed an
empty path or a bare filesystem root. `dir_delete("", 1)` used to resolve the
empty string to the root of the current drive and delete from there, answering
success — because `DirectoryExists("")` is `False`, so the post-check read the
disaster as a clean removal. An empty path, `/`, `C:\` and a UNC share root are
now refused by `dir_delete`, `dir_create` and every other write, root or no root.

Three more shapes are refused with them, each one a way the gate and the kernel
were reading different paths. A path holding a **NUL byte** is refused outright:
the gate reads the whole string and `CreateFileW`/`fpOpen` stop at the first
`#0`, so the two judged different files. It is the one shape here refused for a
**read** as well — no caller can mean a name with a NUL in it, so this refuses
rather than guess where to cut. A **directory the guard cannot identify** is
refused: `mklink /J x "C:\"` makes a directory that *is* the drive root, and
FPC's `FileGetSymLinkTarget` will not say so. Unable to say is not permission. It
is not licence to refuse either — an entry the platform resolves to the very path
already computed, such as a Store app alias, a compressed or cloud-backed file or
any reparse tag FPC declines to decode, is an ordinary file and is allowed, and
refusing those was this guard's own first over-refusal. And a path of **more than
256 components** is refused, because the walk cannot hold it: what it resolved is
then a prefix of what the kernel would open, and a `..` in the part that did not
fit could climb anywhere.

What that costs, measured on this machine with a warm cache: with a root set the
gate resolves the path **once** per call, and the two rules share the one walk.
With no root set a **read** touches no disk at all. A write or a delete asks the
filesystem one question first — does this path name a directory — which is about
20 us; when the answer is yes it walks the path as well, because the rule above
cannot see through a junction without looking, and that is 175 us for a
three-component path and 825 us for a twelve-component one, since every component
is asked about in turn. Before these rules existed all of it was nothing.

`scripts/check-sandbox.py` is what keeps this true as the library grows: it fails
the acceptance suite if any routine a script can reach touches the filesystem
without asking the gate first.

## What the four ceilings do not bound

A ceiling nobody names reads as a ceiling that is there. Everything below is
outside all four of them.

- ~~**Memory.**~~ **Closed on 2026-09-10 by `MaxMemoryBytes`,** and this entry is
  kept because it explains what that ceiling is for. `MaxSteps` counts
  *instructions*, and an instruction whose cost is not O(1) is a poor proxy for
  work. The library budget refuses `string$(1600000000, 97)` before it starts —
  but `s$ = s$ + s$`, three times over a 200 MB string, is three instructions out
  of a million, and it built the same 1.6 GB in 5032 ms at a 14.7 GB peak and
  answered `rc = 0`, under exactly the ceilings prescribed above. `+` is `opAdd`,
  a VM instruction rather than a library call, so no *library* budget is ever
  asked about it; `opAdd` now asks the memory ceiling itself, before it
  concatenates, because that is the one instruction whose result size is known in
  advance. What remains open is the *absolute* bound: a ceiling stops the next
  allocation, not the one already running, so a host that must cap the process
  still wants a job object on Windows or an rlimit or cgroup on Linux.

- **The instruction already running.** `MaxSteps` is tested before every
  instruction, but `TimeoutMs` is only sampled every 4096 of them, and neither
  interrupts the instruction underway. A program that never reaches 4096
  instructions is therefore not bounded in wall-clock time at all — which is how
  the three concatenations above finished at 5032 ms under a 2000 ms ceiling. A
  library call that can run long consults the ceilings itself while it runs; a VM
  instruction such as `opAdd` does not.

- **The network.** `SandboxRoot` is a filesystem ceiling and nothing else, so the
  `http` package reaches the internet whatever the root is. A host that does not
  want a script online does not register the package. `http_ca_file$` is the one
  place a path leaves the gate: it records a filename that OpenSSL, not this
  engine, later opens.

- **The GUI.** A host that registers the GUI packages gives the script windows,
  and no ceiling closes them. The GUI calls that touch a *file* ask the gate like
  everything else; opening a window is not a file.

- **The machine around the script.** `environ$`, `paramstr$` and
  `dir_getcurrent$` answer for the host's environment, command line and working
  directory whether a root is set or not — reading them is not writing. The
  working directory matters twice over, because it is what a relative path is
  resolved against before it is judged.

- **The host's own files.** The gate answers for paths the *script* names. What
  the host opens itself is the host's business: `phosphor --out <path>` is opened
  before the root is bound, and writes wherever the operator pointed it.

- **A second thread.** The root and the library budget are both process-wide, so
  two scripts running at once in two threads share one of each and the last host
  to set one wins. Scripts at different trust levels belong in different
  processes.

What is *not* on that list is worth saying as plainly: **a script cannot start a
process.** Nothing in `engine/` or `host/` spawns one — there is no `exec`, no
`shell`, no `system` — so the filesystem, the network and the GUI are the whole
of a script's reach outside its own memory.

## Output and input

`OnOutput` takes what the program prints. `OnInput` supplies what it reads — it is
a `TPhosphorInputProc`, `function(out ALine: String): Boolean`, and answering
`False` means end of input, which is what makes `input` and `line input` reach a
host that has no console. Leave it `nil` and a program that asks for input gets an
empty line.

`eng.OnOutput` is the one output seam: `PRINT`/`PRINTLN` text arrives there as
UTF-8 bytes (`PRINTLN` includes the trailing LF). Bind it to wherever your host
wants the output:

```pascal
procedure TMyHost.Output(const AText: String);  // matches TPhosphorOutputProc
begin  MyLog.Append(AText);  end;
...
eng.OnOutput := @host.Output;
```

A scripting host that only calls functions may leave `OnOutput` unset; a value
comes back from `CallFunction`, not through output.

## Looking at a prepared script's state

A prepared engine will tell you what its script's variables are **called**, not
just what they hold. `eng.PreparedProgram` is the compiled program and
`eng.PreparedVM` the live VM behind `Prepare`; both are `nil` when nothing is
prepared, and both are read-only — nothing on this surface changes anything, and
the interpreter's inner loop does not know it exists.

```pascal
var prog: TProgram; vm: TPhosphorVM; i: Integer;
...
if eng.Prepare(userScript) = 0 then
begin
  prog := eng.PreparedProgram;
  vm   := eng.PreparedVM;
  if not prog.HasNames then
    Writeln('names unavailable')      // a program loaded from a .pbc
  else
    for i := 0 to vm.DbgGlobalCount - 1 do
      if not prog.GlobalIsTemporary(i) then
        Writeln(prog.GlobalName(i), ' = ', ValToStr(vm.DbgGlobal(i)));
end;
```

Six things are worth knowing before you build a variables pane on this.

**Ask `HasNames` first, and mean it.** It is `True` for anything the compiler
built and `False` for a program that came from a `.pbc`. The `if` above is not
decoration: with no names, `GlobalName` answers `''` for every index *and*
`GlobalIsTemporary` answers `False` for every index — including the `SELECT`
subjects and `SWAP` scratches that are certainly in the table, because there is no
name left to judge them by. A loop written without that branch does not fail; it
quietly prints the compiler's own scratch variables under a blank name, beside the
script's, with nothing to tell them apart. Branch once at the top and show the
values by index when the answer is `False`.

**Read these properties, never hold them.** `Run`, `RunBytecode` and the next
`Prepare` all begin by discarding the current preparation, which frees the VM and
the program this pair points at. A `prog` cached before such a call is a dangling
pointer; the properties themselves go back to `nil`. Re-read them after anything
that starts new work.

**Names are lowercase.** The lexer folds every identifier before the compiler sees
it, so a script that wrote `myCounter` is reported as `mycounter`. The source
spelling is gone by the time a name reaches a table; recovering it would have to
happen in the lexer, and nothing here can do it for you.

**Some slots are the compiler's, not the script's.** A `SELECT` subject, a `SWAP`
scratch, a `FOR` bound are ordinary globals or frame slots with generated names,
and they sit *between* the script's own in the index space — there is no count to
skip. Ask `GlobalIsTemporary` / `LocalIsTemporary`, which answer for both tables
by one rule. A generated name begins with a character no identifier can begin
with, so it can never be confused with something a script wrote.

**A function's own name can appear among the globals.** `tally = acc` inside
`function tally(n)` is not a return in this language — `return` is — and an
undeclared name inside a function is a global, so the assignment makes a global
called `tally`. It will show in the dump holding a value the script's author may
believe was returned. That is the language behaving as documented, not a defect.

**Frames are only live while the VM is inside something.** `DbgFrameDepth` is 0
between calls. From inside a seam the VM called you from — `OnOutput` during a
`println` in a routine, a host function mid-call — the frames are there, and
`DbgFrameFunc`, `DbgFrameLocalCount`, `DbgLocal` and `TProgram.LocalName` describe
them. Frame 0 is the outermost call.

Every accessor answers for an index it was not given rather than faulting: a host
loops over counts, and an out-of-date count must never be able to take the process
down. `TProgram.StoppableLines` completes the picture for an editor — the ascending,
de-duplicated set of source lines a statement boundary actually lands on, which is
*not* every line of the file: `rem`, `next`, `endfunction`, `endselect`, a `case`
label and a blank line carry none, `a = 1 : b = 2` is one line with two, and a
function's header line is left out because its boundary runs once at startup and
never when the function is called.

Names are **not** written to a `.pbc`, and `HasNames` is how a program says so.
Only a script compiled in-process carries them; one from `RunBytecode` or
`phosphor compile` answers `''` for every name, safely, and reports `HasNames`
`False` so a host can say *names unavailable* rather than render a table of blanks.
The format is version 1 behind an exact-match refusal, so adding a name section
would make this build reject every `.pbc` an earlier one wrote — which is why the
names stop at the compiler.

`StoppableLines` is the one part of this surface that does **not** depend on names,
so it answers the same set either way, and it answers it ascending and without
repeats whatever order the boundaries arrive in — a `.pbc` carries each
instruction's line straight from the file, and the loader bounds indices, not line
numbers or their order.

## Stopping a running program

`eng.OnDebug` is the one seam in this engine that **may block**. Everything else —
`OnOutput`, `OnInput`, `OnBreakpoint`, `HostServices` — is a report or a question
with an immediate answer. This one is a question the VM waits on.

The engine is single-threaded, so "stop at a breakpoint" cannot mean *park the
thread and let someone else drive*: there is nobody else. It means **call back**.
The VM invokes your seam at a statement boundary, runs no further instruction
until it returns, and does what the returned action says. A host that wants to
wait for a person does its waiting **inside the callback**.

```pascal
function TMyDebugger.Stopped(AReason: TPhosphorStopReason; ALine: Integer;
                             AFrameDepth: Integer): TPhosphorDebugAction;
var
  vm: TPhosphorVM;
begin
  // Self here is YOUR object -- the seam is `of object` so you can keep session
  // state in it. The engine's VM comes from DebugVM, and only while it runs.
  vm := FEngine.DebugVM;
  ShowWhereWeAre(ALine, AFrameDepth, vm);   // read the state; see the section above
  Result := WaitForTheUserToClickSomething; // daRun / daStepInto / ... / daStop
end;
...
eng.OnDebug := @dbg.Stopped;
eng.ArmDebug([12, 37, 41], {stop at entry} True);
rc := eng.Prepare(script);
```

**`eng.DebugVM` is how the seam reaches the engine.** The callback is given a line
and a frame depth and nothing else; `Self` inside it is your adapter, not a VM.
`DebugVM` answers the VM that is executing *right now* -- through `Run`,
`RunBytecode`, `Prepare`, `CallFunction` and the REPL alike -- and `nil` at every
other moment. With it, everything in *Reading a stopped program's state* above is
available from inside a stop, including through `Run`, where `PreparedVM` is nil
because that VM is a local of the call.

**Never store it.** For `Run` and `RunBytecode` the object it points at is freed
before the call returns. Read it at each stop.

`TPhosphorVM.InterruptDebug` is the exception to that rule and the reason it is
not forwarded on the engine: it is called from ANOTHER thread while a run is in
progress, and a field this thread nils at the end of the run is not one another
thread may read. Take `DebugVM` at your first stop -- arm with stop-at-entry --
and hand that VM to the thread that will pause it. It stays alive for as long as
your seam has not returned, which is as long as the run.

`ArmDebug` hands the VM a **set of lines**, not a callback per boundary. That is
what keeps *continue* fast during a session, and the engine still knows nothing
about breakpoints — to it the set is only "lines to consult on".
`TProgram.StoppableLines` is where an editor gets the lines it may offer.
`DisarmDebug` detaches; `TPhosphorVM.InterruptDebug` is the one thing in this
engine another thread may touch, and it stops the run at its next boundary with
`srPause`.

**Both halves of an attach reach a session that is already prepared.** Installing
`OnDebug` and arming are two separate calls, and a host that clicks *Debug* on a
script it has already loaded makes them in that order, after `Prepare`. `ArmDebug`
always forwarded to the live VM; `OnDebug` was a plain field write that
`ConfigureVM` had already read and copied, so the pair disagreed and such a host
got a normal run with zero stops and no diagnostic. Both forward now, and so does
clearing `OnDebug` to detach mid-session.

**Replacing the breakpoint set from inside a stop is safe.** `DisarmDebug` then
`ArmDebug` is the natural way to write it, and it used to take the seam's
re-entrancy guard with the set — so the host's next watch expression was stopped
inside its own stop, once per boundary, each level re-syncing and evaluating
again. Disarming is about the arming; whether a seam call is live on the stack is
not something it can know.

**A seam installed and never armed costs a single Boolean test per statement
boundary, and on this hardware that is under a few percent of a tight loop and
not resolvable more precisely than that.** The hook lives in the
statement-boundary opcode's own case arm, which is about one instruction in
fourteen of a tight loop. It is not free, and what follows is the measurement
rather than a word like *negligible*, because an embedder who never intends to
debug is entitled to know what the option costs them — including how well it is
known.

The variants below are: **A** the debugger not in the binary at all — the bench
source compiled against a pristine engine from before this piece, since the hook
lives inside `PhosphorVM.pas` and cannot be unlinked from the engine that has it;
**B** the same source against this engine, seam never installed, never armed;
**C** attached with breakpoints armed that never match; **D** answering *step
into* at every boundary. Two loop shapes, four and eight million statement
boundaries, each pass over four seconds.

| | A vs B, detached | B vs C, attached and running | C vs D, one seam call |
|---|---|---|---|
| Windows | not resolvable: 0.0% and +0.8%, under ~3% across reviewers | +2.2 to +2.7% tight, +4.2 to +4.6% dense | 60-75 ns per stop |
| Linux | not resolvable: −0.4% and +0.0% | +2.5 to +3.4% / +3.8 to +5.2% | 270-320 ns per stop |

The attached columns are ranges because five people have now measured them and
they land on top of each other; the latest reading, from the committed bench over
sixteen interleaved rounds with the other machine idle, is +2.26%/+4.52% and
74/61 ns on Windows and +2.77%/+4.79% and 286/271 ns on Linux.

**The per-stop cells are the widest because they are the most quantised, and that
is arithmetic rather than disagreement.** `GetTickCount64` moves in about 15.6 ms
on Windows, so a four-second cell is known to about 0.4%, and a difference divided
by four million boundaries carries ±3.9 ns of that granularity before anything
else. The dense shape has eight million and half the quantisation, which is why
its per-stop figure is the steadier of the two. Read the column as a band, not a
number.

Run it yourself: **`tests/bench_debug.lpr`** is in the tree and is what produced
the right-hand two columns. `bench_debug --full 10` interleaves B, C and D inside
one binary and prints a `PHOSPHOR-BENCH` line per cell; build variant **A** by
compiling that same file with `-dNOSEAM` against a tree from before this piece,
and alternate the two processes round by round. The suite runs it in a quick mode
where it judges only the differential — attached and stepping change nothing a
program prints or answers — and never judges a time, because a fixed millisecond
bar on an unknown machine is red at random.

**The guarantee behind that differential is that the debugger is invisible to the
program, and it is a test rather than a sentence.** `tests/probe_sweep.lpr` runs
every generated program three ways at both doors — detached with no seam
installed, attached and answering *continue* at every boundary, attached and
stepping through every one of them — and requires the exit code, the standard
output, the error line and the error message to come out identical. The detached
leg is the one that can see a defect caused by the PRESENCE of a debugger rather
than by its answers: an engine that recorded its statement boundary differently
while armed prints one answer to a debugging host and another to a plain one, and
both attached legs agree with each other while being wrong.

**The two right-hand columns reproduce; the left one does not, and saying so is
the honest form.** B, C and D live in ONE binary and are interleaved inside a
single rotation, and three people measuring independently got +2.3/+4.5,
+2.5/+4.2 and +2.7/+4.6 percent, with 64-74 ns per seam call on Windows. A and B
are TWO binaries and cannot be interleaved at all; there the same three people got
+2.7/+3.9, +3.2/+2.9 and — over two fourteen-round pinned alternating rotations
with a bench source of its own — 0.0/−0.4 and +0.0/+0.8. Three protocols, three
answers, one of them straddling zero. On the Linux side, twelve pinned rounds put
the patched engine 0.42% FASTER than the pristine one on the tight shape and
0.04% slower on the dense one.

**And the H control says why, which is worth having rather than a fourth guess.**
A build of this engine with those two hook lines deleted and nothing else changed
should sit at A if the test is the cost. Benched in the same rotation it came out
−1.5%/−1.5% and −0.4%/−0.4% — *faster* than the pristine engine on both shapes,
which no model where the hook costs three percent can produce. Two earlier rounds
reported it at −0.8%/0.00% and at +2.9%/+1.8%, in opposite directions. What all of
this is consistent with is that the difference between two separately compiled
binaries of a 4600-line unit is dominated by code layout and not by one Boolean
test, and that the effect being hunted is smaller than that noise. Quote the
attached columns; treat the detached one as an upper bound of a few percent, and
re-run the bench rather than a fourth argument.

**Both of these machines are one machine.** The "Linux VM" is a VirtualBox guest
on the same physical Windows host, so `taskset` inside the guest pins a virtual
CPU rather than a core and each side's timings are perturbed by whatever the other
is doing — measurably: the same Linux rotation read A at 5316 with the Windows
side compiling and 5368 with it idle. Run the other side idle, and take two
absolute numbers taken an hour apart as evidence of the machine's state rather
than of the code's.

The stepping figure is over four times larger on Linux than on Windows, and the
reason is the language runtime rather than this engine: the `try/except` around
the seam call sits on the STOP path only, Win64 gets it free from SEH, and FPC on
Linux pays table-driven unwinding to enter a frame. It is paid once per host round
trip, so only a program stepped four million times ever meets it.

Six things to know before you build a debugger on this.

**`daStop` ends the run the way `END` does.** Rc 0, no error, `eng.Halted` True
afterwards; the statement it stopped at never runs. There is no error code for
"the host said stop", deliberately — a host that wants the run to look like a
failure is the one deciding that and says so itself. A prepared session that was
stopped this way stays closed: `CallFunction` refuses it by name, because its top
level never finished.

**A stop taken inside a `CallFunction` is the one place that DOES report.** There
is no rc to carry it — the call answers a `TValue` — and a default value with
`ErrorMessage` empty is indistinguishable from a function that returned zero, so
that call reports *a debugger stopped this call before it returned*. Every later
call on the session is refused with *a debugger stopped this session*, which is
the same refusal `END` gets and no longer the same sentence: a host that puts the
engine's message in front of a person should not be telling them about an `END`
their script may not contain. A stop inside a **script**-initiated `callfunc` is
still silent and still ends the run cleanly — the interpreter is in the middle of
a statement there, and turning a stop into a fault inside somebody's expression is
not an improvement.

**A step does not survive a run, and `CallFunction` is a run.** The arming does:
arm once and every run of that VM is debugged. But a step is a question about one
boundary, so a *step into* left pending when a prepared script's top level ends
does not stop the host's first `CallFunction` afterwards — it would be a stop in a
line nobody armed, out of a run that is over. The same holds between REPL lines.
A `callfunc` the SCRIPT makes is the same run continuing and a step travels
straight through it, which is what makes step-into work across one.

**Block terminators can never be stopped on.** `next`, `endwhile`, `endif` and
`endfunction` emit no statement boundary, so no breakpoint can live there and no
step will ever land there. `StoppableLines` omits them for that reason.

**A `for` header's boundary runs once.** It executes before the loop top, so a
breakpoint on the `for` line fires on entry and never again, while one on the body
line fires every iteration. That is the right behaviour and it is the clearest
reason the rule is *statement boundaries* and not *the line changed*.

**A step is a line, a pc and TWO depths.** Step into stops at the next boundary
that is not where the step began; step over never enters a call but does land in
the caller when the step was asked on the last statement of a body; step out is
silent until you are strictly shallower.

*Shallower* counts both kinds of call: an activation frame **and** a pending
`GOSUB` return address. `gosub` pushes no frame, so on the frame depth alone a
subroutine body reads as the same level as the line that called it — step over
would walk the whole subroutine and step out from inside one would never find
anywhere shallower. `TPhosphorVM.DbgGosubDepth` is that second number, beside
`DbgFrameDepth`, and a debugger that shows "where am I" should show both.

The one program this pair cannot answer for is a subroutine abandoned by `goto`
instead of `return`: its entry stays pending for the rest of the run, so a step out
asked for inside it never becomes shallower. That program has no return point to
step out *to*.

**Stepping out of the outermost frame of a host call behaves as *continue*** —
control goes back to your Pascal, not to more BASIC. That is judged on whether an
interpreter activation is live above this one, NOT on the frame depth: `callfunc`
and an `on error call` handler are both entered the same way a host call is and
both DO have more BASIC above them, so a step out of either lands on the statement
that follows. Deciding it on the depth alone made a step out of the documented
`on error call` idiom set the mode to *continue*, and a step-only session then
never stopped again.

**A pending step does not survive an `ON ERROR` unwind.** A fault dropping to a
handler and a `resume` climbing back both move the frame stack wholesale, so the
step is rebased onto the stack that is actually there and promoted to *step into* —
the next boundary stops and the user sees where the handler took them. A host that
had said *continue* still continues.

**Parking in the seam costs the script nothing it can be refused for, and the
credit lands as the window goes rather than when it closes.** The VM marks the
wall clock, the library budget's own clock and the process heap when it enters
the seam and gives back what the host spent idle. `MaxSteps` needs no correction —
parking executes no instruction.

*As the window goes* is the load-bearing half. The first version of this
correction applied it once, when the seam returned, which repairs the script's
CONTINUATION and not the WINDOW: while the host was still inside the stop, both
clocks still said the run had been going for as long as the person had been
looking at it, so anything the host did in there that re-entered the engine was
judged against that. Measured on both machines, with a control: one prepared
session under `TimeoutMs := 400`, a seam that evaluates a watch through
`CallFunction`, answered correctly with nobody in front of it and *time limit
exceeded (400 ms)* after a 900 ms pause — and the budget's clock gave the same
verdict in its own words. The credit is now taken at every door the host can
re-enter through.

**What you spend RUNNING THE SCRIPT in there is still yours to pay.**
`CallFunction` from inside a stop — a watch expression — really executes the
script's code: its milliseconds, its instructions and its bytes are all charged to
the script, on every lane and for one reason. For memory the engine could not
separate the two kinds of byte afterwards even if it wanted to, and crediting the
window was a way out of `MaxMemoryBytes`: measured before that term existed, the
same five million bytes of script globals was refused when the script built them
and allowed when a host evaluated the identical function from a stop. For the two
clocks it could separate them — an evaluation's duration is exactly measurable —
and charges anyway, because a rule that credited an evaluation's milliseconds
while charging its bytes would be two different answers to one question.

So a host that sets a ceiling and evaluates from a stop pays for the evaluation
out of the script's budget. A watch that costs milliseconds is invisible; one that
runs for longer than the whole `TimeoutMs` ends the script, and says so. That
ceiling is also what BOUNDS a runaway watch: the script's own clock is still
standing over the evaluation, so `print anExpensiveFunction()` comes back refused
instead of hanging the session — measured, a thirty-million-iteration watch under
a 400 ms ceiling is refused at 400 ms and control returns to the host. An
evaluation with a clock of its own would buy nothing here and would need a lane in
every ceiling.

**A watch expression that fails is not your call's verdict.** `ErrorLine` and
`ErrorMessage` describe the door you most recently called and nothing else. That
takes saying because this door nests inside itself: a watch evaluated from a stop
is a `CallFunction` inside a `CallFunction`, and the inner one's failure used to
still be standing when the outer one finished cleanly — so a host whose own call
returned 7 was told *division by zero* at a line in a function it never called.
Read the evaluation's own verdict from the nested call, where it belongs and where
it is still reported; the outer call now answers only about itself. Every door
does: one that succeeds reports no error.

**From inside a stop, `CallFunction` is the supported re-entry.** `Prepare`,
`Run`, `RunBytecode`, `ReplRun` and `Finish` are not: each of them frees or
replaces the VM your seam is standing in, and it returns into the object they
destroyed. A debug adapter's *Restart* command belongs after the seam has
returned, not inside it.

**A `BREAKPOINT` report is charged to `MaxOutputBytes`, and it costs what printing
its payload costs.** The message plus each operand rendered the way `print` renders
it. This is what puts the debug stream on a ceiling at all: with `MaxOutputBytes`
at 0 it is as unbounded as `print` is, which is a configuration you chose.

**It is charged by `trace`, not by whether you installed `OnBreakpoint`.** The
switch belongs to the script: with tracing off the statement does nothing and
costs nothing, and with it on the payload is charged whether or not a reporter is
there to receive it — exactly as `PRINT` is charged whether or not `OnOutput` is
assigned. The ceiling is on what the script PRODUCES. Gating it on the seam
instead meant one script under one ceiling got two different exit codes from two
hosts, one of which had merely not installed a reporter.

Raising out of the seam is safe: an exception from the callback is turned into an
ordinary engine error at the boundary rather than being allowed to unwind the
interpreter, so a socket that dies mid-session fails the run instead of leaving the
value stack and every open channel wherever the unwinding left them.

## The lifecycle in one glance

```
Create
  -> Registry.Add / AddHost   (your functions)
  -> OnOutput := ...          (optional)
  -> MaxSteps / MaxOutputBytes / TimeoutMs / MaxMemoryBytes := ...   (untrusted scripts)
  -> OnDebug := ...; ArmDebug(lines, stopAtEntry)      (optional; a debugger)
  -> SandboxRoot := '<dir>'                   (optional; bounds WHERE it writes)
  -> Run(source)                              one-shot
     OR
     Prepare(source); CallFunction(name, args); ...   load once, call many
  -> Free
```
