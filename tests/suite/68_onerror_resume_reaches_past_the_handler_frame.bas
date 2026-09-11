rem ---------------------------------------------------------------
rem A RESUME THAT PUTS BACK MORE THAN THE HANDLER'S OWN FRAME.
rem
rem A handler runs at the level it was INSTALLED at; `resume` returns to the
rem level the failing STATEMENT ran at. The two are equal only when the fault was
rem raised in the handler's own frame. Raise it one call deeper -- `w = 1000 +
rem ovg(1)` inside a function that installed the handler -- and the resume has to
rem put back everything between, which is what FErrSaveStack and FErrSaveFrames
rem exist for. That is an ordinary program: both activations come back and both
rem return.
rem
rem THIS FILE IS HERE BECAUSE THAT PROGRAM WAS REFUSED. The end-of-program check
rem that tests/negative/33 to /43 pin records an abandonment at the handler's
rem level and settled it by asking whether the level being restored to was at or
rem below that -- true for a fault in the handler's own frame, false for every
rem fault one call deeper. So this program answered 1003, printed its tail, and
rem then exited 1 with "the call to ovg ... was never returned from" about a call
rem that had returned. The record now carries WHICH FAULT it was taken at, and
rem the resume of that fault settles it however deep the fault was raised.
rem
rem The second block is the same shape through `resume next`, which comes back by
rem a different road (ResumeAtNextStmt continues inside the body that faulted)
rem and must settle the same record.
rem
rem THIS FILE MUST END BY RUNNING OFF THE END, with no `end`: `end` is opHalt, a
rem different exit, and the check being held here is never reached from it.
rem Anything appended after the last block runs as part of it.
rem ---------------------------------------------------------------

test_case("onerror/a handler in a function resumes a fault raised one call deeper")
ovd = 0
ovr = ovf(1)
rem Derived, not read off the run: the handler sets ovd to 2, `resume` re-runs
rem the failing statement so ovg's z becomes 10 / 2, and ovg returns 3 whatever z
rem is. ovf then answers 1000 + 3.
assert_eq(ovr, 1003, "the resume put both activations back and both returned")
assert_eq(ovhits, 1, "the handler ran exactly once")

test_case("onerror/the same shape through resume next")
ovd2 = 0
ovr2 = ovf2(1)
rem `resume next` skips the failing statement instead of re-running it, so ovg2's
rem z keeps the 0 it started at and ovg2 returns 4 regardless: 1000 + 4.
assert_eq(ovr2, 1004, "resume next continued inside the deeper call")

goto ovend

ovh:
ovhits = ovhits + 1
ovd = 2
resume

ovh2:
ovd2 = 2
resume next

function ovg(n) local z
  z = 10 / ovd
  return 3
endfunction

function ovf(n) local w
  on error goto ovh
  w = 1000 + ovg(1)
  return w
endfunction

function ovg2(n) local z
  z = 10 / ovd2
  return 4
endfunction

function ovf2(n) local w
  on error goto ovh2
  w = 1000 + ovg2(1)
  return w
endfunction

ovend:
assert_true(1, "and this program ends by running off the end of the file")
