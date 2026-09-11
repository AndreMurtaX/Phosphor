rem An `on error goto` handler installed INSIDE a function, entered, and never
rem resumed. The direct-call door.
rem
rem Labels are recorded in one place -- the top-level loop in Compile -- and a
rem function body never passes through it, so `on error goto h` with `h:` in the
rem body answers "undefined label h" and every handler a function can install is
rem outside it. Jumping there leaves the activation open: the fault put the frame
rem pointer back to the level the handler was INSTALLED at, which is inside the
rem call, so the program then runs top-level code with that call still pending.
rem `resume` and `resume next` are the only way back into it, and nothing else
rem can pop it -- opRetFunc is emitted only inside a function body, and at top
rem level `return <value>` is a parse error while a bare `return` answers
rem "RETURN without GOSUB".
rem
rem What that produced, at exit 0 and invisible to every golden and gate: the
rem rest of the calling statement was dropped, and one activation frame leaked
rem per occurrence, so a long-running program of this shape died at
rem MaxFrameDepth naming the call site and never the handler. The callfunc form,
rem tests/negative/34, is worse still.
rem
rem MUST fail. tests/suite/54_onerror_reentrancy, /62_onerror_abandoned_activation
rem and /63_onerror_resume_then_end_of_program pin the neighbouring shapes that
rem must NOT: a handler installed at top level, a handler installed in a call
rem that has already returned, `on error call`, and any handler that resumes.
rem tests/negative/35 and /36 are this same defect written with one extra line in
rem the handler, which used to be enough to walk through the check.
function risky(n) local z
  on error goto h
  z = 1 / 0
  return 7
endfunction

println "start"
r = risky(1)
println "NEVER"
goto tail

h:
println "HANDLER"

tail:
println "TAIL"
