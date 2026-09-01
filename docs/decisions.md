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

## Rules carried over from Plan9Basic

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
- **`s$[[n]]` character indexing is base-1 by codepoint** (not by byte). The
  string library decodes UTF-8 to index; raw-byte slicing stays for I/O only.
- **`bool` has its own signature type-code `?`** and does not widen to numeric
  (unlike `int%`, which binds to an `n` slot by widening to Double). Consequence:
  assigning a `bool?` to a numeric variable (`x = true`) is a type-mismatch —
  negative test 07 stays a rejection, for this new documented reason rather than
  the removed "true is not a value".
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
