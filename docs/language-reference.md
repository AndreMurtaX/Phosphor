# Phosphor BASIC — language reference

A quick, didactic guide to writing programs in Phosphor BASIC. Every code block
below was run through `bin/phosphor.exe`; the comment or line after each shows the
real output.

> Phosphor is a modern BASIC built on Free Pascal — a spiritual successor to
> Plan9Basic, not a port of it. Where it made sense to be clearer or stricter than
> the old dialect, Phosphor is: indices start at **1** everywhere, a value type is
> written into every name with a one-character suffix, and a condition must be an
> honest comparison, never a bare number. The result reads like classic BASIC but
> catches more of your mistakes at compile time.

---

## Your first program

Put this in `hello.bas`:

```basic
println "Hello, Phosphor!"
```

Build the console host once, then run the file:

```powershell
scripts\build.ps1            # produces bin\phosphor.exe
bin\phosphor.exe hello.bas
```

```
Hello, Phosphor!
```

`phosphor.exe <file.bas>` runs a program; `phosphor.exe` alone opens a small REPL.
You can also `phosphor compile file.bas out.pbc` (bytecode) or
`phosphor pack file.bas app.exe` (a standalone executable).

---

## Program structure & comments

A program is a list of statements, one per line. There is no boilerplate — the
first line is already running. Two comment forms exist, and both can trail a
statement:

```basic
rem a whole-line comment
' another whole-line comment
x = 21 * 2        ' a trailing comment
println x
```

```
42
```

An explicit `end` stops the program early (handy before a block of subroutines or
functions — see below).

---

## Data types & the suffix convention

Phosphor has **five value types, and the type is part of the name**: the last
character of a variable name is its type suffix. Names are case-insensitive
(`Score` and `score` are the same variable).

| Suffix | Type | Example | Notes |
|--------|------|---------|-------|
| *(none)* | number | `price = 19.99` | double-precision float |
| `%` | integer | `count% = 42` | whole numbers |
| `$` | string | `name$ = "Ada"` | text |
| `?` | boolean | `ready? = 3 > 2` | prints as `true` / `false` |
| `@` | handle | `list@ = dim@(3)` | arrays, dicts, files, JSON… |

```basic
count% = 42          ' % integer
price  = 19.99       '   number (Double)
name$  = "Ada"       ' $ string
ready? = 3 > 2       ' ? boolean
println count%; " "; price; " "; name$; " "; ready?
```

```
42 19.99 Ada true
```

> `#` is **not** a suffix in Phosphor — there is no `#` file-number type. File
> work is done through handle functions (see *Files*).

---

## Variables & CONST

Assignment is just `name = value`; the optional keyword `let` is accepted. A
`const` gives a name to a fixed number or string; assigning to a constant is a
compile-time error, so a value you never meant to change can't be changed by
accident.

```basic
const MAXLIVES = 3
const GREETING$ = "Hi"
let score = MAXLIVES * 10
println GREETING$; ", score = "; score
```

```
Hi, score = 30
```

---

## Operators

Arithmetic, with two divisions worth remembering:

| Operator | Meaning | Example → result |
|----------|---------|------------------|
| `+ - *` | add / subtract / multiply | `6 * 7` → `42` |
| `/` | **real** division (always float) | `7 / 2` → `3.5` |
| `\` | **integer** division | `7 \ 2` → `3` |
| `^` | power (always float) | `2 ^ 8` → `256` |
| `mod` | remainder | `17 mod 5` → `2` |
| `and or not` | logic | `not (5 < 3)` → `true` |
| `= <> < > <= >=` | comparison | `2 >= 2` → `true` |

Integer±*integer stays an integer; the moment a float joins in, the result is a
float. Integer overflow is a catchable error, not silent wraparound.

Compound assignment works too: `+= -= *= /=` for numbers, and `+=` to append to a
string. The operator and `=` must be adjacent (`x += 1`, not `x + = 1`).

```basic
println 7 / 2        ' real division  -> 3.5
println 7 \ 2        ' integer division -> 3
println 2 ^ 8        ' power -> 256
println 17 mod 5     ' remainder -> 2
ok? = (2 > 1) and not (5 < 3)
if ok? = true then println "logic works"
```

```
3.5
3
256
2
logic works
```

---

## Control flow

### IF / ELSEIF / ELSE

A one-line form (`if cond then statement`) and a block form terminated by `endif`
(the two-word `end if` also works). `elseif` chains extra tests.

```basic
score = 72
if score >= 90 then
  println "A"
elseif score >= 60 then
  println "pass"
else
  println "retry"
endif
```

```
pass
```

> **Conditions must be comparisons or logical expressions.** A bare value is
> rejected: `if x then` raises *"a bare value is not a condition"*. Write
> `if x = 1 then`, or for a boolean, `if ok? = true then`.

### Loops

Phosphor has a pre-test loop, a post-test loop, and a counted loop.

```basic
' pre-test: while
i = 0
while i < 3
  i += 1
endwhile
println "while -> "; i

' post-test: repeat runs at least once
j = 0
repeat
  j += 1
until j >= 4
println "repeat -> "; j

' counted, with a step
total = 0
for n = 10 to 1 step -2
  total += n
next
println "for -> "; total
```

```
while -> 3
repeat -> 4
for -> 30
```

Notes:
- `while … endwhile` (and `wend`) is the pre-test loop; `do while <cond> … loop`
  is an equivalent spelling.
- `repeat … until <cond>` is the post-test loop (the body always runs once). There
  is **no** `do … loop until` form.
- `for … to … [step …] … next` — `next` is bare, with no loop variable after it.
- Inside any loop, `break` exits and `continue` skips to the next iteration.

### SELECT CASE

Matches a value against cases; `case else` catches the rest. Works on numbers and
on strings.

```basic
cmd$ = "help"
select case cmd$
  case "help"
    println "showing help"
  case "quit"
    println "goodbye"
  case else
    println "unknown command"
endselect
```

```
showing help
```

### GOSUB / GOTO and labels

A label is a name followed by `:` (or a leading line number). `gosub` calls a
subroutine and `return` comes back; `goto` jumps.

```basic
gosub greet
println "back in main"
goto finish

greet:
  println "hello from a subroutine"
  return

finish:
println "done"
```

```
hello from a subroutine
back in main
done
```

### ON … GOTO / GOSUB

A computed jump: a 1-based selector picks the *N*-th label in the list; a selector
outside the range falls through to the next statement.

```basic
choice = 2
on choice gosub first, second, third
end

first:
  println "one"
  return
second:
  println "two"
  return
third:
  println "three"
  return
```

```
two
```

---

## Functions & LOCAL

Define a function with `function name(args) … return value … endfunction` (the
two-word `end function` is accepted). The name's suffix is the return type:
`greet$` returns a string, `factorial` returns a number. Recursion is fine.

Variables listed after `local` are private to the call. **Any name you use that
is *not* in the `local` list refers to a global** — so declare your scratch
variables as locals unless you deliberately want to share one.

```basic
function factorial(n) local r
  if n <= 1 then return 1
  r = factorial(n - 1)
  return n * r
endfunction

function greet$(who$)
  return "hello " + who$
endfunction

println factorial(5)
println greet$("world")
```

```
120
hello world
```

---

## Arrays

Create an array with `dim@` (numbers), `sdim@` (strings) or `pdim@` (handles); it
returns a handle. **Indices are 1-based.** Read and write elements with bracket
sugar `a@[i]`, and query bounds with `lbound` / `ubound` / `ndims`. Arrays can be
multi-dimensional (`dim@(rows, cols)`), and compound assignment works on elements
(`a@[i] += 1`).

```basic
a@ = dim@(5)
for i = 1 to 5
  a@[i] = i * i
next
println "a[3] = "; a@[3]
println "size = "; ubound(a@, 1)

grid@ = dim@(2, 3)
grid@[2, 3] = 99
println "grid[2,3] = "; grid@[2, 3]

names@ = sdim@(2)
names@[1] = "Ada"
names@[2] = "Alan"
println names@[1]; " and "; names@[2]
```

```
a[3] = 9
size = 5
grid[2,3] = 99
Ada and Alan
```

---

## Strings

Strings are 1-based and Unicode-aware (character operations count codepoints). Two
index sugars sit on a string variable:

- `s$[[n]]` — the **n-th character** (base-1, by codepoint).
- `s$[n]` — the **n-th line** (base-1); `count(s$)` gives the line count.

Escapes are supported in literals: `\n \t \r \0 \a \b \f \v \\ \"`, and a doubled
`""` also yields one quote. Because `\` is an escape, a **literal backslash must be
doubled** — a Windows path is `"C:\\temp\\a.txt"` (or just use `/`).

```basic
s$ = "Phosphor"
println "chars 1 and 8: "; s$[[1]]; s$[[8]]
println "upper: "; ucase$(s$)
println "slice: "; mid$(s$, 2, 4)
println "find:  "; instr(s$, "hor")

poem$ = "first\nsecond\nthird"
println "line 2: "; poem$[2]
println "lines:  "; count(poem$)
```

```
chars 1 and 8: Pr
upper: PHOSPHOR
slice: hosp
find:  6
line 2: second
lines:  3
```

Handy string functions: `len`, `left$`, `right$`, `mid$`, `trim$`/`ltrim$`/`rtrim$`,
`ucase$`/`lcase$`, `reverse$`, `instr`/`instrrev` (1-based, `0` when absent),
`replacestr$`/`replacetext$`, `asc`/`chr$`, `str$`/`stri$` (number → string),
`val` (string → number), `word$`/`wordcount`.

---

## Output

`print` writes with **no** trailing newline; `println` adds one. A `;` separates
items on the same call, and numbers are converted to text automatically.

```basic
print "no newline here... "
println "but this line ends."
println "x="; 10; " y="; 20
```

```
no newline here... but this line ends.
x=10 y=20
```

To turn a number into a string explicitly (e.g. to concatenate with `+`), use
`str$(n)` or the locale-invariant `stri$(n)`.

---

## DATA / READ / RESTORE

`data` lines hold a stream of constants; `read` pulls the next one each time;
`restore` rewinds to the first item. Reading continues across multiple `data`
lines.

```basic
data 11, 22, 33
data 44, 55

read a
read b
println a + b        ' 33

restore              ' rewind to the first item
read c
println c            ' 11
```

```
33
11
```

---

## Files

There is no `#`-channel file I/O. Whole-file text and paths are handled by library
functions that **return** success/failure instead of raising: a write answers `1`
on success (`0` on failure), and a read of a missing file answers `""`.

```basic
ok = file_writealltext("note.txt", "saved by Phosphor")
println "write ok: "; ok
text$ = file_readalltext$("note.txt")
println "read back: "; text$
```

```
write ok: 1
read back: saved by Phosphor
```

Related helpers include `file_exists`, `savetext$`/`opentext$`, and the `dir_*` /
`path_*` families (path helpers accept both `/` and `\` on every platform).

---

## Error handling (errors are values)

A runtime error jumps to an installed handler instead of aborting. `on error goto
<label>` installs one; inside it, `err()` is the error code, `errmsg$()` the
message, and `erl()` the failing line. `resume next` continues past the failing
statement, `resume` retries it, and `on error goto 0` turns handling off.

```basic
on error goto handler
x = 5 / 0
println "after the error, x = "; x
on error goto 0
end

handler:
  println "caught error "; err(); ": "; errmsg$()
  resume next
```

```
caught error 2: division by zero
after the error, x = 0
```

(The handler runs first, then `resume next` continues at the `println` after the
faulting line; `x` was never assigned, so it is still `0`.) Error codes: `1`
integer overflow, `2` division by zero, `3` type mismatch, `4` unknown function,
`5` syntax, `6` runtime. You can raise your own with `error("message")`, clear the
state with `err_clear()`, or route faults to a function with `on error call fn`.

---

## Debugging: TRACE & BREAKPOINT

`trace 1` / `trace 0` toggle tracing, and `breakpoint "msg", var…` reports a frame
to the host debugger. In a plain console run there is no debugger attached, so a
breakpoint simply reports-and-continues — it never blocks a program.

```basic
trace 1
breakpoint "checkpoint reached", 42
trace 0
println "execution continued"
```

```
execution continued
```

---

## The standard libraries

Built-ins are grouped into libraries, all available by default. This is the map;
the full catalog of every function is in
[docs/function-reference.md](function-reference.md).

| Area | What you get | A few names |
|------|--------------|-------------|
| Strings | case, slicing, search, replace, radix, words | `ucase$` `mid$` `instr` `replacestr$` `hex$` |
| Numbers | rounding, roots, logs, trig, random | `abs` `sqr` `round` `sin` `rnd` |
| Arrays | create, index, bounds, multi-dim | `dim@` `sdim@` `ubound` `narr_get` |
| Dictionaries | string-keyed maps | `dict@` `sdict@` `pdict@` |
| String lists | growable text lists | `strings@` `strings_add` `strings_text$` |
| JSON | parse / build / query | `json_parse@` `json_object@` `json_get@` |
| Files & paths | whole-file text, path ops | `file_writealltext` `file_readalltext$` `path_*` |
| Date & time | dates as numbers, arithmetic | `now` `today` `dateadd` `format$` |
| Regex | pattern match / extract (pattern-first) | `regex_match` `regex_find$` |
| Config (INI) | read/write settings files | `config@` `config_getstr$` `config_setint` |
| System | args, dirs, env, colours | `getenv$` `mkdir` `tempdir$` |
| Platform | OS name / version / arch | `os_name$` `os_platform$` `os_check` |
| Errors | the ON ERROR face | `err` `errmsg$` `erl` `error` |
| Indirect call | call a user function by name | `callfunc` |
| Host services | event pump, clipboard (host-filled) | `processmessages` `copytext$` |
| Retrieval (RAG) | local keyword index over markdown | `rag@` `rag_retrieve$` |

> `sqr()` is **square root** (not square). Booleans print as `true` / `false`.

---

## Quick reference

```basic
' --- values ------------------------------------------------------------
n   = 3.14        ' number (Double)      i% = 7      ' integer
s$  = "text"      ' string               b? = 1 < 2  ' boolean (true/false)
h@  = dim@(3)     ' handle (array/dict/file/json/…)
const PI = 3.14159                       ' fixed, assignment is an error

' --- operators ---------------------------------------------------------
+  -  *           /  (real, ->float)     \  (integer)     ^  (power)
mod   and  or  not     =  <>  <  >  <=  >=
+=  -=  *=  /=    (compound; += also appends strings)

' --- control -----------------------------------------------------------
if c then …                              ' one line
if c then … elseif c then … else … endif
while c … endwhile        do while c … loop        repeat … until c
for i = a to b [step k] … next     ' break / continue inside
select case v … case x … case else … endselect
gosub label … return      goto label      on k goto/gosub l1, l2, …

' --- functions ---------------------------------------------------------
function f(a, b) local t … return v … endfunction
'   names not in `local` are GLOBALS; suffix on the name = return type

' --- strings (1-based) -------------------------------------------------
s$[[n]]  ' n-th character      s$[n]  ' n-th line       count(s$) ' #lines
len  left$  right$  mid$  ucase$  lcase$  trim$  instr  replacestr$
escapes: \n \t \r \0 \a \b \f \v \\ \"   and  ""  -> one quote

' --- output ------------------------------------------------------------
print "no newline"     println "with newline"     println a; " "; b

' --- data / errors -----------------------------------------------------
data 1, 2, 3   read x   restore
on error goto h … h:  err()  errmsg$()  erl()  resume | resume next
```

---

## Tips & common mistakes

- **A condition can't be a bare value.** `if x then` and even `if ok? then` are
  rejected. Use a comparison: `if x = 1 then`, `if ok? = true then`,
  `if a > b and c < d then`.
- **Backslashes in string literals are escapes.** `"C:\temp"` is wrong (`\t` is a
  tab); write `"C:\\temp"` or `"C:/temp"`. This bites file paths most often.
- **`/` vs `\`.** `/` always gives a float (`10 / 4` → `2.5`); use `\` for integer
  division (`10 \ 4` → `2`).
- **Everything is 1-based** — arrays, string characters, string lines, `instr`
  positions. There is no index `0`; an absent `instr` match returns `0` to mean
  "not found".
- **`next` takes no variable.** Write `next`, not `next i`.
- **No `input`, no `print using`, no `do … loop until`, no `#` file channels.** Use
  the library functions shown above instead.
- **Undeclared names inside a function are globals.** List scratch variables after
  `local` so they don't leak.
- **`sqr` is square root.** For x², write `x * x` or `x ^ 2`.
