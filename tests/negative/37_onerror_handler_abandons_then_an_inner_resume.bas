rem tests/negative/34 plus three ordinary lines, and those three lines walked the
rem whole defect through the first version of this check.
rem
rem The handler abandons risky()'s activation and then calls an ordinary helper
rem that has its own `on error goto` / `resume next`. Any record of "a handler is
rem out and has not come back" that is ONE FLAG per activation is cleared by that
rem inner resume, and the outer abandonment stops being visible. Measured on a
rem build of the flag version: this program printed its tail TWICE and left two
rem ROW lines on disk from a program that appends one, at exit 0 -- byte for byte
rem the answer the unprotected engine gives.
rem
rem So the record is a DEPTH, kept at the outermost abandonment, and a resume
rem clears it only when the activation it puts back is at or below that depth.
rem The inner resume here restores a frame ONE LEVEL DEEPER than the abandoned
rem one, so it settles its own fault and leaves this one standing.
rem
rem tests/negative/38 is the same shape through the direct-call door.
function inner(n) local z
  on error goto h2
  z = 1 / 0
  return 3
endfunction

function risky(n) local z
  on error goto h
  z = 1 / 0
  return 7
endfunction

println "start"
r = callfunc("risky", 1)
println "NEVER"
goto tail

h:
println "HANDLER"
k = inner(1)
println "inner said " + str$(k)
goto tail

h2:
println "HANDLER2"
resume next

tail:
println "TAIL"
