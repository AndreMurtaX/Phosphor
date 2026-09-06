# Embedding Phosphor BASIC

Phosphor is a **library**. A host program links the engine, registers its own
functions, runs user scripts, and exchanges values with them — and the engine
never learns who is driving it (see [architecture.md](architecture.md), "The one
rule"). The console REPL, the LCL GUI and the `phosphorembed` example are three
consumers of the *same* engine; yours is another.

The worked example this document follows is
[`host/embed/phosphorembed.lpr`](../host/embed/phosphorembed.lpr) — a host that
registers a function, prepares a script once, and calls its routines from Pascal.

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
7. A script can also handle its own errors with `ON ERROR` (see
[roadmap-phase3.md](roadmap-phase3.md)).

## Running untrusted scripts — limits

If the script is not yours, bound it before running. Each ceiling is `0`
(unlimited) by default and costs nothing; a ceiling is **fatal** — `ON ERROR`
cannot catch it, so a script cannot escape its own limit:

```pascal
eng.MaxSteps       := 1000000;   // instruction budget (bounds an infinite loop)
eng.MaxOutputBytes := 64 * 1024; // total bytes emitted through OnOutput
eng.TimeoutMs      := 2000;      // wall-clock ceiling
```

When one is hit, the run aborts and `eng.LastError.Code` is `peLimit`. The
ceilings are cumulative over a prepared session (`Prepare` + all its
`CallFunction`s); re-`Prepare` to reset the counters.

Those three bound how **long** a script runs. The fourth bounds **where** it
writes.

## The filesystem sandbox

A script that is bounded in time and output can still delete your home directory.
`SandboxRoot` is the ceiling for that: set it and every path the script names —
through `file_*`, `dir_*`, `open … as #n`, the string-list and RAG loaders, and
the `zip`/`gzip`/`base64` packages — must resolve inside that directory, or the
call is refused.

```pascal
eng.SandboxRoot := '/var/tmp/run-42';   // '' (the default) = unbounded
```

What "resolve inside" means, exactly: the path is made absolute against the
working directory, `.` and `..` are collapsed, and symlinks are followed on every
component that exists. So `../../etc/passwd` and a link planted inside the root
are both outside it, and both are refused.

Three details worth knowing before you rely on it:

- **A refusal is a value, not an exception.** `file_writealltext` answers `0`,
  `file_readalltext$` answers `""`, `dir_getfiles$` answers `""`, `dir_delete`
  answers `0` and `ioerror()` reports it. The one exception is `OPEN`, which has
  no return value to answer with and so fails the run with a catchable runtime
  error. This is the same house rule the rest of the library follows: a call that
  could not do what it was asked says so in its answer.

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

`scripts/check-sandbox.py` is what keeps this true as the library grows: it fails
the acceptance suite if any routine a script can reach touches the filesystem
without asking the gate first.

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
  -> MaxSteps / MaxOutputBytes / TimeoutMs := ...   (optional, for untrusted scripts)
  -> SandboxRoot := '<dir>'                   (optional; bounds WHERE it writes)
  -> Run(source)                              one-shot
     OR
     Prepare(source); CallFunction(name, args); ...   load once, call many
  -> Free
```
