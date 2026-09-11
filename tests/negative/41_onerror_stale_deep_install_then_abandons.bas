rem THE SHAPE ONLY THE ON ERROR ARM OF THE CHECK CAN SEE, and it is here because
rem the other arm is deliberately switched off for it.
rem
rem deep() installs the handler at frame depth 2 and RETURNS, so the engine keeps
rem remembering depth 2 for the rest of the run. The later fault happens at depth
rem 1, inside risky(), and the fault dispatcher stands the VM at the handler's
rem REMEMBERED depth -- which is above the real one, so the frame count now
rem includes a slot deep() left behind. From then on the frame count is not a
rem count of open activations, and the arm that has nothing but that count to go
rem on stands down rather than risk refusing a correct program (it did refuse
rem one: see tests/suite/65).
rem
rem What is left looking is the record taken AT THE JUMP: the handler was running
rem with an activation under it and the failing statement really ran inside one.
rem risky()'s call is genuinely abandoned here -- on the shipped binary this
rem program ran its tail TWICE and left two ROW lines on disk from a program that
rem appends one, at exit 0.
rem
rem tests/negative/42 adds the inner resume to this, which is what pins the
rem record being a DEPTH rather than a flag.
function deep(n)
  on error goto h
  return 1
endfunction

function mid(n)
  return deep(n)
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
goto tail

tail:
println "TAIL"
