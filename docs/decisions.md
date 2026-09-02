# Phosphor BASIC — frozen decisions

Decisions taken at project start. They diverge from Plan9Basic on purpose;
Plan9Basic is the reference implementation to read and copy from, not a
compatibility target. The ones marked **cheap now, expensive later** are settled
before the interpreter is written because deferring them is what costs.

## Types — five, not three

Plan9Basic's VM had three (`ekNumber`/`ekPointer`/`ekString`). Phosphor has five.
The type suffix is part of the name: `a` and `a$` are different variables. Names
are case-insensitive.

| suffix     | type                                    |
| ---------- | --------------------------------------- |
| *(none)*   | numeric — **Double** (not Extended)     |
| `$`        | string                                  |
| `%`        | integer (**new**)                       |
| `@`        | handle (was `#`)                        |
| `?`        | boolean (**new**)                       |

- **`#` is not a variable suffix.** It is reserved for the file number in
  classic file I/O (`PRINT #1`, `INPUT #1`, `CLOSE #1`), which Phosphor
  implements. Allowing `#` as an optional suffix would make `a` and `a#` two
  different variables holding the same type — a silent trap.
- **The handle suffix moves from `#` to `@`** ("address/reference", and Pascal's
  own address operator). **Consequence — cheap now, expensive later:** the
  record-format separator can no longer be `@`. Use `:` or `|`. In Plan9Basic
  ~4,374 signatures used `name@signature`; Phosphor is born with the new
  separator. This is the one decision on the list that gets expensive if
  deferred.
- **`?` as a boolean suffix** reads as a question (`done?`, `found?`). To free
  it, Plan9Basic's `?>` / `?<` operators (max/min) are gone — replaced by the
  ordinary `max()` and `min()` functions.
- **No scalar BYTE type.** Binary I/O uses a buffer-as-handle
  (`buf@ = buffer_new(1024)`): pure library, zero cost in the parser and VM.

## Arithmetic and promotion

- `int op double` → **double**, always.
- `int + - * int` → **int**.
- `int / int` → **double**. The slash is real division: `7 / 2` is `3.5`.
- Integer division is `\`: `7 \ 2` is `3`. (`\` was only a string-literal escape
  in Plan9Basic; it is now an operator.)
- `^` → **always double** (`2 ^ 0.5` is meaningful).
- Comparison between different types compares as double.
- An array index accepts any numeric and rounds.
- **Integer overflow is a catchable error**, never a silent promotion to double.

## Strict boolean

- Comparison produces a **value everywhere**, not only inside a condition.
  Plan9Basic rejected `x = 2 > 1`; that wart is gone. `true` and `false` are
  usable values.
- The strict rule stays: **a bare value is not a condition.** `if alive then` is
  still refused; write `if alive = 1 then` or a boolean expression. This removes
  a parser special case rather than adding one.

## Indexing — base 1 everywhere

Plan9Basic had base-1 arrays but base-0 `mid`/`instr`. Phosphor is base 1 for
everything, the BASIC convention. `s$[n]` indexes a line; `s$[[n]]` indexes a
character — both base 1 now. (13 of the 45 oracle programs need a mechanical
index adjustment when imported.)

## Input — synchronous

`INPUT` and `INPUT$` are synchronous, as in standard BASIC. The asynchronous
input command existed only for mobile and is gone, along with the suspend/resume
machine that surrounded it.

## Errors

`ON ERROR` in the language, and libraries that **record error state instead of
aborting.** Plan9Basic had 121 fatal `raise`s that killed the user's program and
no error handling at all. Fixing this is a founding goal, not a later addition.

## Standard BASIC commands to include

`PRINT USING`; classic file I/O (`OPEN`, `CLOSE`, `PRINT #`, `INPUT #`,
`LINE INPUT #`) living alongside the IOUtils-style functions; `LINE INPUT`;
`SWAP`; `RANDOMIZE`; `max()` and `min()`. `DEF FN` stays out — `function`
already exists.

> **STATUS (2026-09-02, standard-command milestone) — this whole set is now BUILT and
> tested.** `RANDOMIZE`, `max()`/`min()`; the `INPUT` / `LINE INPUT` statements and the
> `INPUT$` function (synchronous, over a host input seam); classic `#`-number file I/O
> (`OPEN … FOR input|output|append AS #n`, `PRINT #`, `INPUT #`, `LINE INPUT #`, `CLOSE`,
> plus `EOF`/`LOF`/`LOC` and `INPUT$(n, #f)`); `PRINT USING`; and `SWAP` — all covered by
> `tests/classic` (byte-exact, both OSes). They live alongside the IOUtils-style Io
> functions (`file_writealltext`, `file_readalltext$`, `savetext$`, `dir_*`/`path_*`), so
> file work can be done either way. `while … wend` is accepted as well as `endwhile`.
> [language-reference.md](language-reference.md) documents the full surface.

### File channels: streamed, live, positionable

A channel keeps its `TFileStream` open and reads through a sliding 64 KB window, so
`open … for input` never loads the file: memory is bounded by the window and the
longest line, not by the file size, and opening a 200 MB file to read four bytes
takes milliseconds. It follows that `lof(n)` is the file's **live** size and a
channel is a live view rather than a snapshot.

`OPEN … FOR BINARY` is the fourth mode: read/write and positionable. `seek #n, p`
moves the cursor and `loc(n)` reports it — both **1-based**, like every other index
in the language, so `seek #n, loc(n)` is a no-op. `input$` reads at the cursor and
`print #` overwrites at it, which is how a large file is patched without rewriting.
Seeking past the end grows the file.

Deliberately NOT built: the classic `FIELD` / fixed-length-record `GET`/`PUT` model.
Byte-addressed `SEEK` plus `input$`/`print #` covers the same ground without the
record-buffer machinery, and Phosphor is not a port.

### PRINT USING format language

A classic subset. Numeric fields: `#` digit positions, `.` decimals, `,` grouping, a
leading `+` (always-show sign) or `$$` (floating dollar) or `**` (asterisk fill), and a
trailing `+`/`-`; a value too wide for its field is prefixed with `%`. String fields:
`&` (the whole string), `!` (its first character), and `\`…`\` (a fixed-width field of
2 + the inner spaces). `_x` emits `x` literally. Values fill fields left to right, and
the format repeats while values remain. Because Phosphor string literals use backslash
escapes, a `\`…`\` field is written with doubled backslashes: `"\\   \\"`.

## Rules carried over from Plan9Basic

- **Two-word block terminators are accepted as equivalents of the one-word
  forms** (like Plan9Basic): `end if` = `endif`, `end while` = `endwhile`,
  `end select` = `endselect`, `end function` = `endfunction`. The lexer merges an
  `end` token immediately followed by the keyword; a bare `end` (the END
  statement) and `end` on its own line before a `function` definition are left
  alone (an EOL separates them).
- `sqr()` is square root.
- `s$[n]` indexes a line; `s$[[n]]` indexes a character (both base 1 now).
- `do while <cond> ... loop`; `function f(n) local a, b ... endfunction`.

## Encoding

UTF-8 everywhere, declared explicitly, settled on day one. See
[architecture.md](architecture.md), "UTF-8".

## Resolved specifics (owner decisions, 2026-08-31)

Settled when the phase-1 [roadmap](roadmap.md) surfaced them as freeze-now forks:

- **Signature separator is `:`** — `Lib.Add('name:signature')`. The registry `:`
  is parsed in Pascal at registration time and never collides with a source-level
  statement `:`.
- **String-literal escape is a doubled quote** — `""` inside a literal yields one
  `"`. There is no escape character; `\` is exclusively integer division.
  > **SUPERSEDED (2026-09-02, oracle import):** a backslash escape set was added to
  > string literals after all — `\n \t \r \0 \a \b \f \v \\ \"` — because the imported
  > oracle programs rely on it (`tests/suite/46_string_escapes.bas` is the authority).
  > The doubled `""` still works, and `\"` reaches the same quote. Outside a string
  > literal `\` remains integer division. Consequence for users: a Windows path in a
  > literal must double its backslashes (`"C:\\dir"`) or use forward slashes.
- **`s$[[n]]` character indexing is base-1 by codepoint** (not by byte). The
  string library decodes UTF-8 to index; raw-byte slicing stays for I/O only.
- **`bool` has its own signature type-code `?`** and does not widen to numeric
  (unlike `int%`, which binds to an `n` slot by widening to Double). Consequence:
  assigning a `bool?` to a numeric variable (`x = true` or `x = 2 > 1`) is a
  type-mismatch — negative tests **05 and 07 both stay rejections**, for this new
  documented reason rather than the removed "comparison is not a value" / "true
  is not a value". (This overrides the council's earlier guess that 05/07 would
  become positive; that guess predates the bool-distinct decision.) A comparison
  is still a usable value — it just needs a bool destination (`ok? = 2 > 1`) or a
  bool context. And a bare value — number, bool literal, or variable — is never a
  condition (negatives 06 and 08), enforced structurally in the parser.
- **The registry type-code alphabet is `n % $ @ ?`** (`#` is never a code). `n`
  is the numeric family (a Double, or an `int%` widened into it); `%` is an
  exact `int%` slot that does not widen. Resolution prefers the fewest widenings,
  so `assert_eq(2+3,5)` [int,int] → `assert_eq:nn` by widening, while
  `assert_int(7\2,3)` → `assert_int:%%` exactly — and a successful dispatch to a
  `%` slot is itself the proof the value stayed an `int%`.

## Extensibility

The registry `Lib.Add('name:signature')` (note the `:` separator, per the `@`
decision above) is how every function package integrates, and it stays. A styled
console ships as a **function package** (`crt_gotoxy`, `crt_color`, `crt_clear`,
…), not as language commands — FPC's `rtl-console` (`crt`, `video`, `keyboard`)
is already built for win64 here; `video` + `keyboard` is the more portable base.

## On-disk bytecode — decisions now, implementation later

The eventual goal (a later phase) is the Clipper/PyInstaller/AutoIt model:
compile a script to bytecode, append the bytecode to a copy of the VM to make a
single executable, and have it read its own tail at startup. PE and ELF both
ignore bytes after the last section, so the payload rides at the end behind a
trailer (magic signature, offset, size, format version, checksum). The binary's
own path is `ParamStr(0)` on Windows and `/proc/self/exe` on Linux.

Plan9Basic's `TInstr` already nearly serializes:

```pascal
TInstr = record
  proc:  TExeFunc;    // method pointer — DERIVED, recomputed on load
  token: TAsmToken;   // the opcode  — STORED
  i:     Integer;     // string-pool offset / variable index — STORED
  n:     Extended;    // numeric constant — STORED (Phosphor: Double)
end;
```

**Do not build the packer in phase 1** — while the language moves, the format
moves with it. But take these three decisions now, because they cost nothing
today and are expensive to retrofit:

1. **Opcodes carry explicit numbers, assigned by append only, never
   reordered.** Plan9Basic's `TAsmToken` is an alphabetical enum, so inserting
   an opcode shifts every later ordinal — harmless while nothing outside the
   process sees the numbers, a silent format break the moment a `.pbc` exists on
   disk. The **format version must be checked and refused out loud.**
2. In the instruction record, **stored vs derived fields are separated and
   documented as such** (`proc` is derived from `token` via a lookup on load and
   is never written).
3. The **constant pool is an explicit, indexable structure** — the `i` field
   already assumes it.

With `Double` fixed and endianness written explicitly (**little-endian**), the
same `.pbc` runs under the Windows and Linux stubs; only the stub is
per-platform.

**Honest cost, recorded up front:** a binary that reads its own tail and
executes an embedded payload is the classic shape of a dropper, and heuristic
antivirus flags it eagerly — the number-one complaint of PyInstaller and AutoIt
users. It will happen, and the documentation must say so plainly.

---

## No fixed global-variable cap

Plan9Basic addresses globals through a fixed `HeapMem[0..515]` array with three
slots reserved, so it caps a program at **513 globals** and rejects the 514th at
compile time (its `13_global_limit` test pins the upper boundary and a negative
test guards the other side).

**Phosphor does not inherit that cap.** The VM holds globals in a dynamic array
sized to the program's actual variable count (`SetLength(FVars, VarCount)`), and
the bytecode addresses them with a 32-bit index, so there is no `HeapMem`
artifact to bump into. Capping at 513 would be importing an implementation quirk
as a language rule with no technical justification — exactly the kind of thing
"not a port" means to avoid.

Consequences:
- `tests/suite/13_global_limit.bas` (513 globals must compile) is imported and
  passes — Phosphor compiles it with room to spare.
- `tests/negative/01_too_many_globals.bas` is **NOT** imported: it guards a limit
  Phosphor deliberately does not have. If a cap is ever wanted (say for a future
  on-disk format), it would be a large, explicit, documented number — not 513.

A runaway script is bounded by **execution limits, not a variable count**. The
engine exposes three ceilings — `MaxSteps` (instruction budget), `MaxOutputBytes`
(total bytes through `OnOutput`), and `TimeoutMs` (wall-clock) on `PhosphorEngine`
— all **off by default** (`0`), so the embedder opts in to exactly the bound it
wants (`probe_limits` exercises them). This is the deliberate difference from
Plan9Basic's `513`: an arbitrary global count is a proxy for "this program is out
of control", and a 521-global program that Phosphor runs fine is proof the proxy
is the wrong measure. The real question — *is this script consuming more than the
host allows?* — is answered by the opt-in limits the host actually controls, not
by a fixed number baked into the language.

---

## The host-callback seam — how a host runs a BASIC routine

Phase 2's GUI host needs something the console host never did: when an LCL event
fires, *the engine must run a BASIC routine and come back*. The engine still may
not know a window exists, so the seam is defined in engine terms and proven with
no GUI at all.

Two additions, both host-agnostic:

1. **Host-aware functions.** Alongside the plain `TPhosphorFunc`, the registry
   accepts a `TPhosphorHostFunc` (via `AddHost`) that also receives the executing
   VM (typed `TObject` to avoid a dependency cycle; the package casts it back).
   Only functions that must call back into BASIC take this channel; the dozen
   existing libraries are untouched. "Run a BASIC routine" needs no console, file
   or window — only the VM already on the stack — so this stays inside the
   boundary.
2. **`TPhosphorVM.CallUserFunc`.** A public, re-entrant entry that pushes a call
   frame for a named user function and runs the execution loop *bounded to that
   frame*: it stops and hands the return value back the moment the routine
   unwinds to the level it was called at. Globals, handles and the value stack
   are shared with the running program on purpose — a callback sees and mutates
   the same state, exactly as an in-line GOSUB would. The top-level `Run` is just
   `CallUserFunc`'s unbounded case (stop-frame `-1`, a level the frame stack never
   reaches).

The language face of this is **`callfunc`** (`engine/libs/PhosphorCallLib`):

    callfunc(name$)       call a BASIC user function by name, no arguments
    callfunc(name$, x)    ... with one argument of any kind

The name string is the routine's *exact* name, suffix and all (`"shout$"`,
`"identity@"`); the suffix on the call spelling (`callfunc` / `callfunc$` /
`callfunc@`) only reads as the return type expected. `callfunc` reaches user
functions, not library functions — an unknown name is a runtime error, not a
silent no-op (negative `12_callfunc_unknown`). `tests/suite/48_callback.bas`
proves the whole seam headless: indirect numeric/string/handle calls, a routine
mutating a shared global (the event-handler shape), and indirect recursion
through the re-entrant path.

A GUI event dispatcher is then just a host object that, on an LCL event, calls
`CallUserFunc(handlerName, [senderHandle])`. It reuses this seam unchanged; the
reference reached the engine by walking a control's parent chain up to the form,
a fragile path it documents as the source of several dead-event bugs — Phosphor
gives the dispatcher the VM directly at bind time instead.
