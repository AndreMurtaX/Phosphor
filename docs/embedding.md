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
eng.MaxOutputBytes := 64 * 1024;      // total bytes emitted through OnOutput
eng.TimeoutMs      := 2000;           // wall-clock ceiling
eng.MaxMemoryBytes := 256*1024*1024;  // heap this script may ADD while it runs
```

When one is hit, the run aborts and `eng.LastError.Code` is `peLimit`. The
ceilings are cumulative over a prepared session (`Prepare` + all its
`CallFunction`s); re-`Prepare` to reset the counters.

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

## The lifecycle in one glance

```
Create
  -> Registry.Add / AddHost   (your functions)
  -> OnOutput := ...          (optional)
  -> MaxSteps / MaxOutputBytes / TimeoutMs / MaxMemoryBytes := ...   (untrusted scripts)
  -> SandboxRoot := '<dir>'                   (optional; bounds WHERE it writes)
  -> Run(source)                              one-shot
     OR
     Prepare(source); CallFunction(name, args); ...   load once, call many
  -> Free
```
