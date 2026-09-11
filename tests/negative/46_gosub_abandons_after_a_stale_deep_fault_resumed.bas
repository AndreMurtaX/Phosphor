rem THE SAME DEFECT ONE STEP LATER, and it is here to hold the half of the
rem fabricated-frame mark that nothing else does: the half that puts it back.
rem
rem deep() arms at frame depth 2 and RETURNS, so the top-level fault below is
rem taken two frames shallower than the handler is remembered at and the
rem dispatcher fabricates the difference. Then the handler RESUMES. That resume
rem stands the interpreter back at the failing statement's own level -- top level
rem -- and the fabricated slots go with it: nothing is left over them, and the
rem frame count is a count of open calls again.
rem
rem So the abandonment that follows, a `gosub` out of a direct call that never
rem returns, is an ordinary one and must be refused exactly as tests/negative/40
rem is. If the mark is raised and never lowered, it still reads 2 here, the one
rem open frame reads as fabricated, and this program ends at exit 0 with risky()
rem left open and `r is ...` never printed.
rem
rem Measured: with the lowering removed -- and only with the lowering removed --
rem every other file in every corpus on both operating systems stays green and
rem this one runs instead of being rejected. tests/suite/65 and /67 are the
rem correct programs from the same state, and tests/negative/43 is this program
rem WITHOUT the resume, where the mark is still standing and the range's upper
rem end is what sees over it.
function deep(n)
  on error goto h
  return 1
endfunction

function mid(n)
  return deep(n)
endfunction

function risky(n) local k
  k = 1
  gosub sub1
  return 7
endfunction

println "start"
x = mid(1)
println "armed x is " + str$(x)
z = 1 / 0
println "after the resume"
r = risky(1)
println "r is " + str$(r)
goto tail

h:
println "HANDLER"
resume next

sub1:
println "SUB"
goto tail

tail:
println "TAIL"
