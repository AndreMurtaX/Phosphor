rem ---------------------------------------------------------------
rem WRITING THROUGH A STRING INDEX.
rem
rem `s$[[n]]` reads the n-th character and `s$[n]` reads the n-th line, and both
rem have been documented and tested since they were built. Writing through
rem either COMPILED, EXITED 0, AND DID NOTHING until 2026-09-18 -- the worst
rem shape a gap can take, because a grep says the feature is there and the exit
rem code agrees. Only the output disagreed, and nothing in any corpus wrote
rem through one, so nothing would have failed if it had never existed at all.
rem
rem The engine's own diagnostic advertised it: index a NUMBER and it answers
rem "[] indexing needs a handle (@) or string ($) variable", which tells a reader
rem that string indexing is supported without saying only reading was meant.
rem
rem THE CHARACTER FORM SPLICES, and that is a deliberate improvement on the
rem reference. Plan9Basic's setter takes `Args[2].s.Chars[0]` -- the first
rem character of the replacement and nothing else -- so a two-character
rem replacement silently loses one, and a UTF-16 code-unit write breaks any
rem character outside the BMP. Here the whole replacement takes the place of the
rem one codepoint: a longer string lengthens, an empty one deletes, and nothing
rem is discarded without being asked for.
rem
rem AND OUT OF RANGE IS AN ERROR, where the READ answers "". The asymmetry is the
rem point: a read past the end has an obvious empty answer, a write past the end
rem has no answer at all, and silently doing nothing is the defect this file
rem exists to pin.
rem ---------------------------------------------------------------

rem --- the character form -----------------------------------------
s$ = "abc"
s$[[2]] = "Z"
assert_eq(s$, "aZc", "the n-th character is replaced")

s$ = "abc"
s$[[1]] = "Z"
assert_eq(s$, "Zbc", "the first character is reachable")

s$ = "abc"
s$[[3]] = "Z"
assert_eq(s$, "abZ", "so is the last")

s$ = "abc"
s$[[2]] = ""
assert_eq(s$, "ac", "an empty replacement deletes the character")

s$ = "abc"
s$[[2]] = "XY"
assert_eq(s$, "aXYc", "a longer replacement takes its place whole")

rem --- codepoints, not bytes and not UTF-16 code units -------------
rem cafe-acute is four CHARACTERS and five bytes, so a byte-indexed
rem implementation would answer 5 here and split the accent in half.
s$ = "caf" + chr$(233)
assert_eq(str$(len(s$)), "4", "the accented fixture is four characters")
s$[[4]] = "e"
assert_eq(s$, "cafe", "replacing a multi-byte character leaves no fragment")

s$ = "cafe"
s$[[4]] = chr$(233)
assert_eq(str$(len(s$)), "4", "and writing one back keeps the count")

rem --- the line form ----------------------------------------------
p$ = "one\ntwo\nthree"
p$[2] = "TWO"
assert_eq(p$[2], "TWO", "the n-th line is replaced")
assert_eq(p$[1], "one", "the line before it is untouched")
assert_eq(p$[3], "three", "and the line after it")

p$ = "one\ntwo\nthree"
p$[2] = ""
assert_eq(p$[2], "", "a line can be emptied")
assert_eq(str$(count(p$)), "3", "and emptying one does not remove it")

rem --- out of range says so ---------------------------------------
rem A write past the end cannot do what was asked, so it raises rather than
rem passing in silence. `resume next` continues in control-flow order.
on error goto oops
caught = 0

s$ = "abc"
s$[[9]] = "Z"
assert_eq(s$, "abc", "a character write past the end changed nothing")

s$ = "abc"
s$[[0]] = "Z"
assert_eq(s$, "abc", "and neither did one before the start")

p$ = "one\ntwo"
p$[9] = "X"
assert_eq(p$, "one\ntwo", "a line write past the end changed nothing either")

assert_eq(str$(caught), "3", "all three raised")
println "done"
end

oops:
caught = caught + 1
resume next
