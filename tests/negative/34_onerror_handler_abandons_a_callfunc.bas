rem The same abandoned activation as tests/negative/33, reached through the other
rem door. It needs its own file because the two fall out of DIFFERENT interpreter
rem activations: a direct call is a jump inside one ExecFrom, while callfunc
rem re-enters ExecFrom natively, so here it is the INNER one that runs off the
rem end of the program and the outer one that has to be told.
rem
rem This door is the one with the wrong answer rather than the missing one. The
rem inner activation returned "success" with no return value pushed, so
rem CallUserFunc took the success branch and executed `Result := Pop()` over an
rem operand the CALLER still needed; the caller then carried on after its own
rem call and ran the tail of the program a SECOND time. Measured on the shipped
rem binary: a program that appends one ledger row left TWO rows on disk, 8 bytes,
rem and answered exit 0. A duplicated `print #`, a duplicated HTTP post, a
rem duplicated append -- reported as success.
rem
rem tests/negative/35 and /36 are this same file with one more line in the
rem handler -- `on error goto 0`, and `on error call` -- each of which used to
rem switch the check off and put the second row back on disk.
rem
rem MUST fail, and it must fail ONCE: the first build of the VM check cleared the
rem "a handler is running" flag without disarming the handler, so the error
rem travelled back to the outer activation's opCall, which offered it to that
rem same handler, which ran again and put the second row on disk anyway.
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

tail:
println "TAIL"
