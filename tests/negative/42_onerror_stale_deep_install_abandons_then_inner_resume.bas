rem tests/negative/41 with tests/negative/37's escape added on top, and this is
rem the file that pins the whole shape of the abandonment record.
rem
rem The frame-count arm is switched off here (the stale depth-2 install made the
rem count meaningless, see 41), so the ON ERROR arm is the ONLY thing that can
rem refuse this program -- and the handler then calls a helper whose own handler
rem resumes. Three separate ways of writing that record let this through, each
rem measured on a build that had it:
rem
rem   a flag instead of a depth  -- the inner resume clears it
rem   a depth that is overwritten by the inner jump -- the inner resume then
rem                                matches it and clears it
rem   a depth cleared by any resume at all -- same
rem
rem The record is taken once, at the OUTERMOST jump, and a resume settles it only
rem when the activation it puts back is at or below that depth. The helper's
rem resume restores a frame one level deeper, so it settles its own fault and
rem leaves this one standing.
rem
rem On the shipped binary this program ran its tail TWICE, at exit 0.
function deep(n)
  on error goto h
  return 1
endfunction

function mid(n)
  return deep(n)
endfunction

function helper(n) local z
  on error goto h2
  z = 1 / 0
  return 3
endfunction

function risky(n) local z
  z = 1 / 0
  return 7
endfunction

println "start"
x = mid(1)
println "armed x is " + str$(x)
r = callfunc("risky", 1)
println "NEVER"
goto tail

h:
println "HANDLER"
k = helper(1)
println "helper said " + str$(k)
goto tail

h2:
println "HANDLER2"
resume next

tail:
println "TAIL"
