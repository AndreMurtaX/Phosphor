# json — build, parse, read and render JSON documents

`engine/libs/PhosphorJsonLib.pas` · 53 functions · always available

## What it is for

A program that talks to anything outside itself — an HTTP API, a config file, a
row of a database, another Phosphor program — needs a structured value it can
build piece by piece, hand around, and turn into text. This library is that
value: **a JSON document is a handle**, and every function here either makes
one, changes one, asks one a question, or renders one back to text.

Scalars are handles too. `json_null@`, `json_bool@`, `json_number@` and
`json_string@` each answer a full JSON value, which is why there is one
`json_push@` and one `json_set@` rather than a separate pair for every kind: a
number, a string, an object and an array all go into a container the same way.

Two ownership rules make that safe, and they are the thing to understand before
anything else. A value you **construct** (`json_object@`, `json_array@`,
`json_parse@`, `json_clone@`, `json_keys@`, the scalar constructors) owns its
tree. A value you **reach into** — `json_get@`, `json_item@`, `json_path@` —
*borrows*: the handle is a view onto a node the parent still owns, so it costs
nothing and stays in step with the parent. When the parent frees that node,
because the member was replaced or removed, every borrowed handle pointing at it
*or at anything inside it* is emptied first, and the next read through it is a
clean `this json handle is stale` runtime error rather than a crash. The other
side of the same rule: `json_set@`, `json_push@`, `json_setval@`, `json_pushval@`
and `json_merge@` store a **clone**, so the container owns its own copy and the
handle you passed in stays yours to change.

The rest is the house style. Array indices are **1-based**, like every other
positional argument in Phosphor (the reference implementation's JSON arrays were
0-based; this one is not). **Errors are returned, not thrown** — a bad handle, a
wrong shape, a missing member, an index past the end each become a catchable
runtime error, and no reader can ever abort the program: `json_value` and
`json_gets$` answer *something* for every node they are given, including nodes of
the wrong type. **A mutator answers the container**, not a success flag, so
writes chain and the document stays in hand. And **missing is not empty**: the
two-argument readers answer `0` or `""` for an absent member, while the
three-argument form answers the default you supply, so a program can tell the
difference when it matters.

## Functions

### Building, parsing, copying

| function | what it answers |
| --- | --- |
| `json_object@() → handle` | a new empty object, owning its own tree |
| `json_array@() → handle` | a new empty array |
| `json_parse@(text$) → handle` | the document `text$` describes. Malformed text is a runtime error (`invalid json: ...`); so is empty or whitespace-only input, rather than a live handle onto nothing |
| `json_null@() → handle` | a JSON null as a value in its own right |
| `json_bool@(n) → handle` | a JSON boolean; any non-zero `n` is true |
| `json_number@(n) → handle` | a JSON number — stored as an integer when `n` is whole and within int64 range, as a float otherwise |
| `json_string@(s$) → handle` | a JSON string holding exactly the bytes of `s$` |
| `json_clone@(v@) → handle` | a deep copy that owns itself. Changing the copy cannot reach the original, and vice versa |

### Objects — writing

Every one answers **the object it was given**, so writes chain and a failed write
is reported as an error rather than by a return value you have to test.
Non-objects are refused with `json value is not an object`.

| function | what it answers |
| --- | --- |
| `json_setn@(o@, key$, n) → handle` | `o@`, with `key$` set to a number. An existing member of that name is replaced, not duplicated |
| `json_sets@(o@, key$, s$) → handle` | `o@`, with `key$` set to a string, byte for byte |
| `json_setb@(o@, key$, n) → handle` | `o@`, with `key$` set to a boolean (`n <> 0`) |
| `json_setnull@(o@, key$) → handle` | `o@`, with `key$` present and null. A null key is still a key — `json_has` says so |
| `json_set@(o@, key$, v@) → handle` | `o@`, with `key$` set to a **clone** of `v@`. That is how a nested object or array is attached |
| `json_setval@(o@, key$, value) → handle` | the same, with the JSON kind chosen from the value's runtime kind (number, string, bool, handle). This is what a `{ }` literal compiles into; a handle that is not a JSON value is an error |
| `json_remove@(o@, key$) → handle` | `o@` without `key$`. A key that was not there is **not** an error — the answer is the same object either way, so removal is idempotent |
| `json_merge@(dst@, src@) → handle` | `dst@` with a clone of each of `src@`'s members copied in, overwriting on a name collision. `src@` is untouched. Either side not an object is an error |

### Objects — reading

| function | what it answers |
| --- | --- |
| `json_getn(o@, key$ [, default]) → num` | the member as a number. **Absent** → `default`, or `0` when none was given. **Present but off-type** is coerced, never defaulted: a numeric string reads as its number, any other string reads `0`, a boolean reads `1`/`0`, and null, an object or an array read `0` |
| `json_gets$(o@, key$ [, default$]) → str` | the member as a string. Absent → `default$` or `""`; a null member reads `""`; an object or array member reads as its own compact JSON text |
| `json_getb(o@, key$) → num` | `1` only when the member really is a JSON boolean and true. `0` for false, for absent, and for the *string* `"true"`. There is no default form: `0` covers both "false" and "not there" |
| `json_get@(o@, key$) → handle` | a borrowed handle onto the member. An absent key is an error (`no such json member`) — there is no handle that means "nothing", which is what `json_has` is for |
| `json_has(o@, key$) → num` | `1` when the key exists, `0` when it does not, whatever its value is |
| `json_count(o@) → num` | how many members the object holds. An array or a scalar answers `0` rather than an error, which reads exactly like an empty object; array length is `json_len` |
| `json_keys@(o@) → handle` | a **new, owned** array of the key names in insertion order. An empty object answers an empty array, not an error |

### Arrays — writing (1-based)

Like the object writers, each answers the array it was given; a non-array is
refused with `json value is not an array`.

| function | what it answers |
| --- | --- |
| `json_pushn@(a@, n) → handle` | `a@`, one number longer |
| `json_pushs@(a@, s$) → handle` | `a@`, one string longer, stored byte for byte |
| `json_pushb@(a@, n) → handle` | `a@`, one boolean longer |
| `json_pushnull@(a@) → handle` | `a@`, one null longer |
| `json_push@(a@, v@) → handle` | `a@` with a **clone** of `v@` appended — an object goes in whole |
| `json_pushval@(a@, value) → handle` | the same, with the kind taken from the value's runtime kind; what a `[ ]` literal compiles into |
| `json_removeat@(a@, i) → handle` | `a@` without element `i`, the rest shifted down. An index outside `1..json_len` removes nothing and is **not** an error |
| `json_pop@(a@) → handle` | `a@` without its last element. On an empty array it does nothing, and still answers the array |

### Arrays — reading (1-based)

| function | what it answers |
| --- | --- |
| `json_len(a@) → num` | the number of elements. Unlike `json_count`, a non-array here is an error, not `0` |
| `json_itemn(a@, i [, default]) → num` | element `i` as a number, coerced the same way `json_getn` coerces. Out of range: `default` when the third argument is given, otherwise an error naming the bounds — `json array index 5 out of bounds 1..1` |
| `json_items$(a@, i [, default$]) → str` | element `i` as a string; null reads `""`, an object or array reads as compact JSON text. Out of range: `default$`, or the same bounds error |
| `json_itemb(a@, i) → num` | `1` only when element `i` is a boolean and true. `0` for false, for an off-type element **and** for an index past the end — this one never errors and takes no default |
| `json_item@(a@, i) → handle` | a borrowed handle onto element `i`. Out of range is an error (`json array index out of bounds`) |

### Type introspection and scalar reads

| function | what it answers |
| --- | --- |
| `json_isobj(v@) → num` | `1` when `v@` is an object, `0` for every other kind |
| `json_isarr(v@) → num` | `1` when it is an array |
| `json_isnull(v@) → num` | `1` when it is a JSON null — which is a value, distinct from an absent member |
| `json_isbool(v@) → num` | `1` when it is a boolean, whether true or false |
| `json_isnum(v@) → num` | `1` when it is a number |
| `json_isstr(v@) → num` | `1` when it is a string |
| `json_type(v@) → num` | the kind as a code: `1` number, `2` string, `3` boolean, `4` null, `5` array, `6` object (`0` unknown). Useful for comparing two values' kinds; to *name* one, use `json_typename$` |
| `json_typename$(v@) → str` | `"object"`, `"array"`, `"number"`, `"string"`, `"boolean"` or `"null"`; `"unknown"` for a node of no known kind |
| `json_value(v@) → num` | any node at all as a number, without ever raising: a number is itself, a boolean `1`/`0`, a numeric string its value, and a non-numeric string, null, object or array `0` |
| `json_value$(v@) → str` | any node as a string: a null reads `""`, an object or array its compact JSON text, everything else its own text |

### Dotted paths

A path walks nested **objects** with `.` — `"user.address.city"` — which is the
whole point: `json_get@` would need one borrowed handle per level. A segment can
only name an object member; a path cannot index into an array.

| function | what it answers |
| --- | --- |
| `json_paths$(root@, path$ [, default$]) → str` | the string at `path$`. A path that does not resolve — a missing segment, or a segment under a non-object — answers `default$`, or `""` when none was given. Never an error |
| `json_pathn(root@, path$ [, default]) → num` | the number at `path$`, coerced like `json_getn`; unresolved answers `default` or `0` |
| `json_pathb(root@, path$) → num` | `1` only when the path resolves to a boolean that is true; `0` for false, off-type and unresolved alike |
| `json_path@(root@, path$) → handle` | a borrowed handle at `path$`. Unresolved is an error (`no such json path`), for the same reason `json_get@` errors |

### Rendering and identity

| function | what it answers |
| --- | --- |
| `json_stringify$(v@) → str` | the value as compact one-line JSON text — the wire form. Objects carry no padding (`{"s":"txt","n":42}`); array elements are separated by `, ` |
| `json_pretty$(v@ [, indent]) → str` | the same document indented over several lines, `indent` spaces per level (default `2`). This is the readable rendering; `json_stringify$` is the one that goes over a wire |
| `pnttonum(v@) → num` | the integer a handle carries — its registry id, which is non-zero for every live JSON value. `assert_true(pnttonum(x@))` is the idiom for "this really answered a handle". It is registered here for historical reasons but works on any Phosphor handle, and answers `0` for a null pointer |

## A worked example

A service registry arrives as text, is read with defaults because not every entry
carries every field, and is summarised into a fresh document. Note that a quote
inside a Phosphor string literal is written doubled.

```basic
rem Parse a registry, then build a report out of it.
doc$ = "{""services"":["
doc$ = doc$ + "{""name"":""orders"",""port"":8080,""tags"":[""prod"",""eu""]},"
doc$ = doc$ + "{""name"":""billing"",""tags"":[""dev""]}"
doc$ = doc$ + "]}"

root@ = json_parse@(doc$)
list@ = json_get@(root@, "services")     rem borrowed: root@ still owns it

report@ = json_array@()
for i = 1 to json_len(list@)
  svc@ = json_item@(list@, i)
  row@ = json_object@()
  json_sets@(row@, "name", json_gets$(svc@, "name", "?"))
  json_setn@(row@, "port", json_getn(svc@, "port", 80))   rem billing has none
  json_setb@(row@, "prod", 0)
  tags@ = json_get@(svc@, "tags")
  for t = 1 to json_len(tags@)
    if json_items$(tags@, t) = "prod" then json_setb@(row@, "prod", 1)
  next
  json_push@(report@, row@)               rem a clone of row@ goes in
next

println json_stringify$(report@)
println "first row has " + str$(json_count(json_item@(report@, 1))) + " keys"
```

It prints
`[{"name":"orders","port":8080,"prod":true}, {"name":"billing","port":80,"prod":false}]`
and then `first row has 3 keys`. Two things worth noticing:

- **The default is doing real work.** `billing` has no `port`, and
  `json_getn(svc@, "port", 80)` is the only place in the program that decides
  what a missing port means. Without the third argument it would have read `0`,
  which is a port number.
- **`json_push@` copied.** `row@` is rebuilt on every pass of the loop and the
  report is unaffected, because the array holds a clone rather than the handle.
  Had the array borrowed instead, every row would be the last row.

## Notes

**JSON literals are language, not library.** A `[` or `{` at a value position
builds a document inline — `person@ = {"name": "John", "age": 30}` and
`matrix@ = [[1, 2], [3, 4]]` — with any expression allowed as an element, and
`true` / `false` / `null` spelled as themselves. The compiler emits
`json_array@` / `json_object@` and then one `json_pushval@`, `json_pushnull@`,
`json_setval@` or `json_setnull@` per element, which is why those four appear in
the table above even though a program rarely calls them by name. The syntax
itself is described in [language-reference.md](../language-reference.md).

**The text is byte-exact.** Phosphor renders its own JSON rather than using
fpjson's serializer, which re-encoded every byte `>= $80` — a five-byte UTF-8
string came back as seven, so a document looked perfect through `json_gets$` and
was mojibake in the file it was written to. Values now survive the full round
trip, text and tree alike. One limit is stated rather than hidden: fpjson keeps
member *names* in a hash that goes through the system code page, so writing a
**non-ASCII key** out to text and reading it back does not round trip where that
code page is not UTF-8. Setting and getting such a key through the same call is
symmetric everywhere, and non-ASCII *values* are unaffected.

**Prefer `json_get@` to a path for an unusual key.** The direct member lookups
scan names byte for byte, but the dotted walk behind `json_paths$` and its
siblings still uses fpjson's own name lookup, which the unit header records as
missing a byte-exactly stored non-ASCII name on some platforms.

**A borrowed handle is only as good as its parent.** Keep a borrow for as long
as you like while the parent is untouched, but do not hold one across a write
that replaces or removes what it points at — take a `json_clone@` instead if the
value has to outlive its slot. The library will tell you rather than crash, but a
stale-handle error at run time is a worse answer than a copy taken up front.
