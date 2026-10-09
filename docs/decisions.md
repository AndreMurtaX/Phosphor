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
  (`buf@ = buffer_new@(1024)`): pure library, zero cost in the parser and VM.
  *Built.* The spelling gained its `@` when the later rule settled that a
  built-in's return type comes from the suffix on its OWN name — as `dim@`,
  `strings@` and `json_parse@` are spelled. It introduced no type: it operates on
  the same handle `file_readallbytes@` already returned, so the reader, the buffer
  and the writer compose without a conversion step.

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
takes milliseconds. A read that needs a long run in the window at once grows it
geometrically (at least doubling) and resumes its scan where the last pass stopped,
so it costs O(N) and the window holds at most about twice that run; until
2026-10-09 it grew 64 KB at a time by copying, and one 64 MB line took 28 s
(`tests/suite/81_chan_read_linear.bas`; the console twin is `tests/probe_readcost.lpr`). It follows that `lof(n)` is the file's **live** size and a
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

**The field grammar (2026-10-09, round 3).** A numeric field is

    [+] [ **$ | $$ | ** ] [+]  digits  [ . #... ]  [ + | - ]

with one sign mark at most (a `+` before or after the fill, or a trailing `+`/`-`); a
`,` that belongs to the field only between digit positions (after a `#` or the fill,
before another `#` or the field's point); a point that belongs to the field only when
a `#` follows it; and at least one `#`, a fill or a point. One scanner
(`ScanUsingField`) cuts the format by this grammar and the layout reads the record it
fills -- before, the start condition and the consumer were two grammars, and a format
the start condition took as one field (`+$$##.##`) was consumed as two, the first a
zero-width overflow and the second taking the NEXT value. The choices, each with its
reason:

- **A field may start at its point** (`.##`). Classic BASIC's rule is that a digit
  position before the point is always printed, with 0 if need be -- so with none, a
  value below 1 prints `.78`, and one of 1 or more overflows (`%1.50`). The fill
  counts as positions (`$$` is two, one of them the `$`; `**` two; `**$` three), so
  `$$.##` keeps printing `$0.78` as it always did. Before, `.##` was a literal `.` and
  an integer field: 0.78 printed `. 1`, a different number with no `%`.
- **`+` before the fill is the same field as `+` after it.** The sign prints where it
  was written: `+$$##.##` gives `+$5.00`, `$$+##.##` the `$+5.00` it always gave.
  `**$` is classic BASIC's fill-plus-dollar and is now one field, not `**` and then a
  literal `$`.
- **A comma or a point that no digit follows is text.** `Total ###.##.` keeps its
  period (it vanished into the field) and `##, ##` is two fields with a comma between
  (the comma was taken as grouping, and the field grew a column). `###.` prints exactly
  as it did, since a point with no decimals after it printed nothing more than a `.`.
- **One sign mark per field.** After a leading `+`, a trailing `+` or `-` is text:
  `+##-` was one field whose `+` was ignored but still took a column.
- **`^^^^` is not part of the subset**; it prints as text. The digits rule below says a
  field is never an exponent, and that stays true.

`tests/print_using_sweep.py` implements the grammar in Python from this text and
crosses every format of 1 to 4 tokens over `# . , + - $$ ** $ * ^^^^ x` (16104
formats, four values each) against the engine.

**The digits of a number field (2026-10-09).** Never an exponent, and exactly as many
decimals as the field has `#` after the point. A Double shows its first **17
significant digits** and `0` in every place past them; it is rounded **once, half away
from zero**, at the 17th significant digit or the field's last decimal, whichever comes
first, and the rounding is of the exact binary value. An `int%` shows its own digits.
The 17-digit rule is the convention 1e16 .. 1e255 already printed with (FPC's
`FloatToStrF(ffFixed, 18)`), carried to the whole range; the alternative -- every exact
digit, so 1e300 shows 52504760255204420248… -- prints noise past the precision the value
has, and shortest-round-trip digits would have changed what 1e16 .. 1e255 print. The
change it does make: FloatToStrF rounded some values whose exact value lies just below a
written tie UP (2.675 -> 2.68, 0.015 -> 0.02; 235 of the 10 000 values k/1000 at two
decimals), and they now round down, as C's `printf` and Python's `format` do. Before,
from about 1e256 up (less with decimals) FloatToStrF answered in exponent form and the
field printed the mantissa's integer part -- `1` for 1e300 -- with no `%`, and a field
never showed more than 18 decimals. `tests/print_using_sweep.py` crosses the range
against Python's decimal module.

### A radix input field is sign and magnitude, and must fit an int% (2026-10-09)

`input` and `input #` read a numeric field written `$FF`, `0x1F`, `&17` or `%101`,
with an optional sign. It is read as **sign and magnitude**, and a value outside
`-2^63 .. 2^63-1` is refused (`"..." is out of integer range`) -- into a number as
into an `int%`. The reasons: the language's own radix text is sign and magnitude
(`hex$(-255)` is `-FF`), `hex$`/`oct$`/`bin$` write every Int64 and nothing past it,
so this is exactly the set they produce, and the decimal door already refuses an
integer it cannot hold rather than wrapping it. A radix text names an integer; reading
one past Int64 as the nearest Double would invent a rounding no writer of radix text
asked for. Before, the field went to FPC's `TryStrToInt64`, which reads a magnitude up
to 2^64-1, reinterprets it as signed and only then negates: `-$FFFFFFFFFFFFFFFF` read
as `1`, `$FFFFFFFFFFFFFFFF` as `-1`, silently, one past 2^64 was "not a number", and a
field past 255 bytes was refused. The accepted shape is unchanged (measured against
`TryStrToInt64`); `val` and source literals still read no radix at all.
`tests/classic/21_input_radix_fields.bas` crosses 11 magnitudes x 5 prefixes x 3 signs
x 0/1/260 leading zeros at both doors.

### Resuming a fault in a loop's own test (2026-10-09)

A `while` / `do while` condition, a `repeat` loop's `until` test, and a `for` loop's
limit check and increment are each a **statement of their own** for `resume`. `resume`
retries that test or increment. `resume next` continues **after the loop**: the test
could not say "go round again", and the only other readings were retrying the same
fault for ever or going round once more on a test that never answered. The compiler
gives each of them a statement boundary (opStmt with B = 1, which the debugger does not
stop on), so stepping is unchanged. Before this a fault there was blamed on the body's
last statement, whose end is the loop tail: the second `resume next` ran past the
handler and ended a top-level program at exit 0, or a function with its default value.
`tests/suite/80_resume_loop_tail.bas`.

## What this language refuses that Plan9Basic accepts

Recorded 2026-09-18, after a review measured that README.md's pointer at this file
promised more than the file delivered. Four divergences actually **refuse** a valid
Plan9Basic program; only the first was written down.

The measurement, because it sets the scale: of Plan9Basic's own 98 example
programs, `phosphor` refuses **79** at compile time. Rewrite the `#` handle suffix
to `@` mechanically and **95 of the 98 compile**. So the gulf is almost entirely
one decision, and what remains is three.

- **The `#` handle suffix is `@` here.** Already decided and already recorded above;
  it is named again only because it is 76 of those 79 refusals by itself.

- **`next` takes no control variable.** Plan9Basic writes `next col`; here it is a
  bare `next`, and the named form is refused with *"'next' takes no variable"*.
  This is the one that bites in practice: **33 occurrences** across Plan9Basic's
  corpus, including inside the oracle itself (its own `23_archive` suite file). The
  reason it stays: the control variable is already fixed by the `for`, so a name on
  the `next` is either redundant or a lie, and a lie there is a defect a reader
  cannot see. Phosphor names the variable in the diagnostic instead.

- **`do while <cond> ... loop` is the only `do` form.** Plan9Basic has three --
  `DO WHILE`, `DO UNTIL`, and a bare `DO` that loops until an explicit exit. Bare
  `DO` and `DO UNTIL` are refused here with *"only 'do while <cond> ... loop' is
  supported"*, which says so plainly rather than mis-parsing.

- **An unknown escape is an error, not literal text.** Plan9Basic keeps `\w` as a
  backslash followed by `w`; here it is refused. This is not a small difference in
  practice -- it refuses every regex literal written the ordinary way, which is why
  Plan9Basic's own `19_RegexLib_Tests` does not compile here. The rule is
  deliberate and is recorded under *Encoding* below: a silently-kept backslash is
  how a typo becomes data. The cost is that a Plan9Basic regex needs its
  backslashes doubled.

**And compiling is not agreeing.** Two carried-over names answer differently, both
measured: `instr` returns 0 for "not found" where Plan9Basic's `n_instr` returns
-1, and `mid$` counts from 1 where `s_mid` counts from 0. The Plan9Basic idiom
`if instr(x$, "+") >= 0` therefore inverts in silence, with a successful exit code.
Base-1 indexing is decided above and is not being revisited; this note exists so
that a person porting a program knows which two names to search for first.

**The library surface is narrower in three places**, which is not a language
decision but belongs beside these because a porter hits it the same way: regex is
find and split only (8 of Plan9Basic's 16 names -- no `regex_replace$`,
`regex_escape$`, `regex_isvalid`, `regex_match`), HTTP speaks GET and POST, and
Plan9Basic's AI library has no counterpart. The regex gap is why the oracle's
`11_encoding` has no whole counterpart here.

## Rules carried over from Plan9Basic

- **Two-word block terminators are accepted as equivalents of the one-word
  forms** (like Plan9Basic): `end if` = `endif`, `end while` = `endwhile`,
  `end select` = `endselect`, `end function` = `endfunction`. The same pass reads
  `else if` as `elseif`, so the two-word spelling continues the SAME chain rather
  than opening a nested `if` that would want its own `endif`. The lexer merges an
  `end` token immediately followed by the keyword; a bare `end` (the END
  statement) and `end` on its own line before a `function` definition are left
  alone (an EOL separates them). Note what is NOT in the list: `for`/`do`/`repeat`
  end with `next`/`loop`/`until`, so there is no `end for` **here**.

  That last clause used to read "so there is no `end for` to accept", which was a
  wrong fact about the reference rather than a decision about this language:
  Plan9Basic DOES accept it, through `ParseEnd`/`btkFor` in its `parser.pas`, and
  `ENDFOR` is in its keyword table. It is a form Phosphor declines, not one that
  never existed. The distinction matters because this file is where a reader comes
  to learn what changed on purpose.
- `sqr()` is square root.
- `s$[n]` indexes a line; `s$[[n]]` indexes a character (both base 1 now).
- `do while <cond> ... loop`; `function f(n) local a, b ... endfunction`.

## Encoding

UTF-8 everywhere, declared explicitly, settled on day one. See
[architecture.md](architecture.md), "UTF-8".

## Resolved specifics (owner decisions, 2026-08-31)

Settled when the phase-1 [roadmap](roadmap.md) surfaced them as freeze-now forks:

- **Signature separator is `:`** — `Reg.Add('name:signature')`. The registry `:`
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

The registry `Reg.Add('name:signature')` (note the `:` separator, per the `@`
decision above) is how every function package integrates, and it stays. A styled
console ships as a **function package**, not as language commands.

*Built, and in a better shape than this decision imagined.* It does not expose
`gotoxy`/`color` COMMANDS; every call answers an escape SEQUENCE that a program
prints, so styling composes with ordinary string handling and costs nothing when
the output is redirected: `cls$`, `home$`, `at$(x, y)`, `color$`, `bg$`, `bold$`,
`underline$`, `inverse$`, `clreol$`, `savepos$`/`restorepos$`, plus the input side
`getkey$`, `inkey$` and `keypressed`.

**Four names carry the `crt_` prefix, not two.** Everything listed above is spelled
without one — including the input trio, which keeps its classic-BASIC name. What the
four have in common is that none of them is about producing output at all: each
reconfigures the terminal or the console this process is attached to.

- `crt_init` / `crt_done` — the lifecycle pair: turn VT escape processing on (a
  Windows console needs `ENABLE_VIRTUAL_TERMINAL_PROCESSING`; elsewhere ANSI already
  works and it answers 1 unconditionally), and put the terminal back the way it was
  by undoing raw mode. A backstop `crt_done` also runs from the unit's finalization,
  so a program that forgets it does not leave the user's shell in raw mode.
- `crt_hideconsole` / `crt_showconsole` — let go of the console window this process
  OWNS, and make a new one. `1` when there was one of its own to act on, `0`
  otherwise, which is the honest answer both for "you ran me from a terminal" (that
  console belongs to the shell and is never touched) and for Unix. This is the same
  act `phosphor --no-console` performs at startup, exposed to the language with an
  answer, for a program that wants to do it itself and know whether it happened.

This paragraph replaces one that said "only the two lifecycle calls carry a prefix"
while the package registered four. The console pair was added later and nobody came
back to the sentence — the ordinary way a true statement becomes a false one.

## On-disk bytecode — decisions taken up front, now implemented

> **STATUS 2026-09-01 — built.** `engine/PhosphorBytecode` implements
> `WriteProgram`/`ReadProgram` against the format frozen below, with
> `ValidateProgram` checking every index and jump target on load rather than
> trusting the file, and `phosphor compile` / `phosphor pack` are the two CLI verbs
> that produce a `.pbc` and a self-extracting executable. The decisions in this
> section were kept as taken; what follows is the record of why.

The eventual goal (a later phase) is the Clipper/PyInstaller/AutoIt model:
compile a script to bytecode, append the bytecode to a copy of the VM to make a
single executable, and have it read its own tail at startup. PE and ELF both
ignore bytes after the last section, so the payload rides at the end behind a
trailer (magic signature, offset, size, format version, checksum) — and the stub
also carries a 24-byte **mark** in its own initialised data, which `pack`
overwrites with a "packed" sentinel and the finished file's length. The magic IS
the format version: `PHOSPBC1` was offset/size/checksum, `PHOSPBC2` (2026-09-06)
adds a 32-bit flags word before the magic, the first flag being "release the
console this process owns" so `pack --no-console` can be baked into the file. A
reader asks its own compiled-in mark first, because everything in the tail can be
TRUNCATED away and truncation is the commonest corruption there is: a file that
had lost its magic used to answer "bare stub" and open the REPL. Only then does it
take the last eight bytes, decide how much trailer to read from what it finds, and
refuse a magic it does not know. A marked binary whose length or trailer is wrong
is refused out loud, exit 2; falling through to the CLI now requires an *unmarked*
binary, which is the only file that is genuinely a bare stub. Applications packed
before 2026-09-10 carry no mark and keep the old failure mode — repack them. The
binary's own path is `ParamStr(0)` on Windows and `/proc/self/exe` on Linux.

A file handed to `phosphor` is taken for a `.pbc` on **four** bytes, not three:
the magic `PBC` and then the version byte, which must be a control character and
must not be TAB, LF or CR. The three letters alone made `PBCount = 3` a false
positive — a valid source file refused as bytecode with `unsupported .pbc format
version 111`, the fourth *source* character reported as a version — and
`PBC<TAB>= 3`, and a line that is just `PBC`, are valid BASIC too. What that costs
the format is one rule: `PBC_VERSION` must never become 9, 10 or 13 without
changing that test. It is at 1.

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
- `tests/suite/13_global_limit.bas` is imported, and since 2026-10-07 goes past
  the cap it came from: 1027 globals. It used to stop at exactly 513, the one
  count a reintroduced 513 cap still accepts.
- **The count was free and the COST was not, until 2026-10-07.** Every name table
  -- globals, a function's locals, labels, user functions -- was a front-to-back
  scan per name, so N globals compiled in N^2/2 compares: 16 000 took 0.70 s and
  32 000 took 2.67 s, and the other three grew the same way. No cap was written
  and the clock enforced one anyway. Each table is indexed now
  (`engine/PhosphorNameIndex.pas`): 131 072 globals compile and run in 0.42 s, and
  `tests/probe_limits.lpr#CheckNameTablesScale` asserts eight times the names
  take no more than three times the time, for all four tables, and that 65 537
  globals -- past any 16-bit index -- compile and hold their values.
- `tests/negative/01_too_many_globals.bas` is **NOT** imported: it guards a limit
  Phosphor deliberately does not have. If a cap is ever wanted (say for a future
  on-disk format), it would be a large, explicit, documented number — not 513.

A runaway script is bounded by **execution limits, not a variable count**. The
engine exposes five ceilings — `MaxSteps` (instruction budget), `MaxOutputBytes`
(bytes the script pushes through a host seam: `PRINT` through `OnOutput`, and
since 2026-09-11 a `BREAKPOINT`'s payload through `OnBreakpoint`, which used to be
charged to nothing at all), `TimeoutMs` (wall-clock) and, since 2026-09-10,
`MaxMemoryBytes` (heap the script may add) on `PhosphorEngine` — all **off by
default** (`0`), so the embedder opts in to exactly the bound it wants
(`probe_limits` exercises them). This is the deliberate difference from
Plan9Basic's `513`: an arbitrary global count is a proxy for "this program is out
of control", and a 521-global program that Phosphor runs fine is proof the proxy
is the wrong measure. The real question — *is this script consuming more than the
host allows?* — is answered by the opt-in limits the host actually controls, not
by a fixed number baked into the language.

Those three bound time and output, and `SandboxRoot` bounds where a script
writes. **Memory is outside all four**, and so are the network, the GUI and the
machine around the process — [embedding.md](embedding.md), "What the four
ceilings do not bound", is where that is set out, because a set of ceilings
presented as complete is read as complete.

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
   Any function that needs the executing VM takes this channel, not only the ones
   that call back into BASIC: `PhosphorErrLib` uses it so `err`/`errmsg$`/`erl`
   read the VM's own caught-error state, and the GUI event binders use it to hand
   a bridge the VM it will call through. What it is not is the default — a library
   needing nothing from the VM registers with plain `Add`, and most do. "Run a
   BASIC routine" needs no console, file or window — only the VM already on the
   stack — so this stays inside the boundary.
2. **`TPhosphorVM.CallUserFunc`.** A public, re-entrant entry that pushes a call
   frame for a named user function and runs the execution loop *bounded to that
   frame*: it stops and hands the return value back the moment the routine
   unwinds to the level it was called at. Globals, handles and the value stack
   are shared with the running program on purpose — a callback sees and mutates
   the same state, exactly as an in-line GOSUB would. `Run` and `CallUserFunc` are
   SIBLING callers of one private `ExecFrom(AStartPC, AStopFrameSP)`: `Run` passes
   the unbounded stop-frame `-1`, a level the frame stack never reaches, and
   `CallUserFunc` passes the frame it must return to. Neither goes through the
   other.

The language face of this is **`callfunc`** (`engine/libs/PhosphorCallLib`):

    callfunc(name$)                 call by name, no arguments
    callfunc(name$, a, b, ...)      ... with up to eight, of any kinds

The name string is the routine's *exact* name, suffix and all (`"shout$"`,
`"identity@"`); the suffix on the call spelling (`callfunc` / `callfunc$` /
`callfunc@`) only reads as the return type expected. `callfunc` looks in the
program's own routines FIRST and the library SECOND — the order `opCall` uses, so
an indirect call means what a direct one means, including which of two same-named
things wins *(reaching the library was added 2026-09-06; until then it saw only
the program's routines, and a built-in by name was an error while the identical
direct call worked)*. An unknown name is a runtime error, not a silent no-op
(negative `12_callfunc_unknown`).

Eight arguments rather than one needs no signature explosion: the registry
resolves by argument KINDS, so a per-kind signature for every arity would be 5^n
keys — 488281 of them, against a whole registry of 1271. A `*` in a registered
signature matches any kind at that position, tried only after exact resolution
has failed — so the successful path is untouched, and `callfunc` costs 45 keys
instead of 488281. `tests/suite/48_callback.bas`
proves the whole seam headless: indirect numeric/string/handle calls, a routine
mutating a shared global (the event-handler shape), and indirect recursion
through the re-entrant path.

A GUI event dispatcher is then just a host object that, on an LCL event, calls
`CallUserFunc(handlerName, [senderHandle])`. It reuses this seam unchanged; the
reference reached the engine by walking a control's parent chain up to the form,
a fragile path it documents as the source of several dead-event bugs — Phosphor
gives the dispatcher the VM directly at bind time instead.

---

## Compiled programs keep their variable names (2026-09-11)

A compiled `TProgram` used to carry `VarCount` and `VarTypes` and no names at
all, and each `TUserFunc` its `LocalTypes` and no names. The compiler had both
(`FVarNames`, `FLocalNames`) and dropped them on the floor at the end of
`Compile`. An embedder could run a script and then not say what a single one of
its globals was called; any debugger asking for `variables` was asking for
something that did not exist.

`TProgram`'s private name table and `TUserFunc.LocalNames` now carry them, sized to
the type tables **by construction** rather than by a rule a caller has to keep --
the two doors that write a local table, `AddUserFunc` and `SetUserFuncLocals`, size
the names to the types and can do nothing else. `SetUserFuncLocals` matters as much
as the first door: the compiler registers a function before parsing its body, and
the body adds slots (a `FOR` bound is one), so a table filled only at registration
time is short by exactly those and says nothing about it.

The global table has the same shape for the same reason, and it was the half that
had it only in prose. The names began as a public `VarNames` field whose comment
asked writers to fill it beside `VarTypes` and readers to go through `GlobalName`
-- two rules, neither enforceable, and a review found nothing mechanical behind
either. The field is now private, so `SetGlobalTable` and `SetGlobalTableUnnamed`
are the only ways a name gets in and `GlobalName` the only way one comes out.
There are **two** doors rather than one with a defaulted argument, because the
answer with no names in it is the unsafe one and this project has already been
bitten by an unsafe value arrived at by leaving an argument out: the loader has to
say `Unnamed` in its own verb. `VarTypes` stays a public field -- the VM reads it
on the hot store path -- so a writer can still fill it directly, but such a program
reports `HasNames` **False**: the names are then absent and *say* they are absent,
which is the safe half of the failure.

**`TProgram.HasNames` exists because the two temporary filters degrade quietly
without it.** A program from a `.pbc` has no names, so `GlobalName` answers '' for
every index and `GlobalIsTemporary` therefore answers `False` for every index --
including the `SELECT` subjects that are certainly in the table. Nothing is broken
and nothing can be; there is no name left to judge. But a host that loops without
asking prints the compiler's own scratch under a blank name beside the script's
variables and cannot tell them apart. `HasNames` is the one question to ask first,
and `tests/probe_debug.lpr` pins both answers and the cost of not asking.

**They are not serialized, and `PBC_VERSION` is not bumped.** The version test in
`ReadProgram` is an exact match, so a bump makes this build refuse every `.pbc` an
earlier one wrote and makes `phosphor pack` refuse the same files; the sniffer
that tells a source file from bytecode also reads the version byte. Names exist to
serve a host that compiled the program in-process, which is the only path that has
them. A program read back from disk answers '' for every name.

**A compiler temporary is now named with a prefix no script can write.** The old
names were `__h<n>`, and `PhosphorLexer.IsIdentStart` accepts '_' -- so a program
whose first line was `__h0 = 42` and which then used `SELECT` at the top level had
its variable handed to the `SELECT` subject, because `VarIndex` found the name
already in the table. Measured 2026-09-11: the program printed `7`. The prefix is
`TemporaryNamePrefix` in `PhosphorOpcodes`, it begins with '#', and one predicate
(`IsTemporaryName`) reads what the generator writes. That makes the collision
impossible and makes the "is this the compiler's or the script's?" question exact
for both tables at once -- a filter on a *count* cannot work, because hidden
globals interleave with the script's own in the index space.

The read-only window over a live VM (`DbgGlobal`, `DbgFrameDepth`, `DbgFrameFunc`,
`DbgLocal`, `DbgProgram`) and `TProgram.StoppableLines` are described for
embedders in [embedding.md](embedding.md), "Looking at a prepared script's
state". No execution path is touched by any of it: no field was added to the VM,
no branch was put in the dispatch loop, and `tests/probe_debug.lpr` is the proof
that the surface works with no debugger, seam, socket or protocol anywhere in it.

**`StoppableLines` sorts, and the sort is not reachable from the compiler.** A
review turned the whole routine into a no-op and every assertion still passed, so
it looked like dead code. It is not: every program the *compiler* builds arrives
already ascending -- `ParseStatement` emits one boundary per statement in parse
order and parse order is source order, measured at 0 non-ascending over all 146
`.bas` in the tree -- but a `.pbc` carries each instruction's line straight from
the file, and `ValidateProgram` bounds indices, never a line number or the order of
anything. The sort is defending the loader's input, and the de-duplication beside
it compares *adjacent* entries, so the two are one contract. Nothing compiled from
source can test them, which is why `probe_debug` builds the unsorted shape by hand
and then asserts it a second time through the serializer -- the second assertion is
what shows the input class is one a host can really be handed.


**The step-out clamp is decided by an interpreter-activation count, not by the
frame depth.** `ExecFrom` stops when the frame stack comes back to the floor it
was given, so the outermost frame of a host callback has no shallower boundary to
reach and a step out there must behave as *continue* -- otherwise the debugger
arms a condition nothing can satisfy and goes silent for the rest of the run. The
first rule for "is the host above me" was `AStopFrameSP <= 0`, and it was wrong:
top-level code makes re-entrant calls with a floor of zero too. `on error call` is
the one the language reference teaches, and against it a step out of the handler
set the mode to *continue* and a step-only session never stopped again -- four
more boundaries ran, the return to the top level among them, and none was
reported. Measured at 12 of 336 generated programs before the fix and 0 after, the
same counts on both operating systems.

The question the frame pointer cannot answer is whether an `ExecFrom` is live on
the Pascal stack above this one, so `FExecDepth` counts exactly that. The premise
for not doing it -- "a counter around `ExecFrom` means a try/finally around the
hottest routine in the program" -- was measured false: `ExecFrom` has three call
sites, all three already held a try/finally, and an ordinary BASIC call does not
re-enter it (`opCall` pushes its frame inside the dispatch loop). It is paid once
per host call and never per instruction.

**A `GOSUB` is a call, so the stepper counts two depths and not one.** `gosub`
pushes a return address and no activation frame, so on `FFrameSP` alone a
subroutine body is "the same level" as the line that called it: step over walked
every statement of the subroutine and reported them as the caller's own, and step
out from inside one was measured against a depth the subroutine SHARES with its
caller and never became shallower. The pair `(FFrameSP, FCSP)` compared
lexicographically is how deep we are, and `DbgGosubDepth` is the same number
offered to a host that wants to render it. The residual is stated where it can be
met: a subroutine abandoned by `goto` rather than `return` leaves its entry pending
for the rest of the run, and a step out asked for inside one never finds anywhere
shallower -- but that program has no return point to step out to, and the answer
before the pair existed was the same silence in EVERY gosub rather than only the
abandoned one.

**A `BREAKPOINT` report is charged what printing its payload would cost.** The
charge began as `TextLenOf`, which prices any non-string at a flat 32 -- an
estimator borrowed from `opAdd`, whose own header says the exactness does not
matter "because the caller is deciding whether a growth is worth measuring and
then measuring the heap itself". That is true of `opAdd` and false here, where the
number is SPENT against a threshold and nothing measures anything afterwards.
Three small integers cost 96 bytes for the 5 a host writes, and a program whose
whole real output was 61 bytes was refused under a 100-byte ceiling. `ValToStr` is
what `print` charges for the same values, it runs once per report on a path
already gated by `FTrace` and an installed seam, and it makes the number mean
something instead of bounding it. Measured over a generated grid against an oracle
that uses no formula at all -- the same payload through `breakpoint` and through
`print`, under the same ceiling, must be refused together or not at all: 147 of
1512 cells disagreed under the estimate and 0 do now.

**The debug seam hands over two integers, and the VM is reached through
`TPhosphorEngine.DebugVM`.** `TPhosphorDebugProc` is `of object` so a host can keep
session state in the method's own class; `Self` inside it is therefore the host's
adapter and never a VM. Three doc blocks said otherwise, and one of them was the
stated reason for not offering the live VM at all -- which left a host stopping
through `Run` with nothing to read, since `PreparedVM` is nil unless `Prepare`
built it and `Run` keeps its VM in a local. The alternative was a VM parameter on
the seam, and it was refused: `TPhosphorDebugProc` lives in `PhosphorValue`, which
cannot name `TPhosphorVM` without a circular dependency, so the parameter would
have had to be `TObject` and every host would cast it unchecked to reach an object
the engine can hand back with its own type. `DebugVM` is set and RESTORED (not
nilled) around each door's existing budget region, because the doors nest: a watch
expression is `CallFunction` inside `CallFunction`, and nilling on the way out of
the inner one is a debugger that works until the first watch.

**Memory a host makes the SCRIPT allocate while parked is still the script's.** A
stop gives back the heap the host added, which is right for an adapter buffering a
stack frame and wrong the moment the host spends the park running script code:
crediting that window was a way out of `MaxMemoryBytes` -- ask the debugger to do
the allocation. Measured: the same five million bytes of script globals refused at
rc 4 when the script built them and allowed at rc 0 when a host evaluated the
identical function from a stop, on both operating systems. The engine cannot
separate the two kinds of byte after the fact, so it declines to credit the window,
which is the direction where a number it does not know is not silently spent by
the script. A monotone count of `ExecFrom` entries is what it reads, sampled either
side of the park -- the value that ACTS, rather than a flag that would have to be
cleared correctly at every door and would answer only for the one it was written
on.

**A sweep that measures the OFF state of a feature has not measured the feature.**
The debug seam arrived with four sweeps behind it -- 1326 generated programs, 129
real ones and 1296 ceiling cells -- and every one ran against a build with no
debugger installed. They measured very thoroughly that an unattached engine had
not changed, which was true and was not the question. `tests/probe_sweep.lpr` is
the other axis: 512 generated program shapes, every one stepped at every boundary
under step-into, step-over and step-out, judged against a rule written in its own
header rather than read from `PhosphorVM`. Removing the step-out clamp's
activation term makes it report 114 failures; removing the hook entirely makes it
report 498 rather than the `failures: 0` a sweep with no empty-reference check
would have printed. **Those three numbers are counted from a run of the current
corpus every time they are written**, because two of them were quoted here from a
200-program corpus for a round after it had grown, and then from a 280-program one
for a round after that, in sentences whose whole job was the count.

**The window a debugger stops in belongs to the host, and it is given back AS IT
GOES rather than when it closes.** The first correction moved both wall clocks
forward in the seam's `finally`, which repairs the script's CONTINUATION and not
the WINDOW: while the host was still inside the stop, both clocks still said the
run had been going for as long as the person had been looking at it, and
re-entering the engine from in there -- a watch expression, the use
`docs/embedding.md` names by hand -- was judged against that. Measured on both
machines with a control: one prepared session under `TimeoutMs := 400`, a seam
that evaluates a watch through `CallFunction`, answered correctly with nobody in
front of it and *time limit exceeded (400 ms)* after a 900 ms pause, with the
budget's own clock giving the same verdict in its own words. The credit is now
marked at the window's start and taken at every door the host can re-enter
through.

**The engine's error fields describe the door that was called, and a door that
nests inside itself has to say so with a value only it can write.**
`TPhosphorEngine.CallFunction` passed `FLastError` -- the one field every door
shares -- straight into `CallUserFunc` as an `out` parameter. That is correct for
a door nothing nests inside, and the debug seam is documented as a door a host may
re-enter through, so a watch expression is a `CallFunction` inside a
`CallFunction`: the inner one wrote its fault through that reference, the outer
one finished cleanly and never wrote it again, and `IsError` then reported the
inner call's failure as the outer call's verdict -- value 7 returned, *division by
zero* at a line in a function the host never called. Two halves: the out-parameter
is a local now, so the question "did THIS call fail" is asked of a value only this
activation can write; and every door clears its error fields on the way out of a
SUCCESS, because clearing them on the way IN cannot account for what ran in
between. **Found by the sweep and not by hand** -- the three-leg differential in
`tests/probe_sweep.lpr`, in the first round its compared verdict carried the error
line and the error message beside the output, on the shapes where a function
installs its own handler and abandons itself. Pinned by name in
`tests/probe_step.lpr`; both halves have a mutation that is caught.

**What the host spends RUNNING SCRIPT inside that window is charged, on every
lane, and that is one rule rather than three.** An evaluation's milliseconds, its
instructions and its bytes are all the script's. For memory the engine could not
separate them afterwards even if it wanted to; for the two clocks it could -- an
evaluation's duration is exactly measurable -- and charges anyway, because
crediting an evaluation's milliseconds while charging its bytes would be two
different answers to one question, which is this project's oldest failure mode
wearing a new hat. The prototype offered by the reviewer did exactly that: it
restored the VM's clock (charging) and handed the same interval back to the
budget's (crediting). **And the door is a DEPTH, not a flag** -- a `callfunc` the
watch itself makes is the script re-entering, one activation deeper, so the credit
asks whether this activation is the one the seam was entered at. A version written
on "are we inside a seam" survives every fixture whose watch calls out on its
FIRST statement, and is caught by one that calls out after spending 250 ms.

**An evaluation does not need a clock of its own, and that was measured rather
than imported.** The reference design this round was told to read suspends the
script's clock at the start of the stop, which leaves an evaluation with no
ceiling at all unless it is given a new one. This engine credits instead of
suspending, so the script's `TimeoutMs` is still standing over the evaluation: a
thirty-million-iteration watch under a 400 ms ceiling is refused at 400 ms and
control returns to the host. A second clock would have needed a lane in every
ceiling to buy nothing.

**A flag that describes the Pascal stack has exactly one writer pair.**
`FDbgInSeam` says a seam call is live above us, which is not something the
ARMING can know -- and `DisarmDebug` cleared it, so a host re-syncing the editor's
breakpoints from inside a stop (the natural spelling of "replace the set") lost
the re-entrancy guard with the set and its next watch expression was stopped
inside its own stop: 11 stops at seam depth 2 against a control of 1 at depth 1,
bounded only by `MaxCallDepth`. `DebugBeginRun`'s clearer was the same shape one
door over and went with it even though it is provably inert, because two "just in
case" clearers is how the first one was written.

**Both halves of an attach reach a prepared session.** `ArmDebug` forwarded to a
live VM on purpose; `OnDebug` was a plain field write that `ConfigureVM` had
already read, so a host that clicks *Debug* on a script it has already loaded got
zero stops and no diagnostic at all. `OnDebug` has a setter now, forwarding to the
prepared VM and the REPL's exactly as `ArmDebug` does, and clearing it detaches
both.

**A performance claim nobody can re-run is an assertion, so the bench is in the
tree.** `tests/bench_debug.lpr` is committed and both suite runners build it.
Three review rounds disagreed about one cell of the cost table -- whether deleting
the two hook lines recovers the detached cost -- and none could settle it, because
each ran a bench that lived in its author's scratch directory. The three cells
that live in ONE binary and can be interleaved (attached, and one seam call)
reproduced across all three and now a fourth; the one cell that compares two
separately compiled binaries did not, and the fourth reading straddles zero while
the hook-deleted control came out FASTER than the pristine engine on both shapes.
That is consistent with the difference between two builds of a 4600-line unit
being dominated by code layout rather than by one Boolean test, so the table says
*not resolvable, under a few percent* and points at the file. The committed bench
judges only the DIFFERENTIAL -- attached and stepping change nothing a program
prints or answers -- and never judges a time, because a fixed millisecond bar on
an unknown machine produces red at random and teaches everyone to ignore the file.

**And the two operating systems are one machine.** The Linux target is a
VirtualBox guest on the same physical Windows host, so `taskset` inside the guest
pins a virtual CPU rather than a core and each side's timings are perturbed by
whatever the other is doing -- measurably, and it is the missing explanation for
two agents reading the same VM an hour apart and getting minima 9% apart. It
changes no correctness result; it is why a timing disagreement between rounds is
the first thing to suspect and the last thing to conclude from.

## One value per flag, and no output that names an input (2026-10-09)

The second adversarial round found the console host's command line answering a
repeated flag by keeping the LAST value, silently. For a confinement flag that
is a widening: `phosphor --sandbox cage --sandbox . job.bas` ran in `.`, so a
wrapper that puts its own `--sandbox` in front of a caller's arguments was
undone by the caller. Every flag was judged, not just that one:

| flag | repeated | why |
| --- | --- | --- |
| `--sandbox <dir>` | refused, exit 2 | one run has one root; the only safe merge is an intersection, and two roots that do not nest have none |
| `--out <path>` | refused, exit 2 | one run writes one output |
| `compile --names <file>` | refused, exit 2 | already so since 2026-10-08 |
| `debug --port <n>` | refused, exit 2 | a session has one editor |
| `debug --break N,N` | **accumulates** | a breakpoint set is a set; two lists name a bigger one (it used to drop the first list) |
| `debug --stop-at-entry`, `--no-stop-at-entry` | honoured wherever they stand; the two together are refused, exit 2 | `--stop-at-entry --break 9` used to lose the entry stop that `--break 9 --stop-at-entry` kept -- an answer that depended on order. With neither, entry is implied exactly when no `--break` was given |
| `--no-console`, `--gui`, `compile --check`, `pack --no-console` | accepted, idempotent | a switch said twice says the same thing |

**No output may name an input**, and none is opened before every input has been
read. `phosphor run job.bas --out job.bas` created the output -- truncating it --
before the source was read, so the program ran as an empty one (exit 0 on
Linux) and was gone. The question is now asked of every output the host takes,
against every input the same command reads: run's `--out` against the program;
`compile`'s `.pbc` against the source and the `--names` file; `pack`'s
executable against the `.pbc` and against the `phosphor` binary it copies as the
stub (on Linux, rename(2) would replace the running interpreter with a packed
application that ignores its command line). The test is the debugger's
`SameSourceFile`: the expanded spelling, compared as the platform's filesystem
compares names, and then the file's identity (volume and file index on Windows,
device and inode on Unix), which is what a hard link or a symlink needs. An
output that does not exist yet cannot be an input. And `run` now reads the
program -- a `.pbc` included -- into memory before it opens the output at all,
so the order itself is safe even where the check could not see.

## What reaches the wire (2026-10-09)

The first adversarial round against a third machine found five ways a request
could carry something the script did not ask for (docs/libraries/http.md has the
behaviour; this is why it is that behaviour).

- **No control character reaches the request head.** A header value may carry a
  horizontal tab and nothing else below 0x20, nor 0x7F; a header name is an RFC
  9110 token; a cookie name or value carries no control character at all, HTAB
  included (RFC 6265 4.1.1 excludes it from cookie-octet); a url carries none. A
  setter given one refuses -- it stores nothing and keeps the earlier value,
  answering 0 as `http_clientcert` already did -- and a verb given such a url, or
  a redirect hop to one, sends NOTHING. Both say `http_error()` 6. Refusing at
  the setter rather than sanitising is deliberate: a header that silently lost
  its tail would be a request nobody wrote.
- **A relative redirect is resolved on the raw text** (RFC 3986 5.2, with
  remove_dot_segments) and never decoded: `%26` stays `%26`. An absolute Location
  now has its dot segments removed too, as 5.2.2 says it should.
- **A port is a decimal in 1..65535 or the url is not used** -- nothing is
  dialled, as for any other url the library cannot use (status 0, error 0). An
  EMPTY port (`h:/`) means the scheme's default (RFC 3986 3.2.3), and is sent
  without its `:` (6.2.3) -- FPC's parser reads `h:` as the HOST.
- **The url judged is the url dialled** (round 2, the same day). The range check
  above read RFC 3986's authority, which ends at the FIRST `?` or `#`; FPC's
  ParseURI, which dials, cuts at the LAST `#` and `?` first, so
  `http://h:1?@h:(A+65536)?` passed as port 1 and reached `A`. Rather than
  teach one parser the other's quirks, the fragment is removed before FPC sees
  the url at all, and a url on which the two readings still differ in scheme,
  userinfo, host or port is refused like a bad port. Refusing a disagreement
  is the whole rule: neither reading is privileged, so nothing a url can hide
  between them is ever dialled. Agreement on the four fields is also agreement
  on the port digits FPC uses (its authority can outrun the RFC's only by a `?`,
  which then sits in its userinfo or host), so the range checked is the range
  dialled. A generated sweep against ParseURI itself holds the rule
  (`tests/packages/28_http_authority.bas`).
- **Params go before a fragment**, and the fragment -- from the FIRST `#` -- is
  never sent: with two `#`, FPC used to send the text between them.
- **Cookie names match exactly**, in the redirect jar as in the client's bag.

Left as they are, and why: a SPACE in a url path is still written into the
request line (it cannot start a new header line, and refusing it would refuse
urls servers accept today); a cookie name may still hold `;` or `=`.

## Dates, settings and colours: what a library accepts is what it can answer (2026-10-09)

Round 2 of the adversarial loop, over three libraries. Each page has the
behaviour; this is why it is that behaviour.

- **Date arithmetic is done on the line, not on the number.** A TDateTime before
  1899-12-30 is spelled sign-and-magnitude, so the RTL's arithmetic -- written for
  the positive half and patched at the epoch -- was wrong in a fifth and sixth
  place: the increments and the ISO week. Rather than patch two more call sites,
  every function that moves or measures takes the number apart into a day and a
  time of day, computes, and writes the spelling once (`Split`, `Join`, `Linear`
  in PhosphorDateTimeLib.pas); every function that READS a date first rounds it
  to the millisecond on the line, because the RTL's own rounding, done in the
  spelling, reads a pre-1900 moment just before midnight as the day before. The
  calendar itself -- leap years, month lengths, encoding a day -- stays the RTL's.
- **A step is a quantity.** `inc*` read their count through ArgI32, which clamps:
  right for an index, wrong for an amount. The count is read whole (Int64 below
  2^62, the Double above), so an answer is never a clipped step. What a step may
  land on is unchanged: the six additive increments still answer a number outside
  the calendar rather than refuse it (tests pin that such a number can be held),
  and `incmonth`/`incyear` still refuse.
- **The date parsers accept exactly the ISO 8601 forms the page lists, and
  complete nothing.** Unpadded parts (`2024-2-9`), which the page used to allow,
  are refused with the rest: a two-digit year, a missing year, `PM`, a time alone
  for a date-time. The accepted language is the rendered language plus `hh:nn`,
  so render and parse stay inverses, and a malformed record is an error instead of
  a plausible date.
- **A config setter refuses what it cannot round-trip; it does not escape it.**
  Decision 6 of the attack plan again: an escape would invent a convention a
  person editing the file cannot see. The refusal is now asked of the LINE the
  setter would write, through the same two functions the reader asks, instead of
  of a list of shapes -- the list had missed `[k` = `v] ;c`.
- **A colour is an unsigned 32-bit number.** A literal outside 0..2^32 - 1 is no
  colour and answers 0, as an unknown name does; `colortostr$` formats the whole
  value and answers `""` for a number no 32-bit pattern spells. The library still
  answers and never raises, as its page promises.
- **An environment name nobody can have set answers `""`** without asking the OS
  -- empty, or holding `=` or NUL -- because the OS answers such a name for a
  DIFFERENT variable than the one the program named.

## Dates far outside the calendar, text that does not follow the machine, hand-edited .ini files (2026-10-09, round 3)

Round 3 of the adversarial loop, over the same three libraries. Each page has
the behaviour; this is why it is that behaviour.

- **A reader that is not on the refusal list answers every number.** The page
  had promised it since round 2 made `incday`'s plain sum documented output, and
  the RTL could not keep the promise: DecodeTime, DayOfWeek and the `*between`
  formulas convert the whole number into an integer and raised "Invalid
  floating point operation" from about 1.07e11 days. The time of day is now read
  off the number's fraction (rounded half up to the millisecond, exactly as the
  canonical form reads it), the weekday off the day number by exact arithmetic
  mod 7 (from the Double's bits past 2^62), and a whole distance is its count --
  an Int64 below 2^63, the Double at and above. A distance that is not a number
  at all is the engine's finiteness refusal, as for every library result.
- **formatdatetime$ renders a DATE, so it refuses a number that is none**, like
  `datetostr$` and `datetimetostr$`. The alternative the page used to describe
  -- hand the number to the RTL, which clamps the top end to 9999-12-31 -- reports
  a fabricated date as real, and below the range it read the month-name table at
  index 0. `yearof`, `monthof` and `dayof` keep their documented clamp; the
  refusal list is nineteen functions now.
- **The renderer is this library's own, and every piece of its text is
  pinned.** The RTL's FormatDateTime was used under a TFormatSettings copied
  from the machine and pinned field by field; the fields nobody pinned
  (TimeAMString/TimePMString, empty under pt-BR) and the code paths that read
  the thread locale (Windows' `e`/`g` era specifiers) still followed the
  machine. Pinning two more fields would have left the next one. The walker
  reads patterns exactly as dati.inc does -- proved against the RTL by a
  differential sweep of 9000 generated patterns and dates with zero differences
  outside the decided cases -- and decides: `AM`/`PM` (the RTL's own built-in
  designators); `e`, `g` and a lone `a` are letters like any other, printed
  upper-cased (the Linux behaviour, and what every other non-specifier letter
  already did); no 255-byte cut; `c` omits the time only at an exact midnight.
- **A section written twice is one section; a key written twice is its first
  line.** The other readings were: refuse the file (Python's strict
  configparser), or let the last line win (its non-strict one). Refusing a file
  a person edited is a failure the program cannot recover from at `cfg_open@`,
  which answers a handle; "last wins" contradicts what the RTL and Windows'
  GetPrivateProfileString already read for a repeated key. So the line layer
  merges copies (moving their lines up on a save, the repeated header kept as
  text so nothing written is lost) and keeps later lines of a key as text that
  `cfg_delete@` removes with the key.
- **A line no read can reach is text, not a key or a section** -- `=value`,
  `[]`, `[;x]` and the block under such a header -- because counting a name no
  call can read is the shape round 1 removed for comment lines. The block goes
  with its header so that none of its keys silently joins the section above.
- **Text from the host is UTF-8 on Windows too.** `environ$`, `temppath$`,
  `tempfilename$`, `homepath$`, `documentspath$` and `cfg_path$` read the wide
  forms: the environment through kernel32's GetEnvironmentVariableW, declared in
  PhosphorSysLib itself (the `windows` unit stays outside the engine boundary),
  so a name is matched as Windows matches it, Unicode case included -- the RTL's
  own wide reader folds a..z only. The known folders come from the RTL's
  `windirs.GetWindowsSpecialDirUnicode`. A name that is not well-formed UTF-8
  answers `""`: no variable can have it.

## SQLite: the C library runs masked, a nested member is its JSON text, a close is asked (2026-10-09, round 4)

docs/libraries/sqlite.md has the behaviour; this is why it is that behaviour.

- **Every call into sqlite3 runs with every FPU exception masked**, and the
  VM's own state -- the MXCSR whole, sticky flags included, and the x87 control
  word -- is put back on the way out. The VM keeps the invalid-operation trap
  unmasked for the program's arithmetic, on purpose; C code does not expect it,
  and SQLite computes `Inf - Inf` or compares `1e999` as a matter of course. A
  trap there unwound through the C frames, skipped SQLite's cleanup and this
  package's finalize, left a write transaction open under an autocommit flag
  that said none was, and lost every later write that had answered 1. The other
  reading -- refuse the statements that make a NaN -- was rejected: they are
  valid SQL, SQLite has an answer for each (NULL for a NaN, a REAL infinity for
  1e999), and nothing outside SQLite can list which statements make one. The
  mask sits on the package's DOOR (each registered function is entered through
  one masked wrapper), not on each `sqlite3_*` call, so a call site added later
  cannot be the one that forgot.
- **An infinity SQLite returns is SQLite's answer, and the engine's rule still
  holds.** Its text is `Inf`/`-Inf`; read as a number it meets the finiteness
  refusal every library result meets (docs/libraries/num.md). Nothing in this
  package makes a non-finite value finite.
- **A nested member (array or object) handed to `sqlite_bindjson`,
  `sqlite_insertjson` or `sqlite_updatejson` is bound as its JSON text** -- the
  text `json_stringify$` writes for it, which is also what `json_gets$` reads a
  nested member as. The alternative, refusing the object, would make a
  document the json library builds freely unstorable without a hand-written
  flattening step, and SQLite's own JSON functions take exactly this text. A
  member with NO JSON text (a non-finite number, which a fetched row can carry)
  is refused before anything is bound: `0`, `sqlite_error()` 20
  (SQLITE_MISMATCH), the statement's bindings left as they were. A refusal
  halfway through binding is what wrote a row of old and new values mixed.
- **`sqlite_close` answers `1` only when the connection closed.** Every
  statement the package prepares inside a call is finalized in a `finally`; a
  BUSY answer is then met by finalizing whatever SQLite still lists on the
  connection and asking again, and what survives that is `0` with SQLite's code
  in `sqlite_error()` and the handle still open, rather than a `1` over a
  connection that is still holding its file.
