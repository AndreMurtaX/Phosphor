rem ---------------------------------------------------------------
rem A RE-ENTRANT ACTIVATION THAT ENDS THE ONLY WAY IT LEGITIMATELY CAN.
rem
rem The VM refuses a program that reaches the end with a user-function activation
rem still open. The frame-count arm of that check is two terms, and the second --
rem FFrameSP > AStopFrameSP, "the open activation belongs to THIS run rather than
rem to an outer one still live on the Pascal stack" -- exists because
rem ResumeAtNextStmt ends a re-entrant run on purpose, popping to exactly the
rem depth the run was entered at and setting pc past the last instruction. That
rem is the same exit the defect takes, and only that depth tells them apart.
rem
rem THIS FILE IS A SHAPE GUARD AND NOT A TERM PIN, AND SAYS SO RATHER THAN
rem IMPLYING OTHERWISE. It was written to pin that second term and does not:
rem removing the term leaves this file, every other corpus, a generated sweep of
rem 78 on-error and gosub shapes and eight programs written for no other purpose
rem than to reach that exit ALL green. A trace build printing the two depths at
rem the check showed why -- every one of them arrives from the TOP level, because
rem the compiler's implicit end-of-body return sits inside the body, so a resume
rem at the last statement lands on it and leaves through opRetFunc instead. The
rem term stays because failing to reach an exit is not proof it is unreachable
rem and the engine documents that exit as legitimate; see the VM comment.
rem
rem What this file does hold is the SHAPE: a callfunc made from inside another
rem function, whose callee faults and resumes, must keep working through both
rem `resume next` and `resume`. That is the nesting the check is most likely to
rem get wrong, and nothing else in the tree exercises it.
rem ---------------------------------------------------------------

test_case("onerror/resume next ends a callfunc made from inside a function")
assert_eq(nouter(1), 0, "the callee's body ended at the resume, so its default came back")
assert_eq(nhits, 1, "the callee's handler ran exactly once")

test_case("onerror/`resume` retries inside the same nesting and the body returns")
assert_eq(nouter2(1), 12, "the retry saw the divisor the handler set and the body returned it")
assert_eq(n2hits, 1, "that handler ran exactly once too")

test_case("onerror/both nestings came back and nothing is left open")
assert_eq(nhits + n2hits, 2, "two handlers, one run each")
goto fileend

rem The failing statement is the LAST of this body on purpose: that is what sends
rem the resume through ResumeAtNextStmt's "this activation is done" exit rather
rem than to another statement of the body.
function ninner(n) local z
  on error goto nh
  z = 1 / 0
endfunction

function nouter(n)
  return callfunc("ninner", n)
endfunction

rem The divisor is a GLOBAL because `resume` re-runs the failing statement and a
rem handler is top-level code, which cannot reach a function's `local` by name.
function ninner2(n) local z
  on error goto nh2
  z = 24 / ndiv
  return z
endfunction

function nouter2(n)
  return callfunc("ninner2", n)
endfunction

nh:
nhits = nhits + 1
resume next

nh2:
n2hits = n2hits + 1
ndiv = 2
resume

fileend:
assert_true(1, "and the program ends here, without an `end`")
