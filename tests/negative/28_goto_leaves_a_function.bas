rem A GOTO inside a function body, which can only ever name a label outside it.
rem
rem Labels are recorded in one place -- the top-level loop in Compile -- and a
rem function body never passes through it, so there is no such thing as a label
rem inside a function and the jump necessarily abandons the activation. The
rem compiler emitted it anyway and said nothing.
rem
rem What that produced: `c = a + esc()` never finished, c kept its old value, the
rem operand stayed on the stack and the frame was never popped -- exit 0, no
rem diagnostic. Through `callfunc` the escape happens inside a frame-bounded
rem ExecFrom, so the tail of the program ran once INSIDE the call and once again
rem after it returned: every side effect after the label happened twice. Repeating
rem it leaked one frame per call.
rem
rem MUST fail. docs/libraries/err.md already said `on error call` is the form to
rem use inside a function, "and a label written inside a function body is not
rem somewhere `on error goto` can reach" -- the prose was right and nothing
rem enforced it.
rem
rem WHAT IS *NOT* REFUSED, and the first version of this check got it wrong: a
rem jump that COMES BACK. `gosub`, `on <expr> gosub` and `on error goto <label>`
rem all return into the activation, and twelve programs using them answer
rem correctly -- two of them byte-identical to the same program with the handler
rem installed at top level, which is the documented pattern. Only `goto` and
rem `on <expr> goto` PROVABLY never return, and only those are refused -- this
rem file pins the first, tests/negative/30 the second. The check sits at AddGoto,
rem the one place every jump to a label is registered, and discriminates on the
rem opcode: opJump never comes back; opGosub and opSetErrHandler come back when
rem their target does, which this site cannot see. A sub that ends in `goto`, or
rem a handler that never reaches `resume`, still abandons the frame the same way
rem -- measured, unchanged from before this check, and a VM-side repair, not a
rem compile-time one. `on error goto 0` names no label and stays legal.
function esc()
  goto done
endfunction
a = 5
c = a + esc()
println "c="; c
done:
println "reached done, c="; c
