rem ---------------------------------------------------------------
rem A HANDLER THAT RESUMED, IN A PROGRAM THAT ENDS BY RUNNING OFF THE END.
rem
rem This file exists for ONE exit and one line. The VM refuses a program whose
rem `on error goto` handler runs off the end of the program with the call it was
rem raised inside still open. It records that abandonment in a LOCAL of ExecFrom,
rem taken at the moment the handler is jumped to, and RestoreOverlap -- the one
rem operation that actually puts the abandoned activation back -- is what clears
rem it again. Drop that clearing and every handler that DID resume still looks
rem abandoned at the end of the program.
rem
rem Nothing else in the tree notices. tests/suite/54 has handlers that resume,
rem but its program ends at `end` -- opHalt, a different exit, which the check
rem never sees. Measured: with the clearing removed, the whole suite,
rem tests/classic, the examples, the packages and the GUI suite are ALL green,
rem while programs in a generated sweep of the on-error shape space -- a handler
rem installed in a function, entered through either door, resuming, and then
rem ending by falling off the end -- are refused with a runtime error.
rem
rem The clearing is CONDITIONAL, and tests/negative/37, /38 and /42 are the other
rem half of that: a resume settles the record only when the activation it puts
rem back is at or below the recorded depth, so an inner handler resuming its own
rem deeper fault leaves an outer abandonment standing. Both halves have to be
rem right, and each file fails on its own if its half is not.
rem
rem So this file must end WITHOUT an `end`: the last thing it does is fall off
rem the end of the file while the resume state is still set. Anything appended
rem after the final block runs as part of it.
rem ---------------------------------------------------------------

test_case("onerror/a handler installed in a function resumes and the call returns")
assert_eq(rnok(), 5, "resume next came back into the call and it returned its own value")
assert_eq(rnhits, 1, "the handler ran exactly once")

test_case("onerror/`resume` retries the failing statement and the call returns")
assert_eq(rtok(), 12, "resume retried the division with the divisor the handler set")
assert_eq(rthits, 1, "that handler ran exactly once too")

test_case("onerror/the resumed program ends by running off the end of the file")
rem Both calls above left the handler-install depth and the failing-statement
rem depth at 1 -- installed one frame down, and the statement that faulted ran
rem there -- so the only thing separating this program from tests/negative/33 at
rem the exit below is that a resume happened. Do not put an `end` after this
rem line: `end` is opHalt and takes a different exit, and this file would then be
rem green with the very check it exists to hold in place removed.
assert_true(1, "and nothing is left open, because both handlers resumed")
goto fileend

function rnok() local z
  on error goto rnh
  z = 1 / 0
  return 5
endfunction

rem The divisor is a GLOBAL on purpose. `resume` re-runs the failing statement,
rem so the retry has to see a different value or it faults again forever -- and a
rem handler is top-level code, which cannot reach a function's `local` by name.
function rtok() local z
  on error goto rth
  z = 24 / rtdiv
  return z
endfunction

rnh:
rnhits = rnhits + 1
resume next

rth:
rthits = rthits + 1
rtdiv = 2
resume

fileend:
assert_eq(rnhits + rthits, 2, "two handlers, one run each, and the program ends here")
