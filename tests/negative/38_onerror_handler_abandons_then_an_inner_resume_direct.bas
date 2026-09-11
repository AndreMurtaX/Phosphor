rem tests/negative/37 through the direct-call door, where the symptom is the
rem missing answer rather than the duplicated one: the rest of `c = 1 + risky(1)`
rem never runs, so c keeps 55 and the program says so at exit 0.
rem
rem It needs its own file for the reason 33 needs one beside 34: a direct call is
rem a jump inside ONE ExecFrom, while callfunc re-enters ExecFrom natively, so
rem the abandoned frame is judged against a different floor in each -- -1 at the
rem top level, the caller's real depth for a re-entrant activation.
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

c = 55
println "start c is " + str$(c)
c = 1 + risky(1)
println "NEVER"

h:
println "HANDLER"
k = inner(1)
println "inner said " + str$(k)
println "c is still " + str$(c)
goto tail

h2:
println "HANDLER2"
resume next

tail:
println "TAIL"
