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
rem That is where the newest clause lives -- a statement that is only
rem an expression must DO something, so a call needs its parentheses.
rem What belongs HERE is the other direction, and it is the one worth
rem guarding: a refusal that catches a legitimate line is a worse
rem defect than the silence it replaced. The blocks at the end of this
rem file run a call in every statement position the grammar has and
rem assert the effect landed, with the returned value thrown away each
rem time -- and then pin the FOUR positions the refusal deliberately
rem does NOT reach, because a name whose next token is `:` is the label
rem syntax and wins wherever a statement may begin at program level:
rem a line's start, after a `:` separator, after a numeric label, and
rem after another label. Not one position, which is what the first
rem version of this file claimed.
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

test_case("contract/a-call-is-a-statement-everywhere-and-its-value-is-discarded")
rem THE OTHER HALF OF "A STATEMENT MUST DO SOMETHING". `err_clear` with
rem the parentheses left off is now refused -- it was a global read and a
rem discard, and tests/negative/43_bare_call_without_parentheses.bas pins
rem the refusal. A compiler that newly says no can say it to the wrong
rem line, and the shape next door is the commonest statement in the
rem language: a call nobody wants the value of. Every position the
rem grammar allows one in is exercised below and the counter is the
rem proof that each ran -- the total is arithmetic written out here,
rem not a number read off a run.
bumps = 0
bump()
assert_eq(bumps, 1, "a call on a line of its own runs")
if 1 = 1 then bump()
assert_eq(bumps, 2, "a call as the whole body of an inline if runs")
if 1 = 2 then bump() else bump()
assert_eq(bumps, 3, "a call in the else arm of an inline if runs")
let separated = 1 : bump()
assert_eq(bumps, 4, "a call after a ':' separator runs")
for bi = 1 to 2
  bump()
next
assert_eq(bumps, 6, "a call in a loop body runs once per pass")
while bumps < 7
  bump()
endwhile
assert_eq(bumps, 7, "a call in a while body runs")
select case 1
case 1
  bump()
endselect
assert_eq(bumps, 8, "a call in a select arm runs")
twice()
assert_eq(bumps, 10, "a call inside a function body runs")

test_case("contract/a-mutator-called-as-a-statement-keeps-its-effect")
rem The returned handle is what makes these chainable; as statements it
rem is thrown away, which is exactly the shape the new refusal must not
rem touch. It does not: the emitted call is what the rule looks for.
cells@ = dim@(3)
arr_set@(cells@, 1, 5)
assert_eq(narr_get(cells@, 1), 5, "arr_set@ as a statement stored the element")
cells@[2] = 9
assert_eq(narr_get(cells@, 2), 9, "an indexed assignment stored the element")

test_case("contract/the-parenthesised-call-the-bare-name-only-looked-like")
rem The measured instance, written correctly. `err_clear` used to compile
rem here and leave err() at 2 with nothing said; `err_clear()` clears it.
on error goto contractCleared
divided = 1 / 0
contractCleared:
assert_eq(err(), 2, "the division by zero was caught and err() still holds it")
err_clear()
assert_eq(err(), 0, "err_clear() with its parentheses cleared the error")
on error goto 0

test_case("contract/a-name-before-a-colon-is-a-label-at-every-program-level-start")
rem THE DECISION THAT CAME WITH THAT REFUSAL, written down here so the
rem next reader meets it instead of re-deriving it from a silent run.
rem A name whose next token is `:` is the label syntax, and the compiler
rem reads it before any statement is parsed -- so a label may share its
rem line with a statement, and the label wins. A call with its
rem parentheses left off is those same three tokens, which is why the
rem missing parentheses are still silent there.
rem
rem AND IT IS NOT ONLY A LINE'S START, which is what the first version of
rem this block said. Compile's loop comes back to the label reader
rem wherever a statement may BEGIN at program level: after a `:`
rem separator, after a numeric label, and after another label as well.
rem All four are pinned below, each with its own function, because a
rem label name may only be defined once. Inside a block there is no
rem label reader at all and the bare name is refused, which
rem tests/negative and tests/probe_limits cover -- a rejection cannot be
rem asserted from in here.
rem
rem It is the label rule doing its job, not the refusal leaking. The only
rem signal that would separate the two is a label no goto names, and
rem refusing that would refuse a legitimate program -- a jump not written
rem yet -- while reporting something that is not the author's mistake.
rem The assertions below are read off the label rule, not off a run;
rem docs/language-reference.md states the same limit in prose.
hops = 0
hopTarget: hops = hops + 1
if hops < 2 then goto hopTarget
assert_eq(hops, 2, "a label shares its line with a statement, and goto reaches it")
rem The four functions below are called properly FIRST, so that the four
rem "did not run" assertions after them cannot pass by naming something
rem inert -- each one is known to move the counter when it is really
rem called, which is the difference between a pin and a tautology.
armed = bumps
bump()
bumpMid()
bumpNum()
bumpChain()
assert_eq(bumps, armed + 4, "all four demonstration functions do move the counter when called")
beforeLabel = bumps
bump : labelTail = 1
assert_eq(bumps, beforeLabel, "at a line's start 'bump :' is a label, so the function did not run")
assert_eq(labelTail, 1, "and the statement written after the colon did run")
beforeMid = bumps
midHead = 1 : bumpMid : midTail = 1
assert_eq(bumps, beforeMid, "after a ':' separator 'bumpMid :' is a label too, so the function did not run")
assert_eq(midTail, 1, "and the statement written after that colon did run")
beforeNum = bumps
70 bumpNum : numTail = 1
assert_eq(bumps, beforeNum, "after a numeric label 'bumpNum :' is a label too, so the function did not run")
assert_eq(numTail, 1, "and the statement written after that colon did run")
beforeChain = bumps
chainHead: bumpChain : chainTail = 1
assert_eq(bumps, beforeChain, "after another label 'bumpChain :' is a label too, so the function did not run")
assert_eq(chainTail, 1, "and the statement written after that colon did run")

rem AND THE SECOND SPELLING, ONE TOKEN TO THE RIGHT, which no position of the
rem refusal reaches: everything above is about a STATEMENT. Used as a VALUE the
rem same forgotten parentheses are still read as a variable, because the value
rem really is used and nothing looks wrong. `err` here is the global nobody
rem assigned, which carries 0; `err()` is the call, which answers the code the
rem failed division actually set. Swept over the registry rather than argued:
rem all 109 zero-arity registered names are refused written bare as a statement,
rem and all 109 compile silently on an assignment's right-hand side.
on error goto valueLimit
zeroDiv = 1 / 0
valueLimit:
bareErr = err
calledErr = err()
assert_eq(bareErr, 0, "used as a value 'err' is still the global nobody set, not the call")
assert_eq(calledErr, 2, "while 'err()' is the call, and answers the code the division set")
err_clear()
on error goto 0

function bump()
  rem An undeclared name inside a function is the GLOBAL, which is what
  rem lets this count across every position tested above.
  bumps = bumps + 1
  return 0
endfunction

function bumpMid()
  rem A second name, only because `bump` is already a label above and a
  rem label is defined once. It counts into the same global.
  bumps = bumps + 1
  return 0
endfunction

function bumpNum()
  bumps = bumps + 1
  return 0
endfunction

function bumpChain()
  bumps = bumps + 1
  return 0
endfunction

function twice()
  bump()
  bump()
  return 0
endfunction
