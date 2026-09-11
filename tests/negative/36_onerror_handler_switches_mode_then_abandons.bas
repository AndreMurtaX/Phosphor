rem The third spelling of tests/negative/35's hole, and the reason the VM check
rem carries no `FErrHandlerMode = 0` term.
rem
rem `on error call` is the form that unwinds by itself, so a check meant to spare
rem it reads naturally as "only when the installed mode is goto". But the mode is
rem a FIELD, and the handler running here is top-level code that may write it: one
rem `on error call` inside the abandoned handler moves it to 1 and the program
rem walks out with the activation still open. Measured on a build carrying that
rem term: two ledger rows on disk from a program that appends one, at exit 0.
rem
rem The engine asks the question a different way instead. The local that records
rem the jump is assigned in exactly one place -- the goto arm of the fault
rem dispatcher -- so it already means "a GOTO handler ran in this activation", and
rem a mode field read later can only contradict it. `on error call` is untouched
rem because it never sets that local; tests/suite/62_onerror_abandoned_activation
rem pins an `on error call` installed inside a function still working.
rem
rem MUST fail.
function risky(n) local z
  on error goto h
  z = 1 / 0
  return 7
endfunction

function hcall(code%, msg$)
  return 0
endfunction

println "start"
r = callfunc("risky", 1)
println "NEVER"
goto tail

h:
println "HANDLER"
on error call hcall

tail:
println "TAIL"
