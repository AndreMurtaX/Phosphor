rem ---------------------------------------------------------------
rem A FRAME COUNT THAT IS NOT A COUNT OF OPEN ACTIVATIONS.
rem
rem `on error goto` remembers the frame depth it was installed at, and keeps
rem remembering it after the call that installed it has RETURNED. When a later
rem fault is taken SHALLOWER than that, the fault dispatcher stands the VM at the
rem remembered depth -- over frame slots the returned call left behind. The
rem program is correct: nothing is pending, and the top level has no opcode that
rem could return from those slots anyway. But from that moment the frame count is
rem no longer a count of open activations, and the arm of the end-of-program
rem check that has nothing but that count to go on has to stand down.
rem
rem This file is the program that proved it has to. The first build of that arm
rem cleared the "the count is unreliable" mark on the next resume, which made it
rem right again for the fault that had just finished and wrong for the fabricated
rem frames still underneath -- so a handler over a stale install that calls an
rem ordinary helper with its own resuming handler was REFUSED. A generated sweep
rem of the on-error shape space caught it; nothing else in the tree did.
rem
rem The other side of the same mark is tests/negative/41 and /42: the mark makes
rem the frame arm stand down, and the ON ERROR arm -- a record taken at the jump
rem rather than read from a field at the end -- is what refuses those.
rem
rem THIS FILE MUST END BY RUNNING OFF THE END, with no `end`: `end` is opHalt, a
rem different exit, and the check being held here is never reached from it.
rem Anything appended after the last block runs as part of it.
rem ---------------------------------------------------------------

test_case("onerror/a handler installed deeper than the fault, by a call that returned")
assert_eq(cmid(1), 1, "the installing call returned normally and left its depth remembered")
rem The fault below is taken at TOP LEVEL, one frame shallower than the depth the
rem handler is remembered at. Everything after it on this line's own path is
rem skipped, so the rest of the assertions live in the handler.
czz = 1 / 0
assert_true(0, "unreachable: the fault above must have jumped to the handler")
goto fileend

ch:
chits = chits + 1
assert_eq(chelp(1), 3, "a helper called from the handler resumed its own fault and returned")
assert_eq(chits, 1, "the outer handler ran exactly once")
goto fileend

ch2:
c2hits = c2hits + 1
resume next

function cdeep(n)
  on error goto ch
  return 1
endfunction

function cmid(n)
  return cdeep(n)
endfunction

function chelp(n) local z
  on error goto ch2
  z = 1 / 0
  return 3
endfunction

fileend:
assert_eq(c2hits, 1, "the helper's handler ran once, and this program ends here")
