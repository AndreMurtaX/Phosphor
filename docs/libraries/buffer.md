# buffer — mutable bytes behind a handle

`engine/libs/PhosphorBufferLib.pas` · 23 functions · always available (engine core)

## What it is for

The founding brief settled binary I/O in one line: there is **no scalar BYTE
type** — binary I/O uses a buffer as a handle, which costs the parser and the VM
nothing because it is pure library. Half of that existed already:
`file_readallbytes@(path$)` handed back a byte handle and `file_writeallbytes`
took one, so a program could carry a file's bytes from a read to a write — and no
further. It could not read byte 5, change it, or build a payload from nothing.
This package is the missing half.

It deliberately introduces **no new type**. It operates on the same handle the Io
functions already hand out, which is what makes the two compose without a
conversion step: `file_readallbytes@` → mutate → `file_writeallbytes`. A buffer is
also what `strings_savetostream(l@, bytes@)` fills and
`strings_loadfromstream(l@, bytes@)` reads.

**Buffer or string?** `bytelen`, `byteat`, `bytestr$` and `bytemid$` (in Str)
already read bytes *out of* a string, and for inspecting one that is enough.
Writing is where a string fails: a string is immutable, so changing one byte of an
`n`-byte payload rebuilds all `n`, and a loop over it is quadratic — the exact trap
that once made a hex encoder cost 37 seconds for 64 MB. A buffer is mutable in
place, so the same loop is linear. Use `bytemid$` to read a string; use a buffer to
build one.

The stance the whole package takes: positions are **base-1** (the first byte is at
position 1), byte values are `0..255`, and every out-of-range position, count or
value is a **returned, catchable error** — never a raise, never a silent clamp.
Reading past the end of a buffer is a bug in the program, and quietly answering `0`
would hide it. The one deliberate exception is `buffer_free`, which is lenient,
because freeing is the operation a program does defensively. And a mutator answers
**information, not a success flag** — failure is already an error, so "did it work"
would always say the same thing: `buffer_set` gives back the byte written,
`buffer_resize` the new length, the bulk operations the byte count, the setters the
value written.

One spelling note. The brief wrote `buffer_new(1024)`; the rule that a built-in's
return type comes from the suffix on its **own** name arrived later, so the
constructor is `buffer_new@`, exactly as `dim@`, `strings@` and `json_parse@` are
spelled. The `@` left of the `=` types the variable; the `@` in the name types the
function.

## Functions

Throughout, `b@` is a buffer handle, `i` a base-1 position, `n` a byte count and
`v` a byte value `0..255`. Any function that takes a handle rejects one that is
fabricated, stale, or names something else (an array, a list) with an error — it is
never dereferenced.

### Making, sizing, freeing

| function | what it answers |
| --- | --- |
| `buffer_new@(n) → handle` | a buffer of `n` **zero** bytes, not `n` bytes of garbage. `n = 0` is legal. A negative size, or one over the 1 GiB cap, is an error rather than an attempted allocation — so a typo like `1e12` fails instead of trying |
| `buffer_fromstr@(s$) → handle` | a buffer holding a **copy** of `s$`'s bytes; the string is never written back into. Cannot fail — an empty string gives an empty buffer |
| `buffer_clone@(b@) → handle` | an independent copy, not a second name for the same bytes: writing into the clone leaves the original alone, in both directions |
| `buffer_free(b@) → num` | `1` if it freed a buffer, `0` if there was nothing to free. **Lenient by design** — a stale, already-freed or wrong-typed handle is *answered* with `0`, never raised, so freeing twice is safe |
| `buffer_len(b@) → num` | the size in bytes; `0` for an empty buffer |
| `buffer_resize(b@, n) → num` | the new length. Growth is zero-filled, shrinking truncates, existing bytes are kept. Same negative/1 GiB refusals as `buffer_new@` |

### Single bytes

| function | what it answers |
| --- | --- |
| `buffer_get(b@, i) → num` | byte `i` as `0..255`. A position below 1 or past the last byte is an **error**, not a `0` — that is the whole point |
| `buffer_set(b@, i, v) → num` | the byte written, `v`. A bad position or a `v` outside `0..255` is an error and **nothing is written** — the buffer is left exactly as it was |
| `buffer_fill(b@, v) → num` | how many bytes it filled, i.e. the whole length (`0` on an empty buffer, which is a legal no-op). A `v` outside `0..255` is an error |
| `buffer_fillrange(b@, i, n, v) → num` | how many bytes it filled, `n`. `n = 0` is a legal no-op at any valid position, including at length + 1; a range that runs off the end is refused, not shortened |

### Bulk: strings, copies, search

| function | what it answers |
| --- | --- |
| `buffer_tostr$(b@) → str` | all the bytes as a string, high bytes intact — `""` for an empty buffer. The string is a snapshot: later writes to the buffer do not change it |
| `buffer_slice$(b@, i, n) → str` | `n` bytes from `i`. `n = 0` gives `""` (legal, including at length + 1); a count that runs past the end is an error, never a shortened slice |
| `buffer_write(b@, i, s$) → num` | how many bytes it wrote, `bytelen(s$)`. An empty string writes `0` and is legal; a string longer than the room left at `i` is refused whole — no partial write |
| `buffer_copy(dst@, di, src@, si, n) → num` | how many bytes it copied, `n`. **Overlap-safe**, so a buffer may be copied onto itself in either direction to shift bytes. Either range running off its end is an error, and the message says which side |
| `buffer_indexof(b@, pat$ [, from]) → num` | the base-1 position of the first match at or after `from` (default 1), or `0` when there is none. An **empty pattern matches nothing, not everything** — it answers `0`. `from` is the one position in this package that is clamped rather than checked: below 1 it searches from 1, past the end it simply finds nothing |
| `buffer_equal(a@, b@) → num` | `1` when the two hold the same length and the same bytes, `0` otherwise — different lengths never match, and two empty buffers do |

### Fixed-width numbers

Width `w` is `1`, `2`, `4` or `8` bytes; anything else is an error. Byte order is
little-endian unless the optional final `bigendian?` says `true`. The assembly is
arithmetic (shifts), never a copy of a machine word, so a file written on one
machine reads back identically on another whatever that CPU's own endianness is.

| function | what it answers |
| --- | --- |
| `buffer_getint(b@, i, w [, bigendian?]) → num` | the **signed** integer in `w` bytes at `i`, sign-extended — one byte holding 200 reads as `-56`. Eight bytes carry an `int%` exactly, including values a Double cannot hold. A bad width, or `w` bytes that do not fit before the end, is an error |
| `buffer_getuint(b@, i, w [, bigendian?]) → num` | the same bytes read **unsigned** — that byte reads as `200`. Width `8` is refused with "no unsigned form", because it would not fit a signed 64-bit integer |
| `buffer_setint(b@, i, w, v [, bigendian?]) → num` | the value written, `v`. The accepted range spans *both* readings of the width — `200` and `-56` both fit one byte — and anything outside it is a **catchable error, never a silent truncation** |
| `buffer_getdbl(b@, i) → num` | the IEEE-754 double in the 8 bytes at `i`. Always little-endian; there is no byte-order argument |
| `buffer_setdbl(b@, i, v) → num` | the value written, `v`, in 8 bytes at `i`. Fewer than 8 bytes left is an error |
| `buffer_getsng(b@, i) → num` | the IEEE-754 single in the 4 bytes at `i`, widened to a number |
| `buffer_setsng(b@, i, v) → num` | the value written **at single precision** — `0.1` in gives back the nearest single, not `0.1`. 4 bytes at `i` |

## A worked example

A record with a fixed header and a variable-length payload: the magic `"PB"`, a
version byte, a big-endian 4-byte name length, the name's bytes, and a double at
the end. Nothing here concatenates a byte string; the buffer is sized once and
filled in place.

```basic
rem A tiny binary record: "PB", a version byte, a big-endian 4-byte name
rem length, the name's bytes, and an IEEE-754 double at the end.

function pack@(name$, score) local b@, n, x
  n = bytelen(name$)
  b@ = buffer_new@(2 + 1 + 4 + n + 8)
  x = buffer_write(b@, 1, "PB")            ' magic
  x = buffer_set(b@, 3, 1)                 ' version
  x = buffer_setint(b@, 4, 4, n, true)     ' length, big-endian
  x = buffer_write(b@, 8, name$)           ' payload
  x = buffer_setdbl(b@, 8 + n, score)      ' 8 bytes, little-endian
  return b@
endfunction

rec@ = pack@("café", 12.5)
p$ = path_combine$(temppath$(), "score.bin")
ok = file_writeallbytes(p$, rec@)

back@ = file_readallbytes@(p$)
println "bytes on disk: "; buffer_len(back@); ", identical: "; buffer_equal(rec@, back@)
println "magic at:      "; buffer_indexof(back@, "PB")
n = buffer_getint(back@, 4, 4, true)
println "name:          "; buffer_slice$(back@, 8, n)
println "score:         "; buffer_getdbl(back@, 8 + n)

rem one byte changed in place: no rebuild, no re-read
x = buffer_set(back@, 3, 2)
println "version now:   "; buffer_get(back@, 3)

x = buffer_free(rec@)
x = buffer_free(back@)
ok = file_delete(p$)
```

It prints `bytes on disk: 20` — `"café"` is 5 bytes, not 4 characters, and
`bytelen` is what sized the buffer.

Two things worth noticing:

- **There is no conversion step.** `file_writeallbytes` takes the very handle
  `buffer_new@` produced, and `file_readallbytes@` gives back one this package can
  keep editing. That is the payoff for not introducing a byte type.
- **The reader states the byte order it expects.** `buffer_setint(..., true)` wrote
  big-endian and `buffer_getint(..., true)` reads it back; the same four bytes read
  little-endian are a different, perfectly valid number, and nothing would warn you.

## Notes

**Bytes ≥ 128 survive the round trip.** This unit is compiled under the UTF-8
codepage directive, where building a string by concatenation would re-encode any
byte ≥ 128 into its two-byte form. Every operation here touches bytes only through
an indexed read/write, a copy or a move — there is not one `+` on a byte string in
the file, and there must never be one. So `buffer_tostr$` of four bytes is four
bytes, and `buffer_fromstr@` takes them back without growing. On the string side
the same care applies to the caller: `bytestr$(200)` is one byte, `chr$(200)` is
two.

**Errors are caught the ordinary way.** Everything strict in this package returns a
runtime error, so `on error goto` catches it and `errmsg$()` names the function, the
position and the buffer's actual length — see [err.md](err.md).

**Where the rest of byte work lives.** `file_readallbytes@` / `file_writeallbytes`
and the `open ... for binary` statements are Io; `bytelen`, `byteat`, `bytestr$`
and `bytemid$` are Str. Both are catalogued in
[function-reference.md](../function-reference.md), and `examples/binary_file.bas`
walks the string half and the buffer half of the same task side by side.
