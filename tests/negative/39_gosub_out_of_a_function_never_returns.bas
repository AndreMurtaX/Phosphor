rem THE SAME DEFECT WITH NO `on error` IN IT AT ALL, and PhosphorCompiler.pas
rem names this spelling in the same sentence as the handler one:
rem
rem   "A subroutine that ends in `goto` instead of `return`, and a handler that
rem    never reaches `resume`, both abandon the activation exactly as `goto`
rem    does"
rem
rem `gosub` from inside a function body reaches a top-level label -- labels are
rem recorded in Compile's top-level loop, which a body never passes through, so a
rem subroutine is always OUTSIDE the function that jumps to it. A subroutine that
rem `return`s comes back and the call completes; one that ends in `goto` leaves
rem the call open exactly as an unresumed handler does, and on the shipped binary
rem this program ran its tail TWICE at exit 0.
rem
rem It is here because a check built only on the ON ERROR state cannot see this:
rem nothing in the program ever installs a handler, so every field it would read
rem is untouched. The frame stack is the thing both spellings do move.
rem
rem tests/negative/40 is the direct-call door of the same program.
function risky(n) local z
  gosub sub
  return 7
endfunction

println "start"
r = callfunc("risky", 1)
println "NEVER"
goto tail

sub:
println "SUB"
goto tail

tail:
println "TAIL"
