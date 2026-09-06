# dict — string-keyed maps as handles

`engine/libs/PhosphorDictLib.pas` · 20 functions · always available (engine core, no package to enable)

## What it is for

A dictionary is a map from a string key to a value, held as a handle and passed
around like any other `@`. There are three of them, one per value kind: `dict@`
holds numbers, `sdict@` holds strings, `pdict@` holds other handles — which is how
a dictionary of dictionaries, or of arrays, or of JSON nodes, is built. Entries
keep **insertion order**, so `dict_key$(d@, n)` walks them in the order they were
first set, and a key that is overwritten keeps the position it already had.

The lookup is a **linear scan of the keys**, not a hash. That is a deliberate size
trade — configuration, headers, counters, small indexes are what these are for.
A dictionary with tens of thousands of keys will feel it.

The design stance is the project's usual one, in three places a caller can see.
**Errors are values, not events**: the library never raises inside itself, and a
handle that is not a dictionary — a number cast with `pointer@(n)`, a handle from
another library, a stale id — is *checked* rather than dereferenced, and the call
fails the statement with `not a valid dictionary handle`, catchable by
`on error goto`. **A mutator answers information**: `dict_remove` answers whether
it actually removed anything (`1`/`0`), not whether it was asked politely, and
`dict_set@` answers the dict so a set can be used as an expression.
**Indexing is base-1**: `dict_key$(d@, 1)` is the first key.

**Absent is a real answer, and it is the same answer as zero.** `dict_get` on a
missing key gives the kind's empty value — `0`, `""`, or handle `0` — which is
exactly what a stored zero or a stored empty string gives back. When the
difference matters, ask (`dict_exists`, `dict_haskey`) or supply your own fallback
(`dict_getdef`). This matters most for `pdict_get@`: handle `0` is not a valid
handle, so an absent key hands back something that will fail at its *next* use
rather than at this one — `pdict_getdef@` with a real handle avoids that.

One more thing a caller would not guess: get and set are **one implementation
registered under every typed name**. The dictionary knows its own kind and the
accessors do no conversion, so the family you call chooses only how the compiler
types the expression. `dict_get(sd@, "name")` on a string dictionary hands back
the string it stored. Match the family to `dict_typename$` and this never comes up.

## One dictionary, any kind

`dict@()`, `sdict@()` and `pdict@()` all build the **same container**, and always
did: the storage is an array of the engine's five-kind cell and the setter never
enforced anything. What looked like three dictionaries was three registration
surfaces over one, which meant a program wanting a number and a string under the
same keys needed two dictionaries with the same keys — and the bool kind, one of
the language's five, had no dictionary at all.

One dictionary now holds any of them:

```basic
d@ = dict@()
dict_set@(d@, "nome",   "Ana")
dict_set@(d@, "idade",  41)
dict_set@(d@, "altura", 1.62)
dict_set@(d@, "ativo",  true)
dict_set@(d@, "conf",   sdict@())
```

**Reading needs typed spellings**, and that is a rule of the language rather than
a choice here: a function's return type comes from the suffix on its own name, so
`dict_get$` returns a string because it is spelled `$`. There can be no
polymorphic getter. What there can be — and now is — is a way to ask what a key
holds before reading it:

```basic
for i% = 1 to dict_count(d@)
  k$ = dict_key$(d@, i%)
  select case dict_typeof$(d@, k$)
    case "string"  : println k$ + " = " + dict_get$(d@, k$)
    case "int"     : println k$ + " = " + str$(dict_get%(d@, k$))
    case "number"  : println k$ + " = " + str$(dict_get(d@, k$))
    case "bool"    : if dict_get?(d@, k$) = true then println k$ + " = true"
    case "handle"  : println k$ + " = <handle>"
  endselect
next
```

`dict_type` and `dict_typename$` still answer what a dictionary was **created**
as. That is now a statement of intent rather than a constraint — nothing stops
any of them holding anything — and every program written before this keeps
working unchanged.

## Functions

### Creating

| function | what it answers |
| --- | --- |
| `dict@() → handle` | a new, empty dictionary whose values are numbers. Cannot fail. There is no free function: the handle lives until the program ends |
| `sdict@() → handle` | the same, with string values |
| `pdict@() → handle` | the same, with handle values |

### Setting and reading

| function | what it answers |
| --- | --- |
| `dict_set@(d@, key$, value) → handle` | the dictionary itself, so a set can be chained or nested. A key already present is overwritten **in place**, keeping its insertion position and leaving `dict_count` unchanged. On a handle that is not a dictionary the statement fails with `not a valid dictionary handle` |
| `sdict_set@(d@, key$, value$) → handle` | the same, storing a string |
| `pdict_set@(d@, key$, value@) → handle` | the same, storing a handle. The dictionary does not own what it stores and will not free it |
| `dict_get(d@, key$) → num` | the stored number; **`0` for a key that is not there** — indistinguishable from a stored `0`. Fails on a non-dictionary handle |
| `sdict_get$(d@, key$) → str` | the stored string; `""` when the key is absent |
| `pdict_get@(d@, key$) → handle` | the stored handle; **handle `0` when the key is absent**, which is not a valid handle — passing it on fails at that later call, not here |
| `dict_getdef(d@, key$, default) → num` | the stored number, or `default` when the key is absent. The way to tell "absent" from "zero" without a second call |
| `sdict_getdef$(d@, key$, default$) → str` | the stored string, or `default$` when absent |
| `dict_getdef$(d@, key$, default$) → str` | the same, spelled for the one dictionary |
| `dict_getdef@(d@, key$, default@) → handle` | the same with a handle default |
| `dict_getdef?(d@, key$, default?) → bool` | the same with a bool default. There is no separate int form: an int default *is* a number default, because the registry widens `%` to `n` |
| `dict_typeof(d@, key$) → num` | what this key holds — `0` number, `1` string, `2` int, `3` handle, `4` bool, the language's five kinds in their own order — and `-1` when the key is not there. That `-1` is the point: without it an absent key cannot be told from one holding a number |
| `dict_typeof$(d@, key$) → str` | the same as a name (`number`, `string`, `int`, `handle`, `bool`), and `""` for an absent key |
| `dict_get$(d@, key$) → str` | the value at `key$`, `""` when there is none |
| `dict_get%(d@, key$) → int` | the same where an int is expected, `0` when there is none |
| `dict_get@(d@, key$) → handle` | the same for a handle, `0` when there is none |
| `dict_get?(d@, key$) → bool` | the same for a bool, `false` when there is none. Each typed spelling answers ITS OWN empty value; the single shared reader could not, because it knew the container's kind and not the caller's question |
| `pdict_getdef@(d@, key$, default@) → handle` | the stored handle, or `default@` when absent — a usable fallback instead of handle `0` |

### Asking

| function | what it answers |
| --- | --- |
| `dict_count(d@) → num` | how many entries there are; `0` for a new dictionary. Fails on a handle that is not a dictionary — this is the check, and the one call whose only job is to be cheap |
| `dict_haskey(d@, key$) → num` | `1` if the key is present, `0` if not. Asking is not reading: a key holding `0` or `""` still answers `1` |
| `dict_exists(d@, key$) → num` | the same function under a second name — both spellings are registered, neither is preferred |
| `dict_key$(d@, n) → str` | the key at 1-based position `n` in insertion order. Out of range — `0`, negative, past the end, or a number too large to be an index (clamped, never wrapped) — fails with `dict index N out of bounds 1..count`. On an empty dictionary every position is out of range, and the message says `1..0` |
| `dict_type(d@) → num` | the value kind as a code: `0` numeric, `1` string, `2` pointer |
| `dict_typename$(d@) → str` | the same as a word: `"numeric"`, `"string"` or `"pointer"` |

### Removing

| function | what it answers |
| --- | --- |
| `dict_remove(d@, key$) → num` | **whether it removed anything**: `1` if the key was there, `0` if it was never there or was already removed. The keys that follow it shift down one position, keeping their relative order |
| `dict_clear@(d@) → num` | `1`, always — the count drops to `0` and every key is gone. Despite the `@` in the name it answers a number, not the dict, so `x@ = dict_clear@(d@)` is rejected at compile time with `cannot store int into handle variable` |

## A worked example

Tally the words of a line, read the tally back in the order the words first
appeared, then park it inside a pointer dictionary next to a string dictionary of
labels — the ordinary shape of a small record built from all three kinds.

```basic
rem Count the words of a line, then walk the tally in insertion order.

text$ = "the quick brown fox jumps over the lazy dog the fox"
tally@ = dict@()

word$ = ""
for i = 1 to len(text$) + 1
  c$ = mid$(text$, i, 1)
  if c$ = " " or c$ = "" then
    if word$ <> "" then dict_set@(tally@, word$, dict_getdef(tally@, word$, 0) + 1)
    word$ = ""
  else
    word$ = word$ + c$
  endif
next

println "distinct words: "; dict_count(tally@); " in a "; dict_typename$(tally@); " dict"
for i = 1 to dict_count(tally@)
  k$ = dict_key$(tally@, i)
  println k$; " -> "; dict_get(tally@, k$)
next

rem Asking is not reading, and removing answers whether it removed anything.
if dict_exists(tally@, "cat") = 0 then println "'cat' was never counted"
println "removing 'the': "; dict_remove(tally@, "the")
println "and again:     "; dict_remove(tally@, "the")

rem A pointer dict holds the tally itself, beside a string dict of labels.
report@ = pdict@()
pdict_set@(report@, "words", tally@)
labels@ = sdict@()
sdict_set@(labels@, "title", "word tally")
pdict_set@(report@, "labels", labels@)

got@ = pdict_get@(report@, "words")
println sdict_get$(labels@, "title"); ": "; dict_count(got@); " left"
println "missing label -> ["; sdict_getdef$(labels@, "author", "(none)"); "]"
println "kinds: "; dict_type(tally@); " "; dict_type(labels@); " "; dict_type(report@)
println "cleared: "; dict_clear@(tally@); " count now "; dict_count(tally@)
println "and through the pointer dict: "; dict_count(pdict_get@(report@, "words"))
```

Two things worth noticing:

- **`dict_getdef(tally@, word$, 0) + 1` is the whole counter.** Without a default,
  a first sighting and a word counted zero times would read the same, and the
  tally would need a `dict_exists` in front of every increment.
- **`got@` is the same dictionary, not a copy.** A pointer dictionary stores the
  handle, so clearing `tally@` at the end empties what `report@` points at as
  well — which is why the last line reads `0` too.

## Notes

- **No free, no ownership.** Nothing here frees a dictionary, and a `pdict@` does
  not own the handles it stores. Every handle is released together when the run
  ends, which is why storing the same handle in two dictionaries is safe and why a
  long-lived program should reuse a dictionary rather than make one per iteration.
- **Keys are compared exactly**, byte for byte. Case matters, whitespace matters,
  and no Unicode normalization happens; `"Name"` and `"name"` are two keys.
- **Iteration is `dict_count` plus `dict_key$`.** There is no keys-array or
  values-array call, and no sorted view — insertion order is the only order.
- The one-line catalogue entry for each of these names is in
  [function-reference.md](../function-reference.md); this page is the reasoning
  behind them.
