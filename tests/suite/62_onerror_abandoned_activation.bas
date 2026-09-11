rem ---------------------------------------------------------------
rem A HANDLER THAT NEVER RESUMES MAY STILL END THE PROGRAM.
rem
rem The VM refuses a program whose `on error goto` handler runs off the end of
rem the program while the call the error was raised inside is still open. That
rem activation can never return -- a label always belongs to the top level, so
rem the jump left the function for good -- and through callfunc its caller then
rem popped an operand it still needed and ran the tail of the program a SECOND
rem time, at exit 0, with the duplicated side effect on disk.
rem tests/negative/33 to /42 pin that refusal -- /35 and /36 through the two
rem spellings that used to switch the check off from inside the handler, `on
rem error goto 0` and `on error call`; /37 and /38 through an inner handler whose
rem resume used to erase the outer abandonment; /39 and /40 through `gosub`, the
rem same defect with no `on error` in it at all; /41 and /42 through a handler
rem installed DEEPER than the fault by a call that had returned. tests/suite/63
rem pins the other side of the same record: a handler that DID resume, in a
rem program that ends the same way.
rem
rem Every program in this file is the shape NEXT to it and must keep running.
rem A handler INSTALLED AT TOP LEVEL is safe however deep the fault was: the
rem fault puts the frame pointer back where the install stood, which is the
rem bottom, so nothing is left open and control is legitimately at top level
rem again. `on error call` is safe for the opposite reason -- it returns to the
rem call by itself. And a handler that reaches `resume next` unwinds by the
rem route the resume machinery already owns.
rem
rem The last block ends the program from inside a top-level handler that never
rem resumed, which is the exact exit the VM check reads. This file holds TWO of
rem that check's terms in place at once, and loses its summary to a runtime error
rem if either goes: the one asking where the handler was INSTALLED (a top-level
rem install abandons nothing, however deep the fault was), and the frame arm's
rem "an activation is open at all" -- because a top-level handler leaves the
rem frame stack empty, and a check that only asked whether the open activation
rem belongs to this run would read 0 against the top level's floor of -1 and
rem refuse. tests/suite/64 covers the SHAPE the other half of that pair protects,
rem though it does not pin it -- that term is unpinned on purpose and the VM
rem comment says why.
rem ---------------------------------------------------------------

test_case("onerror/a handler installed inside a function still resumes")
assert_eq(insideok(), 5, "the handler ran and resume next came back into the call")

test_case("onerror/`on error call` inside a function returns by itself")
assert_eq(callerok(), 7, "the call form resumed and the function returned its value")
assert_eq(callmsg$, "division by zero", "and the handler saw the error it took")

test_case("onerror/a top-level handler takes a fault raised inside a call")
rem LAST on purpose. Entering a handler that never resumes means control does
rem not come back, so the statements after this one are the handler's own and
rem the program ends by running off the end of the file. The handler was
rem installed at top level and the error was raised one frame down, inside
rem deep(); the fault restored the frame pointer to the install level, so the
rem call is discarded rather than abandoned and this is an ordinary program.
on error goto tlh
tlr = deep(1)
assert_true(0, "the fault must reach the handler, not this line")

end

function insideok() local z
  on error goto ih
  z = 1 / 0
  return 5
endfunction

function callerok() local z
  on error call ch
  z = 1 / 0
  return 7
endfunction

function ch(code%, msg$)
  callmsg$ = msg$
  return 0
endfunction

function deep(n) local z
  z = 1 / 0
  return n
endfunction

ih:
resume next

tlh:
assert_eq(tlr, 0, "the assignment the fault interrupted never completed")
assert_true(1, "and the handler ran to the end of the program without resuming")
