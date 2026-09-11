rem ---------------------------------------------------------------
rem A FAULT RAISED WHERE THE FRAME COUNT IS FABRICATED IS NOT AN ABANDONMENT.
rem
rem tests/suite/65 is the other half of this. When a handler's install is STALE
rem -- `on error goto` executed in a call that has since returned -- the fault
rem dispatcher stands the VM at the remembered depth, over frame slots the
rem returned call left behind. From that moment a frame DEPTH is not a count of
rem open activations, and every question asked of one has to say which slots are
rem real.
rem
rem The frame arm of the end-of-program check learned that in round 3 (that is
rem what 65 pins). The ON ERROR arm did not, and this file is the program that
rem showed it: inside such a handler, top-level code re-arms and takes a fault of
rem its own. Its FErrStmtFrameSP is 2 -- "the failing statement ran inside a
rem call" -- and nothing at all is open, because nothing has been pushed since
rem stmid() returned. The check recorded an abandonment, named stdeep (a function
rem that had returned), and refused a program that answers correctly and runs to
rem its end. Ten shapes of it were refused; a generated sweep that crossed this
rem state with every other axis found them, and none of the tree's corpora did.
rem
rem tests/negative/41 and /42 are the shapes that MUST still be refused from the
rem same state, and they are why the term is a range and not just a ceiling: in
rem those the fabricated slots sit ABOVE a real activation, and the real one is
rem what the failing statement ran in.
rem
rem THIS FILE MUST END BY RUNNING OFF THE END, with no `end`: `end` is opHalt, a
rem different exit, and the check being held here is never reached from it.
rem Anything appended after the last block runs as part of it.
rem ---------------------------------------------------------------

test_case("onerror/a fault taken by a handler standing over a stale deep install")
assert_eq(stmid(1), 1, "the installing call returned and left its depth remembered")
rem The fault below is taken at TOP LEVEL, two frames shallower than the depth
rem the handler is remembered at, so the dispatcher fabricates the difference.
stz = 1 / 0
assert_true(0, "unreachable: the fault above must have jumped to the handler")
goto stend

sth:
sthits = sthits + 1
rem Re-arming clears FInHandler, so the fault on the next line is taken rather
rem than aborting. It is raised by TOP-LEVEL code -- the handler's own -- while
rem the VM stands two frames up, so its depth describes slots stdeep() and
rem stmid() left behind rather than any call that is open.
on error goto sth2
stz2 = 1 / 0
assert_true(0, "unreachable: the second fault must have jumped to sth2")

sth2:
assert_eq(sthits, 1, "the first handler ran exactly once")
goto stend

function stdeep(n)
  on error goto sth
  return 1
endfunction

function stmid(n)
  return stdeep(n)
endfunction

stend:
assert_true(1, "neither handler resumed, and neither left anything open")
