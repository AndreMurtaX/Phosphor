rem ---------------------------------------------------------------
rem PRINT, and the invariant underneath it.
rem
rem fPrint reads two different things out of the stack. The value it
rem is printing, it reads after consulting TypeStack. The separator
rem between two values, it used to read without consulting anything:
rem it took StackMem[..].s and expected to find "," or ";" there.
rem
rem That worked for one reason only. Every numeric push copied an
rem empty string over the slot on its way in, so a slot could never
rem hand PRINT the text of whatever used to live there. Until now
rem that was the compiler's doing -- a whole-record assignment moved
rem all three fields -- and it is now three handlers writing the
rem fields by hand, which means it is an invariant somebody has to
rem remember.
rem
rem So this file fills the stack region with strings and then prints
rem numbers through the same slots. If a numeric push ever stops
rem clearing the string, the separator read finds stale text and the
rem program dies with a PRINT syntax mismatch rather than printing
rem something slightly wrong.
rem ---------------------------------------------------------------

test_case("print/leaves-values-alone")
n = 42
s$ = "text"
println "a"; n; "b"
println n; " "; n
println "x", n, "y"
assert_eq(n, 42, "PRINT did not disturb the numeric global")
assert_eq(s$, "text", "PRINT did not disturb the string global")

test_case("print/numbers-through-slots-that-held-strings")
rem Build strings first, so the stack cells these pushes land in are
rem carrying real text rather than empty ones.
rem mid$ is 1-based here, so start 2 takes "el" (chars 2..3), not "he".
t$ = ucase$("aaa") + lcase$("BBB") + mid$("hello", 2, 2)
assert_eq(t$, "AAAbbbel", "the strings were really built")
println 1; 2; 3
println 10, 20, 30
println 1; "x"; 2; "y"; 3
assert_eq(t$, "AAAbbbel", "and survived the numbers printed after them")

test_case("print/alternating-kinds")
rem Same idea, alternating within one statement, several times, so a
rem slot is reused as string then number then string again.
for i = 1 to 20
  u$ = "row " + stri$(i)
  println u$; " "; i; " "; u$
next
assert_eq(u$, "row 20", "the loop's string variable is intact")
assert_eq(i, 21, "and so is its counter")

test_case("print/empty-and-single")
println ""
println "only text"
println 7
print "no newline here"
println ""
assert_eq(n, 42, "the short forms left the stack balanced too")

test_case("print/separator-spacing-still-applies")
rem "," pads to a column and ";" does not. Nothing here can read the
rem output back, but both paths through the separator branch have to
rem execute without raising.
println 1, 2
println 1; 2
println "a", "b"
println "a"; "b"
assert_true(1, "every separator path ran")
