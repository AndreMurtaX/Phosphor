rem ---------------------------------------------------------------
rem Phosphor's language contract, run rather than read.
rem
rem The contract tells somebody what they may write in a .bas file:
rem which constructs exist, how a string is indexed, where an array
rem starts. This file executes each promise as an assertion.
rem
rem Adapted from Plan9Basic's 19_language_contract, with the ONE
rem deliberate divergence Phosphor makes: Plan9Basic indexes strings
rem from zero (s$[0] first line, s$[[0]] first character); Phosphor
rem indexes them from ONE, so s$[1] is the first line and s$[[1]] the
rem first character. Arrays are 1-based in both, and Phosphor spells
rem the array sigil `@` where Plan9Basic wrote `#`. The character-index
rem constants are recomputed for base-1 (every one shifts by +1).
rem
rem The half that says what does NOT compile lives in tests/negative/,
rem because a rejection cannot be asserted from inside the language.
rem ---------------------------------------------------------------

test_case("contract/a-string-indexes-lines-from-one")
rem s$[n] is the n-th LINE, counting from one -- not the n-th
rem character, which is the mistake the notation invites.
let nl$ = chr$(10)
let s$ = "alpha" + nl$ + "beta" + nl$ + "gamma"
assert_eq(s$[1], "alpha", "s$[1] is the first line")
assert_eq(s$[2], "beta", "s$[2] is the second")
assert_eq(s$[3], "gamma", "s$[3] is the third")

test_case("contract/double-brackets-index-characters-from-one")
let t$ = "abcd"
assert_eq(t$[[1]], "a", "t$[[1]] is the first character")
assert_eq(t$[[4]], "d", "and t$[[4]] the fourth")

test_case("contract/arrays-start-at-one")
rem The line and character notations above start at one as well, so
rem here there is nothing left to misremember: an array's first
rem element is at 1 and its last at the declared size.
let a@ = dim@(3)
a@[1] = 11
a@[2] = 22
a@[3] = 33
assert_eq(a@[1], 11, "the first element is at 1")
assert_eq(a@[3], 33, "and the last at the declared size")

test_case("contract/a-quote-inside-a-literal-is-escaped-with-a-backslash")
let q$ = "he said \"hi\""
assert_eq(len(q$), 12, "the escapes produce one character each")
assert_eq(q$[[9]], chr$(34), "and that character is a quote")

test_case("contract/a-single-backslash-before-a-letter-is-an-escape")
rem Phosphor documents the escape table, and the consequence is worth
rem stating outright: a Windows path typed the obvious way is not that
rem path. Here \f is a form feed and \n is a newline, so what looks
rem like nineteen characters of path is seventeen characters of
rem something else -- each escape collapses two into one. A separator
rem has to be written twice.
let trap$ = "C:\folder\notes.txt"
assert_eq(len(trap$), 17, "the escapes each collapse two characters into one")
assert_eq(trap$[[3]], chr$(12), "\f became a form feed")
assert_eq(trap$[[9]], chr$(10), "and \n became a newline")

let real$ = "C:\\folder\\notes.txt"
assert_eq(len(real$), 19, "doubled, the separators survive")
assert_eq(real$[[3]], chr$(92), "as backslashes")

test_case("contract/on-goto-picks-the-nth-label")
rem Documented in the contract and exercised here: a 1-based selector
rem picks the n-th label in the list.
let hit = 0
let k = 2
on k goto lblOne, lblTwo, lblThree
lblOne:
  hit = 1
  goto afterGoto
lblTwo:
  hit = 2
  goto afterGoto
lblThree:
  hit = 3
afterGoto:
assert_eq(hit, 2, "on k goto took the second branch")

test_case("contract/on-gosub-calls-the-nth-routine-and-returns")
let acc = 0
let j = 3
on j gosub subA, subB, subC
assert_eq(acc, 30, "on j gosub called the third routine")
goto afterSubs
subA:
  acc = 10
  return
subB:
  acc = 20
  return
subC:
  acc = 30
  return
afterSubs:
