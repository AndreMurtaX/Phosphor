rem The abandoned activation of tests/negative/34 with ONE more line in the
rem handler: `on error goto 0`. It is its own file because that line used to walk
rem the whole defect straight back through the check, and nothing said so.
rem
rem Why it walked through: opSetErrHandler ends with `FInHandler := False`
rem OUTSIDE its own if/else, so the DISABLE branch clears it along with the
rem enable branch. A guard keyed on that field is therefore switched off by the
rem very statement a careful author reaches for -- `on error goto 0` is one of
rem the five error statements the reference lists, it is taught in
rem docs/language-reference.md, and docs/libraries/err.md uses it in its own
rem worked example. Measured on the first build of the VM check: this program
rem still put TWO ledger rows on disk from a program that appends one, at exit 0.
rem
rem The VM now records "this activation jumped to a handler" in a LOCAL of
rem ExecFrom, set at the jump and cleared only where the activation is really put
rem back -- beside RestoreOverlap in opResume. No `on error` statement can reach
rem it. tests/negative/36 is the same hole through the third spelling.
rem
rem MUST fail. tests/suite/54_onerror_reentrancy and
rem tests/suite/62_onerror_abandoned_activation pin the shapes that must NOT.
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
on error goto 0

tail:
println "TAIL"
