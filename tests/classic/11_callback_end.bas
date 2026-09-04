rem Execution ORDER across a re-entrant call. A golden is the right assertion here:
rem the defects were not wrong values but statements running twice, or not at all.
rem
rem Both shapes below come from an adversarial hunt and both reproduce with the
rem shipped binary:
rem   * a fault inside callfunc whose handler leaves by GOTO ran the whole rest of
rem     the program inside the nested activation, which then returned "success" to
rem     the caller -- so everything from the call onward executed TWICE, including
rem     the line the first pass had correctly skipped.
rem   * END inside a callfunc'd routine ended only that activation. Its caller read
rem     the exit as an ordinary return, popped the operand it was still holding as
rem     the "return value", and carried on with a corrupted stack. The shipped GUI
rem     host dispatches every button click through the same path, so a click handler
rem     that says `end` to quit did this once per click.

print "start|"
on error goto h
r = callfunc("boomer")
print "unreached|"
h:
print "handler|"
on error goto 0
print "tail|"

rem A callback that ends the program ends the PROGRAM. Nothing after this line runs,
rem and the pending "KEEP" must not come back as the call's result.
k$ = "KEEP" + str$(callfunc("quitter"))
print "never|"
print k$
end

function boomer()
  error("boom")
  return 1
endfunction

function quitter()
  end
endfunction
