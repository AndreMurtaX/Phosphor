# str — text, by codepoint, with an answer for every question

`engine/libs/PhosphorStrLib.pas` · 64 functions · always available

## What it is for

Everything a program does to text that is not printing it: case, length, slicing,
trimming, search, replace, radix and number conversion, padding and
justification, splitting into words and lines, predicates, in-place edits — plus
the two helpers the compiler emits for the index sugar `s$[n]` and `s$[[n]]`.
It is the largest engine library and the one almost every program touches.

Two decisions shape the whole surface. The first is that **a character is a
Unicode codepoint, not a byte**. `len`, `left$`, `right$`, `mid$`, `reverse$`,
`asc`, `instr` and the padding widths all count codepoints, so `len("café")` is
`4` while the string occupies 5 bytes, and `chr$(233)` produces the two-byte
UTF-8 encoding of `é` rather than one masked byte. The second is that **indexing
is base-1 and absence answers 0 or ""**: `instr` answers `1` for a match at the
start and `0` when there is no match at all, `word$` and `line$` answer `""` for
a field that is not there, and `asc("")` answers `0`.

The unit header states the third rule outright — *errors are returned, never
raised*. Out-of-range arguments **clamp** rather than fail: `left$("ab", 10)` is
`"ab"`, `mid$("hello", 99)` is `""`, `space$(-3)` is `""`, `delete$("hello", 10, 2)`
leaves the string alone, and `center$("abcdef", 3)` comes back untouched because
**no padding function ever truncates**. The one deliberate exception is the byte
family: `byteat` and `bytestr$` raise a catchable runtime error when asked for a
byte outside the string or a value outside `0..255`, because there is no honest
number to answer with. `bytemid$` clamps like everything else.

Two things commonly surprise a caller. `ucase$`/`lcase$` know only ASCII `a`–`z`
(`ucase$("café")` is `"CAFé"`); the Unicode-aware pair is `aucase$`/`alcase$`.
And `hex$`/`bin$`/`oct$` are **sign-and-magnitude**, not two's complement:
`hex$(-255)` is `"-FF"`.

## Functions

### Case

| function | what it answers |
| --- | --- |
| `ucase$(s$) → str` | uppercase, ASCII `a`–`z` only. Anything else — an accented letter, punctuation — comes back byte-for-byte unchanged |
| `lcase$(s$) → str` | lowercase, ASCII `A`–`Z` only, same caveat |
| `aucase$(s$) → str` | uppercase over the whole codepoint range; this is the one that turns `é` into `É` |
| `alcase$(s$) → str` | lowercase over the whole codepoint range |
| `proper$(s$) → str` | title case: capitalize the first letter of each whitespace-separated word, lowercase the rest. ASCII letters only; every other byte is copied through untouched |
| `swapcase$(s$) → str` | invert the case of every ASCII letter; non-ASCII bytes are copied through |

### Length and slicing — codepoints, base-1

| function | what it answers |
| --- | --- |
| `len(s$) → num` | how many **codepoints**. `0` for the empty string. For bytes, use `bytelen` |
| `left$(s$, n) → str` | the first `n` codepoints. Asking for more than exists answers the whole string; `n <= 0` answers `""` |
| `right$(s$, n) → str` | the last `n` codepoints, same clamping |
| `mid$(s$, start [, len]) → str` | `len` codepoints from base-1 `start`, or to the end when `len` is omitted. A `start` past the end answers `""`; a `len` longer than what remains answers what remains |
| `reverse$(s$) → str` | the codepoints in the opposite order, so multi-byte characters survive intact |
| `strchar$(s$, n) → str` | the `n`-th codepoint as a one-character string — the helper `s$[[n]]` compiles to. Out of range answers `""` |
| `strline$(s$, n) → str` | the `n`-th line — the helper `s$[n]` compiles to. Out of range answers `""` |
| `line$(s$, n) → str` | the `n`-th line, splitting on `\n` and dropping a trailing `\r`, so CRLF text needs no preparation. Out of range answers `""`, not an error |

### Trim, pad and justify

| function | what it answers |
| --- | --- |
| `trim$(s$) → str` | `s$` without leading or trailing whitespace |
| `ltrim$(s$) → str` | without leading whitespace |
| `rtrim$(s$) → str` | without trailing whitespace |
| `space$(n) → str` | `n` spaces; `n <= 0` answers `""` |
| `string$(n, code) → str` | `n` copies of the character with codepoint `code`, each fully UTF-8 encoded; `n <= 0` answers `""` |
| `mulstring$(s$, n) → str` | `s$` repeated `n` times; `n <= 0` answers `""` |
| `ltab$(s$, width) → str` | `s$` **trimmed** then right-justified in `width` with spaces. Already at or past `width`: returned as is, never cut |
| `rtab$(s$, width) → str` | `s$` trimmed then left-justified in `width`. Same no-truncation rule |
| `lfill$(s$, width, code) → str` | left-pad to `width` with the character `code` (a code, not a string: `asc("0")`). Does **not** trim first — unlike `ltab$` |
| `rfill$(s$, width, code) → str` | right-pad to `width` with the character `code`, no trimming |
| `center$(s$, width [, code]) → str` | `s$` centered in `width`, padded with spaces or with the character `code`. An odd remainder puts the extra pad on the right. Too long for `width`: returned unchanged |

### Search and compare

| function | what it answers |
| --- | --- |
| `instr(hay$, needle$ [, start]) → num` | the base-1 **codepoint** position of `needle$`, `0` when it is not there. The optional `start` is also a codepoint position and clamps to `1`; a `start` past the end answers `0`. An empty `needle$` answers `0` |
| `instrrev(hay$, needle$) → num` | the position of the **last** occurrence, `0` when absent or when `needle$` is empty |
| `countstr(hay$, needle$) → num` | how many non-overlapping occurrences; `0` when absent, and `0` for an empty `needle$` |
| `containsstr(hay$, needle$) → num` | `1` when `needle$` occurs, else `0`. An empty `needle$` answers `0` — unlike `startsstr`/`endsstr`, which call an empty affix a match |
| `containstext(hay$, needle$) → num` | as `containsstr`, ignoring case |
| `startsstr(text$, prefix$) → num` | `1` when `text$` begins with `prefix$`. The **text comes first**; an empty `prefix$` answers `1` |
| `endsstr(text$, suffix$) → num` | `1` when `text$` ends with `suffix$`; a suffix longer than the text answers `0` |
| `startstext(text$, prefix$) → num` | as `startsstr`, ignoring case |
| `endstext(text$, suffix$) → num` | as `endsstr`, ignoring case |
| `strcmp(a$, b$) → num` | the **sign** of a case-sensitive comparison: `-1`, `0` or `1` — never the raw difference |
| `strcmpi(a$, b$) → num` | the same sign, ignoring case |

### Splitting into fields and lines

| function | what it answers |
| --- | --- |
| `count(s$) → num` | how many lines `s$` holds, splitting on `\n` (a trailing `\r` is dropped). The empty string answers `0`; a string with no newline answers `1` |
| `wordcount(s$, sep$) → num` | how many **fields** splitting on `sep$` produces. Never `0`: a string with no separator in it is one field, and so is the empty string. An empty `sep$` answers `1` |
| `word$(s$, n, sep$) → str` | the `n`-th field (base-1). A field that is not there answers `""` — and so does a field that is genuinely empty, so use `wordcount` when the difference matters. An empty `sep$` answers the whole string |

### Replace and edit

All positions are base-1 codepoint positions and all four clamp; none of them
can fail.

| function | what it answers |
| --- | --- |
| `replacestr$(s$, from$, to$) → str` | `s$` with **every** `from$` replaced by `to$`, case-sensitive. No match answers `s$` unchanged |
| `replacetext$(s$, from$, to$) → str` | the same, ignoring case when matching |
| `insert$(s$, ins$, pos) → str` | `s$` with `ins$` inserted before `pos`. `pos` clamps to `1..len+1`, so a position past the end appends rather than erroring |
| `delete$(s$, pos, count) → str` | `s$` with `count` characters removed from `pos`. A `count` of `0`, or a `pos` past the end, answers `s$` unchanged |
| `stuffstring$(s$, start, len, repl$) → str` | `s$` with the `len` characters at `start` replaced by `repl$` — delete and insert in one call. A `start` past the end appends |

### Numbers and radix

| function | what it answers |
| --- | --- |
| `asc(s$) → num` | the codepoint of the first character — `233` for `"é"`, not a byte. The empty string answers `0` |
| `chr$(code) → str` | the character for `code`, UTF-8 encoded, so `chr$(233)` is **two bytes**. A negative `code` clamps to `0` (a NUL byte). For a raw byte, use `bytestr$` |
| `hex$(n%) → str` | `n%` in hexadecimal, uppercase digits. **Sign and magnitude**: `hex$(-255)` is `"-FF"`, not a two's-complement word. `0` answers `"0"` |
| `bin$(n%) → str` | the same in base 2 |
| `oct$(n%) → str` | the same in base 8 |
| `val(s$) → num` | `s$` parsed as a number, after trimming, with `.` as the decimal point whatever the locale. **`0` unless the whole trimmed string is a number** — `val("12abc")` is `0`, not `12`. Ask `valcode()` to tell that apart from a genuine zero |
| `valcode() → num` | the base-1 position where the **last** `val` stopped: `0` when the whole string parsed. `val("12abc")` leaves `3`. It reports on the most recent `val` call anywhere, so read it immediately |
| `stri$(n) → str` | `n` as text, locale-invariant (`.` decimal, no thousands separator) and with **no leading space** for a positive number, unlike classic BASIC `STR$` |
| `str$(n) → str` | the same function under its familiar name — an exact alias of `stri$` |

### Predicates

Each answers `1` or `0` — the names carry no `?` suffix, so the value is a number
you can compare or add. **The empty string is always `0`**: it has no digits, no
letters, and no spaces in it.

| function | what it answers |
| --- | --- |
| `isnumeric(s$) → num` | `1` when the whole trimmed string parses as a number |
| `isalpha(s$) → num` | `1` when every byte is an ASCII letter — an accented letter answers `0` |
| `isdigits(s$) → num` | `1` when every character is `0`–`9` |
| `isalnum(s$) → num` | `1` when every character is an ASCII letter or digit |
| `isspace(s$) → num` | `1` when every character is whitespace (space, tab, CR, LF, VT, FF) |
| `islower(s$) → num` | `1` when there is at least one lowercase letter and no uppercase one. `"123"` answers `0` — no letters at all is not lowercase |
| `isupper(s$) → num` | `1` when there is at least one uppercase letter and no lowercase one |

### Bytes

The four exceptions to codepoint counting. A Phosphor string is a length-counted
byte container that carries all 256 values intact, including NUL, so binary data
needs no hex codec — but it has to be addressed in the byte domain, which is what
these do. They live in the engine, not a package, so an embedding host has them too.

| function | what it answers |
| --- | --- |
| `bytelen(s$) → num` | how many **bytes**. `bytelen("café")` is `5` where `len` is `4` |
| `byteat(s$, i) → num` | the value `0..255` of byte `i`, base-1. An index outside the string **raises** a catchable runtime error naming the valid range — the one place this library refuses rather than clamps, because no number would be an honest answer |
| `bytestr$(v) → str` | a one-byte string holding `v`. This is the byte constructor `chr$` cannot be, since `chr$` would UTF-8-encode anything above 127. A `v` outside `0..255` raises |
| `bytemid$(s$, i, n) → str` | `n` bytes from byte `i`, verbatim. Clamped at both ends and never raises: a start past the end or a non-positive `n` answers `""` |

## A worked example

A small invoice printed as a fixed-width table, from records held as one
multi-line string. Nothing here checks a length or guards an index — the
splitters answer `""` for a field that is absent and the padding functions never
truncate, so the layout code has no error path at all.

```basic
rem Row 3 has no quantity and row 4 has a price that is not a number.
rem Neither is an error here; both are answers the program reads.
data$ = "widget,3,4.50\ngrommet,12,0.75\nflange,,9.00\nbolt,50,tbd"

println center$(" INVOICE ", 34, asc("="))

total = 0
for i = 1 to count(data$)
  row$  = line$(data$, i)
  name$ = trim$(word$(row$, 1, ","))
  qty$  = trim$(word$(row$, 2, ","))
  unit$ = trim$(word$(row$, 3, ","))
  tag$  = lfill$(stri$(i), 3, asc("0"))

  if isdigits(qty$) = 0 then
    println tag$; "  "; rtab$(proper$(name$), 16); ltab$("no quantity", 13)
  else
    price = val(unit$)
    if valcode() <> 0 then
      println tag$; "  "; rtab$(proper$(name$), 16); ltab$("bad price @" + stri$(valcode()), 13)
    else
      total = total + val(qty$) * price
      println tag$; "  "; rtab$(proper$(name$), 16); ltab$(stri$(val(qty$) * price), 13)
    endif
  endif
next

println string$(34, asc("-"))
println "     "; rtab$("TOTAL", 16); ltab$(stri$(total), 13)
```

It prints:

```
============ INVOICE =============
001  Widget                   13.5
002  Grommet                     9
003  Flange            no quantity
004  Bolt             bad price @1
----------------------------------
     TOTAL                    22.5
```

Two things worth noticing:

- **`val` alone cannot tell you it failed.** `val("tbd")` is `0`, and so is
  `val("0")`. `valcode()` is what separates them — it answers `1` here, the
  position where the parse stopped. Read it straight after the `val` that set it.
- **`word$` answers `""` for the missing quantity, so the loop never faults.** The
  program decides what an empty field means; the library only reports that the
  field is empty. That is the same stance `err` takes with errors.

## Notes

- `s$[n]` and `s$[[n]]` are **compiler sugar**, not syntax the library sees:
  `s$[n]` becomes `strline$(s$, n)` and `s$[[n]]` becomes `strchar$(s$, n)`. Both
  helpers are registered and callable directly, and both are base-1.
- **Choosing between the case pairs.** `ucase$`/`lcase$` are ASCII-only and fast;
  `aucase$`/`alcase$` walk the whole codepoint range. `proper$` and `swapcase$`
  are ASCII-only by construction — they edit letters in place inside a copy and
  touch no other byte, which is why an accented letter passes through them intact
  rather than being mangled into `?`.
- **Where the rest of text handling lives.** Regular expressions, string lists,
  formatted output (`print using`), JSON and file I/O are their own libraries;
  this page covers only what operates on a plain `$` value.
