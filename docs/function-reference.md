# Phosphor BASIC — built-in function reference

A complete catalog of every built-in function Phosphor ships, generated from the
registry (the source of truth: the `Reg.Add('name:signature', @fn)` lines in each
`engine/libs/Phosphor*Lib.pas` and `host/packages/Phosphor*Lib.pas` unit) and
verified by running functions through `bin/phosphor.exe`.

## What a built-in is

A built-in is a function a library registers with the engine through the
`:`-signature registry: `Reg.Add('name:sigcodes', @fn)`. The engine looks a call
up by its name **and** the kinds of its arguments, so one name can carry several
overloads (e.g. `mid$` with 2 or 3 arguments). VM-aware built-ins use `Reg.AddHost`
and additionally receive the executing VM.

### Signature and type conventions

- **Argument type codes** (the part after the `:`): `$` string, `n` number
  (an `int%` or a float — `int%` widens into it), `%` an exact `int%` slot that
  does not widen, `@` handle, `?` bool. An empty signature (`name:`) means no
  arguments.
- **Return type is read from the NAME suffix**, by Phosphor convention: a name
  ending `$` returns a **string**, a name ending `@` returns a **handle**;
  otherwise it returns a **number** (an `int%` or a float). This was confirmed by
  running representatives of each: `mid$` → string, `dim@` → handle, `len` →
  number.
- **Base-1 everywhere.** Every index — strings (`mid$`, `instr`), arrays, JSON
  arrays, string lists, SQLite parameters and columns — starts at 1. A search that
  finds nothing answers `0`, not `-1` (`instr`, `strings_indexof`).
- **`@` handles.** Arrays, dictionaries, JSON nodes, config files, string lists,
  byte buffers, RAG indexes, zip archives, HTTP clients and SQLite databases are
  all handle objects. A handle is validated before use, so a fabricated or stale
  handle is **refused** (answered with `0`/`""`), never dereferenced.
- **Errors are values, not exceptions.** Inside the engine, a failing built-in
  returns an empty/zero answer and (where the library keeps one) sets a last-error
  code you read back — `ioerror()`, `valcode()`, `strerror()`, `rag_error()`,
  `http_error()`, `sqlite_error()`, `err()`. A program branches on the value
  instead of being aborted.

### Engine built-ins vs opt-in packages

The **engine built-ins are always present** — the sixteen libraries below register
themselves when a `TPhosphorEngine` is created, so any host (the console
`phosphor`, the embedding host, the test runner) has them.

The **six packages are opt-in**: a host must call the package's register function.
The console `phosphor` host registers **CRT** (so terminal control works out of the
box); the test and embedding hosts register the rest (Base64, Zip, Gzip, Http,
Sqlite). Http and Sqlite additionally need an external runtime (OpenSSL, SQLite)
and are gated on it — the package still compiles everywhere, and reports
availability (`sqlite_available()`) rather than crashing when the library is
absent.

---

# Engine libraries (always available)

## Str — strings (64 functions)

Case, length, codepoint-aware slicing, trimming, search, replace, radix and
number conversion, padding/justification, word and line splitting, predicates and
in-place edits. Character operations count **Unicode codepoints, not bytes**.
`instr`/`instrrev` are 1-based and answer 0 when absent.

**Case**

| function | description |
| --- | --- |
| `ucase$(s$) → str` | uppercase, ASCII `a`–`z` only |
| `lcase$(s$) → str` | lowercase, ASCII `A`–`Z` only |
| `proper$(s$) → str` | title-case: capitalize the first letter of each word |
| `swapcase$(s$) → str` | swap the case of every ASCII letter |
| `aucase$(s$) → str` | Unicode-aware uppercase (whole codepoint range) |
| `alcase$(s$) → str` | Unicode-aware lowercase (whole codepoint range) |

**Length and slicing** (all by codepoint, base-1)

| function | description |
| --- | --- |
| `len(s$) → num` | number of codepoints — **not** bytes; see the byte family below |
| `left$(s$, n) → str` | first `n` codepoints |
| `right$(s$, n) → str` | last `n` codepoints |
| `mid$(s$, start [, len]) → str` | substring from 1-based `start`; to the end when `len` is omitted |
| `reverse$(s$) → str` | reverse the codepoints |
| `strchar$(s$, n) → str` | the `n`-th character (the helper behind `s$[[n]]`) |
| `strline$(s$, n) → str` | the `n`-th line (the helper behind `s$[n]`) |
| `line$(s$, n) → str` | the `n`-th line (1-based), splitting on newlines |

**Trim, pad and justify**

| function | description |
| --- | --- |
| `trim$(s$) → str` | strip leading and trailing whitespace |
| `ltrim$(s$) → str` | strip leading whitespace |
| `rtrim$(s$) → str` | strip trailing whitespace |
| `space$(n) → str` | `n` spaces |
| `string$(n, code) → str` | `n` copies of the character with code `code` |
| `mulstring$(s$, n) → str` | `s$` repeated `n` times |
| `ltab$(s$, width) → str` | trim `s$`, then right-justify to `width` (pad on the left) |
| `rtab$(s$, width) → str` | trim `s$`, then left-justify to `width` (pad on the right) |
| `lfill$(s$, width, code) → str` | left-pad `s$` to `width` with character `code` |
| `rfill$(s$, width, code) → str` | right-pad `s$` to `width` with character `code` |
| `center$(s$, width [, code]) → str` | center `s$` in `width`; pad with spaces, or character `code` |

**Search and compare**

| function | description |
| --- | --- |
| `instr(hay$, needle$ [, start]) → num` | 1-based position of `needle$`, 0 if absent; optional start |
| `instrrev(hay$, needle$) → num` | 1-based position of the last occurrence, 0 if absent |
| `countstr(hay$, needle$) → num` | count of (non-overlapping) occurrences |
| `containsstr(hay$, needle$) → num` | 1 if present, else 0 |
| `containstext(hay$, needle$) → num` | as `containsstr`, case-insensitive |
| `startsstr(s$, prefix$) → num` | 1 if `s$` starts with `prefix$` |
| `endsstr(s$, suffix$) → num` | 1 if `s$` ends with `suffix$` |
| `startstext(s$, prefix$) → num` | as `startsstr`, case-insensitive |
| `endstext(s$, suffix$) → num` | as `endsstr`, case-insensitive |
| `wordcount(s$, sep$) → num` | number of fields when split on `sep$` |
| `word$(s$, n, sep$) → str` | the `n`-th field (1-based) when split on `sep$` |
| `count(s$) → num` | number of lines in `s$` (0 for the empty string) |
| `strcmp(a$, b$) → num` | sign (−1/0/1) of a case-sensitive comparison |
| `strcmpi(a$, b$) → num` | sign of a case-insensitive comparison |

**Replace and edit**

| function | description |
| --- | --- |
| `replacestr$(s$, from$, to$) → str` | replace every `from$` with `to$` (case-sensitive) |
| `replacetext$(s$, from$, to$) → str` | replace every `from$` with `to$` (case-insensitive) |
| `insert$(s$, ins$, pos) → str` | insert `ins$` before the 1-based `pos` |
| `delete$(s$, pos, count) → str` | remove `count` characters starting at `pos` |
| `stuffstring$(s$, start, len, repl$) → str` | replace the `len` characters at `start` with `repl$` |

**Radix and number conversion**

| function | description |
| --- | --- |
| `asc(s$) → num` | the codepoint of the first character (0 for the empty string) |
| `chr$(code) → str` | the character (UTF-8) for codepoint `code` |
| `hex$(n) → str` | hexadecimal text |
| `bin$(n) → str` | binary text |
| `oct$(n) → str` | octal text |
| `val(s$) → num` | parse `s$` to a number; **0 unless the whole trimmed string is numeric** |
| `valcode() → num` | 1-based position where the last `val` stopped; 0 when it was fully numeric |
| `stri$(n) → str` | number → string, locale-invariant (`.` decimal) |
| `str$(n) → str` | alias of `stri$` |

**Predicates** (1 when true and the string is non-empty, else 0)

| function | description |
| --- | --- |
| `isnumeric(s$) → num` | the whole string parses as a number |
| `isalpha(s$) → num` | every character is an ASCII letter |
| `isdigits(s$) → num` | every character is a digit |
| `isalnum(s$) → num` | every character is a letter or digit |
| `isspace(s$) → num` | every character is whitespace |
| `islower(s$) → num` | has a lowercase letter and no uppercase |
| `isupper(s$) → num` | has an uppercase letter and no lowercase |

### Bytes

Everything above counts UTF-8 **codepoints**, and `chr$` *encodes* one (`chr$(200)` is
two bytes). These four work in the byte domain, so binary data can be addressed
directly. A `string$` carries all 256 byte values intact.

| function | description |
| --- | --- |
| `bytelen(s$) → num` | number of **bytes** (`len` counts codepoints) |
| `byteat(s$, i) → num` | value `0..255` of byte `i`, 1-based; error outside the string |
| `bytestr$(v) → str` | a **one-byte** string holding `v` — the byte constructor `chr$` cannot be |
| `bytemid$(s$, i, n) → str` | `n` bytes starting at byte `i`, clamped, never raises |

## Num — numeric (35 functions)

Thin wrappers over FPC's `Math`. Every argument is the numeric family; `sqr` is
**square root** (per decisions.md); `round` rounds to nearest with **ties to even**
(`round(2.5)` = 2, `round(3.5)` = 4).

| function | description |
| --- | --- |
| `abs(n) → num` | absolute value |
| `sqr(n) → num` | square **root** (errors on a negative argument) |
| `sgn(n) → num` | sign: −1, 0, or 1 |
| `min(a, b) → num` | the smaller of two |
| `max(a, b) → num` | the larger of two |
| `round(n) → num` | nearest integer, ties to even |
| `fix(n) → num` | truncate toward zero |
| `cint(n) → num` | truncate toward zero (same as `fix`) |
| `frac(n) → num` | fractional part |
| `int(n) → num` | floor (largest integer ≤ n) |
| `log10(n) → num` | base-10 logarithm |
| `log2(n) → num` | base-2 logarithm |
| `ln(n) → num` | natural logarithm |
| `exp(n) → num` | e raised to `n` |
| `sin/cos/tan(n) → num` | trigonometric functions (radians) |
| `asin/acos/atan(n) → num` | inverse trigonometric functions |
| `atan2(y, x) → num` | angle of the vector (x, y) |
| `degtorad(n) → num` | degrees → radians |
| `radtodeg(n) → num` | radians → degrees |
| `sinh/cosh/tanh(n) → num` | hyperbolic functions |
| `asinh/acosh/atanh(n) → num` | inverse hyperbolic functions |
| `cmpval(a, b) → num` | compare as numbers: −1, 0, or 1 |
| `randomize() → num` | seed the random generator (returns 0) |
| `rnd(n) → num` | a random integer in `0 .. n-1` |
| `rnd() → num` | a random float in `[0, 1)` |
| `isnan(n) → num` | 1 if `n` is NaN |
| `isinfinite(n) → num` | 1 if `n` is infinite |

## Array — N-dimensional arrays (35 registry entries)

Arrays are handle objects, 1-based, up to 3 dimensions in the bracket sugar today.
Three element kinds: numeric (`dim@`), string (`sdim@`), handle/pointer (`pdim@`).
Element get/set is kind-agnostic — the array knows its own kind. Out-of-bounds and
fabricated handles are returned as errors.

**Create and inspect**

| function | description |
| --- | --- |
| `dim@(n [, n [, n]]) → handle` | a numeric array with the given dimension sizes |
| `sdim@(n) → handle` | a string array |
| `pdim@(n) → handle` | a handle/pointer array |
| `ndims(a@) → num` | number of dimensions |
| `lbound(a@, dim) → num` | lower bound of a dimension — always 1 |
| `ubound(a@, dim) → num` | upper bound (size) of a dimension |
| `arraysize(a@) → num` | total element count |
| `arraytype(a@) → num` | element-kind code: 0 numeric, 1 string, 2 pointer |
| `arraytypename$(a@) → str` | `"numeric"`, `"string"`, or `"pointer"` |
| `arr_free(a@) → num` | free the array handle (1 on success) |

**Typed get/set** (all 1-based; each is one impl under a typed name)

| function | description |
| --- | --- |
| `narr_set@(a@, i.., value) → handle` | set a numeric element (1–3 indices) |
| `narr_get(a@, i..) → num` | read a numeric element (1–3 indices) |
| `sarr_set@(a@, i, value$) → handle` | set a string element |
| `sarr_get$(a@, i) → str` | read a string element |
| `parr_set@(a@, i, value@) → handle` | set a handle element |
| `parr_get@(a@, i) → handle` | read a handle element |

**Bracket sugar** — the `a@[i, ...]` and `a@[i] = v` syntax compiles to these
variadic get/set forms (`arr_get` with 1–3 indices; `arr_set` with 1–3 indices ×
numeric/string/handle value). Both read the array's own kind.

| function | description |
| --- | --- |
| `arr_get(a@, i..) → value` | element read for `a@[i, ...]` (1–3 indices) |
| `arr_set(a@, i.., value) → value` | element write for `a@[i, ...] = value` |
| `pointer@(n) → handle` | fabricate a raw handle from an integer (for negative/validation tests) |

## Dict — string-keyed maps (20 functions)

Maps keyed by string, as handles, in insertion order. Three value kinds: numeric
(`dict@`), string (`sdict@`), handle (`pdict@`). Get/set is kind-agnostic.

| function | description |
| --- | --- |
| `dict@() → handle` | a new numeric-valued dictionary |
| `sdict@() → handle` | a new string-valued dictionary |
| `pdict@() → handle` | a new handle-valued dictionary |
| `dict_set@(d@, key$, value) → handle` | set a numeric value; returns the dict |
| `sdict_set@(d@, key$, value$) → handle` | set a string value |
| `pdict_set@(d@, key$, value@) → handle` | set a handle value |
| `dict_get(d@, key$) → num` | numeric value, or 0 if the key is absent |
| `sdict_get$(d@, key$) → str` | string value, or `""` if absent |
| `pdict_get@(d@, key$) → handle` | handle value, or 0 if absent |
| `dict_getdef(d@, key$, default) → num` | numeric value, or `default` if absent |
| `sdict_getdef$(d@, key$, default$) → str` | string value, or `default$` if absent |
| `pdict_getdef@(d@, key$, default@) → handle` | handle value, or `default@` if absent |
| `dict_count(d@) → num` | number of entries |
| `dict_haskey(d@, key$) → num` | 1 if the key exists |
| `dict_exists(d@, key$) → num` | alias of `dict_haskey` |
| `dict_remove(d@, key$) → num` | remove a key (1 on success) |
| `dict_clear@(d@) → handle` | remove all entries |
| `dict_key$(d@, n) → str` | the key at 1-based insertion position `n` |
| `dict_type(d@) → num` | value-kind code: 0 numeric, 1 string, 2 pointer |
| `dict_typename$(d@) → str` | `"numeric"`, `"string"`, or `"pointer"` |

## Json — JSON values (66 registry entries)

**Bytes.** A JSON string value carries bytes: what goes in comes out, and what
`json_stringify$` writes parses back identical. Phosphor renders its own JSON text
rather than using fpjson's serializer, which re-encodes every byte `>= 0x80`.

**One limit, on KEYS only.** fpjson keeps member *names* in a hash whose key type
passes through the system code page. Setting and getting by the same non-ASCII key is
symmetric and works everywhere; writing such a key out to text and reading it back
does not round trip where the system code page is not UTF-8. Values are unaffected.

A JSON value is a handle over an fpjson node. Constructors own their tree;
`json_get@`/`json_item@`/`json_path@` hand back non-owning views onto a child.
Array access is **1-based**. Object readers with a 3rd argument return it as a
default when a member is absent.

**Construct and parse**

| function | description |
| --- | --- |
| `json_object@() → handle` | a new empty object |
| `json_array@() → handle` | a new empty array |
| `json_parse@(text$) → handle` | parse JSON text (error on malformed input) |
| `json_null@() → handle` | a JSON null scalar |
| `json_bool@(n) → handle` | a JSON boolean scalar |
| `json_number@(n) → handle` | a JSON number scalar |
| `json_string@(s$) → handle` | a JSON string scalar |
| `json_clone@(v@) → handle` | a deep copy |

**Object mutation and read**

| function | description |
| --- | --- |
| `json_setn@(o@, key$, n) → handle` | set a number member |
| `json_sets@(o@, key$, s$) → handle` | set a string member |
| `json_setb@(o@, key$, n) → handle` | set a boolean member |
| `json_setnull@(o@, key$) → handle` | set a null member |
| `json_set@(o@, key$, v@) → handle` | set a member to a (cloned) handle value |
| `json_setval@(o@, key$, value) → handle` | set a member, kind from the value (num/str/bool/handle) |
| `json_remove@(o@, key$) → handle` | delete a member |
| `json_getn(o@, key$ [, default]) → num` | number member; optional default when absent |
| `json_gets$(o@, key$ [, default$]) → str` | string member; optional default |
| `json_getb(o@, key$) → num` | boolean member (1/0) |
| `json_get@(o@, key$) → handle` | a (borrowed) handle onto a member (error if absent) |
| `json_has(o@, key$) → num` | 1 if the member exists |
| `json_count(o@) → num` | number of members (0 for a non-object) |
| `json_keys@(o@) → handle` | a new array of the object's key names |
| `json_merge@(dst@, src@) → handle` | copy `src`'s members into `dst` |

**Array mutation and read** (1-based)

| function | description |
| --- | --- |
| `json_pushn@(a@, n) → handle` | append a number |
| `json_pushs@(a@, s$) → handle` | append a string |
| `json_pushb@(a@, n) → handle` | append a boolean |
| `json_pushnull@(a@) → handle` | append a null |
| `json_push@(a@, v@) → handle` | append a (cloned) handle value |
| `json_pushval@(a@, value) → handle` | append, kind from the value (num/str/bool/handle) |
| `json_len(a@) → num` | array length |
| `json_itemn(a@, i [, default]) → num` | number at 1-based `i`; optional default past the end |
| `json_items$(a@, i [, default$]) → str` | string at `i`; optional default |
| `json_itemb(a@, i) → num` | boolean at `i` |
| `json_item@(a@, i) → handle` | a (borrowed) handle onto element `i` |
| `json_removeat@(a@, i) → handle` | delete element `i` |
| `json_pop@(a@) → handle` | delete the last element |

**Type introspection**

| function | description |
| --- | --- |
| `json_isobj(v@) → num` | 1 if an object |
| `json_isarr(v@) → num` | 1 if an array |
| `json_isnull(v@) → num` | 1 if null |
| `json_isbool(v@) → num` | 1 if a boolean |
| `json_isnum(v@) → num` | 1 if a number |
| `json_isstr(v@) → num` | 1 if a string |
| `json_type(v@) → num` | the fpjson type code |
| `json_typename$(v@) → str` | `"object"`/`"array"`/`"number"`/`"string"`/`"boolean"`/`"null"` |
| `json_value(v@) → num` | a scalar's numeric value |
| `json_value$(v@) → str` | a scalar's string value |

**Dotted paths, serialize, id**

| function | description |
| --- | --- |
| `json_paths$(root@, "a.b" [, default$]) → str` | string at a dotted path; optional default |
| `json_pathn(root@, "a.b" [, default]) → num` | number at a dotted path; optional default |
| `json_pathb(root@, "a.b") → num` | boolean at a dotted path |
| `json_path@(root@, "a.b") → handle` | a (borrowed) handle at a dotted path (error if absent) |
| `json_stringify$(v@) → str` | compact JSON text |
| `json_pretty$(v@ [, indent]) → str` | indented JSON text (default indent, or `indent` spaces) |
| `pnttonum(v@) → num` | the handle's integer id |

## DateTime — dates and times (66 functions)

A date is a plain number (a `TDateTime`: days since 1899-12-30, time in the
fraction). Thin wrappers over the RTL's `DateUtils`. String rendering/parsing is
fixed **ISO 8601** (`yyyy-mm-dd`, `hh:nn:ss`), so text round-trips identically on
every machine. `now`/`today`/`tomorrow`/`yesterday` read the clock.

**The clock (no arguments)**

| function | description |
| --- | --- |
| `now() → num` / `gettime() → num` | current date and time |
| `today() → num` / `date() → num` | current date (midnight) |
| `time() → num` | current time of day |
| `tomorrow() → num` | today + 1 day |
| `yesterday() → num` | today − 1 day |
| `istoday(d) → num` | 1 if `d` falls today |

**Decompose a date**

| function | description |
| --- | --- |
| `yearof(d) → num` | year |
| `monthof(d) → num` / `monthoftheyear(d) → num` | month (1–12) |
| `dayof(d) → num` / `dayofthemonth(d) → num` | day of the month |
| `dayoftheyear(d) → num` | day within the year (1–366) |
| `dayofweek(d) → num` | day of week, Sunday = 1 |
| `dayoftheweek(d) → num` | day of week, ISO Monday = 1 |
| `hourof(d) → num` | hour (0–23) |
| `minuteof(d) → num` | minute |
| `secondof(d) → num` | second |
| `millisecondof(d) → num` | millisecond |
| `isam(d) → num` | 1 if before noon |
| `ispm(d) → num` | 1 if noon or later |
| `issameday(a, b) → num` | 1 if both fall on the same day |

**Weeks, leap years, month lengths**

| function | description |
| --- | --- |
| `weekoftheyear(d) → num` / `weekof(d) → num` | ISO week number |
| `weekofthemonth(d) → num` | week within the month |
| `weeksinayear(year) → num` | ISO weeks in a year (by year number) |
| `weeksinyear(d) → num` | ISO weeks in the year of a date |
| `isinleapyear(d) → num` | 1 if the date is in a leap year |
| `daysinayear(year) → num` | days in a year (by year number) |
| `daysinyear(d) → num` | days in the year of a date |
| `daysinmonth(d) → num` | days in the month of a date |
| `daysinamonth(year, month) → num` | days in a given month |

**Increment** (return a new date)

| function | description |
| --- | --- |
| `incday(d, n) → num` | add `n` days |
| `incweek(d, n) → num` | add `n` weeks |
| `incyear(d, n) → num` | add `n` years (clamps Feb 29 to the 28th) |
| `inchour(d, n) → num` | add `n` hours |
| `incminute(d, n) → num` | add `n` minutes |
| `incsecond(d, n) → num` | add `n` seconds |
| `incmillisecond(d, n) → num` | add `n` milliseconds |

**Distances** — `*between` are whole units; `*span` are fractional units.

| function | description |
| --- | --- |
| `daysbetween(a, b) → num` | whole days apart |
| `weeksbetween(a, b) → num` | whole weeks apart |
| `monthsbetween(a, b) → num` | whole months apart |
| `yearsbetween(a, b) → num` | whole years apart |
| `hoursbetween(a, b) → num` | whole hours apart |
| `minutesbetween(a, b) → num` | whole minutes apart |
| `secondsbetween(a, b) → num` | whole seconds apart |
| `millisecondsbetween(a, b) → num` | whole milliseconds apart |
| `dayspan(a, b) → num` | fractional days apart |
| `weekspan/monthspan/yearspan(a, b) → num` | fractional weeks/months/years apart |
| `hourspan/minutespan/secondspan/millisecondspan(a, b) → num` | fractional smaller-unit distances |

**Render and parse** (ISO 8601)

| function | description |
| --- | --- |
| `datetostr$(d) → str` | date as `yyyy-mm-dd` |
| `timetostr$(d) → str` | time as `hh:nn:ss` |
| `datetimetostr$(d) → str` | date and time |
| `date$() → str` | today as `yyyy-mm-dd` |
| `time$() → str` | now, time only |
| `datetime$() → str` | now, date and time |
| `formatdatetime$(fmt$, d) → str` | format `d` with an explicit pattern (ISO settings) |
| `strtodate(s$) → num` | parse a date string (error if invalid) |
| `strtotime(s$) → num` | parse a time string |
| `strtodatetime(s$) → num` | parse a date-time string |

## StrList — string lists (70 registry entries)

A growable list of strings as a handle, **1-based**, with the `TStrings` property
surface Plan9Basic leaned on: delimiters, name/value machinery, case/duplicates
policy, line-break and BOM controls, encoding names, change-handler names, batched
updates, and file/stream round-trips. `strings_indexof`/`strings_find` answer 0
when absent. The stream pair moves a list through the same byte-buffer handle
`file_readallbytes@` hands out.

**Construct and basic ops**

| function | description |
| --- | --- |
| `strings@() → handle` | a new empty list |
| `strings_count(l@) → num` | number of items |
| `strings_add(l@, s$) → num` | append (or, if sorted, insert in order); returns the 1-based index it took |
| `strings_append(l@, s$) → num` | append; returns the new count |
| `strings_strings$(l@, i) → str` | the item at 1-based `i` |
| `strings_strings(l@, i, s$) → num` | set the item at `i` |
| `strings_indexof(l@, s$) → num` | 1-based position (linear), 0 if absent |
| `strings_find(l@, s$) → num` | 1-based position via binary search (needs a sorted list), 0 if absent |
| `strings_insert(l@, i, s$) → num` | insert `s$` at `i` |
| `strings_delete(l@, i) → num` | delete the item at `i` |
| `strings_exchange(l@, a, b) → num` | swap two items |
| `strings_move(l@, from, to) → num` | move an item |
| `strings_sort(l@) → num` | sort ascending |
| `strings_clear(l@) → num` | remove all items |
| `strings_free(l@) → num` | free the handle (0 for an already-invalid handle; never raises) |
| `strings_equals(a@, b@) → num` | 1 if two lists have identical items |
| `strings_capacity(l@) → num` | allocated slack (backing length) |
| `strings_capacity(l@, n) → num` | grow the backing array (never below the live count) |
| `strings_sorted(l@) → num` | whether the sorted flag is on |
| `strings_sorted(l@, on) → num` | set the sorted flag (orders existing items when enabled) |

**Text and delimited forms** (`_$` reads, the setter form writes)

| function | description |
| --- | --- |
| `strings_text(l@, s$) → num` | replace items by splitting on newlines |
| `strings_text$(l@) → str` | items joined by `LineBreak` (honours `TrailingLineBreak`) |
| `strings_commatext(l@, s$) → num` | replace items by splitting on commas |
| `strings_commatext$(l@) → str` | items joined by commas |
| `strings_delimitedtext(l@, s$) → num` | replace items using `Delimiter`/`QuoteChar` |
| `strings_delimitedtext$(l@) → str` | items joined using `Delimiter`/`QuoteChar` |
| `strings_delimiter(l@, c$) → num` / `strings_delimiter$(l@) → str` | the delimiter character (set / get) |
| `strings_quotechar(l@, c$) → num` / `strings_quotechar$(l@) → str` | the quote character (set / get) |
| `strings_strictdelimiter(l@, on) → num` / `strings_strictdelimiter(l@) → num` | strict-delimiter flag (set / get) |

**Name/value machinery** (`name=value` lines)

| function | description |
| --- | --- |
| `strings_values$(l@, name$) → str` | the value for a name |
| `strings_values(l@, name$, value$) → num` | set the value for a name |
| `strings_valuefromindex$(l@, i) → str` | the value at 1-based index `i` |
| `strings_valuefromindex(l@, i, value$) → num` | set the value at index `i` |
| `strings_names$(l@, i) → str` | the name at index `i` |
| `strings_keynames$(l@, i) → str` | the name at index `i` (alias spelling) |
| `strings_indexofname(l@, name$) → num` | 1-based index of a name, 0 if absent |
| `strings_namevalueseparator$(l@) → str` / `strings_namevalueseparator(l@, c$) → num` | the separator (get / set) |

**Policy, line breaks, encoding, handlers, updates**

| function | description |
| --- | --- |
| `strings_casesensitive(l@, on) → num` / `strings_casesensitive(l@) → num` | case-sensitivity flag (set / get) |
| `strings_duplicates(l@, policy$) → num` / `strings_duplicates$(l@) → str` | duplicates policy `ignore`/`accept`/`error` (set / get) |
| `strings_linebreak(l@, s$) → num` / `strings_linebreak$(l@) → str` | line-break string (set / get) |
| `strings_trailinglinebreak(l@, on) → num` / `strings_trailinglinebreak(l@) → num` | trailing-line-break flag (set / get) |
| `strings_writebom(l@, on) → num` / `strings_writebom(l@) → num` | write-BOM flag (set / get) |
| `strings_encoding$(l@) → str` | the established (or default) encoding name |
| `strings_defaultencoding$(l@) → str` / `strings_defaultencoding(l@, s$) → num` | default encoding name (get / set) |
| `strings_onchange(l@, name$) → num` / `strings_onchange$(l@) → str` | onchange handler **name** (set / get) |
| `strings_onchanging(l@, name$) → num` / `strings_onchanging$(l@) → str` | onchanging handler **name** (set / get) |
| `strings_beginupdate(l@) → num` | enter a batched-update block (returns nesting depth) |
| `strings_endupdate(l@) → num` | leave a batched-update block |

**Files and streams** (return the line count)

| function | description |
| --- | --- |
| `strings_savetofile(l@, path$ [, enc$]) → num` | write the list to a file |
| `strings_save(l@, path$) → num` | alias of `strings_savetofile` |
| `strings_loadfromfile(l@, path$ [, enc$]) → num` | replace items from a file |
| `strings_load(l@, path$) → num` | alias of `strings_loadfromfile` |
| `strings_savetostream(l@, bytes@ [, enc$]) → num` | write the list into a byte buffer |
| `strings_loadfromstream(l@, bytes@ [, enc$]) → num` | replace items from a byte buffer |

## Regex — regular expressions (8 functions)

Thin wrappers over the RTL's `TRegExpr`. Throughout, the **pattern comes first**,
the text second. Positions are 1-based, absence is 0; group 0 is the whole match.
The find-list functions return a **string-list handle** (read it with StrList). A
malformed pattern is returned as an error.

| function | description |
| --- | --- |
| `regex_find$(pattern$, text$) → str` | the first match (`""` if none) |
| `regex_findpos(pattern$, text$) → num` | 1-based position of the first match, 0 if none |
| `regex_findlen(pattern$, text$) → num` | length of the first match |
| `regex_groupcount(pattern$, text$) → num` | number of capture groups, including group 0 |
| `regex_group$(pattern$, text$, n) → str` | capture group `n` (0 = the whole match) |
| `regex_findall@(pattern$, text$) → handle` | a string list of every match |
| `regex_groups@(pattern$, text$) → handle` | a string list of the groups (group 0 first) |
| `regex_split@(pattern$, text$) → handle` | a string list of the pieces split on the pattern |

## Config — INI configuration (31 functions)

A config is a handle over an in-memory INI file bound to a path. An empty section
name means the default section `General`. Numbers are stored in a **fixed
(invariant) format**, so a value written on one machine reads the same on another.
Changes reach disk only on `cfg_save` (or under autosave); a bad handle is
rejected.

| function | description |
| --- | --- |
| `cfg_open@(path$) → handle` | open (or create) a config bound to a file |
| `cfg_open_auto@(path$) → handle` | open with autosave on (every set flushes) |
| `cfg_filename$(c@) → str` | the bound file path |
| `cfg_path$() → str` | the platform's per-app config directory |
| `cfg_set@(c@, section$, key$, value$) → handle` | set a string in a section |
| `cfg_get$(c@, section$, key$, default$) → str` | read a string (or `default$`) |
| `cfg_sets@(c@, key$, value$) → handle` | set a string in the default section |
| `cfg_gets$(c@, key$, default$) → str` | read a string from the default section |
| `cfg_setn@(c@, section$, key$, n) → handle` | set a number in a section |
| `cfg_getn(c@, section$, key$, default) → num` | read a number (or `default`) |
| `cfg_setns@(c@, key$, n) → handle` | set a number in the default section |
| `cfg_getns(c@, key$, default) → num` | read a number from the default section |
| `cfg_setb@(c@, section$, key$, n) → handle` | set a boolean (stored `1`/`0`) |
| `cfg_getb(c@, section$, key$, default) → num` | read a boolean |
| `cfg_setbs@(c@, key$, n) → handle` | set a boolean in the default section |
| `cfg_getbs(c@, key$, default) → num` | read a boolean from the default section |
| `cfg_exists(c@, section$, key$) → num` | 1 if a key exists in a section |
| `cfg_haskey(c@, key$) → num` | 1 if a key exists in the default section |
| `cfg_section_exists(c@, section$) → num` | 1 if a section exists |
| `cfg_keycount(c@, section$) → num` | number of keys in a section |
| `cfg_sectioncount(c@) → num` | number of sections |
| `cfg_sections$(c@) → str` | section names, newline-separated |
| `cfg_keys$(c@, section$) → str` | key names in a section, newline-separated |
| `cfg_modified(c@) → num` | 1 if there are unsaved changes |
| `cfg_save(c@) → num` | write pending changes to disk |
| `cfg_reload@(c@) → handle` | re-read from disk, discarding in-memory changes |
| `cfg_delete@(c@, section$, key$) → handle` | delete a key in a section |
| `cfg_deletekey@(c@, key$) → handle` | delete a key in the default section |
| `cfg_section_delete@(c@, section$) → handle` | erase a whole section |
| `cfg_clear@(c@) → handle` | clear the whole config |
| `cfg_autosave@(c@, on) → handle` | turn autosave on/off |

## Io — files, directories, paths (58 names / 67 registry entries)

Whole-file text I/O that preserves bytes exactly (no BOM, no newline translation)
plus an IOUtils-style surface. Path helpers are pure string operations that accept
**both `/` and `\`** on every platform. Failures are returned (a write answers 0,
a read of a missing file answers `""`) and recorded in `ioerror()`.

**File content**

| function | description |
| --- | --- |
| `file_readalltext$(path$) → str` | whole file as text (`""` if missing) |
| `file_writealltext(path$, text$) → num` | write text, byte-exact (1 on success) |
| `file_appendalltext(path$, text$) → num` | append text to a file |
| `opentext$(path$, enc$) → str` | read a file (encoding argument accepted) |
| `savetext$(path$, enc$, text$) → str` | write a file (returns the path) |
| `file_exists(path$) → num` | 1 if the file exists |
| `file_delete(path$) → num` | delete a file |
| `file_copy(src$, dst$ [, overwrite]) → num` | copy a file (optional overwrite guard) |
| `file_move(src$, dst$) → num` | rename/move a file |
| `file_createempty(path$) → num` | create an empty file |
| `file_getsize(path$) → num` | file size in bytes |
| `file_getlastwritetime(path$) → num` | last-modified time |
| `file_setlastwritetime(path$, t) → num` | set the last-modified time |
| `file_getlastaccesstime(path$) → num` | last-access time |
| `file_setlastaccesstime(path$, t) → num` | set the last-access time |
| `dir_getlastwritetime(path$) → num` | a directory's last-modified time |
| `dir_setlastwritetime(path$, t) → num` | set it |
| `dir_getlastaccesstime(path$) → num` | a directory's last-access time |
| `dir_setlastaccesstime(path$, t) → num` | set it |
| `file_readallbytes@(path$) → handle` | read a file into a byte-buffer handle |
| `file_writeallbytes(path$, bytes@) → num` | write a byte-buffer handle to a file |

**File and directory timestamps** — file times are real; directory times are kept
in-process (creation/write/access variants each behave the same underlying way).

| function | description |
| --- | --- |
| `file_getcreationtime/getlastwritetime/getlastaccesstime(path$) → num` | a file's timestamp (as a date number) |
| `file_setcreationtime/setlastwritetime/setlastaccesstime(path$, d) → num` | set a file's timestamp |
| `dir_getcreationtime/getlastwritetime/getlastaccesstime(path$) → num` | a directory timestamp (in-process) |
| `dir_setcreationtime/setlastwritetime/setlastaccesstime(path$, d) → num` | set a directory timestamp (in-process) |

**Directories**

| function | description |
| --- | --- |
| `dir_exists(path$) → num` | 1 if the directory exists |
| `dir_create(path$) → num` | create a directory tree |
| `dir_delete(path$ [, recursive]) → num` | remove a directory (recursively when the flag is set) |
| `dir_isempty(path$) → num` | 1 if the directory has no files |
| `dir_getfiles$(path$ [, pattern$ [, recursive]]) → str` | file names, newline-separated, sorted |
| `dir_getdirectories$(path$ [, pattern$ [, recursive]]) → str` | subdirectory names |
| `dir_getentries$(path$ [, pattern$]) → str` | files and subdirectories together |
| `dir_getparent$(path$) → str` | the parent directory |
| `dir_getcurrent$() → str` | the current working directory |
| `dir_setcurrent(path$) → num` | change the working directory |
| `dir_isrelativepath(path$) → num` | 1 if the path is relative |
| `dir_copy(src$, dst$) → num` | copy a directory tree |
| `dir_move(src$, dst$) → num` | move/rename a directory |

**Path** (pure string operations)

| function | description |
| --- | --- |
| `path_combine$(a$, b$ [, c$]) → str` | join path parts with a separator |
| `path_getdirectoryname$(path$) → str` | the directory part (no trailing separator) |
| `path_getfilename$(path$) → str` | the file-name part |
| `path_getfilenamenoext$(path$) → str` | the file name without its extension |
| `path_getextension$(path$) → str` | the extension, including the dot (`""` if none) |
| `path_changeextension$(path$, ext$) → str` | replace/add the extension |
| `path_hasextension(path$) → num` | 1 if the path has an extension |
| `path_getfullpath$(path$) → str` | the absolute path |
| `path_ispathrooted(path$) → num` | 1 if the path is absolute |
| `path_isrelativepath(path$) → num` | 1 if the path is relative |
| `path_getpathroot$(path$) → str` | the root (`C:\` or `/`) |
| `path_matchespattern(name$, pattern$ [, casesensitive]) → num` | glob match (`*`/`?`) |
| `path_hasvalidpathchars(s$) → num` | 1 if the string has no invalid path characters |
| `path_hasvalidfilenamechars(s$) → num` | 1 if the string has no invalid file-name characters |
| `extractfilename$(path$) → str` | the file-name part (SysLib spelling of `path_getfilename$`) |
| `extractfileext$(path$) → str` | the extension (SysLib spelling) |
| `extractfilepath$(path$) → str` | the directory part **with** its trailing separator |
| `changefileext$(path$, ext$) → str` | replace/add the extension (SysLib spelling) |

**Errors**

| function | description |
| --- | --- |
| `ioerror() → num` | the last I/O error code (0 = clean) |
| `iostrerror$() → str` | the last I/O error as text |

## Sys — system, paths, colours (39 functions)

Process arguments, path separators, known directories, generated names, directory
and file make/remove, environment variables, and a small colour name↔number table.
Several answers are per-platform; a group of mobile-only directories answers `""`
on desktop by design.

| function | description |
| --- | --- |
| `paramcount() → num` | number of command-line arguments |
| `paramstr$(n) → str` | the `n`-th argument (0 is the program path) |
| `dirseparator$() → str` | the path-component separator (`\` or `/`) |
| `pathseparator$() → str` | the PATH list separator (`;` or `:`) |
| `altseparator$() → str` | the alternate separator (`/` on Windows, else `""`) |
| `temppath$() → str` | the system temp directory |
| `homepath$() → str` | the user's home directory |
| `documentspath$() → str` | the user's Documents directory |
| `tempfilename$() → str` | a fresh temp file name |
| `randomfilename$() → str` | a random name (GUID hex, no separators) |
| `guidfilename$(withdashes) → str` | a GUID-based name, with or without dashes |
| `mkdir(path$) → num` | create a directory (returns 1) |
| `rmdir(path$) → num` | remove a directory (returns 1) |
| `forcedirectories(path$) → num` | create a directory tree; reports success |
| `chdir(path$) → num` | change the working directory (returns 1) |
| `fileexists(path$, followlinks) → num` | 1 if a file exists |
| `kill(path$) → num` | delete a file (returns 1) |
| `environ$(name$) → str` | an environment variable's value |
| `color(name$) → num` | the RGB number for a colour name (or a `$rrggbb`/decimal literal) |
| `colortostr$(n) → str` | the colour name for an RGB number (or `$rrggbb`) |
| `alphacolor(name$) → num` | the colour number with an opaque alpha channel |
| *mobile directory paths (18)* | `shareddocumentspath$`, `librarypath$`, `cachepath$`, `publicpath$`, `picturespath$`, `sharedpicturespath$`, `camerapath$`, `sharedcamerapath$`, `musicpath$`, `sharedmusicpath$`, `moviespath$`, `sharedmoviespath$`, `alarmspath$`, `sharedalarmspath$`, `downloadspath$`, `shareddownloadspath$`, `ringtonespath$`, `sharedringtonespath$` — each `() → str`, answering `""` on desktop |

## Platform — platform info and StdLib remainder (18 functions)

Identify the running system (decided at compile time by FPC platform macros, so
the answer is exact), read its version, and a handful of StdLib helpers including
handle round-trips that consult the registry rather than dereferencing a raw
address.

| function | description |
| --- | --- |
| `os_name$() → str` | `"Windows"`, `"macOS"`, `"Linux"`, or `"Unix"` |
| `os_platform$() → str` | the FPC target-OS string |
| `os_architecture$() → str` | the FPC target-CPU string |
| `os_major() → num` | OS major version |
| `os_minor() → num` | OS minor version |
| `os_build() → num` | OS build number |
| `os_spmajor() → num` | service-pack major (0 — not tracked) |
| `os_spminor() → num` | service-pack minor (0 — not tracked) |
| `os_check(major, minor [, build]) → num` | 1 if the system is at least the given version |
| `number(v@) → num` | a handle's integer id (0 for a non-handle) |
| `isassigned(v@) → num` | 1 if the value is a non-nil handle |
| `classname$(v@) → str` | the class name of a live handle (`""` for a fabricated address) |
| `sign(n) → num` | −1, 0, or 1 |
| `isnull(s$) → num` | 1 if the string is a single NUL character |
| `pause(seconds) → num` | sleep for the given seconds (returns 0) |
| `formatsettings$(name$) → str` | read a process-wide format setting by name |
| `formatsettings(name$, value$) → num` | set a process-wide format setting by name |

## Host — host services (5 functions)

The language-visible face of the engine's host-services seam (event pump,
clipboard). Each asks the VM's seam, which a host fills in and a headless runner
leaves empty — so **an absent service returns the empty answer, never faults**.

| function | description |
| --- | --- |
| `processmessages() → num` | pump the host event loop; 1 if a host pumped, else 0 |
| `handlemessage() → num` | wait for / dispatch one host message; 1 if it could, else 0 |
| `copytext$(s$) → str` | put `s$` on the host clipboard; the stored text, or `""` with no service |
| `pastetext$() → str` | read the host clipboard; its text, or `""` with no service |
| `strerror() → num` | the last host-services error code (0 clear; non-zero after a clipboard call found no service) |

## Err — error handling (5 functions)

The BASIC-visible face of the `ON ERROR` handler. `err`/`errmsg$`/`erl`/`err_clear`
read the executing VM's caught-error state; `error` lets a program raise its own
catchable runtime error.

| function | description |
| --- | --- |
| `err() → num` | error code (0 none, 1 int-overflow, 2 div-by-zero, 3 type-mismatch, 4 unknown-function, 5 syntax, 6 runtime) |
| `errmsg$() → str` | the error message |
| `erl() → num` | the source line where the error occurred |
| `err_clear() → num` | reset the caught-error state |
| `error(msg$) → num` | fail the current statement with a catchable runtime error carrying `msg$` |

## Call — indirect calls (`callfunc`, 5 names / 30 registry entries)

Calls a BASIC **user function** chosen at run time by name — the language face of
the engine's re-entrant host-callback seam. The routine runs over the caller's
globals and handles. The suffix on the spelling only reads as the expected return
type; all spellings run the same primitive. An unknown name is a runtime error.

| function | description |
| --- | --- |
| `callfunc(name$) → num` | call a user function by name with no argument |
| `callfunc(name$, arg) → num` | call with one argument of any kind |
| `callfunc$(name$ [, arg]) → str` | same, when the callee returns a string |
| `callfunc%(name$ [, arg]) → int` | same, when the callee returns an int |
| `callfunc?(name$ [, arg]) → bool` | same, when the callee returns a bool |
| `callfunc@(name$ [, arg]) → handle` | same, when the callee returns a handle |

## Rag — local retrieval index (14 functions)

A pure-engine "RAG": a **local** retrieval index over a folder of markdown
documents with YAML-style front-matter — no network, model or vector database. A
query is scored against each document by a multi-signal keyword rule (tags, title,
function names, id) so the same question always returns the same document. The
index is a handle; a fabricated/stale handle is refused (`rag_error` reports it).

| function | description |
| --- | --- |
| `rag@(basepath$) → handle` | build an index over a folder of markdown docs |
| `rag_free(r@) → num` | free the index (1 on success) |
| `rag_rebuild@(r@) → handle` | re-read and re-index the folder |
| `rag_retrieve$(r@, query$) → str` | the best-matching documents as `### Title` blocks |
| `rag_retrieve_json$(r@, query$) → str` | the same results as JSON (id/title/category/score/tokens/truncated/content) |
| `rag_retrieve_budget$(r@, query$, maxtokens) → str` | results trimmed to a token budget |
| `rag_doc$(r@, id$) → str` | one document by id (`"Error: ..."` when the id is unknown) |
| `rag_functions$(r@, query$) → str` | documents matched by function name |
| `rag_tags$(r@, query$) → str` | documents matched by tag (with scores) |
| `rag_analyze$(r@, query$) → str` | the query's extracted signals as JSON |
| `rag_count(r@) → num` | number of indexed documents (0 for a bad handle) |
| `rag_funccount(r@) → num` | number of distinct indexed function names |
| `rag_summary$(r@) → str` | a human-readable index summary |
| `rag_error() → num` | the last RAG error code (0 clear; 1 after a bad handle) |

---

# Opt-in packages (a host must register them)

The console `phosphor` host registers **CRT**. The test and embedding hosts
register the rest. Http and Sqlite need an external runtime and are gated on it.

## Base64 — base64 / hex encoding (10 functions)

MIME base64 (continuous line, no wrapping), a URL-safe variant, whole-file forms,
validity, and hex. Encoding round-trips: `base64_decode$(base64_encode$(s)) = s`.

| function | description |
| --- | --- |
| `base64_encode$(s$) → str` | encode to base64 (no line wrapping) |
| `base64_decode$(s$) → str` | decode base64 |
| `base64_urlencode$(s$) → str` | URL-safe base64 (`-`/`_`, padding stripped) |
| `base64_urldecode$(s$) → str` | decode URL-safe base64 |
| `base64_encodefile$(path$) → str` | encode a whole file's bytes |
| `base64_decodefile(b64$, path$) → num` | decode into a file (1 on success) |
| `base64_valid(s$) → num` | 1 if `s$` is well-formed base64 (line breaks tolerated) |
| `base64_error() → num` | the last base64 op's status (0 = clean) |
| `hex_encode$(s$) → str` | bytes → lowercase hex |
| `hex_decode$(s$) → str` | hex → bytes (stops at the first non-hex pair) |

## Zip — zip archives (18 functions)

Over FPC's `Zipper` (ships with the compiler). A whole-archive surface plus a
handle-based create/open/add/inspect/extract surface. Failures are answered and
recorded in `zip_error()`.

| function | description |
| --- | --- |
| `zip_compress(zip$, srcdir$) → num` | zip the files directly in a directory |
| `unzip_extract(zip$, destdir$) → num` | extract a whole archive |
| `unzip_count(zip$) → num` | number of entries |
| `unzip_entry$(zip$, n) → str` | the `n`-th entry name (1-based) |
| `zip_create@(zip$) → handle` | open a new archive for writing |
| `zip_addfile(z@, disk$, name$) → num` | add a file under an archive name |
| `zip_addstr(z@, text$, name$) → num` | add an entry from a string |
| `zip_open@(zip$) → handle` | open an existing archive for reading |
| `zip_count(z@) → num` | entry count |
| `zip_exists(z@, name$) → num` | 1 if an entry is present |
| `zip_read$(z@, name$) → str` | an entry's content, in memory |
| `zip_entrysize(z@, name$) → num` | an entry's uncompressed size |
| `zip_list$(z@) → str` | the entry names, newline-joined |
| `zip_extract(z@, name$, dir$) → num` | extract one entry under a directory |
| `zip_extractall(z@, dir$) → num` | extract every entry under a directory |
| `zip_close(z@) → num` | flush (a writer) / release and free |
| `zip_quick(src$, zip$) → num` | archive one file by its bare name |
| `zip_error() → num` | the last zip op's status (0 = clean) |

## Gzip — gzip compression (10 functions)

Real RFC-1952 gzip (10-byte header, raw DEFLATE, CRC32 + ISIZE trailer) over FPC's
paszlib — a `.gz` a system `gunzip` reads. Failures are answered and recorded in
`gzip_error()`.

| function | description |
| --- | --- |
| `gzip_compress$(s$ [, level]) → str` | gzip a string (optional zlib level 0–9) |
| `gzip_decompress$(s$) → str` | ungzip a packed string |
| `gzip_compressfile(src$, dst$ [, level]) → num` | gzip a file (1/0) |
| `gzip_decompressfile(src$, dst$) → num` | ungzip a file (1/0) |
| `gzip_size(s$) → num` | byte length of the original text |
| `gzip_csize(s$) → num` | byte length of a packed form |
| `gzip_ratio(orig$, packed$) → num` | packed/original ratio (< 1 when it shrank) |
| `gzip_error() → num` | the last gzip op's status (0 = clean) |

## Http — HTTP client (65 functions)

Over FPC's `TFPHTTPClient`; the URL scheme selects TLS (https needs OpenSSL).
Most of the surface is **offline configuration**: a client handle is a config
accumulator, a form handle collects fields/files, and the encoders are pure. HTTPS
certificate verification is **on by default** (secure — a bad cert fails the
connection); the client also resolves and tries all of a host's A records.
`http_get$`/`http_post$` return the body for any status; `http_status` returns 0
only when the request could not complete.

**Requests and global TLS**

| function | description |
| --- | --- |
| `http_get$(url$) → str` | GET; the response body (for any status) |
| `http_status(url$) → num` | GET; the HTTP status code (0 on failure) |
| `http_post$(url$, body$) → str` | POST; the response body |
| `http_verify_peer(on) → num` | turn https certificate verification on (default) / off |
| `http_ca_file$(path$) → str` | use a specific CA bundle for verification |

**Client handle**

| function | description |
| --- | --- |
| `http_client@([url$]) → handle` | a client (a config accumulator), optionally with a base url |
| `http_free(c@) → num` | release the client |
| `http_reset(c@) → num` | return it to the factory state |
| `http_baseurl$(c@) → str` / `http_baseurl(c@, u$) → num` | base url (get / set) |
| `http_timeout(c@) → num` / `http_timeout(c@, ms) → num` | connect timeout in ms (get / set) |
| `http_responsetimeout(c@, ms) → num` | response timeout in ms (set) |

**Header / param / cookie bags** (setting an existing name replaces it)

| function | description |
| --- | --- |
| `http_headercount(c@) → num` / `http_header(c@, name$, value$) → num` / `http_header$(c@, name$) → str` / `http_headerremove(c@, name$) → num` / `http_headerclear(c@) → num` | request headers (case-insensitive names) |
| `http_paramcount(c@) → num` / `http_param(c@, name$, value$) → num` / `http_param$(c@, name$) → str` / `http_paramremove(c@, name$) → num` / `http_paramclear(c@) → num` | query parameters |
| `http_cookiecount(c@) → num` / `http_cookie(c@, name$, value$) → num` / `http_cookie$(c@, name$) → str` / `http_cookieremove(c@, name$) → num` / `http_cookieclear(c@) → num` | cookies |

**Auth and proxy** (write-only setters)

| function | description |
| --- | --- |
| `http_basicauth(c@, user$, pass$) → num` | HTTP Basic auth |
| `http_bearerauth(c@, token$) → num` | Bearer-token auth |
| `http_customauth(c@, value$) → num` | a raw Authorization value |
| `http_clearauth(c@) → num` | clear auth |
| `http_proxy(c@, host$, port) → num` | set a proxy |
| `http_proxyauth(c@, user$, pass$) → num` | proxy credentials |
| `http_clearproxy(c@) → num` | clear the proxy |

**Behaviour**

| function | description |
| --- | --- |
| `http_useragent(c@, s$) → num` / `http_useragent$(c@) → str` | User-Agent (set / get) |
| `http_contenttype(c@, s$) → num` / `http_contenttype$(c@) → str` | Content-Type (set / get) |
| `http_accept(c@, s$) → num` / `http_accept$(c@) → str` | Accept (set / get) |
| `http_followredirects(c@, on) → num` / `http_followredirects(c@) → num` | follow-redirects flag (set / get) |
| `http_maxredirects(c@, n) → num` / `http_maxredirects(c@) → num` | redirect cap (set / get) |
| `http_validatessl(c@, on) → num` / `http_validatessl(c@) → num` | per-client SSL-validation flag (set / get) |

**Multipart form**

| function | description |
| --- | --- |
| `http_form@() → handle` | a new multipart form |
| `http_formfield(f@, name$, value$) → num` | add a text field |
| `http_formfile(f@, name$, path$) → num` | add a file field |
| `http_formfilenamed(f@, name$, path$, filename$) → num` | add a file field with an explicit filename |
| `http_formfiletype(f@, name$, path$, filename$, contenttype$) → num` | add a file field with a content type |
| `http_formfieldcount(f@) → num` | number of text fields |
| `http_formfilecount(f@) → num` | number of file fields |
| `http_formurlencoded$(f@) → str` | the fields as an `application/x-www-form-urlencoded` string |
| `http_formclear(f@) → num` | clear the form |
| `http_formfree(f@) → num` | free the form handle |

**Pure encoders and errors**

| function | description |
| --- | --- |
| `http_urlencode$(s$) → str` | percent-encode (space → `%20`, `+` → `%2B`) |
| `http_urldecode$(s$) → str` | percent-decode (`+` → space) |
| `http_htmlencode$(s$) → str` | escape HTML entities |
| `http_htmldecode$(s$) → str` | unescape HTML entities |
| `http_error() → num` | the last HTTP/config error code (0 = clean) |
| `http_clearerror() → num` | reset the error code |
| `http_strerror$(code) → str` | the text for an error code |

## Sqlite — SQLite (57 functions)

Over the raw sqlite3 C API (FPC's dynamic binding — needs the SQLite runtime;
`sqlite_available()` reports whether it loaded). One handle from `sqlite_open@`
serves everything, from `sqlite_exec` to the full statement API. Indices are
**1-based** (the package maps bind params and columns onto SQLite's own bases).
Closing a database finalizes and invalidates every cursor opened on it.

**Database**

| function | description |
| --- | --- |
| `sqlite_available() → num` | 1 if the SQLite library loaded |
| `sqlite_open@([path$]) → handle` | open a database (in-memory when no path; `":memory:"` too) |
| `sqlite_close(db@) → num` | close and free the database (and its cursors) |
| `sqlite_isopen(db@) → num` | 1 while the handle is an open database |
| `sqlite_path$(db@) → str` | the file the database was opened on |
| `sqlite_version$() → str` | the SQLite library version |

**Run**

| function | description |
| --- | --- |
| `sqlite_exec(db@, sql$) → num` | run a non-query statement (1/0) |
| `sqlite_scalar$(db@, sql$) → str` | first column of the first row, as text |
| `sqlite_scalar(db@, sql$) → num` | first column of the first row, as a number |
| `sqlite_query$(db@, sql$) → str` | all rows: columns tab-joined, rows newline-joined |
| `sqlite_changes(db@) → num` | rows the last statement changed |
| `sqlite_totalchanges(db@) → num` | rows changed this session |
| `sqlite_lastid(db@) → num` | last inserted row id |

**Introspection**

| function | description |
| --- | --- |
| `sqlite_tableexists(db@, t$) → num` | 1 if a table exists |
| `sqlite_tables@(db@) → handle` | a JSON array of user table names |
| `sqlite_columns@(db@, t$) → handle` | a JSON array of `(name, type, notnull, pk)` per column |

**Prepared statements and cursors** (1-based)

| function | description |
| --- | --- |
| `sqlite_prepare@(db@, sql$) → handle` | a prepared statement |
| `sqlite_query@(db@, sql$) → handle` | a cursor (a prepared SELECT) |
| `sqlite_step(s@) → num` | 1 if it landed on a row, 0 at the end |
| `sqlite_eof(s@) → num` | 1 unless the cursor is on a row |
| `sqlite_reset(s@) → num` | re-run the statement from the top |
| `sqlite_clearbind(s@) → num` | drop every bound value |
| `sqlite_finalize(s@) → num` | finish and free the statement |
| `sqlite_bindstr(s@, i, v$) → num` | bind a string to parameter `i` |
| `sqlite_bindnum(s@, i, v) → num` | bind a number to parameter `i` |
| `sqlite_bindnull(s@, i) → num` | bind SQL NULL to parameter `i` |
| `sqlite_bindjson(s@, obj@) → num` | bind a JSON object's members by name (`:key`) |

**Column access** (1-based)

| function | description |
| --- | --- |
| `sqlite_colcount(s@) → num` | number of result columns |
| `sqlite_colname$(s@, i) → str` | the name of column `i` |
| `sqlite_colindex(s@, name$) → num` | the 1-based index of a column by name (0 if none) |
| `sqlite_coltype(s@, i) → num` | the SQLite type code of column `i` in this row |
| `sqlite_coltypename$(code) → str` | the name of a type code (integer/float/text/blob/null) |
| `sqlite_getstr$(s@, i) → str` | column `i` as text (by position) |
| `sqlite_getnum(s@, i) → num` | column `i` as a number (by position) |
| `sqlite_gets$(s@, name$) → str` | a column as text (by name) |
| `sqlite_getn(s@, name$) → num` | a column as a number (by name) |
| `sqlite_isnull(s@, i) → num` | 1 if column `i` is NULL (by position) |
| `sqlite_isn(s@, name$) → num` | 1 if a column is NULL (by name) |
| `sqlite_isblob(s@, i) → num` | 1 if column `i` is a blob |

**JSON row bridge**

| function | description |
| --- | --- |
| `sqlite_row@(s@) → handle` | the current row as a JSON object |
| `sqlite_fetchone@(s@) → handle` | step, then the new current row as a JSON object |
| `sqlite_fetchall@(s@) → handle` | every remaining row as a JSON array |
| `sqlite_insertjson(db@, t$, o@) → num` | insert a JSON object as a row (returns rows) |
| `sqlite_updatejson(db@, t$, o@, where$) → num` | update rows from a JSON object (returns rows) |

**Transactions, escaping, errors, maintenance**

| function | description |
| --- | --- |
| `sqlite_begin(db@) → num` | BEGIN a transaction |
| `sqlite_commit(db@) → num` | COMMIT |
| `sqlite_rollback(db@) → num` | ROLLBACK |
| `sqlite_intrans(db@) → num` | 1 while a transaction is open |
| `sqlite_escape$(s$) → str` | double every apostrophe |
| `sqlite_quote$(s$) → str` | escape and wrap in apostrophes |
| `sqlite_error() → num` | the last SQLite error code (0 = none) |
| `sqlite_errormsg$() → str` | the last error message |
| `sqlite_strerror$(code) → str` | the English name of an error code |
| `sqlite_clearerror() → num` | reset the last-error code and message |
| `sqlite_backup(db@, path$) → num` | write a standalone copy of the database |
| `sqlite_vacuum(db@) → num` | compact the database |

## Crt — console control (28 functions)

Classic-BASIC terminal control. Screen-control functions **return an ANSI escape
sequence**, which the program emits with `print` (no newline) — keeping the
engine's single output seam. Call `crt_init()` once at startup to enable ANSI on
the Windows console. Colours are 0–7 normal / 8–15 bright (0 black, 1 red, 2 green,
3 yellow, 4 blue, 5 magenta, 6 cyan, 7 white). Key input reads the keyboard
directly; with a non-terminal stdin the input calls return `""`/0 without blocking.

**Screen and cursor**

| function | description |
| --- | --- |
| `cls$() → str` | clear the screen |
| `clreol$() → str` | clear to end of line |
| `clreos$() → str` | clear to end of screen |
| `home$() → str` | move the cursor to the top-left |
| `at$(row, col) → str` | move the cursor to `row`, `col` |
| `moveup$(n) / movedown$(n) / moveleft$(n) / moveright$(n) → str` | move the cursor `n` cells |
| `hidecursor$() → str` | hide the cursor |
| `showcursor$() → str` | show the cursor |
| `savepos$() → str` | save the cursor position |
| `restorepos$() → str` | restore the cursor position |

**Text attributes**

| function | description |
| --- | --- |
| `reset$() → str` | reset all attributes |
| `bold$() → str` | bold |
| `faint$() → str` | faint |
| `italic$() → str` | italic |
| `underline$() → str` | underline |
| `blink$() → str` | blink |
| `inverse$() → str` | inverse video |

**Colour**

| function | description |
| --- | --- |
| `color$(fg) → str` | set the foreground colour |
| `color$(fg, bg) → str` | set foreground and background |
| `bg$(bg) → str` | set the background colour |

**Input and setup**

| function | description |
| --- | --- |
| `inkey$() → str` | non-blocking: a waiting key, or `""` |
| `getkey$() → str` | block for one key |
| `keypressed() → num` | 1 if a key is waiting |
| `crt_init() → num` | put the terminal in raw mode / enable ANSI on Windows |
| `crt_done() → num` | restore the terminal |
