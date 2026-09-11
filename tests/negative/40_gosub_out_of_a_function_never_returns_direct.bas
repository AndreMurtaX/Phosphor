rem tests/negative/39 through the direct-call door: `c = 1 + risky(1)` never
rem completes, so c keeps 55 and the program said so at exit 0.
rem
rem A TOP-LEVEL gosub whose subroutine ends in `goto` is NOT this defect and must
rem keep working -- no activation is open there, so nothing is abandoned. That
rem shape is asserted correct in tests/suite/62_onerror_abandoned_activation.
function risky(n) local z
  gosub sub
  return 7
endfunction

c = 55
println "start c is " + str$(c)
c = 1 + risky(1)
println "NEVER"

sub:
println "SUB"
println "c is still " + str$(c)
goto tail

tail:
println "TAIL"
