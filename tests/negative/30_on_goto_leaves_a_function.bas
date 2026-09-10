rem `on <expr> goto` inside a function body -- the SECOND shape that leaves and
rem never comes back, and the one nothing else pins.
rem
rem tests/negative/28 covers the plain `goto`. It cannot cover this one: the two
rem reach AddGoto from different procedures. `goto` is parsed by ParseStatement
rem (engine/PhosphorCompiler.pas, the `goto` branch); `on <expr> goto` is parsed
rem by ParseOnGoto, which shares its whole body with `on <expr> gosub` and tells
rem the two apart by one boolean. Flipping that one argument from False to True
rem would un-refuse this shape and leave every suite green -- which is exactly the
rem kind of silent break a gate exists to stop.
rem
rem MUST fail. Without the check this file runs to completion and prints `lbl1`:
rem `esc()` is abandoned in the middle of `a = esc()`, the operand stays on the
rem stack, the frame is never popped, and the program exits 0 with the assignment
rem never made. That is the same defect as 28, through the other door.
rem
rem What is NOT refused is a jump that comes back -- `gosub`, `on <expr> gosub`
rem and `on error goto <label>`. tests/suite/54_onerror_reentrancy.bas pins those.
function esc()
  on 1 goto lbl1
  return 7
endfunction
a = esc()
println "a="; a
lbl1:
println "lbl1"
