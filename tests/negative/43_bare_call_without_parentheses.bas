rem A CALL WITH THE PARENTHESES LEFT OFF, which is not a call and used to be legal.
rem `err_clear` names a real, registered, zero-argument function, so the line reads
rem as a correct call and is not one: the compiler saw an identifier, emitted a
rem global read and a discard, and the program ran to exit 0 having cleared nothing.
rem
rem tests/negative/21_orphan_next pins the same shape for a stranded block word.
rem This is the class that word was one instance of -- every registered name behaves
rem this way written bare, and the zero-argument ones are the subset where the bare
rem word looks exactly like the call it is not. It reached this project's own suite:
rem tests/suite/53_bounds said `randomize` and drew from an unseeded generator.
rem
rem The handler is what made the silence measurable before the fix: this file ran
rem clean and printed `code 2` then `after bare: 2` -- the error still there, the
rem clear never called, nothing said about it, exit 0.
on error goto h
x = 1 / 0
h:
println "code " + str$(err())
err_clear
println "after bare: " + str$(err())
