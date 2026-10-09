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

**Under a host's execution budget, a pattern is judged before it runs.** The
matcher cannot be interrupted, so when the host has set `MaxSteps` or `TimeoutMs`
a pattern whose repeated part can match the same text in more than one way — the
`(a+)+` shape — is refused with a catchable `peLimit` error instead of being run
(see [docs/embedding.md](../embedding.md#the-ceilings-reach-inside-a-library-call-too)).
"More than one way" is decided exactly, not guessed from the pattern's look:
`^(a*a*b)+$`, `^((a|a)b)+$` and `^(ab?|b)+$` are refused, while `^(a|ab)+$`,
`^(\d+\.)+\d+$` and a dotted-quad IPv4 pattern counted `{3}` are allowed.
The judge reads the pattern as the matcher does, so spelling the shape differently
does not get it past: `^(\x61+)+$` is `^(a+)+$`, and under `(?i)` the alternation
`(a|A)+` has two branches matching the same character. An escape the judge does
not model (`\p{L}`, `\z`) or a backreference, inside a repeated group, makes the
repeat unprovable, and it is refused. So is a pattern too large for the judge to
finish reading — nesting past 100 groups, or a repeated body bigger than its
automaton limit — which no real pattern reaches. Without a budget this judge is
not asked, and every pattern runs except the few, below, that would end the
process.

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

## Patterns that would end the process

Some patterns are refused on every host, with or without a budget, because running
them would not fail — it would end the program. `TRegExpr` compiles and matches by
recursion on the machine stack and has no limit of its own; an overflow on Windows
is caught once, and the second one in the same thread is an access violation that
closes the host, while on Linux the first one does. So every pattern is read before
it runs, the way `TRegExpr` itself reads it, and four shapes are answered with the
library's ordinary error — code `6`, a message beginning `regex error:` and naming
the function and the reason — instead of being run:

| refused | example | why |
| --- | --- | --- |
| a repeated group that can match nothing, at the start of the pattern | `(a{0,2}){2}`, `(b\|a{0,1}){2}`, `^(a{0,2})+`, `(a?)??` | the compiler walks the group, arrives back at the repeat, and walks it again for ever. It believes `a{0,2}` has width, so it does not refuse the repeat itself |
| a repeat with no upper count over a group that can match nothing | `-(a{0,2})+`, `-(a{0,2})*?c` | the matcher takes the empty match again and again |
| a counted backreference to a group that can capture nothing, or to its own group | `()\1*x`, `(a?)\1+`, `(a\1*)` | the matcher counts empty copies to 2³¹ and then steps back "that many bytes" — past the end of the text. Unguarded, `()\1*?x` against `"a"` answered a 5994-byte match of whatever followed the text in memory |
| a text too long for the stack the pattern's groups would take | `(a\|b)*` over 40000 bytes | every pass through a group, an alternation or a repeated group costs a stack frame that stays until the match ends. `(a\|b)*` costs four per byte, and a 16 MB stack (8 MB on Linux) runs out at about 16000 bytes (8000) |

The last one is arithmetic, not a shape: the stack a call could need is worked out
from the pattern and the text's length and compared with what the calling thread
has left, and the message says both. A repeat of ONE byte-sized thing — `a*`,
`[0-9]+`, `\w{2,}`, `.*` — costs one frame however long the text is, so the usual
patterns over large texts are untouched; it is a repeated *group* that costs per
pass, and the bound is the worst case, a group that consumes one byte per pass.
When a long text is refused, split it first, or repeat a class instead of a group
(`[ab]*` instead of `(a|b)*`).

What still runs: the same group after something that consumes a byte
(`-(a{0,2}){2}` against `"-aaa"` answers `"-aaa"`), a counted repeat over a group
that can match nothing anywhere but at the start (it is bounded by its count), and
a counted backreference to a group that cannot be empty (`(a)\1{2}`) or to a group
the pattern does not have. A pattern that `TRegExpr` itself rejects as malformed
still gets `TRegExpr`'s own message. `tests/suite/88_regex_nullable_repeat.bas`
asks each refusal twice — the second call is the one that used to end the process.

A few refusals are wider than the crash, kept so for one simple rule: a lazy
unbounded repeat over a group that can match nothing crashes only when what
follows it fails, so a trailing `-(a{0,2})*?` — which never repeats at all — is
refused too; and every count on an empty-capable backreference is refused,
although a small one reads only a few bytes past the text.

Two things this does not change. A pattern can still be **slow**: `(a?|b?)` written
out thirty times takes minutes to compile, in a part of `TRegExpr` that no budget
judges, and without a budget an ambiguous repeat over a long text takes exponential
time to fail. And `TRegExpr` raises `loop without loop
entry` for some counted groups over an alternation (`-(b|a{0,1}){2}c` against
`"-abab"`): that is a catchable `regex error:` for a pattern that should simply not
match, a defect of the matcher and not of the process.
