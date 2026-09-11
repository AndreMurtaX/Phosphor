rem THE LAST SPELLING OF THE DEFECT, and the one that walked through round 3.
rem
rem It needs both halves of the check to be looking the other way at once:
rem
rem   deep() arms at frame depth 2 and RETURNS, so a later fault at top level is
rem   taken two frames shallower than the handler is remembered at. The
rem   dispatcher stands the VM at the remembered depth, over slots deep() and
rem   mid() left behind -- and the frame arm, which has nothing but that count to
rem   go on, used to stand down for the rest of the run.
rem
rem   The abandonment is then made through `gosub` out of a DIRECT call, which
rem   touches no ON ERROR state at all, so the arm that records a handler's jump
rem   has nothing to have recorded.
rem
rem On the round-3 build this program exited 0 with stderr empty and `r is ...`
rem never printed: risky()'s activation was left open and the rest of the calling
rem statement was silently dropped, which is the direct-call face of the same
rem wound tests/negative/39 and /40 show. It is not a regression -- the shipped
rem binary says nothing either -- which is exactly why nothing in the tree could
rem see it.
rem
rem What closed it: the mark that says "the frame count is fabricated" is a RANGE
rem rather than a flag, so frames pushed ABOVE the fabrication are still counted.
rem risky() is pushed above it, and the frame arm sees it again.
rem tests/suite/65 and /67 are the correct programs from the same state that must
rem keep running, and they are what makes this a range and not a wider refusal.
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
println "NEVER"
goto tail

h:
println "HANDLER"
r = risky(1)
println "r is " + str$(r)
goto tail

sub1:
println "SUB"
goto tail

tail:
println "TAIL"
