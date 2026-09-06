# array — N-dimensional arrays, held as handles

`engine/libs/PhosphorArrayLib.pas` · 19 functions · always available

## What it is for

An array in Phosphor is an **object in the handle registry**, not a special kind of
variable. `dim@` (numbers), `sdim@` (strings) and `pdim@` (handles) mint one and
answer a handle; every other function here takes that handle as its first argument.
Because a handle is an ordinary value, an array can be passed to a function,
returned from one, stored inside another array, and freed when it is no longer
wanted — none of which a variable-shaped array could do. The bracket syntax
`a@[i]` and `a@[i] = v` is sugar the compiler turns into `arr_get` / `arr_set`
calls; there is no second, hidden array mechanism behind it.

Two design rules run through the whole library. **Indices are base 1, everywhere**
— which is why `lbound` exists at all and why it answers the constant `1`: it is
the project's base-1 rule written down where a loop can read it, not a question the
array is actually asked. And **element access is kind-agnostic**: there is one
`get` and one `set` implementation, registered under every typed name, because the
array already knows whether it holds numbers, strings or handles. The typed
spellings (`narr_get`, `sarr_get$`, `parr_get@`) exist so the *compiler* knows what
type the expression has; they do not dispatch. A consequence a caller should know:
`sarr_get$` on a numeric array is not an error — it answers the stored number
converted to a string, because the conversion happens at the call boundary, not
inside the array.

**Every failure here is a returned error, never a raised one** (decisions.md). A
handle that is not an array, an index outside its bounds, the wrong *number* of
indices, a dimension smaller than 1, a dimension product that overflows — each
comes back as a catchable runtime error whose message names the specific thing that
was wrong (`index 4 out of bounds 1..3 on dimension 1`, `array has 1 dimensions,
got 2 indices`). With no `on error goto` handler that message ends the program;
with one, it is a value the handler reads through `errmsg$()`.

Three things would otherwise surprise a reader. **A trailing `@` in these names is
part of the name, not a promise of a handle**: `narr_set@`, `sarr_set@` and
`parr_set@` answer *the value written*, so `narr_set@(a@, 1, 42)` is `42` and
assigning it to an `@` variable fails at run time. **Only numeric arrays are
multi-dimensional** — `dim@` takes one, two or three sizes, while `sdim@` and
`pdim@` take exactly one. And **a pointer array stores handles without owning
them**: freeing the outer array leaves everything it pointed at alive, to be
released by its own `arr_free` or by the end of the run.

## Functions

### Create

| function | what it answers |
| --- | --- |
| `dim@(n [, n [, n]]) → handle` | a new numeric array of that shape, every element `0`. One to three dimensions. Each size must be at least 1 (`array dimension must be >= 1`), and if the sizes multiply out past the integer range the array is **refused**, not silently shrunk — a capped dimension would make `ubound` report a size that was never allocated |
| `sdim@(n) → handle` | a one-dimensional string array, every element `""`. There is no two-dimensional form: `sdim@(2, 2)` is an unknown function, not a runtime error |
| `pdim@(n) → handle` | a one-dimensional handle array, every element the nil handle `0`. It holds handles; it does not own them |

### Ask an array about itself

| function | what it answers |
| --- | --- |
| `ndims(a@) → num` | how many dimensions it was created with. On anything that is not a live array handle: the error `not a valid array handle` |
| `lbound(a@, dim) → num` | `1`, always — arrays are base 1. The dimension argument is required and ignored, so `lbound(a@, 99)` is still `1`; use `ubound` when you want a dimension actually checked |
| `ubound(a@, dim) → num` | the size of that dimension, base-1 so also its highest legal index. A dimension below 1 or past `ndims` is the error `ubound: no such dimension`, not `0` |
| `arraysize(a@) → num` | the total number of elements, the product of all dimensions |
| `arraytype(a@) → num` | the element-kind code: `0` numeric, `1` string, `2` pointer |
| `arraytypename$(a@) → str` | the same answer as a word: `"numeric"`, `"string"` or `"pointer"` |

### Read and write elements

All of these take the array first and are base 1. An index is rounded to a whole
number (`a@[2.6]` is element 3), and one too large to be an index is rejected by
the bounds check rather than wrapped into a valid one.

| function | what it answers |
| --- | --- |
| `narr_set@(a@, i [, i [, i]], value) → num` | writes a numeric element and answers **the value written**, not the array — despite the `@` in the name. Wrong index count, out-of-range index or bad handle: the corresponding error, and nothing is written |
| `narr_get(a@, i [, i [, i]]) → num` | the element. On a string array it answers that string converted to a number, since the read is kind-agnostic |
| `sarr_set@(a@, i, value$) → str` | writes a string element, answers the string written. One index only |
| `sarr_get$(a@, i) → str` | the element as a string; `""` for a slot never written, which is a real answer and not a signal of failure |
| `parr_set@(a@, i, value@) → handle` | stores a handle in a handle array and answers the handle stored. The array does not take ownership of it |
| `parr_get@(a@, i) → handle` | the stored handle; the nil handle `0` for a slot never written. Nil is not an array, so passing it on gets `not a valid array handle` |

### Bracket sugar, and handles themselves

| function | what it answers |
| --- | --- |
| `arr_get(a@, i [, i [, i]]) → value` | what `a@[i]`, `a@[i, j]` and `a@[i, j, k]` compile to. One implementation for every element kind, reading the array's own kind |
| `arr_set(a@, i [, i [, i]], value) → value` | what `a@[i] = v` compiles to, for a numeric, string or handle value. It answers the value written, which is what makes `a@[i] += 1` work with the index expression evaluated exactly once |
| `arr_free(a@) → num` | releases the array and revokes its handle, answering `1`. Freeing the same handle twice is **the error `not a valid array handle`**, not a quiet `0` — ids are never reused within a run, so a stale handle stays detectably stale. Freeing is optional: every handle is released at the end of the run |
| `pointer@(n) → handle` | relabels a plain number as a handle value **without creating anything**. It exists so tests can prove that a library validates a handle instead of dereferencing it: `ndims(pointer@(305419896))` answers the error `not a valid array handle` on every platform, where following the address would be a crash |

## A worked example

A frequency table kept as two parallel arrays — labels in a string array, counts in
a numeric one — walked with the bounds the arrays themselves report rather than a
length the program has to remember.

```basic
rem A frequency table: labels in a string array, counts in a numeric one,
rem both walked with the bounds the arrays themselves report.

label@ = sdim@(4)
count@ = dim@(4)

label@[1] = "apple"
label@[2] = "pear"
label@[3] = "plum"
label@[4] = "fig"

rem a fresh numeric array is already all zeros, so these just add
count@[slot_of("pear")] += 3
count@[slot_of("fig")] += 1

println "indices run "; lbound(count@, 1); " to "; ubound(count@, 1)
for i = 1 to arraysize(count@)
  println label@[i]; " "; count@[i]
next
println arraytypename$(label@); " labels, "; ndims(count@); "-dimensional counts"
println "type code "; arraytype(count@); ", long form reads "; narr_get(count@, 2)

freed = arr_free(count@) + arr_free(label@)
println "freed "; freed

function slot_of(want$)
  for j = 1 to ubound(label@, 1)
    if sarr_get$(label@, j) = want$ then return j
  next
  return 0
endfunction
```

```
indices run 1 to 4
apple 0
pear 3
plum 0
fig 1
string labels, 1-dimensional counts
type code 0, long form reads 3
freed 2
```

Two things worth noticing:

- **`count@[slot_of("pear")] += 3` calls the helper once.** The compiler needs the
  handle and the index twice — to read the element and to write it back — and
  copies them on the stack instead of emitting the index expression a second time.
  An implementation that re-evaluated it would update a different element from the
  one it read, silently; `tests/suite/44_syntax_compound_arrays.bas` exists to keep
  that honest.
- **The loop asks the array, not the program.** `lbound` and `arraysize` mean the
  bounds cannot drift out of sync with the `sdim@(4)` above them, which is the
  practical reason `lbound` is a function answering a constant rather than a `1`
  the reader has to trust.

## Notes

- **19 names, 35 registry entries.** Most names are registered several times, once
  per arity or per value kind, and every one of those entries points at the same
  variadic implementation. `arr_set` alone accounts for nine of them: three index
  counts times three value kinds.
- **Handles are ids, not addresses.** A handle is a 1-based index into the engine's
  registry (`engine/PhosphorHandles.pas`), which is what lets every function here
  answer `not a valid array handle` for a fabricated or freed one instead of
  dereferencing whatever it was given — recoverable on Windows, a hard crash on
  Linux and Android.
- The language side of arrays — the bracket syntax, `a@[i] += 1`, and how an array
  handle moves through variables and function arguments — is described in
  [language-reference.md](../language-reference.md); the one-line catalogue entry
  for each name is in [function-reference.md](../function-reference.md).
