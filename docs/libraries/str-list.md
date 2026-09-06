# str-list — a growable list of strings, held as a handle

`engine/libs/PhosphorStrListLib.pas` · 60 functions · always available (engine core)

## What it is for

A string list is the collection this dialect reaches for constantly: the lines of
a file, the fields of a record, the `name=value` pairs of a config, the matches a
pattern found. It is one object behind a handle — `l@ = strings@()` — that grows,
sorts, searches, renders itself as text and reads itself back.

Plan9Basic got this by wrapping a Delphi `TStringList`, which came with two things
Phosphor does not want. It was **0-based**, and Phosphor is base-1 *everywhere*
(decisions.md): every index on this page counts from 1, `strings_indexof` answers
**0** when an item is absent rather than `-1`, and `strings_insert` accepts
`count + 1` as the append position and nothing beyond it. And it **raised**: a
fabricated or stale handle was dereferenced, which on Linux and Android is not
something the process survives. Here every entry point validates the handle before
touching it, and every failure — a bad handle, an index outside `1..count`, a
second handle that is not a byte buffer — is a **returned error** an `on error`
handler catches, never a raise and never a silent clamp.

Beyond the list operations the package carries the whole `TStrings` **property**
surface the reference leaned on: the delimiters (`strings_delimiter`,
`strings_quotechar`, `strings_strictdelimiter`, and the `strings_delimitedtext`
pair), the name/value machinery, case sensitivity, the duplicates policy, the line
breaks and BOM, the encoding names, the change-handler **names**, batched updates,
and the file and stream round trips. The stream pair moves a list through the same
byte-buffer handle `file_readallbytes@` hands out, so the package stays
host-agnostic: no console, no window, no socket, only RTL file and byte work.

Three things a caller would otherwise be surprised by. **The default line break is
LF on every platform**, not the host's ending — taking `sLineBreak` made
`strings_text$` and `strings_savetofile` produce different *bytes* on Windows and
Linux for the same list; a program that wants CRLF asks for it with
`strings_linebreak`. **The file and stream calls answer the line count**, not a
success flag, so a `2` is two lines and not "true" — and a write the sandbox
refuses still answers the count, so check `file_exists` when the write mattered.
And `strings_casesensitive` and `strings_duplicates` are **stored and answered but
not yet acted on**: comparisons here are exact and `strings_add` never rejects a
duplicate, whatever the policy says.

## Functions

Throughout, `l@` is a string-list handle, `i` a base-1 index, `s$` an item and
`on` a flag (`0` or non-zero). Every function that takes `l@` rejects a handle that
is fabricated, already freed, or names something else — an array, a dict, a buffer
— with `not a valid string list handle`, and answers `0` or `""` alongside that
error rather than reading the address.

### Making a list, and the list itself

| function | what it answers |
| --- | --- |
| `strings@() → handle` | a new empty list. Cannot fail |
| `strings_count(l@) → num` | how many items it holds; `0` for a list that was just made or just cleared |
| `strings_add(l@, s$) → num` | the **1-based index the item landed at** — the end of the list, or its ordered position when the sorted flag is on |
| `strings_append(l@, s$) → num` | the same insertion, answering the **new count** instead of the index. On an unsorted list the two numbers agree; on a sorted one they do not |
| `strings_strings$(l@, i) → str` | the item at `i`. An `i` outside `1..count` is an error and `""` — *not* an empty item, so a list that can be empty is worth counting first |
| `strings_strings(l@, i, s$) → num` | overwrite the item at `i`, answering `1`. The same out-of-bounds error; it never grows the list to reach `i` |
| `strings_indexof(l@, s$) → num` | the 1-based position of an exact match, found by walking the list; **`0` when absent**. Needs no order |
| `strings_find(l@, s$) → num` | the same reading by **binary search** — and therefore correct only on a sorted list. On an unsorted one it answers `0` for items that are plainly there, in silence and without an error. That is the trap that separates it from `strings_indexof` |
| `strings_equals(a@, b@) → num` | `1` when both lists hold the same items in the same order, `0` otherwise — including when the counts differ. Properties are not compared |
| `strings_insert(l@, i, s$) → num` | the new count, having pushed the rest along. `i = count + 1` appends; beyond that is an error and the list is untouched |
| `strings_delete(l@, i) → num` | the new count. Out of bounds is an error, so deleting from an empty list fails rather than doing nothing |
| `strings_exchange(l@, a, b) → num` | `1`, both indices having swapped items. Either index out of bounds is an error and nothing moves |
| `strings_move(l@, from, to) → num` | `1`, the item having moved to `to` with everything between it shifted one place. `from = to` is legal and does nothing |
| `strings_sort(l@) → num` | `1`, the list ordered ascending by byte comparison (a stable insertion sort). An empty or one-item list sorts fine |
| `strings_sorted(l@) → num` | whether the sorted flag is on: `1` or `0` |
| `strings_sorted(l@, on) → num` | set that flag, answering `1`. **Turning it on sorts what is already there**, and from then on `strings_add` inserts in order instead of appending |
| `strings_clear(l@) → num` | `1`, count back to `0`. Capacity is *kept* — the backing array is not given back, so refilling costs no allocation |
| `strings_free(l@) → num` | `1` if it freed something, `0` if there was nothing to free. **Lenient by design**: a stale, already-freed or non-handle argument is *answered*, never raised, so freeing twice is safe. It frees only what it owns — a string list, or a byte buffer — so a mistyped `strings_free(a@)` cannot destroy an array or a dict |
| `strings_capacity(l@) → num` | the allocated slack: the backing array's length, which is `>= count` |
| `strings_capacity(l@, n) → num` | grow the backing array and answer the capacity it now has. `n` below the live count is raised to it, so this can never discard items |

### Text, comma text and delimited text

The setter form replaces every item; the `$` form renders the list back.

| function | what it answers |
| --- | --- |
| `strings_text(l@, s$) → num` | the count after splitting `s$` on `LF`, dropping a `CR` before it — so CRLF text loads correctly whatever `strings_linebreak` says. `""` gives an **empty list, not one empty line**, and a trailing newline does not add an empty final item |
| `strings_text$(l@) → str` | the items joined by the line break, with a trailing one when that flag is set. An empty list renders `""` |
| `strings_commatext(l@, s$) → num` | the count after splitting on commas — literally, with no quoting and no whitespace rules. `""` gives an empty list |
| `strings_commatext$(l@) → str` | the items joined by commas, unquoted. A field that itself contains a comma will not survive the round trip; that is what the delimited pair is for |
| `strings_delimitedtext(l@, s$) → num` | the count after splitting on the delimiter, honouring the quote character (a doubled quote inside quotes is one quote) and, unless strict, skipping whitespace around each field |
| `strings_delimitedtext$(l@) → str` | the items joined by the delimiter, quoting any field that is empty, holds the delimiter or the quote character, or — unless strict — holds whitespace |
| `strings_delimiter(l@, c$) → num` | set the delimiter to the **first character** of `c$`, answering `1`. An empty string restores `,` |
| `strings_delimiter$(l@) → str` | that character; `","` on a fresh list |
| `strings_quotechar(l@, c$) → num` | set the quote character from the first character of `c$`, answering `1`. An empty string restores `"` |
| `strings_quotechar$(l@) → str` | that character; the double quote on a fresh list |
| `strings_strictdelimiter(l@, on) → num` | set the strict flag, answering `1`. Strict means whitespace is ordinary text: it is neither skipped when reading nor a reason to quote when writing |
| `strings_strictdelimiter(l@) → num` | that flag: `1` or `0`. Off on a fresh list |

### `name=value` lines

Every function here reads the separator off the list, so changing it changes what
the same lines mean.

| function | what it answers |
| --- | --- |
| `strings_values$(l@, name$) → str` | the text right of the first separator on the first line whose name matches. `""` when the name is absent — and `""` is also what a genuinely empty value answers, so use `strings_indexofname` when the difference matters |
| `strings_values(l@, name$, value$) → num` | `1`, having rewritten that line — or **appended** `name$ + separator + value$` when the name was absent. It is an upsert, not a replace |
| `strings_valuefromindex$(l@, i) → str` | the value half of line `i`; `""` when that line holds no separator at all. Out of bounds is an error |
| `strings_valuefromindex(l@, i, value$) → num` | `1`, having replaced the value half of line `i` and kept its name. A line with no separator gains one, with an empty name |
| `strings_names$(l@, i) → str` | the name half of line `i`; `""` when the line holds no separator |
| `strings_keynames$(l@, i) → str` | the same reading — the second spelling the reference exposes, kept so both work |
| `strings_indexofname(l@, name$) → num` | the 1-based line whose name matches, `0` when none does. This is the only way to tell an absent name from an empty value |
| `strings_namevalueseparator$(l@) → str` | the separator character; `"="` on a fresh list |
| `strings_namevalueseparator(l@, c$) → num` | set it from the first character of `c$`, answering `1`. An empty string restores `=` |

### Policy, line breaks and BOM

| function | what it answers |
| --- | --- |
| `strings_casesensitive(l@, on) → num` | store the flag, answering `1` |
| `strings_casesensitive(l@) → num` | that flag; `0` on a fresh list. **Stored only** — searching and sorting here compare exactly, whatever it says |
| `strings_duplicates(l@, policy$) → num` | store the policy, lowercased, answering `1`. Named rather than numbered: `ignore`, `accept`, `error`. Any other word is stored as written |
| `strings_duplicates$(l@) → str` | that policy; `"ignore"` on a fresh list. **Stored only** — `strings_add` currently accepts a duplicate under every policy |
| `strings_linebreak(l@, s$) → num` | set the sequence `strings_text$` and the file and stream saves join with, answering `1`. Any string, not just one character |
| `strings_linebreak$(l@) → str` | that sequence; `chr$(10)` on a fresh list, **on every platform** |
| `strings_trailinglinebreak(l@, on) → num` | set whether a render ends with the line break, answering `1` |
| `strings_trailinglinebreak(l@) → num` | that flag; `1` on a fresh list |
| `strings_writebom(l@, on) → num` | set whether a save prefixes a UTF-8 BOM, answering `1` |
| `strings_writebom(l@) → num` | that flag; `0` on a fresh list. A load drops a leading BOM whether or not this is set |

### Encodings, change handlers, batched updates

| function | what it answers |
| --- | --- |
| `strings_encoding$(l@) → str` | the encoding a load or save established, or the default one when none has — so a **fresh list still answers a name**, which in the reference was an access violation on a nil encoding |
| `strings_defaultencoding$(l@) → str` | the name a save would use when told nothing; `"utf-8"`, because Phosphor speaks raw UTF-8 |
| `strings_defaultencoding(l@, s$) → num` | set that name, answering `1`. It is recorded and handed back, not applied: no transcoding happens here |
| `strings_onchange(l@, name$) → num` | store the **name** of a BASIC handler, answering `1`. `""` unwires it |
| `strings_onchange$(l@) → str` | that name; `""` when none is wired. Nothing fires it in a console program — the firing belongs to a host with an event loop, so this pins the name in and out |
| `strings_onchanging(l@, name$) → num` | the same, for the before-the-change handler; `1` |
| `strings_onchanging$(l@) → str` | that name, `""` when none |
| `strings_beginupdate(l@) → num` | the new nesting depth after entering a batched-update block. The list stays fully usable inside one |
| `strings_endupdate(l@) → num` | the depth after leaving one. An unmatched `strings_endupdate` answers `0` rather than going negative or failing |

### Files and streams

All six answer the **line count**, never a success flag. The three-argument forms
record an encoding name on the list; the two-argument forms record the default.

| function | what it answers |
| --- | --- |
| `strings_savetofile(l@, path$ [, enc$]) → num` | the number of lines rendered — which it answers **even if the write never happened**, because the path was outside the sandbox or the disk refused it. Confirm with `file_exists` when it matters |
| `strings_save(l@, path$) → num` | the short spelling of the same call |
| `strings_loadfromfile(l@, path$ [, enc$]) → num` | the number of lines read, the list having been replaced. A missing or unreadable file is **not** an error: the list ends up empty and the answer is `0` — so a `0` means "no lines", from whichever cause |
| `strings_load(l@, path$) → num` | the short spelling of the same call |
| `strings_loadfromstream(l@, bytes@ [, enc$]) → num` | the number of lines read out of a byte buffer — the handle `file_readallbytes@` and `buffer_new@` hand out. A second handle that is not a buffer is an error |
| `strings_savetostream(l@, bytes@ [, enc$]) → num` | the number of lines written into that buffer, **replacing** whatever it held; it does not append |

## A worked example

A settings file, written and read back, then searched two different ways. Every
index counts from 1, and every "not found" is `0`.

```basic
rem Build the settings, save them, read them back into a second list.
p$ = "bin/strlist_demo.ini"

cfg@ = strings@()
strings_values(cfg@, "user", "andre")
strings_values(cfg@, "port", "8080")
strings_values(cfg@, "host", "localhost")

rem The file calls answer the LINE COUNT, not a success flag.
println "wrote "; strings_savetofile(cfg@, p$, "utf-8"); " lines"
if file_exists(p$) = 0 then println "  ...but nothing reached the disk"

back@ = strings@()
println "read  "; strings_loadfromfile(back@, p$); " lines"
println "port         = "; strings_values$(back@, "port")
println "name of 1    = "; strings_names$(back@, 1)
println "missing name = "; strings_indexofname(back@, "proxy")

rem indexof walks the list and needs no order. find is a binary search
rem and needs a sorted one -- on this list, saved in the order it was
rem built, it reports 0 about a line that is right there.
println "unsorted: indexof "; strings_indexof(back@, "host=localhost")
println "unsorted: find    "; strings_find(back@, "host=localhost")
strings_sort(back@)
println "sorted:   find    "; strings_find(back@, "host=localhost")

rem The same three lines rendered as one delimited field list.
strings_delimiter(back@, ";")
println strings_delimitedtext$(back@)

strings_free(cfg@)
strings_free(back@)
file_delete(p$)
```

Two things worth noticing:

- **`strings_values` is an upsert.** None of the three names existed when it was
  called, so each one appended a line; calling it again with `"port"` would rewrite
  that line rather than add a fourth.
- **`strings_find` answering `0` is not an error.** Nothing is raised and nothing
  is logged — the list simply was not sorted, so the binary search walked past the
  item. When you have no order to maintain, `strings_indexof` is the one that
  always tells the truth.

## Where else lists come from

A program rarely makes every list by hand. `regex_findall@`, `regex_groups@` and
`regex_split@` hand back a string-list handle, and `dir_getfiles$` hands back text
that `strings_text` splits into one. All of them are read with the functions on
this page, and all of them are freed with `strings_free` — worth doing explicitly
when the call sits inside a loop, even though handles are released when the
program ends.

The byte buffer the stream pair moves a list through is documented in
[buffer.md](buffer.md); the full one-line catalogue of every built-in, this
library included, is in [function-reference.md](../function-reference.md).
