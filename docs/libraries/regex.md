# regex — regular expressions over strings

`engine/libs/PhosphorRegexLib.pas` · 8 functions · always available

## What it is for

`instr` finds a string you already know. This library finds a string you can only
*describe* — a run of digits, a date, a field between two separators — and then
takes it apart. It is a thin set of wrappers over the RTL's `TRegExpr`: eight
functions, no compiled-pattern object, no match cursor. Each call takes a pattern
and a text and answers one thing.

Two conventions are worth learning before the first call. **The pattern comes
first and the text second** — the opposite of `instr` and of most of StrLib. And
**positions are 1-based, absence is 0**, exactly as `instr` reports them, so on
ASCII text the two agree on where a match starts instead of differing by one the
way the reference implementation did. (On text with accents they part company —
see the last note on this page.)

The library follows the project's usual stance that **a failure is a value, not an
event**. A pattern that does not match is not an error: `regex_find$` answers
`""`, `regex_findpos` answers `0`, and the three list functions answer a real
handle to an **empty list** — an empty result is an answer, and you read its count
rather than testing for nil. A pattern that is *malformed*, on the other hand, is
returned as an error rather than raised out of the engine: `on error goto` catches
it as code `6` with a message beginning `regex error:`.

The one place Phosphor's base-1 rule does not apply is **group numbering**: group
`0` is the whole match, as in every regex dialect, so two parenthesised groups make
`regex_groupcount` answer `3`. That exception collides with base-1 exactly once, in
`regex_groups@`: the list it answers is base-1 like every other list, so group *n*
lives at entry *n + 1*, and entry `1` is the whole match.

## Functions

| function | what it answers |
| --- | --- |
| `regex_find$(pattern$, text$) → str` | the text of the first match. `""` when the pattern does not match — and also `""` when the match itself is empty, so use `regex_findpos` if you need to tell those apart |
| `regex_findpos(pattern$, text$) → num` | where the first match starts, counting from 1. `0` when there is no match, the same "not found" `instr` gives |
| `regex_findlen(pattern$, text$) → num` | how long the first match is. `0` when there is no match — and also `0` for a match of nothing, such as `[0-9]*` against a letter |
| `regex_groupcount(pattern$, text$) → num` | how many groups the match has, **group 0 included**: two brackets answer `3`. `0` means the pattern did not match at all, since any match has at least group 0 |
| `regex_group$(pattern$, text$, n) → str` | the text of group `n`, `0` being the whole match. `""` when the pattern did not match, when `n` is past the last group, and when `n` is negative — an out-of-range group is not an error |
| `regex_findall@(pattern$, text$) → handle` | a new string list holding **every** match in order, not just the first. No match answers an empty list, not nil. Beware a pattern that can match nothing (`[0-9]*`): it matches at every position |
| `regex_groups@(pattern$, text$) → handle` | a new string list of the whole match followed by each group. **Entry 1 is group 0**, entry *n+1* is group *n*. A pattern with no brackets answers one entry; no match at all answers an empty list |
| `regex_split@(pattern$, text$) → handle` | a new string list of the pieces between matches. This one never needs a match: a pattern that is not there answers a one-entry list holding the whole text, and adjacent separators keep the empty piece between them |

The three `@` functions hand back a fresh list every call, read with StrList
(`strings_count`, `strings_strings$`, …). Handles are freed when the program ends,
but a call inside a loop should `strings_free` its result.

## A worked example

One log line, pulled apart four different ways: named fields by group, every
number in it, the pieces of its message, and a check for a word that is not there.

```basic
rem Pull the fields out of one log line, then look at it a few other ways.
log$ = "2026-09-05 14:22:01 WARN disk 91% full; retry in 30s"
pat$ = "([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2}) ([A-Z]+) (.*)"

if regex_findpos(pat$, log$) = 0 then
  println "not a log line"
else
  println "date  " + regex_group$(pat$, log$, 1)
  println "level " + regex_group$(pat$, log$, 3)
  println "text  " + regex_group$(pat$, log$, 4)
  println "groups, group 0 included: " + str$(regex_groupcount(pat$, log$))
endif

rem Where the whole match sits, without extracting it.
println "match at " + str$(regex_findpos(pat$, log$)) + ", " + str$(regex_findlen(pat$, log$)) + " long"

rem Every number the line mentions, in the order they occur.
nums@ = regex_findall@("[0-9]+", log$)
line$ = ""
for i = 1 to strings_count(nums@)
  line$ = line$ + strings_strings$(nums@, i) + " "
next
println "numbers: " + line$
strings_free(nums@)

rem The same groups as one list. It is base-1 like every other list here,
rem so group 0 is entry 1 and group n is entry n + 1.
g@ = regex_groups@(pat$, log$)
println "entry 1 is group 0: " + strings_strings$(g@, 1)
println "entry 4 is group 3: " + strings_strings$(g@, 4)
strings_free(g@)

rem Splitting on a class rather than one fixed separator.
parts@ = regex_split@("; *", regex_group$(pat$, log$, 4))
println "pieces: " + str$(strings_count(parts@)) + ", second = " + strings_strings$(parts@, 2)
strings_free(parts@)

rem A pattern that is simply not there answers the empty string.
println "fatal? [" + regex_find$("FATAL", log$) + "]"
```

Two things worth noticing:

- **`groupcount` answers 5, not 4.** Four brackets plus the whole match. The same
  five entries come back from `regex_groups@`, and `WARN` — the third bracket — is
  entry `4` there, because the list numbers from 1 while the groups number from 0.
- **Nothing is remembered between calls.** `pat$` is compiled afresh by every one
  of those lines; there is no handle for a prepared pattern and no "find the next
  one" cursor. When you want more than the first match, that is what
  `regex_findall@` is for.

## Notes

**A bad pattern is catchable, not fatal.** Every one of the eight reports a
compile failure through the engine's error channel, so a handler sees it like any
other runtime failure:

```basic
on error goto bad
hits@ = regex_findall@("[unclosed", text$)
end

bad:
println errmsg$()   rem  regex error: TRegExpr compile: unmatched [] (pos 9)
err_clear()
```

**Matching is case-sensitive**, and there is no flag argument to change that. Put
the modifier in the pattern instead: `regex_find$("(?i)abc", "xxABCyy")` answers
`"ABC"`.

**`.` matches a newline here.** `TRegExpr` runs in single-line mode by default, so
`regex_findpos("a.b", "a" + chr$(10) + "b")` answers `1` — a pattern meant for one
line will happily run across two. Turn it off the same way you turn case-folding
on, with an inline modifier: `(?-s)a.b` against that same text answers `0`.

**Positions and lengths are byte offsets, and `.` matches one byte.** This is the
one place the library and the rest of the string functions genuinely disagree: in
`"ação 42"`, `instr` puts the `4` at character `6` while `regex_findpos` puts it at
byte `8`, and `regex_findlen("ção", ...)` answers `5` for three characters. On
ASCII text the two are identical; on text with accents they are not, and a pattern
like `"ç.o"` fails to match `"ação"` because `.` consumes only the first byte of
`ç`. Literal non-ASCII text in a pattern matches fine — it is the single-character
constructs (`.`, character classes, `{n}` counts) that count bytes. Keep patterns
byte-safe, or match on the ASCII structure around the accented text rather than
through it.
